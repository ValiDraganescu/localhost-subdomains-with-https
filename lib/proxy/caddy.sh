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

CADDY_PLIST_LABEL="com.local-dev.caddy"
CADDY_PLIST_PATH="/Library/LaunchDaemons/${CADDY_PLIST_LABEL}.plist"
CADDY_LOG_DIR="$CERT_DIR/caddy-logs"

_caddy_generate_plist() {
    local caddy_bin="$1"
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${CADDY_PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${caddy_bin}</string>
        <string>run</string>
        <string>--config</string>
        <string>${PROXY_CONFIG}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${CADDY_LOG_DIR}/caddy.log</string>
    <key>StandardErrorPath</key>
    <string>${CADDY_LOG_DIR}/caddy-error.log</string>
</dict>
</plist>
EOF
}

manage_proxy() {
    log_step "Managing Caddy service (launchd)"

    local caddy_bin
    caddy_bin="$(command -v caddy)"
    mkdir -p "$CADDY_LOG_DIR"

    # Generate desired plist content
    local plist_content
    plist_content="$(_caddy_generate_plist "$caddy_bin")"

    # Install or update the LaunchDaemon plist if needed
    local plist_changed=false
    if [[ ! -f "$CADDY_PLIST_PATH" ]] || ! echo "$plist_content" | diff - "$CADDY_PLIST_PATH" &>/dev/null; then
        # Unload existing service before updating plist
        if sudo launchctl list "$CADDY_PLIST_LABEL" &>/dev/null; then
            log_info "Unloading existing Caddy service..."
            sudo launchctl unload "$CADDY_PLIST_PATH" 2>/dev/null || true
        fi
        # Stop any non-launchd caddy process
        if pgrep -x caddy &>/dev/null; then
            log_info "Stopping existing Caddy process (migrating to launchd)..."
            sudo caddy stop 2>/dev/null || sudo pkill -x caddy 2>/dev/null || true
            sleep 1
        fi
        log_info "Installing LaunchDaemon plist for Caddy..."
        echo "$plist_content" | sudo tee "$CADDY_PLIST_PATH" > /dev/null
        sudo chmod 644 "$CADDY_PLIST_PATH"
        sudo chown root:wheel "$CADDY_PLIST_PATH"
        log_ok "LaunchDaemon installed at $CADDY_PLIST_PATH"
        plist_changed=true
    else
        log_ok "LaunchDaemon plist is up to date"
    fi

    # Ensure the service is loaded and running
    if ! sudo launchctl list "$CADDY_PLIST_LABEL" &>/dev/null || [[ "$plist_changed" == true ]]; then
        # Stop any rogue caddy process before launchd takes over
        if pgrep -x caddy &>/dev/null; then
            sudo caddy stop 2>/dev/null || sudo pkill -x caddy 2>/dev/null || true
            sleep 1
        fi
        log_info "Loading Caddy LaunchDaemon (starts now and on every boot)..."
        sudo launchctl load "$CADDY_PLIST_PATH"
        sleep 1
        if pgrep -x caddy &>/dev/null; then
            log_ok "Caddy started via launchd (PID: $(pgrep -x caddy | head -1))"
        else
            log_err "Caddy failed to start via launchd. Check logs:"
            log_info "  cat $CADDY_LOG_DIR/caddy-error.log"
            exit 1
        fi
    else
        log_ok "Caddy is running via launchd (PID: $(pgrep -x caddy | head -1 || echo 'unknown'))"
        if [[ "$PROXY_CONFIG_CHANGED" == true || "$CERT_NEEDS_REGEN" == true ]]; then
            log_info "Configuration or certificates changed, reloading..."
            caddy reload --config "$PROXY_CONFIG" 2>/dev/null && \
                log_ok "Caddy reloaded with new configuration" || \
                { log_warn "Reload failed, trying with --force..."; \
                  caddy reload --config "$PROXY_CONFIG" --force && log_ok "Caddy force-reloaded"; }
        else
            log_info "No changes, skipping reload"
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
    echo "  Stop:    sudo launchctl unload $CADDY_PLIST_PATH"
    echo "  Start:   sudo launchctl load $CADDY_PLIST_PATH"
    echo "  Logs:    cat $CADDY_LOG_DIR/caddy-error.log"
    echo "  Reload:  caddy reload --config $PROXY_CONFIG"
}
