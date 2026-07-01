#!/usr/bin/env bash
#
# Interactively set the *sensitive* GitHub Actions release secrets WITHOUT ever
# echoing them or leaving them in shell history. Each value is read with hidden
# input (or base64'd from a file) and piped straight into `gh secret set`.
#
# Non-sensitive identifiers (APPLE_TEAM_ID, APPLE_ID) are set separately and are
# NOT handled here.
#
# Usage:
#   ./set-release-secrets.sh direct     # Developer ID cert + passwords (release.yml)
#   ./set-release-secrets.sh appstore   # Apple Distribution cert + ASC API key (release-appstore.yml)
#
# Prereqs:
#   - gh authenticated for this repo (`gh auth status`)
#   - direct:   the "Developer ID Application" identity in your login keychain
#   - appstore: an "Apple Distribution" cert + an App Store Connect API key (.p8)
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# Read a secret value with hidden input and pipe it (no trailing newline) into a
# repo secret. Nothing is printed; the value never appears in argv or history.
set_secret_from_prompt() {
  local name="$1" prompt="$2" value=""
  printf '%s' "$prompt" >&2
  read -rs value; printf '\n' >&2
  [[ -n "$value" ]] || die "$name: empty value, aborting"
  printf '%s' "$value" | gh secret set "$name"
  printf '  ✓ set %s\n' "$name" >&2
}

# Export a Keychain identity to a temp .p12, base64 it into a secret, then shred.
set_cert_secret() {
  local identity="$1" b64_secret="$2" pw_secret="$3"
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  local pw=""
  printf 'Choose an export password for the %s .p12 (you pick it now): ' "$identity" >&2
  read -rs pw; printf '\n' >&2
  [[ -n "$pw" ]] || die "export password cannot be empty"

  printf 'Exporting "%s" from login keychain (Keychain may prompt to allow)...\n' "$identity" >&2
  security export -t identities -f pkcs12 -P "$pw" -o "$tmp/cert.p12" \
    || die "security export failed — check the identity name / keychain access"
  # security export with -t identities exports every identity; verify it's usable.
  base64 -i "$tmp/cert.p12" | gh secret set "$b64_secret"
  printf '%s' "$pw"          | gh secret set "$pw_secret"
  printf '  ✓ set %s and %s\n' "$b64_secret" "$pw_secret" >&2
}

case "${1:-}" in
  direct)
    echo "== Direct DMG secrets (release.yml) ==" >&2
    set_cert_secret "Developer ID Application" \
      DEVELOPER_ID_CERT_P12_BASE64 DEVELOPER_ID_CERT_PASSWORD
    set_secret_from_prompt APPLE_NOTARY_PASSWORD \
      "Paste the app-specific password (account.apple.com → App-Specific Passwords): "
    echo "Done. Direct pipeline secrets are set." >&2
    ;;
  appstore)
    echo "== App Store secrets (release-appstore.yml) ==" >&2
    set_cert_secret "Apple Distribution" \
      APPLE_DISTRIBUTION_CERT_P12_BASE64 APPLE_DISTRIBUTION_CERT_PASSWORD
    set_secret_from_prompt ASC_API_KEY_ID    "App Store Connect API Key ID: "
    set_secret_from_prompt ASC_API_ISSUER_ID "App Store Connect Issuer ID: "
    printf 'Path to the downloaded AuthKey_XXXX.p8: ' >&2
    read -r p8; [[ -f "$p8" ]] || die "no such file: $p8"
    base64 -i "$p8" | gh secret set ASC_API_KEY_P8_BASE64
    printf '  ✓ set ASC_API_KEY_P8_BASE64\n' >&2
    echo "Done. App Store pipeline secrets are set." >&2
    ;;
  *)
    die "usage: $0 {direct|appstore}"
    ;;
esac
