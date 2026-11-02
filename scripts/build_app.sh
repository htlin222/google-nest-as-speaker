#!/bin/bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
app_dir="$repo_dir/dist/Nest Player.app"
bin_dir=$(swift build --package-path "$repo_dir" -c release --show-bin-path)
mkdir -p "$repo_dir/.build" "$repo_dir/dist"
helper_build=$(mktemp -d "$repo_dir/.build/app-package.XXXXXX")
staged_app="$helper_build/package/Nest Player.app"
contents_dir="$staged_app/Contents"
iconset_dir="$helper_build/NestPlayer.iconset"

swift build --package-path "$repo_dir" -c release
uv run --locked --project "$repo_dir" --group dev pyinstaller \
  --noconfirm \
  --clean \
  --onedir \
  --contents-directory . \
  --recursive-copy-metadata pychromecast \
  --recursive-copy-metadata yt-dlp \
  --collect-all yt_dlp \
  --collect-all yt_dlp_ejs \
  --copy-metadata setuptools \
  --copy-metadata pyinstaller \
  --name nest-service \
  --distpath "$helper_build/dist" \
  --workpath "$helper_build/work" \
  --specpath "$helper_build" \
  "$repo_dir/.agents/skills/google-nest-speaker/scripts/nest_speaker.py"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp -f "$bin_dir/NestPlayer" "$contents_dir/MacOS/NestPlayer"
cp -f "$repo_dir/scripts/Info.plist" "$contents_dir/Info.plist"
cp -R "$helper_build/dist/nest-service" "$contents_dir/Resources/nest-service"
cp "$repo_dir/LICENSE" "$contents_dir/Resources/LICENSE"
uv run --locked --project "$repo_dir" python -c \
  'import shutil, sys, sysconfig; from pathlib import Path; shutil.copy2(Path(sysconfig.get_path("stdlib")) / "LICENSE.txt", sys.argv[1])' \
  "$contents_dir/Resources/PYTHON-LICENSE.txt"

mkdir -p "$iconset_dir"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$repo_dir/assets/nest-player.png" \
    --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$repo_dir/assets/nest-player.png" \
    --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil --convert icns "$iconset_dir" --output "$contents_dir/Resources/NestPlayer.icns"
chmod +x "$contents_dir/MacOS/NestPlayer"
codesign --force --deep --sign - "$staged_app"
codesign --verify --deep --strict "$staged_app"

# Keep the previous generated bundle recoverable; no extra cleanup tool is needed.
if [ -e "$app_dir" ]; then
  mv "$app_dir" "$helper_build/previous-app"
fi
mv "$staged_app" "$app_dir"

echo "$app_dir"
