📡 راهنمای نصب پنل مدیریت WireGuard
یک پنل مدیریت کامل برای WireGuard با قابلیت همگام‌سازی خودکار و مدیریت ترافیک

🚀 نصب سریع
پنل اصلی WireGuard
bash
wget -O install.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/install.sh
bash install.sh
بعد از اجرای دستور بالا، منوی نصب ظاهر می‌شود. برای نصب کامل پنل از دستور زیر استفاده کنید:

bash
./install.sh install
📊 سرویس مدیریت ترافیک
برای نصب و راه‌اندازی سرویس مانیتورینگ ترافیک، دستورات زیر را اجرا کنید:

bash
wget -O wg-quota-monitor.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/wg-quota-monitor.sh
bash wg-quota-monitor.sh install-service
systemctl start wg-quota-monitor.service
systemctl status wg-quota-monitor.service
🔄 سرویس همگام‌سازی خودکار
برای راه‌اندازی سرویس همگام‌سازی خودکار با دیتابیس وب، مراحل زیر را دنبال کنید:

1. ایجاد سرویس systemd
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
2. ایجاد تایمر برای اجرای دوره‌ای
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
3. فعال‌سازی تایمر
bash
systemctl daemon-reload
systemctl enable wg-web-sync.timer
systemctl start wg-web-sync.timer
📋 ویژگی‌های پنل
✅ نصب آسان و سریع

✅ مدیریت کاربران و پیکربندی

✅ مانیتورینگ لحظه‌ای ترافیک

✅ همگام‌سازی خودکار با دیتابیس

✅ رابط کاربری وب

✅ گزارش‌گیری کامل

🛠 وضعیت سرویس‌ها
برای بررسی وضعیت سرویس‌ها از دستورات زیر استفاده کنید:

bash
# وضعیت سرویس مدیریت ترافیک
systemctl status wg-quota-monitor.service

# وضعیت تایمر همگام‌سازی
systemctl status wg-web-sync.timer

# مشاهده لاگ‌های سرویس
journalctl -u wg-quota-monitor.service -f
journalctl -u wg-web-sync.service -f
🔧 عیب‌یابی
در صورت بروز مشکل:

از فعال بودن سرویس systemd اطمینان حاصل کنید

فایل‌های لاگ را بررسی کنید

از صحت دسترسی‌های فایل‌ها مطمئن شوید

اتصال اینترنت سرور را بررسی کنید

📞 پشتیبانی
برای دریافت پشتیبانی و گزارش مشکلات به ریپوزیتوری پروژه مراجعه کنید.

<div align="center"> ✨ **ساخته شده با ❤️ برای جامعه متن‌باز** ✨ </div><style> body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; line-height: 1.6; color: #333; max-width: 900px; margin: 0 auto; padding: 20px; background: linear-gradient(135deg, #667eea 0%, #764ba2 100%); } h1, h2, h3 { color: #2c3e50; border-bottom: 2px solid #3498db; padding-bottom: 10px; } code { background: #f4f4f4; padding: 2px 6px; border-radius: 4px; font-family: 'Courier New', monospace; } pre { background: #2d3748; color: #e2e8f0; padding: 15px; border-radius: 8px; overflow-x: auto; border-left: 4px solid #3498db; } blockquote { border-left: 4px solid #3498db; padding-left: 15px; margin-left: 0; color: #7f8c8d; } </style>
