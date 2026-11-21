#!/bin/bash
set -euo pipefail
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
project_dir="$(cd -- "$script_dir/../.." && pwd)"
target_uid="${1:-$(id -u)}"
case "$target_uid" in ''|*[!0-9]*) echo 'Target UID must be numeric.' >&2; exit 2;; esac
bundle="$script_dir/build/AudioRouter.driver"
mkdir -p "$bundle/Contents/MacOS"
xcrun clang++ -std=c++17 -mmacosx-version-min=14.4 -O2 -Wall -Wextra -Werror -pedantic \
  -fvisibility=hidden -DAR_TARGET_UID="$target_uid" -bundle \
  "$script_dir/driver.cpp" "$project_dir/macos/transport/pcm_transport.cpp" \
  -framework CoreFoundation -Wl,-dead_strip -Wl,-exported_symbol,_AudioRouterFactory \
  -o "$bundle/Contents/MacOS/AudioRouter"
python3 - "$bundle/Contents/Info.plist" "$target_uid" <<'PY'
import plistlib, sys
path, raw_uid = sys.argv[1:]
uid = int(raw_uid)
if not 0 <= uid <= 0xFFFFFFFF:
    raise SystemExit('Target UID must fit uint32.')
factory = '7426B55D-BA66-49B9-9E12-CBEB1AC66890'
data = {
    'CFBundleIdentifier': 'ai.agentsofchange.router.driver',
    'CFBundleName': 'Audio Router',
    'CFBundleExecutable': 'AudioRouter',
    'CFBundlePackageType': 'BNDL',
    'CFBundleVersion': '1',
    'CFBundleShortVersionString': '0.1.0',
    'LSMinimumSystemVersion': '14.4',
    'CFPlugInDynamicRegistration': False,
    'CFPlugInFactories': {factory: 'AudioRouterFactory'},
    'CFPlugInTypes': {'443ABAB8-E7B3-491A-B985-BEB9187030DB': [factory]},
    'AudioServerPlugIn_MachServices': [f'ai.agentsofchange.router.pcm-broker.{uid}'],
    'AudioRouterTargetUID': uid,
}
with open(path, 'wb') as output:
    plistlib.dump(data, output, sort_keys=True)
PY
echo "Built source-only HAL bundle: $bundle"
echo 'Not installed, loaded into an audio host, or signed for distribution.'
