#!/bin/bash

# 一键部署 Telegram MTProxy（终极修复版）
# 修复 GCC 10+ 编译错误，保持原有仓库结构

set -e

# 安装依赖
apt update -y
apt install -y git curl build-essential libssl-dev zlib1g-dev xxd net-tools

# 清理并重新克隆源码
rm -rf MTProxy
git clone https://github.com/TelegramMessenger/MTProxy.git
cd MTProxy

# 关键修复步骤：修改 Makefile 添加 -fcommon
sed -i 's/CFLAGS = /CFLAGS = -fcommon /' Makefile

# 编译安装（自动降级重试）
make -j$(nproc) || {
    echo "并行编译失败，尝试单线程编译..."
    make
}

# 安装文件
cp objs/bin/mtproto-proxy /usr/local/bin/

# 生成密钥和配置
mkdir -p /etc/mtproxy
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
echo "$SECRET" > /etc/mtproxy/proxy-secret
echo "239.255.255.240:443" > /etc/mtproxy/proxy-multi.conf

# 创建系统服务
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

# 启动服务
systemctl daemon-reload
systemctl enable --now mtproxy

# 输出结果
IP=$(curl -s https://api.ipify.org || echo "你的服务器IP")
cat <<EOM

✅ Telegram MTProxy 部署完成
🔹 公网 IP: $IP
🔹 端口: 4433
🔹 Secret: $SECRET

🔗 客户端链接：
tg://proxy?server=$IP&port=4433&secret=ee$SECRET
https://t.me/proxy?server=$IP&port=4433&secret=ee$SECRET
EOM