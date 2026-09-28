#!/usr/bin/env bash
set -euo pipefail

target_dir="${HOME}"
assume_yes=0

usage() {
    cat <<'EOF'
用法：vim-clean.sh [--target-dir DIR] [--yes]

删除目标用户目录中的 Vim 配置、Vim 本地数据，以及本配置使用的 vim-lite 状态。
  --target-dir DIR  目标用户目录，默认当前用户的 $HOME
  --yes             不询问确认，直接删除
  -h, --help        显示帮助

不会删除系统安装的 Vim，也不会修改 shell 或其他应用的配置。
EOF
}

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

while (( $# )); do
    case "$1" in
        --target-dir)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die '--target-dir 需要一个目录'
            target_dir="$2"
            shift 2
            ;;
        --yes) assume_yes=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "未知参数：$1" ;;
    esac
done

[[ -d "$target_dir" ]] || die "目录不存在：$target_dir"
target_dir="$(cd -- "$target_dir" && pwd -P)"
[[ "$target_dir" != / ]] || die '拒绝将文件系统根目录作为目标'

targets=(
    "$target_dir/.vim"
    "$target_dir/.vimrc"
    "$target_dir/.vimrc.local"
    "$target_dir/.gvimrc"
    "$target_dir/.gvimrc.local"
    "$target_dir/.viminfo"
    "$target_dir/.viminfo.tmp"
    "$target_dir/_viminfo"
    "$target_dir/.config/vim"
    "$target_dir/.local/share/vim"
    "$target_dir/.cache/vim"
    "$target_dir/.local/state/vim-lite"
)
shopt -s nullglob
targets+=(
    "$target_dir"/.vimrc.bak.*
    "$target_dir"/.vimrc.tmp.*
    "$target_dir"/.gvimrc.bak.*
    "$target_dir"/.viminfo.bak.*
    "$target_dir"/.viminfo.tmp.*
)

printf '将删除以下 Vim 配置和数据：\n'
found=0
for path in "${targets[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
        printf '  %s\n' "$path"
        found=1
    fi
done
if (( ! found )); then
    printf '未找到 Vim 配置或数据。\n'
    exit 0
fi

if (( ! assume_yes )); then
    read -r -p '确认删除？[y/N] ' answer || answer=''
    [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || {
        printf '已取消。\n'
        exit 0
    }
fi

for path in "${targets[@]}"; do
    if [[ -e "$path" || -L "$path" ]]; then
        rm -rf -- "$path"
        printf '已删除：%s\n' "$path"
    fi
done
