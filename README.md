

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
nano /usr/local/bin/wg-sync-web-db.sh
```

محتوای زیر را قرار دهید:

```ini
#!/bin/bash
# Script to sync web database

WG_DIR="/etc/wireguard"
WEB_DIR="/var/www/wireguard"

# Detect web user
if getent passwd nginx >/dev/null; then
    web_user="nginx"
else
    web_user="www-data"
fi

# Sync databases
for db_file in "clients.db" "quota.db" "admin.db" "endpoint.db" "dns.db"; do
    if [[ -f "$WG_DIR/$db_file" ]]; then
        cp "$WG_DIR/$db_file" "$WEB_DIR/db/$db_file"
        chown "$web_user:$web_user" "$WEB_DIR/db/$db_file"
        chmod 640 "$WEB_DIR/db/$db_file"
    fi
done

# Sync clients directory
if [[ -d "$WG_DIR/clients" ]]; then
    rsync -aq "$WG_DIR/clients/" "$WEB_DIR/clients/"
    chown -R "$web_user:$web_user" "$WEB_DIR/clients"
    find "$WEB_DIR/clients" -type f -name "*_private.key" -exec chmod 600 {} \;
    find "$WEB_DIR/clients" -type f -name "*_public.key" -exec chmod 644 {} \;
    find "$WEB_DIR/clients" -type f -name "*.conf" -exec chmod 644 {} \;
    chmod 750 "$WEB_DIR/clients"
fi

echo "$(date): Web databases synced" >> /var/log/wg-sync.log
```

### ۲. ایجاد تایمر برای اجرای هر دقیقه

```bash
chmod +x /usr/local/bin/wg-sync-web-db.sh
```

محتوای زیر را قرار دهید:

```ini
crontab -e
```

### ۳. فعال‌سازی تایمر

```bash
* * * * * /usr/local/bin/wg-sync-web-db.sh >/dev/null 2>&1
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


### مشاهده لاگ‌های زنده
```bash
journalctl -u wg-quota-monitor.service -f
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


