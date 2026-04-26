#!/bin/bash
# Rebuild the unmodified, bundled FFmpeg source as universal macOS shared libraries.
set -euo pipefail
legal_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:?Usage: build-ffmpeg.sh OUTPUT_DIRECTORY}"
mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
build_root="$(mktemp -d "${TMPDIR:-/tmp}/vplay-ffmpeg-build.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
archive="$legal_dir/ffmpeg-9.0.2.tar.xz"
expected_sha=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
actual_sha="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
if [ "$actual_sha" != "$expected_sha" ]; then
    echo 'FFmpeg source archive checksum does not match.' >&2
    exit 1
fi
tar -xf "$archive" -C "$build_root"
source_dir="$build_root/ffmpeg-9.0.2"
for architecture in arm64 x86_64; do
    build_dir="$build_root/build-$architecture"
    prefix="$build_root/install-$architecture"
    mkdir -p "$build_dir"
    extra=()
    if [ "$architecture" = x86_64 ]; then
        extra=(--enable-cross-compile --target-os=darwin --disable-x86asm)
    fi
    (
        cd "$build_dir"
        "$source_dir/configure" --prefix="$prefix" \
            --enable-shared --disable-static --disable-programs --disable-doc --disable-debug \
            --disable-autodetect --disable-avdevice \
            --enable-videotoolbox --enable-audiotoolbox --enable-securetransport --enable-zlib --enable-bzlib \
            --install-name-dir=@rpath --arch="$architecture" --cc="clang -arch $architecture" \
            --extra-cflags=-mmacosx-version-min=12.4 --extra-ldflags=-mmacosx-version-min=12.4 "${extra[@]}"
        make -j"${FFMPEG_BUILD_JOBS:-8}"
        make install
    )
done
mkdir -p "$output_dir/include" "$output_dir/lib"
cp -R "$build_root/install-arm64/include/" "$output_dir/include/"
for library in libavutil.61 libswresample.7 libavcodec.63 libavformat.63 libswscale.10 libavfilter.12; do
    lipo -create "$build_root/install-arm64/lib/$library.dylib" "$build_root/install-x86_64/lib/$library.dylib" \
        -output "$output_dir/lib/$library.dylib"
done
