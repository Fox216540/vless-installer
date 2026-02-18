#!/bin/bash
set -e

CONFIG="/etc/sing-box/config.json"
REALITY_PUB="/etc/sing-box/reality_public.key"

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ Запусти от root"
    exit 1
  fi
}

ask_install_params() {
  read -p "🔌 Порт VLESS Reality (TCP, напр. 443): " VLESS_PORT
  read -p "🌐 SNI для Reality/Hysteria2 (напр. www.cloudflare.com): " SNI
  read -p "🚀 Порт Hysteria2 (UDP, напр. 8443): " HY_PORT
  read -p "👑 Имя admin пользователя: " ADMIN_NAME

  if [[ -z "$VLESS_PORT" || -z "$SNI" || -z "$HY_PORT" || -z "$ADMIN_NAME" ]]; then
    echo "❌ Все поля обязательны"
    exit 1
  fi
}

ask_client_params() {
  read -p "Введите имя клиента: " NAME
  echo "Выберите протокол:"
  echo "1) VLESS Reality"
  echo "2) Hysteria2"
  read -p "Выбор (1/2): " P

  if [[ -z "$NAME" ]]; then
    echo "❌ Имя обязательно"
    exit 1
  fi

  if [[ "$NAME" == "$ADMIN_NAME" ]]; then
    echo "❌ admin уже существует"
    exit 1
  fi

  if [[ "$P" == "1" ]]; then
    PROTO="vless"
  elif [[ "$P" == "2" ]]; then
    PROTO="hy2"
  else
    echo "❌ Неверный выбор"
    exit 1
  fi
}

install_singbox() {
  echo "🔧 Установка sing-box..."

  apt update
  apt install -y curl jq openssl
  curl -fsSL https://sing-box.app/install.sh | bash

  mkdir -p /etc/sing-box

  # Reality keypair
  REALITY_KEYS=$(sing-box generate reality-keypair)
  PRIVATE_KEY=$(echo "$REALITY_KEYS" | awk '/PrivateKey/ {print $2}')
  PUBLIC_KEY=$(echo "$REALITY_KEYS" | awk '/PublicKey/ {print $2}')
  echo "$PUBLIC_KEY" > "$REALITY_PUB"

  SHORT_ID=$(openssl rand -hex 8)

  ADMIN_UUID=$(cat /proc/sys/kernel/random/uuid)
  ADMIN_PASS=$(openssl rand -hex 16)

  cat > "$CONFIG" <<EOF
{
  "log": { "level": "warn" },

  "inbounds": [
    {
      "tcp_keep_alive": "30s",
      "type": "vless",
      "tag": "vless",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [
        {
          "uuid": "$ADMIN_UUID",
          "name": "$ADMIN_NAME",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    },
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
        "server_name": "$SNI",
        "certificate_path": "/etc/sing-box/cert.pem",
        "key_path": "/etc/sing-box/key.pem"
      }
    }
  ],

  "outbounds": [
    { "type": "direct" }
  ]
}
EOF

  # self-signed TLS для Hysteria2
  openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
    -keyout /etc/sing-box/key.pem \
    -out /etc/sing-box/cert.pem \
    -subj "/CN=$SNI"

  systemctl enable sing-box
  systemctl restart sing-box

  IP=$(curl -s ifconfig.me)

  echo "======================================"
  echo "✅ sing-box установлен"
  echo
  echo "ADMIN VLESS:"
  echo "vless://$ADMIN_UUID@$IP:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#VPN"
  echo
  echo "ADMIN Hysteria2:"
  echo "hy2://$ADMIN_PASS@$IP:$HY_PORT/?insecure=1#VPN"
  echo "======================================"
  read -p "Enter для входа в меню..."
}

add_client() {
  ask_client_params
  IP=$(curl -s ifconfig.me)

  if [[ "$PROTO" == "vless" ]]; then
    UUID=$(cat /proc/sys/kernel/random/uuid)

    jq '.inbounds[] |= (
      if .tag=="vless" then
        .users += [{"uuid":"'"$UUID"'","name":"'"$NAME"'","flow":"xtls-rprx-vision"}]
      else . end
    )' "$CONFIG" > /tmp/config.json && mv /tmp/config.json "$CONFIG"

    PORT=$(jq -r '.inbounds[] | select(.tag=="vless") | .listen_port' "$CONFIG")
    SNI=$(jq -r '.inbounds[] | select(.tag=="vless") | .tls.server_name' "$CONFIG")
    SID=$(jq -r '.inbounds[] | select(.tag=="vless") | .tls.reality.short_id[0]' "$CONFIG")
    PBK=$(cat "$REALITY_PUB")

    echo
    echo "✅ Клиент добавлен (VLESS)"
    echo "vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PBK&sid=$SID&type=tcp#VPN"

  else
    PASS=$(openssl rand -hex 16)

    jq '.inbounds[] |= (
      if .tag=="hy2" then
        .users += [{"name":"'"$NAME"'","password":"'"$PASS"'"}]
      else . end
    )' "$CONFIG" > /tmp/config.json && mv /tmp/config.json "$CONFIG"

    PORT=$(jq -r '.inbounds[] | select(.tag=="hy2") | .listen_port' "$CONFIG")

    echo
    echo "✅ Клиент добавлен (Hysteria2)"
    echo "hy2://$PASS@$IP:$PORT/?insecure=1#VPN"
  fi

  systemctl restart sing-box
  read -p "Enter..."
}

list_clients() {
  echo "📋 VLESS:"
  jq -r '.inbounds[] | select(.tag=="vless") | .users[] | "Name: \(.name) | UUID: \(.uuid)"' "$CONFIG"
  echo
  echo "📋 Hysteria2:"
  jq -r '.inbounds[] | select(.tag=="hy2") | .users[] | "Name: \(.name) | Password: \(.password)"' "$CONFIG"
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

  jq '.inbounds[] |= (
    .users |= map(select(.name != "'"$NAME"'"))
  )' "$CONFIG" > /tmp/config.json && mv /tmp/config.json "$CONFIG"

  systemctl restart sing-box
  echo "🗑 Клиент удалён"
  read -p "Enter..."
}

remove_all() {
  read -p "⚠️ Удалить sing-box полностью? (y/n): " C
  if [[ "$C" == "y" ]]; then
    systemctl stop sing-box
    systemctl disable sing-box
    rm -rf /etc/sing-box
    rm -f /usr/local/bin/sing-box
    rm -f /etc/systemd/system/sing-box.service
    systemctl daemon-reload
    echo "❌ sing-box удалён"
  fi
  exit 0
}

menu() {
  clear
  echo "=============================="
  echo "     SING-BOX MANAGER"
  echo "=============================="
  echo "1) ➕ Добавить клиента"
  echo "2) ➖ Удалить клиента"
  echo "3) 👁 Посмотреть клиентов"
  echo "4) ❌ Удалить sing-box"
  echo "0) 🚪 Выход"
  echo "=============================="
  read -p "Выбор: " C

  case $C in
    1) add_client ;;
    2) remove_client ;;
    3) list_clients ;;
    4) remove_all ;;
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
