#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/vplay-ffmpeg-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
vendor_dir="$project_root/Vendor/FFmpeg"
xcrun clang -fobjc-arc -fmodules -fmodules-cache-path="$test_dir/modules" -mmacosx-version-min=12.4 -framework Foundation \
    -I"$project_root/vplay/Utilities" -I"$vendor_dir/include" \
    "$project_root/tests/ffmpeg_integration.m" "$project_root/vplay/Utilities/VPFFmpegLibrary.m" \
    -L"$vendor_dir/lib" -lavformat.63 -lavcodec.63 -lavfilter.12 -lavutil.61 -lswscale.10 -lswresample.7 \
    -Wl,-rpath,"$vendor_dir/lib" -o "$test_dir/integration"
# No external FFmpeg executable is used by these checks.
PATH=/usr/bin:/bin "$test_dir/integration" "$project_root/tests/Fixtures/media.mkv" "$test_dir"
