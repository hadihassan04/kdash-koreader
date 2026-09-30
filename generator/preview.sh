#!/bin/sh
# Screenshots of every page, drawn by KOReader itself with the kdash plugin, so
# they are exactly what the Kindle shows. Reads out/data.json (and out/photo.png),
# writes out/preview/page-N.png and out/preview/pages.json.
#   KDASH_PLUGIN   plugin repo to take kdash.koplugin and the fonts from
#   KO_VERSION     KOReader release (default: latest)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=${RUNNER_TEMP:-/tmp}/kdash-preview
plugin=${KDASH_PLUGIN:-hadihassan04/kdash-koreader}
rm -rf "$work" && mkdir -p "$work/home/plugins" "$work/home/patches" "$work/home/cache/kdash" "$here/out/preview"

if [ ! -f "$work/../koreader-app/lib/koreader/reader.lua" ]; then
    mkdir -p "$work/../koreader-app"
    gh release download ${KO_VERSION:-} -R koreader/koreader -p 'koreader-linux-x86_64-*.tar.xz' -O - \
        | tar -xJ -C "$work/../koreader-app"
fi
app=$(cd "$work/../koreader-app/lib/koreader" && pwd)

git clone -q --depth 1 "https://github.com/$plugin.git" "$work/plugin"
cp -R "$work/plugin/kdash.koplugin" "$work/home/plugins/"
cp -R "$work/plugin/fonts/literata" "$app/fonts/" 2>/dev/null || true
cp "$here/preview/shoot.lua" "$work/home/patches/2-kdash-shoot.lua"
cp "$here/out/data.json" "$work/home/cache/kdash/data.json"
[ -f "$here/out/photo.png" ] && cp "$here/out/photo.png" "$work/home/cache/kdash/photo.png"
# Skip first-run notices so nothing covers the pages
printf 'return {\n    ["color_rendering"] = false,\n    ["quickstart_shown_version"] = 99999999999999,\n}\n' > "$work/home/settings.reader.lua"

cd "$app"
KO_HOME="$work/home" KDASH_SHOTS="$here/out/preview" SDL_VIDEODRIVER=dummy \
EMULATE_READER_W=${PREVIEW_W:-758} EMULATE_READER_H=${PREVIEW_H:-1024} EMULATE_READER_DPI=212 \
    timeout 150 ./reader.lua >"$work/log.txt" 2>&1 || true
if [ ! -f "$here/out/preview/pages.json" ]; then
    echo "No previews; KOReader log:"; tail -40 "$work/log.txt"; exit 1
fi
echo "previews: $(ls "$here/out/preview" | wc -l) files"
