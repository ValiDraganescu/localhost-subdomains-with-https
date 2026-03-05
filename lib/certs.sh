#!/usr/bin/env bash
# ==============================================================================
# Certificate management: CA installation, domain tracking, cert generation
# ==============================================================================

CERT_NEEDS_REGEN=false

install_ca() {
    log_step "Ensuring local Certificate Authority is installed in all trust stores"
    log_info "Running mkcert -install (idempotent — skips stores that already have the CA)..."
    mkcert -install
    log_ok "Local CA is installed and trusted"
}

manage_certificates() {
    log_step "Managing TLS certificates"

    mkdir -p "$CERT_DIR"

    # The domains file tracks all domains the certificate covers.
    # Browsers don't honor *.localhost wildcards (localhost is a TLD),
    # so each subdomain must be listed explicitly as a SAN.
    if [[ ! -f "$DOMAINS_FILE" ]]; then
        echo "localhost" > "$DOMAINS_FILE"
        log_info "Created domains file: $DOMAINS_FILE"
    fi

    # Extract the bare hostname from the subdomain URL
    if [[ -n "$SUBDOMAIN" ]]; then
        BARE_DOMAIN="${SUBDOMAIN#https://}"
        if grep -qxF "$BARE_DOMAIN" "$DOMAINS_FILE" 2>/dev/null; then
            log_ok "$BARE_DOMAIN is already in the certificate"
        else
            echo "$BARE_DOMAIN" >> "$DOMAINS_FILE"
            log_info "Added $BARE_DOMAIN to domains list"
            CERT_NEEDS_REGEN=true
        fi
    fi

    # Generate or regenerate the certificate
    if [[ "$CERT_NEEDS_REGEN" == true ]] || [[ ! -f "$CERT_FILE" ]] || [[ ! -f "$KEY_FILE" ]]; then
        if [[ "$CERT_NEEDS_REGEN" == true ]]; then
            log_info "New domain added — regenerating certificate..."
        else
            log_info "Generating certificate..."
        fi

        MKCERT_ARGS=()
        while IFS= read -r domain; do
            [[ -n "$domain" ]] && MKCERT_ARGS+=("$domain")
        done < "$DOMAINS_FILE"

        log_info "Certificate will cover: ${MKCERT_ARGS[*]}"
        mkcert -cert-file "$CERT_FILE" -key-file "$KEY_FILE" "${MKCERT_ARGS[@]}"

        log_ok "Certificate generated"
        log_info "Cert: $CERT_FILE"
        log_info "Key:  $KEY_FILE"
    else
        log_ok "Certificate already exists and covers all configured domains"
        log_info "Domains: $(tr '\n' ' ' < "$DOMAINS_FILE")"
    fi
}
