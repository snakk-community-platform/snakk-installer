#!/bin/bash
# =============================================================================
# Snakk — One-Command Installer
# =============================================================================
# Installs prerequisites (Docker, Caddy), pulls the pre-built Docker image,
# and starts containers. After this script finishes, visit the URL it prints
# to complete setup via the browser-based wizard.
#
# Supported distros: Ubuntu, Debian, Linux Mint, Rocky Linux, AlmaLinux, RHEL, Arch Linux
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/snakk-community-platform/snakk-installer/main/docker/install.sh | sudo bash
#   — or —
#   sudo bash install.sh
#
# Update an existing installation:
#   sudo bash install.sh update
# =============================================================================
set -euo pipefail

# When piped via "curl ... | bash", stdin is the script itself.
# Open /dev/tty on fd 3 so we can read user input separately.
exec 3</dev/tty || { echo "ERROR: Cannot open /dev/tty — run this script in an interactive terminal." >&2; exit 1; }

# --- Constants ---------------------------------------------------------------
SNAKK_IMAGE="ghcr.io/snakk-community-platform/snakk"
SNAKK_VERSION="${SNAKK_VERSION:-latest}"
INSTALL_DIR="${SNAKK_INSTALL_DIR:-/opt/snakk}"
SNAKK_PORT=17000

# --- State (set during execution) -------------------------------------------
DISTRO=""        # ubuntu | debian | rocky | alma | rhel | arch
PKG_MGR=""       # apt | dnf | pacman
DOMAIN=""        # user-provided domain (empty = skip Caddy)
DB_PASSWORD=""   # generated password
GRAFANA_PASSWORD=""  # generated password for Grafana admin
ENABLE_MONITORING=false  # whether to install Prometheus + Grafana
TOTAL_RAM_MB=0   # detected total system RAM
POSTGRES_MEM_MB=0
SNAKK_MEM_MB=0

# =============================================================================
# Helpers
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }

ask_yes_no() {
    local prompt="$1" default="${2:-y}"
    local yn
    if [[ "$default" == "y" ]]; then
        read -rp "$(echo -e "${BLUE}[?]${NC} ${prompt} [Y/n]: ")" yn <&3
        yn="${yn:-y}"
    else
        read -rp "$(echo -e "${BLUE}[?]${NC} ${prompt} [y/N]: ")" yn <&3
        yn="${yn:-n}"
    fi
    [[ "${yn,,}" == "y" ]]
}

ask_input() {
    local prompt="$1"
    local result
    read -rp "$(echo -e "${BLUE}[?]${NC} ${prompt}")" result <&3
    echo "${result}"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        error "This script must be run as root (use sudo)."
        exit 1
    fi
}

# =============================================================================
# Update command — pull latest image and restart
# =============================================================================
do_update() {
    require_root

    if [[ ! -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        error "Snakk is not installed at ${INSTALL_DIR}. Run the installer first."
        exit 1
    fi

    local current_version
    current_version=$(grep "image: ${SNAKK_IMAGE}" "${INSTALL_DIR}/docker-compose.yml" | grep -oP ':\K[^ ]+$' || echo "unknown")
    info "Current image tag: ${current_version}"
    info "Pulling: ${SNAKK_IMAGE}:${SNAKK_VERSION}"

    cd "${INSTALL_DIR}"
    docker compose pull snakk
    docker compose up -d snakk

    success "Snakk updated to ${SNAKK_VERSION}!"
    info "Check logs: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs -f snakk"
    exit 0
}

# Handle "install.sh update" subcommand
if [[ "${1:-}" == "update" ]]; then
    do_update
fi

# =============================================================================
# Distro detection
# =============================================================================
detect_distro() {
    if [[ ! -f /etc/os-release ]]; then
        error "Cannot detect distro — /etc/os-release not found."
        exit 1
    fi
    # shellcheck source=/dev/null
    source /etc/os-release

    case "${ID,,}" in
        ubuntu)       DISTRO="ubuntu";    PKG_MGR="apt" ;;
        linuxmint)    DISTRO="ubuntu";    PKG_MGR="apt" ;;
        debian)       DISTRO="debian";    PKG_MGR="apt" ;;
        rocky)        DISTRO="rocky";     PKG_MGR="dnf" ;;
        almalinux)    DISTRO="alma";      PKG_MGR="dnf" ;;
        rhel|centos)  DISTRO="rhel";      PKG_MGR="dnf" ;;
        arch)         DISTRO="arch";      PKG_MGR="pacman" ;;
        *)
            error "Unsupported distro: ${ID}. Supported: Ubuntu, Debian, Linux Mint, Rocky, Alma, RHEL, Arch."
            exit 1
            ;;
    esac

    success "Detected: ${PRETTY_NAME} (package manager: ${PKG_MGR})"
}

# =============================================================================
# Prerequisite installers
# =============================================================================
check_and_install_docker() {
    if command -v docker &>/dev/null && docker compose version &>/dev/null; then
        success "Docker + Compose already installed ($(docker --version))"
        return
    fi

    if ! ask_yes_no "Docker is not installed (or missing Compose plugin). Install Docker CE?"; then
        error "Docker is required. Aborting."
        exit 1
    fi

    info "Installing Docker CE..."

    if [[ "$PKG_MGR" == "apt" ]]; then
        # Install prerequisites
        apt-get update -qq
        apt-get install -y -qq ca-certificates curl gnupg

        # Add Docker's official GPG key
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/${DISTRO}/gpg" \
            | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg

        # Add repository
        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
            https://download.docker.com/linux/${DISTRO} \
            $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
            > /etc/apt/sources.list.d/docker.list

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin

    elif [[ "$PKG_MGR" == "dnf" ]]; then
        # RHEL-family
        dnf install -y -q dnf-plugins-core
        dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        dnf install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
    elif [[ "$PKG_MGR" == "pacman" ]]; then
        pacman -S --noconfirm docker docker-compose
    fi

    systemctl enable --now docker
    success "Docker installed and started."
}

check_and_install_caddy() {
    if command -v caddy &>/dev/null; then
        success "Caddy is already installed ($(caddy version))"
        return
    fi

    if ! ask_yes_no "Caddy (reverse proxy for HTTPS) is not installed. Install it?"; then
        warn "Skipping Caddy. You can access Snakk directly on port ${SNAKK_PORT}."
        return
    fi

    info "Installing Caddy..."

    if [[ "$PKG_MGR" == "apt" ]]; then
        apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https curl
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
            | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
            > /etc/apt/sources.list.d/caddy-stable.list
        apt-get update -qq
        apt-get install -y -qq caddy
    elif [[ "$PKG_MGR" == "dnf" ]]; then
        dnf install -y -q 'dnf-command(copr)' || true
        curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/setup.rpm.sh' | bash
        dnf install -y -q caddy
    elif [[ "$PKG_MGR" == "pacman" ]]; then
        pacman -S --noconfirm caddy
    fi

    success "Caddy installed."
}

# =============================================================================
# Snakk setup
# =============================================================================
create_install_dir() {
    if [[ -f "${INSTALL_DIR}/docker-compose.yml" ]]; then
        info "Snakk already configured at ${INSTALL_DIR}."
        return
    fi

    mkdir -p "${INSTALL_DIR}"
    success "Created install directory: ${INSTALL_DIR}"
}

generate_env() {
    local env_file="${INSTALL_DIR}/.env"

    if [[ -f "${env_file}" ]]; then
        info ".env file already exists — keeping existing configuration."
        # Read existing passwords for summary
        DB_PASSWORD=$(grep -oP 'POSTGRES_PASSWORD=\K.*' "${env_file}" 2>/dev/null || echo "(existing)")
        SETUP_PASSWORD=$(grep -oP 'SETUP_PASSWORD=\K.*' "${env_file}" 2>/dev/null || echo "(existing)")
        return
    fi

    DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
    SETUP_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)

    cat > "${env_file}" <<EOF
# Generated by Snakk installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
POSTGRES_PASSWORD=${DB_PASSWORD}
SETUP_PASSWORD=${SETUP_PASSWORD}
SNAKK_PORT=${SNAKK_PORT}
EOF

    chmod 600 "${env_file}"
    success "Generated .env with random database password."
}

append_grafana_password_to_env() {
    if [[ "${ENABLE_MONITORING}" != true ]]; then return; fi

    local env_file="${INSTALL_DIR}/.env"
    if grep -q "GRAFANA_PASSWORD" "${env_file}" 2>/dev/null; then return; fi

    echo "GRAFANA_PASSWORD=${GRAFANA_PASSWORD}" >> "${env_file}"
}

detect_and_allocate_ram() {
    TOTAL_RAM_MB=$(free -m | awk '/^Mem:/ {print $2}')
    local total_gb
    total_gb=$(awk "BEGIN {printf \"%.1f\", ${TOTAL_RAM_MB}/1024}")

    info "Detected ${total_gb} GB total system RAM."

    # Reserve ~512MB for the OS, split the rest between Postgres and the app
    local available=$((TOTAL_RAM_MB - 512))

    if [[ $available -lt 1024 ]]; then
        # < 1.5 GB total — bare minimum
        POSTGRES_MEM_MB=384
        SNAKK_MEM_MB=512
    elif [[ $available -lt 2560 ]]; then
        # 1.5–3 GB total
        POSTGRES_MEM_MB=640
        SNAKK_MEM_MB=896
    elif [[ $available -lt 4096 ]]; then
        # 3–4.5 GB total
        POSTGRES_MEM_MB=1024
        SNAKK_MEM_MB=1536
    elif [[ $available -lt 8192 ]]; then
        # 4.5–8.5 GB total
        POSTGRES_MEM_MB=2048
        SNAKK_MEM_MB=3072
    else
        # 9+ GB total
        POSTGRES_MEM_MB=4096
        SNAKK_MEM_MB=4096
    fi

    local total_docker=$((POSTGRES_MEM_MB + SNAKK_MEM_MB))

    echo ""
    echo "  Recommended memory allocation:"
    echo "    Total system RAM:      ${total_gb} GB"
    echo "    OS reserve:            512 MB"
    echo "    PostgreSQL container:  ${POSTGRES_MEM_MB} MB"
    echo "    Snakk app container:   ${SNAKK_MEM_MB} MB"
    echo "    Total for Docker:      ${total_docker} MB"
    echo ""

    if ! ask_yes_no "Use this allocation?"; then
        local custom
        custom=$(ask_input "Total MB to allocate for Docker (min 512, split 40/60 between Postgres/app): ")
        if [[ "$custom" =~ ^[0-9]+$ ]] && [[ "$custom" -ge 512 ]]; then
            POSTGRES_MEM_MB=$((custom * 40 / 100))
            SNAKK_MEM_MB=$((custom * 60 / 100))
            info "Custom allocation: PostgreSQL ${POSTGRES_MEM_MB} MB, Snakk ${SNAKK_MEM_MB} MB"
        else
            warn "Invalid input — using recommended allocation."
        fi
    fi
}

generate_postgresql_conf() {
    local conf_file="${INSTALL_DIR}/postgresql.conf"
    local shared_buffers effective_cache_size maintenance_work_mem work_mem wal_buffers

    if [[ $POSTGRES_MEM_MB -lt 512 ]]; then
        shared_buffers="96MB"
        effective_cache_size="256MB"
        maintenance_work_mem="32MB"
        work_mem="2MB"
        wal_buffers="4MB"
    elif [[ $POSTGRES_MEM_MB -lt 1024 ]]; then
        shared_buffers="160MB"
        effective_cache_size="480MB"
        maintenance_work_mem="64MB"
        work_mem="4MB"
        wal_buffers="8MB"
    elif [[ $POSTGRES_MEM_MB -lt 2048 ]]; then
        shared_buffers="256MB"
        effective_cache_size="768MB"
        maintenance_work_mem="128MB"
        work_mem="4MB"
        wal_buffers="8MB"
    elif [[ $POSTGRES_MEM_MB -lt 4096 ]]; then
        shared_buffers="512MB"
        effective_cache_size="1536MB"
        maintenance_work_mem="256MB"
        work_mem="8MB"
        wal_buffers="16MB"
    else
        shared_buffers="1GB"
        effective_cache_size="3GB"
        maintenance_work_mem="512MB"
        work_mem="16MB"
        wal_buffers="16MB"
    fi

    cat > "${conf_file}" <<EOF
# Snakk PostgreSQL tuning
# Generated by install script for ${POSTGRES_MEM_MB}MB container on $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Network — required because -c config_file replaces the default config entirely
listen_addresses = '*'

# Memory
shared_buffers = ${shared_buffers}
effective_cache_size = ${effective_cache_size}
maintenance_work_mem = ${maintenance_work_mem}
work_mem = ${work_mem}
wal_buffers = ${wal_buffers}

# Planner (SSD optimizations)
random_page_cost = 1.1
effective_io_concurrency = 200

# WAL
checkpoint_completion_target = 0.9
EOF

    success "Generated postgresql.conf (shared_buffers=${shared_buffers}, effective_cache_size=${effective_cache_size})"
}

configure_monitoring() {
    echo ""
    if ! ask_yes_no "Install monitoring? (Prometheus + Grafana for metrics dashboards)" "n"; then
        ENABLE_MONITORING=false
        return
    fi

    ENABLE_MONITORING=true
    GRAFANA_PASSWORD=$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)

    # Create monitoring config directories
    local mon_dir="${INSTALL_DIR}/monitoring"
    mkdir -p "${mon_dir}/grafana/provisioning/datasources"
    mkdir -p "${mon_dir}/grafana/provisioning/dashboards"
    mkdir -p "${mon_dir}/grafana/dashboards"

    # Prometheus config
    cat > "${mon_dir}/prometheus.yml" <<'PROMEOF'
scrape_configs:
  - job_name: snakk-web
    metrics_path: /metrics
    static_configs:
      - targets: ['snakk:17000']

  - job_name: snakk-api
    metrics_path: /metrics
    static_configs:
      - targets: ['snakk:5243']
PROMEOF

    # Grafana datasource provisioning
    cat > "${mon_dir}/grafana/provisioning/datasources/prometheus.yml" <<'GRAFEOF'
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
GRAFEOF

    # Grafana dashboard provisioning
    cat > "${mon_dir}/grafana/provisioning/dashboards/default.yml" <<'DASHEOF'
apiVersion: 1
providers:
  - name: Default
    folder: ''
    type: file
    options:
      path: /var/lib/grafana/dashboards
DASHEOF

    success "Monitoring config files created."
}

generate_docker_compose() {
    local compose_file="${INSTALL_DIR}/docker-compose.yml"

    if [[ -f "${compose_file}" ]]; then
        info "docker-compose.yml already exists — keeping existing configuration."
        return
    fi

    local monitoring_services=""
    local monitoring_volumes=""

    if [[ "${ENABLE_MONITORING}" == true ]]; then
        monitoring_services=$(cat <<'MONEOF'

  prometheus:
    image: prom/prometheus:v3.4.0
    restart: unless-stopped
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=30d
    expose:
      - "9090"

  grafana:
    image: grafana/grafana:11.6.0
    restart: unless-stopped
    depends_on:
      - prometheus
    ports:
      - "3000:3000"
    volumes:
      - ./monitoring/grafana/provisioning:/etc/grafana/provisioning:ro
      - ./monitoring/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana
    environment:
      GF_SECURITY_ADMIN_USER: admin
      GF_SECURITY_ADMIN_PASSWORD: ${GRAFANA_PASSWORD}
      GF_SERVER_ROOT_URL: "%(protocol)s://%(domain)s:%(http_port)s/grafana/"
      GF_SERVER_SERVE_FROM_SUB_PATH: "true"
MONEOF
)
        monitoring_volumes=$(cat <<'VOLEOF'
  prometheus-data:
    driver: local
  grafana-data:
    driver: local
VOLEOF
)
    fi

    cat > "${compose_file}" <<EOF
# Snakk — Docker Compose (production)
# Generated by Snakk installer on $(date -u +"%Y-%m-%dT%H:%M:%SZ")
services:
  postgres:
    image: postgres:17-alpine
    restart: unless-stopped
    deploy:
      resources:
        limits:
          memory: ${POSTGRES_MEM_MB}m
        reservations:
          memory: 256m
    environment:
      POSTGRES_DB: snakk
      POSTGRES_USER: snakk
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD:?Set POSTGRES_PASSWORD in .env file}
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./postgresql.conf:/etc/postgresql/postgresql.conf:ro
    command: postgres -c config_file=/etc/postgresql/postgresql.conf
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U snakk -d snakk"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s
    # Internal only — not exposed to host
    expose:
      - "5432"

  snakk:
    image: ${SNAKK_IMAGE}:${SNAKK_VERSION}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    ports:
      - "\${SNAKK_PORT:-17000}:17000"
    volumes:
      - snakk-storage:/app/storage
    deploy:
      resources:
        limits:
          memory: ${SNAKK_MEM_MB}m
        reservations:
          memory: 512m
    environment:
      # Database host for entrypoint migration check
      DB_HOST: postgres
      DB_PORT: "5432"
      # Setup wizard password
      SETUP_PASSWORD: "\${SETUP_PASSWORD}"
      # Connection string for DbSeeder on restart (pending migrations)
      ConnectionStrings__DbConnection: "Host=postgres;Port=5432;Database=snakk;Username=snakk;Password=\${POSTGRES_PASSWORD}"
${monitoring_services}

volumes:
  pgdata:
    driver: local
  snakk-storage:
    driver: local
${monitoring_volumes}
EOF

    success "Generated docker-compose.yml (image: ${SNAKK_IMAGE}:${SNAKK_VERSION})"
}

configure_firewall() {
    if [[ "$PKG_MGR" == "apt" ]] || [[ "$PKG_MGR" == "pacman" ]]; then
        # ufw (Ubuntu/Debian/Arch)
        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            if ask_yes_no "Open ports 80 and 443 in ufw firewall?"; then
                ufw allow 80/tcp
                ufw allow 443/tcp
                success "Firewall ports 80 and 443 opened."
            fi
        else
            info "ufw not active — skipping firewall configuration."
        fi
    else
        # firewalld (Rocky/RHEL/Alma)
        if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
            if ask_yes_no "Open ports 80 and 443 in firewalld?"; then
                firewall-cmd --permanent --add-service=http
                firewall-cmd --permanent --add-service=https
                firewall-cmd --reload
                success "Firewall ports 80 and 443 opened."
            fi
        else
            info "firewalld not active — skipping firewall configuration."
        fi
    fi
}

configure_caddy() {
    if ! command -v caddy &>/dev/null; then
        info "Caddy not installed — skipping reverse proxy configuration."
        return
    fi

    echo ""
    DOMAIN=$(ask_input "Enter your domain for HTTPS (e.g. forum.example.com), or press Enter to skip: ")

    if [[ -z "${DOMAIN}" ]]; then
        info "No domain provided — skipping Caddy configuration."
        info "You can access Snakk directly at http://<server-ip>:${SNAKK_PORT}"
        return
    fi

    local caddyfile="/etc/caddy/Caddyfile"

    # Check for existing custom Caddyfile
    if [[ -f "${caddyfile}" ]]; then
        local default_content
        default_content=$(grep -c "example.com\|:80\|Welcome to Caddy\|localhost" "${caddyfile}" 2>/dev/null || echo "0")
        local line_count
        line_count=$(wc -l < "${caddyfile}")

        if [[ "${line_count}" -gt 5 ]] && [[ "${default_content}" -eq 0 ]]; then
            warn "Existing Caddyfile appears to be customized — not overwriting."
            warn "Please add a reverse_proxy block for ${DOMAIN} manually:"
            echo ""
            echo "  ${DOMAIN} {"
            echo "      reverse_proxy localhost:${SNAKK_PORT}"
            echo "  }"
            echo ""
            return
        fi
    fi

    if ask_yes_no "Write Caddyfile for ${DOMAIN} → localhost:${SNAKK_PORT}?"; then
        local grafana_block=""
        if [[ "${ENABLE_MONITORING}" == true ]]; then
            grafana_block=$(cat <<'GRAFBLOCK'

    # Grafana monitoring
    handle /grafana* {
        reverse_proxy localhost:3000
    }
GRAFBLOCK
)
        fi

        cat > "${caddyfile}" <<EOF
# Snakk — auto-generated by installer
${DOMAIN} {
    # Security headers
    header {
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
        Referrer-Policy strict-origin-when-cross-origin
        -Server
    }

    # Logging
    log {
        output file /var/log/caddy/snakk.log
        format json
    }
${grafana_block}

    # Snakk (default)
    handle {
        reverse_proxy localhost:${SNAKK_PORT}
    }
}
EOF
        success "Caddyfile written for ${DOMAIN}."

        # Create log directory
        mkdir -p /var/log/caddy
        chown caddy:caddy /var/log/caddy

        # SELinux context (Rocky/RHEL/Alma)
        if command -v semanage &>/dev/null; then
            info "Setting SELinux context on /var/log/caddy/..."
            semanage fcontext -a -t httpd_log_t "/var/log/caddy(/.*)?" 2>/dev/null || true
            restorecon -Rv /var/log/caddy
        fi

        # Enable and start Caddy
        systemctl enable caddy
        systemctl restart caddy
        success "Caddy started with HTTPS for ${DOMAIN}."
    fi
}

pull_and_start() {
    info "Pulling Snakk image (${SNAKK_IMAGE}:${SNAKK_VERSION})..."
    cd "${INSTALL_DIR}"
    docker compose pull snakk

    info "Starting containers..."
    docker compose up -d

    success "Containers started."
}

wait_for_healthy() {
    info "Waiting for services to become healthy..."
    local max_wait=120
    local elapsed=0

    while [[ $elapsed -lt $max_wait ]]; do
        # Check if the snakk container is running
        if docker compose -f "${INSTALL_DIR}/docker-compose.yml" ps --format json 2>/dev/null \
            | grep -q '"running"'; then
            success "Snakk is running!"
            return
        fi

        sleep 5
        elapsed=$((elapsed + 5))
        echo -n "."
    done

    echo ""
    warn "Timed out waiting for containers. Check with: docker compose -f ${INSTALL_DIR}/docker-compose.yml logs"
}

print_summary() {
    local url
    if [[ -n "${DOMAIN}" ]]; then
        url="https://${DOMAIN}"
    else
        # Try to get the server's public IP
        local ip
        ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "<server-ip>")
        url="http://${ip}:${SNAKK_PORT}"
    fi

    echo ""
    echo -e "${GREEN}"
    cat <<'BANNER'
 ╔══════════════════════════════════════════════════╗
 ║           Snakk Installation Complete!           ║
 ╚══════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"

    echo "  Install directory:  ${INSTALL_DIR}"
    echo "  Image:              ${SNAKK_IMAGE}:${SNAKK_VERSION}"
    echo ""
    echo "  Memory allocation:"
    echo "    PostgreSQL:  ${POSTGRES_MEM_MB} MB"
    echo "    Snakk app:   ${SNAKK_MEM_MB} MB"
    echo ""
    echo "  Setup wizard password:"
    echo "    ${SETUP_PASSWORD}"
    echo ""
    echo "  Database credentials (use these in the setup wizard):"
    echo "    Host:      postgres"
    echo "    Port:      5432"
    echo "    Database:  snakk"
    echo "    Username:  snakk"
    echo "    Password:  ${DB_PASSWORD}"
    echo ""
    if [[ "${ENABLE_MONITORING}" == true ]]; then
        echo "  Monitoring:"
        if [[ -n "${DOMAIN}" ]]; then
            echo "    Grafana:   https://${DOMAIN}/grafana/"
        else
            echo "    Grafana:   http://${ip}:3000"
        fi
        echo "    Username:  admin"
        echo "    Password:  ${GRAFANA_PASSWORD}"
        echo ""
    fi

    echo "  Next step:"
    echo "    Visit ${url}"
    echo "    Complete the setup wizard in your browser."
    echo ""
    echo "  Useful commands:"
    echo "    cd ${INSTALL_DIR}"
    echo "    docker compose logs -f snakk     # View logs"
    echo "    docker compose restart            # Restart services"
    echo "    docker compose down               # Stop everything"
    echo ""
    echo "  Update to latest version:"
    echo "    sudo bash install.sh update"
    echo "    — or —"
    echo "    cd ${INSTALL_DIR} && docker compose pull snakk && docker compose up -d snakk"
    echo ""
}

# =============================================================================
# Main
# =============================================================================
main() {
    echo ""
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  Snakk Installer${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""

    require_root
    detect_distro

    echo ""
    info "This script will install prerequisites and set up Snakk."
    info "Install directory: ${INSTALL_DIR}"
    info "Image: ${SNAKK_IMAGE}:${SNAKK_VERSION}"
    echo ""

    if ! ask_yes_no "Continue with installation?"; then
        info "Aborted."
        exit 0
    fi

    echo ""

    # 1. Prerequisites
    check_and_install_docker
    check_and_install_caddy

    echo ""

    # 2. Configure
    create_install_dir
    generate_env
    detect_and_allocate_ram
    generate_postgresql_conf
    configure_monitoring
    append_grafana_password_to_env
    generate_docker_compose
    configure_firewall
    configure_caddy

    echo ""

    # 3. Pull and start
    pull_and_start
    wait_for_healthy

    # 4. Done
    print_summary
}

main
