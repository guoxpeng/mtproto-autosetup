#!/bin/bash

# Telegram MTProxy 一键安装脚本 (终极修复版)
# 修复所有编译错误，完全兼容官方仓库

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
echo -e "${YELLOW}[1/5] 正在安装系统依赖...${NC}"
apt-get update -y
apt-get install -y git curl build-essential libssl-dev zlib1g-dev xxd

# 下载源码
echo -e "${YELLOW}[2/5] 下载MTProxy源码...${NC}"
rm -rf /tmp/MTProxy
git clone --depth 1 https://github.com/TelegramMessenger/MTProxy.git /tmp/MTProxy
cd /tmp/MTProxy

# 修复编译错误
echo -e "${YELLOW}[3/5] 应用编译修复...${NC}"
sed -i 's/CFLAGS = /CFLAGS = -fcommon /' Makefile

# 编译安装
echo -e "${YELLOW}[4/5] 编译安装...${NC}"
make -j$(nproc) || {
    echo -e "${YELLOW}并行编译失败，尝试单线程编译...${NC}"
    make
}
cp objs/bin/mtproto-proxy /usr/local/bin/

# 配置服务
echo -e "${YELLOW}[5/5] 配置代理服务...${NC}"
mkdir -p /etc/mtproxy
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
echo "$SECRET" > /etc/mtproxy/proxy-secret
echo "239.255.255.240:443" > /etc/mtproxy/proxy-multi.conf

cat <<EOF > /etc/systemd/system/mtproxy.service
[Unit]
Description=Telegram MTProxy
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
    -M 1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mtproxy

# 显示结果
IP=$(curl -s https://api.ipify.org || echo "你的服务器IP")
echo -e "${GREEN}\n✅ 安装成功！${NC}"
echo -e "IP: ${YELLOW}$IP${NC}"
echo -e "端口: ${YELLOW}4433${NC}"
echo -e "Secret: ${YELLOW}$SECRET${NC}"
echo -e "${GREEN}\n客户端链接：${NC}"
echo -e "tg://proxy?server=$IP&port=4433&secret=ee$SECRET"
echo -e "https://t.me/proxy?server=$IP&port=4433&secret=ee$SECRET"