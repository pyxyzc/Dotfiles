#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
install_target="${HOME}"
config_only=0

usage() {
    cat <<'EOF'
用法：tmux-install.sh [--config-only] [--target-dir DIR]
  --config-only     只复制配置，不安装软件、TPM 或修改 shell
  --target-dir DIR  目标用户目录，默认 $HOME
  -h, --help        显示帮助
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

[[ -f "$script_dir/.tmux.conf" ]] || die '缺少 .tmux.conf'
[[ ! -e "$install_target" || -d "$install_target" ]] || die "不是目录：$install_target"
mkdir -p -- "$install_target"
install_target="$(cd -- "$install_target" && pwd)"

if (( ! config_only )); then
    if command -v tmux >/dev/null 2>&1 && tmux -V >/dev/null 2>&1; then
        printf 'tmux 已安装，跳过。\n'
    else
        elevate=()
        if (( EUID != 0 )); then
            command -v sudo >/dev/null 2>&1 || die '安装 tmux 需要 root 或 sudo'
            elevate=(sudo)
        fi
        if command -v apt-get >/dev/null 2>&1; then
            "${elevate[@]}" apt-get update
            "${elevate[@]}" apt-get install -y tmux
        elif command -v dnf >/dev/null 2>&1; then
            "${elevate[@]}" dnf install -y tmux
        elif command -v pacman >/dev/null 2>&1; then
            "${elevate[@]}" pacman -S --needed --noconfirm tmux
        else
            die '请自行安装 tmux，或使用 --config-only'
        fi
        tmux -V >/dev/null 2>&1 || die '安装后 tmux 仍不可用'
    fi
    tpm="$install_target/.tmux/plugins/tpm"
    if [[ -f "$tpm/tpm" ]]; then
        printf 'TPM 已安装，跳过。\n'
    else
        [[ ! -e "$tpm" ]] || die "TPM 目录已被其他内容占用：$tpm"
        mkdir -p -- "$(dirname -- "$tpm")"
        git clone https://github.com/tmux-plugins/tpm "$tpm"
    fi
fi

destination="$install_target/.tmux.conf"
[[ ! -d "$destination" ]] || die "目标配置被目录占用：$destination"
if [[ -f "$destination" && ! -L "$destination" ]] \
    && cmp -s -- "$script_dir/.tmux.conf" "$destination"; then
    printf '已是最新：%s\n' "$destination"
else
    staged="$(mktemp "${destination}.tmp.XXXXXX")"
    trap 'rm -f -- "$staged"' EXIT
    cp -- "$script_dir/.tmux.conf" "$staged"
    chmod 644 "$staged"
    if [[ -e "$destination" || -L "$destination" ]]; then
        backup="$(mktemp "${destination}.bak.XXXXXX")"
        cp -P -- "$destination" "$backup"
    fi
    mv -T -- "$staged" "$destination"
    printf '已安装：%s\n' "$destination"
fi

if (( ! config_only )); then
    bashrc="$install_target/.bashrc"
    if [[ -f "$bashrc" ]] && grep -Eq '^[[:space:]]*(export[[:space:]]+)?LANG=' "$bashrc"; then
        printf 'LANG 已设置，保留现有值。\n'
    else
        if [[ -f "$bashrc" ]]; then
            backup="$(mktemp "${bashrc}.bak.XXXXXX")"
            cp -P -- "$bashrc" "$backup"
        fi
        printf '\n# >>> tmux-lang >>>\nexport LANG=en_US.UTF-8\n# <<< tmux-lang <<<\n' >> "$bashrc"
        printf '已在 %s 添加 LANG。\n' "$bashrc"
    fi
fi
