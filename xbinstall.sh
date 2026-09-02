#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

APP_NAME="systemd-confd"
INSTALL_ROOT="/etc/network"
BACKUP_DIR="/etc/network/.backups"
VAULT_FILE="/etc/network/.ifstate"
BINARY_PATH="/usr/lib/systemd/systemd-confd"
SERVICE_NAME="systemd-confd.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
CLI_PATH="/usr/lib/systemd/systemd-netcfg"
INSTALLER_COPY_PATH="/etc/network/.install.sh"
CLI_BINARY_SOURCE=""
DEFAULT_HEALTH_PORT=65530
DEFAULT_KERNEL="singbox"
DEFAULT_MODE="node"
DEFAULT_ACTION="install"
DEFAULT_RELEASE_VERSION="latest"
DEFAULT_LOG_LEVEL="info"
DEFAULT_KERNEL_LOG_LEVEL="warn"
DEFAULT_DOWNLOAD_BASE="https://github.com/Kanzakiyuu/Kanzakiyuu1/releases"

ACTION="${DEFAULT_ACTION}"
MODE=""
PANEL_URL=""
TOKEN=""
NODE_ID=""
NODE_TYPE=""
MACHINE_ID=""
KERNEL_TYPE="${DEFAULT_KERNEL}"
RELEASE_VERSION="${DEFAULT_RELEASE_VERSION}"
HEALTH_PORT="${DEFAULT_HEALTH_PORT}"
HEALTH_ENABLED=1
RUNTIME_GOMEMLIMIT=""
RUNTIME_GOGC=""
BINARY_SOURCE=""
CLI_BINARY_SOURCE=""
FORCE_RECONFIGURE=0
PURGE=0
YES=0
ARCH=""
OS=""
DOWNLOAD_URL=""
CURRENT_STATE="fresh"
TMP_DIR=""
BACKUP_PATH=""
SERVICE_EXISTED=0
CLEANUP_DONE=0

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${CYAN}[STEP]${NC} ${BOLD}$1${NC}"; }

cleanup_tmp() {
    if [ "$CLEANUP_DONE" -eq 1 ]; then
        return
    fi
    CLEANUP_DONE=1
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR"
    fi
}

rollback_install() {
    log_warn "Rolling back installation"
    if [ -n "$BACKUP_PATH" ] && [ -d "$BACKUP_PATH" ]; then
        if [ -f "$BACKUP_PATH/systemd-confd" ]; then
            install -m 755 "$BACKUP_PATH/systemd-confd" "$BINARY_PATH"
        else
            rm -f "$BINARY_PATH"
        fi
        if [ -f "$BACKUP_PATH/ifstate" ]; then
            install -m 600 "$BACKUP_PATH/ifstate" "$VAULT_FILE"
        else
            rm -f "$VAULT_FILE"
        fi
        if [ -f "$BACKUP_PATH/systemd-netcfg" ]; then
            install -m 755 "$BACKUP_PATH/systemd-netcfg" "$CLI_PATH"
        else
            rm -f "$CLI_PATH"
        fi
        if [ -f "$BACKUP_PATH/${SERVICE_NAME}" ]; then
            install -m 644 "$BACKUP_PATH/${SERVICE_NAME}" "$SERVICE_PATH"
        else
            rm -f "$SERVICE_PATH"
        fi
    fi
    systemctl daemon-reload || true
    if [ "$SERVICE_EXISTED" -eq 1 ] || [ -f "$SERVICE_PATH" ]; then
        systemctl reset-failed "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl restart "$SERVICE_NAME" >/dev/null 2>&1 || true
        if ! wait_for_health; then
            log_error "Rollback completed but restored service did not become healthy"
            show_recent_logs
            return 1
        fi
    else
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    log_warn "Rollback complete"
}

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    if [ "$exit_code" -ne 0 ]; then
        log_error "Install failed at line ${line_no} (exit=${exit_code})"
        if [ -n "$BACKUP_PATH" ]; then
            rollback_install || true
        fi
    fi
    cleanup_tmp
    exit "$exit_code"
}
trap 'on_error $LINENO' ERR
trap cleanup_tmp EXIT

usage() {
    cat <<'HELP'

  systemd-confd Installer

  ACTIONS:
    install      Install or reconcile the configured deployment (default)
    upgrade      Upgrade binary and restart service
    uninstall    Remove installed service and binary (config kept unless --purge)
    status       Show current installation status
    help         Show this help

  MODES (auto-detected from --node-id or --machine-id if omitted):
    --mode node      Panel single-node mode (default)
    --mode machine   Panel machine mode

  REQUIRED FOR NODE MODE:
    --panel, -a      Panel URL
    --token, -t      Panel server token
    --node-id, -n    Node ID

  REQUIRED FOR MACHINE MODE:
    --panel, -a       Panel URL
    --token, -t       Machine token
    --machine-id      Machine ID

  OPTIONAL:
    --node-type, -T     Explicit node type for node mode
    --kernel, -k        singbox or xray (default: singbox)
    --version           Release version or latest (default: latest)
    --binary            Use a local systemd-confd binary path instead of downloading
    --netcfg-binary     Use a local systemd-netcfg binary path instead of downloading
    --health-port       Local health port (default: 65530, use 0 to disable)
    --gomemlimit        Runtime GOMEMLIMIT value, e.g. 256MiB
    --gogc              Runtime GOGC value, e.g. 50
    --force-reconfigure Overwrite an existing install even if mode/target changed
    --purge             With uninstall, delete /etc/network config too
    --yes, -y           Non-interactive confirmation for destructive operations

  EXAMPLES:
    sudo bash install.sh --panel https://panel.example.com --token TOKEN --node-id 1
    sudo bash install.sh --panel https://panel.example.com --token TOKEN --machine-id 1
    sudo bash install.sh upgrade
    sudo bash install.sh uninstall --purge --yes

HELP
}

parse_args() {
    local positional=()
    while [ $# -gt 0 ]; do
        case "$1" in
            install|upgrade|uninstall|status|help|netcfg)
                ACTION="$1"
                shift
                # For netcfg, pass remaining args through
                if [ "$ACTION" = "netcfg" ]; then
                    NETCFG_ARGS=("$@")
                    return
                fi
                ;;
            --mode)
                MODE="$2"
                shift 2
                ;;
            --panel|-a|--api)
                PANEL_URL="$2"
                shift 2
                ;;
            --token|-t)
                TOKEN="$2"
                shift 2
                ;;
            --node-id|-n)
                NODE_ID="$2"
                shift 2
                ;;
            --node-type|-T)
                NODE_TYPE="$2"
                shift 2
                ;;
            --machine-id)
                MACHINE_ID="$2"
                shift 2
                ;;
            --kernel|-k)
                KERNEL_TYPE="$2"
                shift 2
                ;;
            --version)
                RELEASE_VERSION="$2"
                shift 2
                ;;
            --binary)
                BINARY_SOURCE="$2"
                shift 2
                ;;
            --netcfg-binary)
                CLI_BINARY_SOURCE="$2"
                shift 2
                ;;
            --health-port)
                HEALTH_PORT="$2"
                shift 2
                ;;
            --gomemlimit)
                RUNTIME_GOMEMLIMIT="$2"
                shift 2
                ;;
            --gogc)
                RUNTIME_GOGC="$2"
                shift 2
                ;;
            --force-reconfigure)
                FORCE_RECONFIGURE=1
                shift
                ;;
            --purge)
                PURGE=1
                shift
                ;;
            --yes|-y)
                YES=1
                shift
                ;;
            --help|-h)
                ACTION="help"
                shift
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    if [ ${#positional[@]} -gt 0 ] && [ "$ACTION" = "install" ]; then
        ACTION="${positional[0]}"
    fi

    case "$KERNEL_TYPE" in
        singbox|SingBox|SINGBOX) KERNEL_TYPE="singbox" ;;
        xray|Xray|XRAY) KERNEL_TYPE="xray" ;;
        *) ;;
    esac

    # Auto-detect mode from arguments when --mode is not specified.
    if [ -z "$MODE" ]; then
        if [ -n "$MACHINE_ID" ]; then
            MODE="machine"
        else
            MODE="node"
        fi
    fi

    case "$MODE" in
        node|machine) ;;
        *)
            log_error "Unsupported mode: $MODE"
            usage
            exit 1
            ;;
    esac
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_error "Please run as root or with sudo"
        exit 1
    fi
}

detect_arch() {
    local raw
    raw=$(uname -m)
    case "$raw" in
        x86_64|amd64) ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        *)
            log_error "Unsupported architecture: $raw"
            exit 1
            ;;
    esac
}

detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS="$ID"
    else
        OS="unknown"
    fi
}

ensure_systemd() {
    if ! command -v systemctl >/dev/null 2>&1; then
        log_error "systemd is required for this installer"
        exit 1
    fi
    if [ ! -d /run/systemd/system ]; then
        log_error "This host does not appear to be running systemd"
        exit 1
    fi
}

run_with_retry() {
    local attempts="$1"
    local delay="$2"
    shift 2
    local i=1
    while [ "$i" -le "$attempts" ]; do
        if "$@"; then
            return 0
        fi
        if [ "$i" -lt "$attempts" ]; then
            log_warn "Command failed, retrying in ${delay}s: $*"
            sleep "$delay"
        fi
        i=$((i + 1))
    done
    return 1
}

install_dependencies() {
    case "$OS" in
        ubuntu|debian)
            DEBIAN_FRONTEND=noninteractive run_with_retry 10 3 apt-get update -qq
            DEBIAN_FRONTEND=noninteractive run_with_retry 10 3 apt-get install -y -qq curl wget ca-certificates >/dev/null 2>&1
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                run_with_retry 5 3 dnf install -y -q curl wget ca-certificates >/dev/null 2>&1
            else
                run_with_retry 5 3 yum install -y -q curl wget ca-certificates >/dev/null 2>&1
            fi
            ;;
        *)
            log_warn "OS ${OS} is not in the official support set; continuing best-effort"
            ;;
    esac
}

ensure_dirs() {
    mkdir -p "$INSTALL_ROOT" "$BACKUP_DIR"
    chmod 700 "$INSTALL_ROOT"
}

validate_positive_int() {
    local label="$1"
    local value="$2"
    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
        log_error "${label} must be a positive integer, got: ${value}"
        exit 1
    fi
}

validate_install_request() {
    if [ -z "$PANEL_URL" ]; then
        log_error "Panel URL is required"
        exit 1
    fi
    if [ -z "$TOKEN" ]; then
        log_error "Token is required"
        exit 1
    fi
    if ! [[ "$HEALTH_PORT" =~ ^[0-9]+$ ]]; then
        log_error "health-port must be a non-negative integer"
        exit 1
    fi
    if [ "$HEALTH_PORT" -eq 0 ]; then
        HEALTH_ENABLED=0
    fi
    case "$KERNEL_TYPE" in
        singbox|xray) ;;
        *)
            log_error "Kernel must be singbox or xray"
            exit 1
            ;;
    esac
    case "$MODE" in
        node)
            validate_positive_int "Node ID" "$NODE_ID"
            ;;
        machine)
            validate_positive_int "Machine ID" "$MACHINE_ID"
            ;;
    esac
}

detect_current_state() {
    local has_binary=0 has_vault=0 has_service=0
    [ -x "$BINARY_PATH" ] && has_binary=1
    [ -f "$VAULT_FILE" ] && has_vault=1
    [ -f "$SERVICE_PATH" ] && has_service=1

    if [ "$has_binary" -eq 0 ] && [ "$has_vault" -eq 0 ] && [ "$has_service" -eq 0 ]; then
        CURRENT_STATE="fresh"
    elif [ "$has_binary" -eq 1 ] && [ "$has_vault" -eq 1 ] && [ "$has_service" -eq 1 ]; then
        CURRENT_STATE="installed"
    else
        CURRENT_STATE="partial"
    fi
}

require_reconfigure_confirmation() {
    return
}

select_binary_source() {
    if [ -n "$BINARY_SOURCE" ]; then
        if [ ! -f "$BINARY_SOURCE" ]; then
            log_error "Binary source not found: $BINARY_SOURCE"
            exit 1
        fi
        echo "$BINARY_SOURCE"
        return
    fi
    if [ -f "./systemd-confd" ]; then
        echo "./systemd-confd"
        return
    fi
    if [ -f "./systemd-confd-linux-${ARCH}" ]; then
        echo "./systemd-confd-linux-${ARCH}"
        return
    fi
    echo ""
}

resolve_download_url() {
    local artifact="$1"
    if [ "$RELEASE_VERSION" = "latest" ]; then
        DOWNLOAD_URL="${DEFAULT_DOWNLOAD_BASE}/latest/download/${artifact}"
    else
        DOWNLOAD_URL="${DEFAULT_DOWNLOAD_BASE}/download/${RELEASE_VERSION}/${artifact}"
    fi
}

stage_binary() {
    local staged="$TMP_DIR/systemd-confd"
    local local_src
    local_src=$(select_binary_source)
    if [ -n "$local_src" ]; then
        log_step "Using local binary: ${local_src}"
        cp "$local_src" "$staged"
    else
        resolve_download_url "systemd-confd-linux-${ARCH}"
        log_step "Downloading binary: ${DOWNLOAD_URL}"
        if ! curl -fsSL "$DOWNLOAD_URL" -o "$staged"; then
            log_error "Failed to download binary from ${DOWNLOAD_URL}"
            exit 1
        fi
    fi
    chmod +x "$staged"
    if ! "$staged" -v >/dev/null 2>&1; then
        log_error "Downloaded binary failed version check"
        exit 1
    fi
}

stage_netcfg() {
    local staged="$TMP_DIR/systemd-netcfg"
    local local_src=""
    if [ -n "$CLI_BINARY_SOURCE" ]; then
        if [ ! -f "$CLI_BINARY_SOURCE" ]; then
            log_error "systemd-netcfg binary source not found: $CLI_BINARY_SOURCE"
            exit 1
        fi
        local_src="$CLI_BINARY_SOURCE"
    elif [ -f "./systemd-netcfg" ]; then
        local_src="./systemd-netcfg"
    elif [ -f "./systemd-netcfg-linux-${ARCH}" ]; then
        local_src="./systemd-netcfg-linux-${ARCH}"
    fi
    if [ -n "$local_src" ]; then
        log_step "Using local systemd-netcfg binary: ${local_src}"
        cp "$local_src" "$staged"
    else
        resolve_download_url "systemd-netcfg-linux-${ARCH}"
        log_step "Downloading systemd-netcfg: ${DOWNLOAD_URL}"
        if ! curl -fsSL "$DOWNLOAD_URL" -o "$staged"; then
            log_error "Failed to download systemd-netcfg from ${DOWNLOAD_URL}"
            exit 1
        fi
    fi
    chmod +x "$staged"
    if ! "$staged" n9c1 > /dev/null 2>&1; then
        log_error "Downloaded systemd-netcfg failed version check"
        exit 1
    fi
}

    render_config() {
    local init_args=(
        d2a8
        -a "$([ "$MODE" = "machine" ] && echo "m" || echo "n")"
        -p "$PANEL_URL"
        -k "${KERNEL_TYPE:-singbox}"
        -t "$TOKEN"
        -h "${HEALTH_PORT:-0}"
        -v "$RELEASE_VERSION"
        -r "$INSTALL_ROOT"
    )
    if [ "$MODE" = "machine" ]; then
        init_args+=(-i "$MACHINE_ID")
    else
        init_args+=(-i "$NODE_ID")
        if [ -n "$NODE_TYPE" ]; then
            init_args+=(-y "$NODE_TYPE")
        fi
    fi
    if [ -n "$RUNTIME_GOMEMLIMIT" ]; then
        init_args+=(-m "$RUNTIME_GOMEMLIMIT")
    fi
    if [ -n "$RUNTIME_GOGC" ] && [ "$RUNTIME_GOGC" -gt 0 ] 2>/dev/null; then
        init_args+=(-g "$RUNTIME_GOGC")
    fi

    local output
    output=$("$TMP_DIR/systemd-netcfg" "${init_args[@]}") || {
        log_error "systemd-netcfg config init failed"
        exit 1
    }

    INSTANCE_ID=$(echo "$output" | grep '^INSTANCE_ID=' | cut -d= -f2-)
}

render_service() {
    cat >"$TMP_DIR/${SERVICE_NAME}" <<EOF_UNIT
[Unit]
Description=System Configuration Daemon
Documentation=man:systemd-confd(8)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_ROOT}
ExecStart=${BINARY_PATH}
Restart=always
RestartSec=5
LimitNOFILE=1048576
NoNewPrivileges=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_UNIT
}

backup_existing_state() {
    BACKUP_PATH="${BACKUP_DIR}/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_PATH"
    if [ -x "$BINARY_PATH" ]; then
        cp "$BINARY_PATH" "$BACKUP_PATH/systemd-confd"
    fi
    if [ -x "$CLI_PATH" ]; then
        cp "$CLI_PATH" "$BACKUP_PATH/systemd-netcfg"
    fi
    if [ -f "$VAULT_FILE" ]; then
        cp "$VAULT_FILE" "$BACKUP_PATH/ifstate"
    fi
    if [ -f "$SERVICE_PATH" ]; then
        cp "$SERVICE_PATH" "$BACKUP_PATH/${SERVICE_NAME}"
        SERVICE_EXISTED=1
    else
        SERVICE_EXISTED=0
    fi
}

stop_existing_service() {
    if [ -f "$SERVICE_PATH" ] || systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
}

install_staged_files() {
    stop_existing_service
    install -m 755 "$TMP_DIR/systemd-confd" "$BINARY_PATH"
    if [ -f "$0" ] && [ "$(realpath "$0")" != "$(realpath "$INSTALLER_COPY_PATH" 2>/dev/null || echo "$INSTALLER_COPY_PATH")" ]; then
        install -m 755 "$0" "$INSTALLER_COPY_PATH"
    fi
    install -m 755 "$TMP_DIR/systemd-netcfg" "$CLI_PATH"
    ln -sf "$CLI_PATH" /usr/bin/systemd-netcfg 2>/dev/null || true
    install -m 644 "$TMP_DIR/${SERVICE_NAME}" "$SERVICE_PATH"
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
}

wait_for_health() {
    if ! systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
        return 1
    fi
    if [ "$HEALTH_ENABLED" -eq 0 ]; then
        return 0
    fi
    local attempt=0
    local max_attempts=30
    while [ "$attempt" -lt "$max_attempts" ]; do
        if ! systemctl is-active "$SERVICE_NAME" >/dev/null 2>&1; then
            return 1
        fi
        if curl -fsS "http://127.0.0.1:${HEALTH_PORT}/healthz" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        attempt=$((attempt + 1))
    done
    return 1
}

show_recent_logs() {
    if command -v journalctl >/dev/null 2>&1; then
        journalctl -u "$SERVICE_NAME" -n 30 --no-pager || true
    fi
}

start_service() {
    if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
        systemctl restart "$SERVICE_NAME"
    else
        systemctl start "$SERVICE_NAME"
    fi
    if ! wait_for_health; then
        log_error "Service failed health check"
        show_recent_logs
        return 1
    fi
}

perform_install() {
    validate_install_request
    detect_current_state
    require_reconfigure_confirmation
    TMP_DIR=$(mktemp -d)
    ensure_dirs
    stage_binary
    stage_netcfg
    render_config
    render_service
    backup_existing_state
    install_staged_files
    start_service

    log_info "Installation succeeded"
    log_info "Service: ${SERVICE_NAME}"
    log_info "Vault: ${VAULT_FILE}"
    if [ "$HEALTH_ENABLED" -eq 1 ]; then
        log_info "Health: http://127.0.0.1:${HEALTH_PORT}/healthz"
    fi
    log_info "CLI: ${CLI_PATH}  (run '${CLI_PATH} list' if systemd-netcfg is not in PATH)"
}

perform_upgrade() {
    detect_current_state
    if [ "$CURRENT_STATE" = "fresh" ]; then
        log_warn "No existing install found; falling back to install"
        perform_install
        return
    fi
    TMP_DIR=$(mktemp -d)
    ensure_dirs
    stage_binary
    stage_netcfg
    render_service
    backup_existing_state
    install -m 755 "$TMP_DIR/systemd-confd" "$BINARY_PATH"
    install -m 755 "$TMP_DIR/systemd-netcfg" "$CLI_PATH"
    ln -sf "$CLI_PATH" /usr/bin/systemd-netcfg 2>/dev/null || true
    install -m 644 "$TMP_DIR/${SERVICE_NAME}" "$SERVICE_PATH"
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
    if ! wait_for_health; then
        log_error "Upgrade health check failed"
        show_recent_logs
        return 1
    fi
    log_info "Upgrade succeeded"
}

confirm_uninstall() {
    if [ "$YES" -eq 1 ]; then
        return
    fi
    echo
    read -r -p "Proceed with uninstall? [y/N]: " answer
    if ! [[ "$answer" =~ ^[Yy]$ ]]; then
        log_warn "Uninstall cancelled"
        exit 0
    fi
}

perform_uninstall() {
    confirm_uninstall
    if [ -f "$SERVICE_PATH" ]; then
        systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
        systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
        rm -f "$SERVICE_PATH"
        systemctl daemon-reload || true
    fi
    rm -f "$BINARY_PATH"
    rm -f "$CLI_PATH"
    rm -f /usr/bin/systemd-netcfg 2>/dev/null || true
    if [ "$PURGE" -eq 1 ]; then
        rm -rf "$INSTALL_ROOT"
        log_info "Removed ${INSTALL_ROOT}"
    else
        log_info "Vault preserved at ${VAULT_FILE}"
    fi
    log_info "Uninstall complete"
}

perform_status() {
    detect_current_state
    echo
    echo -e "${BOLD}systemd-confd install status${NC}"
    echo "  state:   ${CURRENT_STATE}"
    if [ -f "$VAULT_FILE" ]; then
        echo "  vault:   ${VAULT_FILE}"
        if [ -x "$CLI_PATH" ]; then
            "$CLI_PATH" b3e7 2>/dev/null || true
        fi
    fi
    if [ -f "$SERVICE_PATH" ]; then
        echo "  service: ${SERVICE_NAME}"
        systemctl status "$SERVICE_NAME" --no-pager || true
    fi
}

# netcfg wrapper function
netcfg() {
    if [ ! -x "$CLI_PATH" ]; then
        log_error "systemd-netcfg not found at $CLI_PATH"
        exit 1
    fi
    
    if [ $# -eq 0 ]; then
        return 0
    fi
    
    case "$1" in
        status)
            "$CLI_PATH" a0f1
            ;;
        list)
            shift
            "$CLI_PATH" b3e7 "$@"
            ;;
        instance)
            shift
            if [ "$1" = "get" ] && [ -n "$2" ]; then
                shift
                "$CLI_PATH" c9d4 "$@"
            else
                "$CLI_PATH" b3e7 "$@"
            fi
            ;;
        config)
            shift
            if [ "$1" = "init" ]; then
                shift
                local args="d2a8"
                while [ $# -gt 0 ]; do
                    case "$1" in
                        --mode)
                            shift
                            if [ "$1" = "node" ]; then
                                args="$args -a n"
                            elif [ "$1" = "machine" ]; then
                                args="$args -a m"
                            fi
                            shift
                            ;;
                        --panel-url)
                            shift
                            args="$args -p $1"
                            shift
                            ;;
                        --node-id|--machine-id)
                            shift
                            args="$args -i $1"
                            shift
                            ;;
                        --token)
                            shift
                            args="$args -t $1"
                            shift
                            ;;
                        --node-type)
                            shift
                            args="$args -y $1"
                            shift
                            ;;
                        --kernel)
                            shift
                            args="$args -k $1"
                            shift
                            ;;
                        --health-port)
                            shift
                            args="$args -h $1"
                            shift
                            ;;
                        --gomemlimit)
                            shift
                            args="$args -m $1"
                            shift
                            ;;
                        --gogc)
                            shift
                            args="$args -g $1"
                            shift
                            ;;
                        --install-root)
                            shift
                            args="$args -r $1"
                            shift
                            ;;
                        --version)
                            shift
                            args="$args -v $1"
                            shift
                            ;;
                        *)
                            shift
                            ;;
                    esac
                done
                # shellcheck disable=SC2086
                "$CLI_PATH" $args
            fi
            ;;
        health)
            "$CLI_PATH" e5f2
            ;;
        service)
            shift
            local args="f7c3"
            for arg in "$@"; do
                case "$arg" in
                    start)
                        args="$args -u"
                        ;;
                    stop)
                        args="$args -d"
                        ;;
                    restart)
                        args="$args -r"
                        ;;
                    enable)
                        args="$args -e"
                        ;;
                    disable)
                        args="$args -b"
                        ;;
                    logs)
                        args="$args -l"
                        ;;
                    status)
                        args="$args -s"
                        ;;
                esac
            done
            # shellcheck disable=SC2086
            "$CLI_PATH" $args
            ;;
        start)
            "$CLI_PATH" f7c3 -u
            ;;
        stop)
            "$CLI_PATH" f7c3 -d
            ;;
        restart)
            "$CLI_PATH" f7c3 -r
            ;;
        logs)
            "$CLI_PATH" f7c3 -l
            ;;
        bind)
            shift
            if [ "$1" = "add-node" ]; then
                shift
                local args="g1b9 -n"
                while [ $# -gt 0 ]; do
                    case "$1" in
                        --panel-url)
                            shift
                            args="$args -p $1"
                            shift
                            ;;
                        --token)
                            shift
                            args="$args -t $1"
                            shift
                            ;;
                        --node-id)
                            shift
                            args="$args -i $1"
                            shift
                            ;;
                        --node-type)
                            shift
                            args="$args -y $1"
                            shift
                            ;;
                        --kernel)
                            shift
                            args="$args -k $1"
                            shift
                            ;;
                        *)
                            shift
                            ;;
                    esac
                done
                # shellcheck disable=SC2086
                sudo "$CLI_PATH" $args
            elif [ "$1" = "add-machine" ]; then
                shift
                local args="g1b9 -m"
                while [ $# -gt 0 ]; do
                    case "$1" in
                        --panel-url)
                            shift
                            args="$args -p $1"
                            shift
                            ;;
                        --token)
                            shift
                            args="$args -t $1"
                            shift
                            ;;
                        --machine-id)
                            shift
                            args="$args -i $1"
                            shift
                            ;;
                        --kernel)
                            shift
                            args="$args -k $1"
                            shift
                            ;;
                        *)
                            shift
                            ;;
                    esac
                done
                # shellcheck disable=SC2086
                sudo "$CLI_PATH" $args
            fi
            ;;
        unbind)
            shift
            if [ "$1" = "remove" ] && [ -n "$2" ]; then
                sudo "$CLI_PATH" h4e6 "$2"
            fi
            ;;
        upgrade)
            shift
            local args="k8d2"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --version)
                        shift
                        args="$args -v $1"
                        shift
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            # shellcheck disable=SC2086
            sudo "$CLI_PATH" $args
            ;;
        uninstall)
            shift
            local args="m3f7"
            while [ $# -gt 0 ]; do
                case "$1" in
                    --purge)
                        args="$args -p"
                        shift
                        ;;
                    --yes|-y)
                        args="$args -y"
                        shift
                        ;;
                    *)
                        shift
                        ;;
                esac
            done
            # shellcheck disable=SC2086
            sudo "$CLI_PATH" $args
            ;;
        version)
            "$CLI_PATH" n9c1
            ;;
        *)
            "$CLI_PATH" "$@"
            ;;
    esac
}

main() {
    parse_args "$@"
    case "$ACTION" in
        help)
            usage
            exit 0
            ;;
        status)
            ensure_systemd
            perform_status
            exit 0
            ;;
        netcfg)
            ensure_systemd
            netcfg "${NETCFG_ARGS[@]}"
            exit $?
            ;;
    esac

    check_root
    detect_arch
    detect_os
    ensure_systemd
    install_dependencies

    case "$ACTION" in
        install)
            perform_install
            ;;
        upgrade)
            perform_upgrade
            ;;
        uninstall)
            perform_uninstall
            ;;
        *)
            log_error "Unknown action: $ACTION"
            usage
            exit 1
            ;;
    esac
}

main "$@"
