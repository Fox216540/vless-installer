#!/bin/bash
set -e

# --- НАСТРОЙКИ ---
CONFIG_DIR="/etc/sing-box"
DATA_DIR="/var/lib/sing-box-manager"
SNI_FILE="$DATA_DIR/snis.conf"
USER_FILE="$DATA_DIR/users.conf"
CRED_FILE="$DATA_DIR/credentials.conf"
START_PORT=4431
# -----------------

if [ "$EUID" -ne 0 ]; then echo "❌ Запусти от root"; exit 1; fi

mkdir -p "$DATA_DIR" "$CONFIG_DIR"
touch "$SNI_FILE" "$USER_FILE"

# Активация модуля stream для Nginx
if [ ! -f /etc/nginx/modules-enabled/50-mod-stream.conf ]; then
    apt update && apt install -y libnginx-mod-stream
    echo "load_module modules/ngx_stream_module.so;" > /etc/nginx/modules-enabled/50-mod-stream.conf
fi

get_credentials() {
    if [ -f "$CRED_FILE" ]; then
        source "$CRED_FILE"
        # Если IP в файле почему-то пустой, переполучим его
        if [ -z "$SERVER_IP" ]; then
            SERVER_IP=$(curl -s ifconfig.me)
            echo "SERVER_IP=\"$SERVER_IP\"" >> "$CRED_FILE"
        fi
    else
        echo "⚙️ Инициализация сервера..."
        KEYS=$(sing-box generate reality-keypair)
        PRIV_KEY=$(echo "$KEYS" | awk '/PrivateKey/ {print $2}')
        PUB_KEY=$(echo "$KEYS" | awk '/PublicKey/ {print $2}')
        SHORT_ID=$(openssl rand -hex 8)
        SERVER_IP=$(curl -s ifconfig.me)
        cat > "$CRED_FILE" <<EOF
PRIV_KEY="$PRIV_KEY"
PUB_KEY="$PUB_KEY"
SHORT_ID="$SHORT_ID"
SERVER_IP="$SERVER_IP"
EOF
    fi
}

rebuild_configs() {
    get_credentials
    sort -u "$SNI_FILE" -o "$SNI_FILE"
    sed -i '/^$/d' "$SNI_FILE"
    sed -i '/^$/d' "$USER_FILE"
    readarray -t SNI_LIST < "$SNI_FILE"

    USERS_JSON=""
    while IFS=: read -r name uuid; do
        [ -z "$name" ] && continue
        USERS_JSON+="{\"uuid\": \"$uuid\", \"flow\": \"xtls-rprx-vision\", \"name\": \"$name\"},"
    done < "$USER_FILE"
    USERS_JSON=$(echo "${USERS_JSON%,}")

    if [ ${#SNI_LIST[@]} -eq 0 ]; then
        echo "{\"log\": {\"level\": \"warn\"}, \"inbounds\": [], \"outbounds\": [{\"type\": \"direct\"}]}" > "$CONFIG_DIR/config.json"
        cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 1024; }
stream { server { listen 443; return 444; } }
EOF
        systemctl restart nginx sing-box
        return
    fi

    NGINX_MAP=""
    NGINX_UPSTREAMS=""
    SB_INBOUNDS=""
    CURRENT_PORT=$START_PORT

    for sni in "${SNI_LIST[@]}"; do
        UP_NAME="vless_$CURRENT_PORT"
        NGINX_MAP+="        $sni    $UP_NAME;\n"
        NGINX_UPSTREAMS+="    upstream $UP_NAME { server 127.0.0.1:$CURRENT_PORT; }\n"
        SB_INBOUNDS+="$(cat <<EOF
        {
          "type": "vless",
          "tag": "in-$CURRENT_PORT",
          "listen": "127.0.0.1",
          "listen_port": $CURRENT_PORT,
          "users": [ $USERS_JSON ],
          "tls": {
            "enabled": true,
            "server_name": "$sni",
            "reality": {
              "enabled": true,
              "handshake": { "server": "$sni", "server_port": 443 },
              "private_key": "$PRIV_KEY",
              "short_id": ["$SHORT_ID"]
            }
          }
        },
EOF
)\n"
        ((CURRENT_PORT++))
    done

    SB_INBOUNDS=$(echo -e "$SB_INBOUNDS" | sed '$ s/,$//')

    cat > /etc/nginx/nginx.conf <<EOF
user www-data;
worker_processes auto;
include /etc/nginx/modules-enabled/*.conf;
events { worker_connections 1024; }
stream {
    map \$ssl_preread_server_name \$backend_name {
$(echo -e "$NGINX_MAP")
        default fallback;
    }
$(echo -e "$NGINX_UPSTREAMS")
    upstream fallback { server 127.0.0.1:9; }
    server { listen 443; proxy_pass \$backend_name; ssl_preread on; }
}
EOF

    if nginx -t > /dev/null 2>&1; then
        systemctl reload nginx || systemctl restart nginx
    else
        systemctl restart nginx
    fi

    echo "{\"log\": {\"level\": \"warn\"}, \"inbounds\": [ $SB_INBOUNDS ], \"outbounds\": [{\"type\": \"direct\"}]}" > "$CONFIG_DIR/config.json"
    systemctl is-active --quiet sing-box && systemctl kill -s SIGHUP sing-box || systemctl restart sing-box
}

case "$1" in
    addsni)
        if [ -z "$2" ]; then echo "NO DOMAIN"; exit 1; fi
        INPUT_SNIS=${2//,/ }
        for s in $INPUT_SNIS; do
            if ! grep -qxF "$s" "$SNI_FILE"; then
                echo "$s" >> "$SNI_FILE"
                echo "SNI ADD"
            fi
        done
        rebuild_configs > /dev/null
        ;;
    delsni)
        if [ -z "$2" ]; then echo "NO DOMAIN"; exit 1; fi
        INPUT_SNIS=${2//,/ }
        for s in $INPUT_SNIS; do
            sed -i "\|^$s$|d" "$SNI_FILE"
            echo "SNI DELETE"
        done
        rebuild_configs > /dev/null
        ;;
    generateclient)
        if [ -z "$2" ]; then echo "NO NAME"; exit 1; fi
        if grep -q "^$2:" "$USER_FILE"; then
            echo "ALREADY EXIST"
        else
            echo "$2:$(cat /proc/sys/kernel/random/uuid)" >> "$USER_FILE"
            rebuild_configs > /dev/null
            echo "CLIENT ADD"
        fi
        ;;
    delclient)
        if [ -z "$2" ]; then echo "NO NAME"; exit 1; fi
        sed -i "/^$2:/d" "$USER_FILE"
        rebuild_configs > /dev/null
        echo "CLIENT DELETE"
        ;;
    view)
        CLIENT_NAME="$2"
        SPECIFIC_SNIS="$3"
        if [ -z "$CLIENT_NAME" ]; then echo "ERROR VIEW"; exit 1; fi
        USER_DATA=$(grep "^$CLIENT_NAME:" "$USER_FILE") || { echo "NO EXIST"; exit 1; }
        UUID=$(echo "$USER_DATA" | cut -d: -f2)
        get_credentials
        SELECTED_SNIS=${SPECIFIC_SNIS//,/ }
        [ -z "$SELECTED_SNIS" ] && SELECTED_SNIS=$(cat "$SNI_FILE")
        for s in $SELECTED_SNIS; do
            echo "vless://$UUID@$SERVER_IP:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$s&fp=chrome&pbk=$PUB_KEY&sid=$SHORT_ID&type=tcp#$s-$CLIENT_NAME"
        done
        ;;
    list)
        echo -e "\n--- DOMAINS ---"; cat "$SNI_FILE"
        echo -e "\n--- CLIENTS ---"; cut -d: -f1 "$USER_FILE"
        ;;
    *)
        apt update && apt install -y curl jq openssl nginx libnginx-mod-stream
        [ ! -x "$(command -v sing-box)" ] && bash <(curl -fsSL https://sing-box.app/install.sh)
        rebuild_configs
        echo "DONE"
        ;;
esac
