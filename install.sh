#!/usr/bin/env bash
set -euo pipefail

CURLRC="$HOME/.curlrc"
WGETRC="$HOME/.wgetrc"
CONFIGDIR="$HOME/.config"
BASHRC="$HOME/.bashrc"

# Defaults (override by running: IP=... PORT=... ./setup.sh)
IP="${IP:-127.0.0.1}"
PORT="${PORT:-7890}"
PROXY_URL="http://${IP}:${PORT}"
NO_PROXY_VAL="127.0.0.1,localhost,local,.local"

# Block markers
CURL_START="# >>> curl-config >>>"
CURL_END="# <<< curl-config <<<"
WGET_START="# >>> wget-config >>>"
WGET_END="# <<< wget-config <<<"

PROXY_START="# >>> proxy-config >>>"
PROXY_END="# <<< proxy-config <<<"
ALIAS_START="# >>> shell-aliases >>>"
ALIAS_END="# <<< shell-aliases <<<"

remove_block() {
  local file="$1" start="$2" end="$3"
  [[ -f "$file" ]] || return 0
  local tmp
  tmp="$(mktemp)"

  awk -v s="$start" -v e="$end" '
    $0==s {inside=1; next}
    $0==e {inside=0; next}
    !inside {print}
  ' "$file" > "$tmp"

  mv "$tmp" "$file"
}

append_block() {
  local file="$1" start="$2" end="$3"
  printf "\n%s\n" "$start" >> "$file"
  cat >> "$file"
  printf "%s\n" "$end" >> "$file"
}

# 1) ~/.curlrc -> managed block
touch "$CURLRC"
remove_block "$CURLRC" "$CURL_START" "$CURL_END"
append_block "$CURLRC" "$CURL_START" "$CURL_END" <<EOF
# Disable TLS certificate verification (insecure)
insecure
EOF

# 2) ~/.wgetrc -> managed block
touch "$WGETRC"
remove_block "$WGETRC" "$WGET_START" "$WGET_END"
append_block "$WGETRC" "$WGET_START" "$WGET_END" <<EOF
# Disable TLS certificate verification (insecure)
check-certificate = off
EOF

# 3) ~/.config directory
# Ensure the config directory exists
mkdir -p "$CONFIGDIR"

# 4) ~/.bashrc -> proxy config + aliases
mkdir -p "$(dirname "$BASHRC")"
touch "$BASHRC"

remove_block "$BASHRC" "$PROXY_START" "$PROXY_END"
remove_block "$BASHRC" "$ALIAS_START" "$ALIAS_END"

append_block "$BASHRC" "$PROXY_START" "$PROXY_END" <<EOF
# Proxy environment variables
export http_proxy="$PROXY_URL"
export https_proxy="$PROXY_URL"
export HTTP_PROXY="$PROXY_URL"
export HTTPS_PROXY="$PROXY_URL"
export no_proxy="$NO_PROXY_VAL"
export NO_PROXY="$NO_PROXY_VAL"
EOF

append_block "$BASHRC" "$ALIAS_START" "$ALIAS_END" <<EOF
# Convenience aliases
alias pp='export http_proxy="$PROXY_URL"; export https_proxy="$PROXY_URL"; export HTTP_PROXY="$PROXY_URL"; export HTTPS_PROXY="$PROXY_URL"; export no_proxy="$NO_PROXY_VAL"; export NO_PROXY="$NO_PROXY_VAL"; echo "proxy => $PROXY_URL (no_proxy=$NO_PROXY_VAL)"'
alias cc='clear'
alias lg='lazygit'
EOF

# 5) Configure git/npm to use proxy (best-effort)
git config --global http.proxy "$PROXY_URL" || true
git config --global https.proxy "$PROXY_URL" || true
git config --global http.sslVerify false || true
git config --global https.sslVerify false || true

npm config set proxy "$PROXY_URL" || true
npm config set https-proxy "$PROXY_URL" || true

echo "Done."
echo "Written:"
echo "  - $CURLRC"
echo "  - $WGETRC"
echo "  - $BASHRC"
echo "Run: source ~/.bashrc"
