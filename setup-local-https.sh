#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Local HTTPS with Subdomains Setup for macOS (using Nix)
#
# Fully idempotent - safe to run multiple times. Only creates what is missing.
#
# Usage:
#   ./setup-local-https.sh https://backend.localhost localhost:8080
#   ./setup-local-https.sh https://frontend.localhost localhost:3000
#   ./setup-local-https.sh  (no args = just ensure infra is set up, start caddy)
#
# The script will:
#   1. Install mkcert and caddy via nix (if missing)
#   2. Create a local CA and trust it (if not already trusted)
#   3. Generate wildcard TLS certificates (if missing)
#   4. Add the mapping to the Caddyfile (if not already present)
#   5. Reload or start Caddy
# ==============================================================================

CERT_DIR="$HOME/.local/dev-certs"
CADDYFILE="$CERT_DIR/Caddyfile"
CERT_FILE="$CERT_DIR/localhost+1.pem"
KEY_FILE="$CERT_DIR/localhost+1-key.pem"

# --- Colors and logging ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_step()  { echo -e "\n${BLUE}${BOLD}==>${NC}${BOLD} $1${NC}"; }
log_ok()    { echo -e "  ${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
log_err()   { echo -e "  ${RED}[ERROR]${NC} $1"; }
log_info()  { echo -e "  ${BLUE}[INFO]${NC} $1"; }

# --- Parse arguments ---
SUBDOMAIN=""
TARGET=""

usage() {
    echo "Usage: $0 [SUBDOMAIN_URL TARGET]"
    echo ""
    echo "Examples:"
    echo "  $0 https://backend.localhost localhost:8080"
    echo "  $0 https://api.localhost localhost:9000"
    echo "  $0   # no mapping, just ensure infra + start caddy"
    exit 1
}

if [[ $# -eq 1 || $# -gt 2 ]]; then
    usage
fi

if [[ $# -eq 2 ]]; then
    SUBDOMAIN="$1"
    TARGET="$2"

    # Validate subdomain format
    if [[ ! "$SUBDOMAIN" =~ ^https://[a-zA-Z0-9_-]+\.localhost$ ]]; then
        log_err "Invalid subdomain format: $SUBDOMAIN"
        log_info "Expected format: https://<name>.localhost"
        exit 1
    fi

    # Validate target format
    if [[ ! "$TARGET" =~ ^localhost:[0-9]+$ ]]; then
        log_err "Invalid target format: $TARGET"
        log_info "Expected format: localhost:<port>"
        exit 1
    fi
fi

# ==============================================================================
# Step 1: Install dependencies via nix
# ==============================================================================
log_step "Checking dependencies (mkcert, caddy)"

install_if_missing() {
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

install_if_missing "mkcert" "mkcert"
install_if_missing "caddy"  "caddy"

# ==============================================================================
# Step 2: Install local CA
# ==============================================================================
log_step "Checking local Certificate Authority"

# mkcert -check is not available in all versions; check for the CA root file instead
MKCERT_ROOT="$(mkcert -CAROOT 2>/dev/null)"
if [[ -n "$MKCERT_ROOT" && -f "$MKCERT_ROOT/rootCA.pem" ]]; then
    log_ok "Local CA already exists at $MKCERT_ROOT"
else
    log_info "Installing local CA into system trust store (may prompt for sudo password)..."
    mkcert -install
    log_ok "Local CA installed and trusted"
fi

# ==============================================================================
# Step 3: Generate wildcard certificates
# ==============================================================================
log_step "Checking TLS certificates for *.localhost"

mkdir -p "$CERT_DIR"

if [[ -f "$CERT_FILE" && -f "$KEY_FILE" ]]; then
    log_ok "Certificates already exist"
    log_info "Cert: $CERT_FILE"
    log_info "Key:  $KEY_FILE"
else
    log_info "Generating certificates..."
    (cd "$CERT_DIR" && mkcert "localhost" "*.localhost")
    log_ok "Certificates generated"
    log_info "Cert: $CERT_FILE"
    log_info "Key:  $KEY_FILE"
fi

# ==============================================================================
# Step 4: Ensure Caddyfile exists with global options
# ==============================================================================
log_step "Checking Caddyfile"

if [[ ! -f "$CADDYFILE" ]]; then
    log_info "Creating new Caddyfile at $CADDYFILE"
    cat > "$CADDYFILE" <<EOF
# Local HTTPS reverse proxy configuration
# Managed by setup-local-https.sh - safe to edit manually too.

{
	auto_https disable_redirects
}
EOF
    log_ok "Caddyfile created"
else
    log_ok "Caddyfile already exists at $CADDYFILE"
fi

# ==============================================================================
# Step 5: Add mapping if provided
# ==============================================================================
CADDYFILE_CHANGED=false

if [[ -n "$SUBDOMAIN" && -n "$TARGET" ]]; then
    log_step "Ensuring mapping: $SUBDOMAIN -> $TARGET"

    # Check if this exact subdomain block already exists
    if grep -qF "$SUBDOMAIN {" "$CADDYFILE" 2>/dev/null; then
        # Subdomain exists - check if the target matches
        # Extract the current target for this subdomain
        EXISTING_TARGET=$(awk "/$SUBDOMAIN {/,/^}/" "$CADDYFILE" | grep "reverse_proxy" | awk '{print $2}' | head -1)
        if [[ "$EXISTING_TARGET" == "$TARGET" ]]; then
            log_ok "Mapping already exists: $SUBDOMAIN -> $TARGET"
        else
            log_warn "Subdomain $SUBDOMAIN exists but points to $EXISTING_TARGET (requested: $TARGET)"
            log_info "Updating target to $TARGET..."
            # Use a temp file for safe in-place editing
            TMPFILE=$(mktemp)
            awk -v domain="$SUBDOMAIN" -v new_target="$TARGET" '
                $0 ~ domain " {" { in_block=1 }
                in_block && /reverse_proxy/ { sub(/reverse_proxy .*/, "reverse_proxy " new_target) }
                /^}/ && in_block { in_block=0 }
                { print }
            ' "$CADDYFILE" > "$TMPFILE"
            mv "$TMPFILE" "$CADDYFILE"
            log_ok "Updated: $SUBDOMAIN -> $TARGET"
            CADDYFILE_CHANGED=true
        fi
    else
        log_info "Adding new mapping..."
        cat >> "$CADDYFILE" <<EOF

$SUBDOMAIN {
	tls $CERT_FILE $KEY_FILE
	reverse_proxy $TARGET
}
EOF
        log_ok "Added: $SUBDOMAIN -> $TARGET"
        CADDYFILE_CHANGED=true
    fi
else
    log_info "No mapping requested (pass SUBDOMAIN_URL TARGET to add one)"
fi

# ==============================================================================
# Step 6: Start or reload Caddy
# ==============================================================================
log_step "Managing Caddy process"

# Check if caddy is already running
if pgrep -x caddy &>/dev/null; then
    log_ok "Caddy is already running (PID: $(pgrep -x caddy | head -1))"
    if [[ "$CADDYFILE_CHANGED" == true ]]; then
        log_info "Caddyfile changed, reloading configuration..."
        caddy reload --config "$CADDYFILE" 2>/dev/null && \
            log_ok "Caddy reloaded with new configuration" || \
            { log_warn "Reload failed, trying with --force..."; caddy reload --config "$CADDYFILE" --force && log_ok "Caddy force-reloaded"; }
    else
        log_info "No config changes, skipping reload"
    fi
else
    log_info "Starting Caddy in the background..."
    log_info "Caddy needs to bind to port 443 - may prompt for sudo password"
    sudo caddy start --config "$CADDYFILE"
    if pgrep -x caddy &>/dev/null; then
        log_ok "Caddy started (PID: $(pgrep -x caddy | head -1))"
    else
        log_err "Caddy failed to start. Run manually for details:"
        log_info "  sudo caddy run --config $CADDYFILE"
        exit 1
    fi
fi

# ==============================================================================
# Summary
# ==============================================================================
log_step "Summary"

echo ""
log_ok "mkcert version: $(mkcert --version 2>&1 || echo 'unknown')"
log_ok "caddy version:  $(caddy version 2>&1 || echo 'unknown')"
log_ok "Caddyfile:      $CADDYFILE"
echo ""

# Show all active mappings from the Caddyfile
echo -e "${BOLD}Active mappings:${NC}"
while IFS= read -r line; do
    if [[ "$line" =~ ^https:// ]]; then
        domain=$(echo "$line" | sed 's/ {//')
    fi
    if [[ "$line" =~ reverse_proxy ]]; then
        target=$(echo "$line" | awk '{print $2}')
        echo -e "  ${GREEN}$domain${NC} -> $target"
    fi
done < "$CADDYFILE"

echo ""
echo -e "${BOLD}Management:${NC}"
echo "  Stop:    sudo caddy stop"
echo "  Logs:    sudo caddy run --config $CADDYFILE  (foreground)"
echo "  Reload:  caddy reload --config $CADDYFILE"
