#!/bin/bash

# Telegram MTProxy 终极修复安装脚本
# 修复所有编译错误，提供完整可用的代理服务

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
        libssl-dev zlib1g-dev xxd
fi

# 清理旧安装
echo -e "${YELLOW}[2/6] 准备安装环境...${NC}"
rm -rf /tmp/MTProxy
mkdir -p /tmp/MTProxy

# 下载源码（使用修复版分支）
echo -e "${YELLOW}[3/6] 下载修复版MTProxy源码...${NC}"
cd /tmp/MTProxy
git clone --depth 1 --branch gcc10-fix https://github.com/krepver/MTProxy.git
cd MTProxy

# 应用额外补丁
echo -e "${YELLOW}[4/6] 应用编译修复补丁...${NC}"
cat << 'EOF' > fixes.patch
diff --git a/Makefile b/Makefile
index 7a3b3a3..d947e4e 100644
--- a/Makefile
+++ b/Makefile
@@ -1,5 +1,5 @@
 # You may want to change these variables
-CFLAGS = -O3 -std=gnu11 -Wall -mpclmul -march=core2 -mfpmath=sse -mssse3 -fno-strict-aliasing -fno-strict-overflow -fwrapv -DAES=1 -DCOMMIT=\"$(shell git rev-parse HEAD 2>/dev/null || echo 'unknown')\" -D_GNU_SOURCE=1 -D_FILE_OFFSET_BITS=64 -fpic
+CFLAGS = -O3 -std=gnu11 -Wall -mpclmul -march=core2 -mfpmath=sse -mssse3 -fno-strict-aliasing -fno-strict-overflow -fwrapv -fcommon -DAES=1 -DCOMMIT=\"$(shell git rev-parse HEAD 2>/dev/null || echo 'unknown')\" -D_GNU_SOURCE=1 -D_FILE_OFFSET_BITS=64 -fpic
 LDFLAGS = -ggdb -rdynamic
 LDLIBS = -lm -lrt -lcrypto -lz -lpthread -lcrypto
 
EOF

git apply fixes.patch

# 编译安装
echo -e "${YELLOW}[5/6] 编译安装MTProxy...${NC}"
make -j$(nproc)
cp objs/bin/mtproto-proxy /usr/local/bin/

# 配置代理
mkdir -p /etc/mtproxy
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
echo "$SECRET" > /etc/mtproxy/proxy-secret
echo "239.255.255.240:443" > /etc/mtproxy/proxy-multi.conf

# 系统服务配置
cat <<EOF > /etc/systemd/system/mtproxy.service
[Unit]
Description=Telegram MTProxy
After=network.target

[Service]
Type=simple
User=nobody
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

# 获取公网IP
IP=$(curl -s --connect-timeout 5 https://api.ipify.org || echo "你的服务器IP")

# 输出结果
echo -e "${GREEN}[6/6] MTProxy 安装成功！${NC}"
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