#!/usr/bin/env bash
# ==============================================================================
# Package driver: Nix
# ==============================================================================

install_packages() {
    log_step "Checking dependencies via Nix"

    _nix_install_if_missing() {
        local cmd="$1"
        local pkg="$2"
        if command -v "$cmd" &>/dev/null; then
            log_ok "$cmd is already installed ($(command -v "$cmd"))"
        else
            log_info "Installing $pkg via nix-env..."
            nix-env -iA "nixpkgs.$pkg"
            if command -v "$cmd" &>/dev/null; then
                log_ok "$cmd installed successfully at $(command -v "$cmd")"
            else
                log_err "Failed to install $pkg. Check your nix channels."
                log_info "Try: nix-channel --add https://nixos.org/channels/nixpkgs-unstable nixpkgs && nix-channel --update"
                exit 1
            fi
        fi
    }

    _nix_install_if_missing "mkcert" "mkcert"

    # nss.tools provides certutil, which mkcert needs for Firefox's trust store.
    # The base nss package in nixpkgs does NOT include certutil — it's in the -tools split output.
    _nix_install_if_missing "certutil" "nss.tools"

    # Install the proxy-specific packages
    local packages
    packages=$(proxy_packages)
    for entry in $packages; do
        local cmd="${entry%%:*}"
        local pkg="${entry##*:}"
        _nix_install_if_missing "$cmd" "$pkg"
    done
}
