#!/bin/bash
# Engineering build only. Upload still requires Store scope and distribution setup.
set -euo pipefail
repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$repo_dir"
: "${NEST_SIGN_IDENTITY:?Set NEST_SIGN_IDENTITY to a local signing identity or its hash}"
: "${NEST_DEVELOPMENT_TEAM:?Set NEST_DEVELOPMENT_TEAM to your Apple team identifier}"
action=${NEST_ACTION:-build}
case "$action" in
  build) configuration=${NEST_CONFIGURATION:-Debug} ;;
  archive) configuration=${NEST_CONFIGURATION:-Release} ;;
  *) echo 'NEST_ACTION must be build or archive' >&2; exit 1 ;;
esac
uv run --locked python scripts/prepare_store_resources.py
# Sign before Xcode copies resources. Signing them in a post-build script can
# change sealed resources without making an incremental outer signature rerun.
EXPANDED_CODE_SIGN_IDENTITY="$NEST_SIGN_IDENTITY" \
  /usr/bin/python3 scripts/sign_helper.py .build/StoreResources/NestCastService.app AppStore/Helper.entitlements
xcodegen generate --spec project.yml
arguments=(-quiet -project NestPlayer.xcodeproj -scheme NestPlayerStore
  -configuration "$configuration" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/StoreDerived \
  CODE_SIGN_IDENTITY="$NEST_SIGN_IDENTITY" DEVELOPMENT_TEAM="$NEST_DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Manual)
if [ "$action" = archive ]; then
  archive_path=${NEST_ARCHIVE_PATH:-"$repo_dir/.build/NestPlayer-$(date +%Y%m%d-%H%M%S).xcarchive"}
  arguments+=(-archivePath "$archive_path" archive)
  app_path="$archive_path/Products/Applications/Nest Player.app"
else
  arguments+=(build)
  app_path="$repo_dir/.build/StoreDerived/Build/Products/$configuration/Nest Player.app"
fi
xcodebuild "${arguments[@]}"
codesign --verify --deep --strict "$app_path"
echo "$app_path"
