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
    local encoded=$1 line=$2 offset=$3 display=$4 highlight=${5:-1} signature encoding='' syntax=''
    local start=0 content_start=0 by_line=0 header_rows=0
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
    signature=${signature//[[:space:]]/}
    case "$signature" in
        fffe*) encoding=UTF-16LE ;;
        feff*) encoding=UTF-16BE ;;
        efbbbf*) offset=$((offset + 3)); content_start=3 ;;
    esac
    if [[ -n "$encoding" ]]; then
        printf '%s\n' "${display//[[:cntrl:]]/ }" '[Transcoded file: bounded decoding from the beginning]'
        header_rows=2
        by_line=1
        if ! command -v iconv >/dev/null 2>&1; then
            printf '%s\n' '[Install iconv to preview the file header]'
            return 0
        fi
    fi
    if [[ "$highlight" != 0 ]]; then
        case "$search_path" in
            *.py|*.pyi|*.pyw) syntax=python ;;
            *.c|*.C|*.cc|*.cpp|*.cxx|*.h|*.H|*.hh|*.hpp|*.hxx|*.cu|*.cuh) syntax=cpp ;;
            *.js|*.jsx|*.mjs|*.cjs|*.ts|*.tsx) syntax=javascript ;;
            *.sh|*.bash|*.zsh|*/.bashrc|*/.bash_profile|*/.zshrc) syntax=shell ;;
            *.vim|*/.vimrc) syntax=vim ;;
            *.json) syntax=json ;;
            *.yaml|*.yml) syntax=yaml ;;
        esac
    fi
    # Seek at most 32 KiB back for preceding context, then read at most 64 KiB total.
    # The renderer keeps only enough complete preceding lines to center the match.
    start=$((offset > content_start + 32768 ? offset - 32768 : content_start))
    # tail seeks on regular files; head bounds even a huge single line.
    # Early exits intentionally cause SIGPIPE in upstream processes.
    {
        if [[ -n "$encoding" ]]; then
            head -c 65536 -- "$search_path" | iconv -f "$encoding" -t UTF-8 2>/dev/null |
                head -c 65536
        else
            tail -c "+$((start + 1))" -- "$search_path" | head -c 65536
        fi
    } | LC_ALL=C "$search_awk_bin" -v match_line="$line" -v syntax="$syntax" \
        -v target_offset="$((offset - start))" -v skip_first="$((start > content_start))" \
        -v by_line="$by_line" -v header_rows="$header_rows" \
        -f "${search_script%/*}/search-preview.awk" || :
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
    local mode=$1 session=$2 history=$3 colors=$4 capabilities=${5:-} finder=${6:-} highlight=${7:-1}
    local command preview_command preview_window status record encoded rest line column export_command
    local initial='' count=0
    # Vim's libvterm can split a UTF-8 character between its default G0 decoder
    # and its UTF-8 decoder when PTY reads start with different byte classes.
    # ASCII G0 makes every non-ASCII byte use the same persistent UTF-8 decoder.
    # stderr is the terminal; stdout carries only selected NUL records.
    printf '\033(B' >&2
    # The explicit dark base keeps preview ANSI colors enabled even under NO_COLOR.
    local -a options=(--read0 --print0 --delimiter=$'\t' --with-nth=5..
        --multi --no-mouse --layout=default --border=rounded --info=inline
        --color="dark,$colors" --bind='ctrl-j:down,ctrl-k:up,esc:abort,ctrl-c:abort')
    # Prevent the user's global shell/fzf options from rewriting the result protocol or
    # mixing in other file sources.
    export SHELL="$BASH" FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE=''
    if [[ -z "$capabilities" ]]; then
        capabilities='baseline'
        if fzf_supports --scheme=path; then capabilities+=',path'; fi
        if fzf_supports --preview-window='right,55%,<40(down,50%)'; then
            capabilities+=',layout'
        fi
        if fzf_supports --bind='resize:refresh-preview'; then capabilities+=',resize'; fi
    fi
    printf '%s\n' "$capabilities" > "$session/capabilities"
    if [[ -n "$history" ]]; then options+=(--history="$history" --history-size=100); fi
    printf -v command 'exec %q %q' "$BASH" "$search_script"
    printf -v export_command 'printf quickfix > %q' "$session/export"
    options+=(--bind="ctrl-q:execute-silent($export_command)+accept"
        --header='Tab select  •  Enter open / export selected  •  Ctrl-q quickfix  •  Esc cancel')
    if [[ "$mode" == files ]]; then
        printf -v FZF_DEFAULT_COMMAND '%s files %q %q' "$command" "$session" "$finder"
        # Space separates multiple terms so "parent-dir filename" narrows same-named files;
        # a / in the path can still be typed directly.
        options+=(--prompt='Files> ' --extended)
        # Path scoring is supported from 0.33.0; older versions keep the default fuzzy score.
        if [[ "$capabilities" == *',path'* ]]; then options+=(--scheme=path); fi
    elif [[ "$mode" == grep ]]; then
        if [[ -f "$session/query" ]]; then initial=$(< "$session/query"); fi
        printf -v FZF_DEFAULT_COMMAND '%s query %q %q' "$command" "$session" "$initial"
        printf -v preview_command '%s preview {s1} {2} {4} {5..} %q' "$command" "$highlight"
        preview_window='right,55%,<40(down,50%)'
        # Automatic layout is supported from 0.31.0; older versions pin the preview below
        # so it stays readable on narrow screens.
        if [[ "$capabilities" != *',layout'* ]]; then
            preview_window='down,50%'
        fi
        options+=(--prompt='Live grep> ' --disabled --no-sort --query="$initial"
            --bind="change:reload:$command query $(printf '%q' "$session") {q}"
            --preview="$preview_command" --preview-window="$preview_window"
            --bind='ctrl-u:preview-half-page-up,ctrl-d:preview-half-page-down')
        if [[ "$capabilities" == *',resize'* ]]; then
            options+=(--bind='resize:refresh-preview')
        fi
    else
        printf -v FZF_DEFAULT_COMMAND '%s recent %q' "$command" "$session"
        options+=(--prompt='Recent> ' --no-sort)
    fi
    export FZF_DEFAULT_COMMAND
    if [[ "$mode" == grep ]]; then
        # rg already performs matching. A single Go scheduler coalesces bursts of
        # typed keys before reload, avoiding repeated cancel/restart poll delays.
        # Empty stdin also avoids starting a shell for the initial empty query.
        if [[ -n "$initial" ]]; then
            query "$session" "$initial" | GOMAXPROCS=1 fzf "${options[@]}" > "$session/selection"
        else
            GOMAXPROCS=1 fzf "${options[@]}" < /dev/null > "$session/selection"
        fi
    else
        fzf "${options[@]}" > "$session/selection"
    fi
    status=$?
    if (( status != 0 )); then
        if (( status != 1 && status != 130 )); then
            printf 'fzf failed (status %s); requires fzf 0.29.0 or newer\n' "$status" > "$session/error"
        fi
        return "$status"
    fi
    : > "$session/results"
    while IFS= read -r -d '' record; do
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
        printf '%s\n' "$record" >> "$session/results"
        if (( count == 0 )); then
            decode_path "$encoded"
            printf '%s' "$search_path" > "$session/path"
            printf '%s\n%s\n' "$line" "$column" > "$session/position"
        fi
        count=$((count + 1))
    done < "$session/selection"
    (( count > 0 )) || return 1
    if (( count > 1 )); then printf quickfix > "$session/export"; fi
}

case "${1:-}" in
    run) shift; run "$@" ;;
    files) shift; files "$@" ;;
    query) shift; query "$@" ;;
    preview) shift; preview "$@" ;;
    recent) shift; recent "$@" ;;
    *) printf 'Internal Vim search helper: run/files/query/preview/recent\n' >&2; exit 2 ;;
esac
