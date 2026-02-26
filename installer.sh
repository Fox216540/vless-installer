#!/bin/bash
set -e

CONFIG="/etc/sing-box/config.json"
REALITY_PUB="/etc/sing-box/reality_public.key"
VLESS_INTERNAL_PORT=4431

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ Запусти от root"
    exit 1
  fi
}

ask_install_params() {
  read -p "🌐 SNI СЕРВЕРА для Reality (напр. www.cloudflare.com): " SERVER_SNI
  read -p "👑 Имя admin пользователя: " ADMIN_NAME
  read -p "🚀 Включить Hysteria2? (y/n): " ENABLE_HY2

  if [[ -z "$SERVER_SNI" || -z "$ADMIN_NAME" ]]; then
    echo "❌ Все поля обязательны"
    exit 1
  fi

  if [[ "$ENABLE_HY2" == "y" ]]; then
    read -p "🚀 Порт Hysteria2 (UDP, напр. 8443): " HY_PORT
    if [[ -z "$HY_PORT" ]]; then
      echo "❌ Порт Hysteria2 обязателен"
      exit 1
    fi
  fi
}

ask_client_params() {
  read -p "Введите имя клиента: " NAME

  if [[ -z "$NAME" ]]; then
    echo "❌ Имя обязательно"
    exit 1
  fi

  if [[ "$NAME" == "$ADMIN_NAME" ]]; then
    echo "❌ admin уже существует"
    exit 1
  fi

  echo "Выберите протокол:"
  echo "1) VLESS Reality"
  if [[ "$ENABLE_HY2" == "y" ]]; then
    echo "2) Hysteria2"
  fi

  read -p "Выбор: " P

  if [[ "$P" == "1" ]]; then
    PROTO="vless"
    read -p "🌍 SNI клиента (например ads.x5.ru): " CLIENT_SNI
    if [[ -z "$CLIENT_SNI" ]]; then
      echo "❌ SNI клиента обязателен"
      exit 1
    fi
  elif [[ "$P" == "2" && "$ENABLE_HY2" == "y" ]]; then
    PROTO="hy2"
  else
    echo "❌ Неверный выбор"
    exit 1
  fi
}

install_nginx() {
  apt install -y nginx

  cat > /etc/nginx/nginx.conf <<EOF
worker_processes auto;

events {
  worker_connections 1024;
}

stream {
  server {
    listen 0.0.0.0:443;
    ssl_preread on;
    proxy_pass 127.0.0.1:${VLESS_INTERNAL_PORT};
  }
}
EOF

  nginx -t
  systemctl enable nginx
  systemctl restart nginx
}

install_singbox() {
  echo "🔧 Установка sing-box и nginx..."

  apt update
  apt install -y curl jq openssl
  curl -fsSL https://sing-box.app/install.sh | bash

  install_nginx

  mkdir -p /etc/sing-box

  REALITY_KEYS=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(echo "$REALITY_KEYS" | awk '/PrivateKey/ {print $2}')
  PUBLIC_KEY=$(echo "$REALITY_KEYS" | awk '/PublicKey/ {print $2}')
  echo "$PUBLIC_KEY" > "$REALITY_PUB"

  SHORT_ID=$(openssl rand -hex 8)
  ADMIN_UUID=$(cat /proc/sys/kernel/random/uuid)

  if [[ "$ENABLE_HY2" == "y" ]]; then
    ADMIN_PASS=$(openssl rand -hex 16)
  fi

  # ---------- config.json ----------
  cat > "$CONFIG" <<EOF
{
  "log": { "level": "warn" },

  "inbounds": [
    {
      "type": "vless",
      "tag": "vless",
      "listen": "127.0.0.1",
      "listen_port": ${VLESS_INTERNAL_PORT},
      "users": [
        {
          "uuid": "$ADMIN_UUID",
          "name": "$ADMIN_NAME",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SERVER_SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SERVER_SNI",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
EOF

  if [[ "$ENABLE_HY2" == "y" ]]; then
    cat >> "$CONFIG" <<EOF
,
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": $HY_PORT,
      "up_mbps": 100,
      "down_mbps": 100,
      "users": [
        {
          "name": "$ADMIN_NAME",
          "password": "$ADMIN_PASS"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SERVER_SNI",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    }
EOF
  fi

  cat >> "$CONFIG" <<EOF
  ],
  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

  if [[ "$ENABLE_HY2" == "y" ]]; then
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
      -keyout /etc/sing-box/key.pem \
      -out /etc/sing-box/cert.pem \
      -subj "/CN=$SERVER_SNI"
  fi

  systemctl enable sing-box
  systemctl restart sing-box

  IP=$(curl -s ifconfig.me)

  echo "======================================"
  echo "✅ Установка завершена"
  echo
  echo "ADMIN VLESS:"
  echo "vless://$ADMIN_UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SERVER_SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#ADMIN"
  if [[ "$ENABLE_HY2" == "y" ]]; then
    echo
    echo "ADMIN Hysteria2:"
    echo "hy2://$ADMIN_PASS@$IP:$HY_PORT/?insecure=1#ADMIN"
  fi
  echo "======================================"
  read -p "Enter для входа в меню..."
}

add_client() {
  ask_client_params
  IP=$(curl -s ifconfig.me)

  if [[ "$PROTO" == "vless" ]]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)

    jq '.inbounds[] |= (if .tag=="vless" then .users += [{"uuid":"'"$UUID"'","name":"'"$NAME"'","flow":"xtls-rprx-vision"}] else . end)' \
      "$CONFIG" > /tmp/config.json && mv /tmp/config.json "$CONFIG"

    SID=$(jq -r '.inbounds[] | select(.tag=="vless") | .tls.reality.short_id[0]' "$CONFIG")
    PBK=$(cat "$REALITY_PUB")

    echo
    echo "✅ Клиент добавлен (VLESS)"
    echo "vless://$UUID@$IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$CLIENT_SNI&fp=chrome&pbk=$PBK&sid=$SID&type=tcp#VPN-$NAME"

  elif [[ "$PROTO" == "hy2" ]]; then
    PASS=$(openssl rand -hex 16)

    jq '.inbounds[] |= (if .tag=="hy2" then .users += [{"name":"'"$NAME"'","password":"'"$PASS"'"}] else . end)' \
      "$CONFIG" > /tmp/config.json && mv /tmp/config.json "$CONFIG"

    echo
    echo "✅ Клиент добавлен (Hysteria2)"
    echo "hy2://$PASS@$IP:$HY_PORT/?insecure=1#VPN-$NAME"
  fi

  systemctl restart sing-box
  read -p "Enter..."
}

list_clients() {
  echo "📋 VLESS:"
  jq -r '.inbounds[] | select(.tag=="vless") | .users[] | "Name: \(.name) | UUID: \(.uuid)"' "$CONFIG"

  if [[ "$ENABLE_HY2" == "y" ]]; then
    echo
    echo "📋 Hysteria2:"
    jq -r '.inbounds[] | select(.tag=="hy2") | .users[] | "Name: \(.name) | Password: \(.password)"' "$CONFIG"
  fi

  read -p "Enter..."
}

remove_client() {
  list_clients
  read -p "Введите имя клиента для удаления: " NAME

  if [[ "$NAME" == "$ADMIN_NAME" ]]; then
    echo "❌ Нельзя удалить admin"
    read -p "Enter..."
    return
  fi

  jq '.inbounds[] |= (.users |= map(select(.name != "'"$NAME"'")))' \
    "$CONFIG" > /tmp/config.json && mv /tmp/config.json "$CONFIG"

  systemctl restart sing-box
  echo "🗑 Клиент удалён"
  read -p "Enter..."
}

menu() {
  clear
  echo "=============================="
  echo "   SING-BOX + NGINX MANAGER"
  echo "=============================="
  echo "1) ➕ Добавить клиента"
  echo "2) ➖ Удалить клиента"
  echo "3) 👁 Посмотреть клиентов"
  echo "0) 🚪 Выход"
  echo "=============================="
  read -p "Выбор: " C

  case $C in
    1) add_client ;;
    2) remove_client ;;
    3) list_clients ;;
    0) exit 0 ;;
    *) sleep 1 ;;
  esac
}

check_root

if [ ! -f "$CONFIG" ]; then
  ask_install_params
  install_singbox
fi

while true; do
  menu
done