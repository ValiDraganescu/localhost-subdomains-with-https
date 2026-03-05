# localhost-subdomains-with-https

A single, idempotent Bash script that gives you **HTTPS subdomains on localhost** for macOS development. Run it as many times as you want — it only creates what's missing.

```
https://backend.localhost  ->  localhost:8080
https://frontend.localhost ->  localhost:3000
https://api.localhost      ->  localhost:9000
```

No more `http://localhost:8080`. Your local environment matches production URLs.

## Prerequisites

- **macOS**
- **[Nix](https://nixos.org/download/)** package manager installed

The script installs everything else (`mkcert`, `caddy`) via Nix automatically.

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

On the first run it will prompt for your sudo password (Caddy needs port 443, mkcert needs to install the local CA).

## What it does

Each run goes through these steps, skipping anything already done:

| Step | Action                                        | Skipped if                             |
|------|-----------------------------------------------|----------------------------------------|
| 1    | Install `mkcert` and `caddy` via `nix-env`    | Already on `$PATH`                     |
| 2    | Create a local Certificate Authority          | `rootCA.pem` already exists            |
| 3    | Generate wildcard TLS certs for `*.localhost` | Cert files already exist               |
| 4    | Create/update the Caddyfile                   | File exists / mapping already present  |
| 5    | Start or reload Caddy                         | Already running with no config changes |

Certificates and the Caddyfile are stored in `~/.local/dev-certs/`.

## Usage

```
./setup-local-https.sh [SUBDOMAIN_URL TARGET]
```

| Arguments                                  | Effect                                             |
|--------------------------------------------|----------------------------------------------------|
| `https://backend.localhost localhost:8080` | Add mapping and start/reload Caddy                 |
| *(none)*                                   | Ensure infra is set up, start Caddy if not running |

### Adding mappings

```bash
./setup-local-https.sh https://backend.localhost localhost:8080
./setup-local-https.sh https://api.localhost localhost:9000
./setup-local-https.sh https://admin.localhost localhost:4000
```

### Updating a mapping

Run the same subdomain with a different port — the script detects the change and updates it:

```bash
# backend was on 8080, move it to 8081
./setup-local-https.sh https://backend.localhost localhost:8081
```

### Managing Caddy

```bash
# Stop
sudo caddy stop

# Start (background)
sudo caddy start --config ~/.local/dev-certs/Caddyfile

# Start (foreground, see logs)
sudo caddy run --config ~/.local/dev-certs/Caddyfile

# Reload after manual Caddyfile edits
caddy reload --config ~/.local/dev-certs/Caddyfile
```

## How it works

- **[mkcert](https://github.com/FiloSottile/mkcert)** creates a local Certificate Authority and generates TLS certificates that your browser trusts without warnings.
- **[Caddy](https://caddyserver.com/)** acts as a reverse proxy, terminating TLS and forwarding requests to your local services.
- `.localhost` subdomains resolve to `127.0.0.1` automatically ([RFC 6761](https://www.rfc-editor.org/rfc/rfc6761)) — no `/etc/hosts` editing needed.

## File locations

| File | Path |
|------|------|
| TLS certificate | `~/.local/dev-certs/localhost+1.pem` |
| TLS private key | `~/.local/dev-certs/localhost+1-key.pem` |
| Caddyfile | `~/.local/dev-certs/Caddyfile` |
| CA root cert | `$(mkcert -CAROOT)/rootCA.pem` |

## Uninstall

```bash
# Stop Caddy
sudo caddy stop

# Remove certificates and config
rm -rf ~/.local/dev-certs

# Remove the local CA from system trust store
mkcert -uninstall

# Optionally remove the tools
nix-env -e mkcert caddy
```

## License

[MIT](LICENSE)
