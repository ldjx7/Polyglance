#!/bin/zsh
set -euo pipefail

test_directory="${0:A:h}"
repository_root="${test_directory:h:h}"
workflow="$repository_root/.github/workflows/release-macos.yml"
package_manifest="$repository_root/apps/macos/Package.swift"
dmg_script="$repository_root/scripts/create-macos-dmg.sh"
repair_script="$repository_root/scripts/resources/修复无法打开.command"

function require_pattern() {
    local pattern="$1"
    if ! rg --quiet --fixed-strings -- "$pattern" "$workflow"; then
        print -u2 "Missing macOS release workflow contract: $pattern"
        return 1
    fi
}

[[ -f "$workflow" ]]
[[ -f "$package_manifest" ]]
[[ -x "$dmg_script" ]]
[[ -x "$repair_script" ]]
require_pattern "tags:"
require_pattern "actions/checkout@v5"
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

if [[ ! -x "$dmg_script" ]]; then
    print -u2 "The macOS DMG packaging script must be executable."
    exit 1
fi

if ! rg --quiet --fixed-strings '修复无法打开.command' "$dmg_script"; then
    print -u2 "The DMG must include the per-app quarantine repair command."
    exit 1
fi

if ! rg --quiet --fixed-strings 'com.apple.quarantine' "$repair_script" \
    || ! rg --quiet --fixed-strings '/Applications/Polyglance.app' "$repair_script"; then
    print -u2 "The repair command must only target Polyglance in Applications."
    exit 1
fi

print "macOS release workflow contract passed"
