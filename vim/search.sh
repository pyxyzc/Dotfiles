#!/usr/bin/env bash
# 内部接口：run / files / query / preview。由 search.vim 使用 bash 显式调用。
set -uo pipefail
umask 077

search_script=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/search.sh

# fzf 使用 NUL 分隔记录，前三个 Tab 字段为元数据，第四字段只用于显示。
# 对路径中的字段分隔符编码，解码只做替换，绝不执行文件名或查询内容。
encode_path() {
    search_encoded=${1//%/%25}
    search_encoded=${search_encoded//$'\t'/%09}
    search_encoded=${search_encoded//$'\n'/%0A}
    search_encoded=${search_encoded//$'\r'/%0D}
    search_encoded=${search_encoded//$'\e'/%1B}
}

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
    printf '\t0\t0\t%s\0' "${message:-search command failed}"
}

files() {
    local session=$1 finder path display status
    finder=$(command -v fd || command -v fdfind) || return 2
    "$finder" --type f --color never --print0 --exclude .git 2> "$session/fd-error" |
        while IFS= read -r -d '' path; do
            path=${path#./}
            encode_path "$path"
            display=${path//[[:cntrl:]]/?}
            printf '%s\t1\t1\t%s\0' "$search_encoded" "$display"
        done
    status=${PIPESTATUS[0]}
    if (( status != 0 && status != 141 )); then error_record "$session/fd-error"; fi
}

query() {
    local session=$1 pattern=$2 diagnostic path match line column text status
    [[ -n "$pattern" ]] || return 0
    sleep 0.1
    diagnostic=$(mktemp "$session/rg.XXXXXX") || return 2
    search_diagnostic=$diagnostic
    trap 'rm -f -- "$search_diagnostic"' EXIT
    rg --no-config --null --column --line-number --no-heading --color=never \
        --smart-case --hidden --glob='!.git/' -- "$pattern" . 2> "$diagnostic" |
        while IFS= read -r -d '' path && IFS= read -r match; do
            path=${path#./}
            line=${match%%:*}
            match=${match#*:}
            column=${match%%:*}
            text=${match#*:}
            encode_path "$path"
            text=${text//[[:cntrl:]]/ }
            printf '%s\t%s\t%s\t%s:%s:%s:%s\0' "$search_encoded" "$line" "$column" \
                "${path//[[:cntrl:]]/?}" "$line" "$column" "$text"
        done
    status=${PIPESTATUS[0]}
    if (( status > 1 && status != 141 )); then error_record "$diagnostic"; fi
}

preview() {
    local encoded=$1 line=$2 display=$3
    if [[ -z "$encoded" ]]; then printf '%s\n' "$display"; return; fi
    decode_path "$encoded"
    [[ "$line" =~ ^[0-9]+$ ]] || return 2
    # 保留全文供 fzf 滚动，初始滚动位置由行号决定；剔除文件内控制字符。
    awk -v target="$line" '
        {
            gsub(/[[:cntrl:]]/, " ")
            if (NR == target) printf "\033[1;36m>%6d %s\033[0m\n", NR, $0
            else printf " %6d %s\n", NR, $0
        }
    ' < "$search_path"
}

# 空输入的 filter 模式不打开终端；0/1 表示参数有效，2 表示不支持。
fzf_supports() {
    fzf "$@" --filter='' < /dev/null > /dev/null 2>&1
    [[ $? == [01] ]]
}

run() {
    local mode=$1 session=$2 history=$3 colors=$4 command preview_command preview_window status record encoded rest line column
    local -a options=(--read0 --print0 --delimiter=$'\t' --with-nth=4..
        --no-multi --no-mouse --layout=default --border=rounded --info=inline
        --color="$colors" --bind='ctrl-j:down,ctrl-k:up,esc:abort,ctrl-c:abort')
    # 避免用户的 shell/fzf 全局选项改写结果协议或混入其他文件来源。
    export SHELL="$BASH" FZF_DEFAULT_OPTS='' FZF_DEFAULT_OPTS_FILE=''
    if [[ -n "$history" ]]; then options+=(--history="$history" --history-size=100); fi
    printf -v command '%q %q' "$BASH" "$search_script"
    if [[ "$mode" == files ]]; then
        printf -v FZF_DEFAULT_COMMAND '%s files %q' "$command" "$session"
        # 空格分隔多个词，便于用“父目录 文件名”缩小同名文件；路径中的 / 仍可直接输入。
        options+=(--prompt='Files> ' --extended)
        # 0.33.0 起支持路径评分；旧版保留默认模糊评分。
        if fzf_supports --scheme=path; then options+=(--scheme=path); fi
    else
        printf -v FZF_DEFAULT_COMMAND '%s query %q %q' "$command" "$session" ''
        printf -v preview_command '%s preview {s1} {2} {4..}' "$command"
        preview_window='right,55%,+{2}/2,<40(down,50%,+{2}/2)'
        # 0.31.0 起支持自动布局；旧版固定下方预览，保证窄屏可读。
        if ! fzf_supports --preview-window="$preview_window"; then
            preview_window='down,50%,+{2}/2'
        fi
        options+=(--prompt='Live grep> ' --disabled --no-sort
            --bind="change:reload:$command query $(printf '%q' "$session") {q}"
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
    *) printf 'Internal Vim search helper: run/files/query/preview\n' >&2; exit 2 ;;
esac
