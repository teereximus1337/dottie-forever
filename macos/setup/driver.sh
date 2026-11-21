#!/bin/bash
# Run interactively with sudo from the signed-in Mac administrator account.
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
umask 077
setup="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source "$setup/platform.sh"

usage() { fail 'Use driver.sh install "/absolute/path/Dottie Forever.app", driver.sh uninstall, or driver.sh recover with sudo /bin/bash.'; }
action="${1:-}"
case "$action" in
  install) [ "$#" -eq 2 ] || usage ;;
  uninstall|recover) [ "$#" -eq 1 ] || usage ;;
  *) usage ;;
esac
[ "$(/usr/bin/id -u)" -eq 0 ] || fail 'Driver changes require administrator approval in Terminal.'
uid="${SUDO_UID:-}"
case "$uid" in ''|0|*[!0-9]*) fail 'Run this with sudo from your Mac desktop account.' ;; esac
[ "$uid" = "$(/usr/bin/stat -f %u /dev/console)" ] ||
  fail 'The account running sudo must be signed in to the Mac desktop.'

state=/private/var/db/DottieForever
lock=/private/var/db/.DottieForever.lock
receipt="$state/receipt"
operation="$state/operation"
label="ai.agentsofchange.router.pcm-broker.$uid"
driver=/Library/Audio/Plug-Ins/HAL/AudioRouter.driver
broker="/Library/PrivilegedHelperTools/ai.agentsofchange.router.pcm-broker-$uid"
daemon="/Library/LaunchDaemons/$label.plist"
driver_id=ai.agentsofchange.router.driver
driver_executable=Contents/MacOS/AudioRouter
driver_info=Contents/Info.plist
staged_driver=AudioRouter.driver

plist_value() { /usr/libexec/PlistBuddy -c "Print :$1" "$2"; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
digest() { /usr/bin/shasum -a 256 < "$1" | /usr/bin/cut -d ' ' -f 1; }

secure_directory() {
  local directory="$1" mode
  [ -d "$directory" ] && [ ! -L "$directory" ] &&
    [ "$(/usr/bin/stat -f %u "$directory")" -eq 0 ] ||
    fail "Expected a root-owned directory at $directory."
  mode="$(/usr/bin/stat -f %OLp "$directory")"
  [[ "$mode" =~ ^[0-7]+$ ]] && (( (8#$mode & 022) == 0 )) ||
    fail "Expected a directory protected from other users at $directory."
}

library_directory() {
  if ! exists "$1"; then /usr/bin/install -d -o root -g wheel -m 755 "$1"; fi
  secure_directory "$1"
}

verify_driver() {
  local bundle="$1"
  [ -d "$bundle" ] && [ ! -L "$bundle" ] ||
    fail 'The expected HAL driver bundle is missing.'
  [ "$(plist_value CFBundleIdentifier "$bundle/$driver_info")" = "$driver_id" ] &&
    [ "$(plist_value AudioRouterTargetUID "$bundle/$driver_info")" = "$uid" ] &&
    [ "$(plist_value AudioServerPlugIn_MachServices:0 "$bundle/$driver_info")" = "$label" ] ||
    fail 'The virtual driver must have been built by this desktop account.'
  /usr/bin/codesign --verify --strict "$bundle"
}

verify_regular_tree() {
  local unexpected
  unexpected="$(/usr/bin/find "$1" ! -type d ! -type f -print -quit)" ||
    fail 'Could not inspect the driver bundle.'
  [ -z "$unexpected" ] || fail 'The driver bundle contains a symbolic link or special file.'
}

write_daemon() {
  /bin/cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$label</string>
<key>ProgramArguments</key><array><string>$broker</string><string>--target-uid</string><string>$uid</string></array>
<key>MachServices</key><dict><key>$label</key><true/></dict>
<key>UserName</key><string>root</string>
<key>ProcessType</key><string>Interactive</string>
</dict></plist>
EOF
  /usr/bin/plutil -lint "$1"
}

make_receipt() {
  printf '%s\n' "$uid"
  digest "$1/$driver_executable" || return 1
  digest "$1/$driver_info" || return 1
  digest "$2" || return 1
  digest "$3" || return 1
}

check_receipt_owner() {
  [ -f "$receipt" ] && [ ! -L "$receipt" ] &&
    [ "$(/usr/bin/head -n 1 "$receipt")" = "$uid" ] ||
    fail "The installation receipt does not match this account. Inspect $state before making any changes."
}

write_operation() {
  local directory="$1" kind="$2"
  printf '%s %s\n' "$uid" "$kind" > "$directory/.new-operation"
  /bin/mv "$directory/.new-operation" "$directory/operation"
}

verify_receipt_file() {
  local path="$1" line="$2"
  [ -f "$path" ] && [ ! -L "$path" ] &&
    [ "$(digest "$path")" = "$(/usr/bin/sed -n "${line}p" "$receipt")" ] ||
    fail "A component differs from its receipt at $path. The transaction is retained at $state."
}

install_driver() {
  local app="$1" resources stage pending
  [[ "$app" == /* ]] && [ -d "$app" ] && [ ! -L "$app" ] &&
    [ "$(/usr/bin/stat -f %u "$app")" = "$uid" ] ||
    fail 'Use the absolute path to the app built by the current account.'
  /usr/bin/codesign --verify --deep --strict "$app"
  [ "$(plist_value CFBundleIdentifier "$app/Contents/Info.plist")" = private.audio.router.app ] ||
    fail 'The app does not have the expected bundle identifier.'
  resources="$app/Contents/Resources"
  check_uninstalled
  if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    fail 'An audio router broker is already registered. Use a clean Mac.'
  fi
  for directory in /Library /Library/Audio /Library/Audio/Plug-Ins /Library/Audio/Plug-Ins/HAL \
    /Library/PrivilegedHelperTools /Library/LaunchDaemons; do
    library_directory "$directory"
  done
  pending="$(/usr/bin/mktemp -d /private/var/db/.DottieForever-install.XXXXXXXX)"
  write_operation "$pending" install
  /bin/mv "$pending" "$state"
  stage="$state/install"
  # Use a root-only stage before validating any privileged payload or installing it.
  trap 'rollback_install "$?"' EXIT
  trap 'exit 1' HUP INT TERM
  /bin/mkdir -m 700 "$stage"
  [ -d "$resources/AudioRouter.driver" ] && [ ! -L "$resources/AudioRouter.driver" ] &&
    [ -f "$resources/bin/audio_router_broker" ] && [ ! -L "$resources/bin/audio_router_broker" ] ||
    fail 'The expected driver and broker files are missing from the built app.'
  /usr/bin/ditto --norsrc --noextattr --noacl "$resources/AudioRouter.driver" "$stage/$staged_driver"
  /usr/bin/install -o root -g wheel -m 755 "$resources/bin/audio_router_broker" "$stage/broker"
  verify_regular_tree "$stage/$staged_driver"
  /usr/sbin/chown -R root:wheel "$stage/$staged_driver"
  /bin/chmod -R go-w "$stage/$staged_driver"
  verify_driver "$stage/$staged_driver"
  /usr/bin/codesign --verify --strict "$stage/broker"
  write_daemon "$stage/daemon"
  /usr/bin/cmp -s "$resources/bin/launchdaemon.plist" "$stage/daemon" ||
    fail 'The bundled broker registration differs from the expected configuration.'
  /usr/sbin/chown root:wheel "$stage/daemon"
  /bin/chmod 644 "$stage/daemon"
  make_receipt "$stage/$staged_driver" "$stage/broker" "$stage/daemon" > "$stage/receipt"
  /bin/mv "$stage/receipt" "$receipt"
  /bin/mv "$stage/$staged_driver" "$driver"
  /bin/mv "$stage/broker" "$broker"
  /bin/mv "$stage/daemon" "$daemon"
  /bin/rm "$operation"
  trap - EXIT HUP INT TERM
  /bin/rmdir "$stage"
  printf '%s\n' 'Driver files installed. Restart your Mac before opening Dottie Forever.'
}

rollback_install() {
  local result="$1" stage="$state/install"
  trap - EXIT HUP INT TERM
  if ! exists "$operation"; then exit "$result"; fi
  if exists "$receipt"; then
    check_receipt_owner
    if exists "$daemon" && ! exists "$stage/daemon"; then
      verify_receipt_file "$daemon" 5
      if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
        /bin/launchctl bootout "system/$label"
      fi
      /bin/mv "$daemon" "$stage/daemon"
    fi
    if exists "$broker" && ! exists "$stage/broker"; then
      verify_receipt_file "$broker" 4
      /bin/mv "$broker" "$stage/broker"
    fi
    if exists "$driver" && ! exists "$stage/$staged_driver"; then
      verify_regular_tree "$driver"
      verify_driver "$driver"
      verify_receipt_file "$driver/$driver_executable" 2
      verify_receipt_file "$driver/$driver_info" 3
      /bin/mv "$driver" "$stage/$staged_driver"
    fi
  fi
  discard_state
  printf '%s\n' 'Installation rolled back. If the driver was loaded, restart your Mac to unload it.' >&2
  exit "$result"
}

uninstall_driver() {
  local stage
  if ! exists "$state"; then
    fail 'No source-build installation receipt was found. Existing audio software was left alone.'
  fi
  secure_directory "$state"
  if exists "$operation"; then fail 'An unfinished driver operation exists. Run driver.sh recover.'; fi
  check_receipt_owner
  verify_regular_tree "$driver"
  verify_driver "$driver"
  [ -f "$broker" ] && [ ! -L "$broker" ] && [ -f "$daemon" ] && [ ! -L "$daemon" ] &&
    make_receipt "$driver" "$broker" "$daemon" | /usr/bin/cmp -s - "$receipt" ||
    fail 'An installed component differs from the receipt. No files were removed.'

  stage="$state/uninstall"
  write_operation "$state" uninstall
  trap 'rollback_uninstall "$?"' EXIT
  trap 'exit 1' HUP INT TERM
  /bin/mkdir -m 700 "$stage"
  if /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    : > "$stage/broker-was-loaded"
    /bin/launchctl bootout "system/$label"
  fi
  /bin/mv "$daemon" "$stage/daemon"
  /bin/mv "$broker" "$stage/broker"
  /bin/mv "$driver" "$stage/$staged_driver"
  discard_state
  trap - EXIT HUP INT TERM
  printf '%s\n' 'Driver files removed. Restart your Mac to finish unloading the virtual inputs.'
}

restore_file() {
  local staged="$1" installed="$2" line="$3"
  if exists "$staged"; then
    verify_receipt_file "$staged" "$line"
    if exists "$installed"; then
      fail "Cannot restore a component over $installed. The transaction is retained at $state."
    fi
    /bin/mv "$staged" "$installed"
  fi
}

rollback_uninstall() {
  local result="$1" stage="$state/uninstall"
  trap - EXIT HUP INT TERM
  if ! exists "$operation"; then exit "$result"; fi
  check_receipt_owner
  if exists "$stage/$staged_driver"; then
    verify_regular_tree "$stage/$staged_driver"
    verify_driver "$stage/$staged_driver"
    verify_receipt_file "$stage/$staged_driver/$driver_executable" 2
    verify_receipt_file "$stage/$staged_driver/$driver_info" 3
    if exists "$driver"; then
      fail "Cannot restore a driver over $driver. The transaction is retained at $state."
    fi
    /bin/mv "$stage/$staged_driver" "$driver"
  fi
  restore_file "$stage/broker" "$broker" 4
  restore_file "$stage/daemon" "$daemon" 5
  if exists "$stage/broker-was-loaded" &&
    ! /bin/launchctl print "system/$label" >/dev/null 2>&1; then
    /bin/launchctl bootstrap system "$daemon" || exit "$result"
  fi
  /bin/rm -rf "$stage"
  /bin/rm "$operation"
  printf '%s\n' 'Uninstall rolled back. The installed files were restored.' >&2
  exit "$result"
}

discard_state() {
  local trash
  # Renaming the receipt and transaction together gives cleanup a commit point.
  trash="$(/usr/bin/mktemp -d /private/var/db/.DottieForever-removed.XXXXXXXX)"
  /bin/mv "$state" "$trash/"
  /bin/rm -rf "$trash"
}

recover_driver() {
  local previous_uid previous_action extra
  secure_directory "$state"
  [ -f "$operation" ] && [ ! -L "$operation" ] ||
    fail 'No unfinished driver operation is recorded.'
  read -r previous_uid previous_action extra < "$operation" ||
    fail "Cannot read the driver operation at $operation."
  [[ "$previous_uid" = "$uid" && -z "$extra" ]] ||
    fail 'The recorded operation does not match the desktop account.'
  case "$previous_action" in
    install) rollback_install 0 ;;
    uninstall) rollback_uninstall 0 ;;
    *) fail "Unrecognized transaction at $operation." ;;
  esac
}

secure_directory /private/var/db
if exists "$lock"; then
  [ -f "$lock" ] && [ ! -L "$lock" ] && [ "$(/usr/bin/stat -f %u "$lock")" = 0 ] ||
    fail "An unexpected file occupies $lock."
fi
(
  # The empty, root-only file provides a stable kernel lock across operations.
  # The kernel releases the lock even if this process is interrupted.
  /usr/bin/lockf -s -t 0 9 || fail 'Another driver operation is running.'
  case "$action" in
    install) install_driver "$2" ;;
    uninstall) uninstall_driver ;;
    recover) recover_driver ;;
  esac
) 9>"$lock"
