#!/usr/bin/env bash
# ============================================================================
# WireGuard Quota Monitor & Auto Disconnect
# Features: Real-time traffic monitoring, quota enforcement, auto disconnect
# Version: 1.0.2
# ============================================================================
set -Eeuo pipefail

# --------------------------- Configuration -----------------------------------
WG_IFACE="wg0"
WG_DIR="/etc/wireguard"
QUOTA_DB="$WG_DIR/quota.db"
CLIENT_DB="$WG_DIR/clients.db"
LOG_FILE="/var/log/wg-quota.log"
CHECK_INTERVAL=60  # seconds
DISABLED_CLIENTS_DIR="$WG_DIR/disabled_clients"
SCRIPT_PATH="$(realpath "$0")"

# --------------------------- Logging -----------------------------------------
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*" >> "$LOG_FILE"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $*"
}

# --------------------------- Helper Functions --------------------------------
bytes_to_gb() {
    echo "$1" | awk '{printf "%.2f", $1/1024/1024/1024}'
}

get_client_public_key() {
    local client_name="$1"
    if [[ ! -f "$CLIENT_DB" ]]; then
        return 1
    fi
    grep "^$client_name|" "$CLIENT_DB" 2>/dev/null | head -n1 | cut -d'|' -f3
}

disable_client() {
    local client_name="$1" client_pubkey="$2" reason="$3"
    
    log "DISABLING CLIENT: $client_name - Reason: $reason"
    
    # حذف از کانفیگ WireGuard
    if [[ -f "$WG_DIR/${WG_IFACE}.conf" ]] && [[ -n "$client_pubkey" ]]; then
        # ایجاد backup از کانفیگ
        cp "$WG_DIR/${WG_IFACE}.conf" "$WG_DIR/${WG_IFACE}.conf.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
        
        # حذف peer از کانفیگ
        if grep -q "PublicKey = $client_pubkey" "$WG_DIR/${WG_IFACE}.conf"; then
            sed -i "/PublicKey = $client_pubkey/,+2d" "$WG_DIR/${WG_IFACE}.conf"
            
            # ریلود کانفیگ
            if systemctl is-active --quiet "wg-quick@${WG_IFACE}" 2>/dev/null; then
                wg syncconf "$WG_IFACE" <(wg-quick strip "$WG_IFACE") >/dev/null 2>&1 || true
            fi
        fi
    fi
    
    # غیرفعال کردن در دیتابیس quota
    if [[ -f "$QUOTA_DB" ]]; then
        local line
        line=$(grep "^$client_name|" "$QUOTA_DB" 2>/dev/null | head -n1)
        if [[ -n "$line" ]]; then
            IFS='|' read -r name used_bytes limit_bytes expiry_date is_active <<< "$line"
            local new_line="$name|$used_bytes|$limit_bytes|$expiry_date|0"
            
            grep -v "^$client_name|" "$QUOTA_DB" > "${QUOTA_DB}.tmp" 2>/dev/null || true
            echo "$new_line" >> "${QUOTA_DB}.tmp"
            mv "${QUOTA_DB}.tmp" "$QUOTA_DB" 2>/dev/null || true
        fi
    fi
    
    # بستن اتصال موجود
    if command -v wg >/dev/null 2>&1 && wg show "$WG_IFACE" peers 2>/dev/null | grep -q "$client_pubkey"; then
        wg set "$WG_IFACE" peer "$client_pubkey" remove 2>/dev/null || true
        log "Connection terminated for client: $client_name"
    fi
    
    # آرشیو کردن کانفیگ کلاینت
    mkdir -p "$DISABLED_CLIENTS_DIR"
    if [[ -f "$WG_DIR/clients/${client_name}.conf" ]]; then
        mv "$WG_DIR/clients/${client_name}.conf" "$DISABLED_CLIENTS_DIR/${client_name}.conf.disabled.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    fi
    
    log "Client $client_name has been disabled: $reason"
}

# --------------------------- Monitoring Functions ----------------------------
update_quota_usage() {
    local client_name="$1" client_pubkey="$2"
    
    if [[ ! -f "$QUOTA_DB" ]] || [[ -z "$client_pubkey" ]]; then
        return 1
    fi
    
    # دریافت ترافیک فعلی از WireGuard
    local current_traffic=0
    if command -v wg >/dev/null 2>&1; then
        current_traffic=$(wg show "$WG_IFACE" transfer 2>/dev/null | grep "$client_pubkey" | awk '{rx+=$2; tx+=$3} END {print rx+tx}' || echo "0")
    fi
    current_traffic=${current_traffic:-0}
    
    # خواندن ترافیک قبلی از دیتابیس
    local old_used_bytes=0
    old_used_bytes=$(grep "^$client_name|" "$QUOTA_DB" 2>/dev/null | head -n1 | cut -d'|' -f2)
    old_used_bytes=${old_used_bytes:-0}
    
    # فقط اگر ترافیک جدید بیشتر باشد آپدیت کنیم (برای جلوگیری از کاهش)
    if [[ $current_traffic -gt $old_used_bytes ]]; then
        # آپدیت دیتابیس
        local line
        line=$(grep "^$client_name|" "$QUOTA_DB" 2>/dev/null | head -n1)
        if [[ -n "$line" ]]; then
            IFS='|' read -r name _ limit_bytes expiry_date is_active <<< "$line"
            local new_line="$name|$current_traffic|$limit_bytes|$expiry_date|$is_active"
            
            grep -v "^$client_name|" "$QUOTA_DB" > "${QUOTA_DB}.tmp" 2>/dev/null || true
            echo "$new_line" >> "${QUOTA_DB}.tmp"
            mv "${QUOTA_DB}.tmp" "$QUOTA_DB" 2>/dev/null || true
            
            log "Updated quota for $client_name: $(bytes_to_gb $old_used_bytes)GB -> $(bytes_to_gb $current_traffic)GB"
        fi
    fi
    
    return 0
}

check_quota_and_expiry() {
    if [[ ! -f "$QUOTA_DB" ]]; then
        log "No quota database found at $QUOTA_DB"
        return 0
    fi
    
    if [[ ! -f "$CLIENT_DB" ]]; then
        log "No client database found at $CLIENT_DB"
        return 0
    fi
    
    local count=0
    local temp_file=$(mktemp)
    
    # استفاده از فایل موقت برای جلوگیری از مشکلات IFS
    grep -v '^#' "$QUOTA_DB" | grep -v '^$' > "$temp_file"
    
    while IFS='|' read -r client_name used_bytes limit_bytes expiry_date is_active; do
        [[ -z "$client_name" ]] && continue
        [[ "$is_active" != "1" ]] && continue
        
        count=$((count + 1))
        local client_pubkey
        client_pubkey=$(get_client_public_key "$client_name")
        
        if [[ -z "$client_pubkey" ]]; then
            log "WARNING: No public key found for client: $client_name"
            continue
        fi
        
        # آپدیت مصرف
        if ! update_quota_usage "$client_name" "$client_pubkey"; then
            log "ERROR: Failed to update quota for $client_name"
            continue
        fi
        
        # خواندن مجدد used_bytes بعد از آپدیت
        local current_used_bytes
        current_used_bytes=$(grep "^$client_name|" "$QUOTA_DB" 2>/dev/null | head -n1 | cut -d'|' -f2)
        current_used_bytes=${current_used_bytes:-0}
        
        # بررسی سقف حجم
        if [[ "$limit_bytes" -gt 0 ]] && [[ "$current_used_bytes" -ge "$limit_bytes" ]]; then
            log "Quota exceeded for $client_name: $(bytes_to_gb $current_used_bytes)GB/$(bytes_to_gb $limit_bytes)GB"
            disable_client "$client_name" "$client_pubkey" "Quota exceeded: $(bytes_to_gb $current_used_bytes)GB/$(bytes_to_gb $limit_bytes)GB"
            continue
        fi
        
        # بررسی تاریخ انقضا
        local current_epoch expiry_epoch days_remaining
        current_epoch=$(date +%s)
        expiry_epoch=$(date -d "$expiry_date" +%s 2>/dev/null || echo "0")
        
        if [[ "$expiry_epoch" -gt 0 ]] && [[ "$current_epoch" -gt "$expiry_epoch" ]]; then
            log "Subscription expired for $client_name: $expiry_date"
            disable_client "$client_name" "$client_pubkey" "Subscription expired on $expiry_date"
            continue
        fi
        
        # هشدار برای نزدیک شدن به انقضا
        if [[ "$expiry_epoch" -gt 0 ]]; then
            days_remaining=$(( (expiry_epoch - current_epoch) / 86400 ))
            if [[ "$days_remaining" -eq 3 ]]; then
                log "WARNING: Client $client_name will expire in 3 days"
            elif [[ "$days_remaining" -eq 1 ]]; then
                log "WARNING: Client $client_name will expire tomorrow"
            elif [[ "$days_remaining" -lt 0 ]]; then
                log "WARNING: Client $client_name expired $((days_remaining * -1)) days ago"
            fi
        fi
        
        # هشدار برای نزدیک شدن به سقف حجم (80% مصرف)
        if [[ "$limit_bytes" -gt 0 ]] && [[ "$current_used_bytes" -gt 0 ]]; then
            local usage_percent
            usage_percent=$(( current_used_bytes * 100 / limit_bytes ))
            if [[ "$usage_percent" -ge 80 ]] && [[ "$usage_percent" -lt 100 ]]; then
                log "WARNING: Client $client_name has used $usage_percent% of quota ($(bytes_to_gb $current_used_bytes)GB/$(bytes_to_gb $limit_bytes)GB)"
            fi
        fi
        
    done < "$temp_file"
    
    rm -f "$temp_file"
    log "Quota check completed. Processed $count clients."
}

# --------------------------- Service Functions -------------------------------
start_monitoring() {
    log "Starting WireGuard Quota Monitor..."
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    chmod 644 "$LOG_FILE"
    
    # بررسی وجود WireGuard (اما اگر نبود هم ادامه بده)
    if ! systemctl is-active --quiet "wg-quick@${WG_IFACE}" 2>/dev/null; then
        log "WARNING: WireGuard interface $WG_IFACE is not active, but continuing anyway..."
    fi
    
    log "Monitoring started. Checking every $CHECK_INTERVAL seconds"
    
    # حلقه اصلی مانیتورینگ
    while true; do
        if check_quota_and_expiry; then
            sleep "$CHECK_INTERVAL"
        else
            log "ERROR: Quota check failed, waiting 10 seconds before retry..."
            sleep 10
        fi
    done
}

stop_monitoring() {
    log "Stopping WireGuard Quota Monitor..."
    pkill -f "wg-quota-monitor.sh monitor" 2>/dev/null || true
    # همچنین سرویس systemd را متوقف کن
    systemctl stop wg-quota-monitor.service 2>/dev/null || true
}

status_monitoring() {
    if pgrep -f "wg-quota-monitor.sh monitor" >/dev/null || systemctl is-active --quiet wg-quota-monitor.service 2>/dev/null; then
        echo "WireGuard Quota Monitor is RUNNING"
        echo "Log file: $LOG_FILE"
        echo "Last 10 log entries:"
        tail -10 "$LOG_FILE" 2>/dev/null || echo "No log entries found"
        
        echo -e "\nCurrent WireGuard status:"
        wg show "$WG_IFACE" 2>/dev/null || echo "WireGuard is not running"
    else
        echo "WireGuard Quota Monitor is STOPPED"
    fi
}

install_service() {
    log "Installing WireGuard Quota Monitor service..."
    
    # ایجاد فایل سرویس systemd
    cat > /etc/systemd/system/wg-quota-monitor.service <<EOF
[Unit]
Description=WireGuard Quota Monitor
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/bin/bash ${SCRIPT_PATH} monitor
Restart=always
RestartSec=10
User=root
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable wg-quota-monitor.service
    
    log "WireGuard Quota Monitor service installed and enabled"
    echo "To start the service, run: systemctl start wg-quota-monitor.service"
}

uninstall_service() {
    systemctl stop wg-quota-monitor.service 2>/dev/null || true
    systemctl disable wg-quota-monitor.service 2>/dev/null || true
    rm -f /etc/systemd/system/wg-quota-monitor.service
    systemctl daemon-reload
    log "WireGuard Quota Monitor service uninstalled"
}

# --------------------------- Debug Function ----------------------------------
debug_check() {
    echo "=== Debug Information ==="
    echo "Script path: $SCRIPT_PATH"
    echo "WireGuard interface: $WG_IFACE"
    echo "WG_DIR: $WG_DIR"
    echo "QUOTA_DB: $QUOTA_DB"
    echo "CLIENT_DB: $CLIENT_DB"
    echo "LOG_FILE: $LOG_FILE"
    
    echo -e "\n=== File Existence ==="
    [[ -f "$QUOTA_DB" ]] && echo "✓ QUOTA_DB exists" || echo "✗ QUOTA_DB missing"
    [[ -f "$CLIENT_DB" ]] && echo "✓ CLIENT_DB exists" || echo "✗ CLIENT_DB missing"
    [[ -f "$WG_DIR/${WG_IFACE}.conf" ]] && echo "✓ WG config exists" || echo "✗ WG config missing"
    
    echo -e "\n=== Service Status ==="
    systemctl is-active "wg-quick@${WG_IFACE}" >/dev/null 2>&1 && echo "✓ WireGuard running" || echo "✗ WireGuard not running"
    
    echo -e "\n=== Sample Quota DB ==="
    head -5 "$QUOTA_DB" 2>/dev/null || echo "Cannot read QUOTA_DB"
    
    echo -e "\n=== Testing Quota Check ==="
    check_quota_and_expiry
}

# --------------------------- Main Dispatcher ----------------------------------
main() {
    local command="${1:-help}"
    
    case "$command" in
        start|monitor)
            start_monitoring
            ;;
        stop)
            stop_monitoring
            ;;
        status)
            status_monitoring
            ;;
        install-service)
            install_service
            ;;
        uninstall-service)
            uninstall_service
            ;;
        check-now)
            check_quota_and_expiry
            ;;
        debug)
            debug_check
            ;;
        help|--help|-h)
            cat <<EOF
WireGuard Quota Monitor v1.0.2
Usage: $0 [command]

Commands:
  start|monitor      Start monitoring in foreground
  stop               Stop monitoring
  status             Show monitoring status and logs
  install-service    Install as systemd service
  uninstall-service  Remove systemd service
  check-now          Run quota check once
  debug              Show debug information
  help               Show this help

Examples:
  $0 install-service    # Install as service
  $0 start              # Start in foreground
  $0 status             # Check status
  $0 check-now          # Manual check
  $0 debug              # Debug information

Service Management:
  systemctl start wg-quota-monitor.service
  systemctl stop wg-quota-monitor.service
  systemctl status wg-quota-monitor.service
  journalctl -u wg-quota-monitor.service -f
EOF
            ;;
        *)
            echo "Unknown command: $command"
            $0 help
            exit 1
            ;;
    esac
}

# اجرای اصلی
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi