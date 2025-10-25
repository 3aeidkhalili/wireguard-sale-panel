<img width="639" height="413" alt="image" src="https://github.com/user-attachments/assets/15255ae0-0c7f-4218-ae1f-a9891b06a3bd" />

<img width="619" height="857" alt="image" src="https://github.com/user-attachments/assets/4aa4a9d8-0dfa-48ec-9e27-b7bcf510ecf4" />

<img width="1920" height="945" alt="image" src="https://github.com/user-attachments/assets/61d7af22-b3bc-4a41-abd5-39a5f1753ed2" />

<img width="1920" height="1439" alt="image" src="https://github.com/user-attachments/assets/c15b35af-2a66-403a-856a-32491c150440" />




    (https://raw.githubusercontent.com/3aeidkhalili/wireguard-sale-panel/refs/heads/main/install.sh)



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
