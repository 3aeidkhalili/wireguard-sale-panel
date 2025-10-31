

## 🚀 نصب سریع پنل اصلی

```bash
wget -O install.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/install.sh
```

> پس از اجرای دستور بالا، **منوی نصب** ظاهر می‌شود.  
> برای نصب کامل پنل از دستور زیر استفاده کنید:

```bash
bash ./install.sh install
```

---

## 📊 سرویس مدیریت ترافیک (Quota Monitor)

برای راه‌اندازی سرویس مانیتورینگ ترافیک:

```bash
wget -O wg-quota-monitor.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/wg-quota-monitor.sh
bash wg-quota-monitor.sh install-service
```

سپس سرویس را فعال کنید:

```bash
systemctl start wg-quota-monitor.service
systemctl status wg-quota-monitor.service
```

---

## 🔄 سرویس همگام‌سازی خودکار با دیتابیس وب

### ۱. ایجاد سرویس systemd

```bash
sudo nano /etc/systemd/system/wg-web-sync.service
```

محتوای زیر را قرار دهید:

```ini
[Unit]
Description=WireGuard Web Database Sync
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wireguard-manager sync-web-db
User=root
```

### ۲. ایجاد تایمر برای اجرای هر دقیقه

```bash
sudo nano /etc/systemd/system/wg-web-sync.timer
```

محتوای زیر را قرار دهید:

```ini
[Unit]
Description=Sync WireGuard Web DB every minute
Requires=wg-web-sync.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
Persistent=true

[Install]
WantedBy=timers.target
```

### ۳. فعال‌سازی تایمر

```bash
sudo systemctl daemon-reload
sudo systemctl enable wg-web-sync.timer
sudo systemctl start wg-web-sync.timer
```

---

## 📋 ویژگی‌های پنل

| ویژگی | توضیح |
|------|-------|
| ✅ **نصب آسان و سریع** | فقط با یک دستور |
| ✅ **مدیریت کاربران و پیکربندی** | ایجاد، ویرایش، حذف |
| ✅ **مانیتورینگ لحظه‌ای ترافیک** | نمایش مصرف هر کاربر |
| ✅ **همگام‌سازی خودکار با دیتابیس** | بدون نیاز به دخالت دستی |
| ✅ **رابط کاربری وب** | زیبا و واکنش‌گرا |
| ✅ **گزارش‌گیری کامل** | آمار دقیق و قابل دانلود |

---

## 🛠 وضعیت سرویس‌ها

### وضعیت سرویس مدیریت ترافیک
```bash
systemctl status wg-quota-monitor.service
```

### وضعیت تایمر همگام‌سازی
```bash
systemctl status wg-web-sync.timer
```

### مشاهده لاگ‌های زنده
```bash
journalctl -u wg-quota-monitor.service -f
journalctl -u wg-web-sync.service -f
```

---

## 🔧 عیب‌یابی

در صورت بروز مشکل، موارد زیر را بررسی کنید:

1. **سرویس‌های systemd فعال باشند**
2. **فایل‌های لاگ** را بررسی کنید (`journalctl`)
3. **دسترسی‌های فایل** (`chmod`, `chown`)
4. **اتصال اینترنت سرور**

---

## 📞 پشتیبانی

برای گزارش باگ، درخواست قابلیت جدید یا دریافت کمک:

👉 [**صفحه Issues در GitHub**](https://github.com/3aeidkhalili/wireguard-sale-panel/issues)

---

## ✨ مشارکت در پروژه

ما از مشارکت جامعه متن‌باز استقبال می‌کنیم!  
اگر می‌خواهید کمک کنید:

1. پروژه را **Fork** کنید
2. شاخه جدید بسازید: `git checkout -b feature/awesome`
3. تغییرات را **Commit** کنید: `git commit -m 'Add awesome feature'`
4. **Push** کنید: `git push origin feature/awesome`
5. **Pull Request** بفرستید

---

## ❤️ ساخته شده با عشق برای جامعه متن‌باز

> **"هر خط کد، یک قدم به آزادی دیجیتال"**

---


