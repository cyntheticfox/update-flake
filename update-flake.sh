#!/usr/bin/env bash
# Usage: $0 /path/to/flakedir /path/to/inputs

readonly DEFAULT_IFS=$IFS

readonly FLAKE_DIR="${1:-.}"

# Hardly good practice, but some tools like `nix flake check` don't support flake refs, just the current directory
pushd "$FLAKE_DIR" 1> /dev/null || exit 3

readonly LOCKFILE="$FLAKE_DIR/flake.lock"
INPUTS_FILE=$(cat "${2:-inputs.csv}")
INPUTS_FILE="${INPUTS_FILE#*
}"

print_final_update_result_md() {
    local RESULT_TYPE="$1"
    local INPUTS=''
    local COUNT=0
    local INPUT_STR='input'
    local HEADER=''

    shift 1

    while [ -n "$1" ]; do
        INPUTS="$(printf '%s\n- %s' "$INPUTS" "$1")"
        COUNT="$(( COUNT + 1 ))"
        shift 1
    done

    if [ "$COUNT" -ne 1 ]; then
        INPUT_STR="${INPUT_STR}s"
    fi

    case "$RESULT_TYPE" in
        'FAIL')
            HEADER='Failed'
            DESC="$INPUT_STR failed to update"
            ;;
        'NONE')
            HEADER='None Available'
            DESC="$INPUT_STR had no update available"
            ;;
        'PASS')
            HEADER='Succeeded'
            DESC="$INPUT_STR successfully updated"
            ;;
        *)
            printf 'ERR: printf_final_update_result_md() - Unknown RESULT_TYPE of "%s"' "$RESULT_TYPE"
            return 1
            ;;
    esac

    printf '## %s\n\n%2u %s:\n%s\n\n' "$HEADER" "$COUNT" "$DESC" "$INPUTS"
    return 0
}

GENERAL_FLAGS=(
    "--accept-flake-config"
    "--no-warn-dirty"
)

# TODO: Waiting on https://github.com/NixOS/nix/issues/6453#issuecomment-1518117282 to ignore custom outputs
# TODO: Waiting on https://github.com/NixOS/nix/issues/7230 for hiding saved value use
FLAKE_CHECK_FLAGS=(
    "${GENERAL_FLAGS[@]}"
    "--no-update-lock-file"
    "--no-write-lock-file"
    "--no-use-registries"
)

readonly CHECK_UPDATE_CMD='curl --location --silent'
readonly UPDATE_INPUT_CMD="nix flake update ${GENERAL_FLAGS[*]} --flake $FLAKE_DIR"
# UPDATE_INPUT_CMD="nix flake lock ${GENERAL_FLAGS[*]} --update-input"
# EVAL_CHECK_CMD="nix flake check --no-build ${FLAKE_CHECK_FLAGS[*]}"
readonly BUILD_CHECK_CMD="nix flake check ${FLAKE_CHECK_FLAGS[*]}"

if [ ! -f "$LOCKFILE" ]; then
    printf 'Cannot find lock file "%s".\n' "$LOCKFILE"
    exit 1
elif [ ! -r "$LOCKFILE" ]; then
    printf 'Lock file "%s" is not readable.\n' "$LOCKFILE"
    exit 7
elif [ ! -w "$LOCKFILE" ]; then
    printf 'Lock file "%s" is not writable.\n' "$LOCKFILE"
    exit 8
fi

PASS=()
NONE=()
FAIL=()

# NOTE: No point in making this parallel as Nix will just complain... I think
NEWLINE_IFS='
'

IFS=$NEWLINE_IFS
for INPUT in $INPUTS_FILE; do
    IFS=$DEFAULT_IFS
    IFS=',' read -ra INPUT_ARRAY <<<"$INPUT"

    INPUT_NAME="${INPUT_ARRAY[0]}"
    INPUT_HASH="${INPUT_ARRAY[1]}"
    INPUT_TYPE="${INPUT_ARRAY[2]}"
    INPUT_URL="${INPUT_ARRAY[3]}"
    FOUND_HASH=''

    printf 'Checking for available update for "%s"\n' "$INPUT_NAME"

    if [ "$INPUT_TYPE" == 'github' ]; then
        RESPONSE=$($CHECK_UPDATE_CMD -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$INPUT_URL")

        # Pretty sure this is how to do it...
        # shellcheck disable=SC2181
        if [ $? -ne 0 ]; then
            printf 'Unable to check input "%s". Possible rate limiting?\n' "$INPUT_NAME"

            FAIL+=("$INPUT_NAME: Resolution failed")

            continue
        fi

        FOUND_HASH="$(printf '%s' "$RESPONSE" | jq '.sha' -r)"

        if [ "$FOUND_HASH" == "$INPUT_HASH" ]; then
            printf 'No update available for "%s".\n' "$INPUT_NAME"

            NONE+=("$INPUT_NAME")

            continue
        fi
    elif [ "$INPUT_TYPE" == 'gitlab' ] || [ "$INPUT_TYPE" == 'sourcehut' ]; then
        RESPONSE=$($CHECK_UPDATE_CMD -H 'Accept: application/json' "$INPUT_URL")

        # shellcheck disable=SC2181
        if [ $? -ne 0 ]; then
            printf 'Unable to check input "%s". Possible rate limiting?\n' "$INPUT_NAME"

            FAIL+=("$INPUT_NAME: Resolution failed")

            continue
        fi

        FOUND_HASH="$(printf '%s' "$RESPONSE" | jq '.id' -r)"

        if [ "$FOUND_HASH" == "$INPUT_HASH" ]; then
            printf 'No update available for "%s".\n' "$INPUT_NAME"

            PASS+=("$INPUT_NAME")

            continue
        fi
    else
        printf 'Unable to check "%s" without attempting update for "%s" type. Assuming update available.\n' "$INPUT_NAME" "$INPUT_TYPE"
    fi

    ORIGINAL_FLAKE="$(cat "$LOCKFILE")"

    printf 'Attempting to update "%s".\n' "$INPUT_NAME"

    if ! $UPDATE_INPUT_CMD "$INPUT_NAME" "${NIX_FLAKE_FLAGS[@]}"; then
        printf 'Unable to update input "%s".\n' "$INPUT_NAME"
        printf '%s' "$ORIGINAL_FLAKE" >"$LOCKFILE"

        FAIL+=("$INPUT_NAME: Update failed")

        continue
    fi

    # printf 'Testing flake eval for "%s".\n' "$INPUT_NAME"

    # TODO: Find way around IFD
    #
    # if ! $EVAL_CHECK_CMD; then
    #     printf 'Check eval for updated input "%s" failed.\n' "$INPUT_NAME"
    #     printf '%s' "$ORIGINAL_FLAKE" >$LOCKFILE
    #
    #     FAIL+=("$INPUT_NAME: Check eval failed")
    #
    #     continue
    # fi

    # NOTE: This only works on the current $SYSTEM
    printf 'Testing flake outputs build for "%s".\n' "$INPUT_NAME"

    if ! $BUILD_CHECK_CMD; then
        printf 'Check build for updated input "%s" failed.\n' "$INPUT_NAME"
        printf '%s' "$ORIGINAL_FLAKE" >"$LOCKFILE"

        FAIL+=("$INPUT_NAME: Check build failed")

        continue
    fi

    PASS+=("$INPUT_NAME")
done

# Assuming a reasonable max of 2
printf '\n=================\n# Update Results\n\nUpdate flake script completed.\n\n'
print_final_update_result_md 'NONE' "${NONE[@]}"
print_final_update_result_md 'PASS' "${PASS[@]}"
print_final_update_result_md 'FAIL' "${FAIL[@]}"
printf '=================\n'

# Undo the move we did
popd 1> /dev/null || exit 4
