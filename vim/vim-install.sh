#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
install_target="${HOME}"
config_only=0
staged=''

# Required files are registered only here; preflight, occupancy checks and install share the list.
config_files=(
    dashboard.vim
    lsp.vim
    clipboard.vim
    tree.vim
    buffers.vim
    edit.vim
    textobjects.vim
    terminal.vim
    git.vim
    search.vim
    search.sh
)
color_files=(
    colors/tokyonight-night.vim
    colors/LICENSE.tokyonight
    colors/README.md
)
plugin_files=(
    vendor/vim-lsp/plugin/lsp.vim
    vendor/vim-lsp/autoload/lsp.vim
    vendor/vim-lsp/LICENSE
    vendor/vim-lsp/LICENSE-THIRD-PARTY
    vendor/vim-lsp/SOURCE.md
)

usage() {
    cat <<'EOF'
用法：vim-install.sh [--config-only] [--target-dir DIR]

默认：检查 Vim，缺失或功能不足时通过系统包管理器安装；备份并复制配置、主题和固定版本 LSP 客户端。
  --config-only     仅复制配置、主题和 LSP 客户端，不检查依赖，不使用网络
  --target-dir DIR  配置目标用户目录，默认当前用户的 $HOME
  -h, --help        显示帮助

只为系统软件安装调用 sudo；请以目标用户身份运行整个脚本。
支持 apt-get、dnf、yum、apk、pacman、zypper，不下载任何 Vim 插件。
搜索需要 fd/fdfind、ripgrep 和 fzf 0.29.0+；缺少时只提示，不自动安装。
LSP 使用本目录保存的 vim-lsp；Pyright/clangd 由用户自行安装，缺失时只提示。
EOF
}

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

while (( $# )); do
    case "$1" in
        --config-only) config_only=1; shift ;;
        --target-dir)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die '--target-dir 需要一个目录'
            install_target="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "未知参数：$1" ;;
    esac
done

[[ -f "$script_dir/.vimrc" ]] || die '缺少 .vimrc，请复制完整的 vim 目录'
for required in "${config_files[@]}" "${color_files[@]}" "${plugin_files[@]}"; do
    [[ -f "$script_dir/$required" ]] || die "缺少 $required，请复制完整的 vim 目录"
done
[[ ! -e "$install_target" || -d "$install_target" ]] || die "不是目录：$install_target"

vim_usable() {
    command -v vim >/dev/null 2>&1 || return 1
    vim -Nu NONE -i NONE -n -es \
        -c 'if v:version < 800 || !has("eval") || !has("syntax") || !has("folding") || !exists("*getbufinfo") | cquit | endif' \
        -c 'qa!' </dev/null >/dev/null 2>&1
}

if (( ! config_only )); then
    if vim_usable; then
        printf 'Vim 已可用，跳过系统软件安装。\n'
    else
        elevate=()
        if (( EUID != 0 )); then
            command -v sudo >/dev/null 2>&1 || die '安装 Vim 需要 root 或 sudo；也可使用 --config-only'
            elevate=(sudo)
        fi
        printf '安装 Vim（此步骤可能需要联网访问系统软件仓库）……\n'
        if command -v apt-get >/dev/null 2>&1; then
            "${elevate[@]}" apt-get update
            "${elevate[@]}" apt-get install -y vim
        elif command -v dnf >/dev/null 2>&1; then
            "${elevate[@]}" dnf install -y vim-enhanced
        elif command -v yum >/dev/null 2>&1; then
            "${elevate[@]}" yum install -y vim-enhanced
        elif command -v apk >/dev/null 2>&1; then
            "${elevate[@]}" apk add vim
        elif command -v pacman >/dev/null 2>&1; then
            "${elevate[@]}" pacman -S --needed --noconfirm vim
        elif command -v zypper >/dev/null 2>&1; then
            "${elevate[@]}" zypper --non-interactive install vim
        else
            die '未找到支持的包管理器；请自行安装 Vim 8/9，再运行此脚本'
        fi
        hash -r
        vim_usable || die '安装后 vim 仍不可用或功能不足，请检查 PATH 和 Vim 版本'
    fi
    missing_search=()
    command -v fd >/dev/null 2>&1 || command -v fdfind >/dev/null 2>&1 || missing_search+=(fd/fdfind)
    command -v rg >/dev/null 2>&1 || missing_search+=(ripgrep)
    command -v fzf >/dev/null 2>&1 || missing_search+=(fzf)
    if (( ${#missing_search[@]} )); then
        printf '搜索依赖缺失：%s；请手动安装，不影响配置复制。\n' "${missing_search[*]}"
        printf 'Debian/Ubuntu 示例：sudo apt install fd-find ripgrep fzf\n'
    fi
    missing_lsp=()
    command -v pyright-langserver >/dev/null 2>&1 || missing_lsp+=(pyright-langserver)
    command -v clangd >/dev/null 2>&1 || missing_lsp+=(clangd)
    if (( ${#missing_lsp[@]} )); then
        printf 'LSP 服务器缺失：%s；请手动安装或配置命令路径，不影响基础编辑和配置复制。\n' "${missing_lsp[*]}"
    fi
fi

mkdir -p -- "$install_target/.vim/colors" "$install_target/.vim/vendor"
install_target="$(cd -- "$install_target" && pwd)"
for destination in "$install_target/.vimrc" \
    "${config_files[@]/#/$install_target/.vim/}" "${color_files[@]/#/$install_target/.vim/}"; do
    [[ ! -d "$destination" ]] || die "目标文件被目录占用：$destination"
done

cleanup() {
    [[ -z "$staged" ]] || rm -rf -- "$staged"
}
trap cleanup EXIT

# Install one file or directory: skip when identical; otherwise stage, back up the old
# version, replace atomically, and roll back on failure.
install_entry() {
    local source="$1" destination="$2" backup=''
    if [[ -d "$source" ]]; then
        if [[ -d "$destination" && ! -L "$destination" ]] \
            && [[ -z "$(find "$destination" -type l -print -quit)" ]] \
            && diff -qr -- "$source" "$destination" >/dev/null 2>&1; then
            printf '已是最新：%s\n' "$destination"
            return
        fi
        staged="$(mktemp -d "${destination}.tmp.XXXXXX")"
        cp -R -- "$source/." "$staged/"
        chmod 755 "$staged"
    else
        if [[ -f "$destination" && ! -L "$destination" ]] && cmp -s -- "$source" "$destination"; then
            printf '已是最新：%s\n' "$destination"
            return
        fi
        staged="$(mktemp "${destination}.tmp.XXXXXX")"
        cp -- "$source" "$staged"
        chmod 644 "$staged"
    fi
    if [[ -e "$destination" || -L "$destination" ]]; then
        backup="${destination}.bak.$(date +%Y%m%d-%H%M%S).$$"
        mv -- "$destination" "$backup"
        printf '已备份：%s\n' "$backup"
    fi
    if ! mv -- "$staged" "$destination"; then
        [[ -z "$backup" ]] || mv -- "$backup" "$destination"
        die "无法安装：$destination"
    fi
    staged=''
    printf '已安装：%s\n' "$destination"
}

install_entry "$script_dir/vendor/vim-lsp" "$install_target/.vim/vendor/vim-lsp"
install_entry "$script_dir/.vimrc" "$install_target/.vimrc"
for name in "${config_files[@]}"; do
    install_entry "$script_dir/$name" "$install_target/.vim/$name"
done
for source in "$script_dir"/colors/*; do
    [[ -f "$source" ]] || continue
    install_entry "$source" "$install_target/.vim/colors/$(basename -- "$source")"
done
printf '\n完成。运行 vim 即可；目标目录：%s\n' "$install_target"
