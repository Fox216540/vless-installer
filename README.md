# Sing-box + Nginx SNI Manager

Скрипт разворачивает и обслуживает VLESS Reality на базе `sing-box` и `nginx` (stream + SNI routing).

## Что делает

- Устанавливает зависимости: `curl`, `jq`, `openssl`, `nginx`, `libnginx-mod-stream`, `sing-box`
- Создаёт и ведёт хранилище:
  - `/var/lib/sing-box-manager/snis.conf`
  - `/var/lib/sing-box-manager/users.conf`
  - `/var/lib/sing-box-manager/credentials.conf`
- Генерирует постоянные REALITY-ключи (один раз) и использует их повторно
- Строит `sing-box` конфиг: `/etc/sing-box/config.json`
- Строит `nginx` stream-конфиг с маршрутизацией по SNI на порт `443`

## Требования

- Ubuntu/Debian
- root-доступ
- Открыт TCP `443`

## Установка

Сохраните скрипт, например как `start.sh`, сделайте исполняемым и запустите:

```bash
chmod +x start.sh
sudo ./start.sh
```

После первого запуска получите сообщение `✅ Система готова`.

## Команды

```bash
sudo ./start.sh setname "My VPN"
sudo ./start.sh addsni example.com
sudo ./start.sh addsni a.com,b.com
sudo ./start.sh delsni example.com
sudo ./start.sh generateclient alice
sudo ./start.sh delclient alice
sudo ./start.sh view alice
sudo ./start.sh view alice example.com
sudo ./start.sh view alice a.com,b.com
sudo ./start.sh list
```

## Описание команд

- `setname <name>`: задаёт отображаемое имя ссылки (remark). Если не указать имя, сбрасывается.
- `addsni <domain[,domain2]>`: добавляет один или несколько доменов (SNI).
- `delsni <domain[,domain2]>`: удаляет домены.
- `generateclient <name>`: создаёт клиента с UUID.
- `delclient <name>`: удаляет клиента.
- `view <name> [domain[,domain2]]`: печатает VLESS-ссылки для клиента.
- `list`: показывает список доменов и клиентов.

## Примеры сценария

```bash
sudo ./start.sh
sudo ./start.sh addsni cloudflare.com
sudo ./start.sh generateclient user1
sudo ./start.sh setname "Main Profile"
sudo ./start.sh view user1
```

## Где хранятся данные

- Домены: `/var/lib/sing-box-manager/snis.conf`
- Пользователи: `/var/lib/sing-box-manager/users.conf`
- Ключи/параметры Reality: `/var/lib/sing-box-manager/credentials.conf`

## Примечания

- Скрипт должен запускаться от `root`.
- При отсутствии SNI скрипт формирует безопасный fallback-конфиг.
- `view` использует внешний IP через `ifconfig.me`; убедитесь, что сервер имеет исходящий доступ в интернет.
- Для каждого домена создаётся отдельный inbound на локальном порту, начиная с `4431`.
