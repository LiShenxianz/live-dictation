#!/bin/bash
# Build the self-contained Apple Silicon application and a drag-to-install disk image.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
cache="${XASR_BUILD_CACHE:-$root/.cache}"
mkdir -p "$cache" build
stage="$(mktemp -d "$root/build/stage.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
image="$stage/image"
app="$image/神仙语音转录.app"
resources="$app/Contents/Resources"
helpers="$app/Contents/Helpers"
mkdir -p "$resources"/{model,node_modules,Notices} "$helpers" "$app/Contents/MacOS"
fetch() {
    local url="$1" digest="$2" archive="$cache/${1##*/}"
    if [[ ! -f "$archive" ]] || [[ "$(shasum -a 256 "$archive" | cut -d' ' -f1)" != "$digest" ]]; then
        local temp
        temp="$(mktemp "$cache/.download.XXXXXX")"
        curl --fail --location --retry 3 --output "$temp" "$url"
        if [[ "$(shasum -a 256 "$temp" | cut -d' ' -f1)" != "$digest" ]]; then
            rm -f "$temp"
            echo "Checksum mismatch: ${url##*/}" >&2
            exit 1
        fi
        mv -f "$temp" "$archive"
    fi
}
node=node-v22.23.2-darwin-arm64
model=sherpa-onnx-x-asr-480ms-streaming-zipformer-transducer-zh-en-punct-int8-2026-06-05
fetch "https://nodejs.org/dist/v22.23.2/$node.tar.gz" 61130f394c1630d211dd50aecc4353d379480f36d3ac913cd85dbba1aed585c6
fetch "https://registry.npmjs.org/sherpa-onnx-node/-/sherpa-onnx-node-1.13.3.tgz" b1d64031355f8fd8d7af95da817c2edb2f597e599ff0981d32ce79b33331f1b2
fetch "https://registry.npmjs.org/sherpa-onnx-darwin-arm64/-/sherpa-onnx-darwin-arm64-1.13.3.tgz" 676b56c823273f42a9cb8b05a17a270605c7205227a5a62068eb80ed54eeb2ca
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/$model.tar.bz2" fa5f63d618e5a01526e275a358bb7772e403f84808a4769fba52cffd8160bf74
tar -xzf "$cache/$node.tar.gz" -C "$helpers" --strip-components 2 "$node/bin/node"
tar -xOzf "$cache/$node.tar.gz" "$node/LICENSE" > "$resources/Notices/Node-LICENSE"
for package in sherpa-onnx-node sherpa-onnx-darwin-arm64; do
    mkdir "$resources/node_modules/$package"
    tar -xzf "$cache/$package-1.13.3.tgz" -C "$resources/node_modules/$package" --strip-components 1
done
tar -xjf "$cache/$model.tar.bz2" -C "$resources/model" --strip-components 1 \
    "$model/encoder.int8.onnx" "$model/decoder.onnx" "$model/joiner.int8.onnx" "$model/tokens.txt" "$model/README.md"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/transcribe.cjs "$resources/"
cp -R Notices/. "$resources/Notices/"
xcrun swiftc -O -target arm64-apple-macos26.0 Sources/*.swift -o "$app/Contents/MacOS/Dictation"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
ln -s /Applications "$image/Applications"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
filename="Live-Dictation-$version-macOS-arm64.dmg"
hdiutil create -quiet -volname "神仙语音转录" -srcfolder "$image" -format UDZO "$stage/$filename"
mv -f "$stage/$filename" "build/$filename"
(cd build && shasum -a 256 "$filename" > "$filename.sha256")
echo "$root/build/$filename"
