#!/bin/bash
set -e

CONFIG="/usr/local/etc/xray/config.json"

check_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "❌ Запусти от root"
    exit 1
  fi
}

ask_install_params() {
  read -p "🔌 Введите порт (например 443): " PORT
  read -p "🌐 Введите SNI (например www.cloudflare.com): " SNI

  if [[ -z "$PORT" || -z "$SNI" ]]; then
    echo "❌ Порт и SNI обязательны"
    exit 1
  fi
}

install_xray() {
  echo "🔧 Установка Xray + VLESS Reality"

  apt update
  apt install -y curl socat ufw jq openssl

  curl -fsSL https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh | bash

  UUID=$(cat /proc/sys/kernel/random/uuid)
  KEYS=$(xray x25519)
  PRIVATE_KEY=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
  PUBLIC_KEY=$(echo "$KEYS" | grep Password | awk '{print $2}')
  SHORT_ID=$(openssl rand -hex 8)

  ufw allow $PORT/tcp
  ufw --force enable

  mkdir -p /usr/local/etc/xray

  cat > $CONFIG <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PORT,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "$SNI:443",
          "xver": 0,
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

  systemctl restart xray
  systemctl enable xray

  IP=$(curl -s ifconfig.me)

  echo "======================================"
  echo "✅ VLESS Reality установлен"
  echo "IP: $IP"
  echo "PORT: $PORT"
  echo "UUID: $UUID"
  echo "PUBLIC KEY: $PUBLIC_KEY"
  echo "SHORT ID: $SHORT_ID"
  echo "SNI: $SNI"
  echo
  echo "VLESS ссылка:"
  echo "vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SHORT_ID&type=tcp#VPN"
  echo "======================================"
  read -p "Нажми Enter для входа в меню..."
}

add_client() {
  UUID=$(cat /proc/sys/kernel/random/uuid)

  jq ".inbounds[0].settings.clients += [{\"id\":\"$UUID\",\"flow\":\"xtls-rprx-vision\"}]" \
    $CONFIG > /tmp/config.json && mv /tmp/config.json $CONFIG

  systemctl restart xray

  PORT=$(jq -r '.inbounds[0].port' $CONFIG)
  SNI=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' $CONFIG)
  PRIVATE_KEY=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' $CONFIG)
  PUBLIC_KEY=$(xray x25519 -i "$PRIVATE_KEY" | grep Password | awk '{print $2}')
  SID=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' $CONFIG)
  IP=$(curl -s ifconfig.me)

  echo "✅ Клиент добавлен"
  echo
  echo "vless://$UUID@$IP:$PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SNI&fp=chrome&pbk=$PUBLIC_KEY&sid=$SID&type=tcp#VLESS-$UUID"
  read -p "Enter..."
}

list_clients() {
  echo "📋 Клиенты:"
  jq -r '.inbounds[0].settings.clients[] | "UUID: \(.id)"' "$CONFIG"
  read -p "Enter..."
}

remove_client() {
  list_clients
  read -p "UUID для удаления: " UUID

  jq ".inbounds[0].settings.clients |= map(select(.id != \"$UUID\"))" \
    $CONFIG > /tmp/config.json && mv /tmp/config.json $CONFIG

  systemctl restart xray
  echo "🗑 Клиент удалён"
  read -p "Enter..."
}

remove_all() {
  read -p "⚠️ Удалить Xray полностью? (y/n): " C
  if [[ "$C" == "y" ]]; then
    systemctl stop xray
    systemctl disable xray
    rm -rf /usr/local/etc/xray
    rm -f /usr/local/bin/xray
    rm -f /etc/systemd/system/xray.service
    systemctl daemon-reload
    echo "❌ Xray удалён"
  fi
  exit 0
}

menu() {
  clear
  echo "============================"
  echo "   XRAY VLESS MANAGER"
  echo "============================"
  echo "1) ➕ Добавить клиента"
  echo "2) ➖ Удалить клиента"
  echo "3) 👁  Посмотреть клиентов"
  echo "4) ❌ Удалить VLESS/Xray"
  echo "0) 🚪 Выход"
  echo "============================"
  read -p "Выбор: " CHOICE

  case $CHOICE in
    1) add_client ;;
    2) remove_client ;;
    3) list_clients ;;
    4) remove_all ;;
    0) exit 0 ;;
    *) echo "Неверный выбор"; sleep 1 ;;
  esac
}

check_root

if [ ! -f "$CONFIG" ]; then
  ask_install_params
  install_xray
fi

while true; do
  menu
done
