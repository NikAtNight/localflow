#!/bin/bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate-release.sh"
RELEASE_WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
RELEASE_PLEASE_WORKFLOW="$REPO_ROOT/.github/workflows/release-please.yml"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/localflow-release-contract.XXXXXX")"
DIST_DIR="$TEST_ROOT/dist"
FRAMEWORK_PATH="$TEST_ROOT/Sparkle.framework"
APPCAST_TOOL="$TEST_ROOT/generate_appcast"
INFO_PLIST="$TEST_ROOT/Info.plist"
DETECTION_REPO="$TEST_ROOT/release-detection"
DETECTION_SCRIPT="$TEST_ROOT/detect-merged-release.sh"
OUTPUT_FILE="$TEST_ROOT/github-output"
STDOUT_FILE="$TEST_ROOT/stdout"
STDERR_FILE="$TEST_ROOT/stderr"
PASS_COUNT=0
FAIL_COUNT=0
LAST_STATUS=0

# RFC 8032 test vectors encoded in Sparkle's modern base64 seed/public-key
# format. They let the contract exercise real key identity without touching a
# developer's Keychain or using the production signing secret.
MATCHING_PRIVATE_KEY='nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A='
MATCHING_PUBLIC_KEY='11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo='
MISMATCHED_PRIVATE_KEY='TM0Imyj/ltqdtsNG7BFOD1uKMZ81q6Yk2oz27U+4pvs='

trap 'rm -rf "$TEST_ROOT"' EXIT

unset RELEASE_TAG COMMIT_SHA
unset MAC_CERT_P12_BASE64 MAC_CERT_PASSWORD
unset APPLE_ID APPLE_APP_SPECIFIC_PASSWORD APPLE_TEAM_ID
unset SPARKLE_PRIVATE_KEY SPARKLE_FRAMEWORK_PATH SPARKLE_APPCAST_TOOL SPARKLE_INFO_PLIST
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
    cp "$REPO_ROOT/Resources/Info.plist" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $MATCHING_PUBLIC_KEY" "$INFO_PLIST"
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
        SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY-$MATCHING_PRIVATE_KEY}" \
        SPARKLE_FRAMEWORK_PATH="${SPARKLE_FRAMEWORK_PATH-$FRAMEWORK_PATH}" \
        SPARKLE_APPCAST_TOOL="${SPARKLE_APPCAST_TOOL-$APPCAST_TOOL}" \
        SPARKLE_INFO_PLIST="${SPARKLE_INFO_PLIST-$INFO_PLIST}" \
        "$VALIDATOR" preflight > "$STDOUT_FILE" 2> "$STDERR_FILE"
    LAST_STATUS=$?
}

extract_detection_script() {
    awk '
        /^      - name: Detect merged release PR$/ { in_step=1; next }
        in_step && /^      - name:/ { exit }
        in_step && /^        run: \|$/ { in_run=1; next }
        in_run && /^          / { sub(/^          /, ""); print; next }
        in_run && /^[[:space:]]*$/ { print; next }
        in_run { exit }
    ' "$RELEASE_PLEASE_WORKFLOW" > "$DETECTION_SCRIPT"
    chmod +x "$DETECTION_SCRIPT"
}

reset_detection_fixture() {
    rm -rf "$DETECTION_REPO"
    mkdir -p "$DETECTION_REPO/.github"
    git -C "$DETECTION_REPO" init -q -b main

    printf '{".":"1.0.0"}\n' > "$DETECTION_REPO/.github/.release-please-manifest.json"
    git -C "$DETECTION_REPO" add .github/.release-please-manifest.json
    git -C "$DETECTION_REPO" -c user.name=Tests -c user.email=tests@example.com \
        commit -qm 'initial release manifest'
    DETECTION_BEFORE_SHA="$(git -C "$DETECTION_REPO" rev-parse HEAD)"

    printf 'intervening change\n' > "$DETECTION_REPO/notes.txt"
    git -C "$DETECTION_REPO" add notes.txt
    git -C "$DETECTION_REPO" -c user.name=Tests -c user.email=tests@example.com \
        commit -qm 'intervening main commit'

    printf '{".":"1.1.0"}\n' > "$DETECTION_REPO/.github/.release-please-manifest.json"
    git -C "$DETECTION_REPO" add .github/.release-please-manifest.json
    git -C "$DETECTION_REPO" -c user.name=Tests -c user.email=tests@example.com \
        commit -qm 'merge release manifest'
    DETECTION_COMMIT_SHA="$(git -C "$DETECTION_REPO" rev-parse HEAD)"
}

run_release_detection() {
    local before_sha="$1"
    local commit_sha="$2"
    : > "$OUTPUT_FILE"
    : > "$STDOUT_FILE"
    : > "$STDERR_FILE"

    (
        cd "$DETECTION_REPO"
        env -i \
            PATH="$PATH" \
            HOME="${HOME:-/tmp}" \
            GITHUB_OUTPUT="$OUTPUT_FILE" \
            BEFORE_SHA="$before_sha" \
            COMMIT_SHA="$commit_sha" \
            bash "$DETECTION_SCRIPT"
    ) > "$STDOUT_FILE" 2> "$STDERR_FILE"
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

test_matching_sparkle_key() {
    reset_tool_fixture
    SPARKLE_PRIVATE_KEY="$MATCHING_PRIVATE_KEY" run_preflight
    assert_success
}

test_mismatched_sparkle_key() {
    reset_tool_fixture
    SPARKLE_PRIVATE_KEY="$MISMATCHED_PRIVATE_KEY" run_preflight
    assert_failure_containing 'SUPublicEDKey'
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

test_release_uses_typed_repository_dispatch() {
    assert_file_contains "$RELEASE_WORKFLOW" 'repository_dispatch:' || return
    if ! grep -Eq 'types:[[:space:]]*\[release-build\]|^[[:space:]]*-[[:space:]]+release-build$' "$RELEASE_WORKFLOW"; then
        fail 'release repository dispatch must only accept release-build events'
        return
    fi
    if grep -Fq 'workflow_dispatch:' "$RELEASE_WORKFLOW"; then
        fail 'release workflow must not accept workflow_dispatch'
    fi
}

test_release_please_dispatches_release_transition() {
    assert_file_contains "$RELEASE_PLEASE_WORKFLOW" 'gh api' || return
    assert_file_contains "$RELEASE_PLEASE_WORKFLOW" \
        'repos/${{ github.repository }}/dispatches' || return
    assert_file_contains "$RELEASE_PLEASE_WORKFLOW" 'event_type' || return
    assert_file_contains "$RELEASE_PLEASE_WORKFLOW" 'release-build' || return
    assert_file_contains "$RELEASE_PLEASE_WORKFLOW" \
        'client_payload[before_sha]=$BEFORE_SHA'
}

test_release_reads_trusted_dispatch_context() {
    local source_job
    local contract_step
    if grep -Fq '${{ inputs.' "$RELEASE_WORKFLOW"; then
        fail 'release state must not come from workflow inputs'
        return
    fi
    source_job="$(awk '
        /^  source:$/ { active=1 }
        /^  build:$/ { active=0 }
        active { print }
    ' "$RELEASE_WORKFLOW")"
    contract_step="$(awk '
        /- name: Validate release contract/ { active=1 }
        active && /- name: Import signing certificate/ { active=0 }
        active { print }
    ' "$RELEASE_WORKFLOW")"
    case "$source_job" in
        *'github.event.client_payload.before_sha'*'DISPATCH_SHA: ${{ github.sha }}'*) ;;
        *) fail 'source verification must use the claimed before revision and trusted dispatch SHA'; return ;;
    esac
    case "$source_job" in
        *'github.event.client_payload.tag'*|*'github.event.client_payload.commit_sha'*)
            fail 'source verification must not trust a payload tag or commit SHA'; return ;;
    esac
    case "$contract_step" in
        *'github.event.client_payload.tag'*|*'github.event.client_payload.commit_sha'*)
            fail 'release validation must use verified source outputs, not payload release state' ;;
    esac
}

test_destination_checks_precede_upload_and_publish() {
    local draft_step
    local publish_step
    draft_step="$(awk '
        /- name: Create verified draft release/ { active=1 }
        /- name: Publish complete release/ { active=0 }
        active { print }
    ' "$RELEASE_WORKFLOW")"
    publish_step="$(awk '
        /- name: Publish complete release/ { active=1 }
        active { print }
    ' "$RELEASE_WORKFLOW")"
    case "$draft_step" in
        *'EXISTING_TARGET'*'TAG_TARGET'*'gh release upload'*) ;;
        *) fail 'draft target and tag checks must run before upload'; return ;;
    esac
    case "$publish_step" in
        *'EXISTING_TARGET'*'TAG_TARGET'*'gh release edit'*) ;;
        *) fail 'draft target and tag checks must run before publication' ;;
    esac
}

test_artifact_validation_precedes_both_publication_steps() {
    local validate_line
    local upload_line
    local publish_line
    validate_line="$(grep -n -m1 'name: Validate release artifacts' "$RELEASE_WORKFLOW" | cut -d: -f1)"
    upload_line="$(grep -n -m1 'gh release upload' "$RELEASE_WORKFLOW" | cut -d: -f1)"
    publish_line="$(grep -n -m1 'name: Publish complete release' "$RELEASE_WORKFLOW" | cut -d: -f1)"
    [[ -n "$validate_line" && -n "$upload_line" && -n "$publish_line" && \
        "$validate_line" -lt "$upload_line" && "$validate_line" -lt "$publish_line" ]] || \
        fail 'artifact validation must run before upload and publication'
}

test_release_please_is_push_main_only() {
    assert_file_contains "$RELEASE_PLEASE_WORKFLOW" 'push:' || return
    assert_file_contains "$RELEASE_PLEASE_WORKFLOW" 'branches: [main]' || return
    if grep -Fq 'workflow_dispatch:' "$RELEASE_PLEASE_WORKFLOW"; then
        fail 'Release Please must not accept workflow_dispatch'
    fi
}

test_release_state_comes_from_verified_manifest_transition() {
    assert_file_contains "$RELEASE_WORKFLOW" \
        '.github/.release-please-manifest.json' || return
    assert_file_contains "$RELEASE_WORKFLOW" \
        'git diff --quiet "$BEFORE_SHA" "$COMMIT_SHA" -- "$MANIFEST"' || return
    assert_file_contains "$RELEASE_WORKFLOW" \
        "jq -er '.[\".\"]'" || return
    assert_file_contains "$RELEASE_WORKFLOW" \
        'release_tag: ${{ steps.source.outputs.tag }}' || return
    assert_file_contains "$RELEASE_WORKFLOW" \
        'RELEASE_TAG: ${{ needs.source.outputs.release_tag }}'
}

test_release_detection_fetches_complete_push_history() {
    assert_file_contains "$RELEASE_PLEASE_WORKFLOW" 'fetch-depth: 0'
}

test_multi_commit_release_push_is_detected() {
    extract_detection_script
    reset_detection_fixture
    run_release_detection "$DETECTION_BEFORE_SHA" "$DETECTION_COMMIT_SHA"
    assert_success || return
    assert_output 'created=true' || return
    assert_output 'tag=v1.1.0'
}

test_missing_before_revision_fails_closed() {
    extract_detection_script
    reset_detection_fixture
    run_release_detection 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$DETECTION_COMMIT_SHA"
    assert_failure_containing 'BEFORE_SHA' || return
    if grep -Fq 'created=true' "$OUTPUT_FILE"; then
        fail 'release detection dispatched after the before revision could not be verified'
    fi
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
run_test 'tagged preflight accepts the private key matching SUPublicEDKey' test_matching_sparkle_key
run_test 'tagged preflight rejects a private key that does not match SUPublicEDKey' test_mismatched_sparkle_key
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
run_test 'release uses a typed repository dispatch trigger' test_release_uses_typed_repository_dispatch
run_test 'Release Please dispatches the release manifest transition' test_release_please_dispatches_release_transition
run_test 'release reads only trusted dispatch context' test_release_reads_trusted_dispatch_context
run_test 'destination checks precede upload and publication' test_destination_checks_precede_upload_and_publish
run_test 'artifact validation precedes both publication phases' test_artifact_validation_precedes_both_publication_steps
run_test 'Release Please only runs on pushes to main' test_release_please_is_push_main_only
run_test 'release state is derived from a verified main manifest transition' test_release_state_comes_from_verified_manifest_transition
run_test 'Release Please fetches the complete pushed revision range' test_release_detection_fetches_complete_push_history
run_test 'multi-commit release pushes detect the manifest transition' test_multi_commit_release_push_is_detected
run_test 'an unavailable before revision fails closed without dispatch' test_missing_before_revision_fails_closed

printf '%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
