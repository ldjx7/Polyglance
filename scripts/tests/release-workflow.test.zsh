#!/bin/zsh
set -euo pipefail

test_directory="${0:A:h}"
repository_root="${test_directory:h:h}"
workflow="$repository_root/.github/workflows/release-macos.yml"

function require_pattern() {
    local pattern="$1"
    if ! rg --quiet --fixed-strings -- "$pattern" "$workflow"; then
        print -u2 "Missing macOS release workflow contract: $pattern"
        return 1
    fi
}

[[ -f "$workflow" ]]
require_pattern "tags:"
require_pattern "git merge-base --is-ancestor"
require_pattern "SPARKLE_PRIVATE_KEY"
require_pattern "generate_appcast"
require_pattern "gh release"
require_pattern "macos-15"

print "macOS release workflow contract passed"
