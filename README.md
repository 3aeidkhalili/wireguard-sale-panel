
دستورات نصب پنل :

wget -O install.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/install.sh

bash install.sh

دستورات نصب سیستم مدیریت حجم :

wget -O wg-quota-monitor.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/wg-quota-monitor.sh

bash wg-quota-monitor.sh install-service

systemctl start wg-quota-monitor.service
systemctl status wg-quota-monitor.service
دستورات

install: نصب و پیکربندی کامل WireGuard (پیش‌فرض)<br>
add-client NAME [GB] [DAYS]: افزودن کلاینت با محدودیت داده و تاریخ انقضا<br>
remove-client NAME: حذف کلاینت<br>
set-quota NAME GB DAYS: تنظیم محدودیت داده برای کلاینت موجود<br>
list-clients: نمایش لیست تمام کلاینت‌ها با محدودیت‌هایشان<br>
status: نمایش وضعیت WireGuard<br>
web: نصب یا به‌روزرسانی پنل وب<br>
help: نمایش راهنما<br>

مثال‌ها

./install.sh install<br>
./install.sh add-client john 5 30 # 5 گیگابایت برای 30 روز<br>
./install.sh add-client jane 0 90 # داده نامحدود برای 90 روز<br>
./install.sh list-clients<br>
./install.sh remove-client john<br>
