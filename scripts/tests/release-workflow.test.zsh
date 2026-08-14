#!/bin/zsh
set -euo pipefail

test_directory="${0:A:h}"
repository_root="${test_directory:h:h}"
workflow="$repository_root/.github/workflows/release-macos.yml"
package_manifest="$repository_root/apps/macos/Package.swift"

function require_pattern() {
    local pattern="$1"
    if ! rg --quiet --fixed-strings -- "$pattern" "$workflow"; then
        print -u2 "Missing macOS release workflow contract: $pattern"
        return 1
    fi
}

[[ -f "$workflow" ]]
[[ -f "$package_manifest" ]]
require_pattern "tags:"
require_pattern "git merge-base --is-ancestor"
require_pattern "SPARKLE_PRIVATE_KEY"
require_pattern "generate_appcast"
require_pattern "gh release"
require_pattern "macos-15"
require_pattern "create-macos-dmg.sh"
require_pattern 'Polyglance-${VERSION}-macOS.dmg'

if ! rg --quiet --fixed-strings "// swift-tools-version: 6.1" "$package_manifest"; then
    print -u2 "The macOS package must remain compatible with the Swift 6.1 toolchain on macos-15."
    exit 1
fi

if [[ ! -x "$repository_root/scripts/create-macos-dmg.sh" ]]; then
    print -u2 "The macOS DMG packaging script must be executable."
    exit 1
fi

print "macOS release workflow contract passed"
