#!/bin/sh
# Build the original PCM worker using upstream release assets pinned by SHA-256.
set -eu
cd "$(dirname "$0")"
export LC_ALL=C
umask 022

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

[ "$(/usr/bin/uname -s)" = Darwin ] && [ "$(/usr/bin/uname -m)" = arm64 ] ||
  fail 'Build the wake worker from an Apple Silicon Mac in an arm64 Terminal.'
[ ! -L build ] || fail 'The wake worker build directory is a symbolic link.'
mkdir -p build
mkdir build/.package-lock || fail 'Another keyword build has the package lock.'
scratch=
cleanup() {
  if [ -n "$scratch" ]; then rm -rf -- "$scratch"; fi
  rmdir build/.package-lock
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

if [ -e build/package ] || [ -L build/package ]; then
  fail 'Move the previous macos/keyword/build/package out of the way before rebuilding.'
fi
scratch="$(/usr/bin/mktemp -d build/.keyword.XXXXXXXX)"
package="$scratch/package"
mkdir -p "$package/lib" "$package/model" "$package/notices"

verify() {
  actual="$(/usr/bin/shasum -a 256 < "$1")"
  [ "${actual%% *}" = "$2" ] || fail "SHA-256 mismatch for $1"
}

fetch() {
  /usr/bin/curl --disable --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --connect-timeout 15 --max-time 180 \
    --retry 2 --output "$2" "$1"
  verify "$2" "$3"
}

sherpa='sherpa-onnx-v2.0.1-osx-arm64-shared-no-tts-lib'
model='sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01'
onnx='onnxruntime-osx-arm64-1.28.2'
sherpa_repo='https://github.com/k2-fsa/sherpa-onnx/releases/download'
sherpa_source='https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v2.0.1'
sherpa_tar="$scratch/$sherpa.tar.bz2"
model_tar="$scratch/$model.tar.bz2"
onnx_zip="$scratch/$onnx.zip"
notices="$package/notices"

printf '%s\n' 'Fetching pinned wake runtime and English keyword model.'
fetch "$sherpa_repo/v2.0.1/$sherpa.tar.bz2" "$sherpa_tar" \
  ac5594ad237db56ec4a6c4b3fc48700441b33a07bb71c235f35530a52a93f2e3
fetch "$sherpa_repo/kws-models/$model.tar.bz2" "$model_tar" \
  f170013b4716e41b62b9bfd809687c207cef798ef9bc6534d524e17af9b6561a
fetch "https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.2/$onnx.zip" "$onnx_zip" \
  d9e5c0c79929e201f5b8eb095e6809a91ce78be9866a1bca0dfab7e20b40ae40
fetch "$sherpa_source/sherpa-onnx/c-api/c-api.h" "$scratch/c-api-reference.h" \
  5698f38ba09ad2bdf085c56a6cbbd7741acf15e25f4ce5c7097b9702cadf437f
fetch "$sherpa_source/LICENSE" "$notices/LICENSE-sherpa-onnx-Apache-2.0.txt" \
  cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30

# Extract individual named members to controlled paths. Keep test audio,
# alternate model weights, unused libraries and archive metadata out of the app.
extract() {
  /usr/bin/tar -xOf "$1" "$2" > "$3"
  verify "$3" "$4"
}

extract "$sherpa_tar" "$sherpa/lib/libsherpa-onnx-c-api.dylib" \
  "$package/lib/libsherpa-onnx-c-api.dylib" \
  2a169fe29c7e75168cc308b0d5b7f9085efebbb3a7f812d46c3a983d6788759f
extract "$sherpa_tar" "$sherpa/lib/libonnxruntime.dylib" \
  "$package/lib/libonnxruntime.dylib" \
  3567d114f7299d559993e536d605a6f46d7bc9d2542004accc80ee9bf5457f0b

selected_model_file() {
  extract "$model_tar" "$model/$1" "$package/model/$1" "$2"
}

selected_model_file encoder-epoch-12-avg-2-chunk-16-left-64.onnx \
  063fbc1aeae8a9b574607a331a00e60371846ef9eaa3c1d9ea48176665dfc693
selected_model_file decoder-epoch-12-avg-2-chunk-16-left-64.onnx \
  f61ebd3eed3773a44d088d53dfae92dbb6aec4839f4dcaee2d402414741663a3
selected_model_file joiner-epoch-12-avg-2-chunk-16-left-64.onnx \
  0d7a37e749d8055223029318d6ffae82db1dae2d315d0892a68ba5dad17c1d2d
selected_model_file bpe.model c8a2a0129c4ab8e463164c142f82d25649661b122c8cd0b7aab5c9e80b90ad24
selected_model_file tokens.txt fd2ded4050a55d2b1578870ba8697d02371980217806b7558bd0a5cc60f3ba53
extract "$model_tar" "$model/README.md" "$notices/MODEL-LICENSE-DECLARATION.md" \
  74e42d37d63acd2366b042151d576fcc0c4917a41de339414a37f1e79f4e80e2
cp "$notices/LICENSE-sherpa-onnx-Apache-2.0.txt" "$notices/LICENSE-model-Apache-2.0.txt"

/usr/bin/unzip -p "$onnx_zip" "$onnx/LICENSE" > "$notices/LICENSE-onnxruntime-MIT.txt"
verify "$notices/LICENSE-onnxruntime-MIT.txt" \
  2f07c72751aed99790b8a4869cf2311df85a860b22ded05fa22803587a48922c
/usr/bin/unzip -p "$onnx_zip" "$onnx/ThirdPartyNotices.txt" > "$notices/ONNXRuntime-ThirdPartyNotices.txt"
verify "$notices/ONNXRuntime-ThirdPartyNotices.txt" \
  0e07b95f3a8d6230037707c5c4a2b554d12c4cb67369669ac255635528ffcee2
cp DEPENDENCIES.md "$notices/DEPENDENCIES.md"

/usr/bin/xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Werror -pedantic \
  -mmacosx-version-min=14.4 -I"$scratch" worker.cpp -L"$package/lib" \
  -lsherpa-onnx-c-api -Wl,-rpath,@executable_path/lib \
  -o "$package/router_keyword_worker"

# A real model initialization and decode of internal startup context detect
# incompatible artifacts without capturing, playing or opening an audio device.
"$package/router_keyword_worker" --model-dir "$package/model" \
  --wake 'Hey Dot' --standby 'Dot standby' < /dev/null > "$scratch/startup.ndjson"
ready='{"event":"ready","protocol":1,"sample_rate":16000,"wake":"Hey Dot","standby":"Dot standby","runtime":"2.0.1","onnxruntime":"1.28.2","model_profile":"gigaspeech3.3m-fp32-paths8-v1","model_name":"sherpa-onnx-kws-zipformer-gigaspeech-3.3M-2024-01-01","precision":"fp32","max_active_paths":8}'
/usr/bin/grep -Fqx "$ready" "$scratch/startup.ndjson" ||
  fail 'The keyword worker did not start with the pinned runtime and model profile.'
/usr/bin/grep -Fqx '{"event":"eof","frames":0,"sequence":1}' "$scratch/startup.ndjson" ||
  fail 'The keyword worker did not exit cleanly on an empty input stream.'

mv "$package" build/package
printf '%s\n' 'Built and checked macos/keyword/build/package (stdin PCM only).'
