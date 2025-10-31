markdown
# WireGuard Sale Panel

پنل مدیریت و فروش WireGuard با قابلیت همگام‌سازی خودکار و مانیتورینگ ترافیک

## 📦 نصب پنل اصلی

دستور زیر را در سرور خود اجرا کنید:

```bash
wget -O install.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/main/install.sh
bash install.sh
پس از اجرا، منوی نصب ظاهر می‌شود و می‌توانید با دستور زیر پنل را نصب کنید:

bash
./install.sh install
🔄 اسکریپت مدیریت ترافیک
برای نصب و راه‌اندازی سرویس مانیتورینگ ترافیک:

bash
wget -O wg-quota-monitor.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/main/wg-quota-monitor.sh
bash wg-quota-monitor.sh install-service
systemctl start wg-quota-monitor.service
systemctl status wg-quota-monitor.service
🔄 سرویس همگام‌سازی خودکار
ایجاد سرویس systemd
فایل سرویس را ایجاد کنید:

bash
nano /etc/systemd/system/wg-web-sync.service
محتوای زیر را در فایل قرار دهید:

ini
[Unit]
Description=WireGuard Web Database Sync
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wireguard-manager sync-web-db
User=root
ایجاد تایمر برای اجرای دوره‌ای
فایل تایمر را ایجاد کنید:

bash
nano /etc/systemd/system/wg-web-sync.timer
محتوای زیر را در فایل قرار دهید:

ini
[Unit]
Description=Sync WireGuard Web DB every minute
Requires=wg-web-sync.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
فعال‌سازی تایمر
bash
systemctl daemon-reload
systemctl enable wg-web-sync.timer
systemctl start wg-quota-monitor.service
systemctl status wg-quota-monitor.service
📋 امکانات
✅ نصب آسان پنل مدیریت

✅ مانیتورینگ ترافیک کاربران

✅ همگام‌سازی خودکار با دیتابیس

✅ اجرای دوره‌ای هر 1 دقیقه

✅ مدیریت حرفه‌ای با systemd
