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

# Logging
log_min_duration_statement = 200
log_lock_waits = on
log_checkpoints = on
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

    # Prometheus config — scrapes via the gateway since internal services bind to 127.0.0.1
    cat > "${mon_dir}/prometheus.yml" <<'PROMEOF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s

rule_files:
  - /etc/prometheus/alerts.yml

scrape_configs:
  - job_name: snakk-web
    metrics_path: /internal/metrics/web
    static_configs:
      - targets: ['snakk:17000']
        labels:
          service: web

  - job_name: snakk-api
    metrics_path: /internal/metrics/api
    static_configs:
      - targets: ['snakk:17000']
        labels:
          service: api

  - job_name: postgres
    static_configs:
      - targets: ['postgres-exporter:9187']
        labels:
          service: postgres

  - job_name: valkey
    static_configs:
      - targets: ['redis-exporter:9121']
        labels:
          service: valkey

  - job_name: node
    static_configs:
      - targets: ['node-exporter:9100']
        labels:
          service: node
PROMEOF

    # Prometheus alerting rules
    cat > "${mon_dir}/alerts.yml" <<'ALERTEOF'
groups:
  - name: snakk
    rules:
      - alert: PostgresConnectionsHigh
        expr: >
          pg_stat_database_numbackends{datname="snakk"}
          / on() group_left() pg_settings_max_connections > 0.8
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "PostgreSQL connections above 80% of max"
          description: "{{ $value | humanizePercentage }} of max_connections in use."

      - alert: DiskSpaceLow
        expr: >
          (
            node_filesystem_avail_bytes{mountpoint="/host/root", fstype!~"tmpfs|overlay|squashfs"}
            / node_filesystem_size_bytes{mountpoint="/host/root", fstype!~"tmpfs|overlay|squashfs"}
          ) < 0.2
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "Root disk below 20% free"
          description: "{{ $value | humanizePercentage }} disk space remaining on root filesystem."

      - alert: GrpcErrorRateHigh
        expr: >
          (
            sum(rate(snakk_grpc_client_duration_seconds_count{status!="OK"}[5m]))
            / sum(rate(snakk_grpc_client_duration_seconds_count[5m]))
          ) > 0.01
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "gRPC client error rate above 1%"
          description: "{{ $value | humanizePercentage }} of gRPC calls are failing."

      - alert: GrpcChannelNotReady
        expr: snakk_grpc_channel_state != 2
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "gRPC channel is not in Ready state"
          description: "Channel state is {{ $value }} (2=Ready, 3=TransientFailure, 0=Idle)."

      - alert: ValkeyMemoryHigh
        expr: redis_memory_used_bytes / redis_memory_max_bytes > 0.85
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Valkey memory above 85% of maxmemory"
          description: "{{ $value | humanizePercentage }} of maxmemory in use; evictions may start."

      - alert: TokenRefreshFailures
        expr: rate(snakk_token_refresh_total{result=~"error|unauthenticated"}[5m]) > 0.1
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Token refresh failure rate elevated"
          description: "{{ $value | humanize }} refresh failures per second (result={{ $labels.result }})."

      - alert: HttpLatencyHigh
        expr: >
          histogram_quantile(0.95,
            sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service)
          ) > 2
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "HTTP P95 latency above 2s"
          description: "Service {{ $labels.service }} P95 latency is {{ $value | humanizeDuration }}."
ALERTEOF

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

    # Grafana dashboards
    cat > "${mon_dir}/grafana/dashboards/snakk-overview.json" <<'OVERVIEWEOF'
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "title": "Request Rate (req/s)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 0 },
      "targets": [
        { "expr": "sum(rate(http_request_duration_seconds_count[1m])) by (service)", "legendFormat": "{{service}}" }
      ],
      "fieldConfig": {
        "defaults": { "unit": "reqps", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 } }
      }
    },
    {
      "title": "Request Latency P95 (ms)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 0 },
      "targets": [
        { "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))", "legendFormat": "P95 {{service}}" },
        { "expr": "histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, service))", "legendFormat": "P50 {{service}}" }
      ],
      "fieldConfig": {
        "defaults": { "unit": "s", "custom": { "drawStyle": "line", "fillOpacity": 5, "lineWidth": 2 } }
      }
    },
    {
      "title": "HTTP Status Codes",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "targets": [
        { "expr": "sum(rate(http_request_duration_seconds_count[1m])) by (code)", "legendFormat": "{{code}}" }
      ],
      "fieldConfig": {
        "defaults": { "unit": "reqps", "custom": { "drawStyle": "bars", "fillOpacity": 50, "lineWidth": 0, "stacking": { "mode": "normal" } } },
        "overrides": [
          { "matcher": { "id": "byRegexp", "options": "^2" }, "properties": [{ "id": "color", "value": { "fixedColor": "green", "mode": "fixed" } }] },
          { "matcher": { "id": "byRegexp", "options": "^4" }, "properties": [{ "id": "color", "value": { "fixedColor": "yellow", "mode": "fixed" } }] },
          { "matcher": { "id": "byRegexp", "options": "^5" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }
        ]
      }
    },
    {
      "title": "Slowest Endpoints (P95)",
      "type": "table",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "targets": [
        { "expr": "topk(10, histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le, controller, action)))", "format": "table", "instant": true }
      ],
      "transformations": [
        { "id": "organize", "options": { "excludeByName": { "Time": true } } }
      ]
    },
    {
      "title": "Process Memory (MB)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 8, "x": 0, "y": 16 },
      "targets": [
        { "expr": "process_working_set_bytes{job=~\"snakk-.*\"} / 1024 / 1024", "legendFormat": "{{service}}" }
      ],
      "fieldConfig": {
        "defaults": { "unit": "decmbytes", "custom": { "drawStyle": "line", "fillOpacity": 20, "lineWidth": 2 } }
      }
    },
    {
      "title": "GC Memory (MB)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 8, "x": 8, "y": 16 },
      "targets": [
        { "expr": "dotnet_total_memory_bytes{job=~\"snakk-.*\"} / 1024 / 1024", "legendFormat": "{{service}}" }
      ],
      "fieldConfig": {
        "defaults": { "unit": "decmbytes", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 1 } }
      }
    },
    {
      "title": "CPU Usage",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 8, "x": 16, "y": 16 },
      "targets": [
        { "expr": "rate(process_cpu_seconds_total{job=~\"snakk-.*\"}[1m])", "legendFormat": "{{service}}" }
      ],
      "fieldConfig": {
        "defaults": { "unit": "percentunit", "max": 1, "custom": { "drawStyle": "line", "fillOpacity": 20, "lineWidth": 2 } }
      }
    },
    {
      "title": "In-Progress HTTP Requests",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 24 },
      "targets": [
        { "expr": "http_requests_in_progress{job=~\"snakk-.*\"}", "legendFormat": "{{service}}" }
      ],
      "fieldConfig": {
        "defaults": { "unit": "short", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 } }
      }
    },
    {
      "title": "GC Collections Rate",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 24 },
      "targets": [
        { "expr": "rate(dotnet_collection_count_total{job=~\"snakk-.*\"}[1m])", "legendFormat": "{{service}} gen{{generation}}" }
      ],
      "fieldConfig": {
        "defaults": { "unit": "ops", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 1 } }
      }
    }
  ],
  "refresh": "10s",
  "schemaVersion": 39,
  "tags": ["snakk"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timepicker": {},
  "timezone": "",
  "title": "Snakk Overview",
  "uid": "snakk-overview",
  "version": 1
}
OVERVIEWEOF

    cat > "${mon_dir}/grafana/dashboards/snakk-grpc.json" <<'GRPCEOF'
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "title": "Channel State",
      "type": "stat",
      "gridPos": { "h": 8, "w": 4, "x": 0, "y": 0 },
      "targets": [
        { "expr": "snakk_grpc_channel_state", "legendFormat": "" }
      ],
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "colorMode": "background",
        "graphMode": "none",
        "orientation": "auto",
        "textMode": "value_and_name"
      },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "thresholds" },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "yellow", "value": null },
              { "color": "green", "value": 2 },
              { "color": "red", "value": 3 }
            ]
          },
          "mappings": [
            {
              "type": "value",
              "options": {
                "0": { "text": "Idle",             "color": "yellow",   "index": 0 },
                "1": { "text": "Connecting",        "color": "blue",     "index": 1 },
                "2": { "text": "Ready",             "color": "green",    "index": 2 },
                "3": { "text": "Transient Failure", "color": "red",      "index": 3 },
                "4": { "text": "Shutdown",          "color": "dark-red", "index": 4 }
              }
            }
          ]
        }
      }
    },
    {
      "title": "Call Rate by Method (calls/s)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 20, "x": 4, "y": 0 },
      "targets": [
        { "expr": "sum(rate(snakk_grpc_client_duration_seconds_count[1m])) by (method)", "legendFormat": "{{method}}" }
      ],
      "fieldConfig": {
        "defaults": { "unit": "reqps", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 } }
      }
    },
    {
      "title": "Call Latency by Method",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 8 },
      "targets": [
        { "expr": "histogram_quantile(0.95, sum(rate(snakk_grpc_client_duration_seconds_bucket[5m])) by (le, method))", "legendFormat": "P95 {{method}}" },
        { "expr": "histogram_quantile(0.50, sum(rate(snakk_grpc_client_duration_seconds_bucket[5m])) by (le, method))", "legendFormat": "P50 {{method}}" }
      ],
      "fieldConfig": {
        "defaults": { "unit": "s", "custom": { "drawStyle": "line", "fillOpacity": 5, "lineWidth": 2 } }
      }
    },
    {
      "title": "Errors by Method & Status (calls/s)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 8 },
      "targets": [
        { "expr": "sum(rate(snakk_grpc_client_duration_seconds_count{status!=\"OK\"}[1m])) by (method, status)", "legendFormat": "{{method}} / {{status}}" }
      ],
      "fieldConfig": {
        "defaults": { "unit": "reqps", "custom": { "drawStyle": "bars", "fillOpacity": 50, "lineWidth": 0, "stacking": { "mode": "normal" } } },
        "overrides": [
          { "matcher": { "id": "byRegexp", "options": "DeadlineExceeded" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] },
          { "matcher": { "id": "byRegexp", "options": "Unauthenticated" }, "properties": [{ "id": "color", "value": { "fixedColor": "yellow", "mode": "fixed" } }] }
        ]
      }
    }
  ],
  "refresh": "10s",
  "schemaVersion": 39,
  "tags": ["snakk", "grpc"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timepicker": {},
  "timezone": "",
  "title": "Snakk gRPC",
  "uid": "snakk-grpc",
  "version": 1
}
GRPCEOF

    cat > "${mon_dir}/grafana/dashboards/snakk-postgres.json" <<'POSTGRESEOF'
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "title": "Active Connections",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
      "targets": [
        { "expr": "pg_stat_database_numbackends{datname=\"snakk\"}", "legendFormat": "" }
      ],
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "colorMode": "background",
        "graphMode": "area",
        "orientation": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "color": { "mode": "thresholds" },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 20 },
              { "color": "red", "value": 50 }
            ]
          }
        }
      }
    },
    {
      "title": "Cache Hit Ratio",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
      "targets": [
        {
          "expr": "100 * rate(pg_stat_database_blks_hit_total{datname=\"snakk\"}[5m]) / clamp_min(rate(pg_stat_database_blks_hit_total{datname=\"snakk\"}[5m]) + rate(pg_stat_database_blks_read_total{datname=\"snakk\"}[5m]), 1)",
          "legendFormat": ""
        }
      ],
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "colorMode": "background",
        "graphMode": "area",
        "orientation": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "color": { "mode": "thresholds" },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "yellow", "value": 95 },
              { "color": "green", "value": 99 }
            ]
          }
        }
      }
    },
    {
      "title": "Database Size",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 },
      "targets": [
        { "expr": "pg_database_size_bytes{datname=\"snakk\"}", "legendFormat": "" }
      ],
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "colorMode": "value",
        "graphMode": "area",
        "orientation": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "bytes",
          "color": { "mode": "fixed", "fixedColor": "blue" }
        }
      }
    },
    {
      "title": "Deadlocks / min",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 },
      "targets": [
        { "expr": "rate(pg_stat_database_deadlocks_total{datname=\"snakk\"}[5m]) * 60", "legendFormat": "" }
      ],
      "options": {
        "reduceOptions": { "calcs": ["lastNotNull"] },
        "colorMode": "background",
        "graphMode": "area",
        "orientation": "auto"
      },
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "decimals": 2,
          "color": { "mode": "thresholds" },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "green", "value": null },
              { "color": "yellow", "value": 0.01 },
              { "color": "red", "value": 1 }
            ]
          }
        }
      }
    },
    {
      "title": "Transactions / sec",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
      "targets": [
        {
          "expr": "rate(pg_stat_database_xact_commit_total{datname=\"snakk\"}[1m])",
          "legendFormat": "Commits"
        },
        {
          "expr": "rate(pg_stat_database_xact_rollback_total{datname=\"snakk\"}[1m])",
          "legendFormat": "Rollbacks"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "reqps",
          "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "Rollbacks" },
            "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }]
          }
        ]
      }
    },
    {
      "title": "Connections",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 },
      "targets": [
        {
          "expr": "pg_stat_database_numbackends{datname=\"snakk\"}",
          "legendFormat": "Active"
        },
        {
          "expr": "pg_settings_max_connections",
          "legendFormat": "Max"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "Max" },
            "properties": [
              { "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } },
              { "id": "custom.lineStyle", "value": { "dash": [8, 4], "fill": "dash" } },
              { "id": "custom.fillOpacity", "value": 0 }
            ]
          }
        ]
      }
    },
    {
      "title": "Cache Hit Ratio",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 12 },
      "targets": [
        {
          "expr": "100 * rate(pg_stat_database_blks_hit_total{datname=\"snakk\"}[5m]) / clamp_min(rate(pg_stat_database_blks_hit_total{datname=\"snakk\"}[5m]) + rate(pg_stat_database_blks_read_total{datname=\"snakk\"}[5m]), 1)",
          "legendFormat": "Hit %"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "percent",
          "min": 0,
          "max": 100,
          "custom": { "drawStyle": "line", "fillOpacity": 20, "lineWidth": 2 },
          "thresholds": {
            "mode": "absolute",
            "steps": [
              { "color": "red", "value": null },
              { "color": "yellow", "value": 95 },
              { "color": "green", "value": 99 }
            ]
          },
          "color": { "mode": "thresholds" }
        }
      }
    },
    {
      "title": "Locks by Mode",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 12 },
      "targets": [
        {
          "expr": "pg_locks_count{datname=\"snakk\"}",
          "legendFormat": "{{mode}}"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 1, "stacking": { "mode": "normal" } }
        }
      }
    },
    {
      "title": "Temp Files",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 20 },
      "targets": [
        {
          "expr": "rate(pg_stat_database_temp_files_total{datname=\"snakk\"}[5m])",
          "legendFormat": "Files / sec"
        },
        {
          "expr": "rate(pg_stat_database_temp_bytes_total{datname=\"snakk\"}[5m])",
          "legendFormat": "Bytes / sec"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "custom": { "drawStyle": "bars", "fillOpacity": 60, "lineWidth": 0 }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "Bytes / sec" },
            "properties": [{ "id": "unit", "value": "Bps" }]
          }
        ]
      }
    },
    {
      "title": "Checkpoints",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 20 },
      "targets": [
        {
          "expr": "rate(pg_stat_bgwriter_checkpoints_timed_total[5m])",
          "legendFormat": "Timed"
        },
        {
          "expr": "rate(pg_stat_bgwriter_checkpoints_req_total[5m])",
          "legendFormat": "Requested"
        },
        {
          "expr": "rate(pg_stat_bgwriter_buffers_checkpoint_total[5m])",
          "legendFormat": "Buffers written"
        }
      ],
      "fieldConfig": {
        "defaults": {
          "unit": "short",
          "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 }
        },
        "overrides": [
          {
            "matcher": { "id": "byName", "options": "Requested" },
            "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }]
          }
        ]
      }
    }
  ],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": ["snakk", "postgres"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timepicker": {},
  "timezone": "",
  "title": "Snakk PostgreSQL",
  "uid": "snakk-postgres",
  "version": 1
}
POSTGRESEOF

    cat > "${mon_dir}/grafana/dashboards/snakk-valkey.json" <<'VALKEYEOF'
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "title": "Hit Rate",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
      "targets": [
        {
          "expr": "100 * rate(redis_keyspace_hits_total[5m]) / clamp_min(rate(redis_keyspace_hits_total[5m]) + rate(redis_keyspace_misses_total[5m]), 1)",
          "legendFormat": ""
        }
      ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "area", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "color": { "mode": "thresholds" }, "thresholds": { "mode": "absolute", "steps": [ { "color": "red", "value": null }, { "color": "yellow", "value": 80 }, { "color": "green", "value": 95 } ] } } }
    },
    {
      "title": "Memory Used",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
      "targets": [ { "expr": "redis_memory_used_bytes", "legendFormat": "" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "area", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "bytes", "color": { "mode": "fixed", "fixedColor": "blue" } } }
    },
    {
      "title": "Connected Clients",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 },
      "targets": [ { "expr": "redis_connected_clients", "legendFormat": "" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "area", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "short", "color": { "mode": "thresholds" }, "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "yellow", "value": 50 }, { "color": "red", "value": 200 } ] } } }
    },
    {
      "title": "Evictions / sec",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 },
      "targets": [ { "expr": "rate(redis_evicted_keys_total[5m])", "legendFormat": "" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "area", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "short", "decimals": 2, "color": { "mode": "thresholds" }, "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "yellow", "value": 1 }, { "color": "red", "value": 10 } ] } } }
    },
    {
      "title": "Commands / sec",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
      "targets": [ { "expr": "rate(redis_commands_processed_total[1m])", "legendFormat": "Commands/s" } ],
      "fieldConfig": { "defaults": { "unit": "ops", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 } } }
    },
    {
      "title": "Hit vs Miss Rate",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 },
      "targets": [
        { "expr": "rate(redis_keyspace_hits_total[1m])", "legendFormat": "Hits/s" },
        { "expr": "rate(redis_keyspace_misses_total[1m])", "legendFormat": "Misses/s" }
      ],
      "fieldConfig": { "defaults": { "unit": "ops", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 } }, "overrides": [ { "matcher": { "id": "byName", "options": "Misses/s" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] } ] }
    },
    {
      "title": "Memory Used Over Time",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 12 },
      "targets": [
        { "expr": "redis_memory_used_bytes", "legendFormat": "Used" },
        { "expr": "redis_memory_max_bytes > 0", "legendFormat": "Max" }
      ],
      "fieldConfig": { "defaults": { "unit": "bytes", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 } }, "overrides": [ { "matcher": { "id": "byName", "options": "Max" }, "properties": [ { "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }, { "id": "custom.lineStyle", "value": { "dash": [8, 4], "fill": "dash" } }, { "id": "custom.fillOpacity", "value": 0 } ] } ] }
    },
    {
      "title": "Evictions & Expired Keys",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 12 },
      "targets": [
        { "expr": "rate(redis_evicted_keys_total[5m])", "legendFormat": "Evictions/s" },
        { "expr": "rate(redis_expired_keys_total[5m])", "legendFormat": "Expired/s" }
      ],
      "fieldConfig": { "defaults": { "unit": "ops", "custom": { "drawStyle": "bars", "fillOpacity": 50, "lineWidth": 0 } }, "overrides": [ { "matcher": { "id": "byName", "options": "Evictions/s" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] } ] }
    },
    {
      "title": "Network I/O",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 20 },
      "targets": [
        { "expr": "rate(redis_net_input_bytes_total[1m])", "legendFormat": "In" },
        { "expr": "rate(redis_net_output_bytes_total[1m])", "legendFormat": "Out" }
      ],
      "fieldConfig": { "defaults": { "unit": "Bps", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 } } }
    }
  ],
  "refresh": "10s",
  "schemaVersion": 39,
  "tags": ["snakk", "valkey"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timepicker": {},
  "timezone": "",
  "title": "Snakk Valkey",
  "uid": "snakk-valkey",
  "version": 1
}
VALKEYEOF

    cat > "${mon_dir}/grafana/dashboards/snakk-system.json" <<'SYSTEMEOF'
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "title": "Disk Free (root)",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
      "targets": [ { "expr": "100 * node_filesystem_avail_bytes{mountpoint=\"/host/root\",fstype!~\"tmpfs|overlay|squashfs\"} / node_filesystem_size_bytes{mountpoint=\"/host/root\",fstype!~\"tmpfs|overlay|squashfs\"}", "legendFormat": "" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "area", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "color": { "mode": "thresholds" }, "thresholds": { "mode": "absolute", "steps": [ { "color": "red", "value": null }, { "color": "yellow", "value": 20 }, { "color": "green", "value": 40 } ] } } }
    },
    {
      "title": "CPU Usage",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
      "targets": [ { "expr": "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[5m])) * 100)", "legendFormat": "" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "area", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "color": { "mode": "thresholds" }, "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "yellow", "value": 70 }, { "color": "red", "value": 90 } ] } } }
    },
    {
      "title": "Memory Available",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 },
      "targets": [ { "expr": "node_memory_MemAvailable_bytes", "legendFormat": "" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "area", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "bytes", "color": { "mode": "fixed", "fixedColor": "blue" } } }
    },
    {
      "title": "Load Average (1m)",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 },
      "targets": [ { "expr": "node_load1", "legendFormat": "" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "area", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "short", "decimals": 2, "color": { "mode": "thresholds" }, "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "yellow", "value": 2 }, { "color": "red", "value": 4 } ] } } }
    },
    {
      "title": "CPU Usage",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
      "targets": [
        { "expr": "100 - (avg by(instance) (rate(node_cpu_seconds_total{mode=\"idle\"}[1m])) * 100)", "legendFormat": "CPU %" },
        { "expr": "avg by(instance) (rate(node_cpu_seconds_total{mode=\"iowait\"}[1m])) * 100", "legendFormat": "IO Wait %" }
      ],
      "fieldConfig": { "defaults": { "unit": "percent", "min": 0, "max": 100, "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 } }, "overrides": [ { "matcher": { "id": "byName", "options": "IO Wait %" }, "properties": [{ "id": "color", "value": { "fixedColor": "orange", "mode": "fixed" } }] } ] }
    },
    {
      "title": "Memory",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 },
      "targets": [
        { "expr": "node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes", "legendFormat": "Used" },
        { "expr": "node_memory_MemTotal_bytes", "legendFormat": "Total" }
      ],
      "fieldConfig": { "defaults": { "unit": "bytes", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 } }, "overrides": [ { "matcher": { "id": "byName", "options": "Total" }, "properties": [ { "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }, { "id": "custom.lineStyle", "value": { "dash": [8, 4], "fill": "dash" } }, { "id": "custom.fillOpacity", "value": 0 } ] } ] }
    },
    {
      "title": "Disk Space (root)",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 12 },
      "targets": [
        { "expr": "node_filesystem_size_bytes{mountpoint=\"/host/root\",fstype!~\"tmpfs|overlay|squashfs\"} - node_filesystem_avail_bytes{mountpoint=\"/host/root\",fstype!~\"tmpfs|overlay|squashfs\"}", "legendFormat": "Used" },
        { "expr": "node_filesystem_size_bytes{mountpoint=\"/host/root\",fstype!~\"tmpfs|overlay|squashfs\"}", "legendFormat": "Total" }
      ],
      "fieldConfig": { "defaults": { "unit": "bytes", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 } }, "overrides": [ { "matcher": { "id": "byName", "options": "Total" }, "properties": [ { "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }, { "id": "custom.lineStyle", "value": { "dash": [8, 4], "fill": "dash" } }, { "id": "custom.fillOpacity", "value": 0 } ] } ] }
    },
    {
      "title": "Disk I/O",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 12 },
      "targets": [
        { "expr": "rate(node_disk_read_bytes_total[1m])", "legendFormat": "Read" },
        { "expr": "rate(node_disk_written_bytes_total[1m])", "legendFormat": "Write" }
      ],
      "fieldConfig": { "defaults": { "unit": "Bps", "custom": { "drawStyle": "line", "fillOpacity": 10, "lineWidth": 2 } }, "overrides": [ { "matcher": { "id": "byName", "options": "Write" }, "properties": [{ "id": "color", "value": { "fixedColor": "orange", "mode": "fixed" } }] } ] }
    },
    {
      "title": "Network I/O",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 24, "x": 0, "y": 20 },
      "targets": [
        { "expr": "rate(node_network_receive_bytes_total{device!~\"lo|veth.*|docker.*\"}[1m])", "legendFormat": "In ({{device}})" },
        { "expr": "rate(node_network_transmit_bytes_total{device!~\"lo|veth.*|docker.*\"}[1m])", "legendFormat": "Out ({{device}})" }
      ],
      "fieldConfig": { "defaults": { "unit": "Bps", "custom": { "drawStyle": "line", "fillOpacity": 5, "lineWidth": 2 } } }
    }
  ],
  "refresh": "30s",
  "schemaVersion": 39,
  "tags": ["snakk", "system"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timepicker": {},
  "timezone": "",
  "title": "Snakk System",
  "uid": "snakk-system",
  "version": 1
}
SYSTEMEOF

    cat > "${mon_dir}/grafana/dashboards/snakk-application.json" <<'APPEOF'
{
  "annotations": { "list": [] },
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "title": "In-Progress HTTP Requests",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 0, "y": 0 },
      "targets": [ { "expr": "sum(http_requests_in_progress{job=~\"snakk-.*\"})", "legendFormat": "" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "none", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "short", "color": { "mode": "thresholds" }, "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "yellow", "value": 50 }, { "color": "red", "value": 200 } ] } } }
    },
    {
      "title": "Token Refreshes / min",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 6, "y": 0 },
      "targets": [ { "expr": "sum(rate(snakk_token_refresh_total[5m])) * 60", "legendFormat": "" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "value", "graphMode": "area", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "short", "decimals": 1, "color": { "mode": "fixed", "fixedColor": "blue" } } }
    },
    {
      "title": "Token Refresh Failures / min",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 12, "y": 0 },
      "targets": [ { "expr": "sum(rate(snakk_token_refresh_total{result=~\"error|unauthenticated\"}[5m])) * 60", "legendFormat": "" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "area", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "short", "decimals": 2, "color": { "mode": "thresholds" }, "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "yellow", "value": 1 }, { "color": "red", "value": 10 } ] } } }
    },
    {
      "title": "Pending Token Refreshes / min",
      "type": "stat",
      "gridPos": { "h": 4, "w": 6, "x": 18, "y": 0 },
      "targets": [ { "expr": "rate(snakk_token_refresh_total{result=\"pending\"}[5m]) * 60", "legendFormat": "" } ],
      "options": { "reduceOptions": { "calcs": ["lastNotNull"] }, "colorMode": "background", "graphMode": "area", "orientation": "auto" },
      "fieldConfig": { "defaults": { "unit": "short", "decimals": 2, "color": { "mode": "thresholds" }, "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null }, { "color": "yellow", "value": 5 }, { "color": "red", "value": 20 } ] } } }
    },
    {
      "title": "In-Progress HTTP Requests Over Time",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 4 },
      "targets": [ { "expr": "http_requests_in_progress{job=~\"snakk-.*\"}", "legendFormat": "{{service}}" } ],
      "fieldConfig": { "defaults": { "unit": "short", "custom": { "drawStyle": "line", "fillOpacity": 20, "lineWidth": 2 } } }
    },
    {
      "title": "Token Refresh Outcomes",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 4 },
      "targets": [ { "expr": "rate(snakk_token_refresh_total[1m]) * 60", "legendFormat": "{{result}}" } ],
      "fieldConfig": { "defaults": { "unit": "short", "custom": { "drawStyle": "bars", "fillOpacity": 60, "lineWidth": 0, "stacking": { "mode": "normal" } } }, "overrides": [ { "matcher": { "id": "byName", "options": "success" }, "properties": [{ "id": "color", "value": { "fixedColor": "green", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "unauthenticated" }, "properties": [{ "id": "color", "value": { "fixedColor": "yellow", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "error" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }, { "matcher": { "id": "byName", "options": "pending" }, "properties": [{ "id": "color", "value": { "fixedColor": "blue", "mode": "fixed" } }] } ] }
    },
    {
      "title": "P50 / P95 / P99 Request Latency",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 0, "y": 12 },
      "targets": [
        { "expr": "histogram_quantile(0.99, sum(rate(http_request_duration_seconds_bucket{job=~\"snakk-.*\"}[5m])) by (le, service))", "legendFormat": "P99 {{service}}" },
        { "expr": "histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket{job=~\"snakk-.*\"}[5m])) by (le, service))", "legendFormat": "P95 {{service}}" },
        { "expr": "histogram_quantile(0.50, sum(rate(http_request_duration_seconds_bucket{job=~\"snakk-.*\"}[5m])) by (le, service))", "legendFormat": "P50 {{service}}" }
      ],
      "fieldConfig": { "defaults": { "unit": "s", "custom": { "drawStyle": "line", "fillOpacity": 5, "lineWidth": 2 } } }
    },
    {
      "title": "Error Rate by Service",
      "type": "timeseries",
      "gridPos": { "h": 8, "w": 12, "x": 12, "y": 12 },
      "targets": [
        { "expr": "sum(rate(http_request_duration_seconds_count{job=~\"snakk-.*\",code=~\"5..\"}[1m])) by (service)", "legendFormat": "5xx {{service}}" },
        { "expr": "sum(rate(http_request_duration_seconds_count{job=~\"snakk-.*\",code=~\"4..\"}[1m])) by (service)", "legendFormat": "4xx {{service}}" }
      ],
      "fieldConfig": { "defaults": { "unit": "reqps", "custom": { "drawStyle": "bars", "fillOpacity": 50, "lineWidth": 0, "stacking": { "mode": "normal" } } }, "overrides": [ { "matcher": { "id": "byRegexp", "options": "5xx" }, "properties": [{ "id": "color", "value": { "fixedColor": "red", "mode": "fixed" } }] }, { "matcher": { "id": "byRegexp", "options": "4xx" }, "properties": [{ "id": "color", "value": { "fixedColor": "yellow", "mode": "fixed" } }] } ] }
    }
  ],
  "refresh": "10s",
  "schemaVersion": 39,
  "tags": ["snakk", "application"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timepicker": {},
  "timezone": "",
  "title": "Snakk Application",
  "uid": "snakk-application",
  "version": 1
}
APPEOF

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

  redis-exporter:
    image: oliver006/redis_exporter:v1.67.0
    restart: unless-stopped
    depends_on:
      - valkey
    environment:
      REDIS_ADDR: "redis://valkey:6379"
    expose:
      - "9121"

  node-exporter:
    image: prom/node-exporter:v1.9.1
    restart: unless-stopped
    pid: host
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/host/root:ro,rslave
    command:
      - --path.procfs=/host/proc
      - --path.sysfs=/host/sys
      - --path.rootfs=/host/root
      - --collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)
    expose:
      - "9100"

  postgres-exporter:
    image: quay.io/prometheuscommunity/postgres_exporter:v0.16.0
    restart: unless-stopped
    depends_on:
      - postgres
    environment:
      DATA_SOURCE_NAME: "postgresql://snakk:${POSTGRES_PASSWORD}@postgres:5432/snakk?sslmode=disable"
    expose:
      - "9187"

  prometheus:
    image: prom/prometheus:v3.4.0
    restart: unless-stopped
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./monitoring/alerts.yml:/etc/prometheus/alerts.yml:ro
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
      # Valkey cache (L2 backing store for HybridCache + shared JWT revocation)
      Valkey__ConnectionString: valkey:6379
${monitoring_services}

  valkey:
    image: valkey/valkey:8-alpine
    restart: unless-stopped
    command: valkey-server --save 60 1 --loglevel warning
    volumes:
      - valkey-data:/data
    # Internal only — not exposed to host
    expose:
      - "6379"

volumes:
  pgdata:
    driver: local
  snakk-storage:
    driver: local
  valkey-data:
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

    # Persist domain to .env so it's available for future re-runs and tooling
    local env_file="${INSTALL_DIR}/.env"
    if ! grep -q "SNAKK_DOMAIN" "${env_file}" 2>/dev/null; then
        echo "SNAKK_DOMAIN=${DOMAIN}" >> "${env_file}"
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
# Snakk - auto-generated by installer
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
        reverse_proxy localhost:${SNAKK_PORT} {
            header_up X-Forwarded-Host {host}
        }
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
