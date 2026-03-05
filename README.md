# localhost-subdomains

A single, idempotent Bash script that gives you **HTTPS subdomains on localhost** for macOS development. Run it as many times as you want — it only creates what's missing.

```
https://backend.localhost  ->  localhost:8080
https://frontend.localhost ->  localhost:3000
https://api.localhost      ->  localhost:9000
```

No more `http://localhost:8080`. Your local environment matches production URLs.

## Prerequisites

- **macOS**
- **[Homebrew](https://brew.sh)** or **[Nix](https://nixos.org/download/)** package manager

The script auto-detects which package manager you have and installs everything else (`mkcert`, `nss`, `caddy`/`nginx`) automatically.

## Browser support

Tested and working with:

- **Google Chrome** 134+
- **Firefox Developer Edition** 136+
- **Safari** 18+ (uses macOS Keychain, works out of the box)

Any Chromium-based browser (Brave, Edge, Arc, etc.) should work since they share Chrome's certificate handling via the macOS Keychain. Firefox uses its own certificate store — the script handles this automatically by installing `nss` (provides `certutil`) so that `mkcert` can inject the CA into Firefox's trust store.

## Quick start

```bash
git clone <this-repo>
cd localhost-subdomains
chmod +x setup-local-https.sh

# Add your first mapping
./setup-local-https.sh https://backend.localhost localhost:8080

# Add another
./setup-local-https.sh https://frontend.localhost localhost:3000

# Run with no args to just ensure everything is up
./setup-local-https.sh
```

On the first run it will prompt for your sudo password (the proxy needs port 443, mkcert needs to install the local CA).

## What it does

Each run goes through these steps, skipping anything already done:

| Step | Action                                          | Skipped if                                    |
|------|-------------------------------------------------|-----------------------------------------------|
| 1    | Install `mkcert`, `nss`, proxy via brew/nix     | Already installed                             |
| 2    | Install local CA into all trust stores          | Already trusted (still runs, is idempotent)   |
| 3    | Generate TLS cert covering all configured subdomains | Cert exists and no new domains added     |
| 4    | Create/update the proxy config                  | File exists / mapping already present         |
| 5    | Start or reload the proxy                       | Already running with no config/cert changes   |

Certificates and proxy configs are stored in `~/.local/dev-certs/`.

### Why not a wildcard certificate?

Browsers treat `localhost` as a TLD and **do not honor `*.localhost` wildcard certificates**. Each subdomain (e.g. `backend.localhost`, `api.localhost`) must be listed explicitly as a Subject Alternative Name (SAN) in the certificate. The script manages this automatically — when you add a new subdomain, it regenerates the certificate to include it.

## Usage

```
./setup-local-https.sh [OPTIONS] [SUBDOMAIN_URL TARGET]
```

### Options

| Flag | Values | Default |
|------|--------|---------|
| `--pkg` | `brew`, `nix` | Auto-detected |
| `--proxy` | `caddy`, `nginx` | `caddy` |
| `--help` | | Show help |

### Examples

```bash
# Auto-detect everything (uses brew or nix, defaults to caddy)
./setup-local-https.sh https://backend.localhost localhost:8080

# Use nginx instead of caddy
./setup-local-https.sh --proxy nginx https://backend.localhost localhost:8080

# Force brew + nginx
./setup-local-https.sh --pkg brew --proxy nginx https://api.localhost localhost:9000

# Just ensure infra is up, no new mapping
./setup-local-https.sh
```

### Adding mappings

```bash
./setup-local-https.sh https://backend.localhost localhost:8080
./setup-local-https.sh https://api.localhost localhost:9000
./setup-local-https.sh https://admin.localhost localhost:4000
```

Each call adds the subdomain to the certificate (regenerating it if needed) and appends the reverse proxy rule to the config.

### Updating a mapping

Run the same subdomain with a different port — the script detects the change and updates it:

```bash
# backend was on 8080, move it to 8081
./setup-local-https.sh https://backend.localhost localhost:8081
```

### Managing the proxy

#### Caddy

```bash
sudo caddy stop
sudo caddy start --config ~/.local/dev-certs/Caddyfile
sudo caddy run --config ~/.local/dev-certs/Caddyfile    # foreground
caddy reload --config ~/.local/dev-certs/Caddyfile
```

#### nginx

```bash
sudo nginx -s stop -c ~/.local/dev-certs/nginx.conf
sudo nginx -c ~/.local/dev-certs/nginx.conf
sudo nginx -s reload -c ~/.local/dev-certs/nginx.conf
tail -f ~/.local/dev-certs/nginx-logs/error.log          # logs
```

## Architecture

```
setup-local-https.sh          # Single entry point
lib/
  core.sh                     # Logging, arg parsing, constants, summary
  certs.sh                    # CA install, domain tracking, cert generation
  pkg/
    brew.sh                   # Install packages via Homebrew
    nix.sh                    # Install packages via Nix
  proxy/
    caddy.sh                  # Caddyfile management, caddy start/reload
    nginx.sh                  # nginx.conf management, nginx start/reload
```

The entry point auto-detects your package manager, loads the appropriate **pkg driver** and **proxy driver**, then runs a shared pipeline:

```
install_packages  →  install_ca  →  manage_certificates  →  ensure_proxy_config  →  ensure_mapping  →  manage_proxy
```

Adding a new proxy (e.g. traefik) or package manager means adding one file under `lib/proxy/` or `lib/pkg/` implementing the required functions.

### Proxy driver interface

Each proxy driver (`lib/proxy/*.sh`) implements:

| Function | Responsibility |
|---|---|
| `proxy_packages` | Return packages to install |
| `ensure_proxy_config` | Create config file if missing |
| `ensure_mapping` | Add/update a subdomain mapping |
| `manage_proxy` | Start, reload, or skip |
| `print_active_mappings` | Print current mappings from config |
| `print_management_commands` | Print stop/reload/logs commands |

### Package driver interface

Each package driver (`lib/pkg/*.sh`) implements:

| Function | Responsibility |
|---|---|
| `install_packages` | Install mkcert, nss, and proxy packages |

## How it works

- **[mkcert](https://github.com/FiloSottile/mkcert)** creates a local Certificate Authority and generates TLS certificates trusted by your browsers.
- **[nss](https://firefox-source-docs.mozilla.org/security/nss/)** provides `certutil`, required so mkcert can install the CA into Firefox's certificate store (Firefox uses its own trust store, not the macOS Keychain).
- **[Caddy](https://caddyserver.com/)** or **[nginx](https://nginx.org/)** acts as a reverse proxy, terminating TLS and forwarding requests to your local services.
- `.localhost` subdomains resolve to `127.0.0.1` automatically ([RFC 6761](https://www.rfc-editor.org/rfc/rfc6761)) — no `/etc/hosts` editing needed.

## File locations

| File | Path |
|------|------|
| TLS certificate | `~/.local/dev-certs/local-dev.pem` |
| TLS private key | `~/.local/dev-certs/local-dev-key.pem` |
| Domains list | `~/.local/dev-certs/domains.txt` |
| Caddyfile | `~/.local/dev-certs/Caddyfile` |
| nginx config | `~/.local/dev-certs/nginx.conf` |
| nginx logs | `~/.local/dev-certs/nginx-logs/` |
| CA root cert | `$(mkcert -CAROOT)/rootCA.pem` |

## Uninstall

```bash
# Stop the proxy
sudo caddy stop           # if using caddy
sudo nginx -s stop        # if using nginx

# Remove certificates and config
rm -rf ~/.local/dev-certs

# Remove the local CA from system trust store
mkcert -uninstall

# Optionally remove the tools (Homebrew)
brew uninstall mkcert caddy nss nginx

# Optionally remove the tools (Nix)
nix-env -e mkcert caddy nss nginx
```

## License

[MIT](LICENSE)
