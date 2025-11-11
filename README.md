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


<img width="1920" height="1425" alt="image" src="https://github.com/user-attachments/assets/9a50ec33-b909-483b-8330-029e9f3a1d15" />
<img width="1920" height="2209" alt="image" src="https://github.com/user-attachments/assets/1d01995d-8fb3-42cd-890d-ba6890e413f1" />
<img width="1920" height="945" alt="image" src="https://github.com/user-attachments/assets/cba324dc-d2b1-4263-ade0-4caba6f91bde" />
<img width="1920" height="1635" alt="image" src="https://github.com/user-attachments/assets/5fb3a7f3-c472-4125-94a8-b07efded8e93" />
<img width="1920" height="1697" alt="image" src="https://github.com/user-attachments/assets/9bcd3814-0e16-4145-92bd-0949a5fd4e34" />







