#!/usr/bin/env bash
# ==============================================================================
# Package driver: Homebrew
# ==============================================================================

install_packages() {
    log_step "Checking dependencies via Homebrew"

    if ! command -v brew &>/dev/null; then
        log_err "Homebrew is not installed."
        log_info "Install it from https://brew.sh"
        exit 1
    fi
    log_ok "Homebrew is installed ($(brew --prefix))"

    _brew_install_if_missing() {
        local formula="$1"
        if brew list "$formula" &>/dev/null; then
            log_ok "$formula is already installed"
        else
            log_info "Installing $formula via brew..."
            brew install "$formula"
            log_ok "$formula installed"
        fi
    }

    _brew_install_if_missing "mkcert"

    # nss provides certutil, which mkcert needs for Firefox's trust store
    _brew_install_if_missing "nss"

    # Install the proxy-specific packages
    local packages
    packages=$(proxy_packages)
    for pkg in $packages; do
        _brew_install_if_missing "$pkg"
    done
}
