#!/usr/bin/env bash
# Internal interface: run / files / query / preview / recent, invoked by search.vim via bash.
set -uo pipefail
umask 077

search_script=${BASH_SOURCE[0]}
search_awk=${search_script%/*}/search.awk
# GNU awk reads NUL-delimited pipes incrementally. mawk can wait for a full
# input block even after fflush(), delaying sparse results until the scan ends.
search_awk_bin=gawk

# fzf uses NUL-separated records; the first four Tab fields are metadata and the fifth
# is display-only. Field separators in paths are encoded, and decoding only substitutes
# text, never executing file names or query contents.
decode_path() {
    search_path=${1//%09/$'\t'}
    search_path=${search_path//%0A/$'\n'}
    search_path=${search_path//%0D/$'\r'}
    search_path=${search_path//%1B/$'\e'}
    search_path=${search_path//%25/%}
}

error_record() {
    local message
    message=$(< "$1")
    message=${message//[[:cntrl:]]/ }
    printf '\t0\t0\t0\t%s\0' "${message:-search command failed}"
}

files() {
    local session=$1 finder=${2:-} status
    if [[ -z "$finder" ]]; then
        finder=$(command -v fd || command -v fdfind) || return 2
    fi
    "$finder" --type f --color never --print0 --exclude .git 2> "$session/fd-error" |
        LC_ALL=C "$search_awk_bin" -v mode=files -f "$search_awk"
    status=${PIPESTATUS[0]}
    if (( status != 0 && status != 141 )); then error_record "$session/fd-error"; fi
}

query() {
    local session=$1 pattern=$2 diagnostic status
    [[ -n "$pattern" ]] || return 0
    sleep 0.02
    diagnostic=$(mktemp "$session/rg.XXXXXX") || return 2
    search_diagnostic=$diagnostic
    trap 'rm -f -- "$search_diagnostic"' EXIT
    rg --no-config --null --with-filename --column --line-number --byte-offset \
        --line-buffered --no-heading --color=never \
        --smart-case --hidden --glob='!.git/' -- "$pattern" . 2> "$diagnostic" |
        LC_ALL=C "$search_awk_bin" -v mode=query -f "$search_awk"
    status=${PIPESTATUS[0]}
    if (( status > 1 && status != 141 )); then error_record "$diagnostic"; fi
}

preview() {
    local encoded=$1 line=$2 offset=$3 display=$4 signature encoding=''
    display=${display:0:500}
    if [[ -z "$encoded" ]]; then printf '%s\n' "$display"; return; fi
    decode_path "$encoded"
    [[ "$line" =~ ^[1-9][0-9]*$ && "$offset" =~ ^[0-9]+$ ]] || return 2
    if [[ ! -f "$search_path" || ! -r "$search_path" ]]; then
        printf '%s\n' "$display"
        return 0
    fi
    # rg offsets are measured after transcoding or stripping the BOM.
    signature=$(od -An -tx1 -N3 -- "$search_path")
    case "$signature" in
        *'ff fe'*) encoding=UTF-16LE ;;
        *'fe ff'*) encoding=UTF-16BE ;;
        *'ef bb bf'*) offset=$((offset + 3)) ;;
    esac
    if [[ -n "$encoding" ]]; then
        printf '%s\n' "${display//[[:cntrl:]]/ }" '[Transcoded file: preview starts at the beginning]'
        offset=0
        line=1
    fi
    # tail seeks on regular files; head bounds even a huge single line.
    # Early exits intentionally cause SIGPIPE in upstream processes.
    {
        if [[ -n "$encoding" ]]; then
            if command -v iconv >/dev/null 2>&1; then
                head -c 65536 -- "$search_path" | iconv -f "$encoding" -t UTF-8 2>/dev/null
            else
                printf '%s\n' '[Install iconv to preview the file header]'
            fi
        else
            tail -c "+$((offset + 1))" -- "$search_path" | head -c 65536
        fi
    } | LC_ALL=C "$search_awk_bin" -v first="$line" '
        {
            bytes += length($0) + 1
            text = $0
            gsub(/[[:cntrl:]]/, " ", text)
            if (length(text) > 500) {
                text = substr(text, 1, 500)
                sub(/[\300-\377][\200-\277]*$/, "", text)
                text = text " …"
                shortened = 1
            } else if (bytes >= 65536) {
                # The byte cap may end in the middle of a UTF-8 character.
                sub(/[\300-\377][\200-\277]*$/, "", text)
            }
            if (NR == 1) printf "\033[1;36m>%6d %s\033[0m\n", first, text
            else printf " %6d %s\n", first + NR - 1, text
            if (NR == 200) exit
        }
        END {
            if (NR == 200 || bytes >= 65536 || shortened)
                print "[Preview limited to 64 KiB / 200 lines / 500 bytes per line; Enter opens the file]"
        }
    ' || :
}

recent() {
    LC_ALL=C "$search_awk_bin" -v mode=recent -f "$search_awk" < "$1/recent"
}

# The empty-input filter mode does not open a terminal; 0/1 mean valid arguments, 2 means unsupported.
fzf_supports() {
    fzf "$@" --filter='' < /dev/null > /dev/null 2>&1
    [[ $? == [01] ]]
}

run() {
    local mode=$1 session=$2 history=$3 colors=$4 capabilities=${5:-} finder=${6:-}
    local command preview_command preview_window status record encoded rest line column
    local -a options=(--read0 --print0 --delimiter=$'\t' --with-nth=5..
        --no-multi --no-mouse --layout=default --border=rounded --info=inline
        --color="$colors" --bind='ctrl-j:down,ctrl-k:up,esc:abort,ctrl-c:abort')
    # Prevent the user's global shell/fzf options from rewriting the result protocol or
    # mixing in other file sources.
    export SHELL="$BASH" FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE=''
    if [[ -z "$capabilities" ]]; then
        capabilities='baseline'
        if fzf_supports --scheme=path; then capabilities+=',path'; fi
        if fzf_supports --preview-window='right,55%,<40(down,50%)'; then
            capabilities+=',layout'
        fi
    fi
    printf '%s\n' "$capabilities" > "$session/capabilities"
    if [[ -n "$history" ]]; then options+=(--history="$history" --history-size=100); fi
    printf -v command 'exec %q %q' "$BASH" "$search_script"
    if [[ "$mode" == files ]]; then
        printf -v FZF_DEFAULT_COMMAND '%s files %q %q' "$command" "$session" "$finder"
        # Space separates multiple terms so "parent-dir filename" narrows same-named files;
        # a / in the path can still be typed directly.
        options+=(--prompt='Files> ' --extended)
        # Path scoring is supported from 0.33.0; older versions keep the default fuzzy score.
        if [[ "$capabilities" == *',path'* ]]; then options+=(--scheme=path); fi
    elif [[ "$mode" == grep ]]; then
        printf -v FZF_DEFAULT_COMMAND '%s query %q %q' "$command" "$session" ''
        printf -v preview_command '%s preview {s1} {2} {4} {5..}' "$command"
        preview_window='right,55%,<40(down,50%)'
        # Automatic layout is supported from 0.31.0; older versions pin the preview below
        # so it stays readable on narrow screens.
        if [[ "$capabilities" != *',layout'* ]]; then
            preview_window='down,50%'
        fi
        options+=(--prompt='Live grep> ' --disabled --no-sort
            --bind="change:reload:$command query $(printf '%q' "$session") {q}"
            --preview="$preview_command" --preview-window="$preview_window"
            --bind='ctrl-u:preview-half-page-up,ctrl-d:preview-half-page-down')
    else
        printf -v FZF_DEFAULT_COMMAND '%s recent %q' "$command" "$session"
        printf -v preview_command '%s preview {s1} {2} {4} {5..}' "$command"
        preview_window='right,55%,<40(down,50%)'
        if [[ "$capabilities" != *',layout'* ]]; then
            preview_window='down,50%'
        fi
        options+=(--prompt='Recent> ' --no-sort
            --header='Recent files  •  Enter open  •  Esc cancel'
            --preview="$preview_command" --preview-window="$preview_window"
            --bind='ctrl-u:preview-half-page-up,ctrl-d:preview-half-page-down')
    fi
    export FZF_DEFAULT_COMMAND
    fzf "${options[@]}" > "$session/selection"
    status=$?
    if (( status != 0 )); then
        if (( status != 1 && status != 130 )); then
            printf 'fzf failed (status %s); requires fzf 0.29.0 or newer\n' "$status" > "$session/error"
        fi
        return "$status"
    fi
    IFS= read -r -d '' record < "$session/selection" || return 1
    encoded=${record%%$'\t'*}
    rest=${record#*$'\t'}
    line=${rest%%$'\t'*}
    rest=${rest#*$'\t'}
    column=${rest%%$'\t'*}
    if [[ -z "$encoded" ]]; then
        rest=${rest#*$'\t'}
        printf '%s\n' "${rest#*$'\t'}" > "$session/error"
        return 2
    fi
    [[ "$line" =~ ^[1-9][0-9]*$ && "$column" =~ ^[1-9][0-9]*$ ]] || return 2
    decode_path "$encoded"
    printf '%s' "$search_path" > "$session/path"
    printf '%s\n%s\n' "$line" "$column" > "$session/position"
}

case "${1:-}" in
    run) shift; run "$@" ;;
    files) shift; files "$@" ;;
    query) shift; query "$@" ;;
    preview) shift; preview "$@" ;;
    recent) shift; recent "$@" ;;
    *) printf 'Internal Vim search helper: run/files/query/preview/recent\n' >&2; exit 2 ;;
esac
