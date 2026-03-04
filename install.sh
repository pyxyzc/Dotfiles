#!/usr/bin/env bash
set -euo pipefail

CURLRC="$HOME/.curlrc"
WGETRC="$HOME/.wgetrc"
CONFIGDIR="$HOME/.config"

# 1) ~/.curlrc -> insecure
if [[ -f "$CURLRC" ]]; then
  if ! grep -qx 'insecure' "$CURLRC"; then
    echo 'insecure' >> "$CURLRC"
  fi
else
  printf '%s\n' 'insecure' > "$CURLRC"
fi

# 2) ~/.wgetrc -> check-certificate = off
if [[ -f "$WGETRC" ]]; then
  if ! grep -qx 'check-certificate = off' "$WGETRC"; then
    echo 'check-certificate = off' >> "$WGETRC"
  fi
else
  printf '%s\n' 'check-certificate = off' > "$WGETRC"
fi

# 3) ~/.config directory
mkdir -p "$CONFIGDIR"

echo "Done."
