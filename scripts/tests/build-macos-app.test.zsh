#!/bin/zsh
set -euo pipefail

test_directory="${0:A:h}"
repository_root="${test_directory:h:h}"
build_script="$repository_root/scripts/build-macos-app.sh"

function require_pattern() {
    local pattern="$1"
    if ! rg --quiet --fixed-strings -- "$pattern" "$build_script"; then
        print -u2 "Missing build-script contract: $pattern"
        return 1
    fi
}

zsh -n "$build_script"
require_pattern "--preserve-permissions"
require_pattern "tccutil reset"
require_pattern "Accessibility"
require_pattern "ScreenCapture"
require_pattern "CFBundleIdentifier"
require_pattern "pgrep -f"
require_pattern "Polyglance.app"
require_pattern "Polyglance.icns"
require_pattern "Sparkle.framework"
require_pattern "POLYGLANCE_APPCAST_URL"
require_pattern "SUPublicEDKey"

if rg --quiet '(^|[[:space:]])open[[:space:]]' "$build_script"; then
    print -u2 "The build script must not launch the app automatically"
    exit 1
fi

print "build-macos-app contract passed"
