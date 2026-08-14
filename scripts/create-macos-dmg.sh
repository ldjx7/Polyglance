#!/bin/zsh
set -euo pipefail

script_name="${0:t}"

function usage() {
    print "Usage: $script_name <Polyglance.app> <output.dmg>"
    print ""
    print "Creates a compressed DMG containing Polyglance.app and an Applications shortcut."
}

if (( $# == 1 )) && [[ "$1" == "--help" || "$1" == "-h" ]]; then
    usage
    exit 0
fi

if (( $# != 2 )); then
    usage >&2
    exit 2
fi

app_bundle="${1:A}"
output_dmg="${2:A}"

if [[ ! -d "$app_bundle" || ! -f "$app_bundle/Contents/Info.plist" ]]; then
    print -u2 "Expected a macOS app bundle, received: $app_bundle"
    exit 1
fi

if [[ "${output_dmg:e:l}" != "dmg" ]]; then
    print -u2 "The output file must use the .dmg extension: $output_dmg"
    exit 1
fi

mkdir -p "${output_dmg:h}"
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/polyglance-dmg.XXXXXX")"

function cleanup() {
    rm -rf "$staging_directory"
}
trap cleanup EXIT

ditto "$app_bundle" "$staging_directory/Polyglance.app"
ln -s /Applications "$staging_directory/Applications"

hdiutil create \
    -volname "Polyglance" \
    -srcfolder "$staging_directory" \
    -format UDZO \
    -ov \
    "$output_dmg"

print "Created $output_dmg"
