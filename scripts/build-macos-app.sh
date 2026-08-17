#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
repository_root="${script_directory:h}"
macos_root="$repository_root/apps/macos"
distribution_root="$repository_root/dist"
app_bundle="$distribution_root/Polyglance.app"
app_executable="$app_bundle/Contents/MacOS/NativeTranslatorMac"
build_script_name="${0:t}"
should_reset_permissions=true

function usage() {
    print "Usage: $build_script_name [--preserve-permissions]"
    print ""
    print "By default, the development build stops the packaged app and resets"
    print "Accessibility, Screen Recording, and Microphone permissions after signing."
    print "Use --preserve-permissions for release/CI builds or to keep TCC state."
}

while (( $# > 0 )); do
    case "$1" in
        --preserve-permissions)
            should_reset_permissions=false
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            print -u2 "Unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac
    shift
done

function stop_packaged_app() {
    local running_processes
    running_processes="$(pgrep -f "^${app_executable}$" || true)"
    if [[ -z "$running_processes" ]]; then
        return
    fi

    print "Stopping the currently running packaged app..."
    local process_id
    for process_id in ${(f)running_processes}; do
        kill "$process_id"
    done

    local stop_attempt
    for stop_attempt in {1..20}; do
        if ! pgrep -f "^${app_executable}$" >/dev/null; then
            return
        fi
        sleep 0.1
    done

    print -u2 "Polyglance did not stop; aborting before replacing the app bundle."
    exit 1
}

function reset_development_permissions() {
    local bundle_identifier
    bundle_identifier="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' \
        "$app_bundle/Contents/Info.plist")"
    if [[ -z "$bundle_identifier" ]]; then
        print -u2 "Unable to read CFBundleIdentifier; permissions were not reset."
        exit 1
    fi

    local permission_service
    for permission_service in Accessibility ScreenCapture Microphone; do
        /usr/bin/tccutil reset "$permission_service" "$bundle_identifier"
    done

    print "Cleared Accessibility, Screen Recording, and Microphone permissions for $bundle_identifier"
    print "Launch the app manually, then add the permissions again in System Settings."
}

stop_packaged_app

"$script_directory/build-macos-core.sh"
swift build --package-path "$macos_root" --configuration release
binary_directory="$(swift build --package-path "$macos_root" --configuration release --show-bin-path)"

if [[ -e "$app_bundle" ]]; then
    rm -rf "$app_bundle"
fi

mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
cp "$binary_directory/NativeTranslatorMac" "$app_bundle/Contents/MacOS/NativeTranslatorMac"
cp "$macos_root/Resources/Info.plist" "$app_bundle/Contents/Info.plist"
cp "$macos_root/Resources/Polyglance.icns" "$app_bundle/Contents/Resources/Polyglance.icns"

sparkle_framework="$macos_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [[ ! -d "$sparkle_framework" ]]; then
    print -u2 "Sparkle.framework was not resolved by Swift Package Manager."
    exit 1
fi
mkdir -p "$app_bundle/Contents/Frameworks"
ditto "$sparkle_framework" "$app_bundle/Contents/Frameworks/Sparkle.framework"

info_plist="$app_bundle/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$info_plist"
fi
if [[ -n "${APP_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_BUILD_NUMBER" "$info_plist"
fi

if [[ -n "${POLYGLANCE_FREE_AI_API_KEY:-}" ]]; then
    free_ai_endpoint="${POLYGLANCE_FREE_AI_ENDPOINT:-https://openrouter.ai/api/v1}"
    free_ai_model="${POLYGLANCE_FREE_AI_MODEL:-openrouter/free}"
    if [[ "$free_ai_endpoint" != https://* ]] \
        || [[ ! "$free_ai_endpoint" =~ '^[A-Za-z0-9._~:/?&=#%-]+$' ]]; then
        print -u2 "POLYGLANCE_FREE_AI_ENDPOINT must be a valid HTTPS URL."
        exit 1
    fi
    if [[ ! "$POLYGLANCE_FREE_AI_API_KEY" =~ '^[A-Za-z0-9._:-]+$' ]]; then
        print -u2 "POLYGLANCE_FREE_AI_API_KEY contains unsupported characters."
        exit 1
    fi
    if [[ ! "$free_ai_model" =~ '^[A-Za-z0-9._:/-]+$' ]]; then
        print -u2 "POLYGLANCE_FREE_AI_MODEL contains unsupported characters."
        exit 1
    fi
    /usr/libexec/PlistBuddy \
        -c "Add :PolyglanceFreeAIAPIKey string $POLYGLANCE_FREE_AI_API_KEY" \
        "$info_plist"
    /usr/libexec/PlistBuddy \
        -c "Add :PolyglanceFreeAIEndpoint string $free_ai_endpoint" \
        "$info_plist"
    /usr/libexec/PlistBuddy \
        -c "Add :PolyglanceFreeAIModel string $free_ai_model" \
        "$info_plist"
    print "Configured the bundled free AI translation service."
fi

if [[ -n "${POLYGLANCE_APPCAST_URL:-}" ]]; then
    if [[ "$POLYGLANCE_APPCAST_URL" != https://* ]]; then
        print -u2 "POLYGLANCE_APPCAST_URL must use HTTPS."
        exit 1
    fi
    sparkle_public_key="${SPARKLE_PUBLIC_ED_KEY:-$(tr -d '\n' < "$repository_root/config/sparkle-public-key.txt")}"
    if [[ -z "$sparkle_public_key" ]]; then
        print -u2 "A Sparkle public EdDSA key is required when an appcast URL is configured."
        exit 1
    fi
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $POLYGLANCE_APPCAST_URL" "$info_plist"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $sparkle_public_key" "$info_plist"
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$info_plist"
    /usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 86400" "$info_plist"
    /usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" "$info_plist"
    /usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$info_plist"
fi

codesign_identity="${CODESIGN_IDENTITY:--}"
if [[ "$codesign_identity" == "-" ]]; then
    codesign --force --deep --sign - "$app_bundle"
else
    codesign_certificate_sha1="${CODESIGN_CERTIFICATE_SHA1:-}"
    if [[ ! "$codesign_certificate_sha1" =~ '^[A-Fa-f0-9]{40}$' ]]; then
        print -u2 "CODESIGN_CERTIFICATE_SHA1 must be the persistent signing certificate SHA-1."
        exit 1
    fi
    codesign_certificate_sha1="${codesign_certificate_sha1:u}"

    installed_certificate_sha1="$(security find-certificate \
        -c "$codesign_identity" \
        -Z 2>/dev/null \
        | awk '/SHA-1 hash:/ { print $3; exit }')"
    if [[ "$installed_certificate_sha1" != "$codesign_certificate_sha1" ]]; then
        print -u2 "The selected code-signing identity does not match the pinned certificate."
        exit 1
    fi

    codesign_timestamp_mode="${CODESIGN_TIMESTAMP_MODE:-secure}"
    codesign_arguments=(--force --sign "$codesign_identity")
    case "$codesign_timestamp_mode" in
        none)
            ;;
        secure)
            codesign_arguments+=(--timestamp)
            ;;
        *)
            print -u2 "CODESIGN_TIMESTAMP_MODE must be either 'none' or 'secure'."
            exit 1
            ;;
    esac

    bundle_identifier="$(/usr/libexec/PlistBuddy \
        -c 'Print :CFBundleIdentifier' \
        "$info_plist")"
    if [[ "$bundle_identifier" != "io.polyglance.macos" ]]; then
        print -u2 "The persistent code-signing requirement expects io.polyglance.macos."
        exit 1
    fi
    codesign_requirement_expression="identifier \"$bundle_identifier\" and certificate leaf = H\"$codesign_certificate_sha1\""
    codesign_requirement="designated => $codesign_requirement_expression"

    # Sign nested code first with its own synthesized requirements, then
    # re-sign only the outer app with the stable TCC identity requirement.
    codesign --deep "${codesign_arguments[@]}" "$app_bundle"
    codesign "${codesign_arguments[@]}" \
        --requirements "=$codesign_requirement" \
        "$app_bundle"
    codesign --verify --deep --strict --verbose=2 "$app_bundle"
    codesign --verify --strict -R "=$codesign_requirement_expression" "$app_bundle"
fi

if $should_reset_permissions; then
    reset_development_permissions
else
    print "Preserved existing macOS privacy permissions."
fi

echo "Built $app_bundle"
