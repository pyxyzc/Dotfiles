#!/usr/bin/env bash

set -e

TPM_DIR="${HOME}/.tmux/plugins/tpm"
BASHRC="${HOME}/.bashrc"
SEPARATOR="$(printf '%*s' 66 '')"
SEPARATOR="${SEPARATOR// /-}"

print_step() {
    printf '\n%s\n%s\n%s\n' "$SEPARATOR" "$1" "$SEPARATOR"
}

print_status() {
    printf '[%s] %s\n' "$1" "$2"
}

print_step 'Step 1/3: Check and install tmux'

if command -v tmux >/dev/null 2>&1; then
    print_status 'SKIP' "tmux is already installed ($(tmux -V))."
else
    print_status 'INFO' 'Installing tmux...'
    apt update
    apt install -y tmux
    print_status ' OK ' "tmux has been installed ($(tmux -V))."
fi

print_step 'Step 2/3: Check and install TPM'

if [[ -f "${TPM_DIR}/tpm" ]]; then
    print_status 'SKIP' "TPM is already installed at ${TPM_DIR}."
else
    if [[ -e "$TPM_DIR" ]]; then
        print_status 'ERROR' "${TPM_DIR} exists but does not look like a TPM installation."
        exit 1
    fi

    print_status 'INFO' 'Installing TPM...'
    mkdir -p "$(dirname "$TPM_DIR")"
    git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
    print_status ' OK ' "TPM has been installed at ${TPM_DIR}."
fi

print_step 'Step 3/3: Configure LANG in ~/.bashrc'

if [[ -f "$BASHRC" ]] && grep -Fxq 'export LANG=en_US.UTF-8' "$BASHRC"; then
    print_status 'SKIP' 'export LANG=en_US.UTF-8 is already in ~/.bashrc.'
else
    printf '\nexport LANG=en_US.UTF-8\n' >> "$BASHRC"
    print_status 'INFO' 'Added export LANG=en_US.UTF-8 to ~/.bashrc.'
    source "$BASHRC"
    print_status ' OK ' 'Sourced ~/.bashrc.'
fi

printf '\n%s\nInstallation complete.\n%s\n' "$SEPARATOR" "$SEPARATOR"
