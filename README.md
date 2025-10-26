<img width="1680" height="1439" alt="image" src="https://github.com/user-attachments/assets/55725c07-88ff-4afc-9bd9-ff759113efc3" />

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


توجه: اجرای systemctl status wg-quota-monitor.service وضعیت سرویس را نمایش می‌دهد تا از فعال بودن آن مطمئن شوید.


دستورات موجود
پنل مدیریت WireGuard از دستورات زیر پشتیبانی می‌کند:


دستورتوضیحاتinstallنصب و پیکربندی کامل WireGuard (پیش‌فرض)add-client NAME [GB] [DAYS]افزودن کلاینت جدید با نام، محدودیت حجم (گیگابایت) و مدت زمان (روز)remove-client NAMEحذف کلاینت با نام مشخصset-quota NAME GB DAYSتنظیم محدودیت حجم و زمان برای کلاینت موجودlist-clientsنمایش لیست تمام کلاینت‌ها به همراه جزئیات محدودیت‌هاstatusنمایش وضعیت فعلی سرویس WireGuardwebنصب یا به‌روزرسانی پنل وبhelpنمایش راهنمای دستورات

مثال‌های استفاده
برای درک بهتر، چند نمونه از دستورات و کاربردهای آن‌ها آورده شده است:

نصب WireGuard:
bash./install.sh install

افزودن کلاینت جدید (مثال: کلاینت با نام john، محدودیت ۵ گیگابایت برای ۳۰ روز):
bash./install.sh add-client john 5 30

افزودن کلاینت با داده نامحدود (مثال: کلاینت با نام jane برای ۹۰ روز):
bash./install.sh add-client jane 0 90

نمایش لیست کلاینت‌ها:
bash./install.sh list-clients

حذف کلاینت (مثال: حذف کلاینت با نام john):
bash./install.sh remove-client john



نکات مهم

دسترسی root: تمامی دستورات باید با دسترسی root یا از طریق sudo اجرا شوند.
بررسی وضعیت سرویس: پس از نصب سرویس مدیریت حجم، از فعال بودن آن با دستور systemctl status wg-quota-monitor.service مطمئن شوید.
پشتیبانی: در صورت بروز مشکل، از بخش Issues در مخزن گیت‌هاب استفاده کنید یا با توسعه‌دهنده تماس بگیرید.


تماس با ما
برای دریافت پشتیبانی یا گزارش مشکلات، به مخزن گیت‌هاب پروژه مراجعه کنید.
