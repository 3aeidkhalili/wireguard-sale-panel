<div align="center">

# WireGuard Sale Panel  
### پنل فروش حرفه‌ای کانفیگ WireGuard  

[![GitHub stars](https://img.shields.io/github/stars/3aeidkhalili/wireguard-sale-panel?style=social)](https://github.com/3aeidkhalili/wireguard-sale-panel/stargazers)
[![GitHub license](https://img.shields.io/github/license/3aeidkhalili/wireguard-sale-panel?color=blue)](LICENSE)
[![Python](https://img.shields.io/badge/Python-3.9%2B-blue?logo=python)](https://python.org)
[![Django](https://img.shields.io/badge/Django-4.2%2B-green?logo=django)](https://djangoproject.com)
[![Docker](https://img.shields.io/badge/Docker-Supported-blue?logo=docker)](https://docker.com)

> **پنل فروش کاملاً خودکار کانفیگ WireGuard با رابط کاربری زیبا، پرداخت آنلاین، مدیریت سرور و کاربران.**

![Panel Preview](https://github.com/3aeidkhalili/wireguard-sale-panel/blob/main/screenshots/dashboard.png?raw=true)

[Demo](https://demo.wireguardsale.ir) · [Documentation](#-documentation) · [Installation](#-installation)

</div>

---

## ویژگی‌های کلیدی

| ویژگی | توضیح |
|-------|-------|
| **فروش خودکار کانفیگ** | کاربران کانفیگ رو خریداری می‌کنن و به صورت خودکار ساخته و تحویل داده می‌شه |
| **پرداخت آنلاین** | پشتیبانی از درگاه‌های زرین‌پال، نکست‌پی و کریپتو (ترون، یو‌اس‌دی‌تی) |
| **مدیریت چند سرور** | اتصال به چندین سرور WireGuard و مدیریت یکپارچه |
| **پنل ادمین حرفه‌ای** | آمار کامل، مدیریت کاربران، سرورها، تراکنش‌ها و تنظیمات |
| **رابط کاربری واکنش‌گرا** | طراحی مدرن با Tailwind CSS و Dark Mode |
| **ساخت QR Code و فایل کانفیگ** | تحویل فوری به کاربر پس از پرداخت |
| **محدودیت ترافیک/زمان** | تنظیم حجم و زمان انقضا برای هر پلن |
| **نوتیفیکیشن تلگرام** | اطلاع‌رسانی پرداخت و انقضای کانفیگ به ادمین و کاربر |

---

## پیش‌نمایش

<div align="center">
  <img src="https://github.com/3aeidkhalili/wireguard-sale-panel/blob/main/screenshots/user-panel.png?raw=true" width="48%" alt="User Panel" />
  <img src="https://github.com/3aeidkhalili/wireguard-sale-panel/blob/main/screenshots/admin-dashboard.png?raw=true" width="48%" alt="Admin Dashboard" />
</div>

---

## نصب سریع (Docker)

```bash
git clone https://github.com/3aeidkhalili/wireguard-sale-panel.git
cd wireguard-sale-panel
cp .env.example .env
docker-compose up -d
