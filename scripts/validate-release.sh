#!/bin/bash
# Central release policy for LocalFlow.
#
# Commands:
#   preflight  Validate the requested build and emit workflow outputs.
#   artifacts  Validate the complete set of files before publication.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

write_output() {
    local key="$1"
    local value="$2"
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
    else
        printf '%s=%s\n' "$key" "$value"
    fi
}

require_value() {
    local name="$1"
    [[ -n "${!name:-}" ]] || fail "$name is required for a tagged release"
}

parse_release_tag() {
    local tag="$1"
    local prerelease_label=""
    local prerelease_number=""

    if [[ ! "$tag" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)(-([A-Za-z]+)\.([0-9]+))?$ ]]; then
        fail "release tag must use vMAJOR.MINOR.PATCH or a supported pre-release suffix"
    fi

    RELEASE_MAJOR="${BASH_REMATCH[1]}"
    RELEASE_MINOR="${BASH_REMATCH[2]}"
    RELEASE_PATCH="${BASH_REMATCH[3]}"
    prerelease_label="${BASH_REMATCH[5]:-}"
    prerelease_number="${BASH_REMATCH[6]:-}"

    for component in "$RELEASE_MAJOR" "$RELEASE_MINOR" "$RELEASE_PATCH"; do
        if [[ ${#component} -gt 1 && "$component" == 0* ]]; then
            fail "release tag has a numeric component with a leading zero"
        fi
    done

    # Apple's CFBundleVersion permits four digits in the first component and
    # two in the second and third. Its development suffix permits three digits.
    if (( 10#$RELEASE_MAJOR > 9999 || 10#$RELEASE_MINOR > 99 || 10#$RELEASE_PATCH > 99 )); then
        fail "release tag cannot be represented safely as CFBundleVersion"
    fi

    RELEASE_SHORT_VERSION="$RELEASE_MAJOR.$RELEASE_MINOR.$RELEASE_PATCH"
    RELEASE_BUNDLE_VERSION="$RELEASE_SHORT_VERSION"
    if [[ -n "$prerelease_label" ]]; then
        if [[ ${#prerelease_number} -gt 1 && "$prerelease_number" == 0* ]]; then
            fail "pre-release build number has a leading zero"
        fi
        if (( 10#$prerelease_number == 0 || 10#$prerelease_number > 999 )); then
            fail "pre-release build number cannot be represented safely as CFBundleVersion"
        fi
        case "$prerelease_label" in
            alpha) RELEASE_BUNDLE_VERSION="${RELEASE_SHORT_VERSION}a${prerelease_number}" ;;
            beta) RELEASE_BUNDLE_VERSION="${RELEASE_SHORT_VERSION}b${prerelease_number}" ;;
            rc) RELEASE_BUNDLE_VERSION="${RELEASE_SHORT_VERSION}fc${prerelease_number}" ;;
            *) fail "unsupported pre-release label '$prerelease_label'; use alpha, beta, or rc" ;;
        esac
    fi

    RELEASE_VERSION="${tag#v}"
}

find_sparkle_framework() {
    find "$REPO_ROOT/.build/artifacts" -type d -name Sparkle.framework -path '*macos*' -print -quit 2>/dev/null || true
}

find_appcast_tool() {
    find "$REPO_ROOT/.build/artifacts" -type f -name generate_appcast -perm -u+x -print -quit 2>/dev/null || true
}

find_sign_update_tool() {
    find "$REPO_ROOT/.build/artifacts/sparkle/Sparkle/bin" \
        -type f -name sign_update -perm -u+x -print -quit 2>/dev/null || true
}

validate_source_plist() {
    local plist="${SPARKLE_INFO_PLIST:-$REPO_ROOT/Resources/Info.plist}"
    [[ -f "$plist" ]] || fail "Resources/Info.plist is missing"
    plutil -lint "$plist" >/dev/null || fail "Resources/Info.plist is invalid"

    local feed_url
    local public_key
    feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$plist" 2>/dev/null || true)"
    public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$plist" 2>/dev/null || true)"
    [[ "$feed_url" == https://* ]] || fail "Info.plist must contain an HTTPS SUFeedURL"
    [[ -n "$public_key" ]] || fail "Info.plist must contain SUPublicEDKey"

    SOURCE_SPARKLE_PUBLIC_KEY="$public_key"
}

validate_sparkle_signing_key() {
    local decoded_key
    if ! decoded_key="$(SPARKLE_PRIVATE_KEY="$SPARKLE_PRIVATE_KEY" swift -e '
        import CryptoKit
        import Foundation

        guard let encodedKey = ProcessInfo.processInfo.environment["SPARKLE_PRIVATE_KEY"] else {
            exit(1)
        }
        let normalizedKey = encodedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let secret = Data(base64Encoded: normalizedKey) else {
            exit(1)
        }

        let publicKey: Data
        switch secret.count {
        case 32:
            guard let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret) else {
                exit(1)
            }
            publicKey = privateKey.publicKey.rawRepresentation
        case 96:
            // The legacy Sparkle export is its 64-byte Ed25519 private key
            // followed by the corresponding 32-byte public key.
            publicKey = secret.suffix(32)
        default:
            exit(1)
        }
        print("\(secret.count) \(publicKey.base64EncodedString())")
    ' 2>/dev/null)"; then
        fail "SPARKLE_PRIVATE_KEY must be a valid Sparkle Ed25519 export"
    fi

    local key_size="${decoded_key%% *}"
    local derived_public_key="${decoded_key#* }"
    [[ "$derived_public_key" == "$SOURCE_SPARKLE_PUBLIC_KEY" ]] || \
        fail "SPARKLE_PRIVATE_KEY does not match Info.plist SUPublicEDKey"

    [[ "$key_size" == 96 ]] || return 0

    local sign_update
    sign_update="$(find_sign_update_tool)"
    [[ -x "$sign_update" ]] || \
        fail "pinned Sparkle sign_update is required to validate a legacy signing key"

    local probe
    local signature
    probe="$(mktemp "${TMPDIR:-/tmp}/localflow-sparkle-key.XXXXXX")"
    printf 'LocalFlow Sparkle legacy key validation probe\n' > "$probe"
    if ! signature="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | \
        "$sign_update" --ed-key-file - -p "$probe" 2>/dev/null)"; then
        rm -f "$probe"
        fail "Sparkle signing key private/public mismatch"
    fi

    if ! SPARKLE_PUBLIC_KEY="$SOURCE_SPARKLE_PUBLIC_KEY" \
        SPARKLE_TEST_SIGNATURE="$signature" \
        swift -e '
            import CryptoKit
            import Foundation

            let environment = ProcessInfo.processInfo.environment
            guard let encodedPublicKey = environment["SPARKLE_PUBLIC_KEY"],
                  let publicKeyData = Data(base64Encoded: encodedPublicKey),
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData),
                  let encodedSignature = environment["SPARKLE_TEST_SIGNATURE"],
                  let signature = Data(base64Encoded: encodedSignature),
                  let probe = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])),
                  publicKey.isValidSignature(signature, for: probe) else {
                exit(1)
            }
        ' "$probe" 2>/dev/null
    then
        rm -f "$probe"
        fail "Sparkle signing key private/public mismatch"
    fi
    rm -f "$probe"
}

preflight() {
    local tag="${RELEASE_TAG:-}"
    local framework="${SPARKLE_FRAMEWORK_PATH:-}"
    local appcast_tool="${SPARKLE_APPCAST_TOOL:-}"

    if [[ -z "$tag" ]]; then
        local short_sha="${COMMIT_SHA:-dev}"
        short_sha="${short_sha:0:7}"
        write_output is_release false
        write_output sign false
        write_output updater false
        write_output tag ""
        write_output version "0.0.0-dev.$short_sha"
        write_output short_version "0.0.0"
        write_output bundle_version "0.0.0"
        return
    fi

    parse_release_tag "$tag"
    for input in \
        MAC_CERT_P12_BASE64 \
        MAC_CERT_PASSWORD \
        APPLE_ID \
        APPLE_APP_SPECIFIC_PASSWORD \
        APPLE_TEAM_ID \
        SPARKLE_PRIVATE_KEY
    do
        require_value "$input"
    done

    [[ -n "$framework" ]] || framework="$(find_sparkle_framework)"
    [[ -d "$framework" ]] || fail "Sparkle.framework is required for a tagged release"

    [[ -n "$appcast_tool" ]] || appcast_tool="$(find_appcast_tool)"
    [[ -x "$appcast_tool" ]] || fail "generate_appcast is required for a tagged release"

    validate_source_plist
    validate_sparkle_signing_key

    write_output is_release true
    write_output sign true
    write_output updater true
    write_output tag "$tag"
    write_output version "$RELEASE_VERSION"
    write_output short_version "$RELEASE_SHORT_VERSION"
    write_output bundle_version "$RELEASE_BUNDLE_VERSION"
    write_output sparkle_framework "$framework"
    write_output appcast_tool "$appcast_tool"
}

require_artifact() {
    local path="$1"
    [[ -f "$path" ]] || fail "required release artifact is missing: $(basename "$path")"
}

manifest_contains() {
    local manifest="$1"
    local name="$2"
    grep -Eq "[[:space:]]${name//./\\.}$" "$manifest" || \
        fail "SHA256SUMS.txt does not cover $name"
}

validate_artifacts() {
    local tag="${RELEASE_TAG:-}"
    [[ -n "$tag" ]] || return 0

    parse_release_tag "$tag"
    local version="${APP_VERSION:-}"
    [[ "$version" == "$RELEASE_VERSION" ]] || \
        fail "APP_VERSION must match release tag version $RELEASE_VERSION"

    local dist="${DIST_DIR:-$REPO_ROOT/dist}"
    local dmg="LocalFlow-${version}.dmg"
    local archive="LocalFlow-${version}.zip"
    local appcast="appcast.xml"
    local checksums="SHA256SUMS.txt"
    local setup="setup-s1-mini.sh"

    for name in "$dmg" "$archive" "$appcast" "$checksums" "$setup"; do
        require_artifact "$dist/$name"
    done

    local expected_archive_path="/releases/download/$tag/$archive"
    grep -Fq "$expected_archive_path" "$dist/$appcast" || \
        fail "appcast.xml does not name $archive at the tagged release URL"
    grep -Eq 'sparkle:edSignature="[^"]+"' "$dist/$appcast" || \
        fail "appcast.xml does not contain a non-empty edSignature"

    manifest_contains "$dist/$checksums" "$dmg"
    manifest_contains "$dist/$checksums" "$archive"
    manifest_contains "$dist/$checksums" "$setup"
    if [[ "${VERIFY_CHECKSUMS:-false}" == "true" ]]; then
        (cd "$dist" && shasum -a 256 -c "$checksums") || \
            fail "SHA256SUMS.txt does not match the release artifacts"
    fi

    if [[ -n "${APP_BUNDLE_PATH:-}" ]]; then
        local bundle_plist="$APP_BUNDLE_PATH/Contents/Info.plist"
        require_artifact "$bundle_plist"
        plutil -lint "$bundle_plist" >/dev/null || fail "built app Info.plist is invalid"

        local actual_short_version
        local actual_bundle_version
        actual_short_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle_plist")"
        actual_bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle_plist")"
        [[ "$actual_short_version" == "$RELEASE_SHORT_VERSION" ]] || \
            fail "built app has the wrong CFBundleShortVersionString"
        [[ "$actual_bundle_version" == "$RELEASE_BUNDLE_VERSION" ]] || \
            fail "built app has the wrong CFBundleVersion"
        [[ -d "$APP_BUNDLE_PATH/Contents/Frameworks/Sparkle.framework" ]] || \
            fail "built app is missing Sparkle.framework"

        local built_feed_url
        local built_public_key
        local automatic_checks
        built_feed_url="$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$bundle_plist" 2>/dev/null || true)"
        built_public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$bundle_plist" 2>/dev/null || true)"
        automatic_checks="$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$bundle_plist" 2>/dev/null || true)"
        [[ "$built_feed_url" == https://* ]] || fail "built app has no HTTPS SUFeedURL"
        [[ -n "$built_public_key" ]] || fail "built app has no SUPublicEDKey"
        [[ "$automatic_checks" == "true" ]] || fail "built app does not enable update checks"
    fi
}

case "${1:-}" in
    preflight) preflight ;;
    artifacts) validate_artifacts ;;
    *) fail "usage: $0 {preflight|artifacts}" ;;
esac
