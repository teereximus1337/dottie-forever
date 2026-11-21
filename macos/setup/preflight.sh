#!/bin/bash
# Read-only check for a supported first-install environment.
set -euo pipefail
setup="$(cd -- "$(dirname -- "$0")" && pwd -P)"
source "$setup/platform.sh"
check_build_platform
check_uninstalled

uid="$(/usr/bin/id -u)"
[ "$uid" = "$(/usr/bin/stat -f %u /dev/console)" ] ||
  fail 'Run preflight from the account signed in to the Mac desktop.'
case " $(/usr/bin/id -Gn) " in
  *' admin '*) ;;
  *) fail 'The desktop account needs permission to install the driver as a Mac administrator.' ;;
esac

for path in "/Applications/Dottie Forever.app" "/Applications/Audio Router.app" \
  "$HOME/Applications/Dottie Forever.app" "$HOME/Applications/Audio Router.app" \
  "$HOME/.audio-router"; do
  if [ -e "$path" ] || [ -L "$path" ]; then
    fail "Existing app or settings at $path. Use a clean Mac for first installation."
  fi
done

printf 'First-install preflight passed for macOS %s, UID %s.\n' "$(/usr/bin/sw_vers -productVersion)" "$uid"
