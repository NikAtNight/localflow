#!/bin/bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate-release.sh"
RELEASE_WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/localflow-release-contract.XXXXXX")"
DIST_DIR="$TEST_ROOT/dist"
FRAMEWORK_PATH="$TEST_ROOT/Sparkle.framework"
APPCAST_TOOL="$TEST_ROOT/generate_appcast"
OUTPUT_FILE="$TEST_ROOT/github-output"
STDOUT_FILE="$TEST_ROOT/stdout"
STDERR_FILE="$TEST_ROOT/stderr"
PASS_COUNT=0
FAIL_COUNT=0
LAST_STATUS=0

trap 'rm -rf "$TEST_ROOT"' EXIT

unset RELEASE_TAG COMMIT_SHA
unset MAC_CERT_P12_BASE64 MAC_CERT_PASSWORD
unset APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID
unset SPARKLE_PRIVATE_KEY SPARKLE_FRAMEWORK_PATH SPARKLE_APPCAST_TOOL
unset APP_VERSION APP_BUNDLE_PATH VALIDATION_DIST_DIR VERIFY_CHECKSUMS

fail() {
    printf '    %s\n' "$*" >&2
    return 1
}

assert_success() {
    if [[ "$LAST_STATUS" -ne 0 ]]; then
        sed 's/^/    stderr: /' "$STDERR_FILE" >&2
        fail "expected success, got exit status $LAST_STATUS"
    fi
}

assert_failure_containing() {
    local expected="$1"
    if [[ "$LAST_STATUS" -eq 0 ]]; then
        fail "expected failure mentioning $expected"
        return
    fi
    if ! grep -Fq "$expected" "$STDERR_FILE"; then
        sed 's/^/    stderr: /' "$STDERR_FILE" >&2
        fail "failure did not mention $expected"
    fi
}

assert_output() {
    local expected="$1"
    if ! grep -Fxq "$expected" "$OUTPUT_FILE"; then
        sed 's/^/    output: /' "$OUTPUT_FILE" >&2
        fail "missing output: $expected"
    fi
}

assert_file_contains() {
    local path="$1"
    local expected="$2"
    if ! grep -Fq "$expected" "$path"; then
        fail "missing $expected in ${path#$REPO_ROOT/}"
    fi
}

run_test() {
    local name="$1"
    local number=$((PASS_COUNT + FAIL_COUNT + 1))
    shift
    if "$@"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'ok %d - %s\n' "$number" "$name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'not ok %d - %s\n' "$number" "$name"
    fi
}

reset_tool_fixture() {
    mkdir -p "$FRAMEWORK_PATH"
    printf '#!/bin/bash\nexit 0\n' > "$APPCAST_TOOL"
    chmod +x "$APPCAST_TOOL"
}

run_preflight() {
    : > "$OUTPUT_FILE"
    : > "$STDOUT_FILE"
    : > "$STDERR_FILE"

    env -i \
        PATH="$PATH" \
        HOME="${HOME:-/tmp}" \
        GITHUB_OUTPUT="$OUTPUT_FILE" \
        RELEASE_TAG="${RELEASE_TAG-v1.2.3}" \
        COMMIT_SHA="${COMMIT_SHA-0123456789abcdef0123456789abcdef01234567}" \
        MAC_CERT_P12_BASE64="${MAC_CERT_P12_BASE64-test-certificate}" \
        MAC_CERT_PASSWORD="${MAC_CERT_PASSWORD-test-password}" \
        APPLE_ID="${APPLE_ID-release@example.com}" \
        APPLE_APP_SPECIFIC_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD-test-app-password}" \
        APPLE_TEAM_ID="${APPLE_TEAM_ID-TESTTEAM01}" \
        SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY-test-sparkle-key}" \
        SPARKLE_FRAMEWORK_PATH="${SPARKLE_FRAMEWORK_PATH-$FRAMEWORK_PATH}" \
        SPARKLE_APPCAST_TOOL="${SPARKLE_APPCAST_TOOL-$APPCAST_TOOL}" \
        "$VALIDATOR" preflight > "$STDOUT_FILE" 2> "$STDERR_FILE"
    LAST_STATUS=$?
}

write_appcast() {
    local archive_name="${1:-LocalFlow-1.2.3.zip}"
    local signature="${2-test-signature}"
    printf '%s\n' \
        '<?xml version="1.0" encoding="utf-8"?>' \
        '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">' \
        '  <channel>' \
        '    <item>' \
        "      <enclosure url=\"https://github.com/NikAtNight/localflow/releases/download/v1.2.3/$archive_name\" sparkle:edSignature=\"$signature\" />" \
        '    </item>' \
        '  </channel>' \
        '</rss>' > "$DIST_DIR/appcast.xml"
}

reset_artifact_fixture() {
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    printf 'dmg\n' > "$DIST_DIR/LocalFlow-1.2.3.dmg"
    printf 'zip\n' > "$DIST_DIR/LocalFlow-1.2.3.zip"
    printf '#!/bin/bash\n' > "$DIST_DIR/setup-s1-mini.sh"
    write_appcast
    printf '%s\n' \
        'test  LocalFlow-1.2.3.dmg' \
        'test  LocalFlow-1.2.3.zip' \
        'test  setup-s1-mini.sh' > "$DIST_DIR/SHA256SUMS.txt"
}

run_artifact_validation() {
    : > "$STDOUT_FILE"
    : > "$STDERR_FILE"

    env -i \
        PATH="$PATH" \
        HOME="${HOME:-/tmp}" \
        RELEASE_TAG="${RELEASE_TAG-v1.2.3}" \
        APP_VERSION="${APP_VERSION-1.2.3}" \
        DIST_DIR="${VALIDATION_DIST_DIR-$DIST_DIR}" \
        VERIFY_CHECKSUMS="${VERIFY_CHECKSUMS-false}" \
        APP_BUNDLE_PATH="${APP_BUNDLE_PATH-}" \
        "$VALIDATOR" artifacts > "$STDOUT_FILE" 2> "$STDERR_FILE"
    LAST_STATUS=$?
}

reset_app_bundle_fixture() {
    APP_BUNDLE_PATH="$TEST_ROOT/LocalFlow.app"
    rm -rf "$APP_BUNDLE_PATH"
    mkdir -p "$APP_BUNDLE_PATH/Contents/Frameworks/Sparkle.framework"
    cp "$REPO_ROOT/Resources/Info.plist" "$APP_BUNDLE_PATH/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleShortVersionString 1.2.3' \
        "$APP_BUNDLE_PATH/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 1.2.3' \
        "$APP_BUNDLE_PATH/Contents/Info.plist"
}

test_tagged_preflight() {
    reset_tool_fixture
    run_preflight
    assert_success || return
    assert_output 'is_release=true' || return
    assert_output 'sign=true' || return
    assert_output 'updater=true' || return
    assert_output 'version=1.2.3' || return
    assert_output 'short_version=1.2.3' || return
    assert_output 'bundle_version=1.2.3'
}

test_development_preflight() {
    RELEASE_TAG='' \
    MAC_CERT_P12_BASE64='' \
    MAC_CERT_PASSWORD='' \
    APPLE_ID='' \
    APPLE_APP_SPECIFIC_PASSWORD='' \
    APPLE_TEAM_ID='' \
    SPARKLE_PRIVATE_KEY='' \
    SPARKLE_FRAMEWORK_PATH="$TEST_ROOT/missing-framework" \
    SPARKLE_APPCAST_TOOL="$TEST_ROOT/missing-generate-appcast" \
        run_preflight
    assert_success || return
    assert_output 'is_release=false' || return
    assert_output 'sign=false' || return
    assert_output 'updater=false'
}

test_missing_release_input() {
    local variable="$1"
    reset_tool_fixture
    case "$variable" in
        MAC_CERT_P12_BASE64) MAC_CERT_P12_BASE64='' run_preflight ;;
        MAC_CERT_PASSWORD) MAC_CERT_PASSWORD='' run_preflight ;;
        APPLE_ID) APPLE_ID='' run_preflight ;;
        APPLE_APP_SPECIFIC_PASSWORD) APPLE_APP_SPECIFIC_PASSWORD='' run_preflight ;;
        APPLE_TEAM_ID) APPLE_TEAM_ID='' run_preflight ;;
        SPARKLE_PRIVATE_KEY) SPARKLE_PRIVATE_KEY='' run_preflight ;;
        *) fail "unknown release input: $variable"; return ;;
    esac
    assert_failure_containing "$variable"
}

test_missing_sparkle_framework() {
    reset_tool_fixture
    SPARKLE_FRAMEWORK_PATH="$TEST_ROOT/missing-framework" run_preflight
    assert_failure_containing 'Sparkle.framework'
}

test_missing_sparkle_tool() {
    reset_tool_fixture
    SPARKLE_APPCAST_TOOL="$TEST_ROOT/missing-generate-appcast" run_preflight
    assert_failure_containing 'generate_appcast'
}

test_prerelease_version_mapping() {
    reset_tool_fixture
    RELEASE_TAG='v1.2.3-beta.4' run_preflight
    assert_success || return
    assert_output 'version=1.2.3-beta.4' || return
    assert_output 'short_version=1.2.3' || return
    assert_output 'bundle_version=1.2.3b4'
}

test_unsupported_prerelease() {
    reset_tool_fixture
    RELEASE_TAG='v1.2.3-preview.1' run_preflight
    assert_failure_containing 'pre-release'
}

test_unsafe_bundle_version() {
    reset_tool_fixture
    RELEASE_TAG='v10000.1.1' run_preflight
    assert_failure_containing 'CFBundleVersion'
}

test_complete_artifacts() {
    reset_artifact_fixture
    run_artifact_validation
    assert_success
}

test_each_required_artifact() {
    local path
    for path in \
        'LocalFlow-1.2.3.dmg' \
        'LocalFlow-1.2.3.zip' \
        'appcast.xml' \
        'SHA256SUMS.txt' \
        'setup-s1-mini.sh'
    do
        reset_artifact_fixture
        rm "$DIST_DIR/$path"
        run_artifact_validation
        assert_failure_containing "$path" || return
    done
}

test_appcast_archive_name() {
    reset_artifact_fixture
    write_appcast 'LocalFlow-1.2.2.zip'
    run_artifact_validation
    assert_failure_containing 'LocalFlow-1.2.3.zip'
}

test_appcast_signature() {
    reset_artifact_fixture
    write_appcast 'LocalFlow-1.2.3.zip' ''
    run_artifact_validation
    assert_failure_containing 'edSignature'
}

test_checksum_manifest_coverage() {
    reset_artifact_fixture
    printf 'test  LocalFlow-1.2.3.dmg\n' > "$DIST_DIR/SHA256SUMS.txt"
    run_artifact_validation
    assert_failure_containing 'LocalFlow-1.2.3.zip'
}

test_checksum_contents() {
    reset_artifact_fixture
    (
        cd "$DIST_DIR"
        shasum -a 256 LocalFlow-1.2.3.dmg LocalFlow-1.2.3.zip setup-s1-mini.sh > SHA256SUMS.txt
    )
    printf 'changed archive\n' > "$DIST_DIR/LocalFlow-1.2.3.zip"
    VERIFY_CHECKSUMS=true run_artifact_validation
    assert_failure_containing 'SHA256SUMS.txt does not match the release artifacts'
}

test_app_bundle_version() {
    reset_artifact_fixture
    reset_app_bundle_fixture
    /usr/libexec/PlistBuddy -c 'Set :CFBundleVersion 9.9.9' \
        "$APP_BUNDLE_PATH/Contents/Info.plist"
    run_artifact_validation
    assert_failure_containing 'built app has the wrong CFBundleVersion'
}

test_release_source_is_main_ancestry() {
    assert_file_contains "$RELEASE_WORKFLOW" 'git merge-base --is-ancestor "$COMMIT_SHA" "origin/main"'
}

test_existing_draft_targets_requested_commit() {
    assert_file_contains "$RELEASE_WORKFLOW" \
        'EXISTING_TARGET="$(gh release view "$RELEASE_TAG" --json targetCommitish --jq .targetCommitish)"' || return
    assert_file_contains "$RELEASE_WORKFLOW" '[[ "$EXISTING_TARGET" == "$COMMIT_SHA" ]]'
}

test_existing_tag_targets_requested_commit() {
    assert_file_contains "$RELEASE_WORKFLOW" \
        'TAG_TARGET="$(git rev-parse "$RELEASE_TAG^{commit}")"' || return
    assert_file_contains "$RELEASE_WORKFLOW" '[[ "$TAG_TARGET" == "$COMMIT_SHA" ]]'
}

test_release_workflow_validates_before_publication() {
    local validate_line
    local draft_line
    validate_line="$(grep -n -m1 'name: Validate release artifacts' "$RELEASE_WORKFLOW" | cut -d: -f1)"
    draft_line="$(grep -n -m1 'name: Create verified draft release' "$RELEASE_WORKFLOW" | cut -d: -f1)"
    [[ -n "$validate_line" && -n "$draft_line" && "$validate_line" -lt "$draft_line" ]] || \
        fail 'release artifact validation must run before draft creation'
    assert_file_contains "$RELEASE_WORKFLOW" 'APP_BUNDLE_PATH: build/LocalFlow.app' || return
    assert_file_contains "$RELEASE_WORKFLOW" 'VERIFY_CHECKSUMS: "true"'
}

test_development_artifacts_are_optional() {
    VALIDATION_DIST_DIR="$TEST_ROOT/missing-dist" RELEASE_TAG='' APP_VERSION='dev' \
        run_artifact_validation
    assert_success
}

if [[ ! -x "$VALIDATOR" ]]; then
    printf 'not ok 1 - release validator exists\n' >&2
    printf '    expected executable: %s\n' "$VALIDATOR" >&2
    printf '    The release contract tests were added before its implementation.\n' >&2
    exit 1
fi

run_test 'tagged preflight enables signing and updates' test_tagged_preflight
run_test 'development preflight permits unsigned builds without updates' test_development_preflight

for input in \
    MAC_CERT_P12_BASE64 \
    MAC_CERT_PASSWORD \
    APPLE_ID \
    APPLE_APP_SPECIFIC_PASSWORD \
    APPLE_TEAM_ID \
    SPARKLE_PRIVATE_KEY
do
    run_test "tagged preflight rejects missing $input" test_missing_release_input "$input"
done

run_test 'tagged preflight requires Sparkle.framework' test_missing_sparkle_framework
run_test 'tagged preflight requires generate_appcast' test_missing_sparkle_tool
run_test 'supported pre-release tags map to plist-safe versions' test_prerelease_version_mapping
run_test 'unsupported pre-release labels fail closed' test_unsupported_prerelease
run_test 'oversized bundle version components fail closed' test_unsafe_bundle_version
run_test 'complete tagged release artifacts pass validation' test_complete_artifacts
run_test 'every tagged release artifact is required' test_each_required_artifact
run_test 'appcast names the exact versioned ZIP' test_appcast_archive_name
run_test 'appcast carries a Sparkle signature' test_appcast_signature
run_test 'checksum manifest covers the update ZIP' test_checksum_manifest_coverage
run_test 'checksum manifest matches the release artifacts' test_checksum_contents
run_test 'built app bundle version matches the release tag' test_app_bundle_version
run_test 'development builds do not require release artifacts' test_development_artifacts_are_optional
run_test 'release source commit is reachable from origin/main' test_release_source_is_main_ancestry
run_test 'existing draft release targets the requested commit' test_existing_draft_targets_requested_commit
run_test 'existing tag targets the requested commit' test_existing_tag_targets_requested_commit
run_test 'release workflow validates artifacts before publication' test_release_workflow_validates_before_publication

printf '%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
