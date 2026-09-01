#!/bin/bash
# Shared release workflow checks. This file is sourced after checkout.

semver_is_greater() {
    local before="$1"
    local after="$2"
    local pattern='^([0-9]+)\.([0-9]+)\.([0-9]+)(-(alpha|beta|rc)\.([0-9]+))?$'
    local before_major before_minor before_patch before_stage before_number
    local after_major after_minor after_patch after_stage after_number
    local component before_rank after_rank

    [[ "$before" =~ $pattern ]] || return 2
    before_major="${BASH_REMATCH[1]}"
    before_minor="${BASH_REMATCH[2]}"
    before_patch="${BASH_REMATCH[3]}"
    before_stage="${BASH_REMATCH[5]:-}"
    before_number="${BASH_REMATCH[6]:-0}"
    [[ "$after" =~ $pattern ]] || return 2
    after_major="${BASH_REMATCH[1]}"
    after_minor="${BASH_REMATCH[2]}"
    after_patch="${BASH_REMATCH[3]}"
    after_stage="${BASH_REMATCH[5]:-}"
    after_number="${BASH_REMATCH[6]:-0}"

    for component in \
        "$before_major" "$before_minor" "$before_patch" "$before_number" \
        "$after_major" "$after_minor" "$after_patch" "$after_number"
    do
        if [[ ${#component} -gt 1 && "$component" == 0* ]]; then
            return 2
        fi
    done
    if [[ -n "$before_stage" && "$before_number" == 0 ]] || \
       [[ -n "$after_stage" && "$after_number" == 0 ]]; then
        return 2
    fi
    # CFBundleVersion permits four digits in the first component and two in
    # the second and third. Its development suffix permits three digits.
    if [[ ${#before_major} -gt 4 || ${#after_major} -gt 4 || \
          ${#before_minor} -gt 2 || ${#after_minor} -gt 2 || \
          ${#before_patch} -gt 2 || ${#after_patch} -gt 2 || \
          ${#before_number} -gt 3 || ${#after_number} -gt 3 ]]; then
        return 2
    fi

    if (( 10#$after_major > 10#$before_major )); then return 0; fi
    if (( 10#$after_major < 10#$before_major )); then return 1; fi
    if (( 10#$after_minor > 10#$before_minor )); then return 0; fi
    if (( 10#$after_minor < 10#$before_minor )); then return 1; fi
    if (( 10#$after_patch > 10#$before_patch )); then return 0; fi
    if (( 10#$after_patch < 10#$before_patch )); then return 1; fi

    if [[ -z "$before_stage" ]]; then
        return 1
    fi
    [[ -z "$after_stage" ]] && return 0
    case "$before_stage" in alpha) before_rank=1 ;; beta) before_rank=2 ;; rc) before_rank=3 ;; esac
    case "$after_stage" in alpha) after_rank=1 ;; beta) after_rank=2 ;; rc) after_rank=3 ;; esac
    if (( after_rank > before_rank )); then return 0; fi
    if (( after_rank < before_rank )); then return 1; fi
    (( 10#$after_number > 10#$before_number ))
}

verify_release_manifest_transition() {
    local before_sha="$1"
    local commit_sha="$2"
    local manifest="$3"
    local allow_unchanged="${4:-false}"
    local before_version version version_status diff_status

    if [[ ! "$before_sha" =~ ^[0-9a-f]{40}$ ]] || \
       ! git cat-file -e "$before_sha^{commit}" 2>/dev/null; then
        echo "error: BEFORE_SHA does not identify an available commit" >&2
        return 1
    fi
    if [[ ! "$commit_sha" =~ ^[0-9a-f]{40}$ ]] || \
       ! git cat-file -e "$commit_sha^{commit}" 2>/dev/null; then
        echo "error: COMMIT_SHA does not identify an available commit" >&2
        return 1
    fi
    if ! git merge-base --is-ancestor "$before_sha" "$commit_sha"; then
        echo "error: BEFORE_SHA is not an ancestor of COMMIT_SHA" >&2
        return 1
    fi
    if ! git cat-file -e "$before_sha:$manifest" 2>/dev/null || \
       ! git cat-file -e "$commit_sha:$manifest" 2>/dev/null; then
        echo "error: release manifest is unavailable across the claimed transition" >&2
        return 1
    fi
    if git diff --quiet "$before_sha" "$commit_sha" -- "$manifest"; then
        if [[ "$allow_unchanged" == "true" ]]; then
            return 3
        fi
        echo "error: release manifest did not change across the claimed transition" >&2
        return 1
    else
        diff_status=$?
        if [[ "$diff_status" -ne 1 ]]; then
            echo "error: could not verify the release manifest transition" >&2
            return 1
        fi
    fi

    before_version="$(git show "$before_sha:$manifest" | jq -er '.["."]')"
    version="$(git show "$commit_sha:$manifest" | jq -er '.["."]')"
    if semver_is_greater "$before_version" "$version"; then
        :
    else
        version_status=$?
        if [[ "$version_status" -eq 2 ]]; then
            echo "error: release manifest version cannot be represented safely as CFBundleVersion" >&2
        else
            echo "error: release version $version must be greater than $before_version" >&2
        fi
        return 1
    fi

    RELEASE_MANIFEST_VERSION="$version"
    RELEASE_MANIFEST_TAG="v$version"
}

verify_current_main_tip() {
    local auth_header
    local origin_main_sha

    auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64)"
    if ! GIT_CONFIG_COUNT=1 \
         GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
         GIT_CONFIG_VALUE_0="$auth_header" \
         git fetch --no-tags origin \
           "+refs/heads/main:refs/remotes/origin/main"; then
        echo "error: could not refresh the origin/main tip before release mutation" >&2
        return 1
    fi
    origin_main_sha="$(git rev-parse origin/main)"
    if [[ "$origin_main_sha" != "$COMMIT_SHA" ]]; then
        echo "error: origin/main tip no longer equals the release source" >&2
        return 1
    fi
}

verify_release_tag_target() {
    local auth_header
    local remote_tag
    local tag_target

    auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64)"
    if ! remote_tag="$(GIT_CONFIG_COUNT=1 \
        GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
        GIT_CONFIG_VALUE_0="$auth_header" \
        git ls-remote --tags --refs origin "refs/tags/$RELEASE_TAG")"; then
        echo "error: could not verify release tag $RELEASE_TAG" >&2
        return 1
    fi
    if [[ -n "$remote_tag" ]]; then
        if ! GIT_CONFIG_COUNT=1 \
             GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
             GIT_CONFIG_VALUE_0="$auth_header" \
             git fetch --no-tags origin \
               "+refs/tags/$RELEASE_TAG:refs/tags/$RELEASE_TAG"; then
            echo "error: could not fetch release tag $RELEASE_TAG" >&2
            return 1
        fi
        tag_target="$(git rev-parse "$RELEASE_TAG^{commit}")"
        if [[ "$tag_target" != "$COMMIT_SHA" ]]; then
            echo "error: tag $RELEASE_TAG targets $tag_target, not $COMMIT_SHA" >&2
            return 1
        fi
    fi
}
