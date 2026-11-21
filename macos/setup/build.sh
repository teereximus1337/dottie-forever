#!/bin/bash
# Build a fresh, per-user app bundle without installing or launching it.
set -euo pipefail
repo="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
source "$repo/macos/setup/platform.sh"
check_build_platform

mode="${1:---full}"
if [ "$#" -gt 1 ]; then fail 'Use build.sh [--full|--manual].'; fi
case "$mode" in
  --full|--manual) ;;
  *) fail 'Use build.sh [--full|--manual].' ;;
esac
if [ "$mode" = --full ] && [ ! -f "$repo/macos/keyword/package.sh" ]; then
  fail 'The verified wake-word package recipe is unavailable. See the project setup instructions.'
fi

uid="$(/usr/bin/id -u)"
output="$repo/build"
app="$output/Dottie Forever.app"
publish_lock="$output/.publish-lock"
if [ -L "$output" ]; then fail 'The build directory is a symbolic link.'; fi
/bin/mkdir -p "$output"
if [ -e "$app" ] || [ -L "$app" ]; then
  fail "Move the previous build out of $app before rebuilding."
fi

workspace="$(/usr/bin/mktemp -d "$output/.build.XXXXXXXX")"
locked=0
cleanup() {
  /bin/rm -rf -- "$workspace"
  if [ "$locked" -eq 1 ]; then /bin/rmdir "$publish_lock"; fi
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
cd "$workspace"

# Fresh working directories prevent local node_modules, output files and private
# Work settings from being reused as build inputs.
/bin/mkdir -p frontend macos/app native
/bin/cp "$repo"/frontend/{index.html,package.json,package-lock.json,tsconfig.json,vite.config.ts} frontend/
/bin/cp -R "$repo/frontend/src" "$repo/frontend/tests" frontend/
/bin/cp "$repo"/macos/app/*.swift "$repo/macos/app/Info.plist" macos/app/
/bin/cp "$repo"/native/router_core.{cpp,hpp} native/
for component in broker capture driver dsp host transport; do
  /bin/mkdir "macos/$component"
  /usr/bin/find "$repo/macos/$component" -maxdepth 1 -type f \
    \( -name '*.cpp' -o -name '*.hpp' -o -name '*.mm' -o -name '*.sh' -o -name 'Info.plist' \) \
    -exec /bin/cp '{}' "macos/$component/" \;
done

if [ "$mode" = --full ]; then
  /bin/mkdir macos/keyword
  /usr/bin/find "$repo/macos/keyword" -maxdepth 1 -type f \
    -exec /bin/cp '{}' macos/keyword/ \;
  /bin/bash macos/keyword/package.sh
  [ -x macos/keyword/build/package/router_keyword_worker ] ||
    fail 'The wake-word recipe did not produce an executable worker.'
  [ -d macos/keyword/build/package/model ] ||
    fail 'The wake-word recipe did not produce a model directory.'
fi

# Node is a build tool only. This archive and the npm lockfile both have fixed
# integrity values. No npm dependency install hooks are needed on macOS arm64.
node_release='v24.22.3'
node_dir="node-$node_release-darwin-arm64"
node_archive="$node_dir.tar.gz"
node_sha='ff6e17d4874b76d272212b908cc020d6e815fba5a6c7eaaa06add725840307fd'
/usr/bin/curl --fail --silent --show-error --location --proto '=https' \
  --connect-timeout 15 --max-time 180 \
  "https://nodejs.org/dist/$node_release/$node_archive" --output "$node_archive"
printf '%s  %s\n' "$node_sha" "$node_archive" | /usr/bin/shasum -a 256 -c -
/usr/bin/tar -xzf "$node_archive"
export PATH="$workspace/$node_dir/bin:/usr/bin:/bin:/usr/sbin:/sbin"

/usr/bin/python3 "$repo/macos/setup/frontend_notices.py" verify frontend
(
  cd frontend
  unset NODE_OPTIONS NODE_PATH NODE_ENV
  export HOME="$workspace/npm-home"
  export npm_config_update_notifier=false
  /bin/mkdir "$HOME"
  : > "$HOME/global-npmrc"
  npm --userconfig /dev/null --globalconfig "$HOME/global-npmrc" ci --ignore-scripts \
    --include=dev --include=optional --no-audit --no-fund
  npm --userconfig /dev/null --globalconfig "$HOME/global-npmrc" --ignore-scripts run build
)

/bin/sh macos/host/build.sh
/bin/sh macos/broker/build.sh "$uid"
/bin/bash macos/driver/build_driver.sh "$uid"

candidate="$workspace/Dottie Forever.app"
resources="$candidate/Contents/Resources"
/bin/mkdir -p "$candidate/Contents/MacOS" "$resources/bin"
/usr/bin/xcrun swiftc -parse-as-library -O -target arm64-apple-macos14.4 \
  -warnings-as-errors macos/app/*.swift \
  -framework AppKit -framework WebKit -framework CoreAudio \
  -o "$candidate/Contents/MacOS/AudioRouter"
/bin/cp macos/app/Info.plist "$candidate/Contents/Info.plist"
/usr/bin/ditto frontend/dist "$resources/web"
/usr/bin/python3 "$repo/macos/setup/frontend_notices.py" collect frontend "$resources/notices/frontend.txt"
/bin/cp macos/host/build/audio_router_host \
  macos/broker/build/{audio_router_broker,launchdaemon.plist} "$resources/bin/"
/usr/bin/ditto macos/driver/build/AudioRouter.driver "$resources/AudioRouter.driver"

if [ "$mode" = --manual ]; then
  : > "$resources/ManualVoiceGate"
else
  /usr/bin/ditto macos/keyword/build/package "$resources/keyword"
  for library in "$resources"/keyword/lib/*.dylib; do
    [ -f "$library" ] || fail 'The wake-word package is missing its runtime libraries.'
    /usr/bin/codesign --force --sign - "$library"
  done
  /usr/bin/codesign --force --sign - "$resources/keyword/router_keyword_worker"
fi
/usr/bin/plutil -lint "$candidate/Contents/Info.plist" "$resources/bin/launchdaemon.plist"
/usr/bin/codesign --force --sign - "$resources/bin/audio_router_host"
/usr/bin/codesign --force --sign - "$resources/AudioRouter.driver"
/usr/bin/codesign --force --sign - "$candidate"
/usr/bin/codesign --verify --strict "$resources/bin/audio_router_host"
/usr/bin/codesign --verify --strict "$resources/bin/audio_router_broker"
/usr/bin/codesign --verify --strict "$resources/AudioRouter.driver"
/usr/bin/codesign --verify --deep --strict "$candidate"
/bin/mkdir "$publish_lock" || fail 'Another build is publishing its output.'
locked=1
if [ -e "$app" ] || [ -L "$app" ]; then fail "Another build already created $app."; fi
/bin/mv -- "$candidate" "$app"
printf 'Built %s for UID %s (%s).\n' "$app" "$uid" "$mode"
