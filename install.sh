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
    log "Saved endpoint and DNS to database files"

    local updated_count=0
    log "Starting client config updates..."
    for client_conf in "$CLIENTS_DIR"/*.conf; do
        [[ -f "$client_conf" ]] || continue
        log "Processing: $client_conf"

        local client_name=$(basename "$client_conf" .conf)
        log "  Client name: $client_name"
        
        # Extract values using sed
        local private_key=$(sed -n 's/^PrivateKey = //p' "$client_conf")
        log "  Private key extracted: ${private_key:0:20}..."
        local address=$(sed -n 's/^Address = //p' "$client_conf")
        log "  Address extracted: $address"
        local server_pubkey=$(sed -n 's/^PublicKey = //p' "$client_conf")
        log "  Server pubkey extracted: ${server_pubkey:0:20}..."

        if [[ -n "$private_key" && -n "$address" && -n "$server_pubkey" ]]; then
            log "  All fields valid, updating config..."
            # Update config file (temporarily disable errexit for this block)
            set +e
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
            set -e
            log "  Config file written"
            
            # Regenerate QR code with new config
            local qr_file="$CLIENTS_DIR/${client_name}.png"
            if command -v qrencode >/dev/null 2>&1; then
                qrencode -t PNG -o "$qr_file" -r "$client_conf" 2>/dev/null || true
                log "  QR code regenerated"
            fi
            
            updated_count=$((updated_count + 1))
            ok "  ✓ Updated config for: $client_name"
        else
            warn "  ✗ Skipping $client_name - missing fields"
        fi
    done

    # Update server config port
    if [[ -f "$WG_CONF" ]]; then
        if grep -qE '^ListenPort\s*=' "$WG_CONF"; then
            sed -i "s/^ListenPort\s*=.*/ListenPort = $new_port/" "$WG_CONF"
        else
            sed -i "/^\[Interface\]/a ListenPort = $new_port" "$WG_CONF"
        fi
    fi

    # Restart WireGuard service
    if systemctl is-active --quiet "wg-quick@$WG_IFACE" 2>/dev/null; then
        systemctl restart "wg-quick@$WG_IFACE" 2>/dev/null || true
        log "WireGuard service restarted"
    fi
    
    ok "Updated $updated_count client configs with new endpoint: $new_endpoint and DNS: $new_dns"
    
    # Sync all changes to web directory
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

    log "Syncing /etc/wireguard to /var/www/wireguard..."

    # ساخت دایرکتوری‌های مورد نیاز
    for dir in "$WEB_DIR" "$WEB_DIR/db" "$WEB_DIR/backups" "$WEB_DIR/clients"; do
        if [[ ! -d "$dir" ]]; then
            mkdir -p "$dir"
        fi
        chown "$web_user:$web_user" "$dir"
        if [[ "$dir" == *"/db" ]] || [[ "$dir" == *"/backups" ]]; then
            chmod 750 "$dir"
        else
            chmod 755 "$dir"
        fi
    done

    # کپی فایل‌های دیتابیس از /etc به /var/www/wireguard/db
    for db_file in "$CLIENT_DB" "$QUOTA_DB" "$ADMIN_DB" "$SERVER_ENDPOINT_DB" "$SERVER_DNS_DB"; do
        if [[ -f "$db_file" ]]; then
            cp -f "$db_file" "$WEB_DIR/db/$(basename "$db_file")"
            chown "$web_user:$web_user" "$WEB_DIR/db/$(basename "$db_file")"
            chmod 640 "$WEB_DIR/db/$(basename "$db_file")"
        fi
    done

    # پاک کردن فایل‌های قدیمی در clients و کپی جدید از /etc
    if [[ -d "$CLIENTS_DIR" ]]; then
        # حذف همه فایل‌های قدیمی در مقصد
        rm -rf "$WEB_DIR/clients"/* 2>/dev/null || true
        
        # کپی تمام فایل‌ها از /etc/wireguard/clients به /var/www/wireguard/clients
        cp -rf "$CLIENTS_DIR"/* "$WEB_DIR/clients/" 2>/dev/null || true
        
        # تنظیم مالکیت و مجوزها
        chown -R "$web_user:$web_user" "$WEB_DIR/clients"
        find "$WEB_DIR/clients" -type f -name "*_private.key" -exec chmod 600 {} \; 2>/dev/null || true
        find "$WEB_DIR/clients" -type f -name "*_public.key" -exec chmod 644 {} \; 2>/dev/null || true
        find "$WEB_DIR/clients" -type f -name "*.conf" -exec chmod 644 {} \; 2>/dev/null || true
        find "$WEB_DIR/clients" -type f -name "*.png" -exec chmod 644 {} \; 2>/dev/null || true
        chmod 750 "$WEB_DIR/clients"
    fi

    ok "Synced all files from /etc/wireguard to /var/www/wireguard"
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

# Ensure /etc databases exist (copy from web if needed)
ensure_etc_databases() {
    if [[ ! -f "$CLIENT_DB" ]] && [[ -f "/var/www/wireguard/db/clients.db" ]]; then
        log "Restoring /etc databases from /var/www..."
        mkdir -p "$WG_DIR/clients"
        cp -f /var/www/wireguard/db/*.db "$WG_DIR/" 2>/dev/null || true
        cp -rf /var/www/wireguard/clients/* "$WG_DIR/clients/" 2>/dev/null || true
        chmod 600 "$WG_DIR"/*.db
        chown root:root "$WG_DIR"/*.db
        ok "Databases restored to /etc/wireguard"
    fi
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
    ensure_etc_databases
    local name="$1" gb="${2:-0}" days="${3:-30}"
    
    if [[ -z "$name" ]]; then
        err "Usage: add-client NAME [GB] [DAYS]"
        return 1
    fi
    
    if [[ ! -f "$SERVER_PUB" ]]; then
        err "Server not set up. Run 'install' first."
        return 1
    fi

    # Check if client already exists
    if [[ -f "$CLIENTS_DIR/${name}_public.key" ]] || [[ -f "$CLIENTS_DIR/${name}.conf" ]]; then
        err "Client '$name' already exists. Please use a different name or remove the existing client first."
        return 1
    fi
    
    # Check if client name exists in database
    if [[ -f "$CLIENT_DB" ]] && grep -q "^$name|" "$CLIENT_DB" 2>/dev/null; then
        err "Client '$name' already exists in database. Please use a different name."
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

    # Save to database (/etc is primary)
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
    ensure_etc_databases
    local name="$1"
    local LOG="/tmp/wireguard_delete.log"
    
    echo "========================================" >> "$LOG"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting deletion for: $name" >> "$LOG"
    
    if [[ -z "$name" ]]; then
        echo "ERROR: No client name provided" >> "$LOG"
        err "Usage: remove-client NAME"
        return 1
    fi
    
    echo "Step 1: Checking if client exists..." >> "$LOG"
    local pub_file="$CLIENTS_DIR/${name}_public.key"
    if [[ ! -f "$pub_file" ]]; then
        echo "ERROR: Client public key not found at $pub_file" >> "$LOG"
        err "Client $name not found"
        return 1
    fi
    echo "  ✓ Client public key found" >> "$LOG"
    
    local pubkey=$(cat "$pub_file")
    echo "  Public key: ${pubkey:0:20}..." >> "$LOG"
    
    # Step 2: Get client IP from database
    echo "Step 2: Reading client IP from $CLIENT_DB..." >> "$LOG"
    local ip=""
    if [[ -f "$CLIENT_DB" ]]; then
        ip=$(grep -m1 "^$name|" "$CLIENT_DB" 2>/dev/null | cut -d'|' -f4 || true)
        echo "  Found IP: $ip" >> "$LOG"
    else
        echo "  WARNING: clients.db not found!" >> "$LOG"
    fi
    
    # Step 3: Remove iptables rule
    echo "Step 3: Removing iptables rule for $ip..." >> "$LOG"
    local CHAIN_NAME="WG-CLIENTS-COUNTS"
    if [[ -n "$ip" ]] && iptables -C "$CHAIN_NAME" -s "$ip" -m comment --comment "$name" -j RETURN >/dev/null 2>&1; then
        if iptables -D "$CHAIN_NAME" -s "$ip" -m comment --comment "$name" -j RETURN 2>&1 | tee -a "$LOG"; then
            echo "  ✓ iptables rule removed" >> "$LOG"
        else
            echo "  ✗ Failed to remove iptables rule" >> "$LOG"
        fi
    else
        echo "  ⊗ No iptables rule found (already removed or not set)" >> "$LOG"
    fi
    
    # Step 4: Remove quota tracking file
    echo "Step 4: Removing quota tracking file..." >> "$LOG"
    local safe_name=$(echo "$name" | sed 's/[^A-Za-z0-9._-]/_/g')
    if rm -f "/var/lib/wg-quota/${safe_name}.last" 2>>"$LOG"; then
        echo "  ✓ Quota file removed" >> "$LOG"
    fi
    
    # Step 5: Remove from WireGuard config
    echo "Step 5: Removing from $WG_CONF..." >> "$LOG"
    if [[ -f "$WG_CONF" ]]; then
        local before_lines=$(wc -l < "$WG_CONF")
        # Escape special characters in public key for sed
        local escaped_pubkey=$(echo "$pubkey" | sed 's/[\/&]/\\&/g')
        sed -i "/PublicKey = $escaped_pubkey/,+2d" "$WG_CONF"
        local after_lines=$(wc -l < "$WG_CONF")
        echo "  Config lines before: $before_lines, after: $after_lines" >> "$LOG"
        echo "  ✓ Removed from WireGuard config" >> "$LOG"
    fi
    
    # Step 6: Reload WireGuard
    echo "Step 6: Reloading WireGuard service..." >> "$LOG"
    if systemctl is-active --quiet "wg-quick@$WG_IFACE" 2>/dev/null; then
        if wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") 2>&1 | tee -a "$LOG"; then
            echo "  ✓ WireGuard reloaded" >> "$LOG"
        fi
    else
        echo "  ⊗ WireGuard service not running" >> "$LOG"
    fi
    
    # Step 7: Remove from clients.db
    echo "Step 7: Removing from $CLIENT_DB..." >> "$LOG"
    if [[ -f "$CLIENT_DB" ]]; then
        local before_count=$(grep -c "^" "$CLIENT_DB" 2>/dev/null || echo 0)
        grep -v "^$name|" "$CLIENT_DB" > "${CLIENT_DB}.tmp" 2>/dev/null
        mv "${CLIENT_DB}.tmp" "$CLIENT_DB"
        local after_count=$(grep -c "^" "$CLIENT_DB" 2>/dev/null || echo 0)
        echo "  Database entries before: $before_count, after: $after_count" >> "$LOG"
        echo "  ✓ Removed from clients.db" >> "$LOG"
        
        # Verify removal
        if grep -q "^$name|" "$CLIENT_DB" 2>/dev/null; then
            echo "  ✗✗✗ ERROR: Client still in database after removal!" >> "$LOG"
        else
            echo "  ✓✓ VERIFIED: Client removed from database" >> "$LOG"
        fi
    fi

    # Step 8: Remove from quota.db
    echo "Step 8: Removing from $QUOTA_DB..." >> "$LOG"
    if [[ -f "$QUOTA_DB" ]]; then
        grep -v "^$name|" "$QUOTA_DB" > "${QUOTA_DB}.tmp" 2>/dev/null
        mv "${QUOTA_DB}.tmp" "$QUOTA_DB"
        echo "  ✓ Removed from quota.db" >> "$LOG"
    fi
    
    # Step 9: Remove client files
    echo "Step 9: Removing client files from $CLIENTS_DIR..." >> "$LOG"
    for file in "${name}_public.key" "${name}_private.key" "${name}.conf" "${name}.png"; do
        if [[ -f "$CLIENTS_DIR/$file" ]]; then
            rm -f "$CLIENTS_DIR/$file" && echo "  ✓ Removed $file" >> "$LOG"
        fi
    done
    
    echo "Step 10: Syncing to web directory..." >> "$LOG"
    sync_web_db 2>&1 | tee -a "$LOG"
    echo "  ✓ Sync completed" >> "$LOG"
    
    # Final verification
    echo "========== FINAL VERIFICATION ==========" >> "$LOG"
    echo "Checking /etc/wireguard/clients.db:" >> "$LOG"
    if grep -q "^$name|" /etc/wireguard/clients.db 2>/dev/null; then
        echo "  ✗✗✗ FAILED: Still in /etc/wireguard/clients.db" >> "$LOG"
    else
        echo "  ✓✓ OK: Not in /etc/wireguard/clients.db" >> "$LOG"
    fi
    
    echo "Checking /var/www/wireguard/db/clients.db:" >> "$LOG"
    if grep -q "^$name|" /var/www/wireguard/db/clients.db 2>/dev/null; then
        echo "  ✗✗✗ FAILED: Still in /var/www/wireguard/db/clients.db" >> "$LOG"
    else
        echo "  ✓✓ OK: Not in /var/www/wireguard/db/clients.db" >> "$LOG"
    fi
    
    echo "$(date '+%Y-%m-%d %H:%M:%S') - Deletion completed for: $name" >> "$LOG"
    echo "========================================" >> "$LOG"
    
    ok "Client $name removed successfully - Check /tmp/wireguard_delete.log for details"
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
set -euo pipefail
DOMAIN="${1:-}"
PORT="${2:-1010}"
DNS="${3:-1.1.1.1,8.8.8.8}"

if [[ -z "$DOMAIN" ]]; then
    echo "Usage: $0 DOMAIN [PORT] [DNS]"
    exit 1
fi

/usr/local/bin/wireguard-manager update-endpoint "$DOMAIN" "$PORT" "$DNS"
EOF
chmod 755 /usr/local/bin/wg-update-endpoint

create_admin_scripts() {
    log "Creating admin scripts..."
    
    # اسکریپت بررسی مدیر
    cat > /usr/local/bin/wg-admin-is-admin <<'EOF'
#!/usr/bin/env bash

PRIVATE_KEY="${1:-}"
# /etc is primary source
ADMIN_DB="/etc/wireguard/admin.db"
if [[ ! -f "$ADMIN_DB" ]]; then
    ADMIN_DB="/var/www/wireguard/db/admin.db"
fi

# Debug log
echo "Checking admin status for key: ${PRIVATE_KEY:0:20}..." >&2
echo "Using admin DB: $ADMIN_DB" >&2

if [[ -z "$PRIVATE_KEY" ]]; then
    echo "false"
    exit 0
fi

if [[ ! -f "$ADMIN_DB" ]]; then
    echo "Admin DB not found: $ADMIN_DB" >&2
    echo "false"
    exit 0
fi

if grep -qFx "$PRIVATE_KEY" "$ADMIN_DB" 2>/dev/null; then
    echo "Admin key found!" >&2
    echo "true"
else
    echo "Admin key not found" >&2
    echo "false"
fi
EOF

    # اسکریپت اطلاعات کلاینت
    cat > /usr/local/bin/wg-client-info <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

PRIVATE_KEY="${1:-}"
# /etc is primary source
CLIENT_DB="/etc/wireguard/clients.db"
QUOTA_DB="/etc/wireguard/quota.db"
if [[ ! -f "$CLIENT_DB" ]]; then
    CLIENT_DB="/var/www/wireguard/db/clients.db"
fi
if [[ ! -f "$QUOTA_DB" ]]; then
    QUOTA_DB="/var/www/wireguard/db/quota.db"
fi
SERVER_PUB="/etc/wireguard/server_public.key"
SERVER_ENDPOINT_DB="/etc/wireguard/endpoint.db"
SERVER_DNS_DB="/etc/wireguard/dns.db"
if [[ ! -f "$SERVER_ENDPOINT_DB" ]]; then
    SERVER_ENDPOINT_DB="/var/www/wireguard/db/endpoint.db"
fi
if [[ ! -f "$SERVER_DNS_DB" ]]; then
    SERVER_DNS_DB="/var/www/wireguard/db/dns.db"
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

# Check if wireguard-manager exists
if [[ ! -f "$WG_SCRIPT" ]]; then
    echo "Error: wireguard-manager not found at $WG_SCRIPT" >&2
    exit 1
fi

case "$ACTION" in
    "add-client")
        if [[ -z "$PARAM1" ]]; then
            echo "Error: Client name is required" >&2
            exit 1
        fi
        "$WG_SCRIPT" add-client "$PARAM1" "$PARAM2" "$PARAM3" 2>&1
        exit $?
        ;;
    "edit-client")
        if [[ -z "$PARAM1" ]]; then
            echo "Error: Client name is required" >&2
            exit 1
        fi
        "$WG_SCRIPT" edit-client "$PARAM1" "$PARAM2" "$PARAM3" 2>&1
        exit $?
        ;;
    "remove-client")
        if [[ -z "$PARAM1" ]]; then
            echo "Error: Client name is required" >&2
            exit 1
        fi
        "$WG_SCRIPT" remove-client "$PARAM1" 2>&1
        exit $?
        ;;
    "set-endpoint")
        if [[ -z "$PARAM1" ]]; then
            echo "Error: Domain/IP is required" >&2
            exit 1
        fi
        "$WG_SCRIPT" update-endpoint "$PARAM1" "$PARAM2" "$PARAM3" 2>&1
        exit $?
        ;;
    "backup")
        echo "Backup functionality would be implemented here"
        exit 0
        ;;
    "restore")
        echo "Restore functionality would be implemented here"
        exit 0
        ;;
    *)
        echo "Error: Invalid action: $ACTION" >&2
        echo "Valid actions: add-client, edit-client, remove-client, set-endpoint, backup, restore" >&2
        exit 1
        ;;
esac
EOF

    # اسکریپت‌های وب
        cat > /usr/local/bin/wg-add-client-web <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="${1:-}"; gb="${2:-}"; days="${3:-}"
/usr/local/bin/wireguard-manager add-client "$name" "$gb" "$days"
rc=$?
{
    echo "$(date +"%Y-%m-%d %H:%M:%S") | ADD  | name=$name | gb=${gb:-} | days=${days:-} | rc=$rc"
} >> /tmp/wireguard_add.log 2>/dev/null || true
exit $rc
EOF

        cat > /usr/local/bin/wg-edit-client-web <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
name="${1:-}"; new_gb="${2:-}"; new_days="${3:-}"
/usr/local/bin/wireguard-manager edit-client "$name" "$new_gb" "$new_days"
rc=$?
{
    echo "$(date +"%Y-%m-%d %H:%M:%S") | EDIT | name=$name | new_gb=${new_gb:-} | new_days=${new_days:-} | rc=$rc"
} >> /tmp/wireguard_edit.log 2>/dev/null || true
exit $rc
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
nginx ALL=(root) NOPASSWD: /usr/local/bin/wg-admin-is-admin
nginx ALL=(root) NOPASSWD: /usr/local/bin/wg-update-endpoint
nginx ALL=(root) NOPASSWD: /usr/local/bin/wg-client-info
nginx ALL=(root) NOPASSWD: /usr/local/bin/wg-add-client-web
nginx ALL=(root) NOPASSWD: /usr/local/bin/wg-edit-client-web
nginx ALL=(root) NOPASSWD: /usr/local/bin/wg-remove-client-web
nginx ALL=(root) NOPASSWD: /usr/local/bin/wg-generate-qr
nginx ALL=(root) NOPASSWD: /usr/local/bin/wg-admin
SUDO
    chmod 440 /etc/sudoers.d/wg-web
    ok "Admin scripts and sudo permissions configured"
}

install_web() {
    log "Installing and configuring web panel..."
    # Ensure OS detection when running web-install directly
    if [[ -z "${OS_ID:-}" ]]; then
        detect_os
    fi
    
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

    # Create advanced debug page with comprehensive logging
    cat > "$WEB_DIR/debug.php" <<'DEBUGPHP'
<?php
header('Content-Type: text/html; charset=utf-8');
// Access guard: require valid token from /var/www/wireguard/debug.key
$keyFile = '/var/www/wireguard/debug.key';
$token = $_GET['token'] ?? '';
$okToken = false;
if (file_exists($keyFile)) {
    $raw = @file_get_contents($keyFile);
    $obj = @json_decode($raw, true);
    if (is_array($obj)) {
        $savedToken = $obj['token'] ?? '';
        $expires = intval($obj['expires'] ?? 0);
        if (!empty($savedToken) && hash_equals($savedToken, (string)$token) && time() <= $expires) {
            $okToken = true;
        }
    }
}
if (!$okToken) { http_response_code(403); echo '403 Forbidden'; exit; }

function getStatus($condition) {
    return $condition ? "✅" : "❌";
}

function getServiceStatus($service) {
    $output = shell_exec("systemctl is-active $service 2>&1");
    $active = trim($output) === 'active';
    return $active ? "🟢 Active" : "🔴 Inactive";
}

function getFileStatus($file) {
    if (!file_exists($file)) return "❌ Not Found";
    $perms = substr(sprintf('%o', fileperms($file)), -4);
    $size = filesize($file);
    return "✅ Exists (perms: $perms, size: " . formatBytes($size) . ")";
}

function formatBytes($bytes) {
    if ($bytes < 1024) return $bytes . ' B';
    if ($bytes < 1048576) return round($bytes / 1024, 2) . ' KB';
    return round($bytes / 1048576, 2) . ' MB';
}

function getDiskUsage($path) {
    $free = disk_free_space($path);
    $total = disk_total_space($path);
    $used = $total - $free;
    $percent = round(($used / $total) * 100, 1);
    return [
        'used' => formatBytes($used),
        'total' => formatBytes($total),
        'percent' => $percent,
        'icon' => $percent > 90 ? '🔴' : ($percent > 70 ? '🟡' : '🟢')
    ];
}

// Efficiently read the last N lines of a file (falls back to PHP slice if tail is unavailable)
function tailFile($file, $lines = 100) {
    $lines = max(1, (int)$lines);
    if (!file_exists($file)) return '';
    $cmd = "tail -n $lines " . escapeshellarg($file) . " 2>&1";
    $out = @shell_exec($cmd);
    if (is_string($out) && $out !== '') {
        return $out;
    }
    $arr = @file($file);
    if ($arr === false) return '';
    return implode('', array_slice($arr, -$lines));
}
?>
<!DOCTYPE html>
<html dir="rtl" lang="fa">
<head>
    <meta charset="UTF-8">
    <title>🔍 WireGuard System Debug</title>
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <meta http-equiv="Content-Security-Policy" content="default-src 'self'; img-src 'self' data:; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self';">
 <style>
    :root {
        /* رنگ‌های اصلی */
        --primary: #667eea;
        --primary-dark: #5a6fd8;
        --primary-light: #8a9cf0;
        --secondary: #764ba2;
        --accent: #f093fb;
        --accent-secondary: #f5576c;
        
        /* رنگ‌های وضعیت */
        --success: #10b981;
        --success-light: #d1fae5;
        --warning: #f59e0b;
        --warning-light: #fef3c7;
        --danger: #ef4444;
        --danger-light: #fee2e2;
        
        /* رنگ‌های خنثی */
        --dark: #1f2937;
        --dark-light: #374151;
        --gray: #6b7280;
        --gray-light: #9ca3af;
        --light: #f8fafc;
        --white: #ffffff;
        
        /* سایه‌ها */
        --shadow-sm: 0 1px 2px 0 rgba(0, 0, 0, 0.05);
        --shadow-md: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
        --shadow-lg: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
        --shadow-xl: 0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04);
        
        /* انیمیشن‌ها */
        --transition-fast: 0.15s ease-in-out;
        --transition-normal: 0.3s ease-in-out;
        --transition-slow: 0.5s ease-in-out;
        
        /* border-radius */
        --radius-sm: 8px;
        --radius-md: 12px;
        --radius-lg: 16px;
        --radius-xl: 20px;
        
        /* تایپوگرافی */
        --font-size-xs: 0.75rem;
        --font-size-sm: 0.875rem;
        --font-size-base: 1rem;
        --font-size-lg: 1.125rem;
        --font-size-xl: 1.25rem;
        --font-size-2xl: 1.5rem;
        --font-size-3xl: 1.875rem;
        --font-size-4xl: 2.25rem;
        
        /* spacing */
        --space-1: 0.25rem;
        --space-2: 0.5rem;
        --space-3: 0.75rem;
        --space-4: 1rem;
        --space-5: 1.25rem;
        --space-6: 1.5rem;
        --space-8: 2rem;
        --space-10: 2.5rem;
        --space-12: 3rem;
    }

    * {
        margin: 0;
        padding: 0;
        box-sizing: border-box;
    }

    body {
        font-family: 'Vazir', Tahoma, sans-serif;
        background: linear-gradient(135deg, var(--primary) 0%, var(--secondary) 100%);
        background-attachment: fixed;
        padding: var(--space-6);
        color: var(--dark);
        line-height: 1.6;
        min-height: 100vh;
    }

    .container {
        max-width: 1400px;
        margin: 0 auto;
    }

    /* Header Styles */
    .header {
        background: var(--white);
        padding: var(--space-10) var(--space-8);
        border-radius: var(--radius-xl);
        box-shadow: var(--shadow-xl);
        margin-bottom: var(--space-8);
        text-align: center;
        position: relative;
        overflow: hidden;
        backdrop-filter: blur(10px);
        border: 1px solid rgba(255, 255, 255, 0.2);
    }

    .header::before {
        content: '';
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        height: 4px;
        background: linear-gradient(90deg, var(--primary), var(--secondary), var(--accent));
        background-size: 200% 100%;
        animation: gradientShift 3s ease infinite;
    }

    .header h1 {
        color: var(--primary);
        font-size: var(--font-size-4xl);
        margin-bottom: var(--space-4);
        font-weight: 700;
        display: flex;
        align-items: center;
        justify-content: center;
        gap: var(--space-4);
        text-shadow: 0 2px 4px rgba(0, 0, 0, 0.1);
    }

    .header-subtitle {
        color: var(--gray);
        font-size: var(--font-size-lg);
        margin-bottom: var(--space-6);
    }

    .header-actions {
        display: flex;
        gap: var(--space-4);
        justify-content: center;
        align-items: center;
        flex-wrap: wrap;
        margin-top: var(--space-6);
    }

    /* Card Styles */
    .card {
        background: var(--white);
        border-radius: var(--radius-lg);
        padding: var(--space-8);
        box-shadow: var(--shadow-lg);
        transition: all var(--transition-normal);
        height: 100%;
        display: flex;
        flex-direction: column;
        border: 1px solid rgba(255, 255, 255, 0.1);
        backdrop-filter: blur(10px);
        position: relative;
        overflow: hidden;
    }

    .card::before {
        content: '';
        position: absolute;
        top: 0;
        left: 0;
        right: 0;
        height: 3px;
        background: linear-gradient(90deg, var(--primary), var(--secondary));
        transform: scaleX(0);
        transform-origin: left;
        transition: transform var(--transition-normal);
    }

    .card:hover {
        transform: translateY(-8px);
        box-shadow: var(--shadow-xl);
    }

    .card:hover::before {
        transform: scaleX(1);
    }

    .card-header {
        display: flex;
        align-items: center;
        gap: var(--space-4);
        margin-bottom: var(--space-6);
        padding-bottom: var(--space-4);
        border-bottom: 2px solid var(--primary);
        position: relative;
    }

    .card-header::after {
        content: '';
        position: absolute;
        bottom: -2px;
        left: 0;
        width: 60px;
        height: 2px;
        background: var(--accent);
        transition: width var(--transition-normal);
    }

    .card:hover .card-header::after {
        width: 100px;
    }

    .card-header h2 {
        color: var(--primary);
        font-size: var(--font-size-2xl);
        margin: 0;
        font-weight: 600;
    }

    .card-header-icon {
        font-size: var(--font-size-2xl);
        color: var(--primary);
        display: flex;
        align-items: center;
        justify-content: center;
        width: 48px;
        height: 48px;
        background: linear-gradient(135deg, var(--primary-light), var(--primary));
        border-radius: var(--radius-md);
        color: white;
    }

    /* Grid Layout */
    .grid {
        display: grid;
        grid-template-columns: repeat(auto-fit, minmax(380px, 1fr));
        gap: var(--space-6);
        margin-bottom: var(--space-8);
    }

    .full-width {
        grid-column: 1 / -1;
    }

    /* Status Items */
    .status-list {
        display: flex;
        flex-direction: column;
        gap: var(--space-3);
    }

    .status-item {
        display: flex;
        justify-content: space-between;
        align-items: center;
        padding: var(--space-4) var(--space-5);
        border-radius: var(--radius-md);
        border-right: 4px solid var(--primary);
        background: var(--light);
        transition: all var(--transition-fast);
        position: relative;
        overflow: hidden;
    }

    .status-item::before {
        content: '';
        position: absolute;
        top: 0;
        left: -100%;
        width: 100%;
        height: 100%;
        background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.4), transparent);
        transition: left var(--transition-slow);
    }

    .status-item:hover::before {
        left: 100%;
    }

    .status-item:hover {
        background: #f1f5f9;
        transform: translateX(4px);
    }

    .status-item.success {
        border-right-color: var(--success);
        background: var(--success-light);
    }

    .status-item.warning {
        border-right-color: var(--warning);
        background: var(--warning-light);
    }

    .status-item.error {
        border-right-color: var(--danger);
        background: var(--danger-light);
    }

    .status-label {
        font-weight: 600;
        color: var(--dark);
        display: flex;
        align-items: center;
        gap: var(--space-3);
        font-size: var(--font-size-sm);
    }

    .status-value {
        font-family: 'Courier New', monospace, 'Vazir';
        color: var(--primary);
        font-weight: 700;
        font-size: var(--font-size-sm);
        direction: ltr;
    }

    /* Progress Bar */
    .progress-container {
        margin-top: var(--space-4);
    }

    .progress-info {
        display: flex;
        justify-content: space-between;
        margin-bottom: var(--space-2);
        font-size: var(--font-size-sm);
        color: var(--gray);
    }

    .progress-bar {
        background: #e2e8f0;
        border-radius: var(--radius-lg);
        height: 28px;
        overflow: hidden;
        position: relative;
        box-shadow: inset 0 1px 3px rgba(0, 0, 0, 0.1);
    }

    .progress-fill {
        height: 100%;
        background: linear-gradient(90deg, var(--success), #059669);
        display: flex;
        align-items: center;
        justify-content: center;
        color: white;
        font-weight: 700;
        font-size: var(--font-size-sm);
        transition: width 0.8s cubic-bezier(0.34, 1.56, 0.64, 1);
        position: relative;
        overflow: hidden;
    }

    .progress-fill::after {
        content: '';
        position: absolute;
        top: 0;
        left: -100%;
        width: 100%;
        height: 100%;
        background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.3), transparent);
        animation: shimmer 2s infinite;
    }

    .progress-fill.warning {
        background: linear-gradient(90deg, var(--warning), #d97706);
    }

    .progress-fill.danger {
        background: linear-gradient(90deg, var(--danger), #dc2626);
    }

    /* Log Box */
    .log-box {
        background: #1e1e1e;
        color: #4ade80;
        padding: var(--space-6);
        border-radius: var(--radius-md);
        font-family: 'Fira Code', 'Courier New', monospace;
        font-size: var(--font-size-sm);
        max-height: 500px;
        overflow-y: auto;
        white-space: pre-wrap;
        word-wrap: break-word;
        direction: ltr;
        text-align: left;
        flex-grow: 1;
        border: 1px solid #374151;
        box-shadow: inset 0 2px 10px rgba(0, 0, 0, 0.3);
        line-height: 1.5;
    }

    /* Accordion (details/summary) styling */
    details.card {
        padding: 0;
        overflow: hidden;
    }
    details.card > summary {
        display: flex;
        align-items: center;
        justify-content: space-between;
        padding: var(--space-5) var(--space-6);
        font-weight: 700;
        color: var(--primary);
        background: var(--white);
        cursor: pointer;
        list-style: none;
        outline: none;
        border-bottom: 1px solid #e5e7eb;
        transition: background var(--transition-normal), color var(--transition-normal);
        position: relative;
    }
    details.card > summary::-webkit-details-marker { display: none; }
    details.card > summary::after {
        content: '▸';
        color: var(--primary);
        font-size: var(--font-size-lg);
        transform: translateX(4px) rotate(0deg);
        transition: transform var(--transition-normal);
    }
    details.card[open] > summary {
        background: #f8fafc;
        color: var(--dark);
    }
    details.card[open] > summary::after {
        transform: translateX(4px) rotate(90deg);
    }
    details.card .log-box {
        border-radius: 0 0 var(--radius-lg) var(--radius-lg);
        margin: 0;
    }
    .timestamp {
        color: #e5e7eb;
        text-align: center;
        margin-top: var(--space-6);
        font-size: var(--font-size-sm);
    }

    .log-box::-webkit-scrollbar {
        width: 12px;
    }

    .log-box::-webkit-scrollbar-track {
        background: #2d3748;
        border-radius: 0 var(--radius-md) var(--radius-md) 0;
    }

    .log-box::-webkit-scrollbar-thumb {
        background: var(--primary);
        border-radius: var(--radius-md);
        border: 2px solid #2d3748;
    }

    .log-box::-webkit-scrollbar-thumb:hover {
        background: var(--primary-dark);
    }

    /* Button Styles */
    .btn {
        display: inline-flex;
        align-items: center;
        gap: var(--space-3);
        padding: var(--space-4) var(--space-6);
        border-radius: var(--radius-md);
        font-weight: 600;
        cursor: pointer;
        transition: all var(--transition-normal);
        border: none;
        text-decoration: none;
        font-size: var(--font-size-base);
        position: relative;
        overflow: hidden;
    }

    .btn::before {
        content: '';
        position: absolute;
        top: 0;
        left: -100%;
        width: 100%;
        height: 100%;
        background: linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.2), transparent);
        transition: left var(--transition-slow);
    }

    .btn:hover::before {
        left: 100%;
    }

    .btn-primary {
        background: linear-gradient(135deg, var(--primary), var(--secondary));
        color: var(--white);
        box-shadow: var(--shadow-md);
    }

    .btn-primary:hover {
        transform: translateY(-2px);
        box-shadow: var(--shadow-lg);
        background: linear-gradient(135deg, var(--primary-dark), var(--secondary));
    }

    .btn-outline {
        background: transparent;
        color: var(--primary);
        border: 2px solid var(--primary);
    }

    .btn-outline:hover {
        background: var(--primary);
        color: var(--white);
        transform: translateY(-2px);
        box-shadow: var(--shadow-md);
    }

    /* Toggle Switch */
    .toggle-container {
        display: flex;
        align-items: center;
        gap: var(--space-3);
        background: var(--light);
        padding: var(--space-4) var(--space-5);
        border-radius: var(--radius-md);
        box-shadow: var(--shadow-sm);
        transition: all var(--transition-normal);
        border: 1px solid #e2e8f0;
    }

    .toggle-container:hover {
        box-shadow: var(--shadow-md);
        transform: translateY(-1px);
    }

    .toggle-switch {
        position: relative;
        display: inline-block;
        width: 52px;
        height: 28px;
    }

    .toggle-switch input {
        opacity: 0;
        width: 0;
        height: 0;
    }

    .toggle-slider {
        position: absolute;
        cursor: pointer;
        top: 0;
        left: 0;
        right: 0;
        bottom: 0;
        background-color: var(--gray-light);
        transition: var(--transition-normal);
        border-radius: 34px;
    }

    .toggle-slider:before {
        position: absolute;
        content: "";
        height: 20px;
        width: 20px;
        left: 4px;
        bottom: 4px;
        background-color: white;
        transition: var(--transition-normal);
        border-radius: 50%;
        box-shadow: var(--shadow-sm);
    }

    input:checked + .toggle-slider {
        background-color: var(--primary);
    }

    input:checked + .toggle-slider:before {
        transform: translateX(24px);
    }

    /* Footer */
    .footer {
        text-align: center;
        color: var(--white);
        margin: var(--space-10) 0 var(--space-6);
        font-size: var(--font-size-lg);
        display: flex;
        justify-content: center;
        align-items: center;
        gap: var(--space-3);
        text-shadow: 0 1px 2px rgba(0, 0, 0, 0.1);
    }

    /* Health Indicator */
    .health-indicator {
        display: flex;
        align-items: center;
        gap: var(--space-4);
        padding: var(--space-4) var(--space-5);
        border-radius: var(--radius-md);
        background: var(--white);
        box-shadow: var(--shadow-md);
        margin-bottom: var(--space-6);
        border-left: 4px solid var(--success);
        transition: all var(--transition-normal);
    }

    .health-indicator.warning {
        border-left-color: var(--warning);
    }

    .health-indicator.critical {
        border-left-color: var(--danger);
    }

    .health-indicator:hover {
        transform: translateX(4px);
        box-shadow: var(--shadow-lg);
    }

    .health-dot {
        width: 12px;
        height: 12px;
        border-radius: 50%;
        animation: pulse 2s infinite;
    }

    .health-good {
        background: var(--success);
    }

    .health-warning {
        background: var(--warning);
    }

    .health-critical {
        background: var(--danger);
    }

    /* Animations */
    @keyframes pulse {
        0% {
            transform: scale(0.95);
            box-shadow: 0 0 0 0 rgba(16, 185, 129, 0.7);
        }
        70% {
            transform: scale(1);
            box-shadow: 0 0 0 10px rgba(16, 185, 129, 0);
        }
        100% {
            transform: scale(0.95);
            box-shadow: 0 0 0 0 rgba(16, 185, 129, 0);
        }
    }

    @keyframes gradientShift {
        0% {
            background-position: 0% 50%;
        }
        50% {
            background-position: 100% 50%;
        }
        100% {
            background-position: 0% 50%;
        }
    }

    @keyframes shimmer {
        0% {
            transform: translateX(-100%);
        }
        100% {
            transform: translateX(400%);
        }
    }

    /* Responsive Design */
    @media (max-width: 768px) {
        body {
            padding: var(--space-4);
        }
        
        .grid {
            grid-template-columns: 1fr;
            gap: var(--space-4);
        }
        
        .header {
            padding: var(--space-6) var(--space-4);
        }
        
        .header h1 {
            font-size: var(--font-size-3xl);
            flex-direction: column;
            gap: var(--space-3);
        }
        
        .header-actions {
            flex-direction: column;
            align-items: stretch;
        }
        
        .card {
            padding: var(--space-6);
        }
        
        .card-header {
            flex-direction: column;
            text-align: center;
            gap: var(--space-3);
        }
        
        .card-header::after {
            left: 50%;
            transform: translateX(-50%);
        }
        
        .status-item {
            flex-direction: column;
            align-items: flex-start;
            gap: var(--space-2);
        }
        
        .btn {
            width: 100%;
            justify-content: center;
        }
    }

    @media (max-width: 480px) {
        :root {
            --font-size-4xl: 1.75rem;
            --font-size-3xl: 1.5rem;
            --font-size-2xl: 1.25rem;
        }
        
        .header h1 {
            font-size: var(--font-size-2xl);
        }
        
        .card {
            padding: var(--space-4);
        }
    }

    /* Utility Classes */
    .text-center {
        text-align: center;
    }
    
    .text-right {
        text-align: right;
    }
    
    .mb-4 {
        margin-bottom: var(--space-4);
    }
    
    .mt-4 {
        margin-top: var(--space-4);
    }
    
    .p-4 {
        padding: var(--space-4);
    }
    
    .hidden {
        display: none;
    }
    
    .fade-in {
        animation: fadeIn 0.5s ease-in-out;
    }
    
    @keyframes fadeIn {
        from {
            opacity: 0;
            transform: translateY(20px);
        }
        to {
            opacity: 1;
            transform: translateY(0);
        }
    }
</style>
</head>
<body>
<div class="container">
    <div class="header">
        <h1>🔍 WireGuard System Diagnostics</h1>
        <p style="color: #666; margin-top: 10px;">آخرین بروزرسانی: <?php echo date('Y-m-d H:i:s'); ?></p>
        <div style="display:flex;gap:10px;justify-content:center;align-items:center;flex-wrap:wrap;">
        </div>
    </div>

    <div class="grid">
        <!-- System Status -->
        <div class="card">
            <h2>💻 وضعیت سیستم</h2>
            <?php
            $load = sys_getloadavg();
            $uptime = shell_exec("uptime -p");
            $disk = getDiskUsage('/');
            ?>
            <div class="status-item <?php echo $load[0] > 5 ? 'warning' : 'success'; ?>">
                <span class="label">📊 بار سیستم (1m)</span>
                <span class="value"><?php echo round($load[0], 2); ?></span>
            </div>
            <div class="status-item success">
                <span class="label">⏱️ مدت زمان فعالیت</span>
                <span class="value"><?php echo trim($uptime); ?></span>
            </div>
            <div class="status-item <?php echo $disk['percent'] > 80 ? 'warning' : 'success'; ?>">
                <span class="label"><?php echo $disk['icon']; ?> فضای دیسک</span>
                <span class="value"><?php echo $disk['used']; ?> / <?php echo $disk['total']; ?></span>
            </div>
            <div class="progress-bar">
                <div class="progress-fill <?php echo $disk['percent'] > 80 ? 'danger' : ($disk['percent'] > 60 ? 'warning' : ''); ?>" 
                     style="width: <?php echo $disk['percent']; ?>%">
                    <?php echo $disk['percent']; ?>%
                </div>
            </div>
        </div>

        <!-- Services Status -->
        <div class="card">
            <h2>⚙️ وضعیت سرویس‌ها</h2>
            <?php
            $services = [
                'wg-quick@wg0' => 'WireGuard',
                'nginx' => 'Nginx',
                'php8.2-fpm' => 'PHP-FPM (8.2)',
                'php8.1-fpm' => 'PHP-FPM (8.1)',
                'php8.0-fpm' => 'PHP-FPM (8.0)',
                'php7.4-fpm' => 'PHP-FPM (7.4)',
                'php-fpm'    => 'PHP-FPM (generic)'
            ];
            foreach ($services as $service => $label) {
                $status = getServiceStatus($service);
                $isActive = strpos($status, 'Active') !== false;
                $class = $isActive ? 'success' : 'error';
                echo "<div class='status-item $class'>";
                echo "<span class='label'>$label</span>";
                echo "<span class='value'>$status</span>";
                echo "</div>";
            }
            ?>
        </div>

        <!-- Database Files -->
        <div class="card">
            <h2>💾 فایل‌های دیتابیس</h2>
            <?php
            $databases = [
                '/etc/wireguard/clients.db' => 'کاربران (ETC)',
                '/var/www/wireguard/db/clients.db' => 'کاربران (WEB)',
                '/etc/wireguard/quota.db' => 'سهمیه (ETC)',
                '/etc/wireguard/admin.db' => 'ادمین (ETC)',
                '/etc/wireguard/endpoint.db' => 'Endpoint',
                '/etc/wireguard/dns.db' => 'DNS'
            ];
            foreach ($databases as $db => $label) {
                $status = getFileStatus($db);
                $exists = file_exists($db);
                $class = $exists ? 'success' : 'error';
                $lines = $exists ? count(file($db, FILE_IGNORE_NEW_LINES)) : 0;
                echo "<div class='status-item $class'>";
                echo "<span class='label'>$label</span>";
                echo "<span class='value'>$status" . ($exists ? " ($lines lines)" : "") . "</span>";
                echo "</div>";
            }
            ?>
        </div>

        <!-- Scripts -->
        <div class="card">
            <h2>📜 اسکریپت‌های سیستم</h2>
            <?php
            $scripts = [
                '/usr/local/bin/wg-admin-is-admin' => 'Admin Check',
                '/usr/local/bin/wg-admin' => 'Admin Manager',
                '/usr/local/bin/wg-update-endpoint' => 'Update Endpoint',
                '/usr/local/bin/wireguard-manager' => 'Main Manager'
            ];
            foreach ($scripts as $script => $label) {
                $status = getFileStatus($script);
                $exists = file_exists($script);
                $class = $exists ? 'success' : 'error';
                $executable = $exists && is_executable($script);
                echo "<div class='status-item $class'>";
                echo "<span class='label'>" . ($executable ? '✅' : '❌') . " $label</span>";
                echo "<span class='value'>$status</span>";
                echo "</div>";
            }
            ?>
        </div>

        <!-- Network Info -->
        <div class="card">
            <h2>🌐 اطلاعات شبکه</h2>
            <?php
            $wg_info = shell_exec("wg show wg0 2>&1");
            $has_interface = strpos($wg_info, 'interface: wg0') !== false;
            $peers_count = substr_count($wg_info, 'peer:');
            ?>
            <div class="status-item <?php echo $has_interface ? 'success' : 'error'; ?>">
                <span class="label">📡 WireGuard Interface</span>
                <span class="value"><?php echo $has_interface ? '🟢 فعال' : '🔴 غیرفعال'; ?></span>
            </div>
            <div class="status-item success">
                <span class="label">👥 تعداد Peers متصل</span>
                <span class="value"><?php echo $peers_count; ?></span>
            </div>
            <?php
            $endpoint = file_exists('/etc/wireguard/endpoint.db') ? 
                        trim(file_get_contents('/etc/wireguard/endpoint.db')) : 'Not Set';
            $dns = file_exists('/etc/wireguard/dns.db') ? 
                   trim(file_get_contents('/etc/wireguard/dns.db')) : 'Not Set';
            ?>
            <div class="status-item success">
                <span class="label">🔗 Endpoint</span>
                <span class="value"><?php echo $endpoint; ?></span>
            </div>
            <div class="status-item success">
                <span class="label">🌍 DNS</span>
                <span class="value"><?php echo $dns; ?></span>
            </div>
        </div>

        <!-- Permissions -->
        <div class="card">
            <h2>🔐 دسترسی‌ها</h2>
            <?php
            $web_user = 'www-data';
            if (posix_getpwnam('nginx')) $web_user = 'nginx';

            // Verify sudoers allows panel commands instead of generic whoami
            $sudo_list = shell_exec("sudo -n -l 2>&1");
            $can_sudo = strpos($sudo_list ?: '', '/usr/local/bin/wg-admin') !== false;
            
            $db_writable = is_writable('/var/www/wireguard/db');
            $etc_readable = is_readable('/etc/wireguard');
            ?>
            <div class="status-item <?php echo $can_sudo ? 'success' : 'error'; ?>">
                <span class="label">🔑 کاربر وب: <?php echo $web_user; ?></span>
                <span class="value"><?php echo $can_sudo ? '✅ دسترسی Sudo دارد' : '❌ دسترسی Sudo ندارد'; ?></span>
            </div>
            <div class="status-item <?php echo $db_writable ? 'success' : 'error'; ?>">
                <span class="label">📝 دسترسی نوشتن DB</span>
                <span class="value"><?php echo $db_writable ? '✅ قابل نوشتن' : '❌ غیرقابل نوشتن'; ?></span>
            </div>
            <div class="status-item <?php echo $etc_readable ? 'success' : 'error'; ?>">
                <span class="label">👁️ دسترسی خواندن /etc</span>
                <span class="value"><?php echo $etc_readable ? '✅ قابل خواندن' : '❌ غیرقابل خواندن'; ?></span>
            </div>
            <?php
            $sudoers_exists = file_exists('/etc/sudoers.d/wg-web');
            ?>
            <div class="status-item <?php echo $sudoers_exists ? 'success' : 'error'; ?>">
                <span class="label">⚙️ فایل Sudoers</span>
                <span class="value"><?php echo getFileStatus('/etc/sudoers.d/wg-web'); ?></span>
            </div>
        </div>
    </div>

    <!-- Deletion Log -->
    <details class="card" style="grid-column: 1 / -1;">
        <summary>🗑️ لاگ حذف کاربران (کلیک برای نمایش)</summary>
        <div class="log-box">
<?php
if (file_exists('/tmp/wireguard_delete.log')) {
    $tail = tailFile('/tmp/wireguard_delete.log', 100);
    echo htmlspecialchars($tail ?? '');
} else {
    echo "📝 هیچ لاگ حذفی موجود نیست.";
}
?>
        </div>
    </details>

    <!-- Add Client Log -->
    <details class="card" style="grid-column: 1 / -1;">
        <summary>➕ لاگ افزودن کاربران (کلیک برای نمایش)</summary>
        <div class="log-box">
<?php
if (file_exists('/tmp/wireguard_add.log')) {
    $tail = tailFile('/tmp/wireguard_add.log', 100);
    echo htmlspecialchars($tail ?? '');
} else {
    echo "📝 هنوز کاربری افزوده نشده است.";
}
?>
        </div>
    </details>

    <!-- Edit Client Log -->
    <details class="card" style="grid-column: 1 / -1;">
        <summary>✏️ لاگ ویرایش کاربران (کلیک برای نمایش)</summary>
        <div class="log-box">
<?php
if (file_exists('/tmp/wireguard_edit.log')) {
    $tail = tailFile('/tmp/wireguard_edit.log', 100);
    echo htmlspecialchars($tail ?? '');
} else {
    echo "📝 هنوز ویرایشی ثبت نشده است.";
}
?>
        </div>
    </details>

    <!-- WireGuard Interface Details -->
    <details class="card" style="grid-column: 1 / -1;">
        <summary>🔧 جزئیات WireGuard Interface (کلیک برای نمایش)</summary>
        <div class="log-box">
<?php
$wg_output = shell_exec("wg show wg0 2>&1");
echo htmlspecialchars($wg_output ?: "⚠️ Unable to retrieve WireGuard interface details");
?>
        </div>
    </details>

    <!-- Active Clients List -->
    <details class="card" style="grid-column: 1 / -1;">
        <summary>👥 لیست کاربران فعال (کلیک برای نمایش)</summary>
        <div class="log-box">
<?php
if (file_exists('/etc/wireguard/clients.db')) {
    $lines = file('/etc/wireguard/clients.db', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    foreach ($lines as $line) {
        if (strpos($line, '#') === 0) {
            echo "<span style='color: #888;'>$line</span>\n";
        } else if (trim($line) !== '') {
            $parts = explode('|', $line);
            if (count($parts) >= 4) {
                echo "👤 " . htmlspecialchars($parts[0] ?? 'unknown') . " → " . htmlspecialchars($parts[3] ?? 'no-ip') . "\n";
            } else if (count($parts) >= 1) {
                echo "👤 " . htmlspecialchars($parts[0] ?? 'unknown') . "\n";
            }
        }
    }
} else {
    echo "❌ Database not found: /etc/wireguard/clients.db";
}
?>
        </div>
    </details>

    <!-- بخش مصرف/نمودار حذف شد بنا به درخواست -->

    <div class="timestamp">
        ⚡ Generated in <?php echo round((microtime(true) - $_SERVER['REQUEST_TIME_FLOAT']) * 1000, 2); ?> ms
    </div>
    </div>

    <script>
    // Auto refresh toggle logic (30s)
    (function(){
        var key = 'wg_debug_auto_refresh';
        var cb = document.getElementById('autoRefreshToggle');
        if (cb) {
            try { if (localStorage.getItem(key) === '1') { cb.checked = true; } } catch(e){}
            var timer = null;
            function arm(){
                if (timer) clearInterval(timer);
                if (cb.checked) timer = setInterval(function(){ location.reload(); }, 30000);
            }
            cb.addEventListener('change', function(){
                try { localStorage.setItem(key, cb.checked ? '1' : '0'); } catch(e){}
                arm();
            });
            arm();
        }
    })();
    </script>

    <script>
    // Guard: silence noisy extension errors like "recorder is not defined" to avoid disrupting UX
    (function(){
        var prevHandler = window.onerror;
        window.onerror = function(message, source, lineno, colno, error){
            try {
                if ((message && /recorder is not defined/i.test(String(message))) ||
                    (error && /recorder is not defined/i.test(String(error && error.message)))) {
                    // Swallow this specific error pattern
                    return true; // prevent default logging
                }
            } catch(e){}
            if (typeof prevHandler === 'function') {
                return prevHandler.apply(this, arguments);
            }
            return false; // proceed normally
        };
    })();
    </script>
</body>
</html>
DEBUGPHP

        chmod 644 "$WEB_DIR/debug.php"
        # Create admin token endpoint
        cat > "$WEB_DIR/make_debug_token.php" <<'PHP'
<?php
header('Content-Type: application/json; charset=utf-8');
$pk = trim($_GET['pk'] ?? '');
if ($pk === '') { echo json_encode(['ok'=>false,'err'=>'no-pk']); exit; }
$cmd = 'sudo /usr/local/bin/wg-admin-is-admin ' . escapeshellarg($pk);
$out = shell_exec($cmd . ' 2>&1');
$lines = preg_split("/\r?\n/", trim((string)$out));
$is_admin = strtolower(trim(end($lines) ?: '')) === 'true';
if (!$is_admin) { echo json_encode(['ok'=>false,'err'=>'not-admin']); exit; }
$token = bin2hex(random_bytes(16));
$payload = ['token'=>$token, 'expires'=> time()+600];
file_put_contents('/var/www/wireguard/debug.key', json_encode($payload), LOCK_EX);
echo json_encode(['ok'=>true, 'url'=> '/debug.php?token=' . $token]);
PHP
        chmod 644 "$WEB_DIR/make_debug_token.php"

        # Create admin debug link script and include it in index.php later
        mkdir -p "$WEB_ASSETS"
                        cat > "$WEB_ASSETS/admin-debug-link.js" <<'JS'
    (function() {
        function hideSearch() {
            var searchInput = document.querySelector('input[name="pk"]');
            var searchBox = document.querySelector('.search-box');
            if (searchBox) searchBox.style.display = 'none';
            if (searchInput) searchInput.style.display = 'none';
        }
        function addButton(url) {
            var btn = document.createElement('button');
            btn.textContent = '🔍 صفحه Debug';
            btn.style.cssText = 'position:fixed;bottom:20px;right:20px;z-index:9999;padding:10px 14px;border:none;border-radius:10px;background:linear-gradient(135deg,#667eea,#764ba2);color:#fff;font-weight:600;cursor:pointer;box-shadow:0 6px 18px rgba(0,0,0,0.22)';
            btn.onclick = function(){ window.open(url, '_blank'); };
            document.body.appendChild(btn);
        }
        var hasUserView = !!document.querySelector('.qr-image') || !!document.querySelector('.config-section');
    if (hasUserView) hideSearch();
        // Try to read pk from the search input; if present, request a token
        var pkInput = document.querySelector('input[name="pk"]');
        var pk = pkInput && pkInput.value ? pkInput.value.trim() : '';
    // If pk exists (admin authenticated), hide search immediately
    if (pk) hideSearch(); else return;
        fetch('/make_debug_token.php?pk=' + encodeURIComponent(pk))
            .then(r => r.json()).then(j => {
            if (j && j.ok && j.url) { addButton(j.url); }
            }).catch(() => {});
    })();
JS
        chmod 644 "$WEB_ASSETS/admin-debug-link.js"

            # Ensure index.php loads the admin debug link helper
            if [ -f "$WEB_DIR/index.php" ] && ! grep -q "admin-debug-link.js" "$WEB_DIR/index.php"; then
                    echo "<script src=\"/assets/admin-debug-link.js\"></script>" >> "$WEB_DIR/index.php"
            fi

            # Usage collector script and cron for weekly chart
            cat > /usr/local/bin/wg-collect-usage <<'BASH'
    #!/usr/bin/env bash
    set -euo pipefail
    DIR=/etc/wireguard/usage
    STATE="$DIR/state.tsv"
    TODAY="$(date +%F)"
    CSV="$DIR/$TODAY.csv"
    mkdir -p "$DIR"

    # Build IP -> user map from client config files
    declare -A ip2user
    shopt -s nullglob
    for f in /etc/wireguard/clients/*.conf /var/www/wireguard/clients/*.conf; do
        [ -f "$f" ] || continue
        name="$(basename "$f" .conf)"
        addr_line=$(grep -m1 -E '^Address\s*=\s*' "$f" || true)
        addr=$(echo "$addr_line" | sed -E 's/.*=\s*([^,\/]*)[\/,]?.*/\1/')
        if [ -n "${addr:-}" ]; then ip2user["$addr"]="$name"; fi
    done

    # Load previous state
    declare -A prev
    if [ -f "$STATE" ]; then
        while IFS='|' read -r k v; do prev["$k"]="$v"; done < "$STATE"
    fi
    > "$STATE.new"
    declare -A add_bytes

    # Read wg dump: peer|allowed_ips|rx|tx (robust if wg0 down)
    # wg show wg0 dump fields for peers: $1=pubkey $2=psk $3=endpoint $4=allowed-ips $5=latest-handshake $6=rx $7=tx $8=keepalive
    WG_DUMP="$(wg show wg0 dump 2>/dev/null || true)"
    printf '%s\n' "$WG_DUMP" | awk 'NR>1 {print $1"|"$4"|"$6"|"$7}' | while IFS='|' read -r peer allowed rx tx; do
        cur=$(( rx + tx ))
        ip=$(echo "$allowed" | awk -F',' '{print $1}' | sed -E 's#/.*##')
        user="${ip2user[$ip]:-}"
        [ -n "$user" ] || continue
        prevv="${prev[$peer]:-0}"
        if [ "$cur" -lt "$prevv" ]; then delta=0; else delta=$(( cur - prevv )); fi
        echo "$peer|$cur" >> "$STATE.new"
        if [ -n "${add_bytes[$user]:-}" ]; then add_bytes[$user]=$(( ${add_bytes[$user]} + delta )); else add_bytes[$user]=$delta; fi
    done

    # Atomically replace state
    mv -f "$STATE.new" "$STATE" 2>/dev/null || cp "$STATE.new" "$STATE"; rm -f "$STATE.new" 2>/dev/null || true

    # Update today's totals CSV
    if [ -f "$CSV" ]; then cp "$CSV" "$CSV.tmp"; else : > "$CSV.tmp"; fi
    for u in "${!add_bytes[@]}"; do
        inc=${add_bytes[$u]}
        if grep -q -E "^${u}\|" "$CSV.tmp"; then
            awk -F'|' -v OFS='|' -v U="$u" -v INC="$inc" '{ if ($1==U) {$2=$2+INC} print }' "$CSV.tmp" > "$CSV.new" && mv "$CSV.new" "$CSV.tmp"
        else
            echo "$u|$inc" >> "$CSV.tmp"
        fi
    done
    mv -f "$CSV.tmp" "$CSV"
BASH
            chmod +x /usr/local/bin/wg-collect-usage

            cat > /etc/cron.d/wg-collect-usage <<'CRON'
    */5 * * * * root /usr/local/bin/wg-collect-usage >/dev/null 2>&1
CRON
            chmod 644 /etc/cron.d/wg-collect-usage
    ok "Advanced debug page created"

    # Create PHP file (Persian interface)
    # [PHP content remains the same as original]
    cat > "$WEB_DIR/index.php" <<'PHP'
 <?php
ob_start(); // شروع output buffering

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

// تابع پاکسازی peer های خالی از کانفیگ
function clean_empty_peers()
{
    $config_file = '/etc/wireguard/wg0.conf';
    $temp_file = '/tmp/wg0_cleaned_' . time() . '.conf';
    
    $cmd = "sudo awk 'BEGIN{in_peer=0;peer_content=\"\"}";
    $cmd .= "/^\\[Interface\\]/{print;in_peer=0;next}";
    $cmd .= "/^\\[Peer\\]/{if(in_peer&&peer_content!=\"\"){print \"[Peer]\";print peer_content}in_peer=1;peer_content=\"\";next}";
    $cmd .= "{if(in_peer){if(\$0!~/^[[:space:]]*\$/){if(peer_content!=\"\"){peer_content=peer_content\"\\n\"\$0}else{peer_content=\$0}}}else{print}}";
    $cmd .= "END{if(in_peer&&peer_content!=\"\"){print \"[Peer]\";print peer_content}}'";
    $cmd .= " $config_file > $temp_file && sudo mv $temp_file $config_file && sudo chmod 600 $config_file";
    
    error_log("Cleaning empty peers from config");
    shell_exec($cmd . " 2>&1");
}

// دریافت اطلاعات سرور
function get_server_info()
{
    // /etc is primary source, web is just a copy
    $endpoint = @file_get_contents('/etc/wireguard/endpoint.db');
    if ($endpoint === false || trim($endpoint) === '') {
        $endpoint = @file_get_contents('/var/www/wireguard/db/endpoint.db');
    }

    $dns = @file_get_contents('/etc/wireguard/dns.db');
    if ($dns === false || trim($dns) === '') {
        $dns = @file_get_contents('/var/www/wireguard/db/dns.db');
    }

    // دریافت کلید عمومی سرور
    $public_key = @file_get_contents('/etc/wireguard/server_public.key');
    if ($public_key === false || trim($public_key) === '') {
        $public_key = @file_get_contents('/var/www/wireguard/server_public.key');
    }

    // Force fresh status check every time - no caching
    // Use custom script to avoid sudo password issues
    $status_output = @shell_exec('sudo /usr/local/bin/wg-service-control is-active 2>&1');
    $status = trim($status_output ?: 'unknown');
    
    // Log for debugging if needed
    error_log("WireGuard status check: raw='" . $status_output . "' trimmed='" . $status . "'");
    
    // تبدیل خروجی های مختلف به active یا inactive
    if (in_array($status, ['active', 'activating'])) {
        $status = 'active';
    } elseif (in_array($status, ['inactive', 'failed', 'deactivating', 'unknown'])) {
        $status = 'inactive';
    }
    
    // Additional verification - check if WG interface exists
    if ($status === 'active') {
        $wg_check = @shell_exec('wg show wg0 2>/dev/null');
        if (empty($wg_check)) {
            error_log("WireGuard service active but no interface found");
            // Keep status as active since systemctl reports it as such
        }
    }

    return array(
        'endpoint' => trim($endpoint) ?: 'SERVER_IP:1010',
        'dns' => trim($dns) ?: '1.1.1.1,8.8.8.8',
        'public_key' => trim($public_key) ?: '',
        'status' => $status
    );
}

// دریافت لیست کاربران
function get_clients_list()
{
    $clients = array();
    // /etc is primary source
    $client_db = '/etc/wireguard/clients.db';
    $quota_db = '/etc/wireguard/quota.db';
    $clients_dir = '/etc/wireguard/clients';

    // Fallback to web if /etc missing
    if (!file_exists($client_db)) {
        $client_db = '/var/www/wireguard/db/clients.db';
        $clients_dir = '/var/www/wireguard/clients';
    }
    if (!file_exists($quota_db)) {
        $quota_db = '/var/www/wireguard/db/quota.db';
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
            $key_file = $clients_dir . "/${name}_private.key";
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
    error_log("=== شروع پشتیبان‌گیری WireGuard ===");
    
    // Store backups under web directory so panel and web user can access them
    $web_backup_root = '/var/www/wireguard/backups';
    error_log("مسیر ریشه بک‌اپ: " . $web_backup_root);
    
    if (!is_dir($web_backup_root)) {
        error_log("ایجاد پوشه backups...");
        @mkdir($web_backup_root, 0755, true);
        @chown($web_backup_root, 'www-data');
        @chgrp($web_backup_root, 'www-data');
        error_log("پوشه backups ایجاد شد: " . (is_dir($web_backup_root) ? 'موفق' : 'ناموفق'));
    }

    $backup_dir = $web_backup_root . '/wireguard-backup-' . date('Y-m-d-H-i-s');
    $backup_file = $backup_dir . '.tar.gz';
    error_log("نام پوشه بک‌اپ: " . $backup_dir);
    error_log("نام فایل آرشیو: " . $backup_file);

    if (!mkdir($backup_dir, 0755, true)) {
        error_log("خطا: نتوانست پوشه بک‌اپ را ایجاد کند");
        return false;
    }
    error_log("پوشه بک‌اپ موقت ایجاد شد");

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

    $backup_count = 0;
    $failed_files = [];
    
    error_log("شروع کپی فایل‌ها...");
    foreach ($files_to_backup as $file) {
        $dest = $backup_dir . '/' . basename($file);
        if (file_exists($file)) {
            if (copy($file, $dest)) {
                $backup_count++;
                $size = filesize($file);
                error_log("کپی شد: " . $file . " (" . $size . " بایت)");
            } else {
                $failed_files[] = $file . " (اصلی)";
                error_log("خطا در کپی: " . $file);
            }
        } else {
            // Try fallback to /etc for DBs
            $etc_path = '/etc/wireguard/' . basename($file);
            if (file_exists($etc_path)) {
                if (copy($etc_path, $dest)) {
                    $backup_count++;
                    $size = filesize($etc_path);
                    error_log("کپی شد (fallback): " . $etc_path . " (" . $size . " بایت)");
                } else {
                    $failed_files[] = $etc_path . " (fallback)";
                    error_log("خطا در کپی fallback: " . $etc_path);
                }
            } else {
                $failed_files[] = $file . " (فایل وجود ندارد)";
                error_log("فایل یافت نشد: " . $file . " یا " . $etc_path);
            }
        }
    }

    // copy clients directory from /etc or web copy
    $clients_copied = false;
    if (is_dir($web_db_dir . '/../clients')) {
        $web_clients = $web_db_dir . '/../clients';
        $cmd = "cp -r " . escapeshellarg($web_clients) . " " . escapeshellarg($backup_dir) . " 2>&1";
        error_log("کپی کردن پوشه clients از web: " . $web_clients);
        $result = shell_exec($cmd);
        if (is_dir($backup_dir . '/clients')) {
            $clients_copied = true;
            $client_count = count(glob($backup_dir . '/clients/*'));
            error_log("پوشه clients کپی شد - تعداد فایل‌ها: " . $client_count);
        } else {
            error_log("خطا در کپی پوشه clients از web: " . $result);
        }
    } 
    
    if (!$clients_copied && is_dir('/etc/wireguard/clients')) {
        $cmd = "cp -r /etc/wireguard/clients " . escapeshellarg($backup_dir) . " 2>&1";
        error_log("کپی کردن پوشه clients از /etc/wireguard/clients");
        $result = shell_exec($cmd);
        if (is_dir($backup_dir . '/clients')) {
            $clients_copied = true;
            $client_count = count(glob($backup_dir . '/clients/*'));
            error_log("پوشه clients کپی شد از /etc - تعداد فایل‌ها: " . $client_count);
        } else {
            error_log("خطا در کپی پوشه clients از /etc: " . $result);
        }
    }

    error_log("تعداد فایل‌های کپی شده: " . $backup_count);
    error_log("پوشه clients کپی شد: " . ($clients_copied ? 'بله' : 'خیر'));
    if (!empty($failed_files)) {
        error_log("فایل‌های ناموفق: " . implode(', ', $failed_files));
    }

    // create archive
    error_log("شروع ایجاد آرشیو...");
    $cmd = "tar -czf " . escapeshellarg($backup_file) . " -C " . escapeshellarg(dirname($backup_dir)) . " " . escapeshellarg(basename($backup_dir)) . " 2>&1";
    error_log("دستور tar: " . $cmd);
    $result = shell_exec($cmd);
    
    if ($result) {
        error_log("خروجی tar: " . trim($result));
    }

    // cleanup
    error_log("پاکسازی پوشه موقت...");
    shell_exec("rm -rf " . escapeshellarg($backup_dir));

    if (file_exists($backup_file)) {
        $archive_size = filesize($backup_file);
        error_log("آرشیو ایجاد شد: " . $backup_file . " (" . $archive_size . " بایت)");
        @chown($backup_file, 'www-data');
        @chgrp($backup_file, 'www-data');
        error_log("=== پشتیبان‌گیری با موفقیت تکمیل شد ===");
        return $backup_file;
    } else {
        error_log("خطا: فایل آرشیو ایجاد نشد");
        error_log("=== پشتیبان‌گیری ناموفق ===");
        return false;
    }
}

// تابع بازنشانی پشتیبان
function restore_backup($backup_file)
{
    error_log("=== شروع بازیابی پشتیبان WireGuard ===");
    error_log("فایل بازیابی: " . $backup_file);
    
    if (!file_exists($backup_file)) {
        error_log("خطا: فایل پشتیبان یافت نشد: " . $backup_file);
        return "فایل پشتیبان یافت نشد";
    }

    $backup_size = filesize($backup_file);
    error_log("حجم فایل بازیابی: " . $backup_size . " بایت");

    $extract_dir = '/tmp/wireguard-restore-' . date('Y-m-d-H-i-s');
    error_log("پوشه استخراج: " . $extract_dir);

    // استخراج فایل آرشیو
    // ensure extraction directory exists
    if (!is_dir($extract_dir)) {
        if (!mkdir($extract_dir, 0755, true)) {
            error_log("خطا: نتوانست پوشه استخراج را ایجاد کند");
            return "خطا در ایجاد پوشه استخراج";
        }
        error_log("پوشه استخراج ایجاد شد");
    }
    
    $tar_cmd = "tar -xzf " . escapeshellarg($backup_file) . " -C " . escapeshellarg($extract_dir) . " 2>&1";
    error_log("دستور استخراج: " . $tar_cmd);
    $result = shell_exec($tar_cmd);
    
    if ($result) {
        error_log("خروجی tar extract: " . trim($result));
    }

    if (!is_dir($extract_dir)) {
        error_log("خطا: پوشه استخراج ایجاد نشد");
        return "خطا در استخراج فایل پشتیبان";
    }

    // پیدا کردن دایرکتوری بکاپ
    $backup_dirs = glob($extract_dir . '/wireguard-backup-*');
    error_log("پوشه‌های backup یافت شده: " . implode(', ', $backup_dirs));
    
    if (empty($backup_dirs)) {
        error_log("خطا: ساختار پشتیبان نامعتبر است");
        shell_exec("rm -rf " . escapeshellarg($extract_dir));
        return "ساختار پشتیبان نامعتبر است";
    }

    $backup_dir = $backup_dirs[0];
    error_log("پوشه backup انتخابی: " . $backup_dir);
    
    // بررسی محتویات پوشه backup
    $backup_contents = glob($backup_dir . '/*');
    error_log("محتویات backup: " . implode(', ', array_map('basename', $backup_contents)));

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

    $restored_count = 0;
    $failed_files = [];
    
    error_log("شروع بازیابی فایل‌ها...");
    foreach ($files_to_restore as $file) {
        $source = $backup_dir . '/' . $file;
        $destination = '/etc/wireguard/' . $file;

        if (file_exists($source)) {
            if (copy($source, $destination)) {
                chmod($destination, 600);
                $size = filesize($destination);
                error_log("بازیابی شد: " . $file . " (" . $size . " بایت)");
                $restored_count++;
            } else {
                $failed_files[] = $file;
                error_log("خطا در بازیابی: " . $file);
            }
        } else {
            error_log("فایل در backup یافت نشد: " . $file);
        }
    }

    error_log("تعداد فایل‌های بازیابی شده: " . $restored_count);
    if (!empty($failed_files)) {
        error_log("فایل‌های ناموفق در بازیابی: " . implode(', ', $failed_files));
    }

    // بازنشانی دایرکتوری کلاینت‌ها
    $clients_restored = false;
    if (is_dir($backup_dir . '/clients')) {
        error_log("شروع بازیابی پوشه clients...");
        $client_files_before = is_dir('/etc/wireguard/clients') ? count(glob('/etc/wireguard/clients/*')) : 0;
        error_log("تعداد فایل‌های client قبل از بازیابی: " . $client_files_before);
        
        shell_exec("rm -rf /etc/wireguard/clients");
        error_log("پوشه clients قدیمی حذف شد");
        
        $cp_result = shell_exec("cp -r " . escapeshellarg($backup_dir . '/clients') . " /etc/wireguard/ 2>&1");
        if ($cp_result) {
            error_log("خروجی کپی clients: " . trim($cp_result));
        }
        
        shell_exec("chmod -R 600 /etc/wireguard/clients");
        
        if (is_dir('/etc/wireguard/clients')) {
            $client_files_after = count(glob('/etc/wireguard/clients/*'));
            error_log("تعداد فایل‌های client بعد از بازیابی: " . $client_files_after);
            $clients_restored = true;
        } else {
            error_log("خطا: پوشه clients بازیابی نشد");
        }
    } else {
        error_log("پوشه clients در backup یافت نشد");
    }

    // راه‌اندازی مجدد سرویس
    error_log("راه‌اندازی مجدد سرویس WireGuard...");
    $restart_result = shell_exec("systemctl restart wg-quick@wg0 2>&1");
    if ($restart_result) {
        error_log("خروجی restart service: " . trim($restart_result));
    }
    
    // بررسی وضعیت سرویس پس از restart
    sleep(2); // انتظار کوتاه برای اطمینان از start شدن سرویس
    $status_check = shell_exec("systemctl is-active wg-quick@wg0 2>&1");
    error_log("وضعیت سرویس پس از restart: " . trim($status_check));

    // همگام‌سازی با دیتابیس وب: copy each file and set ownership
    error_log("شروع همگام‌سازی با دیتابیس وب...");
    $web_db_dir = '/var/www/wireguard/db';
    if (!is_dir($web_db_dir)) {
        @mkdir($web_db_dir, 0755, true);
        error_log("پوشه web db ایجاد شد");
    }

    $sync_count = 0;
    foreach (['clients.db', 'quota.db', 'admin.db', 'endpoint.db', 'dns.db'] as $f) {
        $etc_path = '/etc/wireguard/' . $f;
        $web_path = $web_db_dir . '/' . $f;
        if (file_exists($etc_path)) {
            if (copy($etc_path, $web_path)) {
                @chmod($web_path, 0640);
                @chown($web_path, 'www-data');
                @chgrp($web_path, 'www-data');
                $size = filesize($web_path);
                error_log("همگام‌سازی شد: " . $f . " (" . $size . " بایت)");
                $sync_count++;
            } else {
                error_log("خطا در همگام‌سازی: " . $f);
            }
        } else {
            error_log("فایل برای همگام‌سازی یافت نشد: " . $etc_path);
        }
    }
    error_log("تعداد فایل‌های همگام‌سازی شده: " . $sync_count);

    // copy clients directory into web area for panel usage
    if (is_dir('/etc/wireguard/clients')) {
        error_log("کپی کردن پوشه clients به محیط web...");
        $web_clients_dir = '/var/www/wireguard/clients';
        $rm_result = shell_exec("rm -rf " . escapeshellarg($web_clients_dir) . " 2>&1");
        if ($rm_result) {
            error_log("خروجی حذف web clients: " . trim($rm_result));
        }
        
        $cp_web_result = shell_exec("cp -r /etc/wireguard/clients " . escapeshellarg('/var/www/wireguard/') . " 2>&1");
        if ($cp_web_result) {
            error_log("خروجی کپی web clients: " . trim($cp_web_result));
        }
        
        shell_exec("chmod -R 640 " . escapeshellarg($web_clients_dir) . " 2>&1");
        shell_exec("chown -R www-data:www-data " . escapeshellarg($web_clients_dir) . " 2>&1");
        
        if (is_dir($web_clients_dir)) {
            $web_client_count = count(glob($web_clients_dir . '/*'));
            error_log("پوشه web clients کپی شد - تعداد فایل‌ها: " . $web_client_count);
        }
    } else {
        error_log("پوشه /etc/wireguard/clients برای کپی به web یافت نشد");
    }

    // حذف فایل‌های موقت
    error_log("پاکسازی فایل‌های موقت...");
    $cleanup_result = shell_exec("rm -rf " . escapeshellarg($extract_dir));
    error_log("فایل‌های موقت پاک شد");

    error_log("=== بازیابی پشتیبان با موفقیت تکمیل شد ===");
    error_log("آمار نهایی - فایل‌ها: " . $restored_count . ", Clients: " . ($clients_restored ? 'بله' : 'خیر') . ", همگام‌سازی: " . $sync_count);

    return "پشتیبان با موفقیت بازنشانی شد و سرویس راه‌اندازی مجدد شد";
}

// تابع دریافت لیست بک‌اپ‌های موجود
function get_backup_list()
{
    $backup_dir = '/var/www/wireguard/backups';
    $backups = [];
    
    error_log("دریافت لیست backup ها از: " . $backup_dir);
    
    if (!is_dir($backup_dir)) {
        error_log("پوشه backups وجود ندارد");
        return $backups;
    }
    
    // جستجوی فایل‌های tar.gz
    $backup_files = glob($backup_dir . '/wireguard-backup-*.tar.gz');
    error_log("تعداد backup های یافت شده: " . count($backup_files));
    
    foreach ($backup_files as $file) {
        if (is_file($file)) {
            $basename = basename($file);
            $size = filesize($file);
            $created = filemtime($file);
            
            // استخراج تاریخ از نام فایل
            if (preg_match('/wireguard-backup-(\d{4}-\d{2}-\d{2}-\d{2}-\d{2}-\d{2})\.tar\.gz/', $basename, $matches)) {
                $date_string = $matches[1];
                $formatted_date = DateTime::createFromFormat('Y-m-d-H-i-s', $date_string);
                $display_date = $formatted_date ? $formatted_date->format('Y/m/d H:i:s') : $date_string;
            } else {
                $display_date = date('Y/m/d H:i:s', $created);
            }
            
            $backups[] = [
                'filename' => $basename,
                'filepath' => $file,
                'size' => $size,
                'size_formatted' => formatBytes($size),
                'created' => $created,
                'date' => $display_date
            ];
            
            error_log("Backup: " . $basename . " (" . formatBytes($size) . ")");
        }
    }
    
    // مرتب‌سازی بر اساس تاریخ ایجاد (جدیدترین اول)
    usort($backups, function($a, $b) {
        return $b['created'] - $a['created'];
    });
    
    return $backups;
}

// تابع فرمت کردن حجم فایل
function formatBytes($bytes, $precision = 2) {
    $units = array('B', 'KB', 'MB', 'GB', 'TB');
    
    for ($i = 0; $bytes > 1024 && $i < count($units) - 1; $i++) {
        $bytes /= 1024;
    }
    
    return round($bytes, $precision) . ' ' . $units[$i];
}

// پردازش درخواست‌های مدیریتی
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    // Ensure per-request initialization so previous requests don't leak state
    $ok = false;
    $data = null;
    $qr_code = "";
    $clients_list = array();
    $server_info = array();

    $pk = trim($_POST['pk'] ?? '');
    
    // Debug logging
    error_log("POST Request - PK present: " . (!empty($pk) ? "yes" : "no"));
    error_log("POST Request - Action: " . ($_POST['action'] ?? $_POST['admin_action'] ?? 'none'));
    
    // Test sudo execution
    $test_sudo = shell_exec("sudo -n whoami 2>&1");
    error_log("Sudo test result: " . ($test_sudo ?: "failed"));

    if (!empty($pk)) {
        $admin_check_cmd = "sudo /usr/local/bin/wg-admin-is-admin " . escapeshellarg($pk);
        error_log("Running command: $admin_check_cmd");
        $admin_output = shell_exec($admin_check_cmd . " 2>&1");
        error_log("Admin check raw output: " . ($admin_output ?: "empty"));
        // Only trust the last line as the boolean result
        $admin_lines = preg_split("/\r?\n/", trim((string)$admin_output));
        $admin_last = strtolower(trim(end($admin_lines) ?: ''));
        $is_admin = ($admin_last === 'true');
        
        error_log("Admin check result (parsed): " . ($is_admin ? "true" : "false"));

    if ($is_admin) {
            $ok = true;
            $data = array('client_name' => 'مدیر سیستم', 'ip_address' => 'N/A', 'is_admin' => true);
            // Expose admin PK to JS for subsequent AJAX calls
            echo "<script>window.ADMIN_PK='" . htmlspecialchars($pk, ENT_QUOTES, 'UTF-8') . "';</script>";

            // دریافت لیست کاربران
            $clients_list = get_clients_list();
            $server_info = get_server_info();
            $backup_list = get_backup_list();
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
                        $name_escaped = str_replace("'", "\\'", $name);
                        // Safely escape private_key for inline JavaScript
                        $private_key_js_escaped = str_replace(["\\", "'", "\n", "\r"], ["\\\\", "\\'", "\\n", "\\r"], $private_key);
                        
                        $row = "<tr>\n" .
                            "<td><strong>{$name}</strong></td>\n" .
                            "<td>{$ip}</td>\n" .
                            "<td>\n<div class=\"key-container\">\n<input type=\"text\" class=\"private-key\" value=\"{$private_key}\" readonly>\n<button class=\"copy-btn\" onclick=\"copyToClipboard(this)\"><i class=\"fas fa-copy\"></i></button>\n<button class=\"btn btn-primary\" onclick=\"showKeyModal('{$private_key_js_escaped}')\" style=\"padding: 6px 10px;\"><i class=\"fas fa-eye\"></i></button>\n</div>\n</td>\n" .
                            "<td>{$used_gb}</td>\n" .
                            "<td>{$limit_gb}</td>\n" .
                            "<td class=\"" . (($client['remaining_gb'] === '∞' || $client['remaining_gb'] > 0) ? 'success' : 'error') . "\"> <strong>{$remaining_gb}</strong></td>\n" .
                            "<td>{$expiry}</td>\n" .
                            "<td class=\"" . (($client['days_remaining'] === '∞' || $client['days_remaining'] > 7) ? 'success' : (($client['days_remaining'] > 0) ? 'warning' : 'error')) . "\"><strong>{$days_remaining}</strong></td>\n" .
                            "<td class=\"" . ($client['active'] ? 'success' : 'error') . "\">{$active}</td>\n" .
                            "<td>\n<div class=\"controls\">\n<button type=\"button\" onclick=\"showEditForm('{$name_escaped}', {$limit_gb}, " . ($days_remaining === '∞' ? 0 : $days_remaining) . ")\" class=\"btn btn-warning\" style=\"padding: 8px 12px;\"><i class=\"fas fa-edit\"></i></button>\n" .
                            "<button type=\"button\" onclick=\"if(confirm('آیا از حذف کاربر {$name_escaped} مطمئن هستید؟')) sendAdminAction('remove-client', '{$name_escaped}')\" class=\"btn btn-danger\" style=\"padding: 8px 12px;\"><i class=\"fas fa-trash\"></i></button>\n</div>\n</td>\n" .
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
                
                error_log("Admin Action: $action, Param1: $param1");

                // پردازش بروزرسانی endpoint و DNS
                if ($action === 'set-endpoint') {
                    $domain = $param1 ?? '';
                    $port = $param2 ?? '1010';
                    $dns = $param3 ?? '1.1.1.1,8.8.8.8';

                    if (!empty($domain) && !empty($port) && !empty($dns)) {
                        $endpoint_value = $domain . ':' . $port;
                        
                        error_log("set-endpoint: domain=$domain, port=$port, dns=$dns");
                        
                        // استفاده از اسکریپت جدید برای به‌روزرسانی settings
                        $update_cmd = "sudo /usr/local/bin/wg-update-settings " .
                            escapeshellarg($endpoint_value) . " " .
                            escapeshellarg($dns);
                        
                        $update_result = shell_exec($update_cmd . " 2>&1");
                        
                        // بررسی خطا در به‌روزرسانی settings
                        $settings_error = false;
                        if ($update_result !== null && trim($update_result) !== '') {
                            $out = strtolower($update_result);
                            $settings_error = (strpos($out, 'error') !== false) || 
                                            (strpos($out, 'خطا') !== false) || 
                                            (strpos($out, 'failed') !== false);
                        }
                        
                        if ($settings_error) {
                            $admin_message = "خطا در به‌روزرسانی تنظیمات: " . trim($update_result);
                            error_log("Settings update error: " . trim($update_result));
                            
                            $is_ajax = isset($_SERVER['HTTP_X_REQUESTED_WITH']) && 
                                       strtolower($_SERVER['HTTP_X_REQUESTED_WITH']) === 'xmlhttprequest';
                            
                            if ($is_ajax) {
                                if (ob_get_level()) {
                                    ob_end_clean();
                                }
                                header('Content-Type: application/json; charset=utf-8');
                                echo json_encode([
                                    'status' => 'error',
                                    'message' => $admin_message
                                ], JSON_UNESCAPED_UNICODE);
                                exit;
                            }
                            
                            $server_info = get_server_info();
                            return;
                        }
                        
                        // فراخوانی اسکریپت برای به‌روزرسانی کانفیگ‌های کاربران
                        $endpoint_cmd = "sudo /usr/local/bin/wg-update-endpoint " .
                            escapeshellarg($domain) . " " .
                            escapeshellarg($port) . " " .
                            escapeshellarg($dns);
                        $admin_result = shell_exec($endpoint_cmd . " 2>&1");
                        
                        // بررسی خطا در به‌روزرسانی کانفیگ‌های کاربران
                        $config_error = false;
                        if ($admin_result !== null && trim($admin_result) !== '') {
                            $out = strtolower($admin_result);
                            $config_error = (strpos($out, 'error') !== false) || 
                                          (strpos($out, 'خطا') !== false) || 
                                          (strpos($out, 'failed') !== false);
                        }
                        
                        if ($config_error) {
                            $admin_message = "تنظیمات ذخیره شد اما خطا در به‌روزرسانی کانفیگ‌های کاربران: " . trim($admin_result);
                        } else {
                            $admin_message = "تنظیمات endpoint و DNS با موفقیت به‌روزرسانی شد. Endpoint: {$endpoint_value}, DNS: {$dns}";
                        }

                        // بروزرسانی اطلاعات سرور
                        $server_info = get_server_info();
                        
                        // ارسال پاسخ JSON برای AJAX
                        $is_ajax = isset($_SERVER['HTTP_X_REQUESTED_WITH']) && 
                                   strtolower($_SERVER['HTTP_X_REQUESTED_WITH']) === 'xmlhttprequest';
                        
                        if ($is_ajax) {
                            if (ob_get_level()) {
                                ob_end_clean();
                            }
                            header('Content-Type: application/json; charset=utf-8');
                            echo json_encode([
                                'status' => $config_error ? 'error' : 'success',
                                'message' => $admin_message
                            ], JSON_UNESCAPED_UNICODE);
                            exit;
                        }
                    } else {
                        $admin_message = "خطا: تمام فیلدهای endpoint و DNS باید پر شوند";
                    }
                }
                // پردازش پشتیبان‌گیری
                elseif ($action === 'backup') {
                    $backup_file = create_backup();
                    if ($backup_file) {
                        // ایجاد یک کپی برای دانلود و نگه داشتن اصلی
                        $download_file = '/tmp/download-' . basename($backup_file);
                        copy($backup_file, $download_file);
                        
                        header('Content-Type: application/octet-stream');
                        header('Content-Disposition: attachment; filename="' . basename($backup_file) . '"');
                        header('Content-Length: ' . filesize($download_file));
                        readfile($download_file);
                        unlink($download_file); // فقط فایل موقت حذف می‌شود
                        exit;
                    } else {
                        $admin_message = "خطا در ایجاد پشتیبان";
                    }
                }
                // ایجاد پشتیبان بدون دانلود فوری
                elseif ($action === 'create-backup-only') {
                    $backup_file = create_backup();
                    if ($backup_file) {
                        $admin_message = "پشتیبان با موفقیت ایجاد شد: " . basename($backup_file);
                        // بروزرسانی لیست backup ها
                        $backup_list = get_backup_list();
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
                            $backup_list = get_backup_list();
                        } else {
                            $admin_message = "خطا در آپلود فایل پشتیبان";
                        }
                    } else {
                        $admin_message = "لطفا یک فایل پشتیبان انتخاب کنید";
                    }
                }
                // دانلود بک‌اپ ذخیره شده
                elseif ($action === 'download-backup') {
                    $filename = $_POST['filename'] ?? '';
                    error_log("درخواست دانلود backup: " . $filename);
                    
                    if (empty($filename)) {
                        $admin_message = "نام فایل مشخص نشده است";
                    } else {
                        // بررسی امنیتی نام فایل
                        $filename = basename($filename); // حذف مسیرهای نامناسب
                        $backup_file = '/var/www/wireguard/backups/' . $filename;
                        
                        error_log("مسیر فایل backup: " . $backup_file);
                        
                        if (file_exists($backup_file) && strpos($filename, 'wireguard-backup-') === 0 && substr($filename, -7) === '.tar.gz') {
                            error_log("شروع دانلود backup: " . $filename . " (" . filesize($backup_file) . " بایت)");
                            
                            header('Content-Type: application/octet-stream');
                            header('Content-Disposition: attachment; filename="' . $filename . '"');
                            header('Content-Length: ' . filesize($backup_file));
                            readfile($backup_file);
                            exit;
                        } else {
                            error_log("فایل backup یافت نشد یا نامعتبر است: " . $backup_file);
                            $admin_message = "فایل پشتیبان یافت نشد یا نامعتبر است";
                        }
                    }
                }
                // افزودن کاربر (پاسخ JSON برای استفاده در AJAX)
                elseif ($action === 'add-client') {
                    // پاک کردن هر خروجی قبلی و بستن output buffer
                    if (ob_get_level()) {
                        ob_end_clean();
                    }
                    
                    $admin_cmd = "sudo /usr/local/bin/wg-admin " .
                        escapeshellarg('add-client') . " " .
                        escapeshellarg($param1) . " " .
                        escapeshellarg($param2) . " " .
                        escapeshellarg($param3);

                    error_log("Executing add-client: $admin_cmd");
                    $admin_result = shell_exec($admin_cmd . " 2>&1");
                    error_log("add-client result: " . ($admin_result ?: "empty"));

                    // پاکسازی peer های خالی
                    clean_empty_peers();

                    // تشخیص خطا از خروجی
                    $has_error = false;
                    if ($admin_result !== null && trim($admin_result) !== '') {
                        $out = strtolower($admin_result);
                        $has_error = (strpos($out, 'error') !== false) || 
                                    (strpos($out, 'خطا') !== false) || 
                                    (strpos($out, 'failed') !== false) ||
                                    (strpos($out, 'already exists') !== false);
                    }

                    if ($has_error) {
                        header('Content-Type: application/json; charset=utf-8');
                        echo json_encode([
                            'status' => 'error',
                            'message' => trim((string)$admin_result)
                        ], JSON_UNESCAPED_UNICODE);
                        exit;
                    }

                    // بازیابی اطلاعات کاربر جدید با روش مطمئن‌تر
                    $newClient = null;
                    
                    // روش اول: خواندن مستقیم از فایل کلید خصوصی
                    $private_key_file = "/var/www/wireguard/clients/{$param1}_private.key";
                    $private_key = '';
                    if (file_exists($private_key_file)) {
                        $private_key = trim(file_get_contents($private_key_file));
                    }
                    
                    // اگر در مسیر web نبود، از مسیر /etc بخوانیم
                    if (empty($private_key)) {
                        $etc_key_file = "/etc/wireguard/clients/{$param1}_private.key";
                        if (file_exists($etc_key_file)) {
                            $private_key = trim(file_get_contents($etc_key_file));
                        }
                    }
                    
                    // روش دوم: پیدا کردن IP کاربر از خروجی دستور
                    $ip_address = '';
                    if (preg_match('/IP:\s*([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)/', $admin_result, $matches)) {
                        $ip_address = $matches[1];
                    }
                    
                    // اگر IP از خروجی پیدا نشد، از دیتابیس بگیریم
                    if (empty($ip_address)) {
                        $clients_list = get_clients_list();
                        foreach ($clients_list as $c) {
                            if (isset($c['name']) && $c['name'] === $param1) {
                                $ip_address = $c['ip'] ?? '';
                                if (empty($private_key)) {
                                    $private_key = $c['private_key'] ?? '';
                                }
                                break;
                            }
                        }
                    }
                    
                    // تولید QR Code
                    $qr_code = '';
                    if (!empty($private_key) && !empty($ip_address)) {
                        // تولید محتوای کانفیگ کامل برای QR
                        $server_public_key = '';
                        $server_public_key_file = '/etc/wireguard/server_public.key';
                        if (file_exists($server_public_key_file)) {
                            $server_public_key = trim(file_get_contents($server_public_key_file));
                        }
                        
                        if (empty($server_public_key)) {
                            $server_public_key_file = '/var/www/wireguard/server_public.key';
                            if (file_exists($server_public_key_file)) {
                                $server_public_key = trim(file_get_contents($server_public_key_file));
                            }
                        }
                        
                        // دریافت اطلاعات سرور
                        $temp_server_info = get_server_info();
                        $endpoint = $temp_server_info['endpoint'] ?? 'SERVER_IP:1010';
                        $dns = $temp_server_info['dns'] ?? '1.1.1.1,8.8.8.8';
                        
                        // ساخت کانفیگ کامل
                        $config_content = "[Interface]\n";
                        $config_content .= "PrivateKey = {$private_key}\n";
                        $config_content .= "Address = {$ip_address}/24\n";
                        $config_content .= "DNS = {$dns}\n";
                        $config_content .= "MTU = 1420\n\n";
                        $config_content .= "[Peer]\n";
                        $config_content .= "PublicKey = {$server_public_key}\n";
                        $config_content .= "Endpoint = {$endpoint}\n";
                        $config_content .= "AllowedIPs = 0.0.0.0/0, ::/0\n";
                        $config_content .= "PersistentKeepalive = 25\n";
                        
                        // ذخیره موقت کانفیگ
                        $temp_config = "/tmp/wg_temp_config_{$param1}_" . time() . ".conf";
                        file_put_contents($temp_config, $config_content);
                        
                        // تولید QR با qrencode - روش اول: مستقیم از فایل
                        $qr_cmd = "cat " . escapeshellarg($temp_config) . " | qrencode -t PNG -o - 2>&1";
                        $qr_output = shell_exec($qr_cmd);
                        
                        // بررسی اینکه خروجی واقعاً PNG است
                        $is_png = (!empty($qr_output) && substr($qr_output, 0, 4) === "\x89PNG");
                        
                        if ($is_png) {
                            $qr_code = base64_encode($qr_output);
                            error_log("QR Code generated successfully with qrencode");
                        } else {
                            error_log("QR Code generation with qrencode failed: " . substr($qr_output, 0, 100));
                            
                            // روش دوم: با اسکریپت سفارشی
                            $qr_cmd2 = "sudo /usr/local/bin/wg-generate-qr " . escapeshellarg($temp_config) . " 2>&1";
                            $qr_output2 = shell_exec($qr_cmd2);
                            
                            if (!empty($qr_output2) && substr($qr_output2, 0, 4) === "\x89PNG") {
                                $qr_code = base64_encode($qr_output2);
                                error_log("QR Code generated successfully with custom script");
                            } else {
                                error_log("QR Code generation with custom script also failed");
                            }
                        }
                        
                        // پاک کردن فایل موقت
                        @unlink($temp_config);
                        
                        // لاگ برای دیباگ
                        error_log("QR Code generation result: " . (!empty($qr_code) ? "success (length: " . strlen($qr_code) . ")" : "failed"));
                    } else {
                        error_log("QR Code generation skipped: private_key=" . (!empty($private_key) ? "present" : "missing") . ", ip=" . (!empty($ip_address) ? "present" : "missing"));
                    }

                    header('Content-Type: application/json; charset=utf-8');
                    $resp = [
                        'status' => 'success',
                        'name' => $param1,
                        'ip' => $ip_address,
                        'private_key' => $private_key,
                        'qr' => $qr_code,
                        'param2' => $param2,
                        'param3' => $param3
                    ];

                    echo json_encode($resp, JSON_UNESCAPED_UNICODE);
                    exit;
                }
                // ویرایش کاربر
                elseif ($action === 'edit-client') {
                    // پاک کردن هر خروجی قبلی
                    if (ob_get_level()) {
                        ob_end_clean();
                    }
                    
                    $admin_cmd = "sudo /usr/local/bin/wg-admin " .
                        escapeshellarg('edit-client') . " " .
                        escapeshellarg($param1) . " " .
                        escapeshellarg($param2) . " " .
                        escapeshellarg($param3);

                    error_log("Executing edit-client: $admin_cmd");
                    $admin_result = shell_exec($admin_cmd . " 2>&1");
                    error_log("edit-client result: " . ($admin_result ?: "empty"));

                    // پاکسازی peer های خالی
                    clean_empty_peers();

                    // تشخیص خطا از خروجی
                    $has_error = false;
                    $error_detail = '';
                    if ($admin_result !== null && trim($admin_result) !== '') {
                        $out = strtolower($admin_result);
                        $has_error = (strpos($out, 'error') !== false) || 
                                    (strpos($out, 'خطا') !== false) || 
                                    (strpos($out, 'failed') !== false) ||
                                    (strpos($out, 'not found') !== false) ||
                                    (strpos($out, 'invalid') !== false);
                        
                        if ($has_error) {
                            $error_detail = trim($admin_result);
                        }
                    }

                    // ارسال پاسخ (بدون تنظیم header اگر فرم معمولی است)
                    // بررسی اینکه آیا درخواست AJAX است یا نه
                    $is_ajax = isset($_SERVER['HTTP_X_REQUESTED_WITH']) && 
                               strtolower($_SERVER['HTTP_X_REQUESTED_WITH']) === 'xmlhttprequest';

                    if ($has_error) {
                        $admin_message = "خطا در ویرایش کاربر: " . $error_detail;
                        error_log("Error in edit-client: $admin_message");
                        
                        if ($is_ajax) {
                            header('Content-Type: application/json; charset=utf-8');
                            echo json_encode([
                                'status' => 'error',
                                'message' => $error_detail,
                                'debug' => [
                                    'command' => $admin_cmd,
                                    'output' => $admin_result
                                ]
                            ], JSON_UNESCAPED_UNICODE);
                            exit;
                        }
                    } else {
                        $success_msg = "کاربر {$param1} با موفقیت ویرایش شد (سهمیه: {$param2}GB، مدت: {$param3} روز)";
                        $admin_message = $success_msg;
                        error_log("Success: $success_msg");
                        
                        if ($is_ajax) {
                            header('Content-Type: application/json; charset=utf-8');
                            echo json_encode([
                                'status' => 'success',
                                'message' => $success_msg,
                                'client_name' => $param1,
                                'new_quota' => $param2,
                                'new_days' => $param3
                            ], JSON_UNESCAPED_UNICODE);
                            exit;
                        }
                    }

                    // رفرش اطلاعات برای نمایش معمولی
                    $clients_list = get_clients_list();
                    $server_info = get_server_info();
                }
                // حذف کاربر
                elseif ($action === 'remove-client') {
                    // پاک کردن هر خروجی قبلی
                    if (ob_get_level()) {
                        ob_end_clean();
                    }
                    
                    $admin_cmd = "sudo /usr/local/bin/wg-admin " .
                        escapeshellarg('remove-client') . " " .
                        escapeshellarg($param1);

                    error_log("Executing remove-client: $admin_cmd");
                    $admin_result = shell_exec($admin_cmd . " 2>&1");
                    error_log("remove-client result: " . ($admin_result ?: "empty"));

                    // پاکسازی peer های خالی
                    clean_empty_peers();

                    // تشخیص خطا
                    $has_error = false;
                    if ($admin_result !== null && trim($admin_result) !== '') {
                        $out = strtolower($admin_result);
                        $has_error = (strpos($out, 'error') !== false) || 
                                    (strpos($out, 'خطا') !== false) || 
                                    (strpos($out, 'failed') !== false) ||
                                    (strpos($out, 'not found') !== false);
                    }

                    // بررسی AJAX
                    $is_ajax = isset($_SERVER['HTTP_X_REQUESTED_WITH']) && 
                               strtolower($_SERVER['HTTP_X_REQUESTED_WITH']) === 'xmlhttprequest';

                    if ($has_error) {
                        $admin_message = "خطا: " . trim((string)$admin_result);
                        error_log("Error in remove-client: $admin_message");
                        
                        if ($is_ajax) {
                            header('Content-Type: application/json; charset=utf-8');
                            echo json_encode([
                                'status' => 'error',
                                'message' => $admin_message
                            ], JSON_UNESCAPED_UNICODE);
                            exit;
                        }
                    } else {
                        $success_msg = "کاربر {$param1} با موفقیت حذف شد";
                        $admin_message = $success_msg;
                        error_log("Success: $success_msg");
                        
                        if ($is_ajax) {
                            header('Content-Type: application/json; charset=utf-8');
                            echo json_encode([
                                'status' => 'success',
                                'message' => $success_msg,
                                'client_name' => $param1
                            ], JSON_UNESCAPED_UNICODE);
                            exit;
                        }
                    }

                    // رفرش اطلاعات برای نمایش معمولی
                    $clients_list = get_clients_list();
                    $server_info = get_server_info();
                }
                // پردازش عملیات مدیریت سرویس
                elseif ($action === 'start-service' || $action === 'stop-service' || $action === 'restart-service' || $action === 'update-status') {
                    $service_commands = [
                        'start-service' => '/usr/local/bin/wg-service-control start',
                        'stop-service' => '/usr/local/bin/wg-service-control stop',
                        'restart-service' => '/usr/local/bin/wg-service-control restart',
                        'update-status' => '/usr/local/bin/wg-service-control is-active'
                    ];
                    
                    $service_messages = [
                        'start-service' => 'سرویس WireGuard با موفقیت راه‌اندازی شد',
                        'stop-service' => 'سرویس WireGuard با موفقیت متوقف شد',
                        'restart-service' => 'سرویس WireGuard با موفقیت راه‌اندازی مجدد شد',
                        'update-status' => 'وضعیت سرویس به‌روز شد'
                    ];
                    
                    if (isset($service_commands[$action])) {
                        $cmd = "sudo " . $service_commands[$action] . " 2>&1";
                        error_log("Executing service command: $cmd");
                        $result = shell_exec($cmd);
                        error_log("Service command result: " . ($result ?: "empty"));
                        
                        // صبر کنید تا سرویس به طور کامل شروع/متوقف شود
                        if ($action !== 'update-status') {
                            usleep(500000); // 0.5 ثانیه تاخیر
                        }
                        
                        // بروزرسانی وضعیت سرویس
                        $server_info = get_server_info();
                        
                        // بررسی خطا
                        $has_error = false;
                        if ($result !== null && trim($result) !== '') {
                            $out = strtolower($result);
                            $has_error = (strpos($out, 'failed') !== false) || 
                                        (strpos($out, 'error') !== false) ||
                                        (strpos($out, 'inactive') !== false && $action === 'start-service');
                        }
                        
                        if ($has_error) {
                            $admin_message = "خطا در اجرای دستور: " . trim($result);
                        } else {
                            $admin_message = $service_messages[$action];
                        }
                        
                        // بررسی AJAX
                        $is_ajax = isset($_SERVER['HTTP_X_REQUESTED_WITH']) && 
                                   strtolower($_SERVER['HTTP_X_REQUESTED_WITH']) === 'xmlhttprequest';
                        
                        if ($is_ajax) {
                            if (ob_get_level()) {
                                ob_end_clean();
                            }
                            header('Content-Type: application/json; charset=utf-8');
                            echo json_encode([
                                'status' => $has_error ? 'error' : 'success',
                                'message' => $admin_message,
                                'service_status' => $server_info['status']
                            ], JSON_UNESCAPED_UNICODE);
                            exit;
                        }
                    } else {
                        $admin_message = "دستور سرویس نامعتبر است";
                    }
                    
                    // رفرش اطلاعات
                    $clients_list = get_clients_list();
                }
                // سایر عملیات
                else {
                    $admin_cmd = "sudo /usr/local/bin/wg-admin " .
                        escapeshellarg($action) . " " .
                        escapeshellarg($param1) . " " .
                        escapeshellarg($param2) . " " .
                        escapeshellarg($param3);
                    
                    error_log("Executing command: $admin_cmd");
                    $admin_result = shell_exec($admin_cmd . " 2>&1");
                    error_log("Command result: " . ($admin_result ?: "empty"));
                    
                    // Check if command succeeded
                    if ($admin_result !== null && trim($admin_result) !== '') {
                        // Check if result contains error keywords
                        if (stripos($admin_result, 'error') !== false || 
                            stripos($admin_result, 'خطا') !== false ||
                            stripos($admin_result, 'already exists') !== false ||
                            stripos($admin_result, 'not found') !== false ||
                            stripos($admin_result, 'failed') !== false) {
                            $admin_message = "خطا: " . trim($admin_result);
                            error_log("Error detected in result: $admin_message");
                        } else {
                            $admin_message = trim($admin_result);
                        }
                    } else {
                        // If no output, treat as successful
                        $admin_message = "دستور اجرا شد";
                    }
                }

                // رفرش اطلاعات
                $clients_list = get_clients_list();
                $server_info = get_server_info();
            }
        } else {
            $cmd = "sudo /usr/local/bin/wg-client-info " . escapeshellarg($pk);
            $output = shell_exec($cmd . " 2>&1");
            if ($output !== null) {
                // Try to decode JSON. If decoding fails, log and provide a minimal fallback so UI can render
                $data = json_decode($output, true);
                if (json_last_error() !== JSON_ERROR_NONE || !is_array($data)) {
                    error_log("wg-client-info: failed to decode JSON: " . json_last_error_msg() . " -- raw output: " . substr($output, 0, 2000));
                    // Provide safe fallback data so the user panel can still render and show an informative message
                    $data = array(
                        'client_name' => 'کاربر',
                        'ip_address' => '',
                        'data_used' => 0,
                        'remaining_data' => 0,
                        'days_remaining' => 0,
                        'usage_percent' => 0,
                        'data_limit' => 0,
                        'is_active' => false,
                        'server_dns' => '1.1.1.1,8.8.8.8',
                        'server_public_key' => '',
                        'server_endpoint' => ''
                    );
                    $msg = "خطا در پردازش اطلاعات کاربر (خروجی نامعتبر). لطفاً دوباره تلاش کنید.";
                    // Still allow page to render for the user with fallback info
                    $ok = true;
                } elseif (isset($data['status']) && $data['status'] === 'success') {
                    $ok = true;
                    
                    // Store private key in data array for later use
                    $data['private_key'] = $pk;
                    
                    $qr_cmd = "sudo /usr/local/bin/wg-generate-qr " . escapeshellarg($pk);
                    $qr_output = shell_exec($qr_cmd . " 2>&1");
                    if (!empty($qr_output)) {
                        $qr_code = trim($qr_output);
                    }
                    // اگر درخواست دانلود فایل کانفیگ باشد، همین‌جا پاسخ فایل را ارسال می‌کنیم
                    if (isset($_POST['user_action']) && $_POST['user_action'] === 'download-config') {
                        $clientName = preg_replace('/[^A-Za-z0-9_\-\.]/', '_', $data['client_name'] ?? 'client');
                        $filename = $clientName . '.conf';
                        $config = "[Interface]\n" .
                                  "PrivateKey = " . ($pk) . "\n" .
                                  "Address = " . ($data['ip_address'] ?? '') . "/24\n" .
                                  "DNS = " . ($data['server_dns'] ?? '1.1.1.1,8.8.8.8') . "\n" .
                                  "MTU = 1420\n\n" .
                                  "[Peer]\n" .
                                  "PublicKey = " . ($data['server_public_key'] ?? '') . "\n" .
                                  "Endpoint = " . ($data['server_endpoint'] ?? '') . "\n" .
                                  "AllowedIPs = 0.0.0.0/0, ::/0\n" .
                                  "PersistentKeepalive = 25\n";

                        // Clear any previous output buffers
                        while (ob_get_level()) {
                            ob_end_clean();
                        }
                        
                        // ارسال فایل برای دانلود
                        header('Content-Type: application/octet-stream');
                        header('Content-Disposition: attachment; filename="' . $filename . '"');
                        header('Content-Length: ' . strlen($config));
                        header('Cache-Control: no-cache, must-revalidate');
                        header('Expires: 0');
                        echo $config;
                        exit;
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

    // اطلاعات CPU - استفاده از دستور صحیح
    $cpu_usage = @shell_exec("top -bn2 -d 0.5 | grep 'Cpu(s)' | tail -n 1 | awk '{print $2}' | sed 's/%us,//' | sed 's/us,//'");
    if (empty($cpu_usage)) {
        // روش جایگزین با استفاده از mpstat
        $cpu_usage = @shell_exec("grep 'cpu ' /proc/stat | awk '{usage=(\$2+\$4)*100/(\$2+\$4+\$5)} END {print usage}'");
    }
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

// Read last 7 days usage (in GB) for a specific user from /etc/wireguard/usage/YYYY-MM-DD.csv
function get_weekly_usage($user)
{
    $labels = array();
    $data = array();
    if ($user === null) { $user = ''; }

    for ($i = 6; $i >= 0; $i--) {
        $ts = time() - ($i * 86400);
        $date = date('Y-m-d', $ts);
        $labels[] = $date;

        $csv = '/etc/wireguard/usage/' . $date . '.csv';
        $bytes = 0;
        if (is_readable($csv)) {
            $lines = @file($csv, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
            if ($lines !== false) {
                foreach ($lines as $line) {
                    $parts = explode('|', trim($line), 2);
                    if (count($parts) >= 2 && $parts[0] === $user) {
                        // ensure numeric
                        $val = preg_replace('/[^0-9]/', '', (string)$parts[1]);
                        $bytes = is_numeric($val) ? intval($val) : 0;
                        break;
                    }
                }
            }
        }
        // Convert to GB with 2 decimals
        $data[] = round($bytes / (1024 * 1024 * 1024), 2);
    }

    return array('labels' => $labels, 'data' => $data);
}

$server_stats = get_live_server_stats();

// Debug log: help identify why private key div/modal may not show after login
// This logs key state after request processing so you can check PHP error logs.
// Look for lines starting with "wireguard-panel: debug" in your webserver/PHP error log.
if (php_sapi_name() !== 'cli') {
    $dbg_ok = isset($ok) ? ($ok ? '1' : '0') : 'undef';
    $dbg_admin = isset($is_admin) ? ($is_admin ? '1' : '0') : 'undef';
    $dbg_msg = isset($msg) ? $msg : '';
    $dbg_data_keys = '';
    if (isset($data) && is_array($data)) {
        $dbg_data_keys = implode(',', array_keys($data));
    }
    $dbg_private_present = (isset($data['private_key']) && $data['private_key']) ? '1' : '0';
    $dbg_qr = (!empty($qr_code)) ? '1' : '0';
    error_log("wireguard-panel: debug: ok={$dbg_ok}, is_admin={$dbg_admin}, private_key_present={$dbg_private_present}, qr={$dbg_qr}, data_keys={$dbg_data_keys}, msg=" . substr($dbg_msg,0,1000));
}

// برای نمایش HTML، header را تنظیم کنیم
header('Content-Type: text/html; charset=utf-8');
?>
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <script src="https://cdn.jsdelivr.net/npm/chart.js"></script>
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
    <title>پنل حرفه‌ای مدیریت WireGuard</title>
    <style>
        :root {
            --primary: #6366f1;
            --primary-dark: #4f46e5;
            --secondary: #10b981;
            --danger: #ef4444;
            --warning: #f59e0b;
            --dark: #1e293b;
            --darker: #0f172a;
            --light: #f8fafc;
            --gray: #64748b;
            --card-bg: rgba(30, 41, 59, 0.7);
            --card-border: rgba(255, 255, 255, 0.1);
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
            font-family: 'Vazir', 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
        }

        body {
            background: linear-gradient(135deg, var(--darker) 0%, var(--dark) 100%);
            color: var(--light);
            line-height: 1.6;
            min-height: 100vh;
            padding: 0;
            overflow-x: hidden;
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
            padding: 20px;
        }

        /* Header Styles */
        .header {
            background: var(--card-bg);
            backdrop-filter: blur(10px);
            border-radius: 20px;
            padding: 25px 30px;
            margin-bottom: 30px;
            border: 1px solid var(--card-border);
            box-shadow: 0 10px 25px rgba(0, 0, 0, 0.2);
            display: flex;
            justify-content: space-between;
            align-items: center;
        }

        .logo {
            display: flex;
            align-items: center;
            gap: 15px;
        }

        .logo-icon {
            width: 50px;
            height: 50px;
            background: linear-gradient(135deg, var(--primary), var(--primary-dark));
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 24px;
        }

        .logo-text h1 {
            font-size: 1.8em;
            margin-bottom: 5px;
            background: linear-gradient(135deg, var(--primary), #8b5cf6);
            background-clip: text;
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }

        .logo-text p {
            color: var(--gray);
            font-size: 0.9em;
        }

        .user-badge {
            background: rgba(16, 185, 129, 0.1);
            border: 1px solid rgba(16, 185, 129, 0.3);
            border-radius: 50px;
            padding: 8px 20px;
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: 0.9em;
        }

        .admin-badge {
            background: rgba(99, 102, 241, 0.1);
            border: 1px solid rgba(99, 102, 241, 0.3);
            border-radius: 50px;
            padding: 8px 20px;
            display: flex;
            align-items: center;
            gap: 8px;
            font-size: 0.9em;
        }

        /* Card Styles */
        .card {
            background: var(--card-bg);
            backdrop-filter: blur(10px);
            border-radius: 20px;
            padding: 25px;
            margin-bottom: 25px;
            border: 1px solid var(--card-border);
            box-shadow: 0 8px 20px rgba(0, 0, 0, 0.15);
            transition: transform 0.3s ease, box-shadow 0.3s ease;
        }

        .card:hover {
            transform: translateY(-5px);
            box-shadow: 0 12px 25px rgba(0, 0, 0, 0.25);
        }

        .card-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 20px;
        }

        .card-title {
            font-size: 1.4em;
            display: flex;
            align-items: center;
            gap: 10px;
        }

        .card-title i {
            color: var(--primary);
        }

        /* Form Styles */
        .form-group {
            margin-bottom: 20px;
        }

        .form-label {
            display: block;
            margin-bottom: 8px;
            font-weight: 500;
            color: var(--gray);
        }

        .form-input {
            width: 100%;
            padding: 15px 20px;
            border-radius: 12px;
            border: 1px solid rgba(255, 255, 255, 0.1);
            background: rgba(15, 23, 42, 0.7);
            color: var(--light);
            font-size: 16px;
            transition: all 0.3s ease;
        }

        .form-input:focus {
            outline: none;
            border-color: var(--primary);
            box-shadow: 0 0 0 3px rgba(99, 102, 241, 0.2);
        }

        .btn {
            display: inline-flex;
            align-items: center;
            justify-content: center;
            gap: 8px;
            padding: 15px 25px;
            border-radius: 12px;
            border: none;
            font-size: 16px;
            font-weight: 600;
            cursor: pointer;
            transition: all 0.3s ease;
            text-decoration: none;
        }

        .btn-primary {
            background: linear-gradient(135deg, var(--primary), var(--primary-dark));
            color: white;
        }

        .btn-primary:hover {
            transform: translateY(-2px);
            box-shadow: 0 7px 15px rgba(99, 102, 241, 0.4);
        }

        .btn-success {
            background: linear-gradient(135deg, var(--secondary), #059669);
            color: white;
        }

        .btn-success:hover {
            transform: translateY(-2px);
            box-shadow: 0 7px 15px rgba(16, 185, 129, 0.4);
        }

        .btn-warning {
            background: linear-gradient(135deg, var(--warning), #d97706);
            color: white;
        }

        .btn-warning:hover {
            transform: translateY(-2px);
            box-shadow: 0 7px 15px rgba(245, 158, 11, 0.4);
        }

        .btn-danger {
            background: linear-gradient(135deg, var(--danger), #dc2626);
            color: white;
        }

        .btn-danger:hover {
            transform: translateY(-2px);
            box-shadow: 0 7px 15px rgba(239, 68, 68, 0.4);
        }

        .btn-block {
            width: 100%;
        }

        /* Stats Grid */
        .stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin-bottom: 25px;
        }

        .stat-card {
            background: var(--card-bg);
            border-radius: 16px;
            padding: 20px;
            border: 1px solid var(--card-border);
            display: flex;
            align-items: center;
            gap: 15px;
            transition: transform 0.3s ease;
        }

        .stat-card:hover {
            transform: translateY(-5px);
        }

        .stat-icon {
            width: 60px;
            height: 60px;
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 24px;
        }

        .stat-icon.primary {
            background: rgba(99, 102, 241, 0.2);
            color: var(--primary);
        }

        .stat-icon.success {
            background: rgba(16, 185, 129, 0.2);
            color: var(--secondary);
        }

        .stat-icon.warning {
            background: rgba(245, 158, 11, 0.2);
            color: var(--warning);
        }

        .stat-icon.danger {
            background: rgba(239, 68, 68, 0.2);
            color: var(--danger);
        }

        .stat-info {
            flex: 1;
        }

        .stat-value {
            font-size: 1.8em;
            font-weight: 700;
            margin-bottom: 5px;
        }

        .stat-label {
            color: var(--gray);
            font-size: 0.9em;
        }

        /* Usage Progress */
        .usage-card {
            position: relative;
            overflow: hidden;
        }

        .usage-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
        }

        .usage-percent {
            font-size: 2.5em;
            font-weight: 700;
            background: linear-gradient(135deg, var(--primary), #8b5cf6);
            background-clip: text;
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }

        .progress-container {
            height: 12px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 10px;
            overflow: hidden;
            margin: 20px 0;
        }

        .progress-bar {
            height: 100%;
            border-radius: 10px;
            background: linear-gradient(90deg, var(--primary), var(--primary-dark));
            position: relative;
            transition: width 1s ease-in-out;
        }

        .progress-bar::after {
            content: '';
            position: absolute;
            top: 0;
            left: 0;
            bottom: 0;
            right: 0;
            background-image: linear-gradient(
                -45deg,
                rgba(255, 255, 255, 0.2) 25%,
                transparent 25%,
                transparent 50%,
                rgba(255, 255, 255, 0.2) 50%,
                rgba(255, 255, 255, 0.2) 75%,
                transparent 75%,
                transparent
            );
            background-size: 20px 20px;
            animation: move 1s linear infinite;
        }

        @keyframes move {
            0% {
                background-position: 0 0;
            }
            100% {
                background-position: 20px 0;
            }
        }

        .usage-details {
            display: flex;
            justify-content: space-between;
            margin-top: 10px;
            color: var(--gray);
            font-size: 0.9em;
        }

        /* Config Section */
        .config-container {
            position: relative;
        }

        .config-content {
            background: rgba(15, 23, 42, 0.8);
            border-radius: 12px;
            padding: 20px;
            font-family: 'Courier New', monospace;
            font-size: 14px;
            line-height: 1.5;
            max-height: 200px;
            overflow-y: auto;
            direction: ltr;
            text-align: left;
            border: 1px solid rgba(255, 255, 255, 0.05);
        }

        .config-actions {
            display: flex;
            gap: 10px;
            margin-top: 15px;
        }

        /* QR Section */
        .qr-section {
            text-align: center;
        }

        .qr-container {
            display: inline-block;
            padding: 20px;
            background: white;
            border-radius: 16px;
            box-shadow: 0 10px 25px rgba(0, 0, 0, 0.2);
            margin: 15px 0;
        }

        .qr-image {
            max-width: 220px;
            border-radius: 8px;
        }

        /* Tabs */
        .tabs {
            display: flex;
            background: rgba(15, 23, 42, 0.7);
            border-radius: 12px;
            padding: 5px;
            margin-bottom: 20px;
        }

        .tab {
            flex: 1;
            text-align: center;
            padding: 12px;
            border-radius: 10px;
            cursor: pointer;
            transition: all 0.3s ease;
        }

        .tab.active {
            background: var(--primary);
        }

        .tab-content {
            display: none;
        }

        .tab-content.active {
            display: block;
        }

        /* Status Indicators */
        .status-badge {
            display: inline-flex;
            align-items: center;
            gap: 6px;
            padding: 6px 12px;
            border-radius: 50px;
            font-size: 0.85em;
            font-weight: 500;
        }

        .status-active {
            background: rgba(16, 185, 129, 0.15);
            color: var(--secondary);
        }

        .status-inactive {
            background: rgba(239, 68, 68, 0.15);
            color: var(--danger);
        }

        /* Table Styles */
        .table-container {
            overflow-x: auto;
            margin: 15px 0;
            border-radius: 12px;
            border: 1px solid var(--card-border);
        }

        table {
            width: 100%;
            border-collapse: collapse;
            background: var(--card-bg);
        }

        th, td {
            padding: 12px 15px;
            text-align: center;
            border-bottom: 1px solid rgba(255, 255, 255, 0.1);
        }

        th {
            background: rgba(99, 102, 241, 0.1);
            color: var(--primary);
            font-weight: 600;
        }

        tr:hover {
            background: rgba(255, 255, 255, 0.05);
        }

        .key-container {
            display: flex;
            align-items: center;
            gap: 8px;
            justify-content: center;
        }

        .private-key {
            font-family: 'Courier New', monospace;
            font-size: 12px;
            background: rgba(15, 23, 42, 0.8);
            color: var(--primary);
            border: 1px solid rgba(99, 102, 241, 0.3);
            border-radius: 6px;
            padding: 6px 10px;
            width: 150px;
            direction: ltr;
            text-align: left;
        }

        .copy-btn {
            background: var(--primary);
            color: white;
            border: none;
            border-radius: 6px;
            padding: 6px 10px;
            cursor: pointer;
            transition: background 0.3s;
        }

        .copy-btn:hover {
            background: var(--primary-dark);
        }

        /* Server Stats */
        .server-stats-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(250px, 1fr));
            gap: 20px;
            margin: 20px 0;
        }

        .server-stat-card {
            background: var(--card-bg);
            border-radius: 16px;
            padding: 20px;
            text-align: center;
            border: 1px solid var(--card-border);
        }

        .server-stat-card .icon {
            font-size: 2em;
            margin-bottom: 10px;
        }

        .server-stat-card .value {
            font-size: 1.5em;
            font-weight: 700;
            margin: 10px 0;
        }

        .server-stat-card .label {
            color: var(--gray);
            font-size: 0.9em;
        }

        .server-progress {
            height: 8px;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 4px;
            margin: 10px 0;
            overflow: hidden;
        }

        .server-progress .progress {
            height: 100%;
            border-radius: 4px;
        }

        .progress.cpu { background: linear-gradient(90deg, #4fc3f7, #2196f3); }
        .progress.memory { background: linear-gradient(90deg, #66bb6a, #4caf50); }
        .progress.disk { background: linear-gradient(90deg, #ff9800, #f57c00); }
        .progress.network { background: linear-gradient(90deg, #9c27b0, #7b1fa2); }

        /* Form Rows */
        .form-row {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 15px;
        }

        /* Admin Sections */
        .admin-section {
            margin: 20px 0;
            padding: 20px;
            background: rgba(255, 255, 255, 0.05);
            border-radius: 12px;
        }

        /* Search Box */
        .search-box {
            position: relative;
            margin-bottom: 20px;
        }

        .search-box input {
            padding-right: 40px;
        }

        .search-icon {
            position: absolute;
            right: 15px;
            top: 50%;
            transform: translateY(-50%);
            color: var(--gray);
        }

        /* Edit Form */
        .edit-form {
            display: none;
            background: rgba(255, 255, 255, 0.05);
            padding: 20px;
            border-radius: 12px;
            margin: 15px 0;
        }

        /* Controls */
        .controls {
            display: flex;
            gap: 8px;
            flex-wrap: wrap;
            justify-content: center;
        }

        /* Message Styles */
        .message {
            padding: 15px;
            border-radius: 12px;
            margin: 15px 0;
            text-align: center;
        }

        .message.error {
            background: rgba(239, 68, 68, 0.1);
            border: 1px solid rgba(239, 68, 68, 0.3);
            color: var(--danger);
        }

        .message.success {
            background: rgba(16, 185, 129, 0.1);
            border: 1px solid rgba(16, 185, 129, 0.3);
            color: var(--secondary);
        }

        .message.warning {
            background: rgba(245, 158, 11, 0.1);
            border: 1px solid rgba(245, 158, 11, 0.3);
            color: var(--warning);
        }

        /* Help Text */
        .help {
            font-size: 0.9em;
            color: var(--gray);
            margin-top: 10px;
            text-align: center;
        }

        /* Chart Container */
        .chart-container {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 12px;
            padding: 20px;
            margin: 20px 0;
        }

        .chart-header {
            margin-bottom: 15px;
            text-align: center;
        }

        .chart-header h2 {
            color: var(--primary);
            margin: 0;
        }

        /* Modal */
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
            background: var(--darker);
            color: var(--light);
            border-radius: 12px;
            max-width: 600px;
            width: 100%;
            padding: 20px;
            box-shadow: 0 10px 25px rgba(0, 0, 0, 0.3);
            border: 1px solid var(--card-border);
        }

        .modal-header {
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 15px;
        }

        .modal-body {
            background: rgba(15, 23, 42, 0.8);
            padding: 15px;
            border-radius: 8px;
            font-family: 'Courier New', monospace;
            direction: ltr;
            word-break: break-all;
            max-height: 300px;
            overflow-y: auto;
        }

        .modal-actions {
            margin-top: 15px;
            display: flex;
            gap: 10px;
            justify-content: flex-end;
        }

        /* Footer */
        .footer {
            text-align: center;
            margin-top: 40px;
            padding: 20px;
            color: var(--gray);
            font-size: 0.9em;
            border-top: 1px solid rgba(255, 255, 255, 0.05);
        }

        /* App Download Section */
        .app-download-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
            gap: 20px;
            margin: 20px 0;
        }

        .app-download-card {
            background: rgba(255, 255, 255, 0.05);
            border: 1px solid var(--card-border);
            border-radius: 16px;
            padding: 20px;
            display: flex;
            align-items: center;
            gap: 15px;
            text-decoration: none;
            color: var(--light);
            transition: all 0.3s ease;
            cursor: pointer;
        }

        .app-download-card:hover {
            background: rgba(255, 255, 255, 0.08);
            transform: translateY(-3px);
            box-shadow: 0 8px 20px rgba(0, 0, 0, 0.2);
            border-color: var(--primary);
        }

        .app-icon {
            width: 60px;
            height: 60px;
            border-radius: 12px;
            display: flex;
            align-items: center;
            justify-content: center;
            font-size: 28px;
            background: rgba(99, 102, 241, 0.2);
            color: var(--primary);
            flex-shrink: 0;
        }

        .app-info {
            flex: 1;
        }

        .app-info h3 {
            margin: 0 0 5px 0;
            font-size: 1.1em;
            color: var(--light);
        }

        .app-info p {
            margin: 0;
            color: var(--gray);
            font-size: 0.9em;
        }

        .app-arrow {
            font-size: 20px;
            color: var(--primary);
            transition: transform 0.3s ease;
        }

        .app-download-card:hover .app-arrow {
            transform: translateX(-5px);
        }

        /* Responsive */
        @media (max-width: 768px) {
            .header {
                flex-direction: column;
                gap: 15px;
                text-align: center;
            }

            .stats-grid {
                grid-template-columns: 1fr;
            }

            .form-row {
                grid-template-columns: 1fr;
            }

            .config-actions {
                flex-direction: column;
            }

            .tabs {
                flex-direction: column;
                gap: 5px;
            }

            .controls {
                flex-direction: column;
            }

            .private-key {
                width: 120px;
                font-size: 10px;
            }

            .app-download-grid {
                grid-template-columns: 1fr;
            }

            .app-download-card {
                padding: 15px;
            }

            .app-icon {
                width: 50px;
                height: 50px;
                font-size: 24px;
            }

            .app-info h3 {
                font-size: 1em;
            }
        }

        /* Animations */
        @keyframes fadeIn {
            from { opacity: 0; transform: translateY(20px); }
            to { opacity: 1; transform: translateY(0); }
        }

        .fade-in {
            animation: fadeIn 0.5s ease forwards;
        }

        .delay-1 { animation-delay: 0.1s; }
        .delay-2 { animation-delay: 0.2s; }
        .delay-3 { animation-delay: 0.3s; }
        .delay-4 { animation-delay: 0.4s; }

        /* استایل‌های پیام */
        .error-message {
            color: #ef4444;
            font-weight: bold;
            margin-top: 10px;
        }

        .success-message {
            color: #10b981;
            font-weight: bold;
            margin-top: 10px;
        }

        .modal-backdrop {
            position: fixed;
            inset: 0;
            background: rgba(0, 0, 0, 0.7);
            display: none;
            align-items: center;
            justify-content: center;
            z-index: 10000;
            padding: 20px;
            backdrop-filter: blur(5px);
        }

        .modal {
            background: var(--darker);
            color: var(--light);
            border-radius: 16px;
            max-width: 500px;
            width: 100%;
            max-height: 90vh;
            overflow-y: auto;
            padding: 25px;
            box-shadow: 0 20px 40px rgba(0, 0, 0, 0.5);
            border: 1px solid var(--card-border);
            animation: modalSlideIn 0.3s ease;
        }

        @keyframes modalSlideIn {
            from {
                opacity: 0;
                transform: translateY(-30px) scale(0.9);
            }
            to {
                opacity: 1;
                transform: translateY(0) scale(1);
            }
        }

        /* Scrollbar */
        ::-webkit-scrollbar {
            width: 8px;
        }

        ::-webkit-scrollbar-track {
            background: rgba(255, 255, 255, 0.05);
            border-radius: 10px;
        }

        ::-webkit-scrollbar-thumb {
            background: var(--primary);
            border-radius: 10px;
        }

        ::-webkit-scrollbar-thumb:hover {
            background: var(--primary-dark);
        }

        /* استایل تب‌های مدیریت (admin-tabs) */
        .admin-tabs {
            display: flex;
            background: rgba(15, 23, 42, 0.7);
            border-radius: 12px;
            padding: 5px;
            margin-bottom: 20px;
            flex-wrap: wrap;
        }

        .admin-tabs .tab {
            flex: 1;
            min-width: 150px;
            text-align: center;
            padding: 12px 15px;
            border-radius: 10px;
            cursor: pointer;
            transition: all 0.3s ease;
            margin: 2px;
        }

        .admin-tabs .tab.active {
            background: var(--primary);
            box-shadow: 0 4px 12px rgba(99, 102, 241, 0.3);
        }

        .admin-tabs .tab:hover:not(.active) {
            background: rgba(99, 102, 241, 0.2);
        }

        .admin-tab-content {
            display: none;
            animation: fadeIn 0.5s ease;
        }

        .admin-tab-content.active {
            display: block;
        }

        @media (max-width: 768px) {
            .admin-tabs {
                flex-direction: column;
            }
            
            .admin-tabs .tab {
                min-width: auto;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <!-- Header -->
        <header class="header fade-in">
            <div class="logo">
                <div class="logo-icon">
                    <i class="fas fa-shield-alt"></i>
                </div>
                <div class="logo-text">
                    <h1>پنل حرفه‌ای WireGuard</h1>
                    <p>مدیریت پیشرفته کاربران و اتصالات</p>
                </div>
            </div>
            <?php if ($ok && $data): ?>
            <div style="display: flex; align-items: center; gap: 15px;">
                <div class="<?php echo $is_admin ? 'admin-badge' : 'user-badge'; ?>">
                    <i class="fas fa-<?php echo $is_admin ? 'crown' : 'user-check'; ?>"></i>
                    <span><?php echo $is_admin ? 'دسترسی مدیر' : 'کاربر: ' . h($data['client_name']); ?></span>
                </div>
                <a href="<?php echo htmlspecialchars($_SERVER['PHP_SELF']); ?>" class="btn btn-danger" style="padding: 8px 16px; text-decoration: none;">
                    <i class="fas fa-sign-out-alt"></i> خروج
                </a>
            </div>
            <?php endif; ?>
        </header>

        <?php if (!$ok || !$data): ?>
        <!-- Login Card - فقط وقتی لاگین نشده نمایش داده می‌شود -->
        <div class="card fade-in delay-1">
            <div class="card-header">
                <h2 class="card-title"><i class="fas fa-key"></i> احراز هویت</h2>
            </div>
            <form method="post" id="loginForm">
                <div class="form-group">
                    <input type="text" name="pk" id="pkInput" class="form-input" 
                           value="<?php echo isset($_POST['pk']) ? h($_POST['pk']) : ''; ?>" 
                           placeholder="کلید خصوصی خود را اینجا وارد کنید..." 
                           required 
                           minlength="40"
                           pattern="[A-Za-z0-9+/=]+"
                           title="کلید خصوصی باید حداقل 40 کاراکتر Base64 باشد"
                           autocomplete="off">
                </div>
                <button type="submit" id="loginBtn" class="btn btn-primary btn-block">
                    <i class="fas fa-sign-in-alt"></i> ورود به پنل
                </button>
            </form>
            <div class="help">
                PrivateKey را از فایل کانفیگ خود کپی کرده و در فیلد بالا قرار دهید.
            </div>
            
            <?php if (!empty($msg)): ?>
            <!-- پیغام خطا در همان صفحه ورود -->
            <div class="message error" style="margin-top: 20px;">
                <i class="fas fa-exclamation-circle"></i>
                <?php echo h($msg); ?>
            </div>
            <?php endif; ?>
        </div>
        <?php endif; ?>

        <?php if ($ok && $data): ?>
            <?php if ($is_admin): ?>
    <!-- پنل مدیریت با تب‌ها -->
    <div class="fade-in delay-2">
        <!-- تب‌های مدیریت -->
        <div class="tabs admin-tabs">
            <div class="tab active" onclick="switchAdminTab('dashboard', event)">
                <i class="fas fa-tachometer-alt"></i> پیشخوان
            </div>
            <div class="tab" onclick="switchAdminTab('users', event)">
                <i class="fas fa-users-cog"></i> مدیریت کاربران
            </div>
            <div class="tab" onclick="switchAdminTab('settings', event)">
                <i class="fas fa-cogs"></i> تنظیمات سرور
            </div>
            <div class="tab" onclick="switchAdminTab('backup', event)">
                <i class="fas fa-database"></i> پشتیبان‌گیری
            </div>
        </div>

        <?php if (!empty($admin_message)): ?>
            <div class="message <?php echo contains_error($admin_message) ? 'error' : 'success'; ?> fade-in">
                <?php echo h($admin_message); ?>
            </div>
        <?php endif; ?>

        <!-- تب پیشخوان -->
        <div id="dashboard-tab" class="admin-tab-content active">
            <!-- اطلاعات سرور -->
            <div class="admin-section">
                <h3><i class="fas fa-server"></i> اطلاعات سرور</h3>
                <div class="stats-grid">
                    <div class="stat-card">
                        <div class="stat-icon primary">
                            <i class="fas fa-network-wired"></i>
                        </div>
                        <div class="stat-info">
                            <div class="stat-value"><?php echo h($server_info['endpoint'] ?? 'N/A'); ?></div>
                            <div class="stat-label">آدرس سرور</div>
                        </div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-icon success">
                            <i class="fas fa-globe"></i>
                        </div>
                        <div class="stat-info">
                            <div class="stat-value"><?php echo h($server_info['dns'] ?? 'N/A'); ?></div>
                            <div class="stat-label">DNS سرورها</div>
                        </div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-icon warning">
                            <i class="fas fa-users"></i>
                        </div>
                        <div class="stat-info">
                            <div class="stat-value"><?php echo count($clients_list); ?></div>
                            <div class="stat-label">تعداد کاربران</div>
                        </div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-icon <?php echo ($server_info['status'] === 'active') ? 'success' : 'danger'; ?>">
                            <i class="fas fa-power-off"></i>
                        </div>
                        <div class="stat-info">
                            <div id="dashboard-service-status" class="stat-value"><?php echo ($server_info['status'] === 'active') ? 'فعال' : 'غیرفعال'; ?></div>
                            <div class="stat-label">وضعیت سرویس</div>
                            <button type="button" onclick="updateDashboardServiceStatus()" class="btn btn-info" style="margin-top: 10px; padding: 5px 10px; font-size: 12px;">
                                <i class="fas fa-sync-alt"></i> بروزرسانی
                            </button>
                        </div>
                    </div>
                </div>
            </div>

            <!-- آمار لحظه‌ای سرور -->
            <div class="card">
                <div class="card-header">
                    <h2 class="card-title"><i class="fas fa-chart-bar"></i> آمار لحظه‌ای سرور</h2>
                </div>
                <div class="server-stats-grid">
                    <div class="server-stat-card">
                        <div class="icon">⚡</div>
                        <div class="label">مصرف CPU</div>
                        <div class="value"><?php echo $server_stats['cpu_usage']; ?>%</div>
                        <div class="server-progress">
                            <div class="progress cpu" style="width: <?php echo $server_stats['cpu_usage']; ?>%"></div>
                        </div>
                    </div>
                    <div class="server-stat-card">
                        <div class="icon">🧠</div>
                        <div class="label">مصرف حافظه</div>
                        <div class="value"><?php echo $server_stats['memory_usage']; ?>%</div>
                        <div class="server-progress">
                            <div class="progress memory" style="width: <?php echo $server_stats['memory_usage']; ?>%"></div>
                        </div>
                        <div class="help"><?php echo $server_stats['memory_used']; ?>MB / <?php echo $server_stats['memory_total']; ?>MB</div>
                    </div>
                    <div class="server-stat-card">
                        <div class="icon">💾</div>
                        <div class="label">مصرف دیسک</div>
                        <div class="value"><?php echo $server_stats['disk_usage']; ?>%</div>
                        <div class="server-progress">
                            <div class="progress disk" style="width: <?php echo $server_stats['disk_usage']; ?>%"></div>
                        </div>
                    </div>
                    <div class="server-stat-card">
                        <div class="icon">🌐</div>
                        <div class="label">ترافیک شبکه</div>
                        <div class="value"><?php echo $server_stats['network_rx']; ?>MB / <?php echo $server_stats['network_tx']; ?>MB</div>
                        <div class="server-progress">
                            <div class="progress network" style="width: 50%"></div>
                        </div>
                        <div class="help">دانلود / آپلود</div>
                    </div>
                </div>
                <div class="help">
                    آپ‌تایم سرور: <?php echo $server_stats['uptime']; ?>
                </div>
            </div>

            <!-- خلاصه کاربران -->
            <div class="card">
                <div class="card-header">
                    <h2 class="card-title"><i class="fas fa-users"></i> خلاصه کاربران</h2>
                    <span class="status-badge status-active">
                        <i class="fas fa-circle"></i>
                        <?php echo count($clients_list); ?> کاربر
                    </span>
                </div>
                <div class="stats-grid">
                    <?php
                    $active_users = array_filter($clients_list, function($client) {
                        return $client['active'];
                    });
                    $inactive_users = array_filter($clients_list, function($client) {
                        return !$client['active'];
                    });
                    $near_limit_users = array_filter($clients_list, function($client) {
                        return $client['remaining_gb'] !== '∞' && $client['remaining_gb'] < 1 && $client['remaining_gb'] > 0;
                    });
                    $expired_users = array_filter($clients_list, function($client) {
                        return $client['days_remaining'] !== '∞' && $client['days_remaining'] <= 0;
                    });
                    ?>
                    <div class="stat-card">
                        <div class="stat-icon success">
                            <i class="fas fa-user-check"></i>
                        </div>
                        <div class="stat-info">
                            <div class="stat-value"><?php echo count($active_users); ?></div>
                            <div class="stat-label">کاربران فعال</div>
                        </div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-icon danger">
                            <i class="fas fa-user-times"></i>
                        </div>
                        <div class="stat-info">
                            <div class="stat-value"><?php echo count($inactive_users); ?></div>
                            <div class="stat-label">کاربران غیرفعال</div>
                        </div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-icon warning">
                            <i class="fas fa-exclamation-triangle"></i>
                        </div>
                        <div class="stat-info">
                            <div class="stat-value"><?php echo count($near_limit_users); ?></div>
                            <div class="stat-label">نزدیک به پایان سهمیه</div>
                        </div>
                    </div>
                    <div class="stat-card">
                        <div class="stat-icon danger">
                            <i class="fas fa-clock"></i>
                        </div>
                        <div class="stat-info">
                            <div class="stat-value"><?php echo count($expired_users); ?></div>
                            <div class="stat-label">منقضی شده</div>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- تب مدیریت کاربران -->
        <div id="users-tab" class="admin-tab-content">
            <div class="admin-section">
                <h3><i class="fas fa-users-cog"></i> مدیریت کاربران</h3>
                
                <div class="stats-grid">
                    <!-- افزودن کاربر جدید -->
                    <div class="card">
                        <div class="card-header">
                            <h2 class="card-title"><i class="fas fa-user-plus"></i> افزودن کاربر جدید</h2>
                        </div>
                        <form method="post">
                            <input type="hidden" name="pk" id="addUserPk" value="<?php echo h($_POST['pk'] ?? ''); ?>">
                            <input type="hidden" name="admin_action" value="add-client">
                            <div class="form-group">
                                <input type="text" name="param1" id="addUserName" class="form-input" placeholder="نام کاربر" required>
                            </div>
                            <div class="form-row">
                                <input type="number" name="param2" id="addUserGB" class="form-input" placeholder="سهمیه (GB)" min="0" step="0.1" required>
                                <input type="number" name="param3" id="addUserDays" class="form-input" placeholder="مدت (روز)" min="1" required>
                            </div>
                            <button type="button" id="addUserBtn" class="btn btn-success btn-block">افزودن کاربر</button>
                        </form>
                        <div id="addUserMsg" style="margin-top:10px;color:#d43f3a;font-weight:bold;"></div>
                    </div>

                    <!-- ویرایش کاربر -->
                    <div class="card">
                        <div class="card-header">
                            <h2 class="card-title"><i class="fas fa-user-edit"></i> ویرایش کاربر</h2>
                        </div>
                        <div id="editForm" class="edit-form" style="display: none;">
                            <div style="margin-bottom: 15px;">
                                <label style="display: block; margin-bottom: 5px; font-weight: bold;">نام کاربر:</label>
                                <input type="text" id="editClientName" class="form-input" readonly style="background: rgba(255,255,255,0.1);">
                            </div>
                            <div class="form-row">
                                <div style="flex: 1;">
                                    <label style="display: block; margin-bottom: 5px;">سهمیه جدید (GB):</label>
                                    <input type="number" id="editClientGB" class="form-input" placeholder="سهمیه جدید (GB)" min="0" step="0.1" required>
                                </div>
                                <div style="flex: 1;">
                                    <label style="display: block; margin-bottom: 5px;">مدت جدید (روز):</label>
                                    <input type="number" id="editClientDays" class="form-input" placeholder="مدت جدید (روز)" min="1" required>
                                </div>
                            </div>
                            <input type="hidden" id="editClientPk" value="<?php echo h($_POST['pk'] ?? ''); ?>">
                            <div class="controls" style="margin-top: 15px;">
                                <button type="button" onclick="submitEditClient()" class="btn btn-warning">
                                    <i class="fas fa-save"></i> ذخیره تغییرات
                                </button>
                                <button type="button" onclick="hideEditForm()" class="btn btn-primary">
                                    <i class="fas fa-times"></i> انصراف
                                </button>
                            </div>
                            <div id="editClientMsg" style="margin-top: 10px;"></div>
                        </div>
                        <div class="help">برای ویرایش کاربر، از لیست زیر روی دکمه ویرایش کلیک کنید</div>
                    </div>
                </div>

                <!-- جستجو و لیست کاربران -->
                <div class="card">
                    <div class="card-header">
                        <h2 class="card-title"><i class="fas fa-list"></i> لیست کاربران</h2>
                        <div class="search-box">
                            <input type="text" id="searchUsers" class="form-input" placeholder="جستجوی کاربر..." onkeyup="searchUsers()">
                            <span class="search-icon"><i class="fas fa-search"></i></span>
                        </div>
                    </div>

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
                                                    <button class="copy-btn" onclick="copyToClipboard(this)"><i class="fas fa-copy"></i></button>
                                                    <button class="btn btn-primary" onclick="showKeyModal('<?php echo h($client['private_key']); ?>')" style="padding: 6px 10px;"><i class="fas fa-eye"></i></button>
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
                                            <td>
                                                <span class="status-badge <?php echo $client['active'] ? 'status-active' : 'status-inactive'; ?>">
                                                    <i class="fas fa-circle"></i>
                                                    <?php echo $client['active'] ? 'فعال' : 'غیرفعال'; ?>
                                                </span>
                                            </td>
                                            <td>
                                                <div class="controls">
                                                    <?php
                                                    $client_name_escaped = str_replace("'", "\\'", $client['name']);
                                                    ?>
                                                    <button type="button" onclick="showEditForm('<?php echo $client_name_escaped; ?>', <?php echo h($client['limit_gb']); ?>, <?php echo ($client['days_remaining'] === '∞' ? 0 : h($client['days_remaining'])); ?>)"
                                                        class="btn btn-warning" style="padding: 8px 12px;">
                                                        <i class="fas fa-edit"></i>
                                                    </button>
                                                    <button type="button" onclick="if(confirm('آیا از حذف کاربر <?php echo $client_name_escaped; ?> مطمئن هستید؟')) sendAdminAction('remove-client', '<?php echo $client_name_escaped; ?>')" 
                                                        class="btn btn-danger" style="padding: 8px 12px;">
                                                        <i class="fas fa-trash"></i>
                                                    </button>
                                                </div>
                                            </td>
                                        </tr>
                                    <?php endforeach; ?>
                                <?php else: ?>
                                    <tr>
                                        <td colspan="10" style="text-align:center;padding:20px;">
                                            <i class="fas fa-users" style="font-size: 2em; margin-bottom: 10px; display: block; color: var(--gray);"></i>
                                            هیچ کاربری یافت نشد. اولین کاربر را اضافه کنید.
                                        </td>
                                    </tr>
                                <?php endif; ?>
                            </tbody>
                        </table>
                    </div>
                </div>

                <!-- دکمه رفرش -->
                <div class="card">
                    <button type="button" onclick="refreshUserList()" class="btn btn-primary btn-block">
                        <i class="fas fa-sync-alt"></i> بروزرسانی لیست کاربران
                    </button>
                </div>
            </div>
        </div>

        <!-- تب تنظیمات سرور -->
        <div id="settings-tab" class="admin-tab-content">
            <div class="admin-section">
                <h3><i class="fas fa-cogs"></i> تنظیمات سرور</h3>
                
                <div class="stats-grid">
                    <!-- تنظیم Endpoint و DNS -->
                    <div class="card">
                        <div class="card-header">
                            <h2 class="card-title"><i class="fas fa-network-wired"></i> تنظیم Endpoint و DNS</h2>
                        </div>
                        <form id="endpoint-form" method="post">
                            <input type="hidden" name="pk" value="<?php echo h($_POST['pk'] ?? ''); ?>">
                            <input type="hidden" name="admin_action" value="set-endpoint">
                            <?php
                            $current_endpoint = $server_info['endpoint'] ?? 'SERVER_IP:1010';
                            $endpoint_parts = explode(':', $current_endpoint);
                            $current_domain = $endpoint_parts[0] ?? '';
                            $current_port = $endpoint_parts[1] ?? '1010';
                            $current_dns = $server_info['dns'] ?? '1.1.1.1,8.8.8.8';
                            ?>
                            <div class="form-group">
                                <input type="text" id="endpoint-domain" name="param1" class="form-input" placeholder="دامنه یا IP سرور" required value="<?php echo h($current_domain); ?>">
                            </div>
                            <div class="form-row">
                                <input type="number" id="endpoint-port" name="param2" class="form-input" placeholder="پورت" min="1" max="65535" required value="<?php echo h($current_port); ?>">
                                <input type="text" id="endpoint-dns" name="param3" class="form-input" placeholder="DNS سرورها" required value="<?php echo h($current_dns); ?>">
                            </div>
                            <button type="submit" class="btn btn-primary btn-block">بروزرسانی تنظیمات</button>
                        </form>
                    </div>

                    <!-- مدیریت سرویس -->
                    <div class="card">
                        <div class="card-header">
                            <h2 class="card-title"><i class="fas fa-power-off"></i> مدیریت سرویس</h2>
                        </div>
                        <div class="controls" style="justify-content: center; gap: 15px; padding: 20px;">
                            <button type="button" onclick="handleServiceAction('start-service')" class="btn btn-success">
                                <i class="fas fa-play"></i> راه‌اندازی سرویس
                            </button>
                            <button type="button" onclick="handleServiceAction('stop-service')" class="btn btn-danger">
                                <i class="fas fa-stop"></i> توقف سرویس
                            </button>
                            <button type="button" onclick="handleServiceAction('restart-service')" class="btn btn-warning">
                                <i class="fas fa-redo"></i> راه‌اندازی مجدد
                            </button>
                            <button type="button" onclick="updateServiceStatus(true)" class="btn btn-info">
                                <i class="fas fa-sync-alt"></i> بروزرسانی وضعیت
                            </button>
                            <button type="button" onclick="forceRefreshStatus()" class="btn btn-secondary" title="بارگذاری مجدد کامل صفحه برای حل مشکل کش">
                                <i class="fas fa-refresh"></i> رفرش کامل
                            </button>
                        </div>
                        <div class="help" style="text-align: center;">
                            وضعیت فعلی: 
                            <span id="service-status-badge" class="status-badge <?php echo ($server_info['status'] === 'active') ? 'status-active' : 'status-inactive'; ?>">
                                <i class="fas fa-circle"></i>
                                <span id="service-status-text"><?php echo ($server_info['status'] === 'active') ? 'فعال' : 'غیرفعال'; ?></span>
                            </span>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <!-- تب پشتیبان‌گیری -->
        <div id="backup-tab" class="admin-tab-content">
            <div class="admin-section">
                <h3><i class="fas fa-database"></i> پشتیبان‌گیری و بازیابی</h3>
                
                <div class="stats-grid">
                    <!-- پشتیبان‌گیری -->
                    <div class="card">
                        <div class="card-header">
                            <h2 class="card-title"><i class="fas fa-download"></i> ایجاد پشتیبان</h2>
                        </div>
                        <div style="padding: 20px; text-align: center;">
                            <p style="margin-bottom: 20px; color: var(--gray);">
                                با ایجاد پشتیبان، تمام اطلاعات کاربران، تنظیمات سرور و کلیدها در یک فایل ذخیره می‌شوند.
                            </p>
                            <div style="display: flex; gap: 10px; justify-content: center; flex-wrap: wrap;">
                                <form method="post" style="display: inline-block;">
                                    <input type="hidden" name="pk" value="<?php echo h($_POST['pk'] ?? ''); ?>">
                                    <input type="hidden" name="admin_action" value="backup">
                                    <button type="submit" class="btn btn-success" style="min-width: 200px;">
                                        <i class="fas fa-download"></i> ایجاد و دانلود فوری
                                    </button>
                                </form>
                                <form method="post" style="display: inline-block;">
                                    <input type="hidden" name="pk" value="<?php echo h($_POST['pk'] ?? ''); ?>">
                                    <input type="hidden" name="admin_action" value="create-backup-only">
                                    <button type="submit" class="btn btn-primary" style="min-width: 200px;">
                                        <i class="fas fa-save"></i> ایجاد و ذخیره در سرور
                                    </button>
                                </form>
                            </div>
                        </div>
                    </div>

                    <!-- بازیابی -->
                    <div class="card">
                        <div class="card-header">
                            <h2 class="card-title"><i class="fas fa-upload"></i> بازیابی پشتیبان</h2>
                        </div>
                        <div style="padding: 20px;">
                            <p style="margin-bottom: 20px; color: var(--gray); text-align: center;">
                                توجه: بازیابی پشتیبان باعث جایگزینی تمام تنظیمات فعلی خواهد شد.
                            </p>
                            <form method="post" enctype="multipart/form-data">
                                <input type="hidden" name="pk" value="<?php echo h($_POST['pk'] ?? ''); ?>">
                                <input type="hidden" name="admin_action" value="restore">
                                <div class="form-group">
                                    <label class="form-label">انتخاب فایل پشتیبان:</label>
                                    <input type="file" name="backup_file" class="form-input" accept=".tar.gz,.gz" required>
                                </div>
                                <button type="submit" class="btn btn-warning btn-block">
                                    <i class="fas fa-upload"></i> بازیابی پشتیبان
                                </button>
                            </form>
                        </div>
                    </div>
                </div>

                <!-- لیست پشتیبان‌های ذخیره شده -->
                <div class="card">
                    <div class="card-header">
                        <h2 class="card-title"><i class="fas fa-history"></i> پشتیبان‌های ذخیره شده</h2>
                    </div>
                    <div style="padding: 20px;">
                        <?php if (!empty($backup_list)): ?>
                            <div class="table-responsive">
                                <table class="clients-table">
                                    <thead>
                                        <tr>
                                            <th style="width: 40%;">نام فایل</th>
                                            <th style="width: 25%;">تاریخ ایجاد</th>
                                            <th style="width: 20%;">حجم</th>
                                            <th style="width: 15%;">عملیات</th>
                                        </tr>
                                    </thead>
                                    <tbody>
                                        <?php foreach ($backup_list as $backup): ?>
                                            <tr>
                                                <td>
                                                    <code style="font-size: 12px;"><?php echo h($backup['filename']); ?></code>
                                                </td>
                                                <td><?php echo h($backup['date']); ?></td>
                                                <td><?php echo h($backup['size_formatted']); ?></td>
                                                <td>
                                                    <form method="post" style="display: inline-block;">
                                                        <input type="hidden" name="pk" value="<?php echo h($_POST['pk'] ?? ''); ?>">
                                                        <input type="hidden" name="admin_action" value="download-backup">
                                                        <input type="hidden" name="filename" value="<?php echo h($backup['filename']); ?>">
                                                        <button type="submit" class="btn btn-sm btn-success" title="دانلود پشتیبان">
                                                            <i class="fas fa-download"></i>
                                                        </button>
                                                    </form>
                                                </td>
                                            </tr>
                                        <?php endforeach; ?>
                                    </tbody>
                                </table>
                            </div>
                        <?php else: ?>
                            <div class="help" style="text-align: center; padding: 40px; color: var(--gray);">
                                <i class="fas fa-inbox" style="font-size: 48px; margin-bottom: 15px; opacity: 0.5;"></i>
                                <p>هنوز پشتیبانی ایجاد نشده است.</p>
                                <p style="font-size: 14px;">با کلیک روی "ایجاد پشتیبان کامل" اولین پشتیبان خود را بسازید.</p>
                            </div>
                        <?php endif; ?>
                    </div>
                </div>

                <!-- اطلاعات پشتیبان -->
                <div class="card">
                    <div class="card-header">
                        <h2 class="card-title"><i class="fas fa-info-circle"></i> اطلاعات پشتیبان</h2>
                    </div>
                    <div style="padding: 20px;">
                        <div class="help">
                            <strong>موارد موجود در پشتیبان:</strong>
                            <ul style="margin: 10px 0; padding-right: 20px; color: var(--gray);">
                                <li>لیست کاربران (clients.db)</li>
                                <li>سهمیه کاربران (quota.db)</li>
                                <li>تنظیمات مدیر (admin.db)</li>
                                <li>آدرس سرور (endpoint.db)</li>
                                <li>تنظیمات DNS (dns.db)</li>
                                <li>پیکربندی سرور (وg0.conf)</li>
                                <li>کلیدهای سرور (server_public.key, server_private.key)</li>
                                <li>کلیدهای خصوصی کاربران (پوشه clients)</li>
                            </ul>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <!-- Modal نمایش اطلاعات کاربر جدید -->
    <div id="addUserModal" class="modal-backdrop" style="display:none;">
        <div class="modal" style="max-width:500px;">
            <h3 style="margin-bottom:10px;">اطلاعات کاربر جدید</h3>
            <div id="addUserModalContent"></div>
            <button onclick="document.getElementById('addUserModal').style.display='none'" class="btn btn-primary" style="margin-top:15px;">بستن</button>
        </div>
    </div>

    <script>
        // تابع تغییر تب‌های مدیریت
        function switchAdminTab(tabName, evt) {
            if (!tabName) {
                console.error('switchAdminTab: tabName is required');
                return;
            }
            
            // Hide all admin tab contents
            document.querySelectorAll('.admin-tab-content').forEach(tab => {
                tab.classList.remove('active');
            });

            // Remove active class from all admin tabs
            document.querySelectorAll('.admin-tabs .tab').forEach(tab => {
                tab.classList.remove('active');
            });

            // Show selected tab content
            const content = document.getElementById(tabName + '-tab');
            if (content) {
                content.classList.add('active');
            } else {
                console.error('switchAdminTab: tab content not found for', tabName);
            }

            // Activate selected tab
            if (evt) {
                const el = evt.currentTarget || evt.target;
                if (el && el.classList) {
                    el.classList.add('active');
                }
            }
        }

        // مدیریت افزودن کاربر با AJAX
        document.addEventListener('DOMContentLoaded', function() {
            initializeAddUser();
        });

        function initializeAddUser() {
            const addUserBtn = document.getElementById('addUserBtn');
            if (!addUserBtn) {
                console.warn('Add user button not found');
                return;
            }
            
            addUserBtn.addEventListener('click', function() {
                const nameElem = document.getElementById('addUserName');
                const gbElem = document.getElementById('addUserGB');
                const daysElem = document.getElementById('addUserDays');
                const pkElem = document.getElementById('addUserPk');
                
                if (!nameElem || !gbElem || !daysElem || !pkElem) {
                    showMessage('خطا در پیدا کردن فیلدهای فرم', 'error');
                    return;
                }
                
                const name = nameElem.value.trim();
                const gb = parseFloat(gbElem.value);
                const days = parseInt(daysElem.value);
                const pk = pkElem.value;
                
                // اعتبارسنجی پیشرفته
                if (!validateAddUserForm(name, gb, days)) {
                    return;
                }
                
                addUser(name, gb, days, pk);
            });
        }

        function validateAddUserForm(name, gb, days) {
            const msgElem = document.getElementById('addUserMsg');
            
            if (!name || isNaN(gb) || isNaN(days)) {
                showFieldMessage('لطفا تمام فیلدها را پر کنید', 'error');
                return false;
            }
            
            if (name.length < 2 || name.length > 32) {
                showFieldMessage('نام کاربر باید بین ۲ تا ۳۲ کاراکتر باشد', 'error');
                return false;
            }
            
            // بررسی نام کاربر (فقط حروف، اعداد و زیرخط)
            if (!/^[a-zA-Z0-9_\-\.]+$/.test(name)) {
                showFieldMessage('نام کاربر فقط می‌تواند شامل حروف انگلیسی، اعداد و - _ . باشد', 'error');
                return false;
            }
            
            if (gb < 0.1 || gb > 1000) {
                showFieldMessage('سهمیه باید بین ۰.۱ تا ۱۰۰۰ گیگابایت باشد', 'error');
                return false;
            }
            
            if (days < 1 || days > 3650) {
                showFieldMessage('مدت اعتبار باید بین ۱ تا ۳۶۵۰ روز باشد', 'error');
                return false;
            }
            
            showFieldMessage('', 'success');
            return true;
        }

        function showFieldMessage(message, type) {
            const msgElem = document.getElementById('addUserMsg');
            if (!msgElem) return;
            
            msgElem.textContent = message;
            msgElem.className = type === 'error' ? 'error-message' : 'success-message';
            msgElem.style.color = type === 'error' ? '#ef4444' : '#10b981';
            msgElem.style.fontWeight = 'bold';
            msgElem.style.marginTop = '10px';
        }

        function addUser(name, gb, days, pk) {
            const btn = document.getElementById('addUserBtn');
            const originalText = btn.innerHTML;
            
            btn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> در حال افزودن...';
            btn.disabled = true;
            
            const formData = new FormData();
            formData.append('pk', pk);
            formData.append('admin_action', 'add-client');
            formData.append('param1', name);
            formData.append('param2', gb);
            formData.append('param3', days);
            
            fetch(window.location.href, {
                method: 'POST',
                headers: { 
                    'Accept': 'application/json',
                    'X-Requested-With': 'XMLHttpRequest'
                },
                body: formData
            })
            .then(response => {
                if (!response.ok) {
                    throw new Error(`خطای شبکه: ${response.status}`);
                }
                // بررسی content-type
                const contentType = response.headers.get('content-type');
                if (!contentType || !contentType.includes('application/json')) {
                    console.error('Response is not JSON, content-type:', contentType);
                    return response.text().then(text => {
                        console.error('Response body:', text.substring(0, 500));
                        throw new Error('سرور پاسخ JSON ارسال نکرد. احتمالاً خطای PHP وجود دارد.');
                    });
                }
                return response.json();
            })
            .then(data => {
                if (data.status === 'success') {
                    showFieldMessage('کاربر با موفقیت اضافه شد', 'success');
                    resetAddUserForm();
                    showUserDetailsModal(data);
                    setTimeout(refreshUserList, 1500);
                } else {
                    throw new Error(data.message || 'خطای ناشناخته در افزودن کاربر');
                }
            })
            .catch(error => {
                console.error('Add user error:', error);
                showFieldMessage('خطا در افزودن کاربر: ' + error.message, 'error');
            })
            .finally(() => {
                btn.innerHTML = originalText;
                btn.disabled = false;
            });
        }

        function resetAddUserForm() {
            const nameElem = document.getElementById('addUserName');
            const gbElem = document.getElementById('addUserGB');
            const daysElem = document.getElementById('addUserDays');
            
            if (nameElem) nameElem.value = '';
            if (gbElem) gbElem.value = '';
            if (daysElem) daysElem.value = '';
        }

        // تابع بهبود یافته برای نمایش مدال کاربر جدید
        function showUserDetailsModal(userData) {
            const modal = document.getElementById('addUserModal');
            const modalContent = document.getElementById('addUserModalContent');
            
            if (!modal || !modalContent) {
                console.error('Modal elements not found');
                showMessage('خطا در نمایش اطلاعات کاربر', 'error');
                return;
            }
            
            // ایجاد محتوای مدال
            modalContent.innerHTML = `
                <div style="background: rgba(16, 185, 129, 0.1); padding: 20px; border-radius: 12px; margin-bottom: 20px; border: 1px solid rgba(16, 185, 129, 0.3);">
                    <h4 style="color: #10b981; margin-bottom: 15px; text-align: center;">
                        <i class="fas fa-check-circle"></i> کاربر با موفقیت ایجاد شد
                    </h4>
                    <div style="display: grid; grid-template-columns: 1fr 1fr; gap: 10px;">
                        <div><strong>نام کاربر:</strong> ${escapeHtml(userData.name)}</div>
                        <div><strong>آدرس IP:</strong> ${escapeHtml(userData.ip || 'در حال انتساب...')}</div>
                        <div><strong>سهمیه:</strong> ${userData.param2 || 'N/A'} GB</div>
                        <div><strong>مدت اعتبار:</strong> ${userData.param3 || 'N/A'} روز</div>
                    </div>
                </div>
                
                <div style="margin-bottom: 20px;">
                    <label style="font-weight: bold; display: block; margin-bottom: 8px; color: var(--primary);">
                        <i class="fas fa-key"></i> کلید خصوصی (Private Key):
                    </label>
                    <div style="position: relative;">
                        <textarea 
                            id="privateKeyText" 
                            style="width: 100%; height: 80px; background: rgba(15, 23, 42, 0.9); color: #e2e8f0; border: 1px solid rgba(99, 102, 241, 0.5); border-radius: 8px; padding: 12px; font-family: 'Courier New', monospace; font-size: 12px; line-height: 1.4; resize: vertical;" 
                            readonly
                        >${escapeHtml(userData.private_key || '')}</textarea>
                        <button 
                            onclick="copyPrivateKey()" 
                            class="btn btn-primary" 
                            style="position: absolute; left: 10px; top: 10px; padding: 6px 12px; font-size: 12px;"
                        >
                            <i class="fas fa-copy"></i> کپی
                        </button>
                    </div>
                </div>
                
                ${userData.qr && userData.qr.length > 0 ? `
                <div style="text-align: center; margin: 20px 0; padding: 20px; background: rgba(255, 255, 255, 0.05); border-radius: 12px;">
                    <h4 style="margin-bottom: 15px; color: var(--primary);">
                        <i class="fas fa-qrcode"></i> QR Code برای اتصال سریع
                    </h4>
                    <img src="data:image/png;base64,${userData.qr}" alt="QR Code" style="max-width: 220px; border-radius: 8px; border: 2px solid rgba(255, 255, 255, 0.1);">
                    <p style="margin-top: 10px; color: var(--gray); font-size: 0.9em;">
                        این QR Code را در اپلیکیشن موبایل WireGuard اسکن کنید
                    </p>
                </div>
                ` : `
                <div id="qr-container" style="text-align: center; margin: 20px 0; padding: 20px; background: rgba(255, 255, 255, 0.05); border-radius: 12px;">
                    <h4 style="margin-bottom: 15px; color: var(--primary);">
                        <i class="fas fa-qrcode"></i> QR Code برای اتصال سریع
                    </h4>
                    <div id="qr-placeholder">
                        <i class="fas fa-spinner fa-spin" style="font-size: 32px; color: var(--primary);"></i>
                        <p style="margin-top: 10px; color: var(--gray);">در حال تولید QR Code...</p>
                    </div>
                </div>
                `}
                
                <div style="margin-top: 20px; text-align: center;">
                    <button onclick="downloadUserConfig('${escapeHtml(userData.name)}', '${escapeHtml(userData.private_key || '')}', '${escapeHtml(userData.ip || '')}')" class="btn btn-success">
                        <i class="fas fa-download"></i> دانلود فایل کانفیگ
                    </button>
                </div>
            `;
            
            // نمایش مدال
            modal.style.display = 'flex';
            
            // اگر QR وجود نداشت، سعی کنیم از روش دیگری تولید کنیم
            if (!userData.qr || userData.qr.length === 0) {
                generateQRCodeFallback(userData);
            }
        }

        // تابع جایگزین برای تولید QR Code
        function generateQRCodeFallback(userData) {
            if (!userData.private_key || !userData.ip) {
                document.getElementById('qr-placeholder').innerHTML = `
                    <i class="fas fa-exclamation-triangle" style="color: #f59e0b; font-size: 24px;"></i>
                    <p style="color: #f59e0b; margin-top: 10px;">اطلاعات ناقص برای تولید QR Code</p>
                `;
                return;
            }
            
            const configContent = generateConfigFile(userData.name, userData.private_key, userData.ip);
            
            // استفاده از API آنلاین برای تولید QR
            const apiUrl = 'https://api.qrserver.com/v1/create-qr-code/?size=300x300&format=png&data=' + encodeURIComponent(configContent);
            
            const qrPlaceholder = document.getElementById('qr-placeholder');
            if (qrPlaceholder) {
                qrPlaceholder.innerHTML = `
                    <img src="${apiUrl}" 
                         alt="QR Code" 
                         style="max-width: 220px; border-radius: 8px; border: 2px solid rgba(255, 255, 255, 0.1);"
                         onerror="handleQRError()"
                    >
                    <p style="margin-top: 10px; color: var(--gray); font-size: 0.9em;">
                        این QR Code را در اپلیکیشن موبایل WireGuard اسکن کنید
                    </p>
                `;
            }
        }

        // مدیریت خطا در بارگذاری QR
        function handleQRError() {
            const qrPlaceholder = document.getElementById('qr-placeholder');
            if (qrPlaceholder) {
                qrPlaceholder.innerHTML = `
                    <i class="fas fa-times-circle" style="color: #ef4444; font-size: 24px;"></i>
                    <p style="color: #ef4444; margin-top: 10px;">خطا در تولید QR Code</p>
                    <p style="color: var(--gray); font-size: 0.85em; margin-top: 5px;">لطفاً از دانلود فایل کانفیگ استفاده کنید</p>
                `;
            }
        }

        // تابع برای کپی کلید خصوصی
        function copyPrivateKey() {
            const textarea = document.getElementById('privateKeyText');
            if (!textarea) return;
            
            const key = textarea.value.trim();
            if (!key) {
                showMessage('کلید خصوصی موجود نیست', 'error');
                return;
            }
            
            navigator.clipboard.writeText(key).then(() => {
                showMessage('کلید خصوصی کپی شد', 'success');
            }).catch(err => {
                console.error('Copy failed:', err);
                showMessage('خطا در کپی کلید', 'error');
            });
        }

        // تابع برای دانلود کانفیگ
        function downloadUserConfig(username, privateKey, ip) {
            if (!privateKey || !ip) {
                showMessage('اطلاعات کاربر ناقص است', 'error');
                return;
            }
            
            const config = generateConfigFile(username, privateKey, ip);
            const blob = new Blob([config], { type: 'text/plain' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            
            a.href = url;
            a.download = `${username}.conf`;
            document.body.appendChild(a);
            a.click();
            document.body.removeChild(a);
            URL.revokeObjectURL(url);
            
            showMessage('فایل کانفیگ دانلود شد', 'success');
        }

        // تابع برای تولید محتوای فایل کانفیگ
        function generateConfigFile(username, privateKey, ip) {
            // این اطلاعات باید از سرور گرفته شوند
            const serverPublicKey = '<?php echo h($server_info['public_key'] ?? 'SERVER_PUBLIC_KEY'); ?>';
            const serverEndpoint = '<?php echo h($server_info['endpoint'] ?? 'SERVER_IP:1010'); ?>';
            const dns = '<?php echo h($server_info['dns'] ?? '1.1.1.1,8.8.8.8'); ?>';
            
            return `[Interface]
PrivateKey = ${privateKey}
Address = ${ip}/24
DNS = ${dns}
MTU = 1420

[Peer]
PublicKey = ${serverPublicKey}
Endpoint = ${serverEndpoint}
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25`;
        }

        // تابع برای escape کردن HTML
        function escapeHtml(unsafe) {
            if (typeof unsafe !== 'string') return unsafe;
            return unsafe
                .replace(/&/g, "&amp;")
                .replace(/</g, "&lt;")
                .replace(/>/g, "&gt;")
                .replace(/"/g, "&quot;")
                .replace(/'/g, "&#039;");
        }
    </script>

            <?php else: ?>
                <!-- پنل کاربر عادی -->
                <?php
                $__tmp = get_weekly_usage($data['client_name'] ?? '');
                echo '<script>window.USER_USAGE=' . json_encode($__tmp, JSON_UNESCAPED_UNICODE|JSON_UNESCAPED_SLASHES) . ';</script>';
                ?>
                
                <div class="fade-in delay-2">
                    <!-- آمار مصرف -->
                    <div class="stats-grid">
                        <div class="stat-card">
                            <div class="stat-icon primary">
                                <i class="fas fa-network-wired"></i>
                            </div>
                            <div class="stat-info">
                                <div class="stat-value"><?php echo h($data['ip_address']); ?></div>
                                <div class="stat-label">آدرس IP</div>
                            </div>
                        </div>
                        <div class="stat-card">
                            <div class="stat-icon success">
                                <i class="fas fa-database"></i>
                            </div>
                            <div class="stat-info">
                                <div class="stat-value"><?php echo h($data['data_used']); ?> GB</div>
                                <div class="stat-label">مصرف شده</div>
                            </div>
                        </div>
                        <div class="stat-card">
                            <div class="stat-icon warning">
                                <i class="fas fa-tachometer-alt"></i>
                            </div>
                            <div class="stat-info">
                                <div class="stat-value"><?php echo h($data['remaining_data']); ?> GB</div>
                                <div class="stat-label">باقیمانده</div>
                            </div>
                        </div>
                        <div class="stat-card">
                            <div class="stat-icon primary">
                                <i class="fas fa-calendar-day"></i>
                            </div>
                            <div class="stat-info">
                                <div class="stat-value"><?php echo h($data['days_remaining']); ?> روز</div>
                                <div class="stat-label">اعتبار باقیمانده</div>
                            </div>
                        </div>
                    </div>

                    <!-- درصد مصرف -->
                    <div class="card usage-card fade-in delay-3">
                        <div class="usage-header">
                            <h2 class="card-title"><i class="fas fa-chart-pie"></i> وضعیت مصرف</h2>
                            <div class="usage-percent"><?php echo h($data['usage_percent']); ?>%</div>
                        </div>
                        <div class="progress-container">
                            <div class="progress-bar" style="width: <?php echo max(0, min(100, floatval($data['usage_percent']))); ?>%"></div>
                        </div>
                        <div class="usage-details">
                            <span>0 GB</span>
                            <span><?php echo h($data['data_limit']); ?> GB</span>
                        </div>
                    </div>

                    <!-- نمودار مصرف -->
                    <div class="card fade-in delay-3">
                        <div class="chart-container">
                            <div class="chart-header">
                                <h2><i class="fas fa-chart-line"></i> نمودار مصرف هفتگی</h2>
                            </div>
                            <div style="height:300px;position:relative">
                                <canvas id="usageChart"></canvas>
                            </div>
                        </div>
                    </div>

                    <!-- تب‌ها -->
                    <div class="tabs fade-in delay-4">
                        <div class="tab active" onclick="switchTab('config', event)">
                            <i class="fas fa-file-code"></i> اطلاعات کانفیگ
                        </div>
                        <div class="tab" onclick="switchTab('qr', event)">
                            <i class="fas fa-qrcode"></i> QR Code
                        </div>
                    </div>

                    <!-- محتوای تب‌ها -->
                    <div id="config-tab" class="tab-content active">
                        <div class="card">
                            <div class="card-header">
                                <h2 class="card-title"><i class="fas fa-file-code"></i> پیکربندی اتصال</h2>
                                <span class="status-badge <?php echo ($data['is_active'] ? 'status-active' : 'status-inactive'); ?>">
                                    <i class="fas fa-circle"></i>
                                    <?php echo ($data['is_active'] ? 'فعال' : 'غیرفعال'); ?>
                                </span>
                            </div>
                            <div class="config-container">
                                <div class="config-content">[Interface]<br>
PrivateKey = <?php echo h($_POST['pk'] ?? ''); ?><br>
Address = <?php echo h($data['ip_address']); ?>/24<br>
DNS = <?php echo h($data['server_dns'] ?? '1.1.1.1,8.8.8.8'); ?><br>
MTU = 1420<br>

[Peer]<br>
PublicKey = <?php echo h($data['server_public_key']); ?><br>
Endpoint = <?php echo h($data['server_endpoint']); ?><br>
AllowedIPs = 0.0.0.0/0, ::/0<br>
PersistentKeepalive = 25</div>
                                <div class="config-actions">
                                    <form method="post" style="flex: 1;" id="downloadConfigForm">
                                        <input type="hidden" name="pk" value="<?php echo h($data['private_key'] ?? ''); ?>">
                                        <input type="hidden" name="user_action" value="download-config">
                                        <button type="submit" class="btn btn-success">
                                            <i class="fas fa-download"></i> دانلود فایل کانفیگ
                                        </button>
                                    </form>
                                    <button class="btn btn-primary" onclick="copyConfig(event)">
                                        <i class="fas fa-copy"></i> کپی کانفیگ
                                    </button>
                                </div>
                            </div>
                        </div>
                    </div>

                    <!-- بخش دانلود اپلیکیشن -->
                    <div class="card fade-in delay-4">
                        <div class="card-header">
                            <h2 class="card-title"><i class="fas fa-mobile-alt"></i> دانلود اپلیکیشن WireGuard</h2>
                        </div>
                        <p style="text-align: center; color: var(--gray); margin-bottom: 20px;">
                            برای استفاده از WireGuard روی موبایل، اپلیکیشن رسمی را از استورهای زیر دانلود کنید
                        </p>
                        <div class="app-download-grid">
                            <a href="https://play.google.com/store/apps/details?id=com.wireguard.android&hl=en" target="_blank" class="app-download-card">
                                <div class="app-icon">
                                    <i class="fab fa-android"></i>
                                </div>
                                <div class="app-info">
                                    <h3>WireGuard (رسمی)</h3>
                                    <p>Android - Google Play</p>
                                </div>
                                <div class="app-arrow">
                                    <i class="fas fa-arrow-left"></i>
                                </div>
                            </a>
                            
                            <a href="https://play.google.com/store/apps/details?id=com.zaneschepke.wireguardautotunnel&hl=en" target="_blank" class="app-download-card">
                                <div class="app-icon" style="background: rgba(76, 175, 80, 0.2); color: #4caf50;">
                                    <i class="fab fa-android"></i>
                                </div>
                                <div class="app-info">
                                    <h3>WireGuard Auto Tunnel</h3>
                                    <p>Android - اتصال خودکار</p>
                                </div>
                                <div class="app-arrow">
                                    <i class="fas fa-arrow-left"></i>
                                </div>
                            </a>
                            
                            <a href="https://apps.apple.com/us/app/wireguard/id1441195209" target="_blank" class="app-download-card">
                                <div class="app-icon" style="background: rgba(0, 122, 255, 0.2); color: #007aff;">
                                    <i class="fab fa-apple"></i>
                                </div>
                                <div class="app-info">
                                    <h3>WireGuard (رسمی)</h3>
                                    <p>iOS - App Store</p>
                                </div>
                                <div class="app-arrow">
                                    <i class="fas fa-arrow-left"></i>
                                </div>
                            </a>
                        </div>
                        <div class="help" style="margin-top: 15px;">
                            💡 پس از نصب اپلیکیشن، می‌توانید با اسکن QR Code یا آپلود فایل کانفیگ، به سرویس متصل شوید
                        </div>
                    </div>

                    <div id="qr-tab" class="tab-content">
                        <div class="card qr-section">
                            <div class="card-header">
                                <h2 class="card-title"><i class="fas fa-qrcode"></i> اتصال سریع با QR Code</h2>
                            </div>
                            <?php if (!empty($qr_code)): ?>
                            <div class="qr-container">
                                <img src="data:image/png;base64,<?php echo $qr_code; ?>" alt="QR Code" class="qr-image">
                            </div>
                            <p>با اسکن این QR Code در اپلیکیشن WireGuard، به صورت خودکار متصل شوید</p>
                            <?php else: ?>
                            <div class="message warning">
                                <i class="fas fa-exclamation-triangle"></i>
                                تولید QR Code با مشکل مواجه شد. لطفاً از فایل کانفیگ استفاده کنید.
                            </div>
                            <?php endif; ?>
                        </div>
                    </div>
                </div>
            <?php endif; ?>

        <?php endif; ?>

        <!-- Footer -->
        <footer class="footer fade-in delay-4">
            <p>پنل مدیریت WireGuard • نسخه ۲.۰ • طراحی حرفه‌ای</p>
        </footer>
    </div>

    <!-- Modal for displaying full private key -->
    <div id="keyModalBackdrop" class="modal-backdrop" onclick="closeKeyModal()">
        <div class="modal" onclick="event.stopPropagation()">
            <div class="modal-header">
                <h3><i class="fas fa-key"></i> کلید خصوصی (Private Key)</h3>
                <button onclick="closeKeyModal()" class="btn btn-danger" style="padding: 8px 12px;">
                    <i class="fas fa-times"></i>
                </button>
            </div>
            <div id="keyModalBody" class="modal-body">-----</div>
            <div class="modal-actions">
                <button class="btn btn-primary" onclick="copyModalKey()">
                    <i class="fas fa-copy"></i> کپی کلید
                </button>
                <button class="btn" onclick="closeKeyModal()">بستن</button>
            </div>
        </div>
    </div>

    <script>
        // Tab switching functionality
        function switchTab(tabName, evt) {
            if (!tabName) {
                console.error('switchTab: tabName is required');
                return;
            }
            
            // Hide all tab contents
            document.querySelectorAll('.tab-content').forEach(tab => {
                tab.classList.remove('active');
            });

            // Remove active class from all tabs
            document.querySelectorAll('.tab').forEach(tab => {
                tab.classList.remove('active');
            });

            // Show selected tab content
            const content = document.getElementById(tabName + '-tab');
            if (content) {
                content.classList.add('active');
            } else {
                console.error('switchTab: tab content not found for', tabName);
            }

            // Activate selected tab
            if (evt) {
                const el = evt.currentTarget || evt.target;
                if (el && el.classList) {
                    el.classList.add('active');
                }
            }
        }

        // Copy config to clipboard
        function copyConfig(evt) {
            const configText = `[Interface]
PrivateKey = <?php echo h($_POST['pk'] ?? ''); ?>
Address = <?php echo h($data['ip_address'] ?? '10.0.0.2'); ?>/24
DNS = <?php echo h($data['server_dns'] ?? '1.1.1.1,8.8.8.8'); ?>
MTU = 1420

[Peer]
PublicKey = <?php echo h($data['server_public_key'] ?? ''); ?>
Endpoint = <?php echo h($data['server_endpoint'] ?? 'SERVER_IP:1010'); ?>
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25`;

            let btn = null;
            if (evt && evt.target) {
                btn = evt.target.closest('button') || evt.target;
            } else if (evt && evt.currentTarget) {
                btn = evt.currentTarget;
            }

            const showSuccess = () => {
                if (btn) {
                    const originalText = btn.innerHTML;
                    btn.innerHTML = '<i class="fas fa-check"></i> کپی شد!';
                    btn.style.background = 'linear-gradient(135deg, #10b981, #059669)';
                    setTimeout(() => {
                        btn.innerHTML = originalText;
                        btn.style.background = '';
                    }, 2000);
                } else {
                    alert('کانفیگ کپی شد!');
                }
            };

            const showError = () => {
                if (btn) {
                    const originalText = btn.innerHTML;
                    btn.innerHTML = '<i class="fas fa-times"></i> خطا!';
                    btn.style.background = 'linear-gradient(135deg, #ef4444, #dc2626)';
                    setTimeout(() => {
                        btn.innerHTML = originalText;
                        btn.style.background = '';
                    }, 2000);
                } else {
                    alert('خطا در کپی کانفیگ');
                }
            };

            // Try modern clipboard API first
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(configText)
                    .then(showSuccess)
                    .catch((err) => {
                        console.error('Clipboard API failed:', err);
                        // Fallback to execCommand
                        fallbackCopyConfig(configText, showSuccess, showError);
                    });
            } else {
                // Use fallback method
                fallbackCopyConfig(configText, showSuccess, showError);
            }
        }

        // Fallback copy method for older browsers
        function fallbackCopyConfig(text, onSuccess, onError) {
            const ta = document.createElement('textarea');
            ta.value = text;
            ta.setAttribute('readonly', '');
            ta.style.position = 'absolute';
            ta.style.left = '-9999px';
            ta.style.top = '0';
            document.body.appendChild(ta);
            
            try {
                ta.select();
                ta.setSelectionRange(0, 99999); // For mobile devices
                const successful = document.execCommand('copy');
                if (successful) {
                    onSuccess();
                } else {
                    onError();
                }
            } catch (err) {
                console.error('Fallback copy failed:', err);
                onError();
            } finally {
                ta.remove();
            }
        }

        // تابع کپی کردن Private Key
        function copyToClipboard(button) {
            if (!button || !button.parentElement) {
                console.error('copyToClipboard: invalid button element');
                return;
            }
            
            const input = button.parentElement.querySelector('.private-key');
            if (!input) {
                console.error('copyToClipboard: private-key input not found');
                return;
            }
            
            const value = input.value || input.textContent || '';

            if (!value || value.trim() === '') {
                const original = button.innerHTML;
                button.innerHTML = '<i class="fas fa-times"></i>';
                button.style.background = '#ef4444';
                setTimeout(() => {
                    button.innerHTML = original;
                    button.style.background = '';
                }, 1000);
                return;
            }

            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(value).then(() => {
                    const originalHTML = button.innerHTML;
                    button.innerHTML = '<i class="fas fa-check"></i>';
                    button.style.background = '#10b981';
                    setTimeout(() => {
                        button.innerHTML = originalHTML;
                        button.style.background = '';
                    }, 1500);
                }).catch((err) => {
                    console.error('Clipboard API failed:', err);
                    fallbackCopy(value, button);
                });
            } else {
                fallbackCopy(value, button);
            }
        }

        function fallbackCopy(text, button) {
            if (!text || !button) return;
            
            const ta = document.createElement('textarea');
            ta.value = text;
            ta.setAttribute('readonly', '');
            ta.style.position = 'absolute';
            ta.style.left = '-9999px';
            document.body.appendChild(ta);
            ta.select();
            
            try {
                const success = document.execCommand('copy');
                const originalHTML = button.innerHTML;
                
                if (success) {
                    button.innerHTML = '<i class="fas fa-check"></i>';
                    button.style.background = '#10b981';
                } else {
                    button.innerHTML = '<i class="fas fa-times"></i>';
                    button.style.background = '#ef4444';
                }
                
                setTimeout(() => {
                    button.innerHTML = originalHTML;
                    button.style.background = '';
                }, 1500);
            } catch (e) {
                console.error('Fallback copy failed:', e);
                const originalHTML = button.innerHTML;
                button.innerHTML = '<i class="fas fa-times"></i>';
                button.style.background = '#ef4444';
                setTimeout(() => {
                    button.innerHTML = originalHTML;
                    button.style.background = '';
                }, 1500);
            } finally {
                ta.remove();
            }
        }

        // Show full private key in modal
        function showKeyModal(key) {
            const backdrop = document.getElementById('keyModalBackdrop');
            const body = document.getElementById('keyModalBody');
            
            if (!backdrop || !body) {
                console.error('showKeyModal: modal elements missing');
                return;
            }
            
            if (!key || (typeof key === 'string' && key.trim() === '')) {
                body.textContent = '[خطا: کلید خالی است]';
            } else {
                body.textContent = key;
            }
            
            backdrop.style.display = 'flex';
        }

        function closeKeyModal() {
            const backdrop = document.getElementById('keyModalBackdrop');
            if (backdrop) {
                backdrop.style.display = 'none';
            }
        }

        function copyModalKey() {
            const body = document.getElementById('keyModalBody');
            if (!body) {
                alert('خطا: محتوا یافت نشد');
                return;
            }
            
            const key = body.textContent;
            
            if (!key || key.trim() === '' || key.includes('[خطا:')) {
                alert('کلید خصوصی معتبر نیست');
                return;
            }
            
            if (!navigator.clipboard || !navigator.clipboard.writeText) {
                // Fallback method
                const ta = document.createElement('textarea');
                ta.value = key;
                ta.style.position = 'absolute';
                ta.style.left = '-9999px';
                document.body.appendChild(ta);
                ta.select();
                
                try {
                    document.execCommand('copy');
                    alert('کلید خصوصی کپی شد!');
                } catch (e) {
                    alert('خطا در کپی کلید');
                } finally {
                    ta.remove();
                }
                return;
            }
            
            navigator.clipboard.writeText(key).then(() => {
                alert('کلید خصوصی کپی شد!');
            }).catch((err) => {
                console.error('Copy error:', err);
                alert('خطا در کپی کلید');
            });
        }

        // تابع به روزرسانی نمودار
        let usageChart = null;
        function updateChart() {
            const el = document.getElementById('usageChart');
            if (!el) return;
            const ctx = el.getContext('2d');
            const src = (window.USER_USAGE && Array.isArray(window.USER_USAGE.labels) && Array.isArray(window.USER_USAGE.data))
                ? window.USER_USAGE
                : { labels: ['-','-','-','-','-','-','-'], data: [0,0,0,0,0,0,0] };

            if (usageChart) {
                usageChart.destroy();
            }

            usageChart = new Chart(ctx, {
                type: 'line',
                data: {
                    labels: src.labels,
                    datasets: [{
                        label: 'مصرف داده (GB)',
                        data: src.data,
                        borderColor: '#6366f1',
                        backgroundColor: 'rgba(99, 102, 241, 0.1)',
                        borderWidth: 2,
                        fill: true,
                        tension: 0.4,
                        pointBackgroundColor: '#6366f1',
                        pointBorderColor: '#ffffff',
                        pointBorderWidth: 2,
                        pointRadius: 5,
                        pointHoverRadius: 7
                    }]
                },
                options: {
                    responsive: true,
                    maintainAspectRatio: false,
                    plugins: {
                        legend: {
                            display: true,
                            position: 'top',
                            labels: {
                                color: '#ffffff',
                                font: {
                                    family: 'Vazir, Arial, sans-serif'
                                }
                            }
                        }
                    },
                    scales: {
                        x: {
                            ticks: {
                                color: '#cccccc',
                                font: {
                                    family: 'Vazir, Arial, sans-serif'
                                },
                                maxRotation: 45,
                                minRotation: 45
                            },
                            grid: {
                                color: 'rgba(255, 255, 255, 0.1)'
                            }
                        },
                        y: {
                            ticks: {
                                color: '#cccccc',
                                font: {
                                    family: 'Vazir, Arial, sans-serif'
                                }
                            },
                            grid: {
                                color: 'rgba(255, 255, 255, 0.1)'
                            }
                        }
                    }
                }
            });
        }

        // مقداردهی اولیه نمودار
        document.addEventListener('DOMContentLoaded', function() {
            // Initialize chart if it exists (user panel)
            const chartEl = document.getElementById('usageChart');
            if (chartEl) {
                updateChart();
            }
            
            // Handle login form specifically
            const loginForm = document.getElementById('loginForm');
            const loginBtn = document.getElementById('loginBtn');
            const pkInput = document.getElementById('pkInput');
            
            if (loginForm && loginBtn && pkInput) {
                // Auto-focus on input
                pkInput.focus();
                
                // Remove leading/trailing whitespace only on blur (not during typing)
                pkInput.addEventListener('blur', function() {
                    this.value = this.value.trim();
                });
                
                // Trim on paste after a small delay
                pkInput.addEventListener('paste', function(e) {
                    setTimeout(() => {
                        this.value = this.value.trim();
                    }, 10);
                });
                
                // Handle form submit
                loginForm.addEventListener('submit', function(e) {
                    // Trim the value before validation
                    const pkValue = pkInput.value.trim();
                    
                    // Update the input with trimmed value
                    pkInput.value = pkValue;
                    
                    // Client-side validation
                    if (!pkValue || pkValue === '') {
                        e.preventDefault();
                        alert('لطفا کلید خصوصی خود را وارد کنید');
                        pkInput.focus();
                        return false;
                    }
                    
                    if (pkValue.length < 40) {
                        e.preventDefault();
                        alert('کلید خصوصی باید حداقل 40 کاراکتر داشته باشد\nکلید وارد شده: ' + pkValue.length + ' کاراکتر');
                        pkInput.select();
                        return false;
                    }
                    
                    // Check if it looks like a valid base64 key
                    const base64Pattern = /^[A-Za-z0-9+/]+=*$/;
                    if (!base64Pattern.test(pkValue)) {
                        e.preventDefault();
                        alert('کلید خصوصی باید فقط شامل حروف، اعداد و کاراکترهای +/= باشد');
                        pkInput.select();
                        return false;
                    }
                    
                    // Valid - show loading
                    const originalHTML = loginBtn.innerHTML;
                    loginBtn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> در حال ورود...';
                    loginBtn.disabled = true;
                    // Do NOT disable the input; disabled fields are not submitted with the form
                    // Make it read-only instead to prevent edits while submitting
                    pkInput.readOnly = true;
                    
                    // Don't prevent default - let form submit naturally
                    return true;
                });
            }
            
            // Add loading animation to other submit buttons (not login)
            const buttons = document.querySelectorAll('button[type="submit"]:not(#loginBtn)');
            buttons.forEach(button => {
                button.addEventListener('click', function() {
                    if (this.form && this.form.checkValidity()) {
                        const originalHTML = this.innerHTML;
                        this.innerHTML = '<i class="fas fa-spinner fa-spin"></i> در حال پردازش...';
                        this.disabled = true;
                        
                        // Restore button after 5 seconds (fallback)
                        setTimeout(() => {
                            this.innerHTML = originalHTML;
                            this.disabled = false;
                        }, 5000);
                    }
                });
            });
        });

        // توابع مدیریتی
        function searchUsers() {
            const input = document.getElementById('searchUsers');
            const table = document.getElementById('clientsTable');
            
            if (!input || !table) {
                console.error('searchUsers: required elements missing');
                return;
            }
            
            const filter = input.value.toLowerCase();
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

        // اصلاح تابع نمایش فرم ویرایش
        function showEditForm(clientName, currentGB, currentDays) {
            const nameField = document.getElementById('editClientName');
            const gbField = document.getElementById('editClientGB');
            const daysField = document.getElementById('editClientDays');
            const form = document.getElementById('editForm');
            const msgElem = document.getElementById('editClientMsg');
            
            if (!nameField || !gbField || !daysField || !form) {
                showMessage('خطا در بارگذاری فرم ویرایش', 'error');
                return;
            }
            
            // پاک کردن پیام قبلی
            if (msgElem) {
                msgElem.textContent = '';
                msgElem.className = '';
            }
            
            nameField.value = clientName;
            gbField.value = currentGB;
            daysField.value = currentDays;
            form.style.display = 'block';
            
            form.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
        }

        // تابع جدید برای ارسال ویرایش با AJAX
        function submitEditClient() {
            const nameField = document.getElementById('editClientName');
            const gbField = document.getElementById('editClientGB');
            const daysField = document.getElementById('editClientDays');
            const pkField = document.getElementById('editClientPk');
            const msgElem = document.getElementById('editClientMsg');
            
            if (!nameField || !gbField || !daysField || !pkField) {
                showMessage('خطا: فیلدهای فرم یافت نشد', 'error');
                return;
            }
            
            const clientName = nameField.value.trim();
            const newGB = parseFloat(gbField.value);
            const newDays = parseInt(daysField.value);
            const pk = pkField.value;
            
            // اعتبارسنجی
            if (!clientName || isNaN(newGB) || isNaN(newDays)) {
                if (msgElem) {
                    msgElem.textContent = 'لطفاً تمام فیلدها را به درستی پر کنید';
                    msgElem.className = 'error-message';
                }
                return;
            }
            
            if (newGB < 0.1 || newGB > 1000) {
                if (msgElem) {
                    msgElem.textContent = 'سهمیه باید بین 0.1 تا 1000 گیگابایت باشد';
                    msgElem.className = 'error-message';
                }
                return;
            }
            
            if (newDays < 1 || newDays > 3650) {
                if (msgElem) {
                    msgElem.textContent = 'مدت اعتبار باید بین 1 تا 3650 روز باشد';
                    msgElem.className = 'error-message';
                }
                return;
            }
            
            // نمایش وضعیت در حال پردازش
            if (msgElem) {
                msgElem.textContent = 'در حال ویرایش...';
                msgElem.className = 'success-message';
            }
            
            // ارسال درخواست
            const formData = new FormData();
            formData.append('pk', pk);
            formData.append('admin_action', 'edit-client');
            formData.append('param1', clientName);
            formData.append('param2', newGB);
            formData.append('param3', newDays);
            
            fetch(window.location.href, {
                method: 'POST',
                headers: {
                    'X-Requested-With': 'XMLHttpRequest'
                },
                body: formData
            })
            .then(response => {
                const contentType = response.headers.get('content-type');
                if (contentType && contentType.includes('application/json')) {
                    return response.json();
                }
                return response.text().then(text => {
                    console.log('Response is not JSON:', text.substring(0, 200));
                    // تلاش برای تشخیص موفقیت از HTML
                    return {
                        status: (text.includes('خطا:') || text.includes('Error:')) ? 'error' : 'success',
                        message: text.includes('خطا:') ? 'خطا در ویرایش کاربر' : 'عملیات انجام شد'
                    };
                });
            })
            .then(data => {
                if (data.status === 'success') {
                    if (msgElem) {
                        msgElem.textContent = data.message || 'کاربر با موفقیت ویرایش شد';
                        msgElem.className = 'success-message';
                    }
                    showMessage(`کاربر "${clientName}" با موفقیت ویرایش شد. برای مشاهده تغییرات، دکمه "بروزرسانی لیست" را بزنید.`, 'success');
                    
                    // فقط فرم را مخفی می‌کنیم، بدون reload خودکار
                    setTimeout(() => {
                        hideEditForm();
                    }, 1500);
                } else {
                    const errorMsg = data.message || 'خطا در ویرایش کاربر';
                    if (msgElem) {
                        msgElem.textContent = errorMsg;
                        msgElem.className = 'error-message';
                    }
                    showMessage(errorMsg, 'error');
                    
                    // نمایش اطلاعات debug در console
                    if (data.debug) {
                        console.error('Edit client debug info:', data.debug);
                    }
                }
            })
            .catch(error => {
                console.error('Edit client error:', error);
                if (msgElem) {
                    msgElem.textContent = 'خطا در ارتباط با سرور';
                    msgElem.className = 'error-message';
                }
                showMessage('خطا در ارتباط با سرور', 'error');
            });
        }

        // اصلاح تابع حذف کاربر
        function deleteUser(clientName) {
            const confirmation = confirm(`آیا از حذف کاربر "${clientName}" مطمئن هستید؟\nاین عمل غیرقابل بازگشت است!`);
            
            if (confirmation) {
                sendAdminAction('remove-client', clientName);
            }
        }

        function hideEditForm() {
            const form = document.getElementById('editForm');
            if (form) {
                form.style.display = 'none';
            }
            
            // پاک کردن پیام
            const msgElem = document.getElementById('editClientMsg');
            if (msgElem) {
                msgElem.textContent = '';
                msgElem.className = '';
            }
        }

        // اضافه کردن keyboard shortcut برای بستن فرم
        document.addEventListener('keydown', function(event) {
            if (event.key === 'Escape') {
                const form = document.getElementById('editForm');
                if (form && form.style.display !== 'none') {
                    hideEditForm();
                }
            }
        });

        // تابع برای نمایش پیام به کاربر
        function showMessage(message, type = 'info') {
            // حذف پیام قبلی اگر وجود دارد
            const existingMsg = document.getElementById('dynamic-message');
            if (existingMsg) {
                existingMsg.remove();
            }
            
            // ایجاد پیام جدید
            const messageDiv = document.createElement('div');
            messageDiv.id = 'dynamic-message';
            messageDiv.className = `message ${type}`;
            messageDiv.style.cssText = `
                position: fixed;
                top: 20px;
                left: 50%;
                transform: translateX(-50%);
                z-index: 10000;
                min-width: 300px;
                text-align: center;
                animation: fadeIn 0.3s ease;
            `;
            
            const icon = type === 'success' ? 'fa-check' : 
                         type === 'error' ? 'fa-times' : 
                         type === 'warning' ? 'fa-exclamation-triangle' : 'fa-info';
            
            messageDiv.innerHTML = `
                <i class="fas ${icon}"></i>
                ${message}
            `;
            
            document.body.appendChild(messageDiv);
            
            // حذف خودکار پیام بعد از 5 ثانیه
            setTimeout(() => {
                if (messageDiv.parentNode) {
                    messageDiv.style.animation = 'fadeOut 0.3s ease';
                    setTimeout(() => messageDiv.remove(), 300);
                }
            }, 5000);
        }

        // افزودن استایل fadeOut به CSS
        (function() {
            const style = document.createElement('style');
            style.textContent = `
                @keyframes fadeOut {
                    from { opacity: 1; transform: translateX(-50%) translateY(0); }
                    to { opacity: 0; transform: translateX(-50%) translateY(-20px); }
                }
            `;
            document.head.appendChild(style);
        })();

        // تابع رفرش خودکار لیست - نسخه بهبود یافته
        function refreshUserList() {
            console.log('Refreshing user list...');
            
            let pkValue = (window.ADMIN_PK && window.ADMIN_PK.length) ? window.ADMIN_PK : '';
            if (!pkValue) {
                const allPk = Array.from(document.querySelectorAll('input[name="pk"]'));
                const filled = allPk.find(i => i && i.value && i.value.trim().length > 0);
                pkValue = filled ? filled.value.trim() : '';
            }
            if (!pkValue) {
                console.warn('refreshUserList: no PK found');
                showMessage('خطا: کلید احراز هویت یافت نشد', 'error');
                return;
            }

            const refreshBtn = document.querySelector('button[onclick="refreshUserList()"]');
            const originalText = refreshBtn ? refreshBtn.innerHTML : '';
            if (refreshBtn) {
                refreshBtn.innerHTML = '<i class="fas fa-spinner fa-spin"></i> در حال بروزرسانی...';
                refreshBtn.disabled = true;
            }

            // ارسال درخواست با pk برای بارگذاری مجدد صفحه
            const form = document.createElement('form');
            form.method = 'POST';
            form.action = window.location.href;
            
            const pkInput = document.createElement('input');
            pkInput.type = 'hidden';
            pkInput.name = 'pk';
            pkInput.value = pkValue;
            form.appendChild(pkInput);
            
            // افزودن یک timestamp برای force refresh
            const timestampInput = document.createElement('input');
            timestampInput.type = 'hidden';
            timestampInput.name = '_refresh_timestamp';
            timestampInput.value = Date.now().toString();
            form.appendChild(timestampInput);
            
            document.body.appendChild(form);
            
            // نمایش پیام
            showMessage('در حال بروزرسانی لیست کاربران...', 'info');
            
            // ارسال فرم
            setTimeout(() => {
                form.submit();
            }, 500);
        }

        // تابع اصلاح شده برای ارسال عملیات مدیریتی
        function sendAdminAction(action, param1 = '', param2 = '', param3 = '') {
            console.log('sendAdminAction called:', { action, param1, param2, param3 });
            
            let pkValue = (window.ADMIN_PK && window.ADMIN_PK.length) ? window.ADMIN_PK : '';
            if (!pkValue) {
                const allPk = Array.from(document.querySelectorAll('input[name="pk"]'));
                const filled = allPk.find(i => i && i.value && i.value.trim().length > 0);
                pkValue = filled ? filled.value.trim() : '';
            }
            
            console.log('PK value found:', pkValue ? 'YES' : 'NO');
            
            if (!pkValue) {
                console.error('sendAdminAction: no PK found');
                showMessage('کلید خصوصی مدیر موجود نیست', 'error');
                return;
            }

            // نمایش وضعیت loading
            showLoadingState(action, true);

            const body = new URLSearchParams();
            body.append('pk', pkValue);
            body.append('admin_action', action);
            if (param1 !== '') body.append('param1', param1);
            if (param2 !== '') body.append('param2', param2);
            if (param3 !== '') body.append('param3', param3);

            console.log('Request body:', body.toString());

            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 30000);

            console.log('Sending fetch request to:', window.location.href);

            fetch(window.location.href, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/x-www-form-urlencoded',
                    'X-Requested-With': 'XMLHttpRequest'  // برای تشخیص AJAX در PHP
                },
                body: body.toString(),
                signal: controller.signal
            })
            .then(response => {
                console.log('Response received:', response.status, response.statusText);
                clearTimeout(timeoutId);
                if (!response.ok) {
                    throw new Error(`خطای شبکه: ${response.status} ${response.statusText}`);
                }
                
                // بررسی content-type برای تعیین نوع پاسخ
                const contentType = response.headers.get('content-type');
                console.log('Response content-type:', contentType);
                if (contentType && contentType.includes('application/json')) {
                    return response.json();
                }
                return response.text();
            })
            .then(data => {
                console.log('Admin action response received for:', action);
                console.log('Response type:', typeof data);
                console.log('Response data:', data);
                
                // اگر پاسخ JSON بود
                if (typeof data === 'object' && data !== null) {
                    console.log('Processing JSON response, status:', data.status);
                    
                    if (data.status === 'error') {
                        throw new Error(data.message || 'عملیات با خطا مواجه شد');
                    }
                    
                    // موفقیت با JSON - اضافه کردن یادآوری برای refresh دستی
                    let successMsg = data.message || `عملیات "${getActionName(action)}" با موفقیت انجام شد`;
                    
                    // برای update-status پیام کمتری نمایش بده
                    if (action === 'update-status') {
                        successMsg = 'وضعیت سرویس به‌روز شد';
                    } else if (action === 'remove-client' || action === 'edit-client') {
                        successMsg += '. برای مشاهده تغییرات، دکمه "بروزرسانی لیست کاربران" را بزنید';
                    }
                    
                    showMessage(successMsg, 'success');
                    handleActionSuccess(action, data);
                    return;
                }
                
                // اگر پاسخ HTML/text بود، بررسی خطا
                const html = String(data);
                console.log('Processing HTML response, length:', html.length);
                
                const hasRealError = (
                    html.includes('PHP Fatal error') || 
                    html.includes('PHP Warning') ||
                    html.includes('PHP Error') ||
                    /(?:^|>)\s*خطا:/m.test(html) ||
                    /(?:^|>)\s*Error:/m.test(html) ||
                    html.includes('Command failed') ||
                    (html.includes('not found') && !html.includes('console'))
                );
                
                if (hasRealError) {
                    console.error('Error detected in HTML response');
                    const errorMatch = html.match(/(?:خطا:|Error:)\s*([^\n<]+)/i);
                    const errorMsg = errorMatch ? errorMatch[1].trim() : 'عملیات با خطا مواجه شد';
                    throw new Error(errorMsg);
                }
                
                console.log('No error detected, operation successful');
                // موفقیت با HTML
                let htmlSuccessMsg = `عملیات "${getActionName(action)}" با موفقیت انجام شد`;
                if (action === 'remove-client' || action === 'edit-client') {
                    htmlSuccessMsg += '. برای مشاهده تغییرات، دکمه "بروزرسانی لیست کاربران" را بزنید';
                }
                showMessage(htmlSuccessMsg, 'success');
                handleActionSuccess(action);
            })
            .catch((error) => {
                clearTimeout(timeoutId);
                console.error('sendAdminAction error:', error);
                
                let errorMsg = 'خطا در اجرای عملیات';
                if (error.name === 'AbortError') {
                    errorMsg = 'زمان درخواست تمام شد';
                } else if (error.message) {
                    errorMsg = error.message;
                }
                
                showMessage(errorMsg, 'error');
            })
            .finally(() => {
                showLoadingState(action, false);
            });
        }

        // تابع کمکی برای نمایش نام عملیات
        function getActionName(action) {
            const actions = {
                'start-service': 'راه‌اندازی سرویس',
                'stop-service': 'توقف سرویس', 
                'restart-service': 'راه‌اندازی مجدد سرویس',
                'update-status': 'بروزرسانی وضعیت',
                'set-endpoint': 'به‌روزرسانی Endpoint و DNS',
                'remove-client': 'حذف کاربر',
                'edit-client': 'ویرایش کاربر',
                'add-client': 'افزودن کاربر'
            };
            return actions[action] || action;
        }

        // تابع برای مدیریت موفقیت عملیات
        function handleActionSuccess(action, data = null) {
            console.log('handleActionSuccess called with action:', action, 'data:', data);
            
            // به‌روزرسانی وضعیت سرویس اگر در پاسخ موجود بود
            if (data && data.service_status) {
                console.log('Updating service status from response:', data.service_status);
                updateServiceStatusDisplay(data.service_status);
            }
            
            // برای عملیات سرویس، وضعیت را بعد از یک تأخیر کوتاه دوباره به‌روز کن
            if (action === 'start-service' || action === 'stop-service' || action === 'restart-service') {
                console.log('Service action detected, will update status after 1.5 seconds');
                setTimeout(() => {
                    console.log('Fetching updated service status...');
                    updateServiceStatus();
                }, 1500);
            }
            
            // برای به‌روزرسانی endpoint/DNS، صفحه را reload کن تا اطلاعات جدید بارگذاری شود
            if (action === 'set-endpoint') {
                setTimeout(() => {
                    showMessage('تنظیمات با موفقیت به‌روز شد. در حال بارگذاری مجدد...', 'success');
                    setTimeout(() => {
                        location.reload();
                    }, 1500);
                }, 500);
            }
            
            console.log('Operation completed successfully. Use manual refresh button to update list if needed.');
        }

        // تابع برای به‌روزرسانی نمایش وضعیت سرویس
        function updateServiceStatusDisplay(status) {
            console.log('Updating service status display to:', status);
            
            // به‌روزرسانی در بخش تنظیمات
            const statusBadge = document.getElementById('service-status-badge');
            const statusText = document.getElementById('service-status-text');
            
            if (statusBadge && statusText) {
                if (status === 'active') {
                    statusBadge.className = 'status-badge status-active';
                    statusText.textContent = 'فعال';
                } else {
                    statusBadge.className = 'status-badge status-inactive';
                    statusText.textContent = 'غیرفعال';
                }
            }
            
            // به‌روزرسانی در پیشخوان
            const dashboardStatus = document.getElementById('dashboard-service-status');
            if (dashboardStatus) {
                dashboardStatus.textContent = (status === 'active') ? 'فعال' : 'غیرفعال';
            }
            
            // به‌روزرسانی آیکون stat-card در پیشخوان
            const dashboardStatCard = dashboardStatus?.closest('.stat-card');
            if (dashboardStatCard) {
                const statIcon = dashboardStatCard.querySelector('.stat-icon');
                if (statIcon) {
                    if (status === 'active') {
                        statIcon.className = 'stat-icon success';
                    } else {
                        statIcon.className = 'stat-icon danger';
                    }
                }
            }
        }

        // تابع برای بروزرسانی وضعیت سرویس
        function updateServiceStatus(showNotification = false) {
            console.log('=== updateServiceStatus called ===');
            console.log('Show notification:', showNotification);
            
            if (showNotification) {
                showMessage('در حال بروزرسانی وضعیت...', 'info');
            }
            
            sendAdminAction('update-status');
        }

        // تابع برای بروزرسانی وضعیت سرویس در پیشخوان
        function updateDashboardServiceStatus() {
            console.log('=== updateDashboardServiceStatus called ===');
            showMessage('در حال بروزرسانی وضعیت سرویس...', 'info');
            sendAdminAction('update-status');
        }

        // تابع جدید برای force refresh کامل صفحه
        function forceRefreshStatus() {
            console.log('=== Force refresh status called ===');
            showMessage('در حال بارگذاری مجدد کامل وضعیت...', 'warning');
            
            // Add timestamp to force fresh request
            const url = new URL(window.location);
            url.searchParams.set('_refresh', Date.now());
            
            setTimeout(() => {
                window.location.href = url.toString();
            }, 500);
        }

        // تابع برای نمایش وضعیت loading
        function showLoadingState(action, isLoading) {
            const actionNames = {
                'start-service': 'راه‌اندازی سرویس',
                'stop-service': 'توقف سرویس',
                'restart-service': 'راه‌اندازی مجدد'
            };
            
            if (isLoading) {
                showMessage(`در حال ${actionNames[action] || 'اجرای عملیات'}...`, 'warning');
            }
        }

        // تابع ویژه برای عملیات سرویس (با تاییدیه)
        function handleServiceAction(action) {
            console.log('=== handleServiceAction called ===');
            console.log('Action:', action);
            
            const actionNames = {
                'start-service': 'راه‌اندازی',
                'stop-service': 'توقف', 
                'restart-service': 'راه‌اندازی مجدد'
            };
            
            const actionName = actionNames[action];
            
            if (!actionName) {
                console.error('Unknown action:', action);
                showMessage('عملیات نامعتبر', 'error');
                return;
            }
            
            console.log('Showing confirmation dialog for:', actionName);
            const confirmation = confirm(`آیا از ${actionName} سرویس WireGuard مطمئن هستید؟`);
            
            if (confirmation) {
                console.log('User confirmed, sending action');
                sendAdminAction(action);
            } else {
                console.log('User cancelled');
            }
        }

        // Event listener برای فرم تنظیمات Endpoint
        document.addEventListener('DOMContentLoaded', function() {
            console.log('=== DOMContentLoaded fired ===');
            
            // بررسی وجود PK
            const pkInputs = document.querySelectorAll('input[name="pk"]');
            console.log('Found PK inputs:', pkInputs.length);
            if (pkInputs.length > 0) {
                const pkValue = pkInputs[0].value;
                console.log('PK value available:', pkValue ? 'YES (length: ' + pkValue.length + ')' : 'NO');
                // ذخیره در window برای دسترسی آسان
                window.ADMIN_PK = pkValue;
            } else {
                console.error('NO PK INPUT FOUND!');
            }
            
            const endpointForm = document.getElementById('endpoint-form');
            console.log('Endpoint form found:', !!endpointForm);
            
            if (endpointForm) {
                console.log('Adding submit listener to endpoint form');
                
                // حذف event listener قبلی اگر وجود داشت
                const newForm = endpointForm.cloneNode(true);
                endpointForm.parentNode.replaceChild(newForm, endpointForm);
                
                newForm.addEventListener('submit', function(e) {
                    console.log('=== Form submit event triggered ===');
                    e.preventDefault();
                    e.stopPropagation();
                    
                    const domain = document.getElementById('endpoint-domain').value.trim();
                    const port = document.getElementById('endpoint-port').value.trim();
                    const dns = document.getElementById('endpoint-dns').value.trim();
                    
                    console.log('Form values:', { 
                        domain: domain, 
                        port: port, 
                        dns: dns 
                    });
                    
                    if (!domain || !port || !dns) {
                        console.error('Validation failed: empty fields');
                        showMessage('لطفاً تمام فیلدها را پر کنید', 'error');
                        return false;
                    }
                    
                    if (port < 1 || port > 65535) {
                        console.error('Validation failed: invalid port');
                        showMessage('پورت باید بین 1 تا 65535 باشد', 'error');
                        return false;
                    }
                    
                    console.log('Validation passed, calling sendAdminAction');
                    showMessage('در حال به‌روزرسانی تنظیمات...', 'warning');
                    
                    // تأخیر کوچک برای نمایش پیام
                    setTimeout(() => {
                        sendAdminAction('set-endpoint', domain, port, dns);
                    }, 100);
                    
                    return false;
                });
                
                console.log('✓ Submit listener attached successfully');
            } else {
                console.error('✗ Endpoint form NOT FOUND!');
            }
            
            // اطلاعات اضافی برای دیباگ
            console.log('Page URL:', window.location.href);
            console.log('Page ready for admin actions');
        });


    </script>
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