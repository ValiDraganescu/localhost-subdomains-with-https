#!/usr/bin/env bash
# ==============================================================================
# Core: logging, argument parsing, constants, summary
# ==============================================================================

# Used by sourced files (certs.sh, proxy drivers)
# shellcheck disable=SC2034
CERT_DIR="$HOME/.local/dev-certs"
# shellcheck disable=SC2034
CERT_FILE="$CERT_DIR/local-dev.pem"
# shellcheck disable=SC2034
KEY_FILE="$CERT_DIR/local-dev-key.pem"
# shellcheck disable=SC2034
DOMAINS_FILE="$CERT_DIR/domains.txt"

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

# --- Parsed values (set by parse_args) ---
SUBDOMAIN=""
TARGET=""
PKG_MANAGER=""
PROXY_SERVER=""

parse_args() {
    # Defaults
    PKG_MANAGER=""
    PROXY_SERVER=""

    # Parse flags
    local positional=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pkg)
                PKG_MANAGER="$2"
                shift 2
                ;;
            --proxy)
                PROXY_SERVER="$2"
                shift 2
                ;;
            --help|-h)
                print_usage
                exit 0
                ;;
            -*)
                log_err "Unknown option: $1"
                print_usage
                exit 1
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    # Validate positional args
    if [[ ${#positional[@]} -eq 1 || ${#positional[@]} -gt 2 ]]; then
        print_usage
        exit 1
    fi

    if [[ ${#positional[@]} -eq 2 ]]; then
        SUBDOMAIN="${positional[0]}"
        TARGET="${positional[1]}"

        if [[ ! "$SUBDOMAIN" =~ ^https://[a-zA-Z0-9_-]+\.localhost$ ]]; then
            log_err "Invalid subdomain format: $SUBDOMAIN"
            log_info "Expected format: https://<name>.localhost"
            exit 1
        fi

        if [[ ! "$TARGET" =~ ^localhost:[0-9]+$ ]]; then
            log_err "Invalid target format: $TARGET"
            log_info "Expected format: localhost:<port>"
            exit 1
        fi
    fi

    # Auto-detect package manager if not specified
    if [[ -z "$PKG_MANAGER" ]]; then
        if command -v brew &>/dev/null; then
            PKG_MANAGER="brew"
        elif command -v nix-env &>/dev/null; then
            PKG_MANAGER="nix"
        else
            log_err "Neither brew nor nix found on PATH."
            log_info "Install Homebrew (https://brew.sh) or Nix (https://nixos.org/download/)"
            log_info "Or specify with --pkg brew|nix"
            exit 1
        fi
    fi

    # Auto-detect proxy if not specified
    if [[ -z "$PROXY_SERVER" ]]; then
        if [[ -f "$CERT_DIR/nginx.conf" ]]; then
            PROXY_SERVER="nginx"
        else
            PROXY_SERVER="caddy"
        fi
    fi

    # Validate choices
    if [[ "$PKG_MANAGER" != "brew" && "$PKG_MANAGER" != "nix" ]]; then
        log_err "Unknown package manager: $PKG_MANAGER (expected: brew or nix)"
        exit 1
    fi

    if [[ "$PROXY_SERVER" != "caddy" && "$PROXY_SERVER" != "nginx" ]]; then
        log_err "Unknown proxy server: $PROXY_SERVER (expected: caddy or nginx)"
        exit 1
    fi
}

print_usage() {
    echo "Usage: $0 [OPTIONS] [SUBDOMAIN_URL TARGET]"
    echo ""
    echo "Options:"
    echo "  --pkg brew|nix       Package manager (auto-detected if omitted)"
    echo "  --proxy caddy|nginx  Reverse proxy (defaults to caddy)"
    echo "  --help, -h           Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 https://backend.localhost localhost:8080"
    echo "  $0 --proxy nginx https://api.localhost localhost:9000"
    echo "  $0 --pkg brew --proxy caddy https://app.localhost localhost:3000"
    echo "  $0   # no mapping, just ensure infra + start proxy"
}

print_summary() {
    log_step "Summary"

    echo ""
    log_ok "mkcert version: $(mkcert --version 2>&1 || echo 'unknown')"
    log_ok "Package manager: $PKG_MANAGER"
    log_ok "Reverse proxy:   $PROXY_SERVER"
    log_ok "Domains file:    $DOMAINS_FILE"
    echo ""

    echo -e "${BOLD}Active mappings:${NC}"
    print_active_mappings

    echo ""
    echo -e "${BOLD}Certificate covers:${NC}"
    while IFS= read -r domain; do
        [[ -n "$domain" ]] && echo -e "  ${GREEN}$domain${NC}"
    done < "$DOMAINS_FILE"

    echo ""
    echo -e "${BOLD}Management:${NC}"
    print_management_commands
}
