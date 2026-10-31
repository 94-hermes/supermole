#!/bin/bash
# `mo uninstall --dry-run --json`: the batch preview as one JSON object for
# front ends (Supermole.app). It reads the plan the text preview renders
# (app_details, the personal-data review arrays and the scan's side arrays)
# and measures rows through the same parallel preview workers, so the two
# never disagree on what a real run would remove.

# One measured row of the preview: {"path": ..., "size_kb": N or null}.
_uninstall_plan_json_sized_row() {
    local path="$1" size_kb="" size_rc=0
    size_kb=$(get_path_size_kb "$path" 2> /dev/null) || size_rc=$?
    mole_rc_timeout_or_signal "$size_rc" && return "$size_rc"
    [[ $size_rc -eq 0 ]] || size_kb=""
    printf '{"path": %s, "size_kb": %s}' "$(mole_json_string "$path")" "$(mole_json_positive_or_null "$size_kb")"
}

# Newline-separated JSON values as one array.
_uninstall_plan_json_array() {
    local value first=1
    printf '['
    while IFS= read -r value; do
        [[ -n "$value" ]] || continue
        [[ $first -eq 1 ]] || printf ', '
        first=0
        printf '%s' "$value"
    done <<< "${1:-}"
    printf ']'
}

# The rows of a newline-separated path list that still exist, measured in
# review order like the text preview.
_uninstall_plan_json_sized_rows() {
    local rows="" rc=0
    rows=$(_uninstall_print_preview_paths "${1:-}" "" _uninstall_plan_json_sized_row) || rc=$?
    [[ $rc -eq 0 ]] || return "$rc"
    _uninstall_plan_json_array "$rows"
}

# Whether the first argument equals one of the others.
_uninstall_plan_json_listed() {
    local wanted="$1" item
    shift
    for item in "$@"; do
        [[ "$item" == "$wanted" ]] && return 0
    done
    return 1
}

_uninstall_plan_json_bool() {
    if "$@"; then printf 'true'; else printf 'false'; fi
}

# Appends one app of the plan to _plan_json_apps. Personal paths shared with
# an earlier app are listed once, under the first, as the text preview's
# de-duplicated list does. Runs in the renderer's shell (not a command
# substitution) so the list of paths already listed carries over.
# shellcheck disable=SC2154  # Arrays belong to the calling batch preview scope.
_uninstall_plan_json_add_app() {
    local detail="$1" review_index="$2"
    local app_name app_path bundle_id encoded_system_files needs_sudo_flag is_brew_cask cask_name
    local encoded_diag_system encoded_review_system
    IFS='|' read -r app_name app_path bundle_id _ _ encoded_system_files _ needs_sudo_flag is_brew_cask cask_name encoded_diag_system encoded_review_system _ <<< "$detail"

    local system_files diag_system review_system
    system_files=$(decode_file_list "$encoded_system_files" "$app_name")
    diag_system=$(decode_file_list "$encoded_diag_system" "$app_name")
    if [[ -n "$diag_system" ]]; then
        system_files=$(append_line "$system_files" "$diag_system")
    fi
    review_system=$(decode_file_list "$encoded_review_system" "$app_name")

    local leftovers_json system_json review_json
    leftovers_json=$(_uninstall_plan_json_sized_rows "${_review_auto_files[review_index]-}") || return $?
    system_json=$(_uninstall_plan_json_sized_rows "$system_files") || return $?
    review_json=$(_uninstall_plan_json_sized_rows "$review_system") || return $?

    local removed_data="" kept_rows="" personal_path
    while IFS= read -r personal_path; do
        [[ -n "$personal_path" ]] || continue
        if _uninstall_plan_json_listed "$personal_path" "${_plan_json_listed_personal[@]+"${_plan_json_listed_personal[@]}"}"; then
            continue
        fi
        _plan_json_listed_personal+=("$personal_path")
        if mole_identity_in_list "$personal_path" "${_review_selected_paths[@]+"${_review_selected_paths[@]}"}"; then
            removed_data=$(append_line "$removed_data" "$personal_path")
        else
            # Kept data is listed without a size probe, as in the text preview.
            kept_rows=$(append_line "$kept_rows" "{\"path\": $(mole_json_string "$personal_path")}")
        fi
    done <<< "${_review_personal_files[review_index]-}"
    local removed_json
    removed_json=$(_uninstall_plan_json_sized_rows "$removed_data") || return $?

    local notes="" leftover_note
    for leftover_note in "${leftover_notes[@]+"${leftover_notes[@]}"}"; do
        [[ "${leftover_note%%|*}" == "$app_path" ]] || continue
        notes=$(append_line "$notes" "$(mole_json_string "${leftover_note#*|}")")
    done

    local cask_json="null"
    [[ "$is_brew_cask" != "true" ]] || cask_json=$(mole_json_string "$cask_name")
    # Homebrew casks always open an admin session first (their hooks may
    # call sudo), like an app in a folder the user cannot write.
    local needs_admin=false
    if [[ "$is_brew_cask" == "true" || "$needs_sudo_flag" == "true" ]]; then
        needs_admin=true
    fi

    local app_json
    app_json=$(printf '{"name": %s, "path": %s, "bundle_id": %s, "homebrew_cask": %s, "running": %s, "needs_admin": %s, "steam_managed": %s, "size_kb": %s, "notes": %s, "leftovers": %s, "system": %s, "review_only": %s, "personal_data": {"remove": %s, "keep": %s}}' \
        "$(mole_json_string "$app_name")" \
        "$(mole_json_string "$app_path")" \
        "$(mole_json_string "$bundle_id")" \
        "$cask_json" \
        "$(_uninstall_plan_json_bool _uninstall_plan_json_listed "$app_name" "${running_apps[@]+"${running_apps[@]}"}")" \
        "$needs_admin" \
        "$(_uninstall_plan_json_bool uninstall_app_is_steam_launcher "$app_path")" \
        "$(mole_json_positive_or_null "${_review_app_sizes[review_index]-}")" \
        "$(_uninstall_plan_json_array "$notes")" \
        "$leftovers_json" \
        "$system_json" \
        "$review_json" \
        "$removed_json" \
        "$(_uninstall_plan_json_array "$kept_rows")") || return $?
    _plan_json_apps=$(append_line "$_plan_json_apps" "$app_json")
}

# Writes the plan to MOLE_UNINSTALL_PLAN_JSON_FILE. Called from the batch
# preview with its scope, or with an empty app_details when every selected
# app was blocked or left for manual removal, so the reasons still reach the
# caller. Reads app_details, the _review_* arrays, running_apps, sudo_apps,
# blocked_apps, manual_removal_apps, leftover_notes, total_estimated_size.
# shellcheck disable=SC2154  # Arrays belong to the calling batch scope.
_uninstall_render_plan_json() {
    local -a _plan_json_listed_personal=()
    local _plan_json_apps="" detail review_index=0
    for detail in "${app_details[@]+"${app_details[@]}"}"; do
        _uninstall_plan_json_add_app "$detail" "$review_index" || return $?
        review_index=$((review_index + 1))
    done

    local blocked="" blocked_detail blocked_name blocked_vendor
    for blocked_detail in "${blocked_apps[@]+"${blocked_apps[@]}"}"; do
        IFS='|' read -r blocked_name blocked_vendor <<< "$blocked_detail"
        blocked=$(append_line "$blocked" "{\"name\": $(mole_json_string "$blocked_name"), \"vendor\": $(mole_json_string "$blocked_vendor")}")
    done
    local manual="" manual_name
    for manual_name in "${manual_removal_apps[@]+"${manual_removal_apps[@]}"}"; do
        manual=$(append_line "$manual" "{\"name\": $(mole_json_string "$manual_name")}")
    done

    local with_data=false
    [[ "${MOLE_UNINSTALL_WITH_DATA:-0}" != "1" ]] || with_data=true
    printf '{"dry_run": true, "with_data": %s, "total_size_kb": %s, "apps": %s, "blocked": %s, "manual": %s}\n' \
        "$with_data" \
        "$(mole_json_positive_or_null "${total_estimated_size:-0}")" \
        "$(_uninstall_plan_json_array "$_plan_json_apps")" \
        "$(_uninstall_plan_json_array "$blocked")" \
        "$(_uninstall_plan_json_array "$manual")" > "$MOLE_UNINSTALL_PLAN_JSON_FILE"
}
