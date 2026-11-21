#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p macos/host/build
for source in native/router_core.cpp macos/capture/capture_format.cpp macos/transport/pcm_transport.cpp macos/dsp/stream_resampler.cpp; do
  object="macos/host/build/$(basename "$source" .cpp).o"
  xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -mmacosx-version-min=14.4 -c "$source" -o "$object"
done
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -mmacosx-version-min=14.4 -fobjc-arc -c macos/capture/capture_adapter.mm -o macos/host/build/capture_adapter.o
xcrun clang++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -mmacosx-version-min=14.4 -fobjc-arc macos/host/main.mm \
  macos/host/build/router_core.o macos/host/build/capture_format.o macos/host/build/capture_adapter.o macos/host/build/pcm_transport.o macos/host/build/stream_resampler.o \
  -framework Foundation -framework CoreAudio -framework CoreFoundation \
  -Wl,-sectcreate,__TEXT,__info_plist,macos/host/Info.plist -o macos/host/build/audio_router_host
printf '%s\n' 'Built audio_router_host; no capture was started.'
