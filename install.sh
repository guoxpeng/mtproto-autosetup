#!/bin/bash

# Telegram MTProxy 一键安装脚本 (优化修复版)
# 功能：自动部署 MTProxy 到 4433 端口，支持开机自启
# 修复了编译错误，减少不必要的下载，输出友好信息

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

# 安装必要依赖
echo -e "${YELLOW}[1/6] 正在安装系统依赖...${NC}"
if ! command -v git &> /dev/null || ! command -v make &> /dev/null; then
    apt-get update -y
    apt-get install -y --no-install-recommends \
        git curl build-essential \
        libssl-dev zlib1g-dev
fi

# 下载源码（浅克隆）
echo -e "${YELLOW}[2/6] 下载MTProxy源码...${NC}"
if [ ! -d "MTProxy" ]; then
    git clone --depth 1 https://github.com/TelegramMessenger/MTProxy.git
else
    echo -e "${GREEN}检测到已存在源码目录，跳过下载${NC}"
fi

# 编译安装
echo -e "${YELLOW}[3/6] 编译安装MTProxy...${NC}"
cd MTProxy

# 修复编译错误
sed -i 's/CFLAGS = /CFLAGS = -fcommon /' Makefile

# 并行编译加速
make -j$(nproc) || {
    echo -e "${RED}编译失败！尝试单线程编译...${NC}"
    make
}

# 安装文件
cp objs/bin/mtproto-proxy /usr/local/bin/

# 配置代理
echo -e "${YELLOW}[4/6] 生成代理配置...${NC}"
mkdir -p /etc/mtproxy
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
echo "$SECRET" > /etc/mtproxy/proxy-secret
echo "239.255.255.240:443" > /etc/mtproxy/proxy-multi.conf

# 系统服务配置
echo -e "${YELLOW}[5/6] 配置系统服务...${NC}"
cat <<EOF > /etc/systemd/system/mtproxy.service
[Unit]
Description=Telegram MTProxy
After=network.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/mtproto-proxy \
    -u nobody \
    -p 8888 \
    -H 4433 \
    -S $SECRET \
    --aes-pwd /etc/mtproxy/proxy-secret \
    /etc/mtproxy/proxy-multi.conf \
    -M 1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
systemctl daemon-reload
systemctl enable --now mtproxy

# 获取公网IP
IP=$(curl -s --connect-timeout 5 https://api.ipify.org || echo "你的服务器IP")

# 输出结果
echo -e "${GREEN}[6/6] MTProxy 安装完成！${NC}"
echo -e "===================================="
echo -e "${GREEN}代理配置信息：${NC}"
echo -e "IP地址: ${YELLOW}$IP${NC}"
echo -e "端口: ${YELLOW}4433${NC}"
echo -e "Secret: ${YELLOW}$SECRET${NC}"
echo -e "===================================="
echo -e "${GREEN}Telegram 客户端链接：${NC}"
echo -e "tg://proxy?server=$IP&port=4433&secret=ee$SECRET"
echo -e "${GREEN}或使用以下分享链接：${NC}"
echo -e "https://t.me/proxy?server=$IP&port=4433&secret=ee$SECRET"
echo -e "===================================="
echo -e "${YELLOW}如需卸载，请执行：${NC}"
echo -e "systemctl stop mtproxy && systemctl disable mtproxy"
echo -e "rm -rf /etc/mtproxy /etc/systemd/system/mtproxy.service /usr/local/bin/mtproto-proxy"