#!/bin/bash
# Mole - JSON strings for the commands that print JSON (history, clean).

set -euo pipefail

if [[ -n "${MOLE_JSON_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_JSON_LOADED=1

# Prints a value's JSON string body (without quotes). Control characters are
# escaped and the value is kept valid UTF-8, each invalid byte replaced.
mole_json_escape() {
    local value="${1:-}"
    local LC_ALL=C
    local char code idx width offset byte second_min second_max

    # Most paths are plain ASCII: print them whole instead of byte by byte,
    # which made a 1,000-item clean preview take seconds.
    if [[ "$value" =~ ^[\ -~]*$ && "$value" != *[\"\\]* ]]; then
        printf '%s' "$value"
        return 0
    fi

    idx=0
    while [[ "$idx" -lt "${#value}" ]]; do
        char="${value:$idx:1}"
        case "$char" in
            "\\") printf '%s' "\\\\" ;;
            "\"") printf '%s' "\\\"" ;;
            $'\b') printf '%s' "\\b" ;;
            $'\f') printf '%s' "\\f" ;;
            $'\n') printf '%s' "\\n" ;;
            $'\r') printf '%s' "\\r" ;;
            $'\t') printf '%s' "\\t" ;;
            *)
                printf -v code '%d' "'$char"
                if [[ "$code" -lt 0 ]]; then
                    code=$((code + 256))
                fi
                if [[ "$code" -lt 32 ]]; then
                    printf '\\u%04x' "$code"
                elif [[ "$code" -lt 128 ]]; then
                    printf '%s' "$char"
                else
                    # Bash holds filename bytes, but JSON strings require UTF-8.
                    # Keep canonical scalar sequences; replace each invalid byte.
                    width=0
                    second_min=128
                    second_max=191
                    if [[ "$code" -ge 194 && "$code" -le 223 ]]; then
                        width=2
                    elif [[ "$code" -ge 224 && "$code" -le 239 ]]; then
                        width=3
                        [[ "$code" -ne 224 ]] || second_min=160
                        [[ "$code" -ne 237 ]] || second_max=159
                    elif [[ "$code" -ge 240 && "$code" -le 244 ]]; then
                        width=4
                        [[ "$code" -ne 240 ]] || second_min=144
                        [[ "$code" -ne 244 ]] || second_max=143
                    fi
                    if [[ $((idx + width)) -gt "${#value}" ]]; then
                        width=0
                    fi
                    for ((offset = 1; offset < width; offset++)); do
                        printf -v byte '%d' "'${value:$((idx + offset)):1}"
                        byte=$((byte & 255))
                        if [[ "$byte" -lt 128 || "$byte" -gt 191 ]] ||
                            { [[ "$offset" -eq 1 ]] && [[ "$byte" -lt "$second_min" || "$byte" -gt "$second_max" ]]; }; then
                            width=0
                            break
                        fi
                    done
                    if [[ "$width" -gt 0 ]]; then
                        printf '%s' "${value:$idx:$width}"
                        idx=$((idx + width))
                        continue
                    fi
                    printf '%s' '\ufffd'
                fi
                ;;
        esac
        idx=$((idx + 1))
    done
}

mole_json_string() {
    printf '"'
    mole_json_escape "${1:-}"
    printf '"'
}
