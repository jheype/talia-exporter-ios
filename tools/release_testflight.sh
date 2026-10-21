#!/usr/bin/env bash
#
# Archive Talia Exporter and upload it to TestFlight, unattended.
#
# Authentication is an App Store Connect API key, so no Apple ID password is
# ever typed and the run does not depend on Xcode being signed in on this
# machine. The key is read from disk and never printed.
#
#   ./tools/release_testflight.sh            # archive + upload at the current build number
#   ./tools/release_testflight.sh --bump     # increment the build number first
#   ./tools/release_testflight.sh --dry-run  # archive + export an IPA, upload nothing
#
# One-time setup is documented in docs/RELEASING.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="${ASC_CONFIG:-$HOME/.appstoreconnect/talia.env}"
KEY_DIR="$HOME/.appstoreconnect/private_keys"
ARCHIVE="${TMPDIR:-/tmp}/TaliaExporter.xcarchive"
EXPORT_DIR="${TMPDIR:-/tmp}/TaliaExporterExport"
TEAM_ID="S3SCDDP668"

BUMP=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --bump) BUMP=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

# --- credentials -----------------------------------------------------------
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && source "$CONFIG"
: "${ASC_KEY_ID:=}"
: "${ASC_ISSUER_ID:=}"

if [ -z "$ASC_KEY_ID" ] || [ -z "$ASC_ISSUER_ID" ]; then
  cat >&2 <<MSG
error: App Store Connect API credentials are not configured.

Create $CONFIG containing:

    ASC_KEY_ID=XXXXXXXXXX
    ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx

and put the matching AuthKey_<KEY_ID>.p8 in $KEY_DIR/.
See docs/RELEASING.md for where those come from.
MSG
  exit 1
fi

KEY_PATH="$KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
if [ ! -f "$KEY_PATH" ]; then
  echo "error: private key not found at $KEY_PATH" >&2
  echo "App Store Connect lets you download a key ONCE — if it is lost, revoke it and issue a new one." >&2
  exit 1
fi

# --- build number ----------------------------------------------------------
current_build() {
  grep -m1 -oE 'CURRENT_PROJECT_VERSION = [0-9]+' TaliaExporter.xcodeproj/project.pbxproj \
    | grep -oE '[0-9]+'
}

if [ "$BUMP" -eq 1 ]; then
  old="$(current_build)"
  new=$((old + 1))
  # Three places carry it. project.yml is the XcodeGen source; the two configs
  # in the committed pbxproj are what Xcode actually reads. Miss one and a
  # regenerate silently reverts the release.
  sed -i '' "s/^    CURRENT_PROJECT_VERSION: ${old}$/    CURRENT_PROJECT_VERSION: ${new}/" project.yml
  sed -i '' "s/CURRENT_PROJECT_VERSION = ${old};/CURRENT_PROJECT_VERSION = ${new};/g" \
    TaliaExporter.xcodeproj/project.pbxproj
  echo "==> build ${old} -> ${new} (commit this before or after the upload)"
fi

BUILD="$(current_build)"
VERSION="$(grep -m1 -oE 'MARKETING_VERSION = [0-9.]+' TaliaExporter.xcodeproj/project.pbxproj | grep -oE '[0-9.]+')"
echo "==> releasing ${VERSION} (${BUILD})"

# --- archive ---------------------------------------------------------------
rm -rf "$ARCHIVE" "$EXPORT_DIR"
echo "==> archiving"
xcodebuild archive \
  -project TaliaExporter.xcodeproj \
  -scheme TaliaExporter \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  > "${TMPDIR:-/tmp}/talia_archive.log" 2>&1 \
  || { echo "archive failed — tail of log:" >&2; tail -30 "${TMPDIR:-/tmp}/talia_archive.log" >&2; exit 1; }

# --- export / upload -------------------------------------------------------
DESTINATION="upload"
[ "$DRY_RUN" -eq 1 ] && DESTINATION="export"

OPTIONS="${TMPDIR:-/tmp}/TaliaExportOptions.plist"
cat > "$OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key><string>app-store-connect</string>
	<key>teamID</key><string>${TEAM_ID}</string>
	<key>signingStyle</key><string>automatic</string>
	<key>uploadSymbols</key><true/>
	<key>destination</key><string>${DESTINATION}</string>
</dict>
</plist>
PLIST

echo "==> ${DESTINATION}ing"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$OPTIONS" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY_PATH" \
  -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID" \
  > "${TMPDIR:-/tmp}/talia_export.log" 2>&1 \
  || { echo "${DESTINATION} failed — tail of log:" >&2; tail -30 "${TMPDIR:-/tmp}/talia_export.log" >&2; exit 1; }

if [ "$DRY_RUN" -eq 1 ]; then
  # Prove the IPA is DISTRIBUTION signed. An "Apple Development" certificate
  # produces a perfectly valid archive that App Store Connect then refuses,
  # which is a slow way to find out.
  work="${TMPDIR:-/tmp}/talia_ipa_check"
  rm -rf "$work"; mkdir -p "$work"
  ( cd "$work" && unzip -qo "$EXPORT_DIR/TaliaExporter.ipa" )
  authority="$(codesign -dv --verbose=2 "$work"/Payload/*.app 2>&1 | grep -m1 '^Authority=')"
  echo "==> ${authority#Authority=}"
  case "$authority" in
    *"Apple Distribution"*) echo "==> IPA at $EXPORT_DIR/TaliaExporter.ipa (nothing uploaded)" ;;
    *) echo "error: not distribution-signed — App Store Connect would reject this" >&2; exit 1 ;;
  esac
else
  echo "==> uploaded ${VERSION} (${BUILD}); Apple emails when processing finishes"
fi
