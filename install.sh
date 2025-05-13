#!/bin/bash

# 优化版 Telegram MTProxy 一键部署脚本（端口 4433，开机自启）

set -e

# 检查是否已安装必要组件
if ! command -v git &> /dev/null || ! command -v make &> /dev/null; then
    echo "安装必要依赖..."
    apt update -y
    apt install -y git curl build-essential libssl-dev zlib1g-dev
fi

# 获取 MTProxy（如果目录不存在）
if [ ! -d "MTProxy" ]; then
    git clone --depth 1 https://github.com/TelegramMessenger/MTProxy.git
fi

# 编译 MTProxy
cd MTProxy
make -j$(nproc)

# 安装可执行文件
mkdir -p /usr/local/bin
cp objs/bin/mtproto-proxy /usr/local/bin/

# 配置代理
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
Type=simple
ExecStart=/usr/local/bin/mtproto-proxy -u nobody -p 8888 -H 4433 -S $SECRET --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M 1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# 启动服务
systemctl daemon-reload
systemctl enable --now mtproxy

# 显示结果
IP=$(curl -s https://api.ipify.org)
cat <<EOM

✅ Telegram MTProxy 部署完成
🔹 公网 IP: $IP
🔹 端口: 4433
🔹 Secret: $SECRET

🔗 连接链接：
tg://proxy?server=$IP&port=4433&secret=ee$SECRET
EOM