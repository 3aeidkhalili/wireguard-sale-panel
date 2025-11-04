# 🔐 WireGuard Sale Panel | پنل فروش وایرگارد

---

## 🔧 پیش‌نیازها

### سیستم عامل پشتیبانی شده
```bash
# Ubuntu/Debian
Ubuntu 18.04+ / Debian 10+

# CentOS/RHEL
CentOS 7+ / RHEL 7+

# Other
Fedora 30+, Arch Linux
```

### نرم‌افزارهای مورد نیاز
- **Bash** 4.0+
- **WireGuard** (نصب خودکار)
- **SQLite3**
- **PHP** 7.4+ (برای وب پنل)
- **Nginx/Apache** (پیشنهادی: Nginx)
- **Systemd** (برای سرویس‌ها)

---

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

### 📁 ساختار دایرکتوری‌ها

```
/etc/wireguard/
├── wg0.conf                 # پیکربندی اصلی WireGuard
├── clients/                 # کلیدها و فایل‌های کاربران
│   ├── client1.conf
│   ├── client1_private.key
│   └── client1_public.key
├── db/                      # پایگاه داده‌ها
│   ├── clients.db          # اطلاعات کاربران
│   ├── quota.db            # کوتاها و مصرف
│   ├── admin.db            # کاربران ادمین
│   ├── endpoint.db         # تنظیمات endpoint
│   └── dns.db              # تنظیمات DNS
└── disabled_clients/        # کاربران غیرفعال
```

### 🌐 پیکربندی وب سرور

#### Nginx (پیشنهادی)
```nginx
server {
    listen 80;
    server_name your-domain.com;
    root /var/www/wireguard;
    index index.php index.html;

    # Security headers
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-XSS-Protection "1; mode=block" always;

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php7.4-fpm.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
    }

    # Block access to sensitive files
    location ~ /\.(env|git) {
        deny all;
    }
}
```


---

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

---

## 🌐 واسط کاربری وب

### 👨‍💼 پنل ادمین
- **آدرس:** `http://your-domain.com/admin/`
- **ورود:** کاربری که در نصب ایجاد کردید
- **ویژگی‌ها:**
  - مدیریت کاربران (افزودن/حذف/ویرایش)
  - مشاهده آمار ترافیک
  - تنظیمات کوتا و انقضا
  - گزارش‌گیری پیشرفته
  - بکاپ و بازگردانی

### 👤 پنل کاربری
- **آدرس:** `http://your-domain.com/user/`
- **ویژگی‌ها:**
  - مشاهده وضعیت اتصال
  - دانلود فایل پیکربندی
  - QR Code برای موبایل
  - آمار مصرف ترافیک
  - تاریخ انقضا

### 📱 رابط موبایل
- طراحی واکنش‌گرا (Responsive)
- پشتیبانی از PWA
- دسترسی آفلاین به QR Code
- نوتیفیکیشن برای کوتا

---


---

## 📊 نظارت و لاگ‌ها

### 📁 فایل‌های لاگ

```bash
# لاگ اصلی WireGuard
tail -f /var/log/wireguard.log

# لاگ مانیتورینگ کوتا
tail -f /var/log/wg-quota.log

# لاگ همگام‌سازی وب
tail -f /var/log/wg-sync.log

# لاگ سیستم
journalctl -u wg-quota-monitor.service -f
```

---

## 🔧 عیب‌یابی

### ❗ مشکلات رایج

#### 1️⃣ WireGuard شروع نمی‌شود
```bash
# بررسی پیکربندی
wg-quick up wg0

# بررسی لاگ‌ها
journalctl -u wg-quick@wg0.service

# بررسی پورت‌ها
netstat -tulpn | grep :1010
```

#### 2️⃣ کاربران متصل نمی‌شوند
---


## 🤝 مشارکت

ما از مشارکت جامعه متن‌باز استقبال می‌کنیم! 

### 🔄 نحوه مشارکت

1. **Fork** کنید
2. شاخه جدید بسازید: `git checkout -b feature/amazing-feature`
3. تغییرات را commit کنید: `git commit -m 'Add amazing feature'`
4. Push کنید: `git push origin feature/amazing-feature`
5. **Pull Request** بفرستید

### 📝 راهنمای مشارکت

- کد را تمیز و مستند نگه دارید
- تست‌های مناسب اضافه کنید
- از [Conventional Commits](https://www.conventionalcommits.org/) استفاده کنید
- مستندات را به‌روزرسانی کنید

### 🏆 مشارکت‌کنندگان

<a href="https://github.com/3aeidkhalili/wireguard-sale-panel/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=3aeidkhalili/wireguard-sale-panel" />
</a>

---

## 🐛 گزارش باگ

برای گزارش باگ یا درخواست ویژگی جدید:

1. 🔍 ابتدا [Issues موجود](https://github.com/3aeidkhalili/wireguard-sale-panel/issues) را بررسی کنید
2. 📝 [Issue جدید](https://github.com/3aeidkhalili/wireguard-sale-panel/issues/new) ایجاد کنید
3. 📊 اطلاعات سیستم و لاگ‌ها را ضمیمه کنید

### 🛠️ Template گزارش باگ

```markdown
**توضیح باگ:**
توضیح مختصری از مشکل

**مراحل تکرار:**
1. برو به '...'
2. کلیک روی '...'
3. مشاهده خطا

**رفتار مورد انتظار:**
چه اتفاقی باید بیفتد

**اسکرین‌شات:**
در صورت امکان، اسکرین‌شات ضمیمه کنید

**محیط:**
- OS: [Ubuntu 20.04]
- WireGuard Version: [1.0.20210424]
- Panel Version: [6.3.1]
```

---

