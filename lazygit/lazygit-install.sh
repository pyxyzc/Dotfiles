#!/usr/bin/env bash
set -euo pipefail

default_version='0.65.1'
version="${LAZYGIT_VERSION:-$default_version}"
bin_dir="${LAZYGIT_BIN_DIR:-$HOME/.local/bin}"
system_install=0
tmp_dir=''

usage() {
    cat <<'EOF'
用法：lazygit-install.sh [--version VERSION] [--bin-dir DIR] [--system]

默认：下载固定版本的 LazyGit 到 ~/.local/bin（无需 sudo），并校验 SHA-256。
  --version VERSION  覆盖默认版本（也可用 LAZYGIT_VERSION 环境变量）
  --bin-dir DIR      安装目录，默认 ~/.local/bin（也可用 LAZYGIT_BIN_DIR）
  --system           安装到 /usr/local/bin，需要 root 或 sudo
  -h, --help         显示帮助

仅支持 Linux；从 GitHub Releases 下载，架构不匹配时直接失败。
EOF
}

die() { printf '错误：%s\n' "$*" >&2; exit 1; }

while (( $# )); do
    case "$1" in
        --version)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die '--version 需要一个版本号'
            version="$2"
            shift 2
            ;;
        --bin-dir)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die '--bin-dir 需要一个目录'
            bin_dir="$2"
            shift 2
            ;;
        --system) system_install=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "未知参数：$1" ;;
    esac
done

version="${version#v}"

for tool in curl tar uname; do
    command -v "$tool" >/dev/null 2>&1 || die "缺少 $tool"
done
[[ "$(uname -s)" == 'Linux' ]] || die '仅支持 Linux'

case "$(uname -m)" in
    x86_64|amd64) arch='x86_64' ;;
    aarch64|arm64) arch='arm64' ;;
    armv7l|armv6l) arch='armv6' ;;
    i386|i686) arch='32-bit' ;;
    *) die "不支持的架构：$(uname -m)" ;;
esac

elevate=()
if (( system_install )); then
    bin_dir='/usr/local/bin'
    if (( EUID != 0 )); then
        command -v sudo >/dev/null 2>&1 || die '安装到 /usr/local/bin 需要 root 或 sudo'
        elevate=(sudo)
    fi
fi

target="$bin_dir/lazygit"
if [[ -x "$target" ]] && "$target" --version 2>/dev/null | grep -Fq "$version"; then
    printf 'LazyGit %s 已安装，跳过：%s\n' "$version" "$target"
    exit 0
fi

asset="lazygit_${version}_linux_${arch}.tar.gz"
base_url="https://github.com/jesseduffield/lazygit/releases/download/v${version}"

cleanup() {
    [[ -z "$tmp_dir" ]] || rm -rf -- "$tmp_dir"
}
trap cleanup EXIT
tmp_dir="$(mktemp -d)"

printf '下载 LazyGit %s（%s）……\n' "$version" "$arch"
curl -fL --proto '=https' --tlsv1.2 -o "$tmp_dir/$asset" "$base_url/$asset"

# Verify SHA-256; warn and continue when sha256sum or the checksum file is unavailable,
# abort on mismatch.
if command -v sha256sum >/dev/null 2>&1 \
    && curl -fsSL -o "$tmp_dir/checksums.txt" "$base_url/checksums.txt" 2>/dev/null; then
    expected="$(awk -v name="$asset" '$2 == name { print $1 }' "$tmp_dir/checksums.txt")"
    if [[ -n "$expected" ]]; then
        actual="$(sha256sum "$tmp_dir/$asset" | awk '{ print $1 }')"
        [[ "$expected" == "$actual" ]] || die "校验失败：$asset"
        printf '校验通过：%s\n' "$asset"
    else
        printf '警告：校验文件中没有 %s，跳过校验。\n' "$asset" >&2
    fi
else
    printf '警告：缺少 sha256sum 或无法获取校验文件，跳过 SHA-256 校验。\n' >&2
fi

tar xf "$tmp_dir/$asset" -C "$tmp_dir" lazygit || die '解压失败'
[[ -f "$tmp_dir/lazygit" ]] || die '压缩包中缺少 lazygit'

if [[ -e "$target" || -L "$target" ]]; then
    backup="${target}.bak.$(date +%Y%m%d-%H%M%S).$$"
    mv -- "$target" "$backup"
    printf '已备份：%s\n' "$backup"
fi

"${elevate[@]}" mkdir -p -- "$bin_dir"
"${elevate[@]}" install -m 755 "$tmp_dir/lazygit" "$target"
printf '已安装：%s\n' "$target"

case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) printf '提示：%s 不在 PATH 中，请将其加入 shell 配置。\n' "$bin_dir" ;;
esac
