#!/bin/bash

# 一键部署 Telegram MTProxy（无 TLS，使用 4433 端口）

# 更新系统并安装依赖
apt update -y
apt install -y git curl build-essential libssl-dev zlib1g-dev

# 克隆 MTProxy 源码并编译
git clone https://github.com/TelegramMessenger/MTProxy.git
cd MTProxy
make

# 将可执行文件移动到系统路径
cp objs/bin/mtproto-proxy /usr/local/bin/

# 生成随机 secret
SECRET=$(head -c 16 /dev/urandom | xxd -ps)

# 创建配置文件
mkdir -p /etc/mtproxy
echo $SECRET > /etc/mtproxy/proxy-secret
echo "239.255.255.240:443" > /etc/mtproxy/proxy-multi.conf

# 启动 MTProxy（监听 4433 端口）
nohup mtproto-proxy -u nobody -p 8888 -H 4433 -S $SECRET --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf -M 1 > /var/log/mtproxy.log 2>&1 &

# 获取公网 IP
IP=$(curl -s https://api.ipify.org)

# 输出代理链接
echo
echo "✅ Telegram MTProxy 已启动！"
echo "连接信息如下："
echo "tg://proxy?server=$IP&port=4433&secret=ee${SECRET}"
