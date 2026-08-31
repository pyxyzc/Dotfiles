#!/usr/bin/env bash

set -euo pipefail

if command -v lazygit >/dev/null 2>&1; then
    echo "lazygit is already installed: $(command -v lazygit)"
    exit 0
fi

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

LAZYGIT_VERSION=$(curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | \grep -Po '"tag_name": *"v\K[^"]*')
LAZYGIT_ARCH=$(uname -m | sed -e 's/aarch64/arm64/')
curl -fL -o "$tmp_dir/lazygit.tar.gz" "https://github.com/jesseduffield/lazygit/releases/download/v${LAZYGIT_VERSION}/lazygit_${LAZYGIT_VERSION}_Linux_${LAZYGIT_ARCH}.tar.gz"
tar xf "$tmp_dir/lazygit.tar.gz" -C "$tmp_dir" lazygit
install "$tmp_dir/lazygit" -D -t /usr/local/bin/
