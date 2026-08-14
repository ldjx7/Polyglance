#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h}"
macos_root="$repository_root/apps/macos"
generated_root="$macos_root/Generated"
library_root="$macos_root/Libraries"
staging_directory="$(mktemp -d)"

cleanup() {
    rm -rf "$staging_directory"
}
trap cleanup EXIT

cd "$repository_root"
MACOSX_DEPLOYMENT_TARGET=15.0 cargo build --release -p translator-uniffi -p uniffi-bindgen
cargo run --release -p uniffi-bindgen -- \
    generate \
    --library "$repository_root/target/release/libtranslator_uniffi.dylib" \
    --language swift \
    --out-dir "$staging_directory/generated"

mkdir -p \
    "$generated_root/TranslatorCore" \
    "$generated_root/translator_uniffiFFI/include" \
    "$library_root"
cp "$staging_directory/generated/translator_uniffi.swift" \
    "$generated_root/TranslatorCore/TranslatorCore.swift"
cp "$staging_directory/generated/translator_uniffiFFI.h" \
    "$generated_root/translator_uniffiFFI/include/translator_uniffiFFI.h"
cp "$staging_directory/generated/translator_uniffiFFI.modulemap" \
    "$generated_root/translator_uniffiFFI/include/module.modulemap"
cp "$repository_root/target/release/libtranslator_uniffi.a" \
    "$library_root/libtranslator_uniffi.a"

echo "Generated Swift bindings and Rust static library for macOS"
