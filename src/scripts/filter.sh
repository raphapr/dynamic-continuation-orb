# shellcheck disable=SC2288,SC2001,SC2148,SC2153


shopt -s nullglob


error()
{
    if [ $# -ne 1 ]; then
        printf "Function \"error\" expected at least 1 argument: error message.\\n" >&2
        exit 1
    fi

    local msg
    msg="$1"

    printf "ERROR: %s\\n" "$msg" >&2
}


warn()
{
    if [ $# -ne 1 ]; then
        printf "Function \"warn\" expected at least 1 argument: warn message.\\n" >&2
        exit 1
    fi

    local msg
    msg="$1"

    printf "WARN: %s\\n" "$msg" >&2
}


info()
{
    if [ $# -ne 1 ]; then
        printf "Function \"info\" expected at least 1 argument: info message.\\n" >&2
        exit 1
    fi

    local msg
    msg="$1"

    printf "INFO: %s\\n" "$msg"
}


debug()
{
    if [ $# -ne 1 ]; then
        printf "Function \"debug\" expected at least 1 argument: debug message.\\n" >&2
        exit 1
    fi

    local msg
    msg="$1"

    if [ "$SH_DYNAMIC_CONTINUATION_DEBUG" -eq 1 ]; then
        printf "DEBUG: %s\\n" "$msg"
    fi
}


# Parse environment variables referencing env vars set by CircleCI.
if [ "${SH_CIRCLE_TOKEN:0:1}" = '$' ]; then
    _CIRCLE_TOKEN="$(eval echo "$SH_CIRCLE_TOKEN")"
else
    _CIRCLE_TOKEN="$SH_CIRCLE_TOKEN"
fi

if [ "${SH_CIRCLE_ORGANIZATION:0:1}" = '$' ]; then
    _CIRCLE_ORGANIZATION="$(eval echo "$SH_CIRCLE_ORGANIZATION")"
else
    _CIRCLE_ORGANIZATION="$SH_CIRCLE_ORGANIZATION"
fi

# CircleCI API token should be set.
if [ -z "$_CIRCLE_TOKEN" ]; then
    error "must set CircleCI token for successful authentication."
    exit 1
fi


# Move yaml files -> yml so we can handle both extensions for YAML configs. Not that we want both, but we should handle both cases.
for f in .circleci/*.yaml; do
    warn "migrating pipeline \"$f\" -> \"${f%.*}.yml\""
    if [ -f "${f%.*}.yml" ]; then
        error "could not migrate \"$f\", \"${f%.*}.yml\" already exists."
        exit 1
    fi
    mv "$f" "${f%.*}.yml"
done


# If auto-detecting is enabled (or modules aren't set), check for configs in .circleci/.
if [ "$SH_AUTO_DETECT" -eq 1 ] || [ "$SH_MODULES" = "" ]; then
    # We need to determine what the modules are, ignoring SH_MODULES if it is set.
    SH_MODULES="$(find .circleci/ -type f -name "*.yml" | grep -oP "(?<=.circleci/).*(?=.yml)" | grep -vP "^/?(config)$" | sed "s@${SH_ROOT_CONFIG}@.@")"
    info "auto-detected the following modules:

$SH_MODULES
"
fi


# Add each module to `modules-filtered` if 1) `force-all` is set to `true`, or 2) there is a diff against main at HEAD, or 3) no workflow runs have occurred on the default branch for this project in the past $SH_REPORTING_WINDOW days.
if [ "$SH_FORCE_ALL" -eq 1 ] || { [ "$SH_REPORTING_WINDOW" != "" ] && [ "$(curl -s -X GET --url "https://circleci.com/api/v2/insights/${SH_PROJECT_TYPE}/${_CIRCLE_ORGANIZATION}/${CIRCLE_PROJECT_REPONAME}/workflows?reporting-window=${SH_REPORTING_WINDOW}" --header "Circle-Token: ${_CIRCLE_TOKEN}" | jq -r "[ .items[].name ] | length")" -eq "0" ]; }; then
    info "running all workflows."
    printf "%s" "$SH_MODULES" | awk NF | while read -r module; do
        module_dots="$(sed 's@\/@\.@g' <<< "$module")"
        if [ "${#module_dots}" -gt 1 ] && [ "${module_dots::1}" = "." ]; then
            module_dots="${module_dots:1}"
        fi
        if [ "${#module_dots}" -gt 1 ] && [ "${module_dots: -1}" = "." ]; then
            module_dots="${module_dots::-1}"
        fi

        printf "%s\\n" "$module_dots" >> "$SH_MODULES_FILTERED"
    done
else
    pip install --quiet --disable-pip-version-check --no-input wildmatch=="$SH_WILDMATCH_VERSION"
    printf "%s" "$SH_MODULES" | awk NF | while read -r module; do
        module_dots="$(sed 's@\/@\.@g' <<< "$module")"
        if [ "${#module_dots}" -gt 1 ] && [ "${module_dots::1}" = "." ]; then
            module_dots="${module_dots:1}"
        fi
        if [ "${#module_dots}" -gt 1 ] && [ "${module_dots: -1}" = "." ]; then
            module_dots="${module_dots::-1}"
        fi

        module_slashes="$(sed 's@\.@\/@g' <<< "$module")"
        if [ "${#module_slashes}" -gt 1 ] && [ "${module_slashes::1}" = "/" ]; then
            module_slashes="${module_slashes:1}"
        fi
        if [ "${#module_slashes}" -gt 1 ] && [ "${module_slashes: -1}" = "/" ]; then
            module_slashes="${module_slashes::-1}"
        fi

        # Handle root module "."
        if [ "${module_dots}" = "." ]; then
            # Handle non-root modules
            if [ ! -f ".circleci/${SH_ROOT_CONFIG}.ignore" ]; then
                warn "creating default ignore file for \".circleci/${SH_ROOT_CONFIG}.yml\": \"${SH_ROOT_CONFIG}.ignore\""
                touch ".circleci/${SH_ROOT_CONFIG}.ignore"
            fi

            if [ "$CIRCLE_BRANCH" = "$SH_DEFAULT_BRANCH" ]; then
                if [ "$(git diff-tree --no-commit-id --name-only -r HEAD~"$SH_SQUASH_MERGE_LOOKBEHIND" "$SH_DEFAULT_BRANCH" . | awk NF | wildmatch -c ".circleci/$SH_ROOT_CONFIG.ignore")" != "" ] || { [ "$SH_INCLUDE_CONFIG_CHANGES" -eq 1 ] && [ "$(git diff-tree --no-commit-id --name-only -r HEAD~"$SH_SQUASH_MERGE_LOOKBEHIND" "$SH_DEFAULT_BRANCH" ".circleci/$SH_ROOT_CONFIG.yml" | awk NF)" != "" ]; }; then
                    printf "%s\\n" "$module_dots" >> "$SH_MODULES_FILTERED"
                    info "including \"/$module_slashes\" corresponding workflow \".circleci/${module_dots}.yml\""
                fi
            else
                if [ "$(git diff-tree --no-commit-id --name-only -r HEAD "$SH_DEFAULT_BRANCH" . | awk NF | wildmatch -c ".circleci/$SH_ROOT_CONFIG.ignore")" != "" ] || { [ "$SH_INCLUDE_CONFIG_CHANGES" -eq 1 ] && [ "$(git diff-tree --no-commit-id --name-only -r HEAD "$SH_DEFAULT_BRANCH" ".circleci/$SH_ROOT_CONFIG.yml" | awk NF)" != "" ]; }; then
                    printf "%s\\n" "$module_dots" >> "$SH_MODULES_FILTERED"
                    info "including \"/$module_slashes\" corresponding workflow \".circleci/${module_dots}.yml\""
                fi
            fi

            continue
        fi

        # Handle non-root modules
        if [ ! -f ".circleci/${module_dots}.ignore" ]; then
            # Create a default
            warn "creating default ignore file for \".circleci/${module_dots}.yml\": .circleci/${module_dots}.ignore"
            touch ".circleci/${module_dots}.ignore"

            cat << IGNORE > ".circleci/${module_dots}.ignore"
# Ignore everything outside of the target directory users can add and remove files from here.
*
.*
!/${module_slashes}/
IGNORE
        else
            # User provided their own gitignore.
            info "user provided their own gitignore \".circleci/${module_dots}.ignore\" for \".circleci/${module_dots}.yml\" workflow."
            cat << IGNORE > ".circleci/${module_dots}.ignore.tmp"
# Ignore everything outside of the target directory users can add and remove files from here.
*
.*
!/${module_slashes}/
IGNORE

            # Concatenate generated ignore with user-provided config.
            mv ".circleci/${module_dots}.ignore" ".circleci/${module_dots}.ignore.bak"
            cat ".circleci/${module_dots}.ignore.tmp" ".circleci/${module_dots}.ignore.bak" > ".circleci/${module_dots}.ignore"
            rm ".circleci/${module_dots}.ignore.bak" ".circleci/${module_dots}.ignore.tmp"
        fi

        if [ "$CIRCLE_BRANCH" = "$SH_DEFAULT_BRANCH" ]; then
            if [ "$(git diff-tree --no-commit-id --name-only -r HEAD~"$SH_SQUASH_MERGE_LOOKBEHIND" "$SH_DEFAULT_BRANCH" . | awk NF | wildmatch -c ".circleci/${module_dots}.ignore")" != "" ] || { [ "$SH_INCLUDE_CONFIG_CHANGES" -eq 1 ] && [ "$(git diff-tree --no-commit-id --name-only -r HEAD~"$SH_SQUASH_MERGE_LOOKBEHIND" "$SH_DEFAULT_BRANCH" .circleci/"$module_dots".yml | awk NF)" != "" ]; }; then
                printf "%s\\n" "$module_dots" >> "$SH_MODULES_FILTERED"
                info "including \"/$module_slashes\" corresponding workflow \".circleci/${module_dots}.yml\""
            fi
        else
            if [ "$(git diff-tree --no-commit-id --name-only -r HEAD "$SH_DEFAULT_BRANCH" . | awk NF | wildmatch -c ".circleci/${module_dots}.ignore")" != "" ] || { [ "$SH_INCLUDE_CONFIG_CHANGES" -eq 1 ] && [ "$(git diff-tree --no-commit-id --name-only -r HEAD "$SH_DEFAULT_BRANCH" .circleci/"$module_dots".yml | awk NF)" != "" ]; }; then
                printf "%s\\n" "$module_dots" >> "$SH_MODULES_FILTERED"
                info "including \"/$module_slashes\" corresponding workflow \".circleci/${module_dots}.yml\""
            fi
        fi
    done
fi
