#!/bin/bash

# Telegram MTProxy 终极修复版 (支持SOCKS5协议)
# 修复代理不可用问题，兼容最新版Telegram

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# 检查root权限
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}错误：此脚本必须使用root权限运行！${NC}" >&2
    exit 1
fi

# 安装依赖
echo -e "${YELLOW}[1/6] 正在安装系统依赖...${NC}"
apt-get update -y
apt-get install -y git curl build-essential libssl-dev zlib1g-dev xxd

# 下载源码
echo -e "${YELLOW}[2/6] 下载MTProxy源码...${NC}"
rm -rf /tmp/MTProxy
git clone --depth 1 https://github.com/TelegramMessenger/MTProxy.git /tmp/MTProxy
cd /tmp/MTProxy

# 修复编译错误
echo -e "${YELLOW}[3/6] 应用编译修复...${NC}"
sed -i 's/CFLAGS = /CFLAGS = -fcommon /' Makefile

# 编译安装
echo -e "${YELLOW}[4/6] 编译安装...${NC}"
make -j$(nproc) || {
    echo -e "${YELLOW}并行编译失败，尝试单线程编译...${NC}"
    make
}
cp objs/bin/mtproto-proxy /usr/local/bin/

# 配置服务
echo -e "${YELLOW}[5/6] 配置代理服务...${NC}"
mkdir -p /etc/mtproxy
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
echo "$SECRET" > /etc/mtproxy/proxy-secret
echo "239.255.255.240:443" > /etc/mtproxy/proxy-multi.conf

# 关键修改：添加SOCKS5支持参数
cat <<EOF > /etc/systemd/system/mtproxy.service
[Unit]
Description=Telegram MTProxy (SOCKS5兼容版)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mtproto-proxy \\
    -u nobody \\
    -p 8888 \\
    -H 4433 \\
    -S $SECRET \\
    --aes-pwd /etc/mtproxy/proxy-secret \\
    /etc/mtproxy/proxy-multi.conf \\
    -M 1 \\
    --socks5 \\
    --socks5-port 4434 \\
    --socks5-user proxyuser \\
    --socks5-pass proxypass
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mtproxy

# 配置防火墙
echo -e "${YELLOW}[6/6] 配置防火墙...${NC}"
ufw allow 4433/tcp
ufw allow 4434/tcp
ufw reload

# 显示结果
IP=$(curl -s https://api.ipify.org || echo "你的服务器IP")
echo -e "${GREEN}\n✅ 安装成功！${NC}"
echo -e "🔹 ${YELLOW}MTProto 配置：${NC}"
echo -e "IP: $IP"
echo -e "端口: 4433"
echo -e "Secret: $SECRET"
echo -e "链接: tg://proxy?server=$IP&port=4433&secret=ee$SECRET"

echo -e "\n🔹 ${YELLOW}SOCKS5 配置：${NC}"
echo -e "IP: $IP"
echo -e "端口: 4434"
echo -e "用户名: proxyuser"
echo -e "密码: proxypass"
echo -e "Telegram设置路径: 设置 > 高级 > 代理 > 添加SOCKS5代理"