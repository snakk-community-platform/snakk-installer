# Snakk Installer

One-command installer for [Snakk](https://github.com/snakk-community-platform/snakk) — a self-hosted community platform.

Clones the repo, installs prerequisites (Git, Docker, Caddy), tunes PostgreSQL for your server's RAM, and starts everything in Docker. After installation, complete setup via the browser-based wizard.

## Quick Start

```bash
curl -fsSL https://get.snakk.community/install-docker.sh | sudo bash
```

Or download and run manually:

```bash
wget https://raw.githubusercontent.com/snakk-community-platform/snakk-installer/main/docker/install.sh
sudo bash install.sh
```

## Supported Distros

- Ubuntu (20.04+)
- Debian (11+)
- Linux Mint (21+)
- Rocky Linux (8+)
- AlmaLinux (8+)
- RHEL / CentOS (8+)

## What It Does

1. **Detects your distro** and package manager
2. **Installs prerequisites** — Git, Docker CE + Compose plugin, Caddy (optional)
3. **Clones Snakk** to `/opt/snakk` (configurable)
4. **Generates credentials** — random PostgreSQL password in `docker/.env`
5. **Tunes PostgreSQL** — generates `postgresql.conf` based on available RAM
6. **Sets container memory limits** — via `docker-compose.override.yml`
7. **Configures firewall** — opens ports 80/443 (ufw or firewalld)
8. **Sets up Caddy** — reverse proxy with automatic HTTPS (optional)
9. **Builds and starts** Docker containers

## After Installation

Visit the URL shown at the end of the install to complete setup in your browser.

### Useful Commands

```bash
cd /opt/snakk/docker
docker compose logs -f snakk      # View logs
docker compose restart             # Restart services
docker compose down                # Stop everything
docker compose up -d --build       # Rebuild after updates
```

## Configuration

| Variable | Default | Description |
|---|---|---|
| `SNAKK_INSTALL_DIR` | `/opt/snakk` | Installation directory |

Example:

```bash
curl -fsSL https://...install.sh | SNAKK_INSTALL_DIR=/srv/snakk sudo -E bash
```

## License

[MIT](LICENSE)
