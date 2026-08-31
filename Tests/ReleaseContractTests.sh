#!/bin/bash
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATOR="$REPO_ROOT/scripts/validate-release.sh"
RELEASE_WORKFLOW="$REPO_ROOT/.github/workflows/release.yml"
RELEASE_PLEASE_WORKFLOW="$REPO_ROOT/.github/workflows/release-please.yml"
README="$REPO_ROOT/README.md"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/localflow-release-contract.XXXXXX")"
DIST_DIR="$TEST_ROOT/dist"
FRAMEWORK_PATH="$TEST_ROOT/Sparkle.framework"
APPCAST_TOOL="$TEST_ROOT/generate_appcast"
INFO_PLIST="$TEST_ROOT/Info.plist"
DETECTION_REPO="$TEST_ROOT/release-detection"
DETECTION_SCRIPT="$TEST_ROOT/detect-merged-release.sh"
SOURCE_SCRIPT="$TEST_ROOT/verify-release-source.sh"
PUBLICATION_REPO="$TEST_ROOT/publication-worktree"
PUBLICATION_ORIGIN="$TEST_ROOT/publication-origin.git"
PUBLICATION_SCRIPT="$TEST_ROOT/publication-step.sh"
RELEASE_STEP_SCRIPT="$TEST_ROOT/release-step.sh"
DMG_SIGNING_SCRIPT="$TEST_ROOT/dmg-signing-phase.sh"
RELEASE_TOOL_LOG="$TEST_ROOT/release-tools"
RELEASE_FAKE_BIN="$TEST_ROOT/release-fake-bin"
RELEASE_LABEL_SCRIPT="$TEST_ROOT/mark-release-pr-published.sh"
RELEASE_LABEL_FAKE_BIN="$TEST_ROOT/release-label-fake-bin"
RELEASE_LABEL_ACTIONS="$TEST_ROOT/release-label-actions"
RELEASE_LABEL_STATE="$TEST_ROOT/release-label-state"
RELEASE_REPOSITORY_LABELS="$TEST_ROOT/repository-labels"
RELEASE_LABEL_CANDIDATES="$TEST_ROOT/release-label-candidates.json"
GH_LOG="$TEST_ROOT/gh-mutations"
OUTPUT_FILE="$TEST_ROOT/github-output"
STDOUT_FILE="$TEST_ROOT/stdout"
STDERR_FILE="$TEST_ROOT/stderr"
PASS_COUNT=0
FAIL_COUNT=0
LAST_STATUS=0
RELEASE_LABEL_COMMIT_SHA='1111111111111111111111111111111111111111'
RELEASE_LABEL_OTHER_SHA='2222222222222222222222222222222222222222'

# RFC 8032 test vectors encoded in Sparkle's modern base64 seed/public-key
# format. They let the contract exercise real key identity without touching a
# developer's Keychain or using the production signing secret.
MATCHING_PRIVATE_KEY='nWGxne/9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A='
MATCHING_PUBLIC_KEY='11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo='
MISMATCHED_PRIVATE_KEY='TM0Imyj/ltqdtsNG7BFOD1uKMZ81q6Yk2oz27U+4pvs='
LEGACY_MATCHING_PRIVATE_KEY='MHyDhk8oM8tCei7xwAoBPP3/J2jZgMCjpSDwBpBN6U+bTwr+KAt0aneGhOdUQlAgV7dHOgPwj5b1o46Sh+Afj9damAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea'
LEGACY_MISMATCHED_PRIVATE_KEY='MHyDhk8oM8tCei7xwAoBPP3/J2jZgMCjpSDwBpBN6U+bTwr+KAt0aneGhOdUQlAgV7dHOgPwj5b1o46Sh+Afjz1AF8PoQ4lakrcKp00bfrycmCzPLsSWjMDNVfEq9GYM'
LEGACY_CORRUPT_PRIVATE_KEY='MXyDhk8oM8tCei7xwAoBPP3/J2jZgMCjpSDwBpBN6U+bTwr+KAt0aneGhOdUQlAgV7dHOgPwj5b1o46Sh+Afj9damAGCsQq31Uv+08lkBzoO4XLz2qYjJa8CGmj3B1Ea'

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

assert_failure() {
    if [[ "$LAST_STATUS" -eq 0 ]]; then
        fail 'expected failure, got exit status 0'
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

extract_release_label_script() {
    awk '
        /^      - name: Mark release PR published$/ { in_step=1; next }
        in_step && /^      - name:/ { exit }
        in_step && /^        run: \|$/ { in_run=1; next }
        in_run && /^          / { sub(/^          /, ""); print; next }
        in_run && /^[[:space:]]*$/ { print; next }
        in_run { exit }
    ' "$RELEASE_PLEASE_WORKFLOW" > "$RELEASE_LABEL_SCRIPT"
    chmod +x "$RELEASE_LABEL_SCRIPT"
}

release_please_job_block() {
    local job_name="$1"
    awk -v job_name="$job_name" '
        $0 == "  " job_name ":" { active=1; print; next }
        active && /^  [A-Za-z0-9_-]+:$/ { exit }
        active { print }
    ' "$RELEASE_PLEASE_WORKFLOW"
}

extract_source_script() {
    awk '
        /^      - name: Verify release manifest transition$/ { in_step=1; next }
        in_step && /^      - name:/ { exit }
        in_step && /^        run: \|$/ { in_run=1; next }
        in_run && /^          / { sub(/^          /, ""); print; next }
        in_run && /^[[:space:]]*$/ { print; next }
        in_run { exit }
    ' "$RELEASE_WORKFLOW" > "$SOURCE_SCRIPT"
    chmod +x "$SOURCE_SCRIPT"
}

reset_detection_fixture() {
    local before_version="${1:-1.0.0}"
    local release_version="${2:-1.1.0}"
    rm -rf "$DETECTION_REPO"
    mkdir -p "$DETECTION_REPO/.github"
    git -C "$DETECTION_REPO" init -q -b main

    printf '{".":"%s"}\n' "$before_version" \
        > "$DETECTION_REPO/.github/.release-please-manifest.json"
    git -C "$DETECTION_REPO" add .github/.release-please-manifest.json
    git -C "$DETECTION_REPO" -c user.name=Tests -c user.email=tests@example.com \
        commit -qm 'initial release manifest'
    DETECTION_BEFORE_SHA="$(git -C "$DETECTION_REPO" rev-parse HEAD)"

    printf 'intervening change\n' > "$DETECTION_REPO/notes.txt"
    git -C "$DETECTION_REPO" add notes.txt
    git -C "$DETECTION_REPO" -c user.name=Tests -c user.email=tests@example.com \
        commit -qm 'intervening main commit'

    printf '{".":"%s"}\n' "$release_version" \
        > "$DETECTION_REPO/.github/.release-please-manifest.json"
    git -C "$DETECTION_REPO" add .github/.release-please-manifest.json
    git -C "$DETECTION_REPO" -c user.name=Tests -c user.email=tests@example.com \
        commit -qm 'merge release manifest'
    DETECTION_COMMIT_SHA="$(git -C "$DETECTION_REPO" rev-parse HEAD)"
    git -C "$DETECTION_REPO" update-ref refs/remotes/origin/main "$DETECTION_COMMIT_SHA"
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

reset_release_label_fixture() {
    local candidates="$1"
    shift
    local fake_gh
    local labels_json

    rm -rf "$RELEASE_LABEL_FAKE_BIN"
    mkdir -p "$RELEASE_LABEL_FAKE_BIN"
    : > "$RELEASE_LABEL_ACTIONS"
    : > "$RELEASE_LABEL_STATE"
    printf 'autorelease: published\n' > "$RELEASE_REPOSITORY_LABELS"
    local label
    for label in "$@"; do
        printf '%s\n' "$label" >> "$RELEASE_LABEL_STATE"
    done
    labels_json="$(jq -Rn '[inputs | select(length > 0) | {name: .}]' \
        < "$RELEASE_LABEL_STATE")"

    case "$candidates" in
        one)
            jq -n \
                --arg sha "$RELEASE_LABEL_COMMIT_SHA" \
                --arg other "$RELEASE_LABEL_OTHER_SHA" \
                --argjson labels "$labels_json" \
                '[
                    {number: 101, state: "closed", merged_at: "2026-08-31T20:00:00Z", merge_commit_sha: $sha, base: {ref: "main"}, labels: $labels},
                    {number: 102, state: "closed", merged_at: "2026-08-30T20:00:00Z", merge_commit_sha: $other, base: {ref: "main"}, labels: [{name: "autorelease: pending"}]},
                    {number: 104, state: "open", merged_at: null, merge_commit_sha: $sha, base: {ref: "main"}, labels: [{name: "autorelease: pending"}]},
                    {number: 105, state: "closed", merged_at: "2026-08-30T20:00:00Z", merge_commit_sha: $sha, base: {ref: "develop"}, labels: [{name: "autorelease: pending"}]},
                    {number: 106, state: "closed", merged_at: null, merge_commit_sha: $sha, base: {ref: "main"}, labels: [{name: "autorelease: pending"}]},
                    {number: 107, state: "closed", merged_at: "2026-08-30T20:00:00Z", merge_commit_sha: $sha, base: {ref: "main"}, labels: [{name: "keep-me"}]}
                ]' > "$RELEASE_LABEL_CANDIDATES"
            ;;
        zero)
            jq -n \
                --arg sha "$RELEASE_LABEL_COMMIT_SHA" \
                --arg other "$RELEASE_LABEL_OTHER_SHA" \
                '[
                    {number: 102, state: "closed", merged_at: "2026-08-30T20:00:00Z", merge_commit_sha: $other, base: {ref: "main"}, labels: [{name: "autorelease: pending"}]},
                    {number: 104, state: "open", merged_at: null, merge_commit_sha: $sha, base: {ref: "main"}, labels: [{name: "autorelease: pending"}]},
                    {number: 105, state: "closed", merged_at: "2026-08-30T20:00:00Z", merge_commit_sha: $sha, base: {ref: "develop"}, labels: [{name: "autorelease: pending"}]},
                    {number: 106, state: "closed", merged_at: null, merge_commit_sha: $sha, base: {ref: "main"}, labels: [{name: "autorelease: pending"}]},
                    {number: 107, state: "closed", merged_at: "2026-08-30T20:00:00Z", merge_commit_sha: $sha, base: {ref: "main"}, labels: [{name: "keep-me"}]}
                ]' > "$RELEASE_LABEL_CANDIDATES"
            ;;
        two)
            jq -n \
                --arg sha "$RELEASE_LABEL_COMMIT_SHA" \
                --argjson labels "$labels_json" \
                '[
                    {number: 101, state: "closed", merged_at: "2026-08-31T20:00:00Z", merge_commit_sha: $sha, base: {ref: "main"}, labels: $labels},
                    {number: 103, state: "closed", merged_at: "2026-08-31T20:00:01Z", merge_commit_sha: $sha, base: {ref: "main"}, labels: [{name: "autorelease: pending"}]}
                ]' > "$RELEASE_LABEL_CANDIDATES"
            ;;
        *) fail "unknown release label fixture: $candidates"; return ;;
    esac

    IFS= read -r -d '' fake_gh <<'FAKE_GH' || true
#!/bin/bash
set -euo pipefail

ORIGINAL_ARGS=("$@")
ARGS="${ORIGINAL_ARGS[*]}"
JQ_EXPRESSION=""
for ((index=0; index < ${#ORIGINAL_ARGS[@]}; index++)); do
    if [[ "${ORIGINAL_ARGS[index]}" == "--jq" || "${ORIGINAL_ARGS[index]}" == "-q" ]]; then
        JQ_EXPRESSION="${ORIGINAL_ARGS[index + 1]:-}"
    fi
done

emit_json() {
    local value="$1"
    if [[ -n "$JQ_EXPRESSION" ]]; then
        jq -r "$JQ_EXPRESSION" <<< "$value"
    else
        printf '%s\n' "$value"
    fi
}

labels_json() {
    jq -Rn '[inputs | select(length > 0) | {name: .}] | {labels: .}' \
        < "$RELEASE_LABEL_STATE"
}

repository_labels_json() {
    jq -Rn '[inputs | select(length > 0) | {name: .}]' \
        < "$RELEASE_REPOSITORY_LABELS"
}

if [[ "$ARGS" == release\ view* ]]; then
    printf 'release\n' >> "$RELEASE_LABEL_ACTIONS"
    [[ "$ARGS" == *"$RELEASE_TAG"* ]] || exit 90
    RELEASE_JSON="$(jq -n \
        --argjson draft "$RELEASE_LABEL_DRAFT" \
        --arg target "$RELEASE_LABEL_TARGET" \
        '{isDraft: $draft, targetCommitish: $target}')"
    emit_json "$RELEASE_JSON"
    exit 0
fi

if [[ "$ARGS" == api*"commits/$COMMIT_SHA/pulls"* ]]; then
    printf 'candidates\n' >> "$RELEASE_LABEL_ACTIONS"
    CURRENT_LABELS="$(labels_json | jq '.labels')"
    CANDIDATES="$(jq --argjson labels "$CURRENT_LABELS" \
        'map(if .number == 101 then .labels = $labels else . end)' \
        "$RELEASE_LABEL_CANDIDATES")"
    emit_json "$CANDIDATES"
    exit 0
fi

if [[ ("$ARGS" == *"--method POST"* || "$ARGS" == *"-X POST"*) && \
      "$ARGS" == *"repos/$GITHUB_REPOSITORY/labels"* && \
      "$ARGS" != *"/issues/"* ]]; then
    printf 'create-label\n' >> "$RELEASE_LABEL_ACTIONS"
    [[ "$ARGS" == *"name=autorelease: published"* ]] || exit 95
    [[ "$ARGS" == *"color=0e8a16"* ]] || exit 96
    [[ "$ARGS" == *"description=Release has been published"* ]] || exit 97
    if [[ "$RELEASE_LABEL_CREATE_RACE" == true ]]; then
        grep -Fxq 'autorelease: published' "$RELEASE_REPOSITORY_LABELS" || \
            printf 'autorelease: published\n' >> "$RELEASE_REPOSITORY_LABELS"
        exit 101
    fi
    grep -Fxq 'autorelease: published' "$RELEASE_REPOSITORY_LABELS" || \
        printf 'autorelease: published\n' >> "$RELEASE_REPOSITORY_LABELS"
    jq -n '{name: "autorelease: published", color: "0e8a16", description: "Release has been published"}'
    exit 0
fi

if [[ "$ARGS" == api*"repos/$GITHUB_REPOSITORY/labels"* && \
      "$ARGS" != *"/issues/"* ]]; then
    printf 'repository-label\n' >> "$RELEASE_LABEL_ACTIONS"
    if [[ "$ARGS" == *"/labels/"*published* ]]; then
        grep -Fxq 'autorelease: published' "$RELEASE_REPOSITORY_LABELS" || exit 98
        emit_json '{"name":"autorelease: published","color":"0e8a16","description":"Release has been published"}'
    else
        emit_json "$(repository_labels_json)"
    fi
    exit 0
fi

if [[ ("$ARGS" == *"--method DELETE"* || "$ARGS" == *"-X DELETE"* || "$ARGS" == pr\ edit*"--remove-label"*) && "$ARGS" == *pending* ]]; then
    printf 'delete\n' >> "$RELEASE_LABEL_ACTIONS"
    [[ "$ARGS" == *"/issues/$RELEASE_LABEL_TARGET_PR/labels"* || "$ARGS" == *"pr edit $RELEASE_LABEL_TARGET_PR"* ]] || exit 91
    grep -Fxv 'autorelease: pending' "$RELEASE_LABEL_STATE" \
        > "$RELEASE_LABEL_STATE.next" || true
    mv "$RELEASE_LABEL_STATE.next" "$RELEASE_LABEL_STATE"
    exit 0
fi

if [[ ("$ARGS" == *"--method POST"* || "$ARGS" == *"-X POST"* || "$ARGS" == pr\ edit*"--add-label"*) && "$ARGS" == *"/labels"* ]]; then
    printf 'add\n' >> "$RELEASE_LABEL_ACTIONS"
    [[ "$ARGS" == *"/issues/$RELEASE_LABEL_TARGET_PR/labels"* || "$ARGS" == *"pr edit $RELEASE_LABEL_TARGET_PR"* ]] || exit 92
    [[ "$ARGS" == *"labels[]=autorelease: published"* ]] || exit 99
    grep -Fxq 'autorelease: published' "$RELEASE_REPOSITORY_LABELS" || exit 100
    [[ "$RELEASE_LABEL_ADD_FAILURE" != true ]] || exit 93
    grep -Fxq 'autorelease: published' "$RELEASE_LABEL_STATE" || \
        printf 'autorelease: published\n' >> "$RELEASE_LABEL_STATE"
    labels_json
    exit 0
fi

if [[ "$ARGS" == api*"/issues/$RELEASE_LABEL_TARGET_PR"* || \
      "$ARGS" == api*"/pulls/$RELEASE_LABEL_TARGET_PR"* || \
      "$ARGS" == pr\ view\ "$RELEASE_LABEL_TARGET_PR"* ]]; then
    printf 'labels\n' >> "$RELEASE_LABEL_ACTIONS"
    emit_json "$(labels_json)"
    exit 0
fi

printf 'unexpected gh call: %s\n' "$ARGS" >&2
exit 94
FAKE_GH
    printf '%s\n' "$fake_gh" > "$RELEASE_LABEL_FAKE_BIN/gh"
    chmod +x "$RELEASE_LABEL_FAKE_BIN/gh"
}

run_release_label_script() {
    : > "$STDOUT_FILE"
    : > "$STDERR_FILE"
    env -i \
        PATH="$RELEASE_LABEL_FAKE_BIN:$PATH" \
        HOME="${HOME:-/tmp}" \
        GH_TOKEN=test-token \
        GITHUB_REPOSITORY=test/repo \
        RELEASE_TAG=v1.2.3 \
        COMMIT_SHA="$RELEASE_LABEL_COMMIT_SHA" \
        RELEASE_LABEL_ACTIONS="$RELEASE_LABEL_ACTIONS" \
        RELEASE_LABEL_STATE="$RELEASE_LABEL_STATE" \
        RELEASE_REPOSITORY_LABELS="$RELEASE_REPOSITORY_LABELS" \
        RELEASE_LABEL_CANDIDATES="$RELEASE_LABEL_CANDIDATES" \
        RELEASE_LABEL_DRAFT="${RELEASE_LABEL_DRAFT:-false}" \
        RELEASE_LABEL_TARGET="${RELEASE_LABEL_TARGET:-$RELEASE_LABEL_COMMIT_SHA}" \
        RELEASE_LABEL_TARGET_PR=101 \
        RELEASE_LABEL_ADD_FAILURE="${RELEASE_LABEL_ADD_FAILURE:-false}" \
        RELEASE_LABEL_CREATE_RACE="${RELEASE_LABEL_CREATE_RACE:-false}" \
        bash "$RELEASE_LABEL_SCRIPT" > "$STDOUT_FILE" 2> "$STDERR_FILE"
    LAST_STATUS=$?
}

assert_release_label_queries() {
    grep -Fxq release "$RELEASE_LABEL_ACTIONS" || \
        { fail 'release finalization did not verify the published release'; return; }
    grep -Fxq candidates "$RELEASE_LABEL_ACTIONS" || \
        { fail 'release finalization did not query PRs for the exact commit'; return; }
    local candidate_reads
    candidate_reads="$(grep -Fxc candidates "$RELEASE_LABEL_ACTIONS")"
    if ! grep -Fxq labels "$RELEASE_LABEL_ACTIONS" && [[ "$candidate_reads" -lt 2 ]]; then
        fail 'release finalization did not re-fetch final labels'
    fi
}

assert_no_label_mutations() {
    if grep -Eq '^(create-label|add|delete)$' "$RELEASE_LABEL_ACTIONS"; then
        sed 's/^/    action: /' "$RELEASE_LABEL_ACTIONS" >&2
        fail 'release finalization mutated labels unexpectedly'
    fi
}

assert_label_mutations() {
    local expected="$1"
    local actual
    actual="$(grep -E '^(create-label|add|delete)$' "$RELEASE_LABEL_ACTIONS" || true)"
    if [[ "$actual" != "$expected" ]]; then
        sed 's/^/    action: /' "$RELEASE_LABEL_ACTIONS" >&2
        fail 'release label mutations did not match the required order'
    fi
}

assert_repository_labels() {
    local expected
    local actual
    expected="$(printf '%s\n' "$@" | sort)"
    actual="$(sort "$RELEASE_REPOSITORY_LABELS")"
    if [[ "$actual" != "$expected" ]]; then
        sed 's/^/    repository label: /' "$RELEASE_REPOSITORY_LABELS" >&2
        fail 'repository labels do not match the expected final state'
    fi
}

assert_release_labels() {
    local expected
    local actual
    expected="$(printf '%s\n' "$@" | sort)"
    actual="$(sort "$RELEASE_LABEL_STATE")"
    if [[ "$actual" != "$expected" ]]; then
        sed 's/^/    label: /' "$RELEASE_LABEL_STATE" >&2
        fail 'release PR labels do not match the expected final state'
    fi
}

run_source_verification() {
    local before_sha="$1"
    local release_sha="$2"
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
            COMMIT_SHA="$release_sha" \
            RELEASE_SHA="$release_sha" \
            DISPATCH_SHA="$release_sha" \
            bash "$SOURCE_SCRIPT"
    ) > "$STDOUT_FILE" 2> "$STDERR_FILE"
    LAST_STATUS=$?
}

extract_publication_script() {
    local step_name="$1"
    local script
    script="$(awk -v step_name="$step_name" '
        $0 == "      - name: " step_name { in_step=1; next }
        in_step && /^      - name:/ { exit }
        in_step && /^        run: \|$/ { in_run=1; next }
        in_run && /^          / { sub(/^          /, ""); print; next }
        in_run && /^[[:space:]]*$/ { print; next }
        in_run { exit }
    ' "$RELEASE_WORKFLOW")"
    script="${script//'${{ github.repository }}'/test/repo}"
    script="${script//'${{ steps.contract.outputs.version }}'/1.1.0}"
    printf '%s\n' "$script" > "$PUBLICATION_SCRIPT"
    chmod +x "$PUBLICATION_SCRIPT"
}

extract_release_step_script() {
    local step_name="$1"
    awk -v step_name="$step_name" '
        $0 == "      - name: " step_name { in_step=1; next }
        in_step && /^      - name:/ { exit }
        in_step && /^        run: \|$/ { in_run=1; next }
        in_run && /^          / { sub(/^          /, ""); print; next }
        in_run && /^[[:space:]]*$/ { print; next }
        in_run { exit }
    ' "$RELEASE_WORKFLOW" > "$RELEASE_STEP_SCRIPT"
    chmod +x "$RELEASE_STEP_SCRIPT"
}

release_step_block() {
    local step_name="$1"
    awk -v step_name="$step_name" '
        $0 == "      - name: " step_name { active=1; print; next }
        active && /^      - name:/ { exit }
        active { print }
    ' "$RELEASE_WORKFLOW"
}

extract_dmg_signing_phase() {
    awk '
        /^      - name: Package DMG$/ { after_package=1; next }
        after_package && /^      - name: Verify signed artifacts$/ { exit }
        in_run && /^          / {
            sub(/^          /, "")
            if ($0 == "./scripts/make-dmg.sh") $0="make-dmg"
            print
            next
        }
        in_run && /^[[:space:]]*$/ { print; next }
        in_run { in_run=0 }
        after_package && /^        run: \|$/ { in_run=1; next }
        after_package && /^        run: / {
            sub(/^        run: /, "")
            if ($0 == "./scripts/make-dmg.sh") $0="make-dmg"
            print
        }
    ' "$RELEASE_WORKFLOW" > "$DMG_SIGNING_SCRIPT"
    chmod +x "$DMG_SIGNING_SCRIPT"
}

reset_release_tool_fixture() {
    rm -rf "$RELEASE_FAKE_BIN"
    mkdir -p "$RELEASE_FAKE_BIN"
    : > "$RELEASE_TOOL_LOG"

    local tool
    for tool in codesign spctl xcrun make-dmg; do
        printf '%s\n' \
            '#!/bin/bash' \
            "printf '$tool' >> \"\$RELEASE_TOOL_LOG\"" \
            'printf " <%s>" "$@" >> "$RELEASE_TOOL_LOG"' \
            'printf "\n" >> "$RELEASE_TOOL_LOG"' \
            > "$RELEASE_FAKE_BIN/$tool"
        chmod +x "$RELEASE_FAKE_BIN/$tool"
    done
}

run_release_script() {
    local script="$1"
    : > "$STDOUT_FILE"
    : > "$STDERR_FILE"
    (
        cd "$REPO_ROOT"
        env -i \
            PATH="$RELEASE_FAKE_BIN:$PATH" \
            HOME="${HOME:-/tmp}" \
            RELEASE_TOOL_LOG="$RELEASE_TOOL_LOG" \
            APP_VERSION=1.2.3 \
            SIGNED=true \
            SIGN_IDENTITY='Developer ID Application: LocalFlow Test (TESTTEAM01)' \
            APPLE_ID=release@example.com \
            APPLE_APP_SPECIFIC_PASSWORD=test-app-password \
            APPLE_TEAM_ID=TESTTEAM01 \
            bash "$script"
    ) > "$STDOUT_FILE" 2> "$STDERR_FILE"
    LAST_STATUS=$?
}

assert_logged_call() {
    local tool="$1"
    shift
    local call
    local expected
    while IFS= read -r call; do
        local matches=true
        for expected in "$@"; do
            if [[ "$call" != *" <$expected>"* ]]; then
                matches=false
                break
            fi
        done
        [[ "$matches" == true ]] && return 0
    done < <(grep -E "^${tool}( |$)" "$RELEASE_TOOL_LOG")

    sed 's/^/    tool call: /' "$RELEASE_TOOL_LOG" >&2
    fail "missing $tool call with arguments: $*"
}

reset_publication_fixture() {
    reset_detection_fixture
    rm -rf "$PUBLICATION_REPO" "$PUBLICATION_ORIGIN"
    git init -q --bare "$PUBLICATION_ORIGIN"
    git -C "$PUBLICATION_ORIGIN" symbolic-ref HEAD refs/heads/main
    git -C "$DETECTION_REPO" remote add origin "$PUBLICATION_ORIGIN"
    git -C "$DETECTION_REPO" push -q -u origin main
    git clone -q "$PUBLICATION_ORIGIN" "$PUBLICATION_REPO"

    printf 'main advanced while an older release was building\n' >> "$DETECTION_REPO/notes.txt"
    git -C "$DETECTION_REPO" add notes.txt
    git -C "$DETECTION_REPO" -c user.name=Tests -c user.email=tests@example.com \
        commit -qm 'advance main during release build'
    git -C "$DETECTION_REPO" push -q origin main

    mkdir -p "$TEST_ROOT/fake-bin" "$TEST_ROOT/runner"
    : > "$GH_LOG"
    printf '%s\n' \
        '#!/bin/bash' \
        'set -euo pipefail' \
        'case "$*" in' \
        '  "api --paginate "*) exit 0 ;;' \
        '  *"--json isDraft"*) printf "true\\n" ;;' \
        '  *"--json targetCommitish"*) printf "%s\\n" "$COMMIT_SHA" ;;' \
        '  *"--json assets"*) printf "%s\\n" "LocalFlow-${APP_VERSION}.dmg" "LocalFlow-${APP_VERSION}.zip" "SHA256SUMS.txt" "appcast.xml" "setup-s1-mini.sh" ;;' \
        '  "release create "*|"release upload "*|"release edit "*) printf "%s\\n" "$*" >> "$GH_LOG" ;;' \
        '  *) printf "unexpected gh call: %s\\n" "$*" >&2; exit 1 ;;' \
        'esac' > "$TEST_ROOT/fake-bin/gh"
    chmod +x "$TEST_ROOT/fake-bin/gh"
}

run_publication_step() {
    : > "$STDOUT_FILE"
    : > "$STDERR_FILE"
    (
        cd "$PUBLICATION_REPO"
        env \
            PATH="$TEST_ROOT/fake-bin:$PATH" \
            GH_LOG="$GH_LOG" \
            GH_TOKEN=test-token \
            RUNNER_TEMP="$TEST_ROOT/runner" \
            APP_VERSION=1.1.0 \
            RELEASE_TAG=v1.1.0 \
            COMMIT_SHA="$DETECTION_COMMIT_SHA" \
            bash "$PUBLICATION_SCRIPT"
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

test_matching_legacy_sparkle_key() {
    reset_tool_fixture
    SPARKLE_PRIVATE_KEY="$LEGACY_MATCHING_PRIVATE_KEY" run_preflight
    assert_success
}

test_mismatched_legacy_sparkle_key() {
    reset_tool_fixture
    SPARKLE_PRIVATE_KEY="$LEGACY_MISMATCHED_PRIVATE_KEY" run_preflight
    assert_failure_containing 'SUPublicEDKey'
}

test_corrupt_legacy_sparkle_private_material() {
    reset_tool_fixture
    SPARKLE_PRIVATE_KEY="$LEGACY_CORRUPT_PRIVATE_KEY" run_preflight
    assert_failure_containing 'private/public mismatch'
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

test_dmg_is_signed_after_packaging_before_notarization() {
    local sign_step
    local package_line
    local sign_line
    local notarize_line

    sign_step="$(release_step_block 'Sign DMG')"
    if ! grep -Fq 'SIGN_IDENTITY: ${{ steps.signing.outputs.identity }}' <<< "$sign_step"; then
        fail 'DMG signing must use the imported Developer ID Application identity'
        return
    fi

    extract_dmg_signing_phase
    reset_release_tool_fixture
    run_release_script "$DMG_SIGNING_SCRIPT"
    assert_success || return
    assert_logged_call codesign \
        --sign \
        'Developer ID Application: LocalFlow Test (TESTTEAM01)' \
        dist/LocalFlow-1.2.3.dmg || return
    assert_logged_call xcrun notarytool submit dist/LocalFlow-1.2.3.dmg || return

    package_line="$(grep -n -m1 '^make-dmg' "$RELEASE_TOOL_LOG" | cut -d: -f1)"
    sign_line="$(grep -n -m1 '^codesign .*<dist/LocalFlow-1\.2\.3\.dmg>' \
        "$RELEASE_TOOL_LOG" | cut -d: -f1)"
    notarize_line="$(grep -n -m1 '^xcrun .*<notarytool>.*<submit>.*<dist/LocalFlow-1\.2\.3\.dmg>' \
        "$RELEASE_TOOL_LOG" | cut -d: -f1)"
    [[ -n "$package_line" && -n "$sign_line" && -n "$notarize_line" && \
        "$package_line" -lt "$sign_line" && "$sign_line" -lt "$notarize_line" ]] || {
        sed 's/^/    tool call: /' "$RELEASE_TOOL_LOG" >&2
        fail 'the workflow must package, sign, then notarize the DMG'
    }
}

test_signed_dmg_passes_codesign_gatekeeper_and_stapler_checks() {
    local verify_step
    verify_step="$(release_step_block 'Verify signed artifacts')"
    if ! grep -Fq 'SIGNED: ${{ steps.contract.outputs.sign }}' <<< "$verify_step"; then
        fail 'signed artifact verification must use the validated signing decision'
        return
    fi

    extract_release_step_script 'Verify signed artifacts'
    reset_release_tool_fixture
    run_release_script "$RELEASE_STEP_SCRIPT"
    assert_success || return
    assert_logged_call codesign --verify build/LocalFlow.app || return
    assert_logged_call spctl --assess --type execute build/LocalFlow.app || return
    assert_logged_call xcrun stapler validate build/LocalFlow.app || return
    assert_logged_call codesign --verify dist/LocalFlow-1.2.3.dmg || return
    assert_logged_call spctl \
        --assess \
        --type open \
        --context context:primary-signature \
        dist/LocalFlow-1.2.3.dmg || return
    assert_logged_call xcrun stapler validate dist/LocalFlow-1.2.3.dmg
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

test_release_is_reusable_workflow_only() {
    assert_file_contains "$RELEASE_WORKFLOW" 'workflow_call:' || return
    if grep -Eq 'repository_dispatch:|workflow_dispatch:' "$RELEASE_WORKFLOW"; then
        fail 'release workflow must only accept a trusted workflow_call'
        return
    fi
    if grep -Eq 'github\.event\.client_payload|\$\{\{ inputs\.' "$RELEASE_WORKFLOW"; then
        fail 'release workflow must not accept caller-provided release state'
    fi
}

test_release_runs_share_one_concurrency_group() {
    local concurrency
    concurrency="$(awk '
        /^concurrency:$/ { active=1 }
        /^jobs:$/ { active=0 }
        active { print }
    ' "$RELEASE_WORKFLOW")"
    case "$concurrency" in
        *'group:'*'cancel-in-progress: false'*) ;;
        *) fail 'release workflow must serialize runs without canceling the active release'; return ;;
    esac
    if grep -Fq '${{' <<< "$concurrency"; then
        fail 'production releases must share one constant concurrency group'
    fi
}

test_release_please_calls_release_workflow() {
    assert_file_contains "$RELEASE_PLEASE_WORKFLOW" \
        'uses: ./.github/workflows/release.yml' || return
    if grep -Eq 'gh api|/dispatches|client_payload|release-build' "$RELEASE_PLEASE_WORKFLOW"; then
        fail 'Release Please must call the reusable workflow without repository dispatch'
    fi
}

test_release_label_job_contract() {
    local release_please_job
    local label_job
    local condition
    local permissions
    release_please_job="$(release_please_job_block release-please)"
    label_job="$(release_please_job_block mark-release-pr-published)"
    [[ -n "$label_job" ]] || { fail 'missing mark-release-pr-published caller job'; return; }

    grep -Fq 'release_tag: ${{ steps.merged-release.outputs.tag }}' <<< "$release_please_job" || \
        { fail 'release-please must expose the detected release tag'; return; }
    grep -Eq '^    needs: \[release-please, release\]$' <<< "$label_job" || \
        { fail 'label finalization must wait for release-please and release'; return; }
    condition="$(grep -m1 '^    if:' <<< "$label_job")"
    grep -Fq "needs.release-please.outputs.release_created == 'true'" <<< "$condition" || \
        { fail 'label finalization must require a detected release'; return; }
    grep -Fq "needs.release.result == 'success'" <<< "$condition" || \
        { fail 'label finalization must require successful publication'; return; }
    permissions="$(awk '
        /^    permissions:$/ { active=1 }
        active && /^    [A-Za-z0-9_-]+:/ && $0 != "    permissions:" { exit }
        active { print }
    ' <<< "$label_job")"
    [[ "$permissions" == $'    permissions:\n      contents: read\n      pull-requests: write' ]] || \
        { fail 'label finalization permissions must be contents read and pull requests write'; return; }
    grep -Fq 'RELEASE_TAG: ${{ needs.release-please.outputs.release_tag }}' <<< "$label_job" || \
        { fail 'label finalization must consume the detected tag'; return; }
    grep -Fq 'COMMIT_SHA: ${{ github.sha }}' <<< "$label_job" || \
        { fail 'label finalization must consume the exact release commit'; return; }
    grep -Fq 'GH_TOKEN: ${{ github.token }}' <<< "$label_job" || \
        { fail 'label finalization must use the caller job token'; return; }
    grep -Fq -- '- name: Mark release PR published' <<< "$label_job" || \
        fail 'label finalization must expose an executable contract step'
}

test_release_label_happy_path_selects_exact_pr() {
    extract_release_label_script
    reset_release_label_fixture one 'autorelease: pending' 'keep-me'
    run_release_label_script
    assert_success || return
    assert_release_label_queries || return
    assert_label_mutations $'add\ndelete' || return
    assert_release_labels 'autorelease: published' 'keep-me'
}

test_release_label_creates_missing_repository_label() {
    extract_release_label_script
    reset_release_label_fixture one 'autorelease: pending' 'keep-me'
    : > "$RELEASE_REPOSITORY_LABELS"
    run_release_label_script
    assert_success || return
    assert_release_label_queries || return
    assert_label_mutations $'create-label\nadd\ndelete' || return
    assert_repository_labels 'autorelease: published' || return
    assert_release_labels 'autorelease: published' 'keep-me'
}

test_release_label_recovers_from_concurrent_repository_label_create() {
    extract_release_label_script
    reset_release_label_fixture one 'autorelease: pending' 'keep-me'
    : > "$RELEASE_REPOSITORY_LABELS"
    RELEASE_LABEL_CREATE_RACE=true run_release_label_script
    assert_success || return
    assert_release_label_queries || return
    assert_label_mutations $'create-label\nadd\ndelete' || return
    assert_repository_labels 'autorelease: published' || return
    assert_release_labels 'autorelease: published' 'keep-me'
}

test_release_label_rejects_draft_or_wrong_target() {
    local scenario
    extract_release_label_script
    for scenario in draft wrong-target; do
        reset_release_label_fixture one 'autorelease: pending' 'keep-me'
        case "$scenario" in
            draft) RELEASE_LABEL_DRAFT=true run_release_label_script ;;
            wrong-target) RELEASE_LABEL_TARGET="$RELEASE_LABEL_OTHER_SHA" run_release_label_script ;;
        esac
        assert_failure || return
        assert_no_label_mutations || return
        assert_release_labels 'autorelease: pending' 'keep-me' || return
    done
}

test_release_label_requires_exactly_one_candidate() {
    local candidates
    extract_release_label_script
    for candidates in zero two; do
        reset_release_label_fixture "$candidates" 'autorelease: pending' 'keep-me'
        run_release_label_script
        assert_failure || return
        assert_no_label_mutations || return
        assert_release_labels 'autorelease: pending' 'keep-me' || return
    done
}

test_release_label_is_idempotent_when_already_published() {
    extract_release_label_script
    reset_release_label_fixture one 'autorelease: published' 'keep-me'
    run_release_label_script
    assert_success || return
    assert_release_label_queries || return
    assert_no_label_mutations || return
    assert_release_labels 'autorelease: published' 'keep-me'
}

test_release_label_removes_only_pending_when_both_exist() {
    extract_release_label_script
    reset_release_label_fixture one \
        'autorelease: pending' 'autorelease: published' 'keep-me'
    run_release_label_script
    assert_success || return
    assert_release_label_queries || return
    assert_label_mutations delete || return
    assert_release_labels 'autorelease: published' 'keep-me'
}

test_release_label_add_failure_preserves_pending() {
    extract_release_label_script
    reset_release_label_fixture one 'autorelease: pending' 'keep-me'
    RELEASE_LABEL_ADD_FAILURE=true run_release_label_script
    assert_failure || return
    assert_label_mutations add || return
    assert_release_labels 'autorelease: pending' 'keep-me'
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
        *'BEFORE_SHA: ${{ github.event.before }}'*'${{ github.sha }}'*) ;;
        *) fail 'source verification must derive both revisions from the caller push context'; return ;;
    esac
    if grep -Eq 'github\.event\.client_payload|\$\{\{ inputs\.' <<< "$source_job$contract_step"; then
        fail 'release validation must not consume caller-provided release state'
    fi
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

test_release_source_requires_current_main_tip() {
    extract_source_script
    reset_detection_fixture

    printf 'main advanced after the release call\n' >> "$DETECTION_REPO/notes.txt"
    git -C "$DETECTION_REPO" add notes.txt
    git -C "$DETECTION_REPO" -c user.name=Tests -c user.email=tests@example.com \
        commit -qm 'advance main after release call'
    git -C "$DETECTION_REPO" update-ref refs/remotes/origin/main \
        "$(git -C "$DETECTION_REPO" rev-parse HEAD)"

    run_source_verification "$DETECTION_BEFORE_SHA" "$DETECTION_COMMIT_SHA"
    assert_failure_containing 'origin/main tip'
}

test_release_source_rejects_reverted_main_tip() {
    extract_source_script
    reset_detection_fixture
    git -C "$DETECTION_REPO" update-ref refs/remotes/origin/main "$DETECTION_BEFORE_SHA"
    run_source_verification "$DETECTION_BEFORE_SHA" "$DETECTION_COMMIT_SHA"
    assert_failure_containing 'origin/main'
}

test_numeric_semver_increase_is_detected() {
    extract_detection_script
    reset_detection_fixture '1.9.0' '1.10.0'
    run_release_detection "$DETECTION_BEFORE_SHA" "$DETECTION_COMMIT_SHA"
    assert_success || return
    assert_output 'created=true' || return
    assert_output 'tag=v1.10.0'
}

test_release_detection_rejects_version_rollback() {
    extract_detection_script
    reset_detection_fixture '2.0.0' '1.10.0'
    run_release_detection "$DETECTION_BEFORE_SHA" "$DETECTION_COMMIT_SHA"
    assert_failure_containing 'greater'
}

test_release_detection_rejects_prerelease_rollback() {
    extract_detection_script
    reset_detection_fixture '1.2.3' '1.2.3-rc.2'
    run_release_detection "$DETECTION_BEFORE_SHA" "$DETECTION_COMMIT_SHA"
    assert_failure_containing 'greater'
}

test_release_source_rejects_version_rollback() {
    extract_source_script
    reset_detection_fixture '2.0.0' '1.10.0'
    run_source_verification "$DETECTION_BEFORE_SHA" "$DETECTION_COMMIT_SHA"
    assert_failure_containing 'greater'
}

test_release_docs_describe_only_trusted_automatic_flow() {
    local release_docs
    release_docs="$(awk '
        /^## Cutting a release$/ { active=1 }
        active && /^## / && $0 != "## Cutting a release" { active=0 }
        active { print }
    ' "$README")"
    for expected in 'Release Please' 'automatically' 'main push' 'release.yml'; do
        if ! grep -Fiq "$expected" <<< "$release_docs"; then
            fail "release documentation must describe $expected"
            return
        fi
    done
    if grep -Eiq \
        'repository[_ ]dispatch|client_payload|release-build|request.*manually|tag and (full )?commit|omit .*payload|unpublished development artifact|development artifacts remain unsigned' \
        <<< "$release_docs"; then
        fail 'release documentation contains obsolete direct-dispatch instructions'
    fi
}

test_draft_mutation_rechecks_fresh_main_tip() {
    reset_publication_fixture
    extract_publication_script 'Create verified draft release'
    run_publication_step
    if [[ "$LAST_STATUS" -eq 0 ]]; then
        sed 's/^/    gh mutation: /' "$GH_LOG" >&2
        fail 'stale release run mutated a draft after main advanced'
        return
    fi
    assert_failure_containing 'origin/main tip' || return
    if [[ -s "$GH_LOG" ]]; then
        sed 's/^/    gh mutation: /' "$GH_LOG" >&2
        fail 'stale release run mutated a draft after main advanced'
    fi
}

test_publication_rechecks_fresh_main_tip() {
    reset_publication_fixture
    extract_publication_script 'Publish complete release'
    run_publication_step
    if [[ "$LAST_STATUS" -eq 0 ]]; then
        sed 's/^/    gh mutation: /' "$GH_LOG" >&2
        fail 'stale release run published after main advanced'
        return
    fi
    assert_failure_containing 'origin/main tip' || return
    if [[ -s "$GH_LOG" ]]; then
        sed 's/^/    gh mutation: /' "$GH_LOG" >&2
        fail 'stale release run published after main advanced'
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
run_test 'tagged preflight accepts Sparkle legacy private-plus-public exports' test_matching_legacy_sparkle_key
run_test 'tagged preflight rejects a legacy export whose public key does not match' test_mismatched_legacy_sparkle_key
run_test 'tagged preflight rejects corrupt legacy private material with a matching public suffix' test_corrupt_legacy_sparkle_private_material
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
run_test 'DMG is signed with the imported identity after packaging and before notarization' test_dmg_is_signed_after_packaging_before_notarization
run_test 'signed DMG passes codesign, Gatekeeper, and stapler verification' test_signed_dmg_passes_codesign_gatekeeper_and_stapler_checks
run_test 'release source commit is reachable from origin/main' test_release_source_is_main_ancestry
run_test 'existing draft release targets the requested commit' test_existing_draft_targets_requested_commit
run_test 'existing tag targets the requested commit' test_existing_tag_targets_requested_commit
run_test 'release workflow validates artifacts before publication' test_release_workflow_validates_before_publication
run_test 'release is callable only as a reusable workflow' test_release_is_reusable_workflow_only
run_test 'production releases share one non-canceling concurrency group' test_release_runs_share_one_concurrency_group
run_test 'Release Please calls the reusable release workflow' test_release_please_calls_release_workflow
run_test 'release label finalization has restricted caller job wiring' test_release_label_job_contract
run_test 'release label finalization selects the exact merged PR' test_release_label_happy_path_selects_exact_pr
run_test 'release label finalization creates a missing published repository label' test_release_label_creates_missing_repository_label
run_test 'release label finalization recovers from concurrent repository label creation' test_release_label_recovers_from_concurrent_repository_label_create
run_test 'release label finalization rejects draft or wrong-target releases' test_release_label_rejects_draft_or_wrong_target
run_test 'release label finalization requires exactly one matching PR' test_release_label_requires_exactly_one_candidate
run_test 'release label finalization is idempotent once published' test_release_label_is_idempotent_when_already_published
run_test 'release label finalization removes only a stale pending label' test_release_label_removes_only_pending_when_both_exist
run_test 'release label finalization preserves pending when publication labeling fails' test_release_label_add_failure_preserves_pending
run_test 'release reads only trusted dispatch context' test_release_reads_trusted_dispatch_context
run_test 'destination checks precede upload and publication' test_destination_checks_precede_upload_and_publish
run_test 'artifact validation precedes both publication phases' test_artifact_validation_precedes_both_publication_steps
run_test 'Release Please only runs on pushes to main' test_release_please_is_push_main_only
run_test 'release state is derived from a verified main manifest transition' test_release_state_comes_from_verified_manifest_transition
run_test 'Release Please fetches the complete pushed revision range' test_release_detection_fetches_complete_push_history
run_test 'multi-commit release pushes detect the manifest transition' test_multi_commit_release_push_is_detected
run_test 'an unavailable before revision fails closed without dispatch' test_missing_before_revision_fails_closed
run_test 'release source must equal the current origin/main tip' test_release_source_requires_current_main_tip
run_test 'release source rejects a reverted origin/main tip' test_release_source_rejects_reverted_main_tip
run_test 'numeric semantic-version increases are accepted' test_numeric_semver_increase_is_detected
run_test 'release detection rejects a version rollback' test_release_detection_rejects_version_rollback
run_test 'release detection rejects a stable-to-prerelease rollback' test_release_detection_rejects_prerelease_rollback
run_test 'release source verification rejects a version rollback' test_release_source_rejects_version_rollback
run_test 'release documentation describes only the trusted automatic flow' test_release_docs_describe_only_trusted_automatic_flow
run_test 'draft creation and upload recheck the freshly fetched main tip' test_draft_mutation_rechecks_fresh_main_tip
run_test 'publication rechecks the freshly fetched main tip' test_publication_rechecks_fresh_main_tip

printf '%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
