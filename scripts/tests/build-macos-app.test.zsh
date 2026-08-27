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
require_pattern "Microphone"
require_pattern "CFBundleIdentifier"
require_pattern "lsregister"
require_pattern "Polyglance Open Source Signing"
require_pattern "Persistent signing identity could not be used; falling back to an ad-hoc development signature."
require_pattern "pgrep -f"
require_pattern "Polyglance.app"
require_pattern "Polyglance.icns"
require_pattern "Sparkle.framework"
require_pattern "POLYGLANCE_APPCAST_URL"
require_pattern "SUPublicEDKey"
require_pattern "CODESIGN_CERTIFICATE_SHA1"
require_pattern "CODESIGN_TIMESTAMP_MODE"
require_pattern 'codesign_requirement="designated => $codesign_requirement_expression"'
require_pattern 'certificate leaf = H'
require_pattern "--requirements"
require_pattern "codesign --verify --deep --strict"
require_pattern 'codesign --verify --strict -R "=$codesign_requirement_expression"'

if rg --quiet --fixed-strings -- 'tccutil reset "$permission_service" "$bundle_identifier" || true' "$build_script"; then
    print -u2 "The build script must not report a failed TCC reset as successful"
    exit 1
fi

if rg --quiet '(^|[[:space:]])open[[:space:]]' "$build_script"; then
    print -u2 "The build script must not launch the app automatically"
    exit 1
fi

print "build-macos-app contract passed"
