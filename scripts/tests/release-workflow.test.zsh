#!/bin/zsh
set -euo pipefail

test_directory="${0:A:h}"
repository_root="${test_directory:h:h}"
workflow="$repository_root/.github/workflows/release-macos.yml"
package_manifest="$repository_root/apps/macos/Package.swift"
dmg_script="$repository_root/scripts/create-macos-dmg.sh"
repair_instructions="$repository_root/scripts/resources/打不开Polyglance-复制本文件全部内容到终端执行.txt"
signing_fingerprint="$repository_root/config/macos-signing-certificate-sha1.txt"

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
[[ -f "$repair_instructions" ]]
[[ -f "$signing_fingerprint" ]]
require_pattern "tags:"
require_pattern "actions/checkout@v5"
require_pattern "git merge-base --is-ancestor"
require_pattern "SPARKLE_PRIVATE_KEY"
require_pattern "generate_appcast"
require_pattern "gh release"
require_pattern 'docs/releases/${GITHUB_REF_NAME}.md'
require_pattern '--notes-file "$RELEASE_NOTES"'
require_pattern "macos-15"
require_pattern "create-macos-dmg.sh"
require_pattern 'Polyglance-${VERSION}-macOS.dmg'
require_pattern "MACOS_SIGNING_P12"
require_pattern "MACOS_SIGNING_P12_PASSWORD"
require_pattern "MACOS_SIGNING_IDENTITY"
require_pattern "macos-signing-certificate-sha1.txt"
require_pattern "CODESIGN_CERTIFICATE_SHA1"
require_pattern "CODESIGN_TIMESTAMP_MODE: none"

if rg --quiet --fixed-strings "security add-trusted-cert" "$workflow"; then
    print -u2 "The release workflow must not require interactive trust authorization."
    exit 1
fi

fingerprint="$(tr -d '[:space:]' < "$signing_fingerprint")"
if [[ ! "$fingerprint" =~ '^[A-F0-9]{40}$' ]]; then
    print -u2 "The persistent macOS signing certificate fingerprint must be a SHA-1 hex digest."
    exit 1
fi

if ! rg --quiet --fixed-strings "// swift-tools-version: 6.1" "$package_manifest"; then
    print -u2 "The macOS package must remain compatible with the Swift 6.1 toolchain on macos-15."
    exit 1
fi

if [[ ! -x "$dmg_script" ]]; then
    print -u2 "The macOS DMG packaging script must be executable."
    exit 1
fi

if ! rg --quiet --fixed-strings '打不开Polyglance-复制本文件全部内容到终端执行.txt' "$dmg_script"; then
    print -u2 "The DMG must include the copyable per-app quarantine instructions."
    exit 1
fi

if ! rg --quiet --fixed-strings '# ' "$repair_instructions" \
    || ! rg --quiet --fixed-strings '/usr/bin/xattr -dr com.apple.quarantine "/Applications/Polyglance.app"' "$repair_instructions" \
    || ! rg --quiet --fixed-strings '/usr/bin/open "/Applications/Polyglance.app"' "$repair_instructions"; then
    print -u2 "The copyable instructions must safely target Polyglance in Applications."
    exit 1
fi

print "macOS release workflow contract passed"
