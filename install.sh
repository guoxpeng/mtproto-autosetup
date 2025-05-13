#!/bin/bash

# 一键部署 Telegram MTProxy（端口 4433，支持开机自启）

set -e

# 安装依赖
apt update -y
apt install -y git curl build-essential libssl-dev zlib1g-dev xxd

# 克隆 MTProxy 源码
git clone https://github.com/TelegramMessenger/MTProxy.git
cd MTProxy
make

# 安装可执行文件
cp objs/bin/mtproto-proxy /usr/local/bin/

# 准备配置
mkdir -p /etc/mtproxy
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
echo "$SECRET" > /etc/mtproxy/proxy-secret
echo "239.255.255.240:443" > /etc/mtproxy/proxy-multi.conf

# 创建 systemd 服务文件
cat <<EOF > /etc/systemd/system/mtproxy.service
[Unit]
Description=Telegram MTProxy
After=network.target

[Service]
ExecStart=/usr/local/bin/mtproto-proxy -u nobody -p 8888 -H 4433 -S $SECRET --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M 1
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 启用并启动服务
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable mtproxy
systemctl start mtproxy

# 获取公网 IP
IP=$(curl -s https://api.ipify.org)

# 输出代理信息
echo ""
echo "✅ Telegram MTProxy 部署完成并已后台运行"
echo "🔹公网 IP: $IP"
echo "🔹端口: 4433"
echo "🔹Secret: $SECRET"
echo ""
echo "🔗 连接链接："
echo "tg://proxy?server=$IP&port=4433&secret=ee$SECRET"
