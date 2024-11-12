#!/bin/bash

# ========================
# 一键安装 WireGuard + VLESS (xtls-rprx-vision) + XTLS + QUIC
# ========================

# 设置必要变量
SERVER_IP=$(curl -s ifconfig.me)  # 获取服务器外网IP
WG_PORT=51820                    # WireGuard 端口
VLESS_PORT=443                   # VLESS 端口 (通常使用443作为HTTPS端口)
QUIC_KEY=$(openssl rand -base64 32)  # 随机生成 QUIC key
VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)  # 随机生成 UUID
CERT_DIR="/etc/xray"             # XTLS 证书存放路径
CERT_FILE="$CERT_DIR/certificate.crt"
KEY_FILE="$CERT_DIR/private.key"

# 所需开放的端口
REQUIRED_PORTS=("51820" "443")

# 检查端口是否已开放
check_and_open_ports() {
    for PORT in "${REQUIRED_PORTS[@]}"; do
        if ! netstat -tuln | grep -q ":$PORT"; then
            echo "端口 $PORT 未开放，正在尝试打开该端口..."
            ufw allow $PORT
        else
            echo "端口 $PORT 已开放。"
        fi
    done
}

# 安装 WireGuard
install_wireguard() {
    echo "安装 WireGuard ..."
    apt update && apt upgrade -y
    apt install -y wireguard
}

# 安装 Xray
install_xray() {
    echo "安装 Xray ..."
    bash <(curl -s -L https://github.com/XTLS/Xray-install/releases/latest/download/install-release.sh)
}

# 配置 WireGuard
configure_wireguard() {
    echo "配置 WireGuard ..."
    mkdir -p /etc/wireguard
    wg genkey | tee /etc/wireguard/private.key | wg pubkey > /etc/wireguard/public.key
    local private_key=$(cat /etc/wireguard/private.key)
    local public_key=$(cat /etc/wireguard/public.key)
    
    cat > /etc/wireguard/wg0.conf <<EOF
[Interface]
PrivateKey = $private_key
Address = 10.0.0.1/24
ListenPort = $WG_PORT

[Peer]
PublicKey = $public_key
AllowedIPs = 10.0.0.2/32
EOF

    wg-quick up wg0
    systemctl enable wg-quick@wg0
}

# 获取证书 (如果使用 Let's Encrypt)
get_lets_encrypt_cert() {
    echo "获取 Let's Encrypt 证书 ..."
    
    # 让用户输入域名和邮件
    for i in {1..3}; do
        read -p "请输入用于申请证书的域名: " DOMAIN
        read -p "请输入您的电子邮件地址: " EMAIL

        # 验证域名格式
        if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
            echo "域名格式不正确，请重新输入。"
            continue
        fi

        # 验证邮件格式
        if [[ ! "$EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,4}$ ]]; then
            echo "邮件格式不正确，请重新输入。"
            continue
        fi

        # 进行 Let's Encrypt 证书申请
        certbot certonly --standalone -d "$DOMAIN" --agree-tos --no-eff-email --email "$EMAIL"
        
        if [[ $? -eq 0 ]]; then
            # 复制证书
            cp /etc/letsencrypt/live/$DOMAIN/fullchain.pem $CERT_FILE
            cp /etc/letsencrypt/live/$DOMAIN/privkey.pem $KEY_FILE
            echo "证书获取成功!"
            break
        else
            echo "证书申请失败，请检查域名和邮件地址，或者稍后再试。"
        fi

        # 如果连续 3 次失败，停止脚本
        if [[ $i -eq 3 ]]; then
            echo "输入错误超过三次，脚本终止执行。"
            exit 1
        fi
    done
}

# 配置 Xray + VLESS + XTLS + QUIC
configure_xray() {
    echo "配置 Xray 服务 ..."

    # 创建配置目录
    mkdir -p $CERT_DIR

    # 生成 Xray 配置文件
    cat > /etc/xray/config.json <<EOF
{
  "inbounds": [
    {
      "port": $VLESS_PORT,
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$VLESS_UUID",
            "alterId": 0,
            "level": 1
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "quic",
        "quicSettings": {
          "key": "$QUIC_KEY",
          "security": "none"
        },
        "xtlsSettings": {
          "flow": "xtls-rprx-vision",
          "certificates": [
            {
              "certificateFile": "$CERT_FILE",
              "keyFile": "$KEY_FILE"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF

    # 启动 Xray 服务
    systemctl restart xray
    systemctl enable xray
}

# 生成订阅链接
generate_subscribe_link() {
    echo "生成订阅链接 ..."

    # 创建订阅链接
    SUBSCRIBE_URL="vless://$VLESS_UUID@$SERVER_IP:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$SERVER_IP&fp=chrome&pbk=5crdaiZoni_05bh1iZKDgIbiqBH7y0vlBiqbkEcx8ms&sid=725f8cc2&type=quic&headerType=none#vless-quic-link"

    echo "订阅链接生成完毕！"
    echo "VLESS 订阅链接: $SUBSCRIBE_URL"
}

# 安装依赖
install_dependencies() {
    apt install -y curl wget lsof iptables ufw
}

# 主执行函数
main() {
    install_dependencies
    check_and_open_ports
    install_wireguard
    install_xray
    configure_wireguard

    # 提示是否使用 Let's Encrypt 获取证书
    read -p "是否需要使用 Let's Encrypt 获取证书？(y/n): " USE_LETS_ENCRYPT
    if [[ "$USE_LETS_ENCRYPT" == "y" ]]; then
        get_lets_encrypt_cert
    else
        echo "请手动上传证书到 $CERT_DIR 目录。"
    fi

    configure_xray
    generate_subscribe_link
}

# 运行脚本
main
