#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Local HTTPS with Subdomains for macOS
#
# Fully idempotent — safe to run multiple times. Only creates what is missing.
# Auto-detects package manager (brew/nix) and defaults to Caddy.
#
# Usage:
#   ./setup-local-https.sh https://backend.localhost localhost:8080
#   ./setup-local-https.sh --proxy nginx https://api.localhost localhost:9000
#   ./setup-local-https.sh --pkg brew --proxy caddy https://app.localhost localhost:3000
#   ./setup-local-https.sh  (no args = just ensure infra is set up, start proxy)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load core (logging, arg parsing, constants)
source "$SCRIPT_DIR/lib/core.sh"

# Parse arguments (sets PKG_MANAGER, PROXY_SERVER, SUBDOMAIN, TARGET)
parse_args "$@"

# Load the proxy driver first (pkg driver needs proxy_packages function)
# shellcheck source=lib/proxy/caddy.sh
source "$SCRIPT_DIR/lib/proxy/${PROXY_SERVER}.sh"

# Load the package manager driver
# shellcheck source=lib/pkg/brew.sh
source "$SCRIPT_DIR/lib/pkg/${PKG_MANAGER}.sh"

# Load certificate management
# shellcheck source=lib/certs.sh
source "$SCRIPT_DIR/lib/certs.sh"

log_info "Using $PKG_MANAGER + $PROXY_SERVER"

# --- Run the pipeline ---
install_packages       # pkg driver:   install mkcert, nss, proxy binary
install_ca             # certs:        install CA in all trust stores
manage_certificates    # certs:        generate/regen cert with all domains
ensure_proxy_config    # proxy driver: create config file if missing
ensure_mapping         # proxy driver: add/update subdomain mapping
manage_proxy           # proxy driver: start or reload the proxy
print_summary          # core:         print status and active mappings
