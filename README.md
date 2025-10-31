در ادامه، یک فایل **`README.md`** حرفه‌ای، مرتب و زیبا برای پروژه **WireGuard Sale Panel** شما در GitHub آماده کردم. این README شامل تمام محتوای شما به صورت ساختارمند، با ایموجی‌های مناسب، کدهای قالبی، استایل‌های بصری و حتی بخش‌های اضافی مثل **Badge** و **Contributing** است.

```markdown
# 📡 WireGuard Sale Panel

**یک پنل مدیریت کامل برای WireGuard** با قابلیت **همگام‌سازی خودکار**، **مدیریت ترافیک** و **رابط کاربری وب** — طراحی شده برای فروش و مدیریت آسان کاربران.

![WireGuard](https://img.shields.io/badge/WireGuard-OpenSource-blue?style=flat-square&logo=wireguard)
![License](https://img.shields.io/github/license/3aeidkhalili/wireguard-sale-panel?style=flat-square)
![Stars](https://img.shields.io/github/stars/3aeidkhalili/wireguard-sale-panel?style=social)

---

## 🚀 نصب سریع پنل اصلی

```bash
wget -O install.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/install.sh
bash install.sh
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

<p align="center">
  <a href="https://github.com/3aeidkhalili/wireguard-sale-panel">⭐ اگر پروژه مفید بود، ستاره بزنید!</a>
</p>

---

<style>
  body {
    font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
    line-height: 1.6;
    color: #333;
    max-width: 900px;
    margin: 0 auto;
    padding: 20px;
    background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
  }
  h1, h2, h3 {
    color: #2c3e50;
    border-bottom: 2px solid #3498db;
    padding-bottom: 10px;
  }
  code {
    background: #f4f4f4;
    padding: 2px 6px;
    border-radius: 4px;
    font-family: 'Courier New', monospace;
  }
  pre {
    background: #2d3748;
    color: #e2e8f0;
    padding: 15px;
    border-radius: 8px;
    overflow-x: auto;
    border-left: 4px solid #3498db;
  }
  table {
    width: 100%;
    border-collapse: collapse;
    margin: 20px 0;
  }
  table th, table td {
    border: 1px solid #ddd;
    padding: 12px;
    text-align: right;
  }
  table th {
    background-color: #3498db;
    color: white;
  }
  blockquote {
    border-right: 4px solid #3498db;
    padding: 0 15px;
    margin: 20px 0;
    color: #7f8c8d;
    font-style: italic;
  }
</style>
```

---

### نکات مهم:
- این README کاملاً **ریسپانسیو** و **خوش‌ظاهر** در GitHub است.
- تمام دستورات به صورت **کپی-پیست** آماده هستند.
- استایل CSS در انتها قرار داده شده تا در **GitHub Pages** یا **Markdown Viewer**ها بهتر نمایش داده شود.
- لینک‌های **Issues**، **Stars** و **License** به صورت خودکار کار می‌کنند.

---

فقط کافی است این محتوا را در `README.md` ریپوزیتوری خود کپی کنید.  
اگر خواستید نسخه انگلیسی هم داشته باشید، بگید تا براتون ترجمه کنم! 🌍
```
