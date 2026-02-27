# 🚀 Sing-box VLESS Reality Manager

Bash-скрипт для **автоматической установки и управления sing-box + Nginx (stream)** с протоколом **VLESS Reality** на Linux-серверах (Ubuntu / Debian).

Подходит для быстрого развёртывания VPN без TLS-сертификатов с маршрутизацией по **SNI** на `443`.

---

## ✨ Возможности

- ⚙️ Автоустановка `sing-box`, `nginx` и зависимостей
- 🔐 Генерация постоянных Reality-ключей (`PrivateKey`, `PublicKey`, `ShortID`)
- 🌐 Поддержка нескольких SNI-доменов
- ➕ Добавление клиентов (UUID генерируется автоматически)
- ➖ Удаление клиентов
- 👁 Просмотр клиентов и доменов
- 🔗 Генерация готовых VLESS-ссылок
- 🏷 Установка общего имени ссылки (`setname`)
- ♻️ Автопересборка конфигов `sing-box` и `nginx` после изменений

---

## 🖥 Требования

- ОС: **Ubuntu / Debian**
- Права: **root**
- Открытый TCP-порт: **443**
- Валидные SNI-домены (например: `www.cloudflare.com`)

---

## 🚀 Установка

### 1️⃣ Клонировать файл
```bash
wget https://raw.githubusercontent.com/Fox216540/vless-installer/main/installer.sh -O installer.sh
```

### 2️⃣ Дать права на выполнение
```bash
chmod +x installer.sh
```

### 3️⃣ Запустить от root
```bash
sudo ./installer.sh
```

После первого запуска скрипт установит всё необходимое и выведет: `✅ Система готова`.

---

## 🧩 Команды

### 🌐 Управление доменами (SNI)

```bash
sudo ./installer.sh addsni example.com
sudo ./installer.sh addsni a.com,b.com
sudo ./installer.sh delsni example.com
```

### 👤 Управление клиентами

```bash
sudo ./installer.sh generateclient alice
sudo ./installer.sh delclient alice
```

### 🔗 Просмотр ссылок

```bash
sudo ./installer.sh view alice
sudo ./installer.sh view alice example.com
sudo ./installer.sh view alice a.com,b.com
```

### 🏷 Имя ссылок (remark)

```bash
sudo ./installer.sh setname "My VPN"
```

Если имя не задано, используется имя клиента.

### 📋 Список доменов и клиентов

```bash
sudo ./installer.sh list
```

---

## ⚡ Быстрый сценарий

```bash
sudo ./installer.sh
sudo ./installer.sh addsni www.cloudflare.com
sudo ./installer.sh generateclient user1
sudo ./installer.sh setname "Main Profile"
sudo ./installer.sh view user1
```

---

## 📂 Где хранятся данные

- Домены (SNI): `/var/lib/sing-box-manager/snis.conf`
- Клиенты: `/var/lib/sing-box-manager/users.conf`
- Ключи Reality и имя ссылок: `/var/lib/sing-box-manager/credentials.conf`
- Конфиг `sing-box`: `/etc/sing-box/config.json`
- Конфиг `nginx`: `/etc/nginx/nginx.conf`

---

## 📝 Примечания

- Скрипт всегда нужно запускать от `root`.
- При пустом списке SNI поднимается fallback-конфиг (без рабочих inbound).
- Для генерации ссылок используется внешний IP через `ifconfig.me`.
- Для каждого SNI создаётся отдельный inbound, начиная с локального порта `4431`.

