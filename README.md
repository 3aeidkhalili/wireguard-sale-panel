## ⚡ نصب سریع

### 1️⃣ دانلود و اجرای اسکریپت نصب

```bash
# دانلود اسکریپت نصب
wget -O install.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/main/install.sh

# اجرای نصب کامل
bash install.sh install
```

### 3️⃣ راه‌اندازی سرویس مانیتورینگ

```bash
# دانلود و نصب سرویس کوتا
wget -O wg-quota-monitor.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/main/wg-quota-monitor.sh

# نصب سرویس
bash wg-quota-monitor.sh install-service

# فعال‌سازی
systemctl enable --now wg-quota-monitor.service
```

---

## 🛠️ پیکربندی پیشرفته


### 🔄 سرویس همگام‌سازی وب

```bash
# ایجاد سرویس همگام‌سازی
cat > /etc/systemd/system/wg-web-sync.service << 'EOF'
[Unit]
Description=WireGuard Web Database Sync
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wg-sync-web-db.sh
User=root
StandardOutput=journal
StandardError=journal
EOF

# ایجاد تایمر
cat > /etc/systemd/system/wg-web-sync.timer << 'EOF'
[Unit]
Description=Sync WireGuard Web DB every minute
Requires=wg-web-sync.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# فعال‌سازی
systemctl daemon-reload
systemctl enable --now wg-web-sync.timer
```
تنظیم دسترسی sudo بدون پسورد

```bash
sudo visudo
```
خطوط زیر را اضافه کنید:
```int
www-data ALL=(ALL) NOPASSWD: /bin/systemctl status wg-quick@wg0, /bin/systemctl is-active wg-quick@wg0, /usr/bin/wg show wg0 dump, /bin/ip link show wg0, /bin/ping
```
