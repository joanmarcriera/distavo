#!/usr/bin/env python3
"""One-time App Store listing setup for Distavo, driven by the ASC API.

Fills everything Apple demands before a first review submission that the
public API supports: subtitle + privacy-policy URL, primary category, the
age-rating questionnaire, copyright, description/keywords/support URL,
free pricing, the App Review contact, and desktop screenshots.

NOT automatable (App Store Connect UI only): publishing the App Privacy
"data usages" answers.

Listing text lives in apple/metadata/listing.json (public-safe).
Review contact comes from env so personal data stays out of the repo:
  ASC_CONTACT_FIRST_NAME, ASC_CONTACT_LAST_NAME,
  ASC_CONTACT_PHONE, ASC_CONTACT_EMAIL
Screenshots: PNGs in apple/metadata/screenshots/ (Mac sizes: 1280x800,
1440x900, 2560x1600 or 2880x1800). Skipped with a warning when absent.

Auth env: same as submit-appstore-review.py (ASC_API_KEY_ID / ASC_API_ISSUER_ID
/ ASC_API_KEY_P8_PATH|_BASE64), with fallback to Marc's ~/.tokens names
(APPLE_API_KEY_ID / APPLE_API_ISSUER / APPLE_API_KEY as a key-file path).

Idempotent: only missing/differing fields are written; re-run freely.
`--dry-run` prints every planned mutation without performing it.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import struct
import sys
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_LISTING = ROOT / "apple" / "metadata" / "listing.json"
DEFAULT_SCREENSHOTS = ROOT / "apple" / "metadata" / "screenshots"

# Load the submit script as a module to reuse its AscClient / constants.
_spec = importlib.util.spec_from_file_location(
    "submit_appstore_review", ROOT / "scripts" / "submit-appstore-review.py")
assert _spec is not None and _spec.loader is not None
_submit = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_submit)

AscClient = _submit.AscClient
SubmitError = _submit.SubmitError
BUNDLE_ID = _submit.BUNDLE_ID
PLATFORM = _submit.PLATFORM
REUSABLE_VERSION_STATES = _submit.REUSABLE_VERSION_STATES
version_state = _submit.version_state

MAC_SCREENSHOT_SIZES = {(1280, 800), (1440, 900), (2560, 1600), (2880, 1800)}

# Age-rating questionnaire: a meeting-notes utility has none of it.
# Enum attributes take NONE; boolean attributes take False. If Apple's schema
# shifts (it grew several attributes in 2025), the PATCH 409 names the
# offending attribute and its expected values — adjust here and re-run.
AGE_RATING_ENUMS_NONE = [
    "alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated",
    "gunsOrOtherWeapons", "horrorOrFearThemes", "matureOrSuggestiveThemes",
    "medicalOrTreatmentInformation", "profanityOrCrudeHumor",
    "sexualContentGraphicAndNudity", "sexualContentOrNudity",
    "violenceCartoonOrFantasy", "violenceRealistic",
    "violenceRealisticProlongedGraphicOrSadistic",
]
AGE_RATING_BOOLS_FALSE = [
    "gambling", "lootBox", "unrestrictedWebAccess", "advertising",
    "healthOrWellnessTopics", "messagingAndChat", "userGeneratedContent",
    "parentalControls", "ageAssurance",
]


def load_auth() -> tuple[str, str, str]:
    key_id = os.environ.get("ASC_API_KEY_ID") or os.environ.get("APPLE_API_KEY_ID")
    issuer = os.environ.get("ASC_API_ISSUER_ID") or os.environ.get("APPLE_API_ISSUER")
    if not key_id or not issuer:
        raise SubmitError("set ASC_API_KEY_ID/ASC_API_ISSUER_ID "
                          "(or APPLE_API_KEY_ID/APPLE_API_ISSUER)")
    apple_key_path = os.environ.get("APPLE_API_KEY")
    if apple_key_path and Path(apple_key_path).expanduser().is_file():
        return key_id, issuer, Path(apple_key_path).expanduser().read_text("utf-8")
    return key_id, issuer, _submit.load_private_key()


def patch_missing(client: AscClient, kind: str, path: str, resource_id: str,
                  current: dict, wanted: dict, label: str) -> None:
    """PATCH only the attributes that are absent or different."""
    delta = {k: v for k, v in wanted.items() if current.get(k) != v}
    if not delta:
        print(f"{label}: already complete")
        return
    client.mutate(
        "PATCH", f"{path}/{resource_id}",
        {"data": {"type": kind, "id": resource_id, "attributes": delta}},
        f"{label}: set {', '.join(sorted(delta))}",
    )


def setup_app_info(client: AscClient, app_id: str, listing: dict) -> None:
    # Apple's "third-party content" means licensed media/characters, not
    # open-source code libraries — Distavo bundles only the latter.
    app = client.get(f"/v1/apps/{app_id}")["data"]
    patch_missing(client, "apps", "/v1/apps", app_id, app["attributes"],
                  {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"},
                  "content rights declaration")

    info = client.get(f"/v1/apps/{app_id}/appInfos")["data"][0]
    info_id = info["id"]

    cat = client.get(f"/v1/appInfos/{info_id}/primaryCategory")
    current_cat = (cat.get("data") or {}).get("id")
    if current_cat != listing["primaryCategory"]:
        client.mutate(
            "PATCH", f"/v1/appInfos/{info_id}",
            {"data": {"type": "appInfos", "id": info_id, "relationships": {
                "primaryCategory": {"data": {
                    "type": "appCategories", "id": listing["primaryCategory"]}}}}},
            f"set primary category {listing['primaryCategory']}",
        )
    else:
        print(f"primary category: already {current_cat}")

    for loc in client.get(f"/v1/appInfos/{info_id}/appInfoLocalizations")["data"]:
        patch_missing(client, "appInfoLocalizations", "/v1/appInfoLocalizations",
                      loc["id"], loc["attributes"],
                      {"subtitle": listing["subtitle"],
                       "privacyPolicyUrl": listing["privacyPolicyUrl"]},
                      f"app info ({loc['attributes']['locale']})")

    age = client.get(f"/v1/appInfos/{info_id}/ageRatingDeclaration")["data"]
    wanted = {**{k: "NONE" for k in AGE_RATING_ENUMS_NONE},
              **{k: False for k in AGE_RATING_BOOLS_FALSE}}
    patch_missing(client, "ageRatingDeclarations", "/v1/ageRatingDeclarations",
                  age["id"], age["attributes"], wanted, "age rating")


def find_editable_version(client: AscClient, app_id: str) -> dict:
    versions = client.get(f"/v1/apps/{app_id}/appStoreVersions",
                          params={"filter[platform]": PLATFORM, "limit": "200"})["data"]
    editable = [v for v in versions if version_state(v) in REUSABLE_VERSION_STATES]
    if not editable:
        raise SubmitError("no editable App Store version found — run "
                          "submit-appstore-review.py --until version first")
    v = editable[0]
    print(f"Editable version: {v['attributes']['versionString']} ({version_state(v)})")
    return v


def setup_version(client: AscClient, version: dict, listing: dict) -> str:
    patch_missing(client, "appStoreVersions", "/v1/appStoreVersions",
                  version["id"], version["attributes"],
                  {"copyright": listing["copyright"]}, "version copyright")
    locs = client.get(
        f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations")["data"]
    for loc in locs:
        patch_missing(client, "appStoreVersionLocalizations",
                      "/v1/appStoreVersionLocalizations", loc["id"], loc["attributes"],
                      {"description": listing["description"],
                       "keywords": listing["keywords"],
                       "promotionalText": listing["promotionalText"],
                       "supportUrl": listing["supportUrl"],
                       "marketingUrl": listing["marketingUrl"]},
                      f"version listing ({loc['attributes']['locale']})")
    return locs[0]["id"] if locs else ""


def setup_free_price(client: AscClient, app_id: str) -> None:
    resp = client.session.get(
        f"{_submit.API_BASE}/v1/appPriceSchedules/{app_id}/manualPrices",
        headers={"Authorization": f"Bearer {client._bearer()}"}, timeout=60)
    if resp.status_code == 200 and resp.json().get("data"):
        print("price schedule: already set")
        return
    points = client.get(f"/v1/apps/{app_id}/appPricePoints",
                        params={"filter[territory]": "USA", "limit": "1"})["data"]
    if not points:
        raise SubmitError("no price points returned for territory USA")
    free_point = points[0]  # price points are sorted ascending; first is 0.00
    price = free_point.get("attributes", {}).get("customerPrice")
    if price not in ("0.0", "0.00", "0"):
        raise SubmitError(f"expected the first USA price point to be free, got {price}")
    client.mutate(
        "POST", "/v1/appPriceSchedules",
        {"data": {"type": "appPriceSchedules", "relationships": {
            "app": {"data": {"type": "apps", "id": app_id}},
            "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
            "manualPrices": {"data": [{"type": "appPrices", "id": "${price-free}"}]}},
          },
         "included": [{"type": "appPrices", "id": "${price-free}",
                       "attributes": {"startDate": None},
                       "relationships": {"appPricePoint": {"data": {
                           "type": "appPricePoints", "id": free_point["id"]}}}}]},
        "set price schedule to FREE (base territory USA)",
    )


def setup_review_detail(client: AscClient, version_id: str) -> None:
    contact = {k: os.environ.get(f"ASC_CONTACT_{k.upper()}") for k in
               ("first_name", "last_name", "phone", "email")}
    if not all(contact.values()):
        print("WARNING: review contact skipped — set ASC_CONTACT_FIRST_NAME, "
              "ASC_CONTACT_LAST_NAME, ASC_CONTACT_PHONE, ASC_CONTACT_EMAIL "
              "(e.g. in ~/.tokens) and re-run, or fill it in ASC by hand.")
        return
    # demoAccountRequired=False matters: ASC defaults the "Sign-in required"
    # checkbox on, which then demands demo credentials at submission time.
    attrs = {"contactFirstName": contact["first_name"],
             "contactLastName": contact["last_name"],
             "contactPhone": contact["phone"],
             "contactEmail": contact["email"],
             "demoAccountRequired": False}
    # Reviewer-facing notes (bring-your-own-server explanation — added after the
    # 1.8.0 Guideline 2.1(a) rejection). Optional file so the script still runs
    # on repos without one.
    notes_file = ROOT / "apple" / "metadata" / "review-notes.txt"
    if notes_file.exists():
        attrs["notes"] = notes_file.read_text().strip()
    existing = client.get(f"/v1/appStoreVersions/{version_id}/appStoreReviewDetail")
    if existing.get("data"):
        patch_missing(client, "appStoreReviewDetails", "/v1/appStoreReviewDetails",
                      existing["data"]["id"], existing["data"]["attributes"],
                      attrs, "review contact")
        return
    client.mutate(
        "POST", "/v1/appStoreReviewDetails",
        {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
                  "relationships": {"appStoreVersion": {"data": {
                      "type": "appStoreVersions", "id": version_id}}}}},
        "create review contact",
    )


def png_dimensions(path: Path) -> tuple[int, int]:
    with path.open("rb") as f:
        header = f.read(24)
    if header[:8] != b"\x89PNG\r\n\x1a\n":
        raise SubmitError(f"{path} is not a PNG")
    width, height = struct.unpack(">II", header[16:24])
    return width, height


def upload_screenshots(client: AscClient, ver_loc_id: str, folder: Path) -> None:
    pngs = sorted(folder.glob("*.png")) if folder.is_dir() else []
    if not pngs:
        print(f"WARNING: no screenshots in {folder} — Apple requires at least one "
              "desktop screenshot before submission (1280x800, 1440x900, "
              "2560x1600 or 2880x1800 PNG).")
        return
    for png in pngs:
        dims = png_dimensions(png)
        if dims not in MAC_SCREENSHOT_SIZES:
            raise SubmitError(f"{png.name} is {dims[0]}x{dims[1]} — not an accepted "
                              f"Mac screenshot size {sorted(MAC_SCREENSHOT_SIZES)}")

    sets = client.get(
        f"/v1/appStoreVersionLocalizations/{ver_loc_id}/appScreenshotSets")["data"]
    desktop = next((s for s in sets
                    if s["attributes"]["screenshotDisplayType"] == "APP_DESKTOP"), None)
    if desktop is None:
        created = client.mutate(
            "POST", "/v1/appScreenshotSets",
            {"data": {"type": "appScreenshotSets",
                      "attributes": {"screenshotDisplayType": "APP_DESKTOP"},
                      "relationships": {"appStoreVersionLocalization": {"data": {
                          "type": "appStoreVersionLocalizations", "id": ver_loc_id}}}}},
            "create APP_DESKTOP screenshot set",
        )
        if created is None:  # dry-run
            print(f"  DRY-RUN would upload {len(pngs)} screenshot(s)")
            return
        desktop = created["data"]

    have = {s["attributes"].get("fileName")
            for s in client.get(
                f"/v1/appScreenshotSets/{desktop['id']}/appScreenshots")["data"]}
    for png in pngs:
        if png.name in have:
            print(f"screenshot {png.name}: already uploaded")
            continue
        data = png.read_bytes()
        if client.dry_run:
            print(f"  DRY-RUN would upload screenshot {png.name} ({len(data)} bytes)")
            continue
        reserved = client.mutate(
            "POST", "/v1/appScreenshots",
            {"data": {"type": "appScreenshots",
                      "attributes": {"fileName": png.name, "fileSize": len(data)},
                      "relationships": {"appScreenshotSet": {"data": {
                          "type": "appScreenshotSets", "id": desktop["id"]}}}}},
            f"reserve upload for {png.name}",
        )
        shot = reserved["data"]
        for op in shot["attributes"]["uploadOperations"]:
            chunk = data[op["offset"]:op["offset"] + op["length"]]
            headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
            resp = requests.request(op["method"], op["url"], data=chunk,
                                    headers=headers, timeout=120)
            resp.raise_for_status()
        client.mutate(
            "PATCH", f"/v1/appScreenshots/{shot['id']}",
            {"data": {"type": "appScreenshots", "id": shot["id"],
                      "attributes": {"uploaded": True,
                                     "sourceFileChecksum": hashlib.md5(data).hexdigest()}}},
            f"commit screenshot {png.name}",
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--listing", type=Path, default=DEFAULT_LISTING)
    parser.add_argument("--screenshots-dir", type=Path, default=DEFAULT_SCREENSHOTS)
    args = parser.parse_args()

    listing = json.loads(args.listing.read_text(encoding="utf-8"))
    key_id, issuer, private_key = load_auth()
    client = AscClient(key_id, issuer, private_key, args.dry_run)

    app_id = _submit.resolve_app(client)
    setup_app_info(client, app_id, listing)
    version = find_editable_version(client, app_id)
    ver_loc_id = setup_version(client, version, listing)
    setup_free_price(client, app_id)
    setup_review_detail(client, version["id"])
    if ver_loc_id:
        upload_screenshots(client, ver_loc_id, args.screenshots_dir)

    print("\nListing setup pass complete. Still manual in App Store Connect:")
    print("  - App Privacy (Data Not Collected) — no public API")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except SubmitError as err:
        print(f"ERROR: {err}", file=sys.stderr)
        raise SystemExit(1)
