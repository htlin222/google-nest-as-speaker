#!/bin/bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir="$repo_dir/dist/Nest Player.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$repo_dir/scripts/Info.plist")
architecture=$(uname -m)
archive_name="Nest-Player-${version}-macOS-${architecture}.zip"
archive_path="$repo_dir/dist/$archive_name"

if [ ! -d "$app_dir" ]; then
  echo 'Build the app first: ./scripts/build_app.sh' >&2
  exit 1
fi
if [ -e "$archive_path" ] || [ -e "$archive_path.sha256" ]; then
  echo "Release archive already exists: $archive_path" >&2
  exit 1
fi

codesign --verify --deep --strict "$app_dir"
ditto -c -k --sequesterRsrc --keepParent "$app_dir" "$archive_path"
(
  cd "$repo_dir/dist"
  shasum -a 256 "$archive_name" > "$archive_name.sha256"
)
echo "$archive_path"
echo "$archive_path.sha256"
