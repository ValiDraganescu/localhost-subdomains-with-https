#!/usr/bin/env bash
# ==============================================================================
# Proxy driver: Caddy
# ==============================================================================

PROXY_CONFIG="$CERT_DIR/Caddyfile"

# Return packages needed. Format: "cmd:nix_pkg" (nix driver splits on :, brew uses cmd name)
proxy_packages() {
    if [[ "$PKG_MANAGER" == "nix" ]]; then
        echo "caddy:caddy"
    else
        echo "caddy"
    fi
}

ensure_proxy_config() {
    log_step "Checking Caddyfile"

    if [[ ! -f "$PROXY_CONFIG" ]]; then
        log_info "Creating new Caddyfile at $PROXY_CONFIG"
        cat > "$PROXY_CONFIG" <<EOF
# Local HTTPS reverse proxy configuration
# Managed by setup-local-https — safe to edit manually too.

{
	auto_https disable_redirects
}
EOF
        log_ok "Caddyfile created"
    else
        log_ok "Caddyfile already exists at $PROXY_CONFIG"
    fi
}

PROXY_CONFIG_CHANGED=false

ensure_mapping() {
    if [[ -z "$SUBDOMAIN" || -z "$TARGET" ]]; then
        log_info "No mapping requested (pass SUBDOMAIN_URL TARGET to add one)"
        return
    fi

    log_step "Ensuring mapping: $SUBDOMAIN -> $TARGET"

    if grep -qF "$SUBDOMAIN {" "$PROXY_CONFIG" 2>/dev/null; then
        EXISTING_TARGET=$(awk -v domain="$SUBDOMAIN" \
            '$0 ~ domain " {" {found=1} found && /reverse_proxy/ {print $2; exit} /^}/ {found=0}' \
            "$PROXY_CONFIG")
        if [[ "$EXISTING_TARGET" == "$TARGET" ]]; then
            log_ok "Mapping already exists: $SUBDOMAIN -> $TARGET"
        else
            log_warn "Subdomain $SUBDOMAIN exists but points to $EXISTING_TARGET (requested: $TARGET)"
            log_info "Updating target to $TARGET..."
            TMPFILE=$(mktemp)
            awk -v domain="$SUBDOMAIN" -v new_target="$TARGET" '
                $0 ~ domain " {" { in_block=1 }
                in_block && /reverse_proxy/ { sub(/reverse_proxy .*/, "reverse_proxy " new_target) }
                /^}/ && in_block { in_block=0 }
                { print }
            ' "$PROXY_CONFIG" > "$TMPFILE"
            mv "$TMPFILE" "$PROXY_CONFIG"
            log_ok "Updated: $SUBDOMAIN -> $TARGET"
            PROXY_CONFIG_CHANGED=true
        fi
    else
        log_info "Adding new mapping..."
        cat >> "$PROXY_CONFIG" <<EOF

$SUBDOMAIN {
	tls $CERT_FILE $KEY_FILE
	reverse_proxy $TARGET
}
EOF
        log_ok "Added: $SUBDOMAIN -> $TARGET"
        PROXY_CONFIG_CHANGED=true
    fi
}

manage_proxy() {
    log_step "Managing Caddy process"

    local needs_action=false
    if [[ "$PROXY_CONFIG_CHANGED" == true || "$CERT_NEEDS_REGEN" == true ]]; then
        needs_action=true
    fi

    if pgrep -x caddy &>/dev/null; then
        log_ok "Caddy is already running (PID: $(pgrep -x caddy | head -1))"
        if [[ "$needs_action" == true ]]; then
            log_info "Configuration or certificates changed, reloading..."
            caddy reload --config "$PROXY_CONFIG" 2>/dev/null && \
                log_ok "Caddy reloaded with new configuration" || \
                { log_warn "Reload failed, trying with --force..."; \
                  caddy reload --config "$PROXY_CONFIG" --force && log_ok "Caddy force-reloaded"; }
        else
            log_info "No changes, skipping reload"
        fi
    else
        log_info "Starting Caddy in the background..."
        log_info "Caddy needs to bind to port 443 — may prompt for sudo password"
        sudo caddy start --config "$PROXY_CONFIG"
        if pgrep -x caddy &>/dev/null; then
            log_ok "Caddy started (PID: $(pgrep -x caddy | head -1))"
        else
            log_err "Caddy failed to start. Run manually for details:"
            log_info "  sudo caddy run --config $PROXY_CONFIG"
            exit 1
        fi
    fi
}

print_active_mappings() {
    local domain=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^https:// ]]; then
            domain="${line// \{/}"
        fi
        if [[ "$line" =~ reverse_proxy ]]; then
            local target
            target=$(echo "$line" | awk '{print $2}')
            echo -e "  ${GREEN}$domain${NC} -> $target"
        fi
    done < "$PROXY_CONFIG"
}

print_management_commands() {
    echo "  Stop:    sudo caddy stop"
    echo "  Logs:    sudo caddy run --config $PROXY_CONFIG  (foreground)"
    echo "  Reload:  caddy reload --config $PROXY_CONFIG"
}
