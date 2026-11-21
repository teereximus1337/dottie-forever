#!/bin/bash

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

check_build_platform() {
  local major sdk
  major="$(/usr/bin/sw_vers -productVersion)"
  major="${major%%.*}"
  if [ "$(/usr/bin/uname -m)" != arm64 ] || [ "$major" -lt 15 ]; then
    fail 'Use an Apple Silicon Mac running macOS 15 or later, in a native arm64 Terminal.'
  fi
  [ "$(/usr/bin/id -u)" -ne 0 ] || fail 'Run the build as the account that will use Dottie Forever.'
  sdk="$(/usr/bin/xcrun --sdk macosx --show-sdk-version 2>/dev/null)" ||
    fail 'Install Apple’s Command Line Tools or Xcode first.'
  if ! /usr/bin/awk -F. '{ exit !($1 >= 15 || ($1 == 14 && $2 >= 4)) }' <<< "$sdk"; then
    fail 'The active Apple toolchain needs the macOS 14.4 SDK or newer.'
  fi
  /usr/bin/xcrun --find swiftc >/dev/null &&
    /usr/bin/xcrun --find clang++ >/dev/null &&
    /usr/bin/python3 -c 'import plistlib' ||
    fail 'The active Apple toolchain needs Swift, Clang and Python 3.'
}

check_uninstalled() {
  local path
  for path in /Library/Audio/Plug-Ins/HAL/AudioRouter.driver \
    /Library/LaunchDaemons/ai.agentsofchange.router.pcm-broker.*.plist \
    /Library/PrivilegedHelperTools/ai.agentsofchange.router.pcm-broker-* \
    /private/var/db/DottieForever; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      fail "Existing audio router component at $path. Use a clean Mac for first installation."
    fi
  done
}
