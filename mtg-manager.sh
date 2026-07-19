#!/bin/bash
#===============================================================================
# MTG MTProto Proxy Manager  (v4) - 一键安装/管理脚本
# 项目地址: https://github.com/guoxpeng/mtproto-autosetup
# 基于官方 9seconds/mtg: https://github.com/9seconds/mtg
#
# 安装命令（直接复制到服务器终端）:
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/guoxpeng/mtproto-autosetup/main/mtg-manager.sh)" -- install
#   （默认自动选空闲端口，也可加 --port 8443 指定）
#
# 功能清单:
#   1. 密钥历史管理 - list-keys / show-key <n>
#   2. 连接监控统计 - stats 命令查看活跃连接
#   3. JSON 输出模式 - show --json / key --json / stats --json
#   4. 增强错误处理 - 严格校验 + 明确的失败提示
#   5. 防火墙增强 - 支持 iptables
#   6. 健康检查增强 - 时间同步 / DNS / Telegram 连通性
#   7. 自动备份 - 更新/轮换密钥前强制备份
#   8. 非交互式保护 - 避免 read 在管道模式下挂起
#===============================================================================
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ========== 路径配置 ==========
CONFIG_DIR="/etc/mtg"
CONFIG_FILE="$CONFIG_DIR/config.toml"
SECRET_FILE="$CONFIG_DIR/secret"
KEYS_DIR="$CONFIG_DIR/keys"
BACKUP_DIR="$CONFIG_DIR/backups"
BIN="/usr/local/bin/mtg"
MANAGER_BIN="/usr/local/bin/mtg-manager"
SERVICE_FILE="/etc/systemd/system/mtg.service"
LOG_FILE="/var/log/mtg-manager.log"
LOCK_FILE="/tmp/mtg-manager.lock"

# ========== 日志函数 ==========
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; echo "$(date '+%F %T') [INFO] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $*";   echo "$(date '+%F %T') [OK] $*"   >> "$LOG_FILE" 2>/dev/null || true; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; echo "$(date '+%F %T') [WARN] $*" >> "$LOG_FILE" 2>/dev/null || true; }
log_err()  { echo -e "${RED}[ERR]${NC} $*" >&2; echo "$(date '+%F %T') [ERR] $*" >> "$LOG_FILE" 2>/dev/null || true; }
die()      { log_err "$@"; exit 1; }

# ========== 临时目录 ==========
TMP_DIR="$(mktemp -d 2>/dev/null || echo "/tmp/mtg-manager.$$")"
mkdir -p "$TMP_DIR" || die "无法创建临时目录: $TMP_DIR"
[ -w "$TMP_DIR" ] || die "临时目录不可写: $TMP_DIR"

cleanup() { rm -f "$LOCK_FILE"; rm -rf "$TMP_DIR"; exec 200>&- 2>/dev/null || true; }
trap cleanup EXIT INT TERM
require_root()  { [ "$(id -u)" = "0" ] || die "此操作需要 root 权限，请用 sudo 运行"; }
require_interactive() { [ -t 0 ] || die "该命令需要交互终端，请在 SSH 中直接运行"; }

# 脚本锁 — 确保同一时间只有一个实例在运行
acquire_lock() {
    # 先清除旧实例（读取锁文件中的 PID，如果还在运行就杀掉）
    if [ -f "$LOCK_FILE" ]; then
        local old_pid
        old_pid=$(head -1 "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$old_pid" ] && [ "$old_pid" != "$$" ]; then
            kill "$old_pid" 2>/dev/null && sleep 1
            kill -0 "$old_pid" 2>/dev/null && kill -9 "$old_pid" 2>/dev/null
        fi
        rm -f "$LOCK_FILE"
    fi
    # 获取新锁（同时写入当前 PID，方便下次清理）
    exec 200>"$LOCK_FILE" || die "无法创建锁文件: $LOCK_FILE"
    flock -n 200 || die "无法获得锁"
    echo "$$" >&200
}

curl_retry() {
    # -f = fail on HTTP error, -sS = silent but show errors, -L = follow redirects
    curl -fsSL --connect-timeout 5 --max-time 20 --retry 2 --retry-delay 2 "$@"
}

# ========== 读取安全输入（替代 read，防止非交互模式下挂起） ==========
safe_read() {
    local var="$1" prompt="$2" default="$3"
    local input
    if [ -t 0 ]; then
        read -r -p "$prompt" input
        printf -v "$var" "%s" "${input:-$default}"
    else
        printf -v "$var" "%s" "$default"
        log_info "$(echo "$prompt" | tr -d '\n') -> 使用默认值: $default"
    fi
}

# ========== 系统检测 ==========
detect_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        armv7l)  echo "armv7" ;;
        i386|i686) echo "386" ;;
        *) die "不支持的 CPU 架构: $(uname -m)" ;;
    esac
}

detect_pkg_manager() {
    command -v apt-get >/dev/null 2>&1 && { echo "apt-get"; return; }
    command -v dnf >/dev/null 2>&1     && { echo "dnf"; return; }
    command -v yum >/dev/null 2>&1     && { echo "yum"; return; }
    die "不支持的系统: 未找到 apt-get/dnf/yum 包管理器"
}

# ========== 校验函数 ==========
validate_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] || { die "端口必须是数字: $p"; return 1; }
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { die "端口超出范围 (1-65535): $p"; return 1; }
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qF ":$p" && { die "端口 $p 已被占用，请更换端口或先停止占用服务"; return 1; }
    fi
    return 0
}

# 找一个空闲端口（默认随机 20000-60000，也可指定）
pick_port() {
    local preferred="${1:-}"
    [ -n "$preferred" ] && { echo "$preferred"; return; }
    while true; do
        local p
        p=$(od -An -N2 -tu2 /dev/urandom 2>/dev/null | tr -d ' ')
        [ -z "$p" ] && p=$(( (RANDOM % 40001) + 20000 ))
        p=$(( (p % 40001) + 20000 ))
        if command -v ss >/dev/null 2>&1; then
            ss -ltn 2>/dev/null | awk '{print $4}' | grep -qF ":$p" || { echo "$p"; return; }
        else
            echo "$p"; return
        fi
    done
}

validate_domain() {
    local d="$1"
    [ -z "$d" ] && die "伪装域名不能为空"
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 8 "https://${d}" 2>/dev/null)
    if [ "$code" = "000" ] || [ -z "$code" ]; then
        log_warn "域名 $d 通过 HTTPS 无法访问 (连接超时/拒绝)，伪装效果可能不佳"
    else
        log_ok "伪装域名 $d 可正常访问 (HTTP $code)"
    fi
}

validate_json_output() {
    for arg in "$@"; do
        [ "$arg" = "--json" ] && return 0
    done
    return 1
}

is_installed() { [ -x "$BIN" ] && [ -f "$CONFIG_FILE" ]; }

# ========== 自我安装到 PATH ==========
self_install_to_path() {
    local target="$MANAGER_BIN"
    local self="${BASH_SOURCE[0]:-}"
    if [ -n "$self" ] && [ -f "$self" ] && [ -r "$self" ] \
       && [ "$(readlink -f "$self" 2>/dev/null)" != "$target" ]; then
        if cp "$self" "$target" 2>/dev/null && chmod +x "$target" 2>/dev/null; then
            log_ok "已安装为全局命令，以后直接用: mtg-manager show / mtg-manager key"
            return 0
        fi
    fi
    log_warn "未安装全局命令。如需保留请手动: sudo cp '<script>' $target && sudo chmod +x $target"
}

# ========== 依赖安装 ==========
install_deps() {
    log_info "检查系统依赖..."
    local missing=()
    for c in curl tar ss; do
        command -v "$c" >/dev/null 2>&1 || missing+=("$c")
    done
    [ ${#missing[@]} -eq 0 ] && { log_ok "依赖已就绪"; return; }

    local pm; pm=$(detect_pkg_manager)
    case "$pm" in
        apt-get)
            apt-get update -y >/dev/null 2>&1 || true
            apt-get install -y curl tar iproute2 >/dev/null 2>&1 || die "apt-get 安装依赖失败"
            ;;
        yum|dnf)
            $pm install -y curl tar iproute >/dev/null 2>&1 || die "$pm 安装依赖失败"
            ;;
    esac
    log_ok "依赖安装完成"
}

# ========== 版本解析与下载 ==========
resolve_version() {
    local ver="$1"
    if [ "$ver" = "latest" ]; then
        ver=$(curl_retry "https://api.github.com/repos/9seconds/mtg/releases/latest" \
            | grep -m1 '"tag_name"' | sed -E 's/.*"([^"]+)".*/\1/')
        [ -n "$ver" ] || die "无法获取最新版本号，请用 --version 手动指定 (如 --version v2.2.8)"
    fi
    echo "$ver"
}

download_mtg() {
    local version="$1"
    local arch; arch=$(detect_arch)
    local vnum="${version#v}"
    local url="https://github.com/9seconds/mtg/releases/download/${version}/mtg-${vnum}-linux-${arch}.tar.gz"

    log_info "下载 mtg ${version} (${arch})..."
    # 管道：curl → tar。curl 写完数据后 tar 先关闭管道会导致 curl 退出码 23（SIGPIPE），属于良性
    { curl -fsSL --connect-timeout 5 --max-time 60 --retry 3 --retry-delay 2 "$url" || [ $? -eq 23 ]; } \
        | tar xz --strip-components=1 -C "$TMP_DIR" || die "下载/解压失败: $url"
    [ -f "$TMP_DIR/mtg" ] || die "压缩包内未找到 mtg 可执行文件"

    install -m 0755 "$TMP_DIR/mtg" "$BIN" || die "安装二进制文件失败"
    "$BIN" --version >/dev/null 2>&1 || die "下载的二进制无法执行 (架构不匹配或文件损坏)"
    log_ok "mtg 安装完成: $("$BIN" --version 2>&1 | head -1)"
}

# ========== 密钥管理 ==========
gen_secret_local() {
    # 纯本地生成随机密钥，不依赖 mtg binary
    # 输出 64 位 hex，首字节 ee 表示 TLS 伪装
    local hex

    # 方案一: dd + od
    hex=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | od -An -tx1 | tr -d ' \n')
    if [ -n "$hex" ] && [ ${#hex} -ge 64 ]; then
        echo "ee${hex:2}"
        return
    fi

    # 方案二: 纯 bash（无外部依赖）
    local s="ee"
    for i in $(seq 1 31); do
        printf -v b "%02x" $(( (RANDOM << 8 | RANDOM) & 0xFF ))
        s="${s}${b}"
    done
    [ ${#s} -eq 64 ] && echo "$s" && return

    die "无法生成随机密钥（/dev/urandom 和 RANDOM 均不可用）"
}

gen_secret() {
    local domain="$1" secret

    # mtg v2.2.8 仅支持无参 generate-secret；带 -c/tls 会报错
    secret=$("$BIN" generate-secret 2>&1)
    secret=$(echo "$secret" | grep -oE '^[a-f0-9]{64,}' | head -1)

    # mtg 失败 → 纯本地生成（必成功）
    if [ -z "$secret" ]; then
        log_warn "mtg generate-secret 不可用，使用本地随机生成" >&2
        secret=$(gen_secret_local)
    fi

    [ -n "$secret" ] || die "无法生成密钥（mtg 和本地方案均失败）"

    mkdir -p "$CONFIG_DIR" "$KEYS_DIR"

    # 保存当前密钥（保存/恢复 umask，不影响全局）
    local old_umask; old_umask=$(umask)
    umask 077
    echo "$secret" > "$SECRET_FILE"
    umask "$old_umask"
    chmod 600 "$SECRET_FILE"

    # 写入密钥历史（带时间戳和域名元数据）
    local ts; ts=$(date '+%Y%m%d-%H%M%S')
    {
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "# 伪装域名: $domain"
        echo "$secret"
    } > "$KEYS_DIR/secret-$ts"
    chmod 644 "$KEYS_DIR/secret-$ts"

    # 更新最新密钥符号链接
    ln -sf "$KEYS_DIR/secret-$ts" "$CONFIG_DIR/secret.latest" 2>/dev/null || true

    log_ok "已生成加密安全的随机密钥 (每次安装/轮换都不同)" >&2
    echo "$secret"
}

# ========== 配置读写 ==========
write_config() {
    local secret="$1" port="$2"
    cat > "$CONFIG_FILE" <<EOF
# 由 mtg-manager 自动生成 $(date '+%F %T')
secret = "${secret}"
bind-to = "0.0.0.0:${port}"
EOF
    # 644 让 DynamicUser 也能读取（服务以非 root 运行）
    chmod 644 "$CONFIG_FILE"
    log_ok "配置文件已写入: $CONFIG_FILE"
}

backup_config() {
    [ -f "$CONFIG_FILE" ] || return 0
    mkdir -p "$BACKUP_DIR"
    local ts; ts=$(date '+%Y%m%d-%H%M%S')

    if cp "$CONFIG_FILE" "$BACKUP_DIR/config.toml.$ts" 2>/dev/null; then
        log_ok "已备份配置: config.toml.$ts"
    else
        log_warn "配置备份失败 (config.toml)"
    fi

    if [ -f "$SECRET_FILE" ] && cp "$SECRET_FILE" "$BACKUP_DIR/secret.$ts" 2>/dev/null; then
        log_ok "已备份密钥: secret.$ts"
    fi

    # 备份密钥历史目录
    if [ -d "$KEYS_DIR" ] && [ "$(ls -A "$KEYS_DIR" 2>/dev/null)" ]; then
        cp -r "$KEYS_DIR" "$BACKUP_DIR/keys.$ts" 2>/dev/null && log_ok "已备份密钥历史: keys.$ts"
    fi
}

# ========== 密钥历史查询 ==========
list_keys() {
    [ -d "$KEYS_DIR" ] || die "密钥历史目录不存在: $KEYS_DIR"
    local files; files=$(ls -1 "$KEYS_DIR"/secret-* 2>/dev/null | sort) || die "没有密钥历史记录"

    if validate_json_output "$@"; then
        local first=true
        echo "["
        local idx=0
        while IFS= read -r f; do
            [ "$first" = false ] && echo ","
            first=false
            local domain
            domain=$(grep "^# 伪装域名:" "$f" 2>/dev/null | sed 's/^# 伪装域名: //')
            [ -z "$domain" ] && domain="unknown"
            local ts_date
            ts_date=$(basename "$f" | sed 's/^secret-//')
            echo "  {\"index\":$idx,\"date\":\"$ts_date\",\"domain\":\"$domain\",\"file\":\"$(basename "$f")\"}"
            idx=$((idx + 1))
        done <<< "$files"
        echo "]"
    else
        echo -e "${BOLD}${CYAN}================= 密钥历史记录 =================${NC}"
        echo -e "${YELLOW}序号  生成时间           伪装域名${NC}"
        echo "------------------------------------------------"
        local idx=0
        while IFS= read -r f; do
            local domain filename date_str
            filename=$(basename "$f")
            domain=$(grep "^# 伪装域名:" "$f" 2>/dev/null | sed 's/^# 伪装域名: //')
            [ -z "$domain" ] && domain="(未知)"
            date_str=$(echo "$filename" | sed 's/^secret-//; s/\(....\)\(..\)\(..\)-/\1-\2-\3 /')
            echo -e " ${GREEN}$idx${NC}     $date_str    ${BLUE}$domain${NC}"
            idx=$((idx + 1))
        done <<< "$files"
        echo -e "${BOLD}=================================================${NC}"
        echo -e "${YELLOW}使用 'mtg-manager show-key <序号>' 查看详细信息和连接串${NC}"
    fi
}

show_key() {
    local idx="${1:-}"
    [ -n "$idx" ] || die "请指定密钥序号: mtg-manager show-key <序号>"
    [[ "$idx" =~ ^[0-9]+$ ]] || die "序号必须是数字: $idx"
    [ -d "$KEYS_DIR" ] || die "密钥历史目录不存在: $KEYS_DIR"

    local files; files=($(ls -1 "$KEYS_DIR"/secret-* 2>/dev/null | sort))
    [ ${#files[@]} -gt 0 ] || die "没有密钥历史记录"
    [ "$idx" -lt "${#files[@]}" ] || die "序号 $idx 超出范围 (0-$((${#files[@]}-1)))"

    local f="${files[$idx]}"
    local secret domain ip port link
    secret=$(tail -1 "$f")
    domain=$(grep "^# 伪装域名:" "$f" 2>/dev/null | sed 's/^# 伪装域名: //')
    [ -z "$domain" ] && domain="(未知)"
    ip=$(get_public_ip)
    port=$(grep -oE '0\.0\.0\.0:[0-9]+' "$CONFIG_FILE" 2>/dev/null | cut -d: -f2)

    if [ -n "$port" ]; then
        link="tg://proxy?server=${ip}&port=${port}&secret=${secret}"
    else
        link="(无活动配置，端口未知)"
    fi

    echo ""
    echo -e "${BOLD}${CYAN}============ 密钥 #${idx} 详细信息 ============${NC}"
    echo -e "  生成时间 : ${f##*/secret-}"
    echo -e "  伪装域名 : ${BLUE}$domain${NC}"
    echo -e "  服务器   : ${GREEN}${ip}${NC}"
    [ -n "$port" ] && echo -e "  端口     : ${GREEN}${port}${NC}"
    echo -e "  Secret   : ${GREEN}${secret}${NC}"
    [ -n "$port" ] && echo -e "  链接     : ${GREEN}${link}${NC}"
    echo -e "${BOLD}${CYAN}=============================================${NC}"
    echo ""
    echo -e "${YELLOW}完整密钥行 (复制用):${NC}"
    echo "$secret"
}

# ========== 系统服务 ==========
setup_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=mtg - MTProto proxy server
Documentation=https://github.com/9seconds/mtg
After=network.target

[Service]
ExecStart=${BIN} run ${CONFIG_FILE}
Restart=always
RestartSec=3
DynamicUser=true
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=${CONFIG_DIR}

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || die "systemctl daemon-reload 失败"
    systemctl enable mtg >/dev/null 2>&1 || log_warn "systemctl enable mtg 失败"
    log_ok "systemd 服务配置完成"
}

restart_and_verify() {
    systemctl restart mtg || die "systemctl restart mtg 失败"
    sleep 2
    if systemctl is-active --quiet mtg; then
        log_ok "mtg 服务运行正常"
    else
        log_err "服务未能正常启动，最近日志:"
        journalctl -u mtg -n 30 --no-pager
        exit 1
    fi
}

# ========== 防火墙配置 ==========
setup_firewall() {
    local port="$1"
    log_info "配置防火墙放行端口 $port ..."

    # ufw
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
        ufw allow 22/tcp >/dev/null 2>&1 || true
        ufw allow "${port}/tcp" >/dev/null 2>&1 && log_ok "ufw 已放行 $port/tcp" || log_warn "ufw 规则添加失败"
        return
    fi

    # firewalld
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1 && log_ok "firewalld 已放行 $port/tcp" || log_warn "firewalld 重载失败"
        return
    fi

    # iptables (nftables 底层或传统 iptables)
    if command -v iptables >/dev/null 2>&1; then
        if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
            log_ok "iptables 已存在 $port/tcp 放行规则"
        else
            iptables -A INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null && log_ok "iptables 已添加 $port/tcp 放行规则" || log_warn "iptables 规则添加失败 (可能缺少权限)"
        fi
        # 持久化 iptables 规则（自动安装持久化工具）
        if command -v iptables-save >/dev/null 2>&1; then
            local pm; pm=$(detect_pkg_manager)
            case "$pm" in
                apt-get)
                    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
                        log_info "安装 iptables-persistent 以持久化防火墙规则..."
                        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent >/dev/null 2>&1 && \
                            log_ok "iptables-persistent 安装完成" || \
                            log_warn "iptables-persistent 安装失败，重启后规则将失效"
                    fi
                    netfilter-persistent save >/dev/null 2>&1 && log_ok "iptables 规则已持久化 (netfilter-persistent)" || \
                        { iptables-save > /etc/iptables/rules.v4 2>/dev/null && log_ok "iptables 规则已持久化 (iptables-save)"; }
                    ;;
                yum|dnf)
                    if ! rpm -q iptables-services >/dev/null 2>&1; then
                        log_info "安装 iptables-services 以持久化防火墙规则..."
                        $pm install -y iptables-services >/dev/null 2>&1 && \
                            log_ok "iptables-services 安装完成" || \
                            log_warn "iptables-services 安装失败，重启后规则将失效"
                    fi
                    systemctl enable iptables >/dev/null 2>&1 || true
                    iptables-save > /etc/sysconfig/iptables 2>/dev/null && log_ok "iptables 规则已持久化"
                    ;;
            esac
        fi
        return
    fi

    # nftables
    if command -v nft >/dev/null 2>&1; then
        log_warn "检测到 nftables，需要手动添加规则: nft add rule inet filter input tcp dport $port accept"
        return
    fi

    log_warn "未检测到防火墙工具。若使用云服务商，请手动在安全组放行 TCP $port"
}

# ========== 网络信息 ==========
get_public_ip() {
    local ip
    ip=$(curl -s --max-time 4 "https://api.ipify.org" 2>/dev/null)
    [ -n "$ip" ] && { echo "$ip"; return; }
    ip=$(curl -s --max-time 4 "https://ifconfig.me" 2>/dev/null)
    [ -n "$ip" ] && { echo "$ip"; return; }
    ip=$(curl -s --max-time 4 "https://icanhazip.com" 2>/dev/null)
    [ -n "$ip" ] && { echo "$ip"; return; }
    ip=$(curl -s --max-time 4 "https://checkip.amazonaws.com" 2>/dev/null)
    [ -n "$ip" ] && { echo "$ip"; return; }
    # 回退: 尝试获取出口 IP
    ip=$(curl -s --max-time 4 "https://ipinfo.io/ip" 2>/dev/null)
    [ -n "$ip" ] && { echo "$ip"; return; }
    echo "无法获取公网 IP"
}

get_public_ip_with_warn() {
    local ip; ip=$(get_public_ip)
    if [ "$ip" = "无法获取公网 IP" ] || echo "$ip" | grep -qE '^(10\.|172\.(1[6-9]|2[0-9]|3[01])|192\.168\.|127\.)'; then
        log_warn "获取到的 IP ($ip) 可能是内网地址，客户端可能无法直接连接" >&2
    fi
    echo "$ip"
}

# ========== 显示函数 ==========
show_key_only() {
    is_installed || die "尚未安装，请先执行: mtg-manager install"
    if validate_json_output "$@"; then
        local ip port secret
        ip=$(get_public_ip)
        port=$(grep -oE 'bind-to = "0\.0\.0\.0:[0-9]+"' "$CONFIG_FILE" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
        secret=$(cat "$SECRET_FILE" 2>/dev/null)
        echo "{\"ip\":\"$ip\",\"port\":$port,\"secret\":\"$secret\",\"link\":\"tg://proxy?server=${ip}&port=${port}&secret=${secret}\"}"
    else
        [ -f "$SECRET_FILE" ] || die "未找到密钥文件: $SECRET_FILE"
        cat "$SECRET_FILE"
    fi
}

show_config() {
    is_installed || die "尚未安装，请先执行: mtg-manager install"
    local ip secret port link
    ip=$(get_public_ip_with_warn)
    secret=$(cat "$SECRET_FILE" 2>/dev/null || true)
    port=$(grep -oE 'bind-to = "0\.0\.0\.0:[0-9]+"' "$CONFIG_FILE" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || true)

    if [ -z "$secret" ]; then
        log_warn "密钥文件为空: $SECRET_FILE（安装未完成，请重新安装）"
        secret="(空)"
    fi
    if [ -z "$port" ]; then
        log_warn "无法从配置中解析端口: $CONFIG_FILE"
        port="(未知)"
    fi

    link="tg://proxy?server=${ip}&port=${port}&secret=${secret}"

    if validate_json_output "$@"; then
        # 额外获取连接数 (如可用)
        local connections=0
        command -v ss >/dev/null 2>&1 && connections=$(ss -tn state established 2>/dev/null | grep -c ":${port}" || true)
        cat <<EOF
{
  "ip": "$ip",
  "port": $port,
  "secret": "$secret",
  "link": "tg://proxy?server=${ip}&port=${port}&secret=${secret}",
  "tme": "https://t.me/proxy?server=${ip}&port=${port}&secret=${secret}",
  "active_connections": $connections
}
EOF
        return
    fi

    echo ""
    echo -e "${BOLD}${CYAN}=============== MTProto 代理信息 ===============${NC}"
    echo -e "  服务器地址 : ${GREEN}${ip}${NC}"
    echo -e "  端口       : ${GREEN}${port}${NC}"
    echo -e "  Secret     : ${GREEN}${secret}${NC}"
    echo -e "  连接链接   : ${GREEN}${link}${NC}"
    echo -e "  t.me链接   : ${GREEN}https://t.me/proxy?server=${ip}&port=${port}&secret=${secret}${NC}"
    echo -e "${BOLD}====================================================${NC}"

    # 二维码
    if command -v qrencode >/dev/null 2>&1; then
        echo ""
        echo -e "${YELLOW}手机扫码即可导入:${NC}"
        qrencode -t ANSIUTF8 "$link" 2>/dev/null || echo "(二维码生成失败)"
    else
        echo ""
        echo -e "${YELLOW}提示: apt install -y qrencode 可显示二维码${NC}"
    fi
}

# ========== 连接统计 ==========
cmd_stats() {
    is_installed || die "尚未安装"
    local json=false
    validate_json_output "$@" && json=true

    local port
    port=$(grep -oE 'bind-to = "0\.0\.0\.0:[0-9]+"' "$CONFIG_FILE" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    [ -z "$port" ] && die "无法解析端口"

    local connections unique_ips
    connections=$(ss -tn state established 2>/dev/null | grep -c ":${port}" || echo 0)
    unique_ips=$(ss -tn state established 2>/dev/null | grep ":${port}" | awk '{print $5}' | cut -d: -f1 | sort -u | wc -l || echo 0)

    if $json; then
        local secret ip
        ip=$(get_public_ip)
        secret=$(cat "$SECRET_FILE" 2>/dev/null)
        cat <<EOF
{
  "active_connections": $connections,
  "unique_clients": $unique_ips,
  "port": $port,
  "server": "$ip",
  "secret": "$secret"
}
EOF
    else
        echo -e "${BOLD}${CYAN}========== MTG 连接统计 ==========${NC}"
        echo -e "  活跃连接数    : ${GREEN}${connections}${NC}"
        echo -e "  唯一客户端 IP : ${GREEN}${unique_ips}${NC}"
        echo -e "  监听端口      : ${port}"
        echo -e "${BOLD}${CYAN}===================================${NC}"
        echo -e "${YELLOW}提示: 数据来自 ss 快照，非实时计数器${NC}"
    fi
}

# ========== 生命周期命令 ==========
cmd_install() {
    require_root
    local domain="${1:-www.bing.com}" port="${2:-$(pick_port)}" version="${3:-latest}" force="${4:-0}"

    if is_installed && [ "$force" != "1" ]; then
        log_warn "检测到已安装 mtg。如需覆盖重装 (生成新密钥，旧客户端失效):"
        log_warn "  sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/guoxpeng/mtproto-autosetup/main/mtg-manager.sh)\" -- install --force"
        show_config
        exit 0
    fi

    install_deps
    validate_port "$port"
    validate_domain "$domain"
    backup_config
    version=$(resolve_version "$version")
    download_mtg "$version"
    local secret; secret=$(gen_secret "$domain")
    write_config "$secret" "$port"
    setup_service
    setup_firewall "$port"
    restart_and_verify
    self_install_to_path
    echo ""
    show_config
    echo ""
    log_ok "安装完成！如需查看历史密钥: mtg-manager list-keys"
}

cmd_update() {
    require_root
    is_installed || die "尚未安装"
    local version="${1:-latest}"
    version=$(resolve_version "$version")

    log_info "更新 mtg 到 $version (配置和 secret 保持不变)..."
    backup_config
    download_mtg "$version"
    restart_and_verify
    log_ok "更新完成 (版本: $version)"
}

cmd_rotate_secret() {
    require_root
    is_installed || die "尚未安装"
    local domain="${1:-www.bing.com}"

    log_warn "即将轮换 Secret — 所有使用当前密钥的客户端将断开连接"
    if [ -t 0 ]; then
        read -r -p "确认继续? [y/N]: " confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "已取消"; exit 0; }
    else
        log_info "非交互模式，自动继续..."
    fi

    backup_config
    validate_domain "$domain"
    local port; port=$(grep -oE 'bind-to = "0\.0\.0\.0:[0-9]+"' "$CONFIG_FILE" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    [ -z "$port" ] && die "无法从配置文件解析端口: $CONFIG_FILE"
    local secret; secret=$(gen_secret "$domain")
    write_config "$secret" "$port"
    restart_and_verify
    echo ""
    log_ok "Secret 已轮换。旧密钥仍保留在历史中: mtg-manager list-keys"
    show_config
}

cmd_uninstall() {
    require_root
    echo -e "${RED}${BOLD}警告: 即将卸载 mtg 代理服务${NC}"
    echo -e "  配置文件目录: $CONFIG_DIR (将保留)"
    echo -e "  备份目录:     $BACKUP_DIR (将保留)"
    echo -e "  密钥历史:     $KEYS_DIR (将保留)"
    echo ""

    if [ -t 0 ]; then
        read -r -p "确认卸载? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { log_info "已取消"; exit 0; }
    else
        log_info "非交互模式，自动继续..."
    fi

    systemctl stop mtg 2>/dev/null || true
    systemctl disable mtg 2>/dev/null || true
    rm -f "$SERVICE_FILE"
    systemctl daemon-reload
    rm -f "$BIN" "$MANAGER_BIN"
    log_ok "已卸载。配置文件保留在 $CONFIG_DIR，备份在 $BACKUP_DIR"
    echo -e "  如需彻底清除所有数据: sudo rm -rf $CONFIG_DIR"
}

cmd_status() {
    if ! is_installed; then
        die "尚未安装"
    fi
    systemctl status mtg --no-pager 2>/dev/null || {
        log_err "服务状态查询失败"
        return 1
    }
}

cmd_logs() { journalctl -u mtg -f --no-pager; }

cmd_doctor() {
    is_installed || die "尚未安装"

    echo -e "${BOLD}${CYAN}========== MTG 健康诊断 ==========${NC}"

    # 1. 二进制检查
    echo -ne "  1. 二进制文件    : "
    if [ -x "$BIN" ]; then
        local ver; ver=$("$BIN" --version 2>&1 | head -1)
        echo -e "${GREEN}正常${NC} ($ver)"
    else
        echo -e "${RED}缺失${NC} (未找到: $BIN)"
    fi

    # 2. 配置文件
    echo -ne "  2. 配置文件      : "
    if [ -f "$CONFIG_FILE" ]; then
        if grep -q 'secret =' "$CONFIG_FILE" && grep -q 'bind-to =' "$CONFIG_FILE"; then
            echo -e "${GREEN}有效${NC}"
        else
            echo -e "${RED}格式异常${NC} (缺少 secret 或 bind-to)"
        fi
    else
        echo -e "${RED}缺失${NC}"
    fi

    # 3. 密钥文件
    echo -ne "  3. 密钥文件      : "
    if [ -f "$SECRET_FILE" ]; then
        local len; len=$(wc -c < "$SECRET_FILE")
        echo -e "${GREEN}存在${NC} (${len}B)"
    else
        echo -e "${RED}缺失${NC}"
    fi

    # 4. 服务状态
    echo -ne "  4. 服务状态      : "
    if systemctl is-active --quiet mtg 2>/dev/null; then
        echo -e "${GREEN}运行中${NC}"
    else
        echo -e "${RED}未运行${NC}"
    fi

    # 5. 端口监听
    echo -ne "  5. 端口监听      : "
    local port
    port=$(grep -oE 'bind-to = "0\.0\.0\.0:[0-9]+"' "$CONFIG_FILE" 2>/dev/null | grep -oE '[0-9]+' | tail -1)
    if [ -n "$port" ]; then
        if command -v ss >/dev/null 2>&1; then
            ss -ltnp 2>/dev/null | grep -q ":$port" && echo -e "${GREEN}${port}/tcp 监听中${NC}" || echo -e "${RED}${port}/tcp 未监听${NC}"
        else
            echo -e "${YELLOW}无法检测 (ss 不可用)${NC}"
        fi
    else
        echo -e "${RED}无法解析端口${NC}"
    fi

    # 6. 公网 IP
    echo -ne "  6. 公网 IP       : "
    local ip; ip=$(get_public_ip 2>/dev/null)
    if [ -n "$ip" ] && [ "$ip" != "无法获取公网 IP" ]; then
        echo -e "${GREEN}${ip}${NC}"
    else
        echo -e "${RED}无法获取${NC}"
    fi

    # 7. 时间同步
    echo -ne "  7. 时间同步      : "
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl status 2>/dev/null | grep -q "NTP synchronized: yes" && echo -e "${GREEN}已同步${NC}" || echo -e "${YELLOW}未同步 (建议启用 NTP)${NC}"
    else
        echo -e "${YELLOW}未检测${NC}"
    fi

    # 8. 内核转发 (仅当端口不是 443 时检查)
    echo -ne "  8. IP 转发       : "
    local ip_fwd; ip_fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null)
    [ "$ip_fwd" = "1" ] && echo -e "${GREEN}已启用${NC}" || echo -e "${YELLOW}未启用 (非必需)${NC}"

    # 9. DNS 解析
    echo -ne "  9. DNS 解析      : "
    local dns_ok=0
    for dmn in "google.com" "telegram.org" "github.com"; do
        host "$dmn" 2>/dev/null || nslookup "$dmn" 2>/dev/null || dig "$dmn" +short 2>/dev/null && dns_ok=1 && break
    done
    [ "$dns_ok" = "1" ] && echo -e "${GREEN}正常${NC}" || echo -e "${RED}DNS 解析失败 (检查 /etc/resolv.conf)${NC}"

    # 10. Telegram 连通性
    echo -ne " 10. Telegram 连通 : "
    local tg_ok=0
    for dc in "149.154.175.50" "149.154.167.50" "149.154.175.100" "149.154.167.91"; do
        curl -s --connect-timeout 2 --max-time 4 "https://${dc}" >/dev/null 2>&1 && tg_ok=1 && break
    done
    [ "$tg_ok" = "1" ] && echo -e "${GREEN}可达${NC}" || echo -e "${RED}不可达 (Telegram 数据中心被屏蔽?)${NC}"

    echo -e "${BOLD}${CYAN}========================================${NC}"

    # 如果 mtg 有内置 doctor
    if "$BIN" doctor --help >/dev/null 2>&1; then
        echo ""
        echo -e "${YELLOW}--- mtg 官方诊断 ---${NC}"
        "$BIN" doctor "$CONFIG_FILE"
    fi
}

# ========== 交互菜单 ==========
show_menu() {
    while true; do
        echo ""
        echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}${CYAN}║    MTG 代理一键管理工具 v4              ║${NC}"
        echo -e "${BOLD}${CYAN}║    github.com/guoxpeng/mtproto-autosetup ║${NC}"
        echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${GREEN}1${NC}) 安装/重装代理"
        echo -e "  ${GREEN}2${NC}) 查看当前配置与二维码"
        echo -e "  ${GREEN}3${NC}) 查看当前密钥 (仅密钥行)"
        echo -e "  ${GREEN}4${NC}) 密钥历史记录"
        echo -e "  ${GREEN}5${NC}) 连接统计"
        echo -e "  ${GREEN}6${NC}) 服务状态"
        echo -e "  ${GREEN}7${NC}) 实时日志"
        echo -e "  ${GREEN}8${NC}) 健康诊断"
        echo -e "  ${GREEN}9${NC}) 轮换密钥"
        echo -e "  ${GREEN}10${NC}) 更新 mtg 版本"
        echo -e "  ${GREEN}11${NC}) 卸载"
        echo -e "  ${GREEN}0${NC}) 退出"
        echo ""
        read -r -p "选择操作 [0-11]: " choice

        case "$choice" in
            1)
                local d p
                safe_read d "伪装域名 [www.bing.com]: " "www.bing.com"
                safe_read p "监听端口 [随机空闲端口]: " "$(pick_port)"
                cmd_install "$d" "$p" "latest" "1"
                ;;
            2) show_config ;;
            3) show_key_only ;;
            4) list_keys ;;
            5) cmd_stats ;;
            6) cmd_status ;;
            7) cmd_logs ;;
            8) cmd_doctor ;;
            9)
                local d
                safe_read d "伪装域名 [www.bing.com]: " "www.bing.com"
                cmd_rotate_secret "$d"
                ;;
            10) cmd_update ;;
            11) cmd_uninstall ;;
            0) echo -e "${GREEN}再见!${NC}"; exit 0 ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
    done
}

# ========== 入口 ==========
mkdir -p "$(dirname "$LOG_FILE")" "$KEYS_DIR" 2>/dev/null || true
acquire_lock

case "${1:-}" in
    install)
        shift
        domain="www.bing.com"; port="$(pick_port)"; version="latest"; force="0"
        while [ $# -gt 0 ]; do
            case "$1" in
                --domain) domain="$2"; shift 2 ;;
                --port) port="$2"; shift 2 ;;
                --version) version="$2"; shift 2 ;;
                --force) force="1"; shift ;;
                *) die "未知参数: $1" ;;
            esac
        done
        cmd_install "$domain" "$port" "$version" "$force"
        ;;
    update)
        shift
        cmd_update "${1:-latest}"
        ;;
    rotate-secret)
        shift
        domain="${1:-www.bing.com}"
        cmd_rotate_secret "$domain"
        ;;
    uninstall)
        cmd_uninstall
        ;;
    status)
        cmd_status
        ;;
    logs)
        cmd_logs
        ;;
    show)
        shift
        show_config "$@"
        ;;
    key|secret)
        shift
        show_key_only "$@"
        ;;
    list-keys|list)
        shift
        list_keys "$@"
        ;;
    show-key)
        shift
        show_key "${1:-}"
        ;;
    stats)
        shift
        cmd_stats "$@"
        ;;
    doctor|check)
        cmd_doctor
        ;;
    help|-h|--help)
        echo -e "${BOLD}${CYAN}MTG MTProto 代理管理脚本 v4${NC}"
        echo -e "仓库: https://github.com/guoxpeng/mtproto-autosetup"
        echo ""
        echo -e "${YELLOW}用法:${NC} $0 {install|update|rotate-secret|uninstall|status|logs|show|key|list-keys|show-key <n>|stats|doctor|check}"
        echo ""
        echo -e "  ${GREEN}install${NC} [--domain d] [--port p] [--version v] [--force]  安装/重装"
        echo -e "  ${GREEN}update${NC} [版本]                   更新 mtg (配置不变)"
        echo -e "  ${GREEN}rotate-secret${NC} [域名]            轮换密钥"
        echo -e "  ${GREEN}uninstall${NC}                       卸载"
        echo -e "  ${GREEN}status${NC}                          服务状态"
        echo -e "  ${GREEN}logs${NC}                            实时日志"
        echo -e "  ${GREEN}show${NC} [--json]                   查看配置信息"
        echo -e "  ${GREEN}key${NC} [--json]                    查看密钥 (仅行)"
        echo -e "  ${GREEN}list-keys${NC}                       密钥历史列表"
        echo -e "  ${GREEN}show-key${NC} <序号>                 查看历史密钥详情"
        echo -e "  ${GREEN}stats${NC} [--json]                  连接统计"
        echo -e "  ${GREEN}doctor${NC} / ${GREEN}check${NC}             健康诊断"
        exit 0
        ;;
    "")
        require_interactive
        show_menu
        ;;
    *)
        echo -e "${YELLOW}安装命令 (直接复制到服务器):${NC}"
        echo -e "  ${GREEN}sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/guoxpeng/mtproto-autosetup/main/mtg-manager.sh)\" -- install${NC}"
        echo -e "  # 默认随机选一个空闲端口 (20000-60000)，也可以用 --port 指定:"
        echo ""
        echo -e "${YELLOW}用法:${NC} $0 {install|update|rotate-secret|uninstall|status|logs|show|key|list-keys|show-key <n>|stats|doctor|check}"
        echo ""
        echo -e "  ${GREEN}install${NC} [--domain d] [--port p] [--version v] [--force]  安装/重装"
        echo -e "  ${GREEN}update${NC} [版本]                   更新 mtg (配置不变)"
        echo -e "  ${GREEN}rotate-secret${NC} [域名]            轮换密钥"
        echo -e "  ${GREEN}uninstall${NC}                       卸载"
        echo -e "  ${GREEN}status${NC}                          服务状态"
        echo -e "  ${GREEN}logs${NC}                            实时日志"
        echo -e "  ${GREEN}show${NC} [--json]                   查看配置信息"
        echo -e "  ${GREEN}key${NC} [--json]                    查看密钥 (仅行)"
        echo -e "  ${GREEN}list-keys${NC}                       密钥历史列表"
        echo -e "  ${GREEN}show-key${NC} <序号>                 查看历史密钥详情"
        echo -e "  ${GREEN}stats${NC} [--json]                  连接统计"
        echo -e "  ${GREEN}doctor${NC} / ${GREEN}check${NC}             健康诊断"
        echo ""
        echo -e "  ${YELLOW}无参数${NC} = 交互菜单模式"
        exit 1
        ;;
esac
