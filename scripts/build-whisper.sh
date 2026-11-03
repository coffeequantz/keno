#!/bin/zsh
# Builds whisper.cpp as a static, universal (Apple Silicon + Intel) xcframework for Keno.
#
# Why not the official prebuilt one: its Intel slice only uses SSE3, which makes transcription
# about 2.5x slower on Intel Macs. Every Mac that runs macOS 13 or later has AVX2/FMA/F16C, so we enable
# them. Apple Silicon gets Metal (with the shaders embedded) plus Accelerate.
#
# Output: build.noindex/whisper/whisper-<version>-macos.xcframework.zip and its SwiftPM checksum.
# Only maintainers need this (requires cmake); Package.swift downloads the finished zip.
set -euo pipefail
setopt null_glob
cd "$(dirname "$0")/.."

VERSION="${1:-v1.9.5}"
OUT="$PWD/build.noindex/whisper"
SRC="$OUT/src-$VERSION"
rm -rf "$OUT/build-"* "$OUT/whisper.xcframework" "$OUT"/*.zip
mkdir -p "$OUT"

[[ -d "$SRC" ]] || git clone --quiet --depth 1 --branch "$VERSION" https://github.com/ggml-org/whisper.cpp.git "$SRC"

common=(
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3
    -DBUILD_SHARED_LIBS=OFF
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
    -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF
    -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_BLAS=ON -DGGML_ACCELERATE=ON
)
# Keep this machine's paths out of the binary (ggml embeds __FILE__ in its error messages).
prefix_map="-ffile-prefix-map=$SRC=whisper.cpp -ffile-prefix-map=$OUT=build"
common+=(-DCMAKE_C_FLAGS="$prefix_map" -DCMAKE_CXX_FLAGS="$prefix_map" -DCMAKE_OBJC_FLAGS="$prefix_map")

build() { # arch, extra cmake flags...
    local arch=$1; shift
    local dir="$OUT/build-$arch"
    cmake -S "$SRC" -B "$dir" "${common[@]}" -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_SYSTEM_PROCESSOR="$arch" "$@" >/dev/null
    cmake --build "$dir" --config Release -j "$(sysctl -n hw.ncpu)" >/dev/null
    # Merge whisper + all ggml parts into one static library per architecture.
    libtool -static -o "$dir/libwhisper-all.a" $(find "$dir" -name '*.a' ! -name 'libwhisper-all.a') 2>/dev/null
    echo "Built $arch"
}

build arm64  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON
build x86_64 -DGGML_METAL=OFF -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_FMA=ON -DGGML_F16C=ON -DGGML_BMI2=ON

lipo -create "$OUT/build-arm64/libwhisper-all.a" "$OUT/build-x86_64/libwhisper-all.a" -output "$OUT/libwhisper.a"

HDR="$OUT/headers"
rm -rf "$HDR" && mkdir -p "$HDR"
cp "$SRC/include/whisper.h" "$SRC"/ggml/include/ggml*.h "$SRC/ggml/include/gguf.h" "$HDR/"
cat > "$HDR/module.modulemap" <<'EOF'
module whisper {
    header "whisper.h"
    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"
    export *
}
EOF

xcodebuild -create-xcframework -library "$OUT/libwhisper.a" -headers "$HDR" -output "$OUT/whisper.xcframework" >/dev/null
cp "$SRC/LICENSE" "$OUT/whisper.xcframework/LICENSE"

# Refuse to publish anything that still mentions this machine's home folder or user name.
if grep -rqaF -e "$HOME" -e "/Users/$USER" "$OUT/whisper.xcframework"; then
    echo "error: build paths leaked into the library:" >&2
    strings -a "$OUT/libwhisper.a" | grep -F -e "$HOME" -e "/Users/$USER" | sort -u | head >&2
    exit 1
fi

ZIP="$OUT/whisper-$VERSION-macos.xcframework.zip"
xattr -cr "$OUT/whisper.xcframework"
(cd "$OUT" && ditto -c -k --norsrc --noextattr --noqtn --keepParent whisper.xcframework "$ZIP")
echo "Archive:  $ZIP ($(du -h "$ZIP" | cut -f1))"
echo "Checksum: $(swift package compute-checksum "$ZIP")"
