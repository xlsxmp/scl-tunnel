#!/bin/sh
# =====================================================
# scl-tunnel 部署脚本 (Alpine Linux / 低内存优化版)
# 二进制来源: 用户自行编译并上传的 GitHub Release
#   https://github.com/xlsxmp/sing-box/releases/download/<version>/scl-tunnel-<version>-linux-<arch>.tar.gz
#
# 注意: 该 tar.gz 解压后直接就是 scl-tunnel 可执行文件（无子目录），
# 跟官方发布包"子目录+二进制"的结构不同，本脚本按此结构处理。
#
# 用法：
#   直接以 root 运行即可： bash deploy-scl-tunnel.sh
#   卸载：                 bash deploy-scl-tunnel.sh uninstall
#   指定版本：              SB_VERSION=1.14.1 bash deploy-scl-tunnel.sh
# =====================================================

if [ -z "$BASH_VERSION" ]; then
    if ! apk add --no-cache bash >/dev/null 2>&1; then
        echo "安装 bash 失败，请检查网络连接或 apk 源配置后重试" >&2
        exit 1
    fi
    exec bash "$0" "$@"
fi

set -e
set -o pipefail

# ---- 颜色（直接用 ANSI 转义码，不依赖 tput/TERM）----
if [ -t 1 ]; then
    C_RED="$(printf '\033[31m')"
    C_GREEN="$(printf '\033[32m')"
    C_YELLOW="$(printf '\033[33m')"
    C_RESET="$(printf '\033[0m')"
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_RESET=""
fi
log_ok()   { printf '%s%s%s\n' "${C_GREEN}" "$*" "${C_RESET}"; }
log_err()  { printf '%s%s%s\n' "${C_RED}" "$*" "${C_RESET}" >&2; }
log_warn() { printf '%s%s%s\n' "${C_YELLOW}" "$*" "${C_RESET}"; }
log_info() { printf '%s\n' "$*"; }

# ---- 项目命名 ----
APP_NAME="scl-tunnel"
APP_DIR="/etc/${APP_NAME}"
APP_BIN="/usr/local/bin/${APP_NAME}"
SERVICE="${APP_NAME}"
LOG_FILE="/var/log/${APP_NAME}.log"

SB_VERSION="${SB_VERSION:-1.14.1}"
GOMEMLIMIT_VALUE="${GOMEMLIMIT_VALUE:-40MiB}"
GOGC_VALUE="${GOGC_VALUE:-30}"
VLESS_PORT=3270
WORK_DIR=""

log_info "================================="
log_info "${APP_NAME} 部署脚本 (自构建精简版 ${SB_VERSION})"
log_info "================================="

if [ "$(id -u)" != "0" ]; then
    log_err "请使用root运行"
    exit 1
fi

cleanup() {
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT INT TERM

# ---- 卸载 ----
if [ "$1" == "uninstall" ]; then
    log_warn "即将卸载 ${APP_NAME}，包括服务、二进制和配置文件"
    read -p "确认卸载？(y/N): " CONFIRM
    if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
        log_info "已取消"
        exit 0
    fi
    if [ -f "/etc/init.d/${SERVICE}" ]; then
        rc-service "$SERVICE" stop 2>/dev/null || true
        rc-update del "$SERVICE" default 2>/dev/null || true
        rm -f "/etc/init.d/${SERVICE}"
    fi
    rm -f "$APP_BIN"
    rm -rf "$APP_DIR"
    rm -f "$LOG_FILE"
    log_ok "卸载完成"
    exit 0
fi

if [ -f "$APP_BIN" ] || [ -f "/etc/init.d/${SERVICE}" ]; then
    log_warn "检测到 ${APP_NAME} 可能已安装（二进制或服务已存在）。"
    log_warn "继续将覆盖现有配置，UUID / WS Path 会重新生成，旧节点链接将失效。"
    read -p "是否继续？(y/N): " OVERWRITE_CONFIRM
    if [ "$OVERWRITE_CONFIRM" != "y" ] && [ "$OVERWRITE_CONFIRM" != "Y" ]; then
        log_info "已取消"
        exit 0
    fi
fi

WS_PATH="/$(openssl rand -hex 8 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
UUID=$(cat /proc/sys/kernel/random/uuid)

read -s -p "Cloudflare Tunnel Token: " CF_TOKEN
echo
if [ -z "$CF_TOKEN" ]; then
    log_err "Token不能为空"
    exit 1
fi

if [ ${#CF_TOKEN} -lt 100 ]; then
    log_warn "警告: Token 长度异常偏短（当前长度: ${#CF_TOKEN}），请确认是否完整复制"
    read -p "是否仍然继续？(y/N): " TOKEN_CONFIRM
    if [ "$TOKEN_CONFIRM" != "y" ] && [ "$TOKEN_CONFIRM" != "Y" ]; then
        log_info "已取消"
        exit 1
    fi
fi

read -p "你的域名(example.com): " DOMAIN
if [ -z "$DOMAIN" ]; then
    log_err "域名不能为空"
    exit 1
fi

case "$DOMAIN" in
    *" "*|*"/"*|http://*|https://*)
        log_err "域名格式不正确，请只输入裸域名，例如: example.com"
        exit 1
        ;;
esac

if ! echo "$DOMAIN" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'; then
    log_err "域名格式不正确，请检查后重新运行脚本"
    exit 1
fi

DNS_RESOLVED=0
if command -v getent >/dev/null 2>&1; then
    getent hosts "$DOMAIN" >/dev/null 2>&1 && DNS_RESOLVED=1
elif command -v nslookup >/dev/null 2>&1; then
    nslookup "$DOMAIN" >/dev/null 2>&1 && DNS_RESOLVED=1
fi

if [ "$DNS_RESOLVED" -eq 0 ]; then
    log_warn "警告: 域名 ${DOMAIN} 当前无法解析，请确认拼写正确"
    log_warn "且已在 Cloudflare 的「已发布应用程序路由」中为该主机名配置好路由"
    read -p "是否仍然继续？(y/N): " DNS_CONFIRM
    if [ "$DNS_CONFIRM" != "y" ] && [ "$DNS_CONFIRM" != "Y" ]; then
        log_info "已取消，请检查域名拼写后重新运行脚本"
        exit 1
    fi
else
    log_ok "域名解析检查通过: ${DOMAIN} 可正常解析"
fi

install_deps() {
    local missing=""
    command -v curl    >/dev/null 2>&1 || missing="$missing curl"
    command -v tar     >/dev/null 2>&1 || missing="$missing tar"
    command -v openssl >/dev/null 2>&1 || missing="$missing openssl"
    if ! command -v ss >/dev/null 2>&1 && ! command -v netstat >/dev/null 2>&1; then
        missing="$missing iproute2"
    fi
    if [ -n "$missing" ]; then
        log_info "更新 apk 索引..."
        apk update
        log_info "安装缺失依赖:$missing"
        apk add --no-cache $missing
    else
        log_info "所需依赖已全部满足，跳过 apk 安装"
    fi
}
install_deps

if command -v ss >/dev/null 2>&1; then
    ss -ltn 2>/dev/null | grep -q ":${VLESS_PORT} " && { log_err "端口 ${VLESS_PORT} 已被占用，请先释放或修改脚本中的 VLESS_PORT"; exit 1; }
elif command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | grep -q ":${VLESS_PORT} " && { log_err "端口 ${VLESS_PORT} 已被占用，请先释放或修改脚本中的 VLESS_PORT"; exit 1; }
else
    log_warn "警告: 未找到 ss/netstat，跳过端口占用检测"
fi

case "$(uname -m)" in
    x86_64)  SB_ARCH="amd64" ;;
    aarch64|arm64) SB_ARCH="arm64" ;;
    armv7l)  SB_ARCH="armv7" ;;
    *) log_err "不支持的架构: $(uname -m)"; exit 1 ;;
esac
log_info "检测到架构: $(uname -m) -> ${SB_ARCH}"

# ---- 自建 Release 地址，按需替换用户名/仓库 ----
SB_URL="https://github.com/xlsxmp/sing-box/releases/download/${SB_VERSION}/${APP_NAME}-${SB_VERSION}-linux-${SB_ARCH}.tar.gz"

is_tmpfs() {
    local fstype
    fstype=$(df -T "$1" 2>/dev/null | awk 'NR==2{print $2}')
    [ "$fstype" = "tmpfs" ]
}

for candidate in /root/.${APP_NAME}-install /var/tmp/${APP_NAME}-install; do
    mkdir -p "$candidate" 2>/dev/null || continue
    if ! is_tmpfs "$candidate"; then
        WORK_DIR="$candidate"
        break
    else
        rmdir "$candidate" 2>/dev/null || true
    fi
done
if [ -z "$WORK_DIR" ]; then
    log_warn "警告: 未找到非 tmpfs 候选目录，回退使用 /tmp（低内存/小tmpfs环境下有风险）"
    WORK_DIR="/tmp/${APP_NAME}-install"
    mkdir -p "$WORK_DIR"
fi
log_ok "工作目录: ${WORK_DIR}"

ARCHIVE_PATH="${WORK_DIR}/${APP_NAME}-${SB_VERSION}-linux-${SB_ARCH}.tar.gz"

log_info "下载 ${APP_NAME} ${SB_VERSION} (linux-${SB_ARCH}) ..."
log_info "URL: ${SB_URL}"

if ! curl -fL --connect-timeout 15 --max-time 180 --retry 3 -o "$ARCHIVE_PATH" "$SB_URL"; then
    log_err "下载失败，请检查网络连接、版本号，或确认该架构的 Release 是否已上传"
    exit 1
fi

if [ ! -s "$ARCHIVE_PATH" ]; then
    log_err "下载的文件为空，可能下载失败"
    exit 1
fi
log_ok "下载完成: $(du -h "$ARCHIVE_PATH" | cut -f1)"

log_info "解压中..."
if ! tar xzf "$ARCHIVE_PATH" -C "$WORK_DIR"; then
    log_err "解压失败，请确认文件完整且未损坏"
    exit 1
fi

# 这个包解压后直接是二进制文件，没有子目录
EXTRACTED_BIN="${WORK_DIR}/${APP_NAME}"
if [ ! -f "$EXTRACTED_BIN" ]; then
    log_err "解压后未找到预期的二进制文件: ${EXTRACTED_BIN}"
    log_info "解压出的实际内容："
    ls -la "$WORK_DIR"
    exit 1
fi

install -m 755 "$EXTRACTED_BIN" "$APP_BIN"
rm -f "$ARCHIVE_PATH" "$EXTRACTED_BIN"

if ! "$APP_BIN" version >/dev/null 2>&1; then
    log_err "二进制无法运行，可能与当前系统不兼容"
    exit 1
fi
log_ok "已安装到: ${APP_BIN}  ($("$APP_BIN" version | head -n1))"

mkdir -p "$APP_DIR"

cat > "${APP_DIR}/config.json" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": false
  },
  "inbounds": [
    {
      "type": "cloudflared",
      "tag": "cf-tunnel",
      "token": "${CF_TOKEN}",
      "protocol": "http2",
      "edge_ip_version": 4,
      "post_quantum": false
    },
    {
      "type": "vless",
      "tag": "vless-ws",
      "listen": "127.0.0.1",
      "listen_port": ${VLESS_PORT},
      "users": [
        { "uuid": "${UUID}" }
      ],
      "transport": {
        "type": "ws",
        "path": "${WS_PATH}"
      }
    }
  ],
  "route": {
    "rules": [
      {
        "inbound": ["cf-tunnel"],
        "action": "route",
        "outbound": "direct",
        "override_address": "127.0.0.1",
        "override_port": ${VLESS_PORT}
      }
    ]
  },
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

chmod 600 "${APP_DIR}/config.json"

cat > "/etc/init.d/${SERVICE}" <<EOF
#!/sbin/openrc-run
name="${APP_NAME}"
description="${APP_NAME} (sing-box minimal build) Cloudflare Tunnel"
command="${APP_BIN}"
command_args="run -c ${APP_DIR}/config.json"
command_background=true
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${LOG_FILE}"
error_log="${LOG_FILE}"
export GOMEMLIMIT="${GOMEMLIMIT_VALUE}"
export GOGC="${GOGC_VALUE}"
depend() {
    need net
    after firewall
}
EOF

chmod +x "/etc/init.d/${SERVICE}"

if command -v logrotate >/dev/null 2>&1; then
    cat > "/etc/logrotate.d/${APP_NAME}" <<EOF
${LOG_FILE} {
    weekly
    rotate 4
    missingok
    notifempty
    compress
    copytruncate
}
EOF
fi

log_info "校验配置..."
if ! "$APP_BIN" check -c "${APP_DIR}/config.json"; then
    log_err "配置校验失败，请检查上方报错信息，服务未启动"
    exit 1
fi

rc-update add "$SERVICE" default
rc-service "$SERVICE" restart

sleep 2

if ! rc-service "$SERVICE" status | grep -q started; then
    log_err "服务启动失败，请查看日志: cat ${LOG_FILE}"
    exit 1
fi

echo
log_ok "=============================="
log_ok "部署完成 (${APP_NAME})"
echo
log_info "二进制: ${APP_BIN}"
log_info "服务名: ${SERVICE}  (rc-service ${SERVICE} status / restart)"
log_info "日志:   ${LOG_FILE}"
echo
log_info "UUID:"
log_info "$UUID"
echo
log_info "WS Path:"
log_info "$WS_PATH"
echo
log_info "节点:"
echo
log_ok "vless://${UUID}@${DOMAIN}:443?encryption=none&security=tls&type=ws&host=${DOMAIN}&path=${WS_PATH}#${APP_NAME}"
echo
log_ok "=============================="
