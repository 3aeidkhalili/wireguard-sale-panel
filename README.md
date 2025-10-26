# WireGuard Sale Panel
پنل مدیریت و فروش WireGuard با قابلیت مدیریت کلاینت‌ها، محدودیت حجم داده، و تاریخ انقضا. این ابزار به شما امکان می‌دهد تا به راحتی سرور WireGuard خود را نصب، پیکربندی و مدیریت کنید.

---

## پیش‌نیازها
- سیستم‌عامل: **Ubuntu 20.04 یا بالاتر**، **Debian 10 یا بالاتر**
- دسترسی **root** یا کاربر با امتیازات **sudo**
- اتصال اینترنت پایدار

---

## نصب و راه‌اندازی
### ۱. نصب پنل مدیریت WireGuard
برای نصب و پیکربندی کامل WireGuard، دستورات زیر را اجرا کنید:

```bash
wget -O install.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/install.sh
bash install.sh


wget -O wg-quota-monitor.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/wg-quota-monitor.sh
bash wg-quota-monitor.sh install-service
systemctl start wg-quota-monitor.service
systemctl status wg-quota-monitor.service
