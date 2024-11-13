#!/bin/bash

# 定义颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PLAIN='\033[0m'

# 检查root权限
[[ $EUID -ne 0 ]] && echo -e "${RED}请使用 root 用户运行此脚本！${PLAIN}" && exit 1

# 系统检测
OS_ARCH=$(uname -m)
case $OS_ARCH in
    x86_64|amd64)
        OS_ARCH="amd64"
        ;;
    arm64|aarch64)
        OS_ARCH="arm64"
        ;;
    *)
        echo -e "${RED}不支持的系统架构: ${OS_ARCH}${PLAIN}"
        exit 1
        ;;
esac

# 安装基础工具
install_base() {
    if [[ -f /etc/debian_version ]]; then
        apt update -y
        apt install -y wget curl tar unzip vim jq qrencode net-tools
    elif [[ -f /etc/redhat-release ]]; then
        yum install -y wget curl tar unzip vim jq qrencode net-tools
    fi
}

# 获取最新版本的sing-box
get_latest_version() {
    echo $(curl -Ls "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
}

# 安装sing-box
install_singbox() {
    VERSION=$(get_latest_version)
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/${VERSION}/sing-box-${VERSION/v/}-linux-${OS_ARCH}.tar.gz"
    
    wget -q ${DOWNLOAD_URL} -O sing-box.tar.gz
    tar -xzf sing-box.tar.gz
    mv sing-box-*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    
    mkdir -p /usr/local/etc/sing-box
    mkdir -p /var/log/sing-box
    
    rm -rf sing-box.tar.gz sing-box-*
}

# 生成配置文件
create_config() {
    local vmess_port=$(shuf -i 10000-65535 -n 1)
    local uuid=$(sing-box generate uuid)
    local domain
    
    echo -e "${YELLOW}请输入您的域名：${PLAIN}"
    read -p "Domain: " domain
    
    cat > /usr/local/etc/sing-box/config.json << EOF
{
    "log": {
        "level": "info",
        "timestamp": true,
        "output": "/var/log/sing-box/sing-box.log"
    },
    "inbounds": [
        {
            "type": "vmess",
            "tag": "vmess-in",
            "listen": "::",
            "listen_port": ${vmess_port},
            "users": [
                {
                    "uuid": "${uuid}",
                    "alterId": 0
                }
            ],
            "transport": {
                "type": "ws",
                "path": "/vmess",
                "max_early_data": 2048,
                "early_data_header_name": "Sec-WebSocket-Protocol"
            },
            "tls": {
                "enabled": true,
                "server_name": "${domain}",
                "certificate_path": "/usr/local/etc/sing-box/cert.pem",
                "key_path": "/usr/local/etc/sing-box/key.pem",
                "xtls": {
                    "enabled": true,
                    "vision": true
                }
            },
            "multiplex": {
                "enabled": true,
                "padding": true,
                "brutal": {
                    "enabled": true,
                    "up_mbps": 100,
                    "down_mbps": 100
                }
            }
        }
    ],
    "outbounds": [
        {
            "type": "direct",
            "tag": "direct"
        },
        {
            "type": "block",
            "tag": "block"
        }
    ]
}
EOF
    
    echo -e "${GREEN}配置文件已生成${PLAIN}"
}

# 申请证书
install_cert() {
    local domain=$1
    
    # 安装 acme.sh
    curl https://get.acme.sh | sh
    
    # 关闭可能占用80端口的服务
    systemctl stop nginx || true
    systemctl stop apache2 || true
    
    # 申请证书
    ~/.acme.sh/acme.sh --issue -d ${domain} --standalone -k ec-256
    
    # 安装证书到 sing-box 目录
    ~/.acme.sh/acme.sh --install-cert -d ${domain} \
        --key-file /usr/local/etc/sing-box/key.pem \
        --fullchain-file /usr/local/etc/sing-box/cert.pem \
        --ecc
        
    # 设置权限
    chmod 644 /usr/local/etc/sing-box/cert.pem
    chmod 644 /usr/local/etc/sing-box/key.pem
    
    echo -e "${GREEN}证书安装完成${PLAIN}"
}

# 创建systemd服务
create_service() {
    cat > /etc/systemd/system/sing-box.service << EOF
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
WorkingDirectory=/usr/local/etc/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /usr/local/etc/sing-box/config.json
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=10
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl start sing-box
    
    echo -e "${GREEN}sing-box 服务已创建并启动${PLAIN}"
}

# 显示配置信息
show_config() {
    local domain=$1
    local vmess_port=$(jq -r '.inbounds[0].listen_port' /usr/local/etc/sing-box/config.json)
    local uuid=$(jq -r '.inbounds[0].users[0].uuid' /usr/local/etc/sing-box/config.json)
    
    echo -e "\n${GREEN}=== sing-box 配置信息 ===${PLAIN}"
    echo -e "${YELLOW}域名：${PLAIN}${domain}"
    echo -e "${YELLOW}端口：${PLAIN}${vmess_port}"
    echo -e "${YELLOW}UUID：${PLAIN}${uuid}"
    echo -e "${YELLOW}传输协议：${PLAIN}WebSocket"
    echo -e "${YELLOW}WebSocket路径：${PLAIN}/vmess"
    echo -e "${YELLOW}XTLS：${PLAIN}开启 (Vision)"
    echo -e "${YELLOW}多路复用：${PLAIN}开启"
    
    # 生成 VMess 链接
    local config="{\"v\":\"2\",\"ps\":\"sing-box-vmess-xtls\",\"add\":\"${domain}\",\"port\":${vmess_port},\"id\":\"${uuid}\",\"aid\":0,\"net\":\"ws\",\"path\":\"/vmess\",\"type\":\"none\",\"host\":\"${domain}\",\"tls\":\"xtls\",\"flow\":\"xtls-rprx-vision\"}"
    local vmess_link="vmess://$(echo -n ${config} | base64 -w 0)"
    
    echo -e "\n${YELLOW}VMess 链接：${PLAIN}\n${vmess_link}\n"
    
    # 生成二维码
    echo -e "${YELLOW}VMess 二维码：${PLAIN}"
    echo -n "${vmess_link}" | qrencode -t UTF8
    
    # 显示服务状态
    echo -e "\n${YELLOW}sing-box 运行状态：${PLAIN}"
    systemctl status sing-box --no-pager
    
    echo -e "\n${YELLOW}管理命令：${PLAIN}"
    echo -e "启动：systemctl start sing-box"
    echo -e "停止：systemctl stop sing-box"
    echo -e "重启：systemctl restart sing-box"
    echo -e "状态：systemctl status sing-box"
    echo -e "查看日志：journalctl -u sing-box -f"
}

# 清理安装
clean_install() {
    systemctl stop sing-box >/dev/null 2>&1
    systemctl disable sing-box >/dev/null 2>&1
    rm -rf /usr/local/bin/sing-box
    rm -rf /usr/local/etc/sing-box
    rm -rf /etc/systemd/system/sing-box.service
    systemctl daemon-reload
}

# 主函数
main() {
    echo -e "${BLUE}开始安装 sing-box...${PLAIN}"
    
    # 清理旧安装
    clean_install
    
    # 安装基础工具
    install_base
    
    # 安装sing-box
    install_singbox
    
    # 创建配置
    create_config
    
    # 获取域名
    local domain=$(jq -r '.inbounds[0].tls.server_name' /usr/local/etc/sing-box/config.json)
    
    # 安装证书
    install_cert ${domain}
    
    # 创建服务
    create_service
    
    # 显示配置信息
    show_config ${domain}
}

# 运行主函数
main

exit 0
