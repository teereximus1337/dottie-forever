#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
mkdir -p macos/broker/build
target_uid="${1:-$(id -u)}"
case "$target_uid" in ''|0|*[!0-9]*) echo 'A non-root numeric target UID is required.' >&2; exit 2;; esac
clang++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -mmacosx-version-min=14.4 \
  macos/broker/broker_main.cpp macos/transport/pcm_transport.cpp -lbsm \
  -o macos/broker/build/audio_router_broker
codesign --force --sign - macos/broker/build/audio_router_broker
cat > macos/broker/build/launchdaemon.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>ai.agentsofchange.router.pcm-broker.$target_uid</string>
<key>ProgramArguments</key><array><string>/Library/PrivilegedHelperTools/ai.agentsofchange.router.pcm-broker-$target_uid</string><string>--target-uid</string><string>$target_uid</string></array>
<key>MachServices</key><dict><key>ai.agentsofchange.router.pcm-broker.$target_uid</key><true/></dict>
<key>UserName</key><string>root</string>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
plutil -lint macos/broker/build/launchdaemon.plist
printf '%s\n' 'Built the local broker; no service was installed or started.'
