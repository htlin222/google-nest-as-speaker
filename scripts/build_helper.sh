#!/bin/bash
set -euo pipefail

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
destination=${1:?Usage: build_helper.sh /absolute/path/to/new/nest-service}
mode=${2:-directory}
if [ "$mode" != directory ] && [ "$mode" != app ]; then
  echo 'Helper mode must be directory or app' >&2
  exit 1
fi
if [ -e "$destination" ]; then
  echo "Refusing to replace an existing helper: $destination" >&2
  exit 1
fi
mkdir -p "$repo_dir/.build"
helper_build=$(mktemp -d "$repo_dir/.build/helper-package.XXXXXX")
freeze_options=(--onedir --console --contents-directory .
  --recursive-copy-metadata pychromecast \
  --recursive-copy-metadata yt-dlp \
  --collect-all yt_dlp --collect-all yt_dlp_ejs \
  --copy-metadata setuptools --copy-metadata pyinstaller \
  --name nest-service --specpath "$helper_build")
entry="$repo_dir/.agents/skills/google-nest-speaker/scripts/nest_speaker.py"
if [ "$mode" = app ]; then
  uv run --locked --project "$repo_dir" --group dev pyi-makespec "${freeze_options[@]}" "$entry"
  # Keep the console bootloader for piped JSON IPC, but use PyInstaller's BUNDLE
  # layout so binaries and data occupy the correct macOS bundle directories.
  cat >> "$helper_build/nest-service.spec" <<'SPEC'
app = BUNDLE(coll, name='NestCastService.app',
             bundle_identifier='dev.htlin.nest-player.cast-service',
             info_plist={'LSUIElement': True})
SPEC
  uv run --locked --project "$repo_dir" --group dev pyinstaller \
    --noconfirm --clean --distpath "$helper_build/dist" --workpath "$helper_build/work" \
    "$helper_build/nest-service.spec"
  product="$helper_build/dist/NestCastService.app"
else
  uv run --locked --project "$repo_dir" --group dev pyinstaller \
    --noconfirm --clean --distpath "$helper_build/dist" --workpath "$helper_build/work" \
    "${freeze_options[@]}" "$entry"
  product="$helper_build/dist/nest-service"
fi
mkdir -p "$(dirname -- "$destination")"
cp -R "$product" "$destination"
echo "$destination"
