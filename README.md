<img width="1920" height="2052" alt="image" src="https://github.com/user-attachments/assets/cae2eb86-e47e-4842-badf-05ad799c1d20" />
اسکریپت اصلی :
دستور زیر را در سرور کپی و enter کنید بعد از ظاهر شدن منو با کامنت ```./install.sh install``` میتوانید پنل را نصب بکنید 
```bash
wget -O install.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/install.sh
bash install.sh

اسکریپت مدیریت ترافیک : همین دستورات داخل سرور کپی پیست کنید نصب و اجرا میشود

wget -O wg-quota-monitor.sh https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/wg-quota-monitor.sh
bash wg-quota-monitor.sh install-service
systemctl start wg-quota-monitor.service
systemctl status wg-quota-monitor.service

```





