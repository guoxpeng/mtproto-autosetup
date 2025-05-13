#!/bin/bash

# 一键部署 Telegram MTProxy（端口 4433，开机自启）

set -e

# 安装依赖
apt update -y
apt install -y git curl build-essential libssl-dev zlib1g-dev xxd net-tools

# 克隆 MTProxy
rm -rf MTProxy
git clone https://github.com/TelegramMessenger/MTProxy.git
cd MTProxy
make

# 安装可执行文件
cp objs/bin/mtproto-proxy /usr/local/bin/

# 配置代理密钥和配置文件
mkdir -p /etc/mtproxy
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
echo "$SECRET" > /etc/mtproxy/proxy-secret
echo "239.255.255.240:443" > /etc/mtproxy/proxy-multi.conf

# 创建 systemd 服务
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

# 启动并设置开机自启
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable mtproxy
systemctl start mtproxy

# 获取公网 IP
IP=$(curl -s https://api.ipify.org)

# 显示结果
cat <<EOM

✅ Telegram MTProxy 部署完成
🔹公网 IP: $IP
🔹端口: 4433
🔹Secret: $SECRET

🔗 连接链接：
tg://proxy?server=$IP&port=4433&secret=ee$SECRET
EOM
