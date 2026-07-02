#!/usr/bin/env python3
"""Submit an uploaded Distavo build to Mac App Store review.

Automates the App Store Connect steps that used to be manual clicks:
wait for build processing, set export compliance, create/reuse the
version record (release type: after approval), set "What's New", attach
the build, and submit for review via the Review Submissions API.

Auth: App Store Connect API key (the same one release-appstore.yml uses).
  ASC_API_KEY_ID       key id
  ASC_API_ISSUER_ID    issuer id
  ASC_API_KEY_P8_PATH  path to AuthKey_XXXX.p8 (or ASC_API_KEY_P8_BASE64)

Every step is find-before-create and safe to re-run. `--dry-run` performs
only GETs and prints the mutations it would make. `--until` stops after a
named phase so the earlier phases can be exercised without submitting.

Deps: PyJWT[crypto], requests.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import sys
import time
from pathlib import Path

import jwt
import requests

ROOT = Path(__file__).resolve().parents[1]
PROJECT_YML = ROOT / "apple" / "project.yml"
DEFAULT_WHATS_NEW_DIR = ROOT / "apple" / "metadata" / "whats-new"

BUNDLE_ID = "uk.co.riera.distavo"
PLATFORM = "MAC_OS"
API_BASE = "https://api.appstoreconnect.apple.com"
TOKEN_LIFETIME_SECONDS = 15 * 60

PHASES = ["processed", "compliance", "version", "attach", "submit"]

# appVersionState values in which the version record is still editable and can
# be (re)used for this submission. Anything else means a submission is already
# in flight or the version has shipped — bail out with a clear message.
REUSABLE_VERSION_STATES = {
    "PREPARE_FOR_SUBMISSION",
    "REJECTED",
    "DEVELOPER_REJECTED",
    "METADATA_REJECTED",
    "INVALID_BINARY",
    "READY_FOR_REVIEW",  # sitting in an unsubmitted review-submission draft
    "WAITING_FOR_EXPORT_COMPLIANCE",
}

# reviewSubmissions states that mean "already with Apple" — do not double-submit.
IN_FLIGHT_SUBMISSION_STATES = ["WAITING_FOR_REVIEW", "IN_REVIEW", "UNRESOLVED_ISSUES"]

# States proving a version reached (or passed) release. Apple only allows
# "What's New" text once a previous version actually shipped — draft or
# rejected records don't count.
RELEASED_VERSION_STATES = {
    "ACCEPTED",
    "PROCESSING_FOR_DISTRIBUTION",
    "PENDING_APPLE_RELEASE",
    "PENDING_DEVELOPER_RELEASE",
    "READY_FOR_DISTRIBUTION",
    "READY_FOR_SALE",  # legacy appStoreState name
    "REPLACED_WITH_NEW_VERSION",
}


class SubmitError(Exception):
    """Fatal, already-explained condition; printed without a traceback."""


class AscClient:
    """Minimal App Store Connect REST client with ES256 JWT auth."""

    def __init__(self, key_id: str, issuer_id: str, private_key: str, dry_run: bool):
        self.key_id = key_id
        self.issuer_id = issuer_id
        self.private_key = private_key
        self.dry_run = dry_run
        self.session = requests.Session()
        self._token = ""
        self._token_expiry = 0.0

    def _bearer(self) -> str:
        if time.time() > self._token_expiry - 60:
            now = int(time.time())
            self._token_expiry = now + TOKEN_LIFETIME_SECONDS
            self._token = jwt.encode(
                {"iss": self.issuer_id, "iat": now, "exp": int(self._token_expiry),
                 "aud": "appstoreconnect-v1"},
                self.private_key,
                algorithm="ES256",
                headers={"kid": self.key_id, "typ": "JWT"},
            )
        return self._token

    def _request(self, method: str, path: str, params: dict | None = None,
                 payload: dict | None = None) -> dict:
        url = f"{API_BASE}{path}"
        for attempt in range(5):
            try:
                resp = self.session.request(
                    method, url, params=params, json=payload,
                    headers={"Authorization": f"Bearer {self._bearer()}"}, timeout=60,
                )
            except requests.RequestException as exc:
                wait = 2 ** attempt * 5
                print(f"  network error talking to ASC ({exc}); retrying in {wait}s")
                time.sleep(wait)
                continue
            if resp.status_code == 429 or resp.status_code >= 500:
                wait = 2 ** attempt * 5
                print(f"  ASC returned {resp.status_code}; retrying in {wait}s")
                time.sleep(wait)
                continue
            if resp.status_code == 401:
                raise SubmitError(
                    "ASC API returned 401 — check ASC_API_KEY_ID/ASC_API_ISSUER_ID, "
                    "the .p8 contents, and that this machine's clock is correct."
                )
            if resp.status_code >= 400:
                raise SubmitError(
                    f"{method} {path} failed with {resp.status_code}:\n"
                    f"{json.dumps(resp.json() if resp.content else {}, indent=2)}"
                )
            return resp.json() if resp.content else {}
        raise SubmitError(f"{method} {path}: still failing after retries")

    def get(self, path: str, params: dict | None = None) -> dict:
        return self._request("GET", path, params=params)

    def mutate(self, method: str, path: str, payload: dict, describe: str) -> dict | None:
        """POST/PATCH, or print-and-skip in --dry-run. Returns None when skipped."""
        if self.dry_run:
            print(f"  DRY-RUN would {describe}:")
            print(f"    {method} {path}")
            print("    " + json.dumps(payload, indent=2).replace("\n", "\n    "))
            return None
        print(f"  {describe}")
        return self._request(method, path, payload=payload)


def read_project_versions() -> tuple[str, str]:
    """(marketing version, build number) from apple/project.yml — same source
    of truth bump-minor-version.py maintains."""
    text = PROJECT_YML.read_text(encoding="utf-8")
    marketing = re.search(r'^\s*MARKETING_VERSION:\s*"([^"]+)"\s*$', text, flags=re.MULTILINE)
    build = re.search(r'^\s*CURRENT_PROJECT_VERSION:\s*"(\d+)"\s*$', text, flags=re.MULTILINE)
    if marketing is None or build is None:
        raise SubmitError(f"could not read versions from {PROJECT_YML}")
    return marketing.group(1), build.group(1)


def load_private_key() -> str:
    path = os.environ.get("ASC_API_KEY_P8_PATH")
    if path:
        return Path(path).expanduser().read_text(encoding="utf-8")
    b64 = os.environ.get("ASC_API_KEY_P8_BASE64")
    if b64:
        return base64.b64decode(b64).decode("utf-8")
    raise SubmitError("set ASC_API_KEY_P8_PATH (or ASC_API_KEY_P8_BASE64)")


def load_whats_new(whats_new_dir: Path) -> dict[str, str]:
    """locale -> text. Fails fast so a blank listing never reaches Apple."""
    if not whats_new_dir.is_dir():
        raise SubmitError(f"whats-new directory not found: {whats_new_dir}")
    notes = {}
    for f in sorted(whats_new_dir.glob("*.txt")):
        text = f.read_text(encoding="utf-8").strip()
        if not text:
            raise SubmitError(f"whats-new file is empty: {f}")
        if len(text) > 4000:
            raise SubmitError(f"whats-new file exceeds Apple's 4000-char limit: {f}")
        notes[f.stem] = text
    if not notes:
        raise SubmitError(f"no <locale>.txt files in {whats_new_dir}")
    return notes


def resolve_app(client: AscClient) -> str:
    data = client.get("/v1/apps", params={"filter[bundleId]": BUNDLE_ID})["data"]
    if not data:
        raise SubmitError(f"no App Store Connect app found for bundle id {BUNDLE_ID}")
    app_id = data[0]["id"]
    print(f"App: {data[0]['attributes']['name']} ({BUNDLE_ID}) — id {app_id}")
    return app_id


def wait_for_build(client: AscClient, app_id: str, marketing: str, build_number: str,
                   timeout_minutes: int) -> dict:
    params = {
        "filter[app]": app_id,
        "filter[version]": build_number,
        "filter[preReleaseVersion.version]": marketing,
        "sort": "-uploadedDate",
        "limit": "1",
    }
    deadline = time.time() + timeout_minutes * 60
    while True:
        data = client.get("/v1/builds", params=params)["data"]
        if data:
            build = data[0]
            state = build["attributes"]["processingState"]
            print(f"Build {marketing} ({build_number}): processingState={state}")
            if state == "VALID":
                return build
            if state in ("FAILED", "INVALID"):
                raise SubmitError(
                    f"Apple marked build {build_number} as {state} — fix and re-upload. "
                    f"Details: {json.dumps(build['attributes'], indent=2)}"
                )
        else:
            print(f"Build {marketing} ({build_number}) not visible yet "
                  "(upload may still be transferring)")
        if client.dry_run:
            # a VALID build already returned above, so in dry-run don't poll
            raise SubmitError(
                "dry-run: build is not processed (VALID) yet; re-run once it is"
            )
        if time.time() > deadline:
            raise SubmitError(
                f"build not processed within {timeout_minutes} minutes — "
                "safe to re-run this script once App Store Connect finishes."
            )
        time.sleep(60)


def ensure_compliance(client: AscClient, build: dict) -> None:
    flag = build["attributes"].get("usesNonExemptEncryption")
    if flag is not None:
        print(f"Export compliance already set (usesNonExemptEncryption={flag})")
        return
    client.mutate(
        "PATCH", f"/v1/builds/{build['id']}",
        {"data": {"type": "builds", "id": build["id"],
                  "attributes": {"usesNonExemptEncryption": False}}},
        "set usesNonExemptEncryption=false on the build",
    )


def version_state(version: dict) -> str:
    attrs = version["attributes"]
    return attrs.get("appVersionState") or attrs.get("appStoreState") or "UNKNOWN"


def ensure_version(client: AscClient, app_id: str, marketing: str) -> tuple[str | None, bool]:
    """Returns (version id, is_first_appstore_version)."""
    all_versions = client.get(
        f"/v1/apps/{app_id}/appStoreVersions",
        params={"filter[platform]": PLATFORM, "limit": "200"},
    )["data"]
    for v in all_versions:
        print(f"Existing version record: {v['attributes']['versionString']} "
              f"(state {version_state(v)})")
    is_first = not any(
        version_state(v) in RELEASED_VERSION_STATES
        for v in all_versions
        if v["attributes"]["versionString"] != marketing
    )
    existing = [v for v in all_versions if v["attributes"]["versionString"] == marketing]

    if existing:
        version = existing[0]
        state = version_state(version)
        if state not in REUSABLE_VERSION_STATES:
            raise SubmitError(
                f"version {marketing} exists in state {state} — already submitted or "
                "released; bump the version or resolve it in App Store Connect."
            )
        print(f"Reusing version record {marketing} (state {state})")
        if version["attributes"].get("releaseType") != "AFTER_APPROVAL":
            client.mutate(
                "PATCH", f"/v1/appStoreVersions/{version['id']}",
                {"data": {"type": "appStoreVersions", "id": version["id"],
                          "attributes": {"releaseType": "AFTER_APPROVAL"}}},
                "set releaseType=AFTER_APPROVAL",
            )
        return version["id"], is_first

    # ASC allows only ONE editable version per platform, so if a draft exists
    # under another version string (e.g. the 1.0 record created with the app
    # listing), rename it — that keeps its description/screenshots — instead
    # of attempting a doomed create.
    editable = [v for v in all_versions if version_state(v) in REUSABLE_VERSION_STATES]
    if editable:
        version = editable[0]
        old = version["attributes"]["versionString"]
        client.mutate(
            "PATCH", f"/v1/appStoreVersions/{version['id']}",
            {"data": {"type": "appStoreVersions", "id": version["id"],
                      "attributes": {"versionString": marketing,
                                     "releaseType": "AFTER_APPROVAL"}}},
            f"rename editable version record {old} -> {marketing} "
            "(keeps its listing metadata)",
        )
        return version["id"], is_first

    created = client.mutate(
        "POST", "/v1/appStoreVersions",
        {"data": {
            "type": "appStoreVersions",
            "attributes": {"platform": PLATFORM, "versionString": marketing,
                           "releaseType": "AFTER_APPROVAL"},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }},
        f"create App Store version record {marketing}",
    )
    return (created["data"]["id"] if created else None), is_first


def set_whats_new(client: AscClient, version_id: str | None,
                  notes: dict[str, str], is_first: bool) -> None:
    if is_first:
        print("First App Store version — Apple forbids What's New text; skipping.")
        return
    if version_id is None:  # dry-run created nothing to localize
        print("  DRY-RUN would set What's New on each locale of the new version")
        return
    locs = client.get(f"/v1/appStoreVersions/{version_id}/appStoreVersionLocalizations")["data"]
    fallback = notes.get("en-GB") or next(iter(notes.values()))
    for loc in locs:
        locale = loc["attributes"]["locale"]
        text = notes.get(locale, fallback)
        client.mutate(
            "PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}",
            {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"],
                      "attributes": {"whatsNew": text}}},
            f"set What's New for {locale}",
        )


def attach_build(client: AscClient, version_id: str | None, build_id: str) -> None:
    if version_id is None:
        print("  DRY-RUN would attach the build to the new version")
        return
    client.mutate(
        "PATCH", f"/v1/appStoreVersions/{version_id}/relationships/build",
        {"data": {"type": "builds", "id": build_id}},
        "attach the build to the version",
    )


def submit_for_review(client: AscClient, app_id: str, version_id: str | None) -> None:
    in_flight = client.get("/v1/reviewSubmissions", params={
        "filter[app]": app_id,
        "filter[platform]": PLATFORM,
        "filter[state]": ",".join(IN_FLIGHT_SUBMISSION_STATES),
    })["data"]
    if in_flight:
        s = in_flight[0]
        raise SubmitError(
            f"a review submission is already in flight (state {s['attributes']['state']}) — "
            f"resolve it in App Store Connect first (submission id {s['id']})."
        )

    drafts = client.get("/v1/reviewSubmissions", params={
        "filter[app]": app_id,
        "filter[platform]": PLATFORM,
        "filter[state]": "READY_FOR_REVIEW",
    })["data"]
    if drafts:
        submission_id = drafts[0]["id"]
        print(f"Reusing draft review submission {submission_id}")
    else:
        created = client.mutate(
            "POST", "/v1/reviewSubmissions",
            {"data": {"type": "reviewSubmissions",
                      "attributes": {"platform": PLATFORM},
                      "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}},
            "create a review submission",
        )
        submission_id = created["data"]["id"] if created else None

    if submission_id is None or version_id is None:
        print("  DRY-RUN would add the version to the submission and submit it")
        return

    # Check for THIS version among the draft's items (not mere non-emptiness):
    # a stale draft could still hold a previous version's item, which must not
    # be silently submitted instead.
    items = client.get(f"/v1/reviewSubmissions/{submission_id}/items")["data"]
    attached = any(
        item.get("relationships", {}).get("appStoreVersion", {})
            .get("data", {}).get("id") == version_id
        for item in items
    )
    stale = [i for i in items
             if i.get("relationships", {}).get("appStoreVersion", {})
                 .get("data", {}).get("id") not in (version_id, None)]
    if stale:
        raise SubmitError(
            f"draft review submission {submission_id} contains item(s) for a "
            "different version — remove them in App Store Connect first."
        )
    if not attached:
        client.mutate(
            "POST", "/v1/reviewSubmissionItems",
            {"data": {"type": "reviewSubmissionItems", "relationships": {
                "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": submission_id}},
                "appStoreVersion": {"data": {"type": "appStoreVersions", "id": version_id}},
            }}},
            "add the version to the review submission",
        )
    client.mutate(
        "PATCH", f"/v1/reviewSubmissions/{submission_id}",
        {"data": {"type": "reviewSubmissions", "id": submission_id,
                  "attributes": {"submitted": True}}},
        "SUBMIT FOR REVIEW",
    )


def main() -> int:
    default_marketing, default_build = read_project_versions()
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", default=default_marketing,
                        help=f"marketing version (default from project.yml: {default_marketing})")
    parser.add_argument("--build-number", default=default_build,
                        help=f"CFBundleVersion (default from project.yml: {default_build})")
    parser.add_argument("--dry-run", action="store_true",
                        help="GETs only; print every mutation instead of performing it")
    parser.add_argument("--until", choices=PHASES, default="submit",
                        help="stop after this phase (default: submit)")
    parser.add_argument("--whats-new-dir", type=Path, default=DEFAULT_WHATS_NEW_DIR)
    parser.add_argument("--timeout-minutes", type=int, default=45,
                        help="how long to wait for Apple to process the build")
    args = parser.parse_args()

    key_id = os.environ.get("ASC_API_KEY_ID")
    issuer_id = os.environ.get("ASC_API_ISSUER_ID")
    if not key_id or not issuer_id:
        raise SubmitError("set ASC_API_KEY_ID and ASC_API_ISSUER_ID")

    notes = load_whats_new(args.whats_new_dir)  # fail fast, before any API call
    client = AscClient(key_id, issuer_id, load_private_key(), args.dry_run)
    stop_after = PHASES.index(args.until)

    app_id = resolve_app(client)

    build = wait_for_build(client, app_id, args.version, args.build_number,
                           args.timeout_minutes)
    if stop_after < PHASES.index("compliance"):
        print("Stopped after: processed")
        return 0

    ensure_compliance(client, build)
    if stop_after < PHASES.index("version"):
        print("Stopped after: compliance")
        return 0

    version_id, is_first = ensure_version(client, app_id, args.version)
    set_whats_new(client, version_id, notes, is_first)
    if stop_after < PHASES.index("attach"):
        print("Stopped after: version")
        return 0

    attach_build(client, version_id, build["id"])
    if stop_after < PHASES.index("submit"):
        print("Stopped after: attach")
        return 0

    submit_for_review(client, app_id, version_id)
    print(f"\nDone. Track it: https://appstoreconnect.apple.com/apps/{app_id}/distribution")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SubmitError as err:
        print(f"ERROR: {err}", file=sys.stderr)
        raise SystemExit(1)
