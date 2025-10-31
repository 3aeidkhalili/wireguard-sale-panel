#!/usr/bin/env bash
# ============================================================================
# WireGuard Manager (Complete Rewrite - Enhanced Version)
# Features: Auto install, add/remove/list clients, quotas & expiry, Web UI with QR Code
# Version: 6.3.1
# ============================================================================
set -Eeuo pipefail

# --------------------------- Styling & Logging -------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }

# ------------------------------ Globals -------------------------------------
WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/${WG_IFACE}.conf"
SERVER_PRIV="$WG_DIR/server_private.key"
SERVER_PUB="$WG_DIR/server_public.key"
CLIENTS_DIR="$WG_DIR/clients"
QUOTA_DB="$WG_DIR/quota.db"
CLIENT_DB="$WG_DIR/clients.db"
ADMIN_DB="$WG_DIR/admin.db"
SERVER_ENDPOINT_DB="$WG_DIR/endpoint.db"
SERVER_DNS_DB="$WG_DIR/dns.db"
WEB_DIR="/var/www/wireguard"
WEB_ASSETS="$WEB_DIR/assets"
LISTEN_PORT="${LISTEN_PORT:-1010}"
SUBNET="${SUBNET:-10.0.0.0/24}"
MTU="${MTU:-1420}"
DNS_SERVERS="${DNS_SERVERS:-1.1.1.1,8.8.8.8}"

# --------------------------- Helper Functions --------------------------------
need_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root"
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        OS_ID="$ID"
        OS_VER="$VERSION_ID"
    else
        err "Operating system not recognized"
        exit 1
    fi
}

pkg_install() {
    local pkgs=("$@")
    log "Installing packages: ${pkgs[*]}"
    
    case "$OS_ID" in
        ubuntu|debian)
            DEBIAN_FRONTEND=noninteractive apt-get update -y
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y "${pkgs[@]}"
            else
                yum install -y "${pkgs[@]}"
            fi
            ;;
        *)
            err "Unsupported OS: $OS_ID"
            exit 1
            ;;
    esac
}

disable_apparmor() {
    if command -v aa-status >/dev/null && aa-status | grep -q "enabled"; then
        systemctl stop apparmor 2>/dev/null || true
        systemctl disable apparmor 2>/dev/null || true
        ok "AppArmor disabled to allow file access"
    fi
}

configure_selinux() {
    if command -v getenforce >/dev/null && [ "$(getenforce)" = "Enforcing" ]; then
        chcon -R -t httpd_sys_content_t "$WEB_DIR" 2>/dev/null || true
        ok "SELinux context set for web directory"
    fi
}

update_system() {
    log "Updating system packages..."
    case "$OS_ID" in
        ubuntu|debian)
            apt-get update -y && apt-get upgrade -y
            ;;
        centos|rhel|rocky|almalinux|fedora)
            if command -v dnf >/dev/null; then
                dnf upgrade -y
            else
                yum update -y
            fi
            ;;
    esac
    ok "System updated successfully"
}

ensure_line_once() {
    local line="$1" file="$2"
    touch "$file"
    if ! grep -qxF "$line" "$file"; then
        echo "$line" >> "$file"
    fi
}

detect_default_iface() {
    ip route 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0"
}

public_ip() {
    local ip
    ip=$(curl -fsS4 --connect-timeout 10 https://api.ipify.org 2>/dev/null || curl -fsS6 --connect-timeout 10 https://api64.ipify.org 2>/dev/null || true)
    echo "${ip:-IP_SERVER}"
}

cidr_ip_host() {
    local subnet="$1"
    IFS='/' read -r base _ <<< "$subnet"
    IFS='.' read -r a b c d <<< "$base"
    echo "$a.$b.$c.$((d+1))"
}

next_client_ip() {
    local base
    IFS='/' read -r base _ <<< "$SUBNET"
    IFS='.' read -r a b c d <<< "$base"
    local start=$((d+2))
    
    # Read used IPs
    local used_ips=()
    if [[ -f "$CLIENT_DB" ]]; then
        while IFS='|' read -r _ _ _ ip _; do
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+)$ ]]; then
                used_ips+=("${BASH_REMATCH[1]}")
            fi
        done < <(grep -v '^#' "$CLIENT_DB" 2>/dev/null || true)
    fi

    # Find free IP
    for i in $(seq $start 254); do
        local taken=0
        for used in "${used_ips[@]}"; do
            if [[ "$used" == "$i" ]]; then
                taken=1
                break
            fi
        done
        if [[ $taken -eq 0 ]]; then
            echo "$a.$b.$c.$i"
            return 0
        fi
    done
    
    err "No free IPs available in subnet $SUBNET"
    return 1
}

bytes_to_gb() {
    echo "$1" | awk '{printf "%.2f", $1/1024/1024/1024}'
}

generate_qr_base64() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        echo ""
        return 1
    fi
    
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t PNG -o - < "$config_file" | base64 -w 0 2>/dev/null || echo ""
    else
        echo ""
    fi
}

get_server_endpoint() {
    if [[ -f "$SERVER_ENDPOINT_DB" ]]; then
        local stored_endpoint
        stored_endpoint=$(head -n1 "$SERVER_ENDPOINT_DB" 2>/dev/null | tr -d '\n')
        if [[ -n "$stored_endpoint" ]]; then
            echo "$stored_endpoint"
            return 0
        fi
    fi
    echo "$(public_ip):$LISTEN_PORT"
}

get_server_dns() {
    if [[ -f "$SERVER_DNS_DB" ]]; then
        local stored_dns
        stored_dns=$(head -n1 "$SERVER_DNS_DB" 2>/dev/null | tr -d '\n')
        if [[ -n "$stored_dns" ]]; then
            echo "$stored_dns"
            return 0
        fi
    fi
    echo "$DNS_SERVERS"
}

update_all_client_configs() {
    local new_domain="$1" new_port="$2" new_dns="$3"
    local new_endpoint="$new_domain:$new_port"

    log "Updating endpoint in all client configs to: $new_endpoint"
    log "Updating DNS in all client configs to: $new_dns"

    mkdir -p "$CLIENTS_DIR"
    echo "$new_endpoint" > "$SERVER_ENDPOINT_DB"
    echo "$new_dns" > "$SERVER_DNS_DB"

    for client_conf in "$CLIENTS_DIR"/*.conf; do
        [[ -f "$client_conf" ]] || continue

        local private_key address server_pubkey
        private_key=$(grep -m1 -oP 'PrivateKey\s*=\s*\K\S+' "$client_conf" || true)
        address=$(grep -m1 -oP 'Address\s*=\s*\K\S+' "$client_conf" || true)
        server_pubkey=$(grep -m1 -oP 'PublicKey\s*=\s*\K\S+' "$client_conf" || true)

        if [[ -n "$private_key" && -n "$address" && -n "$server_pubkey" ]]; then
            cat > "$client_conf" <<EOF
[Interface]
PrivateKey = $private_key
Address = $address
DNS = $new_dns
MTU = $MTU

[Peer]
PublicKey = $server_pubkey
Endpoint = $new_endpoint
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF
        fi
    done

    if [[ -f "$WG_CONF" ]]; then
        if grep -qE '^ListenPort\s*=' "$WG_CONF"; then
            sed -i "s/^ListenPort\s*=.*/ListenPort = $new_port/" "$WG_CONF"
        else
            sed -i "/^\[Interface\]/a ListenPort = $new_port" "$WG_CONF"
        fi
    fi

    systemctl restart "wg-quick@$WG_IFACE" 2>/dev/null || true
    ok "All client configs updated with new endpoint: $new_endpoint and DNS: $new_dns"
    sync_web_db
}

# --------------------------- Install WireGuard --------------------------------
install_wireguard() {
    log "Installing WireGuard and dependencies..."
    case "$OS_ID" in
        ubuntu|debian)
            pkg_install wireguard-tools qrencode nginx php-fpm php-cli php-curl php-gd bc jq curl
            ;;
        centos|rhel|rocky|almalinux|fedora)
            pkg_install epel-release
            pkg_install wireguard-tools qrencode nginx php-fpm php-cli php-curl php-gd bc jq curl
            ;;
    esac
    
    # Enable IP forwarding
    ensure_line_once "net.ipv4.ip_forward=1" /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
    
    ok "WireGuard and dependencies installed successfully"
}

# --------------------------- Server Setup -------------------------------------
setup_server() {
    log "Configuring WireGuard server..."
    mkdir -p "$WG_DIR" "$CLIENTS_DIR"
    chmod 700 "$WG_DIR"

    # Generate server keys
    if [[ ! -f "$SERVER_PRIV" ]] || [[ ! -f "$SERVER_PUB" ]]; then
        umask 077
        wg genkey | tee "$SERVER_PRIV" | wg pubkey > "$SERVER_PUB"
        ok "Server keys generated"
    else
        ok "Server keys already exist"
    fi

    local srv_ip srv_port nic pubip
    srv_ip=$(cidr_ip_host "$SUBNET")
    srv_port="$LISTEN_PORT"
    nic=$(detect_default_iface)
    pubip=$(public_ip)

    # Create server config
    cat > "$WG_CONF" <<EOF
[Interface]
Address = $srv_ip/24
ListenPort = $srv_port
PrivateKey = $(cat "$SERVER_PRIV")
SaveConfig = false
MTU = $MTU

# NAT and forwarding
PreUp = sysctl -q -w net.ipv4.ip_forward=1
PostUp = iptables -t nat -A POSTROUTING -o $nic -j MASQUERADE; iptables -A FORWARD -i %i -j ACCEPT; iptables -A FORWARD -o %i -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -o $nic -j MASQUERADE; iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -j ACCEPT
EOF

    ok "Server configuration saved to $WG_CONF"
    echo -e "${GREEN}Server Public Key:${NC} $(cat "$SERVER_PUB")"
    echo -e "${GREEN}Server Endpoint:${NC} $pubip:$srv_port"
}

# --------------------------- Firewall ----------------------------------------
configure_firewall() {
    log "Configuring firewall..."
    if command -v ufw >/dev/null 2>&1; then
        ufw allow "$LISTEN_PORT/udp" >/dev/null 2>&1 || true
        ufw allow ssh >/dev/null 2>&1 || true
        ensure_line_once "net.ipv4.ip_forward=1" /etc/ufw/sysctl.conf
        ufw --force enable >/dev/null 2>&1 || true
        ok "UFW configured"
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="$LISTEN_PORT/udp" >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-service=ssh >/dev/null 2>&1 || true
        firewall-cmd --permanent --add-masquerade >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
        ok "firewalld configured"
    else
        warn "No firewall manager found, using iptables rules from WireGuard config"
    fi
}

# --------------------------- Databases ---------------------------------------
init_databases() {
    mkdir -p "$WG_DIR"
    
    if [[ ! -f "$QUOTA_DB" ]]; then
        cat > "$QUOTA_DB" <<'EOF'
# name|used_bytes|limit_bytes|expiry_date|is_active
EOF
    fi
    
    if [[ ! -f "$CLIENT_DB" ]]; then
        cat > "$CLIENT_DB" <<'EOF'
# name|private_key|public_key|ip_address|created_date
EOF
    fi

    if [[ ! -f "$ADMIN_DB" ]]; then
        cat > "$ADMIN_DB" <<'EOF'
# list of admin private keys (one per line)
EOF
        ok "Admin database created - add private keys to /etc/wireguard/admin.db"
    fi

    if [[ ! -f "$SERVER_ENDPOINT_DB" ]]; then
        touch "$SERVER_ENDPOINT_DB"
    fi

    if [[ ! -f "$SERVER_DNS_DB" ]]; then
        echo "$DNS_SERVERS" > "$SERVER_DNS_DB"
    fi
    
    ok "Databases initialized"
}

sync_web_db() {
    local web_user="www-data"
    if getent passwd nginx >/dev/null; then
        web_user="nginx"
    fi

    log "Syncing web files..."

    # ساخت دایرکتوری‌های مورد نیاز
    for dir in "$WEB_DIR" "$WEB_DIR/db" "$WEB_DIR/backups" "$WEB_DIR/clients"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
            ok "Created directory: $dir"
        fi
        chown "$web_user:$web_user" "$dir"
        if [[ "$dir" == *"/db" ]] || [[ "$dir" == *"/backups" ]]; then
            chmod 750 "$dir"
        else
            chmod 755 "$dir"
        fi
    done

    # کپی فایل‌های دیتابیس و کلیدها
    for db_file in "$CLIENT_DB" "$QUOTA_DB" "$ADMIN_DB" "$SERVER_ENDPOINT_DB" "$SERVER_DNS_DB"; do
        if [[ -f "$db_file" ]]; then
            cp "$db_file" "$WEB_DIR/db/$(basename "$db_file")"
            chown "$web_user:$web_user" "$WEB_DIR/db/$(basename "$db_file")"
            chmod 640 "$WEB_DIR/db/$(basename "$db_file")"
        fi
    done

    # کپی فایل‌های دیتابیس
    for db_file in "$CLIENT_DB" "$QUOTA_DB" "$ADMIN_DB" "$SERVER_ENDPOINT_DB" "$SERVER_DNS_DB"; do
        if [[ -f "$db_file" ]]; then
            cp "$db_file" "$WEB_DIR/db/$(basename "$db_file")"
            chown "$web_user:$web_user" "$WEB_DIR/db/$(basename "$db_file")"
            chmod 640 "$WEB_DIR/db/$(basename "$db_file")"
        fi
    done

    # کپی و تنظیم مجوزهای کلیدها
    if [[ -d "$CLIENTS_DIR" ]]; then
        # استفاده از rsync برای کپی امن فایل‌ها
        rsync -a "$CLIENTS_DIR/" "$WEB_DIR/clients/"
        chown -R "$web_user:$web_user" "$WEB_DIR/clients"
        
        # تنظیم مجوزهای مناسب برای انواع مختلف فایل‌ها
        find "$WEB_DIR/clients" -type f -name "*_private.key" -exec chmod 600 {} \;
        find "$WEB_DIR/clients" -type f -name "*_public.key" -exec chmod 644 {} \;
        find "$WEB_DIR/clients" -type f -name "*.conf" -exec chmod 644 {} \;
        find "$WEB_DIR/clients" -type f -name "*.png" -exec chmod 644 {} \;
        
        # تنظیم مجوز دایرکتوری
        chmod 750 "$WEB_DIR/clients"
    fi

    # بررسی دسترسی
    if ! su -s /bin/sh "$web_user" -c "test -w '$WEB_DIR/db'"; then
        err "Warning: Web user ($web_user) cannot write to $WEB_DIR/db"
    fi
}

quota_set() {
    local name="$1" gb="${2:-0}" days="${3:-30}"
    
    if [[ -z "$name" ]]; then
        err "Client name is required"
        return 1
    fi
    
    local limit_bytes=$((gb * 1024 * 1024 * 1024))
    local expiry=$(date -d "+${days} days" +"%Y-%m-%d")
    
    # Remove existing record and add new one
    if [[ -f "$QUOTA_DB" ]]; then
        grep -v "^$name|" "$QUOTA_DB" > "${QUOTA_DB}.tmp" 2>/dev/null || true
        mv "${QUOTA_DB}.tmp" "$QUOTA_DB"
    fi
    
    echo "$name|0|$limit_bytes|$expiry|1" >> "$QUOTA_DB"
    ok "Quota set for $name: ${gb}GB until $expiry"
    sync_web_db
}

quota_get_line() {
    local name="$1"
    grep "^$name|" "$QUOTA_DB" 2>/dev/null | head -n1 || true
}

# --------------------------- Admin Management --------------------------------
add_admin() {
    local private_key="$1"

    if [[ -z "$private_key" ]]; then
        err "Usage: add-admin PRIVATE_KEY"
        return 1
    fi

    touch "$ADMIN_DB"
    if grep -qFx "$private_key" "$ADMIN_DB" 2>/dev/null; then
        warn "This private key is already an admin"
        return 0
    fi

    echo "$private_key" >> "$ADMIN_DB"
    ok "Private key added to admin database"

    local client_name
    client_name=$(grep -F "|$private_key|" "$CLIENT_DB" 2>/dev/null | cut -d'|' -f1 || true)
    if [[ -n "$client_name" ]]; then
        ok "User '$client_name' is now an admin"
    else
        warn "Note: This private key doesn't match any client"
    fi
    sync_web_db
}

remove_admin() {
    local private_key="$1"
    if [[ -z "$private_key" ]]; then
        err "Usage: remove-admin PRIVATE_KEY"
        return 1
    fi

    if grep -qFx "$private_key" "$ADMIN_DB" 2>/dev/null; then
        grep -vFx "$private_key" "$ADMIN_DB" > "${ADMIN_DB}.tmp" && mv "${ADMIN_DB}.tmp" "$ADMIN_DB"
        ok "Private key removed from admin database"
    else
        warn "Private key not found in admin database"
    fi
    sync_web_db
}

is_admin() {
    local private_key="$1"
    if [[ -z "$private_key" ]]; then
        echo "false"
        return 0
    fi
    if [[ -f "$ADMIN_DB" ]] && grep -qFx "$private_key" "$ADMIN_DB" 2>/dev/null; then
        echo "true"
    else
        echo "false"
    fi
}

# --------------------------- Client Management --------------------------------
add_client() {
    local name="$1" gb="${2:-0}" days="${3:-30}"
    
    if [[ -z "$name" ]]; then
        err "Usage: add-client NAME [GB] [DAYS]"
        return 1
    fi
    
    if [[ ! -f "$SERVER_PUB" ]]; then
        err "Server not set up. Run 'install' first."
        return 1
    fi

    # Find next available IP
    local ip
    ip=$(next_client_ip) || return 1
    
    # Generate client keys
    umask 077
    local c_priv c_pub cfg
    c_priv=$(wg genkey)
    c_pub=$(echo "$c_priv" | wg pubkey)
    cfg="$CLIENTS_DIR/${name}.conf"
    
    # Save keys
    echo "$c_priv" > "$CLIENTS_DIR/${name}_private.key"
    echo "$c_pub" > "$CLIENTS_DIR/${name}_public.key"

    # Add to server config
    cat >> "$WG_CONF" <<EOF

[Peer]
PublicKey = $c_pub
AllowedIPs = $ip/32
EOF

    local srv_pub=$(cat "$SERVER_PUB")
    local endpoint=$(get_server_endpoint)
    local dns_servers=$(get_server_dns)

    # Create client config
    cat > "$cfg" <<EOF
[Interface]
PrivateKey = $c_priv
Address = $ip/24
DNS = $dns_servers
MTU = $MTU

[Peer]
PublicKey = $srv_pub
Endpoint = $endpoint
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    # Save to database
    echo "$name|$c_priv|$c_pub|$ip|$(date +%F)" >> "$CLIENT_DB"
    quota_set "$name" "$gb" "$days"

    # Ensure quota chain exists and add per-client rule for monitoring
    CHAIN_NAME="WG-CLIENTS-COUNTS"
    if ! iptables -L "$CHAIN_NAME" -n >/dev/null 2>&1; then
        iptables -N "$CHAIN_NAME" || true
    fi
    if ! iptables -C FORWARD -j "$CHAIN_NAME" >/dev/null 2>&1; then
        iptables -I FORWARD -j "$CHAIN_NAME" || true
    fi
    # add rule for this client IP with comment=name so monitor can match
    if ! iptables -C "$CHAIN_NAME" -s "$ip" -m comment --comment "$name" -j RETURN >/dev/null 2>&1; then
        iptables -I "$CHAIN_NAME" -s "$ip" -m comment --comment "$name" -j RETURN || true
    fi

    # Reload if service is active
    if systemctl is-active --quiet "wg-quick@$WG_IFACE" 2>/dev/null; then
        wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") >/dev/null 2>&1
    fi

    # Generate QR code
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -o "$CLIENTS_DIR/${name}.png" < "$cfg" 2>/dev/null && ok "QR code generated"
    fi

    ok "Client $name added successfully"
    echo -e "${GREEN}Config file:${NC} $cfg"
    echo -e "${GREEN}Private key:${NC} $c_priv"
    
    # Display QR code in terminal if possible
    if command -v qrencode >/dev/null 2>&1 && [ -t 1 ]; then
        echo -e "\n${CYAN}QR Code for client $name:${NC}"
        qrencode -t UTF8 < "$cfg" 2>/dev/null || true
        echo
    fi
    sync_web_db
}

remove_client() {
    local name="$1"
    
    if [[ -z "$name" ]]; then
        err "Usage: remove-client NAME"
        return 1
    fi
    
    local pub_file="$CLIENTS_DIR/${name}_public.key"
    if [[ ! -f "$pub_file" ]]; then
        err "Client $name not found"
        return 1
    fi
    
    local pubkey=$(cat "$pub_file")
    
    # Remove from server config
    if [[ -f "$WG_CONF" ]]; then
        sed -i "/PublicKey = $pubkey/,+2d" "$WG_CONF"
    fi
    
    # Remove files
    rm -f "$CLIENTS_DIR/${name}_public.key" \
          "$CLIENTS_DIR/${name}_private.key" \
          "$CLIENTS_DIR/${name}.conf" \
          "$CLIENTS_DIR/${name}.png" 2>/dev/null || true
    
    # determine client IP from clients.db BEFORE removing DB entries
    ip=""
    if [[ -f "$CLIENT_DB" ]]; then
        ip=$(grep -m1 "^$name|" "$CLIENT_DB" 2>/dev/null | cut -d'|' -f4 || true)
    fi

    # Remove from databases
    if [[ -f "$CLIENT_DB" ]]; then
        grep -v "^$name|" "$CLIENT_DB" > "${CLIENT_DB}.tmp" 2>/dev/null && mv "${CLIENT_DB}.tmp" "$CLIENT_DB"
    fi

    if [[ -f "$QUOTA_DB" ]]; then
        grep -v "^$name|" "$QUOTA_DB" > "${QUOTA_DB}.tmp" 2>/dev/null && mv "${QUOTA_DB}.tmp" "$QUOTA_DB"
    fi

    # Remove iptables rule and state file for quota monitor (use the IP we captured)
    CHAIN_NAME="WG-CLIENTS-COUNTS"
    if [[ -n "$ip" ]] && iptables -C "$CHAIN_NAME" -s "$ip" -m comment --comment "$name" -j RETURN >/dev/null 2>&1; then
        iptables -D "$CHAIN_NAME" -s "$ip" -m comment --comment "$name" -j RETURN || true
    fi
    safe_name=$(echo "$name" | sed 's/[^A-Za-z0-9._-]/_/g')
    rm -f "/var/lib/wg-quota/${safe_name}.last" 2>/dev/null || true

    # Reload service
    if systemctl is-active --quiet "wg-quick@$WG_IFACE" 2>/dev/null; then
        wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") >/dev/null 2>&1
    fi
    
    ok "Client $name removed successfully"
    sync_web_db
}

edit_client() {
    local name="$1" new_gb="${2:-}" new_days="${3:-}"
    
    if [[ -z "$name" ]]; then
        err "Usage: edit-client NAME [NEW_GB] [NEW_DAYS]"
        return 1
    fi
    
    if [[ ! -f "$CLIENT_DB" ]] || ! grep -q "^$name|" "$CLIENT_DB" 2>/dev/null; then
        err "Client $name not found"
        return 1
    fi
    
    local current_line=$(grep "^$name|" "$QUOTA_DB" 2>/dev/null | head -n1)
    if [[ -z "$current_line" ]]; then
        err "Quota information for client $name not found"
        return 1
    fi
    
    IFS='|' read -r _ used current_limit current_expiry active <<< "$current_line"
    
    local new_limit="$current_limit"
    local new_expiry="$current_expiry"
    
    if [[ -n "$new_gb" ]]; then
        new_limit=$((new_gb * 1024 * 1024 * 1024))
    fi
    
    if [[ -n "$new_days" ]]; then
        if [[ "$new_days" == "0" ]]; then
            # If days is 0, set expiry far in the future
            new_expiry="2099-12-31"
        else
            new_expiry=$(date -d "+${new_days} days" +"%Y-%m-%d")
        fi
    fi
    
    # Update record
    grep -v "^$name|" "$QUOTA_DB" > "${QUOTA_DB}.tmp" 2>/dev/null || true
    echo "$name|$used|$new_limit|$new_expiry|$active" >> "${QUOTA_DB}.tmp"
    mv "${QUOTA_DB}.tmp" "$QUOTA_DB"
    
    ok "Client $name updated successfully"
    echo -e "${GREEN}New quota:${NC} $(bytes_to_gb $new_limit)GB"
    echo -e "${GREEN}New expiry:${NC} $new_expiry"
}

list_clients() {
    printf "%-20s %-15s %-12s %-12s %-12s %-8s %-8s\n" "User" "IP" "Used(GB)" "Limit(GB)" "Remaining" "Days" "Active"
    echo "-------------------------------------------------------------------------------------------"
    
    if [[ ! -f "$CLIENT_DB" ]]; then
        return 0
    fi
    
    while IFS='|' read -r name priv pub ip created; do
        [[ "$name" =~ ^# ]] && continue
        
        local qline=$(quota_get_line "$name")
        if [[ -z "$qline" ]]; then
            qline="$name|0|0|2099-12-31|1"
        fi

        IFS='|' read -r _ used limit expiry active <<< "$qline"
        
        # Calculations
        local used_gb limit_gb remain_gb days_remaining
        
        used_gb=$(bytes_to_gb "$used")
        limit_gb=$(bytes_to_gb "$limit")
        
        if [[ "$limit" -gt 0 ]]; then
            remain_gb=$(echo "$used $limit" | awk '{printf "%.2f", ($2-$1)/1024/1024/1024}')
        else
            remain_gb="∞"
        fi
        
        local now=$(date +%s)
        local exp_seconds=$(date -d "$expiry" +%s 2>/dev/null || echo "$now")
        days_remaining=$(( (exp_seconds - now) / 86400 ))
        
        printf "%-20s %-15s %-12s %-12s %-12s %-8s %-8s\n" \
               "$name" "$ip" "$used_gb" "$limit_gb" "$remain_gb" "$days_remaining" "$active"
               
    done < <(grep -v '^#' "$CLIENT_DB" 2>/dev/null || true)
}

# --------------------------- Service Control ----------------------------------
enable_start() {
    log "Starting WireGuard service..."
    systemctl enable "wg-quick@$WG_IFACE" >/dev/null 2>&1
    systemctl restart "wg-quick@$WG_IFACE" >/dev/null 2>&1 || systemctl start "wg-quick@$WG_IFACE" >/dev/null 2>&1
    
    sleep 2
    if systemctl is-active --quiet "wg-quick@$WG_IFACE"; then
        ok "WireGuard is running"
    else
        err "Failed to start WireGuard"
        journalctl -u "wg-quick@$WG_IFACE" -n 20 --no-pager
        return 1
    fi
}

# --------------------------- Web Panel ----------------------------------------
detect_php_fpm_sock() {
    # Search for PHP-FPM sockets
    local sockets=(
        "/run/php/php8.1-fpm.sock"
        "/run/php/php8.0-fpm.sock" 
        "/run/php/php7.4-fpm.sock"
        "/var/run/php/php8.1-fpm.sock"
        "/var/run/php/php8.0-fpm.sock"
        "/var/run/php/php7.4-fpm.sock"
        "/run/php-fpm/www.sock"
        "/var/run/php-fpm/www.sock"
    )
    
    for sock in "${sockets[@]}"; do
        if [[ -S "$sock" ]]; then
            echo "$sock"
            return 0
        fi
    done
    
    # Fallback to TCP
    echo "127.0.0.1:9000"
}

# اسکریپت بروزرسانی endpoint
cat > /usr/local/bin/wg-update-endpoint <<'EOF'
#!/usr/bin/env bash
/usr/local/bin/wireguard-manager update-endpoint "$1" "$2" "$3"
EOF
chmod 755 /usr/local/bin/wg-update-endpoint

create_admin_scripts() {
    log "Creating admin scripts..."
    
    # اسکریپت بررسی مدیر
    cat > /usr/local/bin/wg-admin-is-admin <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PRIVATE_KEY="${1:-}"
# prefer web copy of admin db
WEB_DB_DIR="/var/www/wireguard/db"
ADMIN_DB="$WEB_DB_DIR/admin.db"
if [[ ! -f "$ADMIN_DB" ]]; then
    ADMIN_DB="/etc/wireguard/admin.db"
fi

if [[ -z "$PRIVATE_KEY" ]]; then
    echo "false"
    exit 0
fi

if [[ -f "$ADMIN_DB" ]] && grep -qFx "$PRIVATE_KEY" "$ADMIN_DB" 2>/dev/null; then
    echo "true"
else
    echo "false"
fi
EOF

    # اسکریپت اطلاعات کلاینت
    cat > /usr/local/bin/wg-client-info <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PRIVATE_KEY="${1:-}"
# Prefer web-accessible DB copies
WEB_DB_DIR="/var/www/wireguard/db"
CLIENT_DB="$WEB_DB_DIR/clients.db"
QUOTA_DB="$WEB_DB_DIR/quota.db"
if [[ ! -f "$CLIENT_DB" ]]; then
    CLIENT_DB="/etc/wireguard/clients.db"
fi
if [[ ! -f "$QUOTA_DB" ]]; then
    QUOTA_DB="/etc/wireguard/quota.db"
fi
SERVER_PUB="/etc/wireguard/server_public.key"
SERVER_ENDPOINT_DB="$WEB_DB_DIR/endpoint.db"
SERVER_DNS_DB="$WEB_DB_DIR/dns.db"
if [[ ! -f "$SERVER_ENDPOINT_DB" ]]; then
    SERVER_ENDPOINT_DB="/etc/wireguard/endpoint.db"
fi
if [[ ! -f "$SERVER_DNS_DB" ]]; then
    SERVER_DNS_DB="/etc/wireguard/dns.db"
fi

if [[ -z "$PRIVATE_KEY" ]]; then
    echo '{"status":"error","message":"Private key is required"}'
    exit 1
fi

# پیدا کردن کلاینت بر اساس private key
client_line=$(grep -F "|$PRIVATE_KEY|" "$CLIENT_DB" 2>/dev/null | head -n1 || true)

if [[ -z "$client_line" ]]; then
    echo '{"status":"error","message":"Client not found"}'
    exit 1
fi

IFS='|' read -r client_name private_key public_key ip_address created_date <<< "$client_line"

# پیدا کردن اطلاعات سهمیه
quota_line=$(grep "^$client_name|" "$QUOTA_DB" 2>/dev/null | head -n1 || true)

used_bytes=0
limit_bytes=0
expiry_date="2099-12-31"
is_active=1

if [[ -n "$quota_line" ]]; then
    IFS='|' read -r _ used_bytes limit_bytes expiry_date is_active <<< "$quota_line"
fi

# محاسبات
used_gb=$(echo "$used_bytes" | awk '{printf "%.2f", $1/1024/1024/1024}')
limit_gb=$(echo "$limit_bytes" | awk '{printf "%.2f", $1/1024/1024/1024}')

if [[ "$limit_bytes" -gt 0 ]]; then
    remaining_gb=$(echo "$used_bytes $limit_bytes" | awk '{printf "%.2f", ($2-$1)/1024/1024/1024}')
    usage_percent=$(echo "$used_bytes $limit_bytes" | awk '{printf "%.1f", ($1/$2)*100}')
else
    remaining_gb="Unlimited"
    usage_percent="0.0"
fi

# محاسبه روزهای باقیمانده
now_seconds=$(date +%s)
expiry_seconds=$(date -d "$expiry_date" +%s 2>/dev/null || echo "$now_seconds")
days_remaining=$(( (expiry_seconds - now_seconds) / 86400 ))

if [[ $days_remaining -lt 0 ]]; then
    days_remaining=0
fi

# اطلاعات سرور
server_endpoint=$(cat "$SERVER_ENDPOINT_DB" 2>/dev/null || echo "SERVER_IP:1010")
server_dns=$(cat "$SERVER_DNS_DB" 2>/dev/null || echo "1.1.1.1,8.8.8.8")
server_public_key=$(cat "$SERVER_PUB" 2>/dev/null || echo "SERVER_PUBLIC_KEY")

cat <<JSON
{
    "status": "success",
    "client_name": "$client_name",
    "ip_address": "$ip_address",
    "data_used": "$used_gb",
    "data_limit": "$limit_gb",
    "remaining_data": "$remaining_gb",
    "usage_percent": "$usage_percent",
    "expiry_date": "$expiry_date",
    "days_remaining": "$days_remaining",
    "is_active": "$is_active",
    "server_endpoint": "$server_endpoint",
    "server_dns": "$server_dns",
    "server_public_key": "$server_public_key"
}
JSON
EOF

    # اسکریپت تولید QR کد
    cat > /usr/local/bin/wg-generate-qr <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PRIVATE_KEY="${1:-}"
# prefer web clients dir
CLIENTS_DIR="/var/www/wireguard/clients"
if [[ ! -d "$CLIENTS_DIR" ]]; then
    CLIENTS_DIR="/etc/wireguard/clients"
fi

if [[ -z "$PRIVATE_KEY" ]]; then
    exit 1
fi

# پیدا کردن فایل کانفیگ کلاینت
for client_conf in "$CLIENTS_DIR"/*.conf; do
    if [[ -f "$client_conf" ]] && grep -q "PrivateKey = $PRIVATE_KEY" "$client_conf"; then
        if command -v qrencode >/dev/null 2>&1; then
            qrencode -t PNG -o - < "$client_conf" | base64 -w 0 2>/dev/null || echo ""
            exit 0
        fi
    fi
done

exit 1
EOF

    # اسکریپت مدیریت اصلی
    cat > /usr/local/bin/wg-admin <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"
PARAM1="${2:-}"
PARAM2="${3:-}"
PARAM3="${4:-}"

WG_SCRIPT="/usr/local/bin/wireguard-manager"

case "$ACTION" in
    "add-client")
        "$WG_SCRIPT" add-client "$PARAM1" "$PARAM2" "$PARAM3"
        ;;
    "edit-client")
        "$WG_SCRIPT" edit-client "$PARAM1" "$PARAM2" "$PARAM3"
        ;;
    "remove-client")
        "$WG_SCRIPT" remove-client "$PARAM1"
        ;;
    "set-endpoint")
        "$WG_SCRIPT" update-endpoint "$PARAM1" "$PARAM2" "$PARAM3"
        ;;
    "backup")
        echo "Backup functionality would be implemented here"
        ;;
    "restore")
        echo "Restore functionality would be implemented here"
        ;;
    *)
        echo "Invalid action: $ACTION"
        exit 1
        ;;
esac
EOF

    # اسکریپت‌های وب
    cat > /usr/local/bin/wg-add-client-web <<'EOF'
#!/usr/bin/env bash
/usr/local/bin/wireguard-manager add-client "$1" "$2" "$3"
EOF

    cat > /usr/local/bin/wg-edit-client-web <<'EOF'
#!/usr/bin/env bash
/usr/local/bin/wireguard-manager edit-client "$1" "$2" "$3"
EOF

    cat > /usr/local/bin/wg-remove-client-web <<'EOF'
#!/usr/bin/env bash
/usr/local/bin/wireguard-manager remove-client "$1"
EOF

    chmod 755 /usr/local/bin/wg-*
    
    # کپی اسکریپت اصلی به مسیر قابل دسترسی
    cp "$0" /usr/local/bin/wireguard-manager 2>/dev/null || true
    chmod 755 /usr/local/bin/wireguard-manager

    # تنظیمات سودو
    cat > /etc/sudoers.d/wg-web <<SUDO
www-data ALL=(root) NOPASSWD: /usr/local/bin/wg-admin-is-admin
www-data ALL=(root) NOPASSWD: /usr/local/bin/wg-update-endpoint
www-data ALL=(root) NOPASSWD: /usr/local/bin/wg-client-info
www-data ALL=(root) NOPASSWD: /usr/local/bin/wg-add-client-web
www-data ALL=(root) NOPASSWD: /usr/local/bin/wg-edit-client-web
www-data ALL=(root) NOPASSWD: /usr/local/bin/wg-remove-client-web
www-data ALL=(root) NOPASSWD: /usr/local/bin/wg-generate-qr
www-data ALL=(root) NOPASSWD: /usr/local/bin/wg-admin
SUDO
    chmod 440 /etc/sudoers.d/wg-web
    ok "Admin scripts and sudo permissions configured"
}

install_web() {
    log "Installing and configuring web panel..."
    
    # Install required packages
    case "$OS_ID" in
        ubuntu|debian)
            pkg_install nginx php-fpm php-cli php-curl php-gd
            ;;
        centos|rhel|rocky|almalinux|fedora)
            pkg_install nginx php-fpm php-cli php-curl php-gd
            ;;
    esac

    create_admin_scripts
    
    # تأیید نصب اسکریپت‌ها
    verify_installation || return 1

    # Create web directory
    mkdir -p "$WEB_DIR" "$WEB_ASSETS"
    chown -R www-data:www-data "$WEB_DIR" 2>/dev/null || chown -R nginx:nginx "$WEB_DIR" 2>/dev/null || true
    chmod 755 "$WEB_DIR"

    # Create PHP file (Persian interface)
    # [PHP content remains the same as original]
    cat > "$WEB_DIR/index.php" <<'PHP'
<?php
header('Content-Type: text/html; charset=utf-8');
function h($s)
{
    return htmlspecialchars($s, ENT_QUOTES, 'UTF-8');
}

$ok = false;
$msg = "";
$data = null;
$qr_code = "";
$is_admin = false;
$admin_message = "";
$clients_list = array();
$server_info = array();

// دریافت اطلاعات سرور
function get_server_info()
{
    // Primary storage for web-readable DBs
    $web_db_dir = '/var/www/wireguard/db';

    // Prefer web DB copies so the panel shows latest synced values
    $endpoint = @file_get_contents($web_db_dir . '/endpoint.db');
    if ($endpoint === false || trim($endpoint) === '') {
        $endpoint = @file_get_contents('/etc/wireguard/endpoint.db');
    }

    $dns = @file_get_contents($web_db_dir . '/dns.db');
    if ($dns === false || trim($dns) === '') {
        $dns = @file_get_contents('/etc/wireguard/dns.db');
    }

    $status_output = @shell_exec('systemctl is-active wg-quick@wg0 2>/dev/null');
    $status = trim($status_output ?: 'unknown');

    return array(
        'endpoint' => trim($endpoint) ?: 'SERVER_IP:1010',
        'dns' => trim($dns) ?: '1.1.1.1,8.8.8.8',
        'status' => $status
    );
}

// دریافت لیست کاربران
function get_clients_list()
{
    $clients = array();
    $web_db_dir = '/var/www/wireguard/db';
    $web_clients_dir = '/var/www/wireguard/clients';
    $client_db = $web_db_dir . '/clients.db';
    $quota_db = $web_db_dir . '/quota.db';

    // Fallback to /etc if web copies missing
    if (!file_exists($client_db)) {
        $client_db = '/etc/wireguard/clients.db';
        $web_clients_dir = '/etc/wireguard/clients';
    }
    if (!file_exists($quota_db)) {
        $quota_db = '/etc/wireguard/quota.db';
    }

    if (!file_exists($client_db)) return $clients;

    $lines = file($client_db, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach ($lines as $line) {
        if (strpos($line, '#') === 0) continue;
        $parts = explode('|', $line);
        if (count($parts) < 5) continue;

        $name = $parts[0];
        $private_key = $parts[1];  // استخراج private key از دیتابیس
        $ip = $parts[3];
        $created = $parts[4];

        // بررسی و خواندن private key از فایل اگر در دیتابیس نباشد
        if (empty($private_key)) {
            $key_file = $web_clients_dir . "/${name}_private.key";
            if (file_exists($key_file)) {
                $private_key = trim(file_get_contents($key_file));
            }
        }

        // دریافت اطلاعات سهمیه
        $used = 0;
        $limit = 0;
        $expiry = '';
        $active = 1;

        if (file_exists($quota_db)) {
            $quota_lines = file($quota_db, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            foreach ($quota_lines as $qline) {
                if (strpos($qline, $name . '|') === 0) {
                    $qparts = explode('|', $qline);
                    if (count($qparts) >= 5) {
                        $used = floatval($qparts[1]);
                        $limit = floatval($qparts[2]);
                        $expiry = $qparts[3];
                        $active = intval($qparts[4]);
                    }
                    break;
                }
            }
        }

        // محاسبات
        $used_gb = round($used / 1024 / 1024 / 1024, 2);
        $limit_gb = round($limit / 1024 / 1024 / 1024, 2);
        $remaining_gb = $limit > 0 ? round(($limit - $used) / 1024 / 1024 / 1024, 2) : '∞';

        // محاسبه روزهای باقیمانده
        $days_remaining = 0;
        if ($expiry && $expiry !== '2099-12-31') {
            $now = time();
            $exp_ts = strtotime($expiry);
            $days_remaining = $exp_ts ? max(0, floor(($exp_ts - $now) / 86400)) : 0;
        } else {
            $days_remaining = '∞';
        }

        // خواندن کلید خصوصی
        $private_key = '';
        $private_key_file = "/var/www/wireguard/clients/{$name}_private.key";
        if (file_exists($private_key_file)) {
            $private_key = trim(file_get_contents($private_key_file));
        }

        $clients[] = array(
            'name' => $name,
            'ip' => $ip,
            'private_key' => $private_key,
            'used_gb' => $used_gb,
            'limit_gb' => $limit_gb,
            'remaining_gb' => $remaining_gb,
            'expiry' => $expiry,
            'days_remaining' => $days_remaining,
            'active' => $active
        );
    }

    return $clients;
}

// تابع پشتیبان‌گیری
function create_backup()
{
    // Store backups under web directory so panel and web user can access them
    $web_backup_root = '/var/www/wireguard/backups';
    if (!is_dir($web_backup_root)) {
        @mkdir($web_backup_root, 0755, true);
        @chown($web_backup_root, 'www-data');
        @chgrp($web_backup_root, 'www-data');
    }

    $backup_dir = $web_backup_root . '/wireguard-backup-' . date('Y-m-d-H-i-s');
    $backup_file = $backup_dir . '.tar.gz';

    if (!mkdir($backup_dir, 0755, true)) {
        return false;
    }

    // Prefer web copies of DBs
    $web_db_dir = '/var/www/wireguard/db';
    $files_to_backup = [
        $web_db_dir . '/clients.db',
        $web_db_dir . '/quota.db',
        $web_db_dir . '/admin.db',
        $web_db_dir . '/endpoint.db',
        $web_db_dir . '/dns.db',
        '/etc/wireguard/wg0.conf',
        '/etc/wireguard/server_public.key',
        '/etc/wireguard/server_private.key'
    ];

    foreach ($files_to_backup as $file) {
        if (file_exists($file)) {
            copy($file, $backup_dir . '/' . basename($file));
        } else {
            // Try fallback to /etc for DBs
            $etc_path = '/etc/wireguard/' . basename($file);
            if (file_exists($etc_path)) {
                copy($etc_path, $backup_dir . '/' . basename($etc_path));
            }
        }
    }

    // copy clients directory from /etc or web copy
    if (is_dir($web_db_dir . '/../clients')) {
        shell_exec("cp -r " . escapeshellarg($web_db_dir . '/../clients') . " " . escapeshellarg($backup_dir) . " 2>&1");
    } elseif (is_dir('/etc/wireguard/clients')) {
        shell_exec("cp -r /etc/wireguard/clients " . escapeshellarg($backup_dir) . " 2>&1");
    }

    // create archive
    $cmd = "tar -czf " . escapeshellarg($backup_file) . " -C " . escapeshellarg(dirname($backup_dir)) . " " . escapeshellarg(basename($backup_dir)) . " 2>&1";
    $result = shell_exec($cmd);

    // cleanup
    shell_exec("rm -rf " . escapeshellarg($backup_dir));

    if (file_exists($backup_file)) {
        @chown($backup_file, 'www-data');
        @chgrp($backup_file, 'www-data');
        return $backup_file;
    }
    return false;
}

// تابع بازنشانی پشتیبان
function restore_backup($backup_file)
{
    if (!file_exists($backup_file)) {
        return "فایل پشتیبان یافت نشد";
    }

    $extract_dir = '/tmp/wireguard-restore-' . date('Y-m-d-H-i-s');

    // استخراج فایل آرشیو
    // ensure extraction directory exists
    if (!is_dir($extract_dir)) {
        mkdir($extract_dir, 0755, true);
    }
    $result = shell_exec("tar -xzf " . escapeshellarg($backup_file) . " -C " . escapeshellarg($extract_dir) . " 2>&1");

    if (!is_dir($extract_dir)) {
        return "خطا در استخراج فایل پشتیبان";
    }

    // پیدا کردن دایرکتوری بکاپ
    $backup_dirs = glob($extract_dir . '/wireguard-backup-*');
    if (empty($backup_dirs)) {
        shell_exec("rm -rf " . escapeshellarg($extract_dir));
        return "ساختار پشتیبان نامعتبر است";
    }

    $backup_dir = $backup_dirs[0];

    // بازنشانی فایل‌ها
    $files_to_restore = [
        'clients.db',
        'quota.db',
        'admin.db',
        'endpoint.db',
        'dns.db',
        'wg0.conf',
        'server_public.key',
        'server_private.key'
    ];

    foreach ($files_to_restore as $file) {
        $source = $backup_dir . '/' . $file;
        $destination = '/etc/wireguard/' . $file;

        if (file_exists($source)) {
            copy($source, $destination);
            chmod($destination, 600);
        }
    }

    // بازنشانی دایرکتوری کلاینت‌ها
    if (is_dir($backup_dir . '/clients')) {
        shell_exec("rm -rf /etc/wireguard/clients");
        shell_exec("cp -r " . escapeshellarg($backup_dir . '/clients') . " /etc/wireguard/ 2>&1");
        shell_exec("chmod -R 600 /etc/wireguard/clients");
    }

    // راه‌اندازی مجدد سرویس
    shell_exec("systemctl restart wg-quick@wg0 2>&1");

    // همگام‌سازی با دیتابیس وب: copy each file and set ownership
    $web_db_dir = '/var/www/wireguard/db';
    if (!is_dir($web_db_dir)) {
        @mkdir($web_db_dir, 0755, true);
    }

    foreach (['clients.db', 'quota.db', 'admin.db', 'endpoint.db', 'dns.db'] as $f) {
        $etc_path = '/etc/wireguard/' . $f;
        $web_path = $web_db_dir . '/' . $f;
        if (file_exists($etc_path)) {
            copy($etc_path, $web_path);
            @chmod($web_path, 0640);
            @chown($web_path, 'www-data');
            @chgrp($web_path, 'www-data');
        }
    }

    // copy clients directory into web area for panel usage
    if (is_dir('/etc/wireguard/clients')) {
        $web_clients_dir = '/var/www/wireguard/clients';
        shell_exec("rm -rf " . escapeshellarg($web_clients_dir) . " 2>&1");
        shell_exec("cp -r /etc/wireguard/clients " . escapeshellarg('/var/www/wireguard/') . " 2>&1");
        shell_exec("chmod -R 640 " . escapeshellarg($web_clients_dir) . " 2>&1");
        shell_exec("chown -R www-data:www-data " . escapeshellarg($web_clients_dir) . " 2>&1");
    }

    // حذف فایل‌های موقت
    shell_exec("rm -rf " . escapeshellarg($extract_dir));

    return "پشتیبان با موفقیت بازنشانی شد و سرویس راه‌اندازی مجدد شد";
}

// پردازش درخواست‌های مدیریتی
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $pk = trim($_POST['pk'] ?? '');

    if (!empty($pk)) {
        $admin_check_cmd = "sudo /usr/local/bin/wg-admin-is-admin " . escapeshellarg($pk);
        $admin_output = shell_exec($admin_check_cmd . " 2>&1");
        $is_admin = (trim($admin_output) === "true");

        if ($is_admin) {
            $ok = true;
            $data = array('client_name' => 'مدیر سیستم', 'ip_address' => 'N/A', 'is_admin' => true);

            // دریافت لیست کاربران
            $clients_list = get_clients_list();
            $server_info = get_server_info();
            // پشتیبانی از رفرش AJAX (فقط tbody جدول کاربران)
            if (isset($_POST['action']) && $_POST['action'] === 'refresh') {
                // بازسازی tbody و بازگشت سریع
                if (!empty($clients_list)) {
                    foreach ($clients_list as $client) {
                        $name = h($client['name']);
                        $ip = h($client['ip']);
                        $private_key = h($client['private_key']);
                        $used_gb = h($client['used_gb']);
                        $limit_gb = h($client['limit_gb']);
                        $remaining_gb = h($client['remaining_gb']);
                        $expiry = h($client['expiry']);
                        $days_remaining = $client['days_remaining'] === '∞' ? '∞' : h($client['days_remaining']);
                        $active = $client['active'] ? 'فعال' : 'غیرفعال';
                        $row = "<tr>\n" .
                            "<td><strong>{$name}</strong></td>\n" .
                            "<td>{$ip}</td>\n" .
                            "<td>\n<div class=\"key-container\">\n<input type=\"text\" class=\"private-key\" value=\"{$private_key}\" readonly>\n<button class=\"copy-btn\" onclick=\"copyToClipboard(this)\">📋</button>\n<button class=\"btn\" onclick=\"showKeyModal(this.parentElement.querySelector(\\\'.private-key\\\').value)\">🔍</button>\n</div>\n</td>\n" .
                            "<td>{$used_gb}</td>\n" .
                            "<td>{$limit_gb}</td>\n" .
                            "<td class=\"" . (($client['remaining_gb'] === '∞' || $client['remaining_gb'] > 0) ? 'success' : 'error') . "\"> <strong>{$remaining_gb}</strong></td>\n" .
                            "<td>{$expiry}</td>\n" .
                            "<td class=\"" . (($client['days_remaining'] === '∞' || $client['days_remaining'] > 7) ? 'success' : (($client['days_remaining'] > 0) ? 'warning' : 'error')) . "\"><strong>{$days_remaining}</strong></td>\n" .
                            "<td class=\"" . ($client['active'] ? 'success' : 'error') . "\">{$active}</td>\n" .
                            "<td>\n<div class=\"controls\">\n<button type=\"button\" onclick=\"showEditForm('{$name}', {$limit_gb}, " . ($days_remaining === '∞' ? 0 : $days_remaining) . ") class=\"btn-warning\" style=\"width:auto;padding:8px 15px;margin:2px;\">✏️ ویرایش</button>\n" .
                            "<button type=\"button\" onclick=\"if(confirm('آیا از حذف کاربر \' + '{$name}' + '\' مطمئن هستید؟')) sendAdminAction('remove-client', '{$name}')\" class=\"btn-danger\" style=\"width:auto;padding:8px 15px;margin:2px;\">🗑️ حذف</button>\n</div>\n</td>\n" .
                            "</tr>\n";
                        echo $row;
                    }
                } else {
                    echo "<tr><td colspan=\"10\" style=\"text-align:center;padding:20px;\">📝 هیچ کاربری یافت نشد. اولین کاربر را اضافه کنید.</td></tr>";
                }
                exit;
            }

            // پردازش عملیات مدیریتی
            if (isset($_POST['admin_action'])) {
                $action = $_POST['admin_action'];
                $param1 = $_POST['param1'] ?? '';
                $param2 = $_POST['param2'] ?? '';
                $param3 = $_POST['param3'] ?? '';

                // پردازش بروزرسانی endpoint و DNS
                if ($action === 'set-endpoint') {
                    $domain = $param1 ?? '';
                    $port = $param2 ?? '1010';
                    $dns = $param3 ?? '1.1.1.1,8.8.8.8';

                    if (!empty($domain) && !empty($port) && !empty($dns)) {
                        $endpoint_cmd = "sudo /usr/local/bin/wg-update-endpoint " .
                            escapeshellarg($domain) . " " .
                            escapeshellarg($port) . " " .
                            escapeshellarg($dns);
                        $admin_result = shell_exec($endpoint_cmd . " 2>&1");
                        $admin_message = $admin_result ?: "تنظیمات endpoint و DNS با موفقیت به‌روزرسانی شد";

                        // بروزرسانی اطلاعات سرور
                        $server_info = get_server_info();
                    } else {
                        $admin_message = "خطا: تمام فیلدهای endpoint و DNS باید پر شوند";
                    }
                }
                // پردازش پشتیبان‌گیری
                elseif ($action === 'backup') {
                    $backup_file = create_backup();
                    if ($backup_file) {
                        header('Content-Type: application/octet-stream');
                        header('Content-Disposition: attachment; filename="' . basename($backup_file) . '"');
                        header('Content-Length: ' . filesize($backup_file));
                        readfile($backup_file);
                        unlink($backup_file);
                        exit;
                    } else {
                        $admin_message = "خطا در ایجاد پشتیبان";
                    }
                }
                // پردازش بازنشانی
                elseif ($action === 'restore') {
                    if (isset($_FILES['backup_file']) && $_FILES['backup_file']['error'] === UPLOAD_ERR_OK) {
                        $upload_dir = '/tmp/';
                        $backup_file = $upload_dir . basename($_FILES['backup_file']['name']);

                        if (move_uploaded_file($_FILES['backup_file']['tmp_name'], $backup_file)) {
                            $restore_result = restore_backup($backup_file);
                            $admin_message = $restore_result;
                            unlink($backup_file);

                            // بروزرسانی اطلاعات پس از بازنشانی
                            $clients_list = get_clients_list();
                            $server_info = get_server_info();
                        } else {
                            $admin_message = "خطا در آپلود فایل پشتیبان";
                        }
                    } else {
                        $admin_message = "لطفا یک فایل پشتیبان انتخاب کنید";
                    }
                }
                // سایر عملیات
                else {
                    $admin_cmd = "sudo /usr/local/bin/wg-admin " .
                        escapeshellarg($action) . " " .
                        escapeshellarg($param1) . " " .
                        escapeshellarg($param2) . " " .
                        escapeshellarg($param3);
                    $admin_result = shell_exec($admin_cmd . " 2>&1");
                    $admin_message = $admin_result ?: "دستور اجرا شد";
                }

                // رفرش اطلاعات
                $clients_list = get_clients_list();
                $server_info = get_server_info();
            }
        } else {
            $cmd = "sudo /usr/local/bin/wg-client-info " . escapeshellarg($pk);
            $output = shell_exec($cmd . " 2>&1");
            if ($output !== null) {
                $data = json_decode($output, true);
                if (is_array($data) && isset($data['status']) && $data['status'] === 'success') {
                    $ok = true;
                    $qr_cmd = "sudo /usr/local/bin/wg-generate-qr " . escapeshellarg($pk);
                    $qr_output = shell_exec($qr_cmd . " 2>&1");
                    if (!empty($qr_output)) {
                        $qr_code = trim($qr_output);
                    }
                } else {
                    $msg = $data['message'] ?? "کلید نامعتبر یا کاربر یافت نشد";
                }
            } else {
                $msg = "خطا در اجرای دستور";
            }
        }
    } else {
        $msg = "لطفا کلید خصوصی خود را وارد کنید";
    }
}

// تابع برای بررسی اینکه آیا رشته حاوی کلمه "خطا" است
function contains_error($str)
{
    return strpos($str, 'خطا') !== false;
}
// دريافت اطلاعات لحظه اي سرور
function get_live_server_stats()
{
    $stats = array();

    // اطلاعات CPU
    $cpu_usage = @shell_exec("top -bn1 | grep 'Cpu(s)' | awk '{print $2}' | cut -d'%' -f1");
    $stats['cpu_usage'] = floatval(trim($cpu_usage)) ?: 0;

    // اطلاعات حافظه
    $memory_info = @shell_exec("free -m | grep Mem:");
    if ($memory_info) {
        $memory_parts = preg_split('/\s+/', trim($memory_info));
        $total_memory = $memory_parts[1] ?? 0;
        $used_memory = $memory_parts[2] ?? 0;
        $stats['memory_usage'] = $total_memory > 0 ? round(($used_memory / $total_memory) * 100, 1) : 0;
        $stats['memory_used'] = $used_memory;
        $stats['memory_total'] = $total_memory;
    } else {
        $stats['memory_usage'] = 0;
        $stats['memory_used'] = 0;
        $stats['memory_total'] = 0;
    }

    // اطلاعات ديسك
    $disk_usage = @shell_exec("df -h / | awk 'NR==2 {print $5}' | tr -d '%'");
    $stats['disk_usage'] = intval(trim($disk_usage)) ?: 0;

    // اطلاعات ترافيك شبكه (nload)
    $network_stats = @shell_exec("cat /proc/net/dev | grep -E '(eth0|ens|enp)' | head -1");
    if ($network_stats) {
        $network_parts = preg_split('/\s+/', trim($network_stats));
        $stats['network_rx'] = isset($network_parts[1]) ? round($network_parts[1] / 1024 / 1024, 2) : 0; // MB
        $stats['network_tx'] = isset($network_parts[9]) ? round($network_parts[9] / 1024 / 1024, 2) : 0; // MB
    } else {
        $stats['network_rx'] = 0;
        $stats['network_tx'] = 0;
    }

    // آپ تايم سرور
    $uptime = @shell_exec("uptime -p");
    $stats['uptime'] = $uptime ? trim($uptime) : 'نامشخص';

    return $stats;
}

$server_stats = get_live_server_stats();
?>
<!DOCTYPE html>
<html lang="fa" dir="rtl">

<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>

    <title>پنل مدیریت WireGuard</title>
    <style>
        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
            font-family: vazir, Arial, sans-serif;
        }

        body {
            font-family: vazir, Arial, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 100%);
            color: #ffffff;
            line-height: 1.6;
            min-height: 100vh;
            padding: 20px;
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
        }

        .header {
            text-align: center;
            margin-bottom: 30px;
            padding: 20px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 15px;
            backdrop-filter: blur(10px);
        }

        .header h1 {
            color: #4fc3f7;
            margin-bottom: 10px;
            font-size: 2.2em;
        }

        .header p {
            color: #ccc;
            font-size: 1.1em;
        }

        .card {
            background: rgba(255, 255, 255, 0.1);
            border-radius: 15px;
            padding: 25px;
            margin: 20px 0;
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255, 255, 255, 0.2);
        }

        input,
        button,
        select,
        textarea {
            padding: 12px 15px;
            border-radius: 10px;
            border: 1px solid #444;
            background: rgba(0, 0, 0, 0.4);
            color: #fff;
            width: 100%;
            font-size: 16px;
            margin: 5px 0;
        }

        input:focus,
        select:focus,
        textarea:focus {
            outline: none;
            border-color: #4fc3f7;
            box-shadow: 0 0 10px rgba(79, 195, 247, 0.3);
        }

        .usage-chart-container {
            background: linear-gradient(135deg,
                    rgba(255, 255, 255, 0.07),
                    rgba(255, 255, 255, 0.03));
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 20px;
            padding: 20px;
            margin-bottom: 20px;
            position: relative;
            overflow: hidden;
        }

        .chart-header {
            display: flex;
            align-items: center;
            justify-content: space-between;
            margin-bottom: 15px;
        }

        .chart-controls {
            display: flex;
            gap: 10px;
            align-items: center;
        }

        .chart-timeframe {
            background: rgba(255, 255, 255, 0.08);
            border: 1px solid rgba(255, 255, 255, 0.1);
            border-radius: 10px;
            padding: 6px 12px;
            color: var(--text);
            font-size: 12px;
            cursor: pointer;
            transition: all 0.2s ease;
        }

        .chart-timeframe:hover {
            background: rgba(255, 255, 255, 0.12);
        }

        .chart-timeframe.active {
            background: var(--primary);
            color: white;
        }

        .chart-wrapper {
            position: relative;
            height: 200px;
            width: 100%;
        }

        button {
            background: linear-gradient(135deg, #4fc3f7 0%, #2196f3 100%);
            border: none;
            color: white;
            cursor: pointer;
            font-weight: bold;
            transition: all 0.3s ease;
        }

        button:hover {
            transform: translateY(-2px);
            box-shadow: 0 5px 15px rgba(33, 150, 243, 0.4);
        }

        .grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-top: 20px;
        }

        .stat {
            background: rgba(255, 255, 255, 0.1);
            padding: 20px;
            border-radius: 10px;
            text-align: center;
            border: 1px solid rgba(255, 255, 255, 0.1);
        }

        .stat .value {
            font-size: 1.3em;
            font-weight: bold;
            margin: 10px 0;
        }

        .stat .label {
            font-size: 0.9em;
            opacity: 0.8;
            color: #ccc;
        }

        .success {
            color: #66bb6a;
        }

        .warning {
            color: #ffb74d;
        }

        .error {
            color: #f44336;
        }

        .message {
            padding: 15px;
            border-radius: 10px;
            margin: 15px 0;
            text-align: center;
        }

        .message.error {
            background: rgba(244, 67, 54, 0.2);
            border: 1px solid #f44336;
        }

        .message.success {
            background: rgba(76, 175, 80, 0.2);
            border: 1px solid #4caf50;
        }

        .help {
            font-size: 0.9em;
            opacity: 0.8;
            margin-top: 10px;
            color: #ccc;
        }

        .config-section {
            background: #1e1e1e;
            padding: 20px;
            border-radius: 10px;
            margin: 20px 0;
            direction: ltr;
            text-align: left;
        }

        .config-code {
            color: #ccc;
            font-family: 'Courier New', monospace;
            font-size: 12px;
            white-space: pre-wrap;
            word-break: break-all;
        }

        .qr-container {
            text-align: center;
            margin: 20px 0;
        }

        .qr-image {
            max-width: 300px;
            border: 2px solid #4fc3f7;
            border-radius: 10px;
            padding: 10px;
            background: white;
        }

        .two-column {
            grid-template-columns: 1fr 1fr;
            gap: 20px;
        }

        .admin-panel {
            border-left: 4px solid #4fc3f7;
        }

        .notice {
            padding: 10px;
            border-radius: 8px;
            margin-bottom: 12px;
        }

        .notice.ok {
            background: rgba(16, 185, 129, 0.08);
            border: 1px solid rgba(16, 185, 129, 0.12);
            color: #10b981;
        }

        .notice.err {
            background: rgba(239, 68, 68, 0.06);
            border: 1px solid rgba(239, 68, 68, 0.12);
            color: #ef4444;
        }

        .controls {
            display: flex;
            gap: 8px;
            flex-wrap: wrap;
        }

        .small {
            font-size: 13px;
            color: #94a3b8;
        }

        .table-container {
            overflow-x: auto;
            margin: 15px 0;
        }

        table {
            width: 100%;
            border-collapse: separate;
            border-spacing: 0;
            background: rgba(255, 255, 255, 0.05);
            border-radius: 14px;
            overflow: hidden;
            box-shadow: 0 2px 16px 0 rgba(0, 0, 0, 0.07);
        }

        th,
        td {
            padding: 12px 8px;
            text-align: center;
            border-bottom: 1.5px solid rgba(79, 195, 247, 0.08);
            font-size: 15px;
        }

        th {
            background: rgba(79, 195, 247, 0.13);
            font-weight: bold;
            color: #4fc3f7;
            border-bottom: 2px solid #4fc3f7;
        }

        tr {
            transition: background 0.2s;
        }

        tr:hover {
            background: rgba(33, 150, 243, 0.08);
        }

        .key-container {
            display: flex;
            align-items: center;
            gap: 6px;
            justify-content: center;
        }

        .private-key {
            font-family: 'Courier New', monospace;
            font-size: 13px;
            background: #23272e;
            color: #4fc3f7;
            border: 1px solid #4fc3f7;
            border-radius: 7px;
            padding: 4px 8px;
            width: 170px;
            direction: ltr;
            text-align: left;
            transition: box-shadow 0.2s;
        }

        .private-key:focus {
            box-shadow: 0 0 0 2px #4fc3f7;
        }

        .copy-btn {
            background: #4fc3f7;
            color: #fff;
            border: none;
            border-radius: 6px;
            padding: 4px 8px;
            font-size: 15px;
            cursor: pointer;
            transition: background 0.2s;
        }

        .copy-btn:hover {
            background: #2196f3;
        }

        .btn-danger {
            background: linear-gradient(135deg, #f44336, #d32f2f);
        }

        .btn-warning {
            background: linear-gradient(135deg, #ff9800, #f57c00);
        }

        .btn-success {
            background: linear-gradient(135deg, #4caf50, #388e3c);
        }

        .form-row {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 15px;
        }

        .refresh-btn {
            background: linear-gradient(135deg, #9c27b0, #7b1fa2);
            width: 328px;
            padding: 8px 15px;
            margin-bottom: 15px;
            margin-right: 493px;
        }

        .admin-section {
            margin: 20px 0;
            padding: 20px;
            background: rgba(255, 255, 255, 0.05);
            border-radius: 10px;
        }

        .search-box {
            position: relative;
            margin-bottom: 20px;
        }

        .search-box input {
            padding-left: 40px;
        }

        .search-icon {
            position: absolute;
            left: 15px;
            top: 50%;
            transform: translateY(-50%);
            color: #666;
        }

        .edit-form {
            display: none;
            background: rgba(255, 255, 255, 0.05);
            padding: 15px;
            border-radius: 10px;
            margin: 10px 0;
        }

        @media (max-width: 900px) {
            .private-key {
                width: 110px;
                font-size: 11px;
            }

            th,
            td {
                font-size: 13px;
                padding: 8px 4px;
            }
        }

        @media (max-width: 768px) {

            .two-column,
            .form-row {
                grid-template-columns: 1fr;
            }

            .header h1 {
                font-size: 1.8em;
            }

            .table-container {
                font-size: 12px;
            }
        }

        /* Modal for showing full private key */
        .modal-backdrop {
            position: fixed;
            inset: 0;
            background: rgba(0, 0, 0, 0.6);
            display: none;
            align-items: center;
            justify-content: center;
            z-index: 9999;
            padding: 20px;
        }

        .modal {
            background: #0f1724;
            color: #e6eef8;
            border-radius: 12px;
            max-width: 720px;
            width: 100%;
            padding: 18px;
            box-shadow: 0 8px 40px rgba(2, 6, 23, 0.6);
            border: 1px solid rgba(79, 195, 247, 0.12);
        }

        .modal .modal-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: 10px;
            margin-bottom: 10px;
        }

        .modal .modal-body {
            background: #071021;
            padding: 12px;
            border-radius: 8px;
            font-family: 'Courier New', monospace;
            direction: ltr;
            word-break: break-all;
        }

        .modal .modal-actions {
            margin-top: 12px;
            display: flex;
            gap: 8px;
            justify-content: flex-end;
        }

        .server-stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 15px;
            margin: 20px 0;
        }

        .stat-card {
            background: rgba(255, 255, 255, 0.08);
            border-radius: 12px;
            padding: 20px;
            text-align: center;
            border: 1px solid rgba(255, 255, 255, 0.1);
            transition: all 0.3s ease;
        }

        .stat-card:hover {
            transform: translateY(-5px);
            box-shadow: 0 10px 20px rgba(0, 0, 0, 0.2);
        }

        .stat-card .icon {
            font-size: 2em;
            margin-bottom: 10px;
        }

        .stat-card .value {
            font-size: 20px;
            font-weight: bold;
            margin: 10px 0;
        }

        .stat-card .label {
            font-size: 0.9em;
            opacity: 0.8;
            color: #ccc;
        }

        .progress-bar {
            height: 8px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 4px;
            margin: 10px 0;
            overflow: hidden;
        }

        .progress {
            height: 100%;
            border-radius: 4px;
            transition: width 0.5s ease;
        }

        .progress.cpu {
            background: linear-gradient(90deg, #4fc3f7, #2196f3);
        }

        .progress.memory {
            background: linear-gradient(90deg, #66bb6a, #4caf50);
        }

        .progress.disk {
            background: linear-gradient(90deg, #ff9800, #f57c00);
        }

        .progress.network {
            background: linear-gradient(90deg, #9c27b0, #7b1fa2);
        }
    </style>
    <script>
        function searchUsers() {
            const input = document.getElementById('searchUsers');
            const filter = input.value.toLowerCase();
            const table = document.getElementById('clientsTable');
            const tr = table.getElementsByTagName('tr');

            for (let i = 1; i < tr.length; i++) {
                const td = tr[i].getElementsByTagName('td')[0];
                if (td) {
                    const txtValue = td.textContent || td.innerText;
                    if (txtValue.toLowerCase().indexOf(filter) > -1) {
                        tr[i].style.display = '';
                    } else {
                        tr[i].style.display = 'none';
                    }
                }
            }
        }

        function showEditForm(clientName, currentGB, currentDays) {
            document.getElementById('editClientName').value = clientName;
            document.getElementById('editClientGB').value = currentGB;
            document.getElementById('editClientDays').value = currentDays;
            document.getElementById('editForm').style.display = 'block';
        }

        function hideEditForm() {
            document.getElementById('editForm').style.display = 'none';
        }

        function confirmDelete(clientName) {
            return confirm('آیا از حذف کاربر "' + clientName + '" مطمئن هستید؟');
        }

        // تابع کپی کردن Private Key
        function copyToClipboard(button) {
            const input = button.parentElement.querySelector('.private-key');
            const value = input ? input.value || input.textContent : '';

            if (!value) {
                // flash error briefly
                const original = button.innerText;
                button.innerText = '❌';
                setTimeout(() => button.innerText = original, 900);
                return;
            }

            // Use modern Clipboard API when available
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(value).then(() => {
                    const originalEmoji = button.innerText;
                    button.innerText = '✅';
                    button.style.color = '#4caf50';
                    setTimeout(() => {
                        button.innerText = originalEmoji;
                        button.style.color = '';
                    }, 1000);
                }).catch(() => {
                    // fallback
                    fallbackCopy(value, button);
                });
            } else {
                fallbackCopy(value, button);
            }
        }

        function fallbackCopy(text, button) {
            // create temporary textarea
            const ta = document.createElement('textarea');
            ta.value = text;
            ta.setAttribute('readonly', '');
            ta.style.position = 'absolute';
            ta.style.left = '-9999px';
            document.body.appendChild(ta);
            ta.select();
            try {
                document.execCommand('copy');
                const originalEmoji = button.innerText;
                button.innerText = '✅';
                button.style.color = '#4caf50';
                setTimeout(() => {
                    button.innerText = originalEmoji;
                    button.style.color = '';
                }, 1000);
            } catch (e) {
                const originalEmoji = button.innerText;
                button.innerText = '❌';
                setTimeout(() => button.innerText = originalEmoji, 900);
            }
            ta.remove();
        }

        // Show full private key in modal
        function showKeyModal(key) {
            const backdrop = document.getElementById('keyModalBackdrop');
            const body = document.getElementById('keyModalBody');
            if (backdrop && body) {
                body.textContent = key;
                backdrop.style.display = 'flex';
            }
        }

        function closeKeyModal() {
            const backdrop = document.getElementById('keyModalBackdrop');
            if (backdrop) backdrop.style.display = 'none';
        }
    </script>
</head>

<body>
    <div class="container">
        <div class="header">
            <h1>🔒 پنل مدیریت WireGuard</h1>
            <p>مدیریت پیشرفته کاربران، سهمیه‌بندی، QR Code و تنظیمات حرفه‌ای</p>
        </div>

        <!-- Modal for displaying full private key -->
        <div id="keyModalBackdrop" class="modal-backdrop" onclick="closeKeyModal()" aria-hidden="true">
            <div class="modal" role="dialog" aria-modal="true" onclick="event.stopPropagation()">
                <div class="modal-header">
                    <strong>کلید خصوصی (Private Key)</strong>
                    <button onclick="closeKeyModal()" style="background:transparent;border:none;color:#fff;font-size:18px;cursor:pointer">✖</button>
                </div>
                <div id="keyModalBody" class="modal-body">-----</div>
                <div class="modal-actions">
                    <button class="copy-btn" onclick="(function(){ const k=document.getElementById('keyModalBody').textContent; if(navigator.clipboard) navigator.clipboard.writeText(k); else { const ta=document.createElement('textarea'); ta.value=k; document.body.appendChild(ta); ta.select(); document.execCommand('copy'); ta.remove(); } })()">📋 کپی</button>
                    <button class="btn" onclick="closeKeyModal()">بستن</button>
                </div>
            </div>
        </div>

        <div class="card">
            <h2>🔍 بررسی وضعیت اتصال</h2>
            <form method="post">
                <input type="text" name="pk" placeholder="کلید خصوصی خود را اینجا وارد کنید..." required>
                <button type="submit">📊 بررسی وضعیت</button>
            </form>
            <div class="help">
                PrivateKey را از فایل کانفیگ خود کپی کرده و در فیلد بالا قرار دهید.
            </div>
        </div>

        <?php if ($ok && $data): ?>
            <?php if ($is_admin): ?>
                <!-- پنل مدیریت -->
                <div class="card admin-panel">
                    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:20px">
                        <div>
                            <h2 style="margin:0;color:#4fc3f7">👨‍💼 پنل مدیریت</h2>
                            <div class="small">دسترسی کامل به مدیریت کاربران و تنظیمات سیستم</div>
                        </div>
                        <div style="background:rgba(76,175,80,0.2);padding:8px 15px;border-radius:20px;border:1px solid #4caf50">
                            🟢 دسترسی مدیر
                        </div>
                    </div>

                    <?php if (!empty($admin_message)): ?>
                        <div class="message <?php echo contains_error($admin_message) ? 'error' : 'success'; ?>" style="margin-top:12px;white-space:pre-wrap"><?php echo h($admin_message); ?></div>
                    <?php endif; ?>

                    <!-- اطلاعات سرور -->
                    <div class="admin-section">
                        <h3>📊 اطلاعات سرور</h3>
                        <div class="grid">
                            <div class="stat">
                                <div class="label">آدرس سرور</div>
                                <div class="value"><?php echo h($server_info['endpoint'] ?? 'N/A'); ?></div>
                            </div>
                            <div class="stat">
                                <div class="label">DNS سرورها</div>
                                <div class="value"><?php echo h($server_info['dns'] ?? 'N/A'); ?></div>
                            </div>
                            <div class="stat">
                                <div class="label">تعداد کاربران</div>
                                <div class="value"><?php echo count($clients_list); ?></div>
                            </div>
                            <div class="stat">
                                <div class="label">وضعیت سرویس</div>
                                <div class="value <?php echo ($server_info['status'] === 'active') ? 'success' : 'error'; ?>">
                                    <?php echo ($server_info['status'] === 'active') ? '🟢 فعال' : '🔴 غیرفعال'; ?>
                                </div>
                            </div>
                        </div>

                        <!-- بخش اطلاعات سرور -->
                        <div class="card">
                            <h2>📊 اطلاعات لحظه‌ای سرور</h2>
                            <div class="server-stats-grid">
                                <div class="stat-card">
                                    <div class="icon">⚡</div>
                                    <div class="label">مصرف CPU</div>
                                    <div class="value"><?php echo $server_stats['cpu_usage']; ?>%</div>
                                    <div class="progress-bar">
                                        <div class="progress cpu" style="width: <?php echo $server_stats['cpu_usage']; ?>%"></div>
                                    </div>
                                </div>
                                <div class="stat-card">
                                    <div class="icon">🧠</div>
                                    <div class="label">مصرف حافظه</div>
                                    <div class="value"><?php echo $server_stats['memory_usage']; ?>%</div>
                                    <div class="progress-bar">
                                        <div class="progress memory" style="width: <?php echo $server_stats['memory_usage']; ?>%"></div>
                                    </div>
                                    <div class="small"><?php echo $server_stats['memory_used']; ?>MB / <?php echo $server_stats['memory_total']; ?>MB</div>
                                </div>
                                <div class="stat-card">
                                    <div class="icon">💾</div>
                                    <div class="label">مصرف دیسک</div>
                                    <div class="value"><?php echo $server_stats['disk_usage']; ?>%</div>
                                    <div class="progress-bar">
                                        <div class="progress disk" style="width: <?php echo $server_stats['disk_usage']; ?>%"></div>
                                    </div>
                                </div>
                                <div class="stat-card">
                                    <div class="icon">🌐</div>
                                    <div class="label">ترافیک شبکه</div>
                                    <div class="value"><?php echo $server_stats['network_rx']; ?>MB ↓ / <?php echo $server_stats['network_tx']; ?>MB ↑</div>
                                    <div class="progress-bar">
                                        <div class="progress network" style="width: 50%"></div>
                                    </div>
                                    <div class="small">آپلود / دانلود</div>
                                </div>
                            </div>
                            <div class="small" style="text-align: center; margin-top: 10px;">
                                آپ‌تایم سرور: <?php echo $server_stats['uptime']; ?>
                            </div>
                        </div>
                    </div>
                    <!-- مدیریت کاربران -->
                    <div class="admin-section">
                        <h3>👥 مدیریت کاربران</h3>
                        <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px;margin-bottom:20px">
                            <!-- افزودن کاربر جدید -->
                            <div class="card" style="padding:15px">
                                <h4 style="margin:0 0 12px;color:#4caf50">➕ افزودن کاربر جدید</h4>
                                <form method="post">
                                    <input type="hidden" name="pk" value="<?php echo h($_POST['pk']); ?>">
                                    <input type="hidden" name="admin_action" value="add-client">
                                    <input type="text" name="param1" placeholder="نام کاربر" required>
                                    <div class="form-row">
                                        <input type="number" name="param2" placeholder="سهمیه (GB)" min="0" step="0.1" required>
                                        <input type="number" name="param3" placeholder="مدت (روز)" min="1" required>
                                    </div>
                                    <button type="submit" class="btn-success">افزودن کاربر</button>
                                </form>
                            </div>

                            <!-- ویرایش کاربر -->
                            <div class="card" style="padding:15px">
                                <h4 style="margin:0 0 12px;color:#ff9800">✏️ ویرایش کاربر</h4>
                                <div id="editForm" class="edit-form">
                                    <form method="post">
                                        <input type="hidden" name="pk" value="<?php echo h($_POST['pk']); ?>">
                                        <input type="hidden" name="admin_action" value="edit-client">
                                        <input type="hidden" name="param1" id="editClientName">
                                        <div class="form-row">
                                            <input type="number" name="param2" id="editClientGB" placeholder="سهمیه جدید (GB)" min="0" step="0.1" required>
                                            <input type="number" name="param3" id="editClientDays" placeholder="مدت جدید (روز)" required>
                                        </div>
                                        <div class="controls">
                                            <button type="submit" class="btn-warning">ذخیره تغییرات</button>
                                            <button type="button" onclick="hideEditForm()" class="btn">انصراف</button>
                                        </div>
                                    </form>
                                </div>
                                <div class="help">برای ویرایش کاربر، از لیست زیر روی دکمه ویرایش کلیک کنید</div>
                            </div>
                        </div>

                        <!-- جستجوی کاربران -->
                        <div class="search-box">
                            <input type="text" id="searchUsers" placeholder="جستجوی کاربر بر اساس نام..." onkeyup="searchUsers()">
                            <span class="search-icon">🔍</span>
                        </div>

                        <!-- لیست کاربران -->
                        <div class="table-container">
                            <table id="clientsTable">
                                <thead>
                                    <tr>
                                        <th>نام کاربر</th>
                                        <th>آدرس IP</th>
                                        <th>Private Key</th>
                                        <th>مصرف (GB)</th>
                                        <th>سقف (GB)</th>
                                        <th>باقیمانده (GB)</th>
                                        <th>تاریخ انقضا</th>
                                        <th>روز باقیمانده</th>
                                        <th>وضعیت</th>
                                        <th>عملیات</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    <?php if (!empty($clients_list)): ?>
                                        <?php foreach ($clients_list as $client): ?>
                                            <tr>
                                                <td><strong><?php echo h($client['name']); ?></strong></td>
                                                <td><?php echo h($client['ip']); ?></td>
                                                <td>
                                                    <div class="key-container">
                                                        <input type="text" class="private-key" value="<?php echo h($client['private_key']); ?>" readonly>
                                                        <button class="btn" onclick="showKeyModal(this.parentElement.querySelector('.private-key').value)" title="نمایش کامل" style="width:auto;padding:6px 8px;margin:0">🔍</button>
                                                    </div>
                                                </td>
                                                <td><?php echo h($client['used_gb']); ?></td>
                                                <td><?php echo h($client['limit_gb']); ?></td>
                                                <td class="<?php echo ($client['remaining_gb'] === '∞' || $client['remaining_gb'] > 0) ? 'success' : 'error'; ?>">
                                                    <strong><?php echo h($client['remaining_gb']); ?></strong>
                                                </td>
                                                <td><?php echo h($client['expiry']); ?></td>
                                                <td class="<?php echo ($client['days_remaining'] === '∞' || $client['days_remaining'] > 7) ? 'success' : (($client['days_remaining'] > 0) ? 'warning' : 'error'); ?>">
                                                    <strong><?php echo h($client['days_remaining']); ?></strong>
                                                </td>
                                                <td class="<?php echo ($client['active'] ? 'success' : 'error'); ?>">
                                                    <?php echo ($client['active'] ? 'فعال' : 'غیرفعال'); ?>
                                                </td>
                                                <td>
                                                    <div class="controls">
                                                        <button type="button" onclick="showEditForm('<?php echo h($client['name']); ?>', <?php echo h($client['limit_gb']); ?>, <?php echo ($client['days_remaining'] === '∞' ? 0 : h($client['days_remaining'])); ?>)"
                                                            class="btn-warning" style="width:auto;padding:8px 15px;margin:2px;">
                                                            ✏️ ویرایش
                                                        </button>
                                                        <button type="button" onclick="if(confirm('آیا از حذف کاربر \"' + ' <?php echo h($client['name']); ?>' + '\" مطمئن هستید؟' )) sendAdminAction('remove-client', '<?php echo h($client['name']); ?>' )" class="btn-danger" style="width:auto;padding:8px 15px;margin:2px;">🗑️ حذف</button>
                                                    </div>
                                                </td>
                                            </tr>
                                        <?php endforeach; ?>
                                    <?php else: ?>
                                        <tr>
                                            <td colspan="10" style="text-align:center;padding:20px;">
                                                📝 هیچ کاربری یافت نشد. اولین کاربر را اضافه کنید.
                                            </td>
                                        </tr>
                                    <?php endif; ?>
                                </tbody>
                            </table>
                        </div>
                    </div>
                    <!-- دکمه رفرش -->
                    <form method="post">
                        <input type="hidden" name="pk" value="<?php echo h($_POST['pk']); ?>">
                        <button type="submit" class="refresh-btn">🔄 بروزرسانی اطلاعات</button>
                    </form>
                    <script>
                        // تابع رفرش خودکار لیست
                        function refreshUserList() {
                            const pkInput = document.querySelector('input[name="pk"]');
                            if (!pkInput) return; // nothing to refresh for non-admin view

                            fetch(window.location.href, {
                                    method: 'POST',
                                    body: new URLSearchParams({
                                        'action': 'refresh',
                                        'pk': pkInput.value
                                    })
                                })
                                .then(response => response.text())
                                .then(html => {
                                    const parser = new DOMParser();
                                    const doc = parser.parseFromString(html, 'text/html');
                                    const newTable = doc.querySelector('#clientsTable tbody');
                                    if (newTable) {
                                        const tbody = document.querySelector('#clientsTable tbody');
                                        if (tbody) tbody.innerHTML = newTable.innerHTML;
                                    }
                                }).catch(() => {
                                    /* ignore network errors silently */
                                });
                        }

                        // ارسال عملیات مدیریتی به سرور (AJAX) برای حذف/ویرایش بدون لود کامل صفحه
                        function sendAdminAction(action, param1 = '', param2 = '', param3 = '') {
                            const pkInput = document.querySelector('input[name="pk"]');
                            if (!pkInput || !pkInput.value) {
                                alert('کلید خصوصی مدیر موجود نیست');
                                return;
                            }

                            const body = new URLSearchParams();
                            body.append('pk', pkInput.value);
                            body.append('admin_action', action);
                            if (param1 !== '') body.append('param1', param1);
                            if (param2 !== '') body.append('param2', param2);
                            if (param3 !== '') body.append('param3', param3);

                            fetch(window.location.href, {
                                method: 'POST',
                                body: body
                            }).then(() => {
                                // بعد از انجام عملیات، tbody را رفرش کن
                                refreshUserList();
                            }).catch(() => {
                                alert('خطا در ارسال درخواست مدیریتی');
                            });
                        }

                        // رفرش خودکار هر 30 ثانیه
                        setInterval(refreshUserList, 30000);

                        // رفرش اولیه در لود صفحه
                        document.addEventListener('DOMContentLoaded', () => {
                            const refreshBtn = document.querySelector('.refresh-btn');
                            if (refreshBtn) {
                                refreshBtn.addEventListener('click', refreshUserList);
                            }
                        });
                    </script>
                    <!-- تنظیمات سرور -->
                    <div class="admin-section">
                        <h3>⚙️ تنظیمات سرور</h3>
                        <div style="display:grid;grid-template-columns:1fr 1fr;gap:20px">
                            <div class="card" style="padding:15px">
                                <h4 style="margin:0 0 12px">🌐 تنظیم Endpoint و DNS</h4>
                                <form method="post">
                                    <input type="hidden" name="pk" value="<?php echo h($_POST['pk']); ?>">
                                    <input type="hidden" name="admin_action" value="set-endpoint">
                                    <?php
                                    $current_endpoint = $server_info['endpoint'] ?? 'SERVER_IP:1010';
                                    $endpoint_parts = explode(':', $current_endpoint);
                                    $current_domain = $endpoint_parts[0] ?? '';
                                    $current_port = $endpoint_parts[1] ?? '1010';
                                    $current_dns = $server_info['dns'] ?? '1.1.1.1,8.8.8.8';
                                    ?>
                                    <input type="text" name="param1" placeholder="دامنه یا IP سرور" required value="<?php echo h($current_domain); ?>">
                                    <div class="form-row">
                                        <input type="number" name="param2" placeholder="پورت" min="1" max="65535" required value="<?php echo h($current_port); ?>">
                                        <input type="text" name="param3" placeholder="DNS سرورها" required value="<?php echo h($current_dns); ?>">
                                    </div>
                                    <button type="submit">بروزرسانی تنظیمات</button>
                                </form>
                            </div>

                            <div class="card" style="padding:15px">
                                <h4 style="margin:0 0 12px">💾 پشتیبان‌گیری و بازیابی</h4>
                                <form method="post" style="margin-bottom:8px">
                                    <input type="hidden" name="pk" value="<?php echo h($_POST['pk']); ?>">
                                    <input type="hidden" name="admin_action" value="backup">
                                    <button type="submit" style="width:100%">💾 ایجاد پشتیبان</button>
                                </form>
                                <form method="post" enctype="multipart/form-data">
                                    <input type="hidden" name="pk" value="<?php echo h($_POST['pk']); ?>">
                                    <input type="hidden" name="admin_action" value="restore">
                                    <input type="file" name="backup_file" accept=".tar.gz,.gz" required style="margin-bottom:8px">
                                    <button type="submit" style="width:100%;background:linear-gradient(135deg, #9c27b0, #7b1fa2)">🔄 بازیابی پشتیبان</button>
                                </form>
                            </div>
                        </div>
                    </div>
                </div>

            <?php else: ?>
                <!-- پنل کاربر عادی -->
                <div class="two-column">
                    <div>
                        <div class="card">
                            <h2>📈 نتیجه بررسی</h2>
                            <div class="grid">
                                <div class="stat">
                                    <div class="label">👤 کاربر</div>
                                    <div class="value"><?php echo h($data['client_name']); ?></div>
                                </div>
                                <div class="stat">
                                    <div class="label">🌐 آدرس IP</div>
                                    <div class="value"><?php echo h($data['ip_address']); ?></div>
                                </div>
                                <div class="stat">
                                    <div class="label">📊 مصرف شده</div>
                                    <div class="value"><?php echo h($data['data_used']); ?> GB</div>
                                </div>
                                <div class="stat">
                                    <div class="label">📈 سقف مصرف</div>
                                    <div class="value"><?php echo h($data['data_limit']); ?> GB</div>
                                </div>
                                <div class="stat">
                                    <div class="label">📉 باقیمانده</div>
                                    <div class="value <?php echo ($data['remaining_data'] == 'Unlimited' ? 'success' : (floatval($data['remaining_data']) > 0 ? '' : 'error')); ?>">
                                        <?php echo h($data['remaining_data']); ?> GB
                                    </div>
                                </div>
                                <div class="stat">
                                    <div class="label">📊 درصد مصرف</div>
                                    <div class="value <?php echo (floatval($data['usage_percent']) < 80 ? 'success' : (floatval($data['usage_percent']) < 95 ? 'warning' : 'error')); ?>">
                                        <?php echo h($data['usage_percent']); ?>%
                                    </div>
                                </div>
                                <div class="stat">
                                    <div class="label">📅 تاریخ انقضا</div>
                                    <div class="value"><?php echo h($data['expiry_date']); ?></div>
                                </div>
                                <div class="stat">
                                    <div class="label">⏳ روزهای باقیمانده</div>
                                    <div class="value <?php echo ($data['days_remaining'] > 7 ? 'success' : ($data['days_remaining'] > 0 ? 'warning' : 'error')); ?>">
                                        <?php echo h($data['days_remaining']); ?> روز
                                    </div>
                                </div>
                                <div class="stat">
                                    <div class="label">🔐 وضعیت</div>
                                    <div class="value <?php echo ($data['is_active'] ? 'success' : 'error'); ?>">
                                        <?php echo ($data['is_active'] ? 'فعال' : 'غیرفعال'); ?>
                                    </div>
                                </div>
                            </div>
                        </div>

                        <div class="card">
                            <h2>📄 اطلاعات کانفیگ</h2>
                            <div class="config-section">
                                <pre class="config-code">[Interface]
PrivateKey = <?php echo h($_POST['pk']); ?> 
Address = <?php echo h($data['ip_address']); ?>/24
DNS = <?php echo h($data['server_dns'] ?? '1.1.1.1,8.8.8.8'); ?> 
MTU = 1420

[Peer]
PublicKey = <?php echo h($data['server_public_key']); ?> 
Endpoint = <?php echo h($data['server_endpoint']); ?> 
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25</pre>
                            </div>
                            <div class="help">
                                💡 این اطلاعات برای اتصال شما ضروری است. می‌توانید از آن برای تنظیم دستی کلاینت استفاده کنید.
                            </div>
                        </div>
                    </div>
                    <div class="usage-chart-container">
                        <div class="chart-header">
                            <h3 style="margin: 0">📈 نمودار مصرف روزانه</h3>
                            <div class="chart-controls">
                                <button class="chart-timeframe active" data-days="7">۷ روز</button>
                                <button class="chart-timeframe" data-days="30">۳۰ روز</button>
                                <button class="chart-timeframe" data-days="90">۹۰ روز</button>
                            </div>
                        </div>
                        <div class="chart-wrapper">
                            <canvas id="usageChart" width="1375" height="200" style="display: block; box-sizing: border-box; height: 200px; width: 1375.4px;"></canvas>
                        </div>
                    </div>
                    <div>
                        <?php if (!empty($qr_code)): ?>
                            <div class="card">
                                <h2>📱 QR Code</h2>
                                <div class="qr-container">
                                    <img src="data:image/png;base64,<?php echo $qr_code; ?>" alt="QR Code" class="qr-image">
                                </div>
                                <div class="help">
                                    📸 این QR Code را با اپلیکیشن WireGuard اسکن کنید تا به طور خودکار تنظیم شود.
                                </div>
                            </div>
                        <?php else: ?>
                            <div class="card">
                                <h2>📱 QR Code</h2>
                                <div class="message warning">
                                    ❌ تولید QR Code با مشکل مواجه شد. لطفاً از فایل کانفیگ استفاده کنید.
                                </div>
                            </div>
                        <?php endif; ?>
                    </div>
                </div>
            <?php endif; ?>

        <?php elseif (!empty($msg)): ?>
            <div class="card">
                <div class="message error">
                    ❌ <?php echo h($msg); ?>
                </div>
            </div>
        <?php endif; ?>
    </div>
</body>

</html>
PHP

    # Set file permissions
    chown -R www-data:www-data "$WEB_DIR" 2>/dev/null || chown -R nginx:nginx "$WEB_DIR" 2>/dev/null || true
    chmod 644 "$WEB_DIR/index.php"
    ok "Web interface created"

    # Install quota monitor & timer if a monitor script is available next to this installer
    install_quota_monitor || true

     # Configure nginx
    local php_sock=$(detect_php_fpm_sock)

    # Determine fastcgi_pass (socket vs TCP)
    if [[ "$php_sock" == *":"* ]]; then
        FASTCGI_PASS="$php_sock"
    else
        FASTCGI_PASS="unix:$php_sock"
    fi

    # Create nginx configuration
    cat > /etc/nginx/sites-available/wireguard <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name _;
    
    root $WEB_DIR;
    index index.php index.html index.htm;
    
    access_log /var/log/nginx/wireguard_access.log;
    error_log /var/log/nginx/wireguard_error.log;
    
    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }
    
    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass $FASTCGI_PASS;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
        fastcgi_connect_timeout 300;
    }
    
    location ~ /\.ht {
        deny all;
    }
}
NGINX

    # Enable site
    if [[ -d /etc/nginx/sites-enabled ]]; then
        ln -sf /etc/nginx/sites-available/wireguard /etc/nginx/sites-enabled/ 2>/dev/null || true
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi

    # Start services
    systemctl enable php8.1-fpm 2>/dev/null || systemctl enable php8.0-fpm 2>/dev/null || 
    systemctl enable php7.4-fpm 2>/dev/null || systemctl enable php-fpm 2>/dev/null || true
    
    systemctl start php8.1-fpm 2>/dev/null || systemctl start php8.0-fpm 2>/dev/null || 
    systemctl start php7.4-fpm 2>/dev/null || systemctl start php-fpm 2>/dev/null || true

    if nginx -t >/dev/null 2>&1; then
        systemctl enable nginx
        systemctl restart nginx
        ok "Nginx configured and started"
    else
        err "Nginx configuration test failed"
        nginx -t
        return 1
    fi

    # Open port 80 in firewall
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    sync_web_db
    ok "Web panel installed successfully"
    echo -e "${GREEN}Web interface URL:${NC} http://$(public_ip)/"
}
verify_installation() {
    log "Verifying installation..."
    
    local errors=0
    local web_user="www-data"
    
    # تشخیص کاربر وب‌سرور
    if getent passwd nginx >/dev/null; then
        web_user="nginx"
    fi
    
    # بررسی اسکریپت‌های ضروری
    for script in wg-admin-is-admin wg-client-info wg-generate-qr; do
        if [[ ! -f "/usr/local/bin/$script" ]]; then
            err "Missing script: /usr/local/bin/$script"
            ((errors++))
        fi
    done
    
    # بررسی دسترسی‌های سودو
    if [[ ! -f "/etc/sudoers.d/wg-web" ]]; then
        err "Missing sudoers configuration"
        ((errors++))
    fi
    
    # ساخت و بررسی دایرکتوری‌های وب
    for dir in "$WEB_DIR" "$WEB_DIR/db" "$WEB_DIR/backups" "$WEB_DIR/clients"; do
        if [[ ! -d "$dir" ]]; then
            log "Creating directory: $dir"
            mkdir -p "$dir"
        fi
        # تنظیم مالکیت و دسترسی‌ها
        chown "$web_user:$web_user" "$dir"
        if [[ "$dir" == *"/db" ]] || [[ "$dir" == *"/backups" ]]; then
            chmod 750 "$dir"
        else
            chmod 755 "$dir"
        fi
    done

    # بررسی دسترسی‌های وب
    if ! su -s /bin/sh "$web_user" -c "test -w '$WEB_DIR/db'"; then
        err "Web user ($web_user) cannot write to $WEB_DIR/db"
        ((errors++))
    fi

    # کپی فایل‌های پایه اگر وجود ندارند
    for db_file in "clients.db" "quota.db" "admin.db" "endpoint.db" "dns.db"; do
        if [[ ! -f "$WEB_DIR/db/$db_file" ]] && [[ -f "/etc/wireguard/$db_file" ]]; then
            cp "/etc/wireguard/$db_file" "$WEB_DIR/db/$db_file"
            chown "$web_user:$web_user" "$WEB_DIR/db/$db_file"
            chmod 640 "$WEB_DIR/db/$db_file"
        fi
    done
    
    if [[ $errors -eq 0 ]]; then
        ok "Backend installation verified successfully"
    else
        err "Backend installation has $errors errors"
        return 1
    fi
}

# --------------------------- Quota Monitor Installer ------------------------
install_quota_monitor() {
    log "Installing wg-quota-monitor (if provided)"

    local target_bin="/usr/local/bin/wg-quota-monitor.sh"
    local script_dir
    script_dir=$(dirname "$0")

    # Prefer a monitor script shipped next to installer
    if [[ -f "$target_bin" ]]; then
        ok "Quota monitor already installed: $target_bin"
    elif [[ -f "$script_dir/wg-quota-monitor.sh" ]]; then
        cp "$script_dir/wg-quota-monitor.sh" "$target_bin"
        chmod 750 "$target_bin"
        chown root:root "$target_bin" || true
        ok "Copied quota monitor to $target_bin"
    else
        warn "No wg-quota-monitor.sh found next to installer; skipping install of monitor"
        return 0
    fi

    # Create systemd service + timer
    cat > /etc/systemd/system/wg-quota-monitor.service <<'UNIT'
[Unit]
Description=WireGuard Quota Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-quota-monitor.sh
Nice=10
KillMode=process
TimeoutStartSec=60

[Install]
WantedBy=multi-user.target
UNIT

    cat > /etc/systemd/system/wg-quota-monitor.timer <<'TIMER'
[Unit]
Description=Run WireGuard Quota Monitor every minute

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
TIMER

    systemctl daemon-reload
    systemctl enable --now wg-quota-monitor.timer >/dev/null 2>&1 || systemctl start wg-quota-monitor.timer >/dev/null 2>&1 || true
    ok "wg-quota-monitor timer enabled"

    # ensure state dir exists
    mkdir -p /var/lib/wg-quota
    chown root:root /var/lib/wg-quota || true
    chmod 750 /var/lib/wg-quota || true
}
# --------------------------- Main Installation --------------------------------
main_install() {
    log "Starting WireGuard installation process..."
    need_root
    detect_os
    update_system
    disable_apparmor
    configure_selinux
    install_wireguard
    setup_server
    configure_firewall
    init_databases
    enable_start
    install_web
    
    echo
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${GREEN}Installation completed successfully!${NC}"
    echo -e "${GREEN}==================================================${NC}"
    echo -e "${CYAN}Server Public Key:${NC} $(cat "$SERVER_PUB")"
    echo -e "${CYAN}Server Endpoint:${NC} $(get_server_endpoint)"
    echo -e "${CYAN}Web Panel:${NC} http://$(public_ip)/"
    echo -e "${CYAN}Default Interface:${NC} $(detect_default_iface)"
    echo -e "${CYAN}WireGuard Config:${NC} $WG_CONF"
    echo -e "${CYAN}Clients Directory:${NC} $CLIENTS_DIR"
    echo
    echo -e "${YELLOW}Next steps:${NC}"
    echo -e "1. Add clients: $0 add-client NAME [GB] [DAYS]"
    echo -e "2. List clients: $0 list-clients"
    echo -e "3. Access web panel: http://$(public_ip)/"
    echo
}

# --------------------------- Usage -------------------------------------------
usage() {
    cat <<EOF
WireGuard Manager v6.3.1

Usage: $0 [COMMAND] [ARGS]

Commands:
  install                     - Complete installation
  add-client NAME [GB] [DAYS] - Add client with quota and expiry
  remove-client NAME          - Remove client
  edit-client NAME [GB] [DAYS]- Edit client quota and expiry
  list-clients                - Show all clients with usage
  add-admin PRIVATE_KEY       - Add admin by private key
  remove-admin PRIVATE_KEY    - Remove admin by private key
  update-endpoint DOMAIN PORT - Update server endpoint and DNS
  web-install                 - Install web panel only
  service-restart             - Restart WireGuard service
  status                      - Show service status

Examples:
  $0 install
  $0 add-client alice 10 30
  $0 add-client bob 0 0     # Unlimited
  $0 update-endpoint vpn.example.com 51820

Web Panel:
  Access: http://$(public_ip)/
  Note: Add your private key to /etc/wireguard/admin.db to access admin features

EOF
}

# --------------------------- Main --------------------------------------------
case "${1:-}" in
    install)
        main_install
        ;;
    add-client)
        add_client "${2:-}" "${3:-0}" "${4:-30}"
        ;;
    remove-client)
        remove_client "${2:-}"
        ;;
    edit-client)
        edit_client "${2:-}" "${3:-}" "${4:-}"
        ;;
    list-clients)
        list_clients
        ;;
    add-admin)
        add_admin "${2:-}"
        ;;
    remove-admin)
        remove_admin "${2:-}"
        ;;
    update-endpoint)
        update_all_client_configs "${2:-}" "${3:-}" "${4:-}"
        ;;
    web-install)
        install_web
        ;;
    service-restart)
        systemctl restart "wg-quick@$WG_IFACE"
        ok "Service restarted"
        ;;
    status)
        systemctl status "wg-quick@$WG_IFACE" --no-pager
        ;;
    *)
        usage
        ;;
esac
