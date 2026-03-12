#!/usr/bin/env bash
# ==============================================================================
# Proxy driver: nginx
# ==============================================================================

PROXY_CONFIG="$CERT_DIR/nginx.conf"
NGINX_PID_FILE="$CERT_DIR/nginx.pid"
NGINX_LOG_DIR="$CERT_DIR/nginx-logs"
NGINX_TEMP_DIR="$CERT_DIR/nginx-tmp"

# Return packages needed. Format: "cmd:nix_pkg" (nix driver splits on :, brew uses cmd name)
proxy_packages() {
    if [[ "$PKG_MANAGER" == "nix" ]]; then
        echo "nginx:nginx"
    else
        echo "nginx"
    fi
}

ensure_proxy_config() {
    log_step "Checking nginx config"

    mkdir -p "$NGINX_LOG_DIR" "$NGINX_TEMP_DIR"

    if [[ ! -f "$PROXY_CONFIG" ]]; then
        log_info "Creating new nginx.conf at $PROXY_CONFIG"
        cat > "$PROXY_CONFIG" <<EOF
# Local HTTPS reverse proxy configuration
# Managed by setup-local-https — safe to edit manually too.

worker_processes 1;
pid $NGINX_PID_FILE;

events {
    worker_connections 128;
}

http {
    error_log  $NGINX_LOG_DIR/error.log;
    access_log $NGINX_LOG_DIR/access.log;

    client_body_temp_path $NGINX_TEMP_DIR/client_body;
    proxy_temp_path       $NGINX_TEMP_DIR/proxy;
    fastcgi_temp_path     $NGINX_TEMP_DIR/fastcgi;
    uwsgi_temp_path       $NGINX_TEMP_DIR/uwsgi;
    scgi_temp_path        $NGINX_TEMP_DIR/scgi;

    # --- server blocks are appended below by setup-local-https ---
}
EOF
        log_ok "nginx.conf created"
    else
        log_ok "nginx.conf already exists at $PROXY_CONFIG"
    fi
}

PROXY_CONFIG_CHANGED=false

ensure_mapping() {
    if [[ -z "$SUBDOMAIN" || -z "$TARGET" ]]; then
        log_info "No mapping requested (pass SUBDOMAIN_URL TARGET to add one)"
        return
    fi

    log_step "Ensuring mapping: $SUBDOMAIN -> $TARGET"

    local bare_domain="${SUBDOMAIN#https://}"
    local target_port="${TARGET#localhost:}"

    if grep -qF "server_name $bare_domain;" "$PROXY_CONFIG" 2>/dev/null; then
        # Extract the existing proxy_pass port
        local existing_port
        existing_port=$(awk -v domain="$bare_domain" \
            '$0 ~ "server_name " domain ";" {found=1} found && /proxy_pass/ {match($0, /localhost:([0-9]+)/, m); print m[1]; exit} /^    }/ && found {found=0}' \
            "$PROXY_CONFIG")
        if [[ "$existing_port" == "$target_port" ]]; then
            log_ok "Mapping already exists: $SUBDOMAIN -> $TARGET"
        else
            log_warn "Subdomain $SUBDOMAIN exists but points to localhost:$existing_port (requested: $TARGET)"
            log_info "Updating target to $TARGET..."
            TMPFILE=$(mktemp)
            awk -v domain="$bare_domain" -v new_port="$target_port" '
                $0 ~ "server_name " domain ";" { in_block=1 }
                in_block && /proxy_pass/ { sub(/localhost:[0-9]+/, "localhost:" new_port) }
                /^    }/ && in_block { in_block=0 }
                { print }
            ' "$PROXY_CONFIG" > "$TMPFILE"
            mv "$TMPFILE" "$PROXY_CONFIG"
            log_ok "Updated: $SUBDOMAIN -> $TARGET"
            PROXY_CONFIG_CHANGED=true
        fi
    else
        log_info "Adding new server block..."
        # Insert the server block before the closing } of the http block
        TMPFILE=$(mktemp)
        # Remove the last line (closing brace of http block), append server, re-add brace
        sed '$ d' "$PROXY_CONFIG" > "$TMPFILE"
        cat >> "$TMPFILE" <<EOF

    server {
        listen 443 ssl;
        server_name $bare_domain;

        ssl_certificate     $CERT_FILE;
        ssl_certificate_key $KEY_FILE;

        location / {
            proxy_pass http://$TARGET;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
        }
    }
}
EOF
        mv "$TMPFILE" "$PROXY_CONFIG"
        log_ok "Added: $SUBDOMAIN -> $TARGET"
        PROXY_CONFIG_CHANGED=true
    fi
}

NGINX_PLIST_LABEL="com.local-dev.nginx"
NGINX_PLIST_PATH="/Library/LaunchDaemons/${NGINX_PLIST_LABEL}.plist"

_nginx_generate_plist() {
    local nginx_bin="$1"
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${NGINX_PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${nginx_bin}</string>
        <string>-c</string>
        <string>${PROXY_CONFIG}</string>
        <string>-g</string>
        <string>daemon off;</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${NGINX_LOG_DIR}/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${NGINX_LOG_DIR}/launchd-stderr.log</string>
</dict>
</plist>
EOF
}

manage_proxy() {
    log_step "Managing nginx service (launchd)"

    local nginx_bin
    nginx_bin="$(command -v nginx)"
    mkdir -p "$NGINX_LOG_DIR" "$NGINX_TEMP_DIR"

    # Validate config before any action
    if ! nginx -t -c "$PROXY_CONFIG" 2>/dev/null; then
        log_err "nginx config validation failed:"
        nginx -t -c "$PROXY_CONFIG" 2>&1 | while IFS= read -r line; do log_info "$line"; done
        exit 1
    fi
    log_ok "nginx config is valid"

    # Generate desired plist content
    local plist_content
    plist_content="$(_nginx_generate_plist "$nginx_bin")"

    # Install or update the LaunchDaemon plist if needed
    local plist_changed=false
    if [[ ! -f "$NGINX_PLIST_PATH" ]] || ! echo "$plist_content" | diff - "$NGINX_PLIST_PATH" &>/dev/null; then
        # Unload existing service before updating plist
        if sudo launchctl list "$NGINX_PLIST_LABEL" &>/dev/null; then
            log_info "Unloading existing nginx service..."
            sudo launchctl unload "$NGINX_PLIST_PATH" 2>/dev/null || true
        fi
        # Stop any non-launchd nginx process
        if [[ -f "$NGINX_PID_FILE" ]] && kill -0 "$(cat "$NGINX_PID_FILE")" 2>/dev/null; then
            log_info "Stopping existing nginx process (migrating to launchd)..."
            sudo nginx -s stop -c "$PROXY_CONFIG" 2>/dev/null || sudo pkill -x nginx 2>/dev/null || true
            sleep 1
        fi
        log_info "Installing LaunchDaemon plist for nginx..."
        echo "$plist_content" | sudo tee "$NGINX_PLIST_PATH" > /dev/null
        sudo chmod 644 "$NGINX_PLIST_PATH"
        sudo chown root:wheel "$NGINX_PLIST_PATH"
        log_ok "LaunchDaemon installed at $NGINX_PLIST_PATH"
        plist_changed=true
    else
        log_ok "LaunchDaemon plist is up to date"
    fi

    # Ensure the service is loaded and running
    if ! sudo launchctl list "$NGINX_PLIST_LABEL" &>/dev/null || [[ "$plist_changed" == true ]]; then
        # Stop any rogue nginx process before launchd takes over
        if pgrep -x nginx &>/dev/null; then
            sudo nginx -s stop -c "$PROXY_CONFIG" 2>/dev/null || sudo pkill -x nginx 2>/dev/null || true
            sleep 1
        fi
        log_info "Loading nginx LaunchDaemon (starts now and on every boot)..."
        sudo launchctl load "$NGINX_PLIST_PATH"
        sleep 2
        if pgrep -x nginx &>/dev/null; then
            log_ok "nginx started via launchd (PID: $(pgrep -x nginx | head -1))"
        else
            log_err "nginx failed to start via launchd. Check logs:"
            log_info "  cat $NGINX_LOG_DIR/launchd-stderr.log"
            log_info "  cat $NGINX_LOG_DIR/error.log"
            exit 1
        fi
    else
        if pgrep -x nginx &>/dev/null; then
            log_ok "nginx is running via launchd (PID: $(pgrep -x nginx | head -1))"
            if [[ "$PROXY_CONFIG_CHANGED" == true || "$CERT_NEEDS_REGEN" == true ]]; then
                log_info "Configuration or certificates changed, reloading..."
                sudo nginx -s reload -c "$PROXY_CONFIG" 2>/dev/null && \
                    log_ok "nginx reloaded with new configuration" || \
                    { log_err "nginx reload failed"; exit 1; }
            else
                log_info "No changes, skipping reload"
            fi
        else
            log_warn "LaunchDaemon is loaded but nginx is not running — restarting..."
            sudo launchctl unload "$NGINX_PLIST_PATH" 2>/dev/null || true
            sleep 1
            sudo launchctl load "$NGINX_PLIST_PATH"
            sleep 2
            if pgrep -x nginx &>/dev/null; then
                log_ok "nginx restarted via launchd (PID: $(pgrep -x nginx | head -1))"
            else
                log_err "nginx failed to restart. Check logs:"
                log_info "  cat $NGINX_LOG_DIR/launchd-stderr.log"
                log_info "  cat $NGINX_LOG_DIR/error.log"
                exit 1
            fi
        fi
    fi
}

print_active_mappings() {
    local domain=""
    while IFS= read -r line; do
        if [[ "$line" =~ server_name[[:space:]]+([a-zA-Z0-9._-]+)\; ]]; then
            domain="${BASH_REMATCH[1]}"
        fi
        if [[ "$line" =~ proxy_pass[[:space:]]+http://(.+)\; ]]; then
            local target="${BASH_REMATCH[1]}"
            echo -e "  ${GREEN}https://$domain${NC} -> $target"
        fi
    done < "$PROXY_CONFIG"
}

print_management_commands() {
    echo "  Stop:    sudo launchctl unload $NGINX_PLIST_PATH"
    echo "  Start:   sudo launchctl load $NGINX_PLIST_PATH"
    echo "  Logs:    tail -f $NGINX_LOG_DIR/error.log"
    echo "  Reload:  sudo nginx -s reload -c $PROXY_CONFIG"
}
