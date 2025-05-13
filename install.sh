#!/bin/bash

# Telegram MTProxy 终极修复脚本
# 解决代理不可用问题 | 支持SOCKS5 | 自动诊断

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

# 函数：诊断网络问题
diagnose_network() {
    echo -e "\n${YELLOW}[诊断开始]${NC}"
    
    # 检查服务运行状态
    if ! systemctl is-active --quiet mtproxy; then
        echo -e "${RED}✗ 服务未运行${NC}"
        systemctl restart mtproxy
        sleep 2
    fi
    
    # 检查端口监听
    echo -e "${YELLOW}▶ 检查端口监听：${NC}"
    ss -tulnp | grep -E '4433|4434' || {
        echo -e "${RED}✗ 端口未监听${NC}"
        return 1
    }
    
    # 检查防火墙
    echo -e "${YELLOW}▶ 检查防火墙：${NC}"
    ufw status | grep -E '4433|4434' || iptables -L -n | grep -E '4433|4434' || {
        echo -e "${YELLOW}⚠ 未检测到防火墙规则，继续检查...${NC}"
    }
    
    # 测试本地连接
    echo -e "${YELLOW}▶ 测试本地SOCKS5连接：${NC}"
    curl --socks5 proxyuser:proxypass@127.0.0.1:4434 ifconfig.me && {
        echo -e "${GREEN}✓ 本地连接成功${NC}"
    } || {
        echo -e "${RED}✗ 本地连接失败${NC}"
        return 1
    }
    
    # 测试外部连接
    EXT_IP=$(curl -s https://api.ipify.org)
    echo -e "${YELLOW}▶ 测试外部连接 ($EXT_IP:4434)：${NC}"
    timeout 5 curl --socks5 proxyuser:proxypass@$EXT_IP:4434 ifconfig.me && {
        echo -e "${GREEN}✓ 外部连接成功${NC}"
        return 0
    } || {
        echo -e "${RED}✗ 外部连接失败${NC}"
        echo -e "${YELLOW}可能原因："
        echo -e "1. 云服务商安全组限制"
        echo -e "2. ISP封锁"
        echo -e "3. 服务器网络配置问题${NC}"
        return 1
    }
}

# 主安装流程
echo -e "${YELLOW}[1/6] 安装依赖...${NC}"
apt-get update -y
apt-get install -y git curl build-essential libssl-dev zlib1g-dev xxd ufw

echo -e "${YELLOW}[2/6] 下载源码...${NC}"
rm -rf /tmp/MTProxy
git clone --depth 1 https://github.com/TelegramMessenger/MTProxy.git /tmp/MTProxy
cd /tmp/MTProxy

echo -e "${YELLOW}[3/6] 编译安装...${NC}"
sed -i 's/CFLAGS = /CFLAGS = -fcommon /' Makefile
make -j$(nproc) || make
cp objs/bin/mtproto-proxy /usr/local/bin/

echo -e "${YELLOW}[4/6] 生成配置...${NC}"
mkdir -p /etc/mtproxy
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
echo "$SECRET" > /etc/mtproxy/proxy-secret
echo "239.255.255.240:443" > /etc/mtproxy/proxy-multi.conf

echo -e "${YELLOW}[5/6] 配置服务...${NC}"
cat <<EOF > /etc/systemd/system/mtproxy.service
[Unit]
Description=MTProxy (SOCKS5兼容版)
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
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now mtproxy

echo -e "${YELLOW}[6/6] 开放端口...${NC}"
ufw allow 4433/tcp
ufw allow 4434/tcp
ufw --force enable
ufw reload

# 诊断网络
if diagnose_network; then
    IP=$(curl -s https://api.ipify.org || hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}✅ 代理运行正常${NC}"
    echo -e "===================================="
    echo -e "${GREEN}MTProto 配置：${NC}"
    echo -e "服务器: $IP"
    echo -e "端口: 4433"
    echo -e "Secret: $SECRET"
    echo -e "链接: tg://proxy?server=$IP&port=4433&secret=ee$SECRET"
    echo -e "\n${GREEN}SOCKS5 配置：${NC}"
    echo -e "服务器: $IP"
    echo -e "端口: 4434"
    echo -e "用户名: proxyuser"
    echo -e "密码: proxypass"
    echo -e "===================================="
else
    echo -e "\n${RED}❌ 代理配置失败，请检查以下内容：${NC}"
    echo -e "1. 云服务器安全组规则（开放4433/4434端口）"
    echo -e "2. 运行命令手动测试：curl --socks5 proxyuser:proxypass@127.0.0.1:4434 ifconfig.me"
    echo -e "3. 查看日志：journalctl -u mtproxy -f"
fi