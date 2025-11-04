# 🔐 WireGuard Sale Panel | پنل فروش وایرگارد

<div align="center">

![WireGuard](https://img.shields.io/badge/WireGuard-88171A?style=for-the-badge&logo=wireguard&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)
![SQLite](https://img.shields.io/badge/SQLite-07405E?style=for-the-badge&logo=sqlite&logoColor=white)
![PHP](https://img.shields.io/badge/PHP-777BB4?style=for-the-badge&logo=php&logoColor=white)
![License](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)

**سیستم مدیریت و فروش WireGuard با واسط کاربری وب و مانیتورینگ ترافیک**

[📖 مستندات](#-مستندات) • [⚡ نصب سریع](#-نصب-سریع) • [🛠️ پیکربندی](#️-پیکربندی) • [🐛 باگ‌ها](#-گزارش-باگ) • [🤝 مشارکت](#-مشارکت)

</div>

---

## 📋 فهرست مطالب

- [ویژگی‌های کلیدی](#-ویژگی‌های-کلیدی)
- [پیش‌نیازها](#-پیشنیازها)
- [نصب سریع](#-نصب-سریع)
- [پیکربندی پیشرفته](#️-پیکربندی-پیشرفته)
- [مدیریت سرویس‌ها](#️-مدیریت-سرویسها)
- [واسط کاربری وب](#-واسط-کاربری-وب)
- [API و ادغام](#-api-و-ادغام)
- [نظارت و لاگ‌ها](#-نظارت-و-لاگها)
- [عیب‌یابی](#-عیبیابی)
- [امنیت](#-امنیت)
- [پشتیبانی](#-پشتیبانی)

---

## 🚀 ویژگی‌های کلیدی

### 📊 مدیریت کاربران
- ✅ **ایجاد خودکار کاربران** با QR Code
- ✅ **مدیریت کوتا ترافیک** (MB/GB/TB)
- ✅ **تاریخ انقضا** برای هر کاربر
- ✅ **فعال/غیرفعال کردن** کاربران
- ✅ **گروه‌بندی کاربران** (VIP, Premium, Standard)

### 📈 مانیتورینگ ترافیک
- ✅ **نظارت لحظه‌ای** بر مصرف ترافیک
- ✅ **قطع خودکار** هنگام تمام شدن کوتا
- ✅ **آمار دقیق** ورودی و خروجی
- ✅ **گزارش‌گیری روزانه/ماهانه**
- ✅ **نمودارهای تحلیلی** مصرف

### 🌐 واسط کاربری وب
- ✅ **پنل ادمین** کامل و قدرتمند
- ✅ **پنل کاربری** برای مشتریان
- ✅ **رابط موبایل** واکنش‌گرا
- ✅ **چندزبانه** (فارسی/انگلیسی)
- ✅ **تم تاریک/روشن**

### 🔧 ویژگی‌های پیشرفته
- ✅ **پایگاه داده SQLite** سبک و سریع
- ✅ **همگام‌سازی خودکار** با وب
- ✅ **پشتیبان‌گیری خودکار**
- ✅ **لاگ‌های جامع** تمام عملیات
- ✅ **API RESTful** برای ادغام

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

### 2️⃣ پیکربندی اولیه

```bash
# تنظیم پورت و IP سرور
./install.sh configure

# ایجاد کاربر ادمین اول
./install.sh create-admin
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

### 🗄️ پیکربندی پایگاه داده

```bash
# بهینه‌سازی SQLite
sqlite3 /etc/wireguard/clients.db "PRAGMA optimize;"
sqlite3 /etc/wireguard/quota.db "PRAGMA optimize;"

# بررسی یکپارچگی
sqlite3 /etc/wireguard/clients.db "PRAGMA integrity_check;"
```

---

## 🖥️ مدیریت سرویس‌ها

### 🔄 سرویس مانیتورینگ کوتا

```bash
# وضعیت سرویس
systemctl status wg-quota-monitor.service

# مشاهده لاگ‌های زنده
journalctl -u wg-quota-monitor.service -f

# راه‌اندازی مجدد
systemctl restart wg-quota-monitor.service

# توقف سرویس
systemctl stop wg-quota-monitor.service
```

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

## 🔌 API و ادغام

### 📡 RESTful API

```bash
# Base URL
BASE_URL="http://your-domain.com/api"

# Authentication
curl -X POST "$BASE_URL/auth" \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"password"}'

# Get clients list
curl -X GET "$BASE_URL/clients" \
  -H "Authorization: Bearer $TOKEN"

# Create new client
curl -X POST "$BASE_URL/clients" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "client1",
    "quota": "10GB",
    "expire_date": "2024-12-31"
  }'

# Get traffic stats
curl -X GET "$BASE_URL/stats/traffic" \
  -H "Authorization: Bearer $TOKEN"
```

### 🔗 Webhook Integration

```php
// Example webhook for payment systems
// File: /var/www/wireguard/webhook/payment.php

<?php
// Verify payment and create client
$payload = json_decode(file_get_contents('php://input'), true);

if (verify_payment($payload)) {
    $client_name = generate_client_name();
    $quota = $payload['plan']['quota'];
    $expire_days = $payload['plan']['days'];
    
    exec("./wireguard-manager add-client $client_name $quota $expire_days");
    
    // Send config to customer
    send_config_to_customer($payload['email'], $client_name);
}
?>
```

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

### 📈 آمار سیستم

```bash
# آمار کلی ترافیک
wg show wg0

# آمار کاربران فعال
sqlite3 /etc/wireguard/clients.db "SELECT COUNT(*) FROM clients WHERE status='active';"

# Top 10 کاربران پرمصرف
sqlite3 /etc/wireguard/quota.db "
  SELECT client_name, used_bytes/1024/1024/1024 as used_gb 
  FROM quota 
  ORDER BY used_bytes DESC 
  LIMIT 10;
"
```

### 🔔 هشدارهای خودکار

```bash
# اسکریپت هشدار کوتا
cat > /usr/local/bin/quota-alert.sh << 'EOF'
#!/bin/bash
# Alert when client reaches 80% quota

sqlite3 /etc/wireguard/quota.db "
  SELECT client_name, 
         (used_bytes * 100.0 / quota_bytes) as usage_percent
  FROM quota 
  WHERE usage_percent > 80;
" | while read line; do
    echo "Warning: $line" | mail -s "Quota Alert" admin@domain.com
done
EOF

chmod +x /usr/local/bin/quota-alert.sh

# اضافه به cron برای اجرای هر ساعت
echo "0 * * * * /usr/local/bin/quota-alert.sh" | crontab -
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
netstat -tulpn | grep :51820
```

#### 2️⃣ کاربران متصل نمی‌شوند
```bash
# بررسی Firewall
ufw status
iptables -L

# بررسی IP forwarding
sysctl net.ipv4.ip_forward

# تست اتصال
ping -c 3 10.66.66.1
```

#### 3️⃣ سرویس کوتا کار نمی‌کند
```bash
# بررسی وضعیت
systemctl status wg-quota-monitor.service

# بررسی دسترسی‌های فایل
ls -la /etc/wireguard/*.db

# تست دستی
/usr/local/bin/wg-quota-monitor.sh check
```

### 🔍 ابزارهای تشخیص

```bash
# اسکریپت تشخیص خودکار
cat > /usr/local/bin/wg-diagnostics.sh << 'EOF'
#!/bin/bash
echo "=== WireGuard Diagnostics ==="

echo "1. Service Status:"
systemctl is-active wg-quick@wg0.service
systemctl is-active wg-quota-monitor.service

echo "2. Interface Status:"
wg show

echo "3. Database Status:"
sqlite3 /etc/wireguard/clients.db ".schema" 2>/dev/null && echo "Clients DB: OK" || echo "Clients DB: ERROR"

echo "4. Network Status:"
ping -c 1 8.8.8.8 >/dev/null && echo "Internet: OK" || echo "Internet: ERROR"

echo "5. Disk Space:"
df -h /etc/wireguard

echo "6. Memory Usage:"
free -h
EOF

chmod +x /usr/local/bin/wg-diagnostics.sh
```

---

## 🔐 امنیت

### 🛡️ پیکربندی امنیتی

```bash
# 1. محدود کردن دسترسی SSH
echo "Port 22
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes" >> /etc/ssh/sshd_config

# 2. فعال‌سازی Firewall
ufw enable
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp
ufw allow 51820/udp
ufw allow 80/tcp
ufw allow 443/tcp

# 3. محافظت از پایگاه داده‌ها
chmod 640 /etc/wireguard/*.db
chown root:www-data /etc/wireguard/*.db

# 4. رمزگذاری کلیدهای خصوصی
chmod 600 /etc/wireguard/private.key
chmod 600 /etc/wireguard/clients/*_private.key
```

### 🔑 مدیریت کلیدها

```bash
# تولید کلید جدید برای سرور
wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key

# پشتیبان‌گیری کلیدها
tar -czf wireguard-keys-backup-$(date +%Y%m%d).tar.gz /etc/wireguard/*.key

# چرخش کلیدها (هر 6 ماه)
/usr/local/bin/rotate-server-keys.sh
```

### 📋 Audit و Compliance

```bash
# لاگ تمام اتصالات
echo "LogLevel INFO" >> /etc/wireguard/wg0.conf

# نظارت بر تغییرات فایل‌ها
auditctl -w /etc/wireguard/ -p wa -k wireguard-config

# گزارش امنیتی ماهانه
/usr/local/bin/security-report.sh
```

---

## 📚 مستندات تکمیلی

### 📖 راهنماهای تخصصی
- [نصب در محیط تولید](docs/production-setup.md)
- [کانفیگ پیشرفته](docs/advanced-configuration.md)
- [ادغام با سیستم‌های پرداخت](docs/payment-integration.md)
- [مانیتورینگ با Prometheus](docs/monitoring.md)
- [بکاپ و Disaster Recovery](docs/backup-recovery.md)

### 🎥 آموزش‌های ویدئویی
- [نصب گام به گام](https://youtube.com/watch?v=example1)
- [مدیریت کاربران](https://youtube.com/watch?v=example2)
- [عیب‌یابی رایج](https://youtube.com/watch?v=example3)

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

## 📄 مجوز

این پروژه تحت مجوز [MIT License](LICENSE) منتشر شده است.

```
MIT License

Copyright (c) 2024 WireGuard Sale Panel

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.
```

---

## 🌟 ستاره دادن

اگر این پروژه برایتان مفید بود، لطفاً ⭐ ستاره دهید!

---

---

<div align="center">

### ❤️ ساخته شده با عشق برای جامعه متن‌باز

**"هر خط کد، یک قدم به آزادی دیجیتال"**

[![Made with Love](https://img.shields.io/badge/Made%20with-❤️-red.svg)](https://github.com/3aeidkhalili/wireguard-sale-panel)

---

⭐ اگر این پروژه مفید بود، حتماً ستاره بدهید! ⭐

</div>
