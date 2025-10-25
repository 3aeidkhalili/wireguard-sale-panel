#!/usr/bin/env bash
# ============================================================================
# WireGuard Manager (Complete Rewrite - Enhanced Version)
# Features: Auto install, add/remove/list clients, quotas & expiry, Web UI with QR Code
# Version: 6.1.0
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
WEB_DIR="/var/www/wireguard"
WEB_ASSETS="$WEB_DIR/assets"
LISTEN_PORT="${LISTEN_PORT:-1010}"
SUBNET="${SUBNET:-10.0.0.0/24}"
MTU="${MTU:-1420}"

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
        err "Cannot detect OS"
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
    ok "System updated"
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
    ip=$(curl -fsS4 https://api.ipify.org 2>/dev/null || curl -fsS6 https://api64.ipify.org 2>/dev/null || true)
    echo "${ip:-YOUR_SERVER_IP}"
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
    
    # خواندن IPهای استفاده شده
    local used_ips=()
    if [[ -f "$CLIENT_DB" ]]; then
        while IFS='|' read -r _ _ _ ip _; do
            if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.([0-9]+)$ ]]; then
                used_ips+=("${BASH_REMATCH[1]}")
            fi
        done < <(grep -v '^#' "$CLIENT_DB" 2>/dev/null || true)
    fi

    # پیدا کردن IP آزاد
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
        # تولید QR code و تبدیل به base64
        qrencode -t PNG -o - < "$config_file" | base64 -w 0 2>/dev/null || echo ""
    else
        echo ""
    fi
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
    
    # فعال کردن IP forwarding
    ensure_line_once "net.ipv4.ip_forward=1" /etc/sysctl.conf
    sysctl -p >/dev/null 2>&1 || true
    
    ok "WireGuard and dependencies installed"
}

# --------------------------- Server Setup -------------------------------------
setup_server() {
    log "Configuring WireGuard server..."
    mkdir -p "$WG_DIR" "$CLIENTS_DIR"
    chmod 700 "$WG_DIR"

    # تولید کلیدهای سرور
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

    # ایجاد کانفیگ سرور
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

    ok "Server configuration written to $WG_CONF"
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
    
    ok "Databases initialized"
}

quota_set() {
    local name="$1" gb="${2:-0}" days="${3:-30}"
    
    if [[ -z "$name" ]]; then
        err "Client name is required"
        return 1
    fi
    
    local limit_bytes=$((gb * 1024 * 1024 * 1024))
    local expiry=$(date -d "+${days} days" +"%Y-%m-%d")
    
    # حذف رکورد موجود و اضافه کردن جدید
    if [[ -f "$QUOTA_DB" ]]; then
        grep -v "^$name|" "$QUOTA_DB" > "${QUOTA_DB}.tmp" 2>/dev/null || true
        mv "${QUOTA_DB}.tmp" "$QUOTA_DB"
    fi
    
    echo "$name|0|$limit_bytes|$expiry|1" >> "$QUOTA_DB"
    ok "Quota set for $name: ${gb}GB until $expiry"
}

quota_get_line() {
    local name="$1"
    grep "^$name|" "$QUOTA_DB" 2>/dev/null | head -n1 || true
}

# --------------------------- Client Management --------------------------------
add_client() {
    local name="$1" gb="${2:-0}" days="${3:-30}"
    
    if [[ -z "$name" ]]; then
        err "Usage: add-client NAME [GB] [DAYS]"
        return 1
    fi
    
    if [[ ! -f "$SERVER_PUB" ]]; then
        err "Server not initialized. Run 'install' first."
        return 1
    fi

    # پیدا کردن IP بعدی
    local ip
    ip=$(next_client_ip) || return 1
    
    # تولید کلیدهای کلاینت
    umask 077
    local c_priv c_pub cfg
    c_priv=$(wg genkey)
    c_pub=$(echo "$c_priv" | wg pubkey)
    cfg="$CLIENTS_DIR/${name}.conf"
    
    # ذخیره کلیدها
    echo "$c_priv" > "$CLIENTS_DIR/${name}_private.key"
    echo "$c_pub" > "$CLIENTS_DIR/${name}_public.key"

    # اضافه کردن به کانفیگ سرور
    cat >> "$WG_CONF" <<EOF

[Peer]
PublicKey = $c_pub
AllowedIPs = $ip/32
EOF

    local srv_pub=$(cat "$SERVER_PUB")
    local endpoint=$(public_ip):$LISTEN_PORT

    # ایجاد کانفیگ کلاینت
    cat > "$cfg" <<EOF
[Interface]
PrivateKey = $c_priv
Address = $ip/24
DNS = 1.1.1.1, 8.8.8.8
MTU = $MTU

[Peer]
PublicKey = $srv_pub
Endpoint = $endpoint
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    # ذخیره در دیتابیس
    echo "$name|$c_priv|$c_pub|$ip|$(date +%F)" >> "$CLIENT_DB"
    quota_set "$name" "$gb" "$days"

    # ریلود اگر سرویس فعال است
    if systemctl is-active --quiet "wg-quick@$WG_IFACE" 2>/dev/null; then
        wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") >/dev/null 2>&1
    fi

    # ساخت QR code
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -o "$CLIENTS_DIR/${name}.png" < "$cfg" 2>/dev/null && ok "QR code generated"
    fi

    ok "Client $name added successfully"
    echo -e "${GREEN}Config file:${NC} $cfg"
    echo -e "${GREEN}Private Key:${NC} $c_priv"
    
    # نمایش QR code در ترمینال اگر ممکن باشد
    if command -v qrencode >/dev/null 2>&1 && [ -t 1 ]; then
        echo -e "\n${CYAN}QR Code for client $name:${NC}"
        qrencode -t UTF8 < "$cfg" 2>/dev/null || true
        echo
    fi
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
    
    # حذف از کانفیگ سرور
    if [[ -f "$WG_CONF" ]]; then
        sed -i "/PublicKey = $pubkey/,+2d" "$WG_CONF"
    fi
    
    # حذف فایل‌ها
    rm -f "$CLIENTS_DIR/${name}_public.key" \
          "$CLIENTS_DIR/${name}_private.key" \
          "$CLIENTS_DIR/${name}.conf" \
          "$CLIENTS_DIR/${name}.png" 2>/dev/null || true
    
    # حذف از دیتابیس
    if [[ -f "$CLIENT_DB" ]]; then
        grep -v "^$name|" "$CLIENT_DB" > "${CLIENT_DB}.tmp" 2>/dev/null && mv "${CLIENT_DB}.tmp" "$CLIENT_DB"
    fi
    
    if [[ -f "$QUOTA_DB" ]]; then
        grep -v "^$name|" "$QUOTA_DB" > "${QUOTA_DB}.tmp" 2>/dev/null && mv "${QUOTA_DB}.tmp" "$QUOTA_DB"
    fi

    # ریلود سرویس
    if systemctl is-active --quiet "wg-quick@$WG_IFACE" 2>/dev/null; then
        wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") >/dev/null 2>&1
    fi
    
    ok "Client $name removed successfully"
}

list_clients() {
    printf "%-20s %-15s %-12s %-12s %-12s %-8s %-8s\n" "Client" "IP" "Used(GB)" "Limit(GB)" "Remaining" "Days" "Active"
    echo "-------------------------------------------------------------------------------------------"
    
    if [[ ! -f "$CLIENT_DB" ]]; then
        return 0
    fi
    
    while IFS='|' read -r name priv pub ip created; do
        [[ "$name" =~ ^# ]] && continue
        
        local qline=$(quota_get_line "$name")
        [[ -z "$qline" ]] && continue
        
        IFS='|' read -r _ used limit expiry active <<< "$qline"
        
        # محاسبات
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
    # جستجوی socketهای PHP-FPM
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
    
    # Fallback به TCP
    echo "127.0.0.1:9000"
}

install_web() {
    log "Installing and configuring Web UI..."
    
    # نصب بسته‌های لازم
    case "$OS_ID" in
        ubuntu|debian)
            pkg_install nginx php-fpm php-cli php-curl php-gd
            ;;
        centos|rhel|rocky|almalinux|fedora)
            pkg_install nginx php-fpm php-cli php-curl php-gd
            ;;
    esac

    # ایجاد دایرکتوری وب
    mkdir -p "$WEB_DIR" "$WEB_ASSETS"
    chown -R www-data:www-data "$WEB_DIR" 2>/dev/null || true
    chmod 755 "$WEB_DIR"

    # ایجاد فایل PHP
    cat > "$WEB_DIR/index.php" <<'PHP'
<?php
header('Content-Type: text/html; charset=utf-8');
function h($s) { return htmlspecialchars($s, ENT_QUOTES, 'UTF-8'); }

$ok = false;
$msg = "";
$data = null;
$qr_code = "";

if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['pk'])) {
    $pk = trim($_POST['pk']);
    if (!empty($pk)) {
        $cmd = "sudo /usr/local/bin/wg-client-info " . escapeshellarg($pk);
        $output = shell_exec($cmd . " 2>&1");
        
        if ($output !== null) {
            $data = json_decode($output, true);
            if (is_array($data) && isset($data['status']) && $data['status'] === 'success') {
                $ok = true;
                // دریافت QR code
                $qr_cmd = "sudo /usr/local/bin/wg-generate-qr " . escapeshellarg($pk);
                $qr_output = shell_exec($qr_cmd . " 2>&1");
                if (!empty($qr_output)) {
                    $qr_code = trim($qr_output);
                }
            } else {
                $msg = $data['message'] ?? "Invalid key or user not found";
            }
        } else {
            $msg = "Command execution failed";
        }
    } else {
        $msg = "Please enter your private key";
    }
}
?>
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>WireGuard User Panel</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: vazir;}
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
            background: rgba(255,255,255,0.1);
            border-radius: 15px;
            backdrop-filter: blur(10px);
        }
        .header h1 {
            color: #4fc3f7;
            margin-bottom: 10px;
        }
        .card {
            background: rgba(255,255,255,0.1);
            border-radius: 15px;
            padding: 25px;
            margin: 20px 0;
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255,255,255,0.2);
        }
        input, button {
            padding: 12px 15px;
            border-radius: 10px;
            border: 1px solid #444;
            background: rgba(255,255,255,0.1);
            color: #fff;
            width: 100%;
            font-size: 16px;
            margin: 5px 0;
        }
        input:focus {
            outline: none;
            border-color: #4fc3f7;
            box-shadow: 0 0 10px rgba(79, 195, 247, 0.3);
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
            background: rgba(255,255,255,0.1);
            padding: 20px;
            border-radius: 10px;
            text-align: center;
            border: 1px solid rgba(255,255,255,0.1);
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
        .success { color: #66bb6a; }
        .warning { color: #ffb74d; }
        .error { color: #f44336; }
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
        .help {
            font-size: 0.9em;
            opacity: 0.8;
            margin-top: 10px;
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
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 20px;
        }
        @media (max-width: 768px) {
            .two-column {
                grid-template-columns: 1fr;
            }
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔒 پنل کاربری WireGuard</h1>
            <p>بررسی وضعیت اتصال و مصرف داده + نمایش QR Code</p>
        </div>

        <div class="card">
            <h2>🔍 بررسی وضعیت اتصال</h2>
            <form method="post">
                <input type="text" name="pk" placeholder="PrivateKey خود را اینجا وارد کنید..." required>
                <button type="submit">📊 بررسی وضعیت</button>
            </form>
            <div class="help">
                PrivateKey را از فایل کانفیگ خود کپی کرده و در فیلد بالا قرار دهید.
            </div>
        </div>

        <?php if ($ok && $data): ?>
            <div class="two-column">
                <div>
                    <div class="card">
                        <h2>📈 نتیجه بررسی</h2>
                        <div class="grid">
                            <div class="stat">
                                <div class="label">👤 کاربر</div>
                                <div class="value"><?= h($data['client_name']) ?></div>
                            </div>
                            <div class="stat">
                                <div class="label">🌐 آدرس IP</div>
                                <div class="value"><?= h($data['ip_address']) ?></div>
                            </div>
                            <div class="stat">
                                <div class="label">📊 مصرف شده</div>
                                <div class="value"><?= h($data['data_used']) ?> GB</div>
                            </div>
                            <div class="stat">
                                <div class="label">📈 سقف مصرف</div>
                                <div class="value"><?= h($data['data_limit']) ?> GB</div>
                            </div>
                            <div class="stat">
                                <div class="label">📉 باقیمانده</div>
                                <div class="value <?= ($data['remaining_data'] == 'Unlimited' ? 'success' : (floatval($data['remaining_data']) > 0 ? '' : 'error')) ?>">
                                    <?= h($data['remaining_data']) ?> GB
                                </div>
                            </div>
                            <div class="stat">
                                <div class="label">📊 درصد مصرف</div>
                                <div class="value <?= (floatval($data['usage_percent']) < 80 ? 'success' : (floatval($data['usage_percent']) < 95 ? 'warning' : 'error')) ?>">
                                    <?= h($data['usage_percent']) ?>%
                                </div>
                            </div>
                            <div class="stat">
                                <div class="label">📅 تاریخ انقضا</div>
                                <div class="value"><?= h($data['expiry_date']) ?></div>
                            </div>
                            <div class="stat">
                                <div class="label">⏳ روزهای باقیمانده</div>
                                <div class="value <?= ($data['days_remaining'] > 7 ? 'success' : ($data['days_remaining'] > 0 ? 'warning' : 'error')) ?>">
                                    <?= h($data['days_remaining']) ?> روز
                                </div>
                            </div>
                            <div class="stat">
                                <div class="label">🔐 وضعیت</div>
                                <div class="value <?= ($data['is_active'] ? 'success' : 'error') ?>">
                                    <?= ($data['is_active'] ? 'فعال' : 'غیرفعال') ?>
                                </div>
                            </div>
                        </div>
                    </div>

                    <div class="card">
                        <h2>📄 اطلاعات کانفیگ</h2>
                        <div class="config-section">
                            <pre class="config-code">[Interface]
PrivateKey = <?= h($_POST['pk']) ?>
<br>Address = <?= h($data['ip_address']) ?>/24
<br>DNS = 1.1.1.1, 8.8.8.8
MTU = 1420

[Peer]
PublicKey = <?= h($data['server_public_key']) ?>
<br>Endpoint = <?= h($data['server_endpoint']) ?>
<br>AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25</pre>
                        </div>
                        <div class="help">
                            💡 این اطلاعات برای اتصال شما ضروری است. می‌توانید از آن برای تنظیم دستی کلاینت استفاده کنید.
                        </div>
                    </div>
                </div>

                <div>
                    <?php if (!empty($qr_code)): ?>
                    <div class="card">
                        <h2>📱 QR Code</h2>
                        <div class="qr-container">
                            <img src="data:image/png;base64,<?= $qr_code ?>" alt="QR Code" class="qr-image">
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
        <?php elseif (!empty($msg)): ?>
            <div class="card">
                <div class="message error">
                    ❌ <?= h($msg) ?>
                </div>
            </div>
        <?php endif; ?>
    </div>
</body>
</html>
PHP

    # تنظیم مجوزهای فایل PHP
    chown www-data:www-data "$WEB_DIR/index.php" 2>/dev/null || true
    chmod 644 "$WEB_DIR/index.php"
    ok "Web interface created"

    # ایجاد اسکریپت helper برای اطلاعات کلاینت
    cat > /usr/local/bin/wg-client-info <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail

PK="${1:-}"
CLIENT_DB="/etc/wireguard/clients.db"
QUOTA_DB="/etc/wireguard/quota.db"
SERVER_PUB="/etc/wireguard/server_public.key"

if [[ -z "$PK" ]]; then
    echo '{"status":"error","message":"Private key is required"}'
    exit 1
fi

# بررسی وجود دیتابیس
if [[ ! -f "$CLIENT_DB" ]]; then
    echo '{"status":"error","message":"Client database not found"}'
    exit 1
fi

if [[ ! -f "$QUOTA_DB" ]]; then
    echo '{"status":"error","message":"Quota database not found"}'
    exit 1
fi

# جستجوی کلاینت
line=$(grep -F "|$PK|" "$CLIENT_DB" 2>/dev/null | head -n1)

if [[ -z "$line" ]]; then
    echo '{"status":"error","message":"Client not found"}'
    exit 0
fi

IFS='|' read -r name priv pub ip created <<< "$line"

# جستجوی اطلاعات quota
qline=$(grep "^$name|" "$QUOTA_DB" 2>/dev/null | head -n1)

if [[ -z "$qline" ]]; then
    echo '{"status":"error","message":"Quota information not found for client"}'
    exit 0
fi

IFS='|' read -r _ used limit expiry active <<< "$qline"

# اطلاعات سرور
server_public_key=$(cat "$SERVER_PUB" 2>/dev/null || echo "YOUR_SERVER_PUBLIC_KEY")
server_ip=$(curl -fsS4 https://api.ipify.org 2>/dev/null || curl -fsS6 https://api64.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")
server_port=$(grep -oP 'ListenPort\s*=\s*\K\d+' /etc/wireguard/wg0.conf 2>/dev/null || echo "1010")
server_endpoint="$server_ip:$server_port"

# توابع کمکی
to_gb() {
    echo "$1" | awk '{printf "%.2f", $1/1024/1024/1024}'
}

calculate_remaining() {
    local used="$1" limit="$2"
    if [[ "$limit" -eq 0 ]]; then
        echo "Unlimited"
    else
        echo "$used $limit" | awk '{printf "%.2f", ($2 - $1)/1024/1024/1024}'
    fi
}

calculate_percent() {
    local used="$1" limit="$2"
    if [[ "$limit" -eq 0 ]]; then
        echo "0.00"
    else
        echo "$used $limit" | awk '{printf "%.2f", ($1 * 100) / $2}'
    fi
}

calculate_days_remaining() {
    local expiry="$1"
    local now=$(date +%s)
    local exp_seconds=$(date -d "$expiry" +%s 2>/dev/null || echo "$now")
    echo $(( (exp_seconds - now) / 86400 ))
}

# محاسبات
used_gb=$(to_gb "$used")
limit_gb=$(to_gb "$limit")
remaining=$(calculate_remaining "$used" "$limit")
percent=$(calculate_percent "$used" "$limit")
days_remaining=$(calculate_days_remaining "$expiry")

# خروجی JSON
cat << EOF
{
    "status": "success",
    "client_name": "$name",
    "ip_address": "$ip",
    "created_date": "$created",
    "data_used": "$used_gb",
    "data_limit": "$limit_gb",
    "remaining_data": "$remaining",
    "usage_percent": "$percent",
    "expiry_date": "$expiry",
    "days_remaining": $days_remaining,
    "is_active": $active,
    "server_public_key": "$server_public_key",
    "server_endpoint": "$server_endpoint"
}
EOF
BASH

    chmod 755 /usr/local/bin/wg-client-info

    # ایجاد اسکریپت helper برای تولید QR code
    cat > /usr/local/bin/wg-generate-qr <<'BASH'
#!/usr/bin/env bash
set -Eeuo pipefail

PK="${1:-}"
CLIENT_DB="/etc/wireguard/clients.db"

if [[ -z "$PK" ]]; then
    exit 1
fi

# جستجوی کلاینت
line=$(grep -F "|$PK|" "$CLIENT_DB" 2>/dev/null | head -n1)

if [[ -z "$line" ]]; then
    exit 1
fi

IFS='|' read -r name priv pub ip created <<< "$line"

# پیدا کردن فایل کانفیگ
config_file="/etc/wireguard/clients/${name}.conf"

if [[ ! -f "$config_file" ]]; then
    exit 1
fi

# تولید QR code به صورت base64
if command -v qrencode >/dev/null 2>&1; then
    qrencode -t PNG -o - < "$config_file" | base64 -w 0 2>/dev/null || echo ""
else
    echo ""
fi
BASH

    chmod 755 /usr/local/bin/wg-generate-qr
    ok "Helper scripts created"

    # تنظیم دسترسی sudo
    if [[ ! -f /etc/sudoers.d/wg-web ]] || ! grep -q "wg-client-info" /etc/sudoers.d/wg-web 2>/dev/null; then
        cat > /etc/sudoers.d/wg-web <<'SUDO'
www-data ALL=(root) NOPASSWD: /usr/local/bin/wg-client-info
www-data ALL=(root) NOPASSWD: /usr/local/bin/wg-generate-qr
SUDO
        chmod 440 /etc/sudoers.d/wg-web
        ok "Sudo permissions configured"
    fi

    # پیکربندی nginx
    local php_sock=$(detect_php_fpm_sock)
    
    # ایجاد پیکربندی nginx
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
    
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$php_sock;
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

    # فعال کردن سایت
    if [[ -d /etc/nginx/sites-enabled ]]; then
        ln -sf /etc/nginx/sites-available/wireguard /etc/nginx/sites-enabled/ 2>/dev/null || true
        rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
    fi

    # راه‌اندازی سرویس‌ها
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

    # باز کردن پورت 80 در فایروال
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 80/tcp >/dev/null 2>&1 || true
    elif command -v firewall-cmd >/dev/null 2>&1; then
        firewall-cmd --permanent --add-service=http >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    local server_ip=$(public_ip)
    ok "Web UI successfully installed and configured!"
    echo -e "${GREEN}🌐 Web Panel URL:${NC} http://$server_ip/"
    echo -e "${YELLOW}📝 Note:${NC} Make sure port 80 is accessible from your network"
}

# --------------------------- Performance Tweaks -------------------------------
tune_sysctl() {
    log "Applying performance tweaks..."
    cat >> /etc/sysctl.conf <<'EOF'

# WireGuard Performance Tweaks
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl -p >/dev/null 2>&1 || true
    ok "Performance tweaks applied"
}

# --------------------------- Main Installation --------------------------------
do_install() {
    need_root
    detect_os
    update_system
    install_wireguard
    init_databases
    setup_server
    configure_firewall
    enable_start
    install_web
    tune_sysctl
    
    ok "WireGuard installation completed successfully!"
    echo
    echo -e "${GREEN}🎉 Installation Complete!${NC}"
    echo -e "${GREEN}🔑 Server Public Key:${NC} $(cat "$SERVER_PUB" 2>/dev/null || echo "Not generated")"
    echo -e "${GREEN}🌐 Server Endpoint:${NC} $(public_ip):$LISTEN_PORT"
    echo -e "${GREEN}📱 Web Panel:${NC} http://$(public_ip)/"
    echo
    echo -e "${YELLOW}Next steps:${NC}"
    echo -e "  Add a client: $0 add-client username 10 30"
    echo -e "  List clients: $0 list-clients"
}

# --------------------------- Usage --------------------------------------------
usage() {
    cat <<EOF
WireGuard Manager v6.1.0
Usage: $0 [command]

Commands:
  install                       Complete installation (default)
  add-client NAME [GB] [DAYS]  Add client with data quota and expiry
  remove-client NAME           Remove client
  set-quota NAME GB DAYS       Set quota for existing client
  list-clients                 List all clients with quotas
  status                       Show WireGuard status
  web                          Install/update web panel only
  help                         Show this help

Examples:
  $0 install
  $0 add-client john 5 30     # 5GB for 30 days
  $0 add-client jane 0 90     # Unlimited data for 90 days
  $0 list-clients
  $0 remove-client john
EOF
}

# --------------------------- Main Dispatcher ----------------------------------
main() {
    local command="${1:-install}"
    
    case "$command" in
        install)
            do_install
            ;;
        add-client)
            add_client "${2:-}" "${3:-0}" "${4:-30}"
            ;;
        remove-client)
            remove_client "${2:-}"
            ;;
        set-quota)
            quota_set "${2:-}" "${3:-}" "${4:-}"
            ;;
        list-clients)
            list_clients
            ;;
        status)
            wg show "$WG_IFACE" 2>/dev/null || echo "WireGuard is not running"
            ;;
        web)
            install_web
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            err "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# اجرای اصلی
main "$@"
