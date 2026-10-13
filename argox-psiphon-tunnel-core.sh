#!/usr/bin/env bash
#
# ArgoX Lite (sing-box 版)
#
# 架构:
#   Cloudflare 边缘 ──隧道──> sing-box 内置 cloudflared 入站 ──路由──> 本地 VLESS(WS) 入站 ──> 出站(直连 / 链式出站)
#   只有一个 sing-box 进程，不需要 cloudflared 二进制，也不需要 Xray。
#
# 链式出站（出站标签统一为 warp，五种来源互斥，不做二跳）:
#   1. warp   : Cloudflare WARP（自动注册，WireGuard）
#   2. wgconf : 自定义 WireGuard 配置文件（如 ProtonVPN 官方后台导出的 .conf，解析标准 [Interface]/[Peer] 格式）
#   4. psiphon: 赛风 Psiphon —— 本机起一个 SOCKS5 代理进程（Psiphon 官方 tunnel core，静态编译版），
#               sing-box 通过 socks 出站接到 127.0.0.1:端口，可按国家选出口
#   3. ovpn   : 自定义 OpenVPN（用户名密码）
#               基于 sing-box 1.14+ 内置 openvpn-client endpoint，解析标准 .ovpn 获取
#               服务器地址/协议/CA 证书/tls-auth|tls-crypt/auth 摘要等，账号密码单独输入
#   5. ss     : 自有 VPS 落地（Shadowsocks，纯 TCP 链路）—— 在你的 VPS 上先运行 ss-exit.sh 一键部署服务端，
#               再在这里粘贴它输出的 ss:// 链接。适合本机出站 UDP 被封、WireGuard 走不通的 NAT 小鸡
#   分流模式（对五种来源都适用）: 解锁流媒体 & AI / 全局出站(隐藏源站 IP) / 自定义规则
#
# 保留: 固定隧道（Token，或用 Cloudflare API 令牌自动创建隧道/回源/DNS）、VLESS + WS + TLS
# 已移除: 临时隧道、Argo Json、cloudflared 二进制、Xray、VMess/Trojan
#
# 注意: 需要编译了 with_cloudflared 标签的 sing-box（脚本会检测）。
#       如果官方发布包没有该标签，可自行指定: SINGBOX_URL=<自编译包或二进制的下载地址>
#       OpenVPN 来源需要 sing-box >= 1.14 且编译了 openvpn-client 支持。
#
# 用法:
#   bash argox-lite.sh            交互菜单（首次运行即安装）
#   argox -n                      查看节点信息
#   argox -t                      更换 Argo 隧道
#   argox -w                      链式出站设置（WARP / WireGuard / OpenVPN / 赛风 / 自有 VPS）
#   argox -s                      开关 sing-box
#   argox -v                      同步 sing-box 到最新版
#   argox -u                      卸载
#
# 非交互安装: 预先导出变量即可跳过对应提问，例如
#   UUID=... WS_PATH=argox NODE_NAME=vps1 BASE_PORT=8080 CDN=ip.sb \
#   ARGO_DOMAIN=a.example.com ARGO_AUTH='<tunnel-token|cf-api-token>' \
#   WARP_MODE=unlock WARP_SOURCE=warp bash argox-lite.sh
#
#   # 自定义 WireGuard 配置文件
#   WARP_MODE=unlock WARP_SOURCE=wgconf WG_CONF_FILE=/root/proton.conf ... bash argox-lite.sh
#   # 赛风（国家码如 US/JP/SG；端口默认 40000）
#   WARP_MODE=unlock WARP_SOURCE=psiphon PSIPHON_COUNTRY=US PSIPHON_PORT=40000 ... bash argox-lite.sh
#   #   可选: PSIPHON_BIN_FILE=<本地已有的 tunnel core 路径>（优先于下载）
#   #         PSIPHON_URL=<自编译/自托管的 zip 或二进制地址> PSIPHON_SHA256=<二进制校验值，设为空则不校验>
#   # 自定义 OpenVPN（账号密码可省略，脚本会询问）
#   WARP_MODE=unlock WARP_SOURCE=ovpn OVPN_CONF_FILE=/root/ai.ovpn \
#   OVPN_USERNAME=user OVPN_PASSWORD=pass ... bash argox-lite.sh
#   # 自有 VPS 落地（Shadowsocks）：SS_URI 为 ss-exit.sh 输出的链接；SS_NETWORK 默认 tcp（可选 udp / both）
#   WARP_MODE=unlock WARP_SOURCE=ss SS_URI='ss://...' ... bash argox-lite.sh

VERSION='lite-2.6 (sing-box)'

SINGBOX_VERSION="${SINGBOX_VERSION:-1.14.2}"
WORK_DIR='/etc/argox'
TEMP_DIR='/tmp/argox'
CONF_FILE="${WORK_DIR}/config"
WARP_FILE="${WORK_DIR}/warp.conf"        # WARP 账号（WG_*）
CWG_FILE="${WORK_DIR}/wgcustom.conf"     # 自定义 WireGuard 参数（CWG_*）
OVPN_FILE="${WORK_DIR}/ovpn.conf"        # 自定义 OpenVPN 参数（OVPN_*）
PSI_FILE="${WORK_DIR}/psiphon.conf"      # 赛风参数（PSI_*）
PSI_BIN="${WORK_DIR}/psiphon-tunnel-core"   # Psiphon 官方 tunnel core（ConsoleClient）
PSI_CONF="${WORK_DIR}/psiphon-core.json"
PSI_DATA="${WORK_DIR}/psiphon-data"
# tunnel core 二进制: 默认从自托管仓库下载「CGO_ENABLED=0 静态编译」的官方 ConsoleClient（Alpine/musl 可直接运行）
# 官方 psiphon-tunnel-core-x86_64 经 UPX 压缩后依赖 glibc，Alpine 上无法运行，所以不用它
# 用 PSIPHON_URL 换地址（zip / tar.gz / 裸二进制均可）；PSIPHON_SHA256 固定二进制校验值（设为空字符串则不校验）
PSI_BIN_URL="${PSIPHON_URL:-https://github.com/xlsxmp/scl-tunnel/raw/refs/heads/main/psiphon-tunnel-core-static.zip}"
PSIPHON_SHA256="${PSIPHON_SHA256-f56138106cbab14ea56103c76210af2182017760100a9eff813469e7a32fafc6}"
# 以下与 bepass-org/warp-plus 的 psiphon/p.go 保持一致（不设上游代理，直连 Psiphon）
PSI_SPONSOR='FFFFFFFFFFFFFFFF'
PSI_LIST_URL='https://s3.amazonaws.com//psiphon/web/mjr4-p23r-puwl/server_list_compressed'
PSI_PUBKEY='MIICIDANBgkqhkiG9w0BAQEFAAOCAg0AMIICCAKCAgEAt7Ls+/39r+T6zNW7GiVpJfzq/xvL9SBH5rIFnk0RXYEYavax3WS6HOD35eTAqn8AniOwiH+DOkvgSKF2caqk/y1dfq47Pdymtwzp9ikpB1C5OfAysXzBiwVJlCdajBKvBZDerV1cMvRzCKvKwRmvDmHgphQQ7WfXIGbRbmmk6opMBh3roE42KcotLFtqp0RRwLtcBRNtCdsrVsjiI1Lqz/lH+T61sGjSjQ3CHMuZYSQJZo/KrvzgQXpkaCTdbObxHqb6/+i1qaVOfEsvjoiyzTxJADvSytVtcTjijhPEV6XskJVHE1Zgl+7rATr/pDQkw6DPCNBS1+Y6fy7GstZALQXwEDN/qhQI9kWkHijT8ns+i1vGg00Mk/6J75arLhqcodWsdeG/M/moWgqQAnlZAGVtJI1OgeF5fsPpXu4kctOfuZlGjVZXQNW34aOzm8r8S0eVZitPlbhcPiR4gT/aSMz/wd8lZlzZYsje/Jr8u/YtlwjjreZrGRmG8KMOzukV3lLmMppXFMvl4bxv6YFEmIuTsOhbLTwFgh7KYNjodLj/LsqRVfwz31PgWQFTEPICV7GCvgVlPRxnofqKSjgTWI4mxDhBpVcATvaoBl1L/6WLbFvBsoAUBItWwctO2xalKxF5szhGm8lccoc5MZr8kfE0uxMgsxz4er68iCID+rsCAQM='
PSI_SVC='argox-psiphon'
PSI_COUNTRIES=(AT AU BE BG CA CH CZ DE DK EE ES FI FR GB HR HU IE IN IT JP LV NL NO PL PT RO RS SE SG SK US)   # 与 warp-plus psiphon/p.go 的 Countries 一致
SB_CONFIG="${WORK_DIR}/config.json"
RULES_DIR="${WORK_DIR}/rules"
SVC='argox-singbox'
GH_PROXY="${GH_PROXY:-}"          # 可选: GitHub 反代前缀，如 https://xxx/
BASE_PORT_DEFAULT='8080'          # VLESS(WS) 在本机 127.0.0.1 上的监听端口，也是 Cloudflare 回源端口
CDN_DOMAIN=("skk.moe" "ip.sb" "time.is" "cf.090227.xyz" "bestcf.top" "cdn.2020111.xyz")
# 流媒体 / AI 预设（走链式出站）；geosite 对应 sing-geosite 的 rule-set
UNLOCK_RULES=("geosite:netflix" "geosite:disney" "geosite:category-ai-!cn" "geosite:hbo" "geosite:spotify" "geosite:openai" "domain:chatgpt.com" "domain:openai.com")
CONF_KEYS=(UUID WS_PATH NODE_NAME BASE_PORT CDN CDN_PORT ARGO_DOMAIN ARGO_TOKEN WARP_MODE WARP_SOURCE WARP_STACK WARP_CUSTOM)
CWG_KEYS=(CWG_PRIV CWG_V4 CWG_V6 CWG_PEER CWG_PSK CWG_HOST CWG_PORT CWG_ALLOWED CWG_KEEPALIVE CWG_MTU)
SOURCE_DIRTY=0   # 来源刚导入/注册/切换，应用前需要连通性测试
PSI_KEYS=(PSI_PORT PSI_COUNTRY PSI_STACK PSI_ENDPOINT)
SS_FILE="${WORK_DIR}/ss.conf"            # 自有 VPS（Shadowsocks）参数（SS_*）
SS_KEYS=(SS_SERVER SS_PORT SS_METHOD SS_PASS SS_NETWORK)
OVPN_KEYS=(OVPN_SERVER OVPN_PORT OVPN_PROTO OVPN_USER OVPN_PASS OVPN_CA OVPN_WRAP_TYPE OVPN_WRAP_KEY OVPN_WRAP_DIR OVPN_AUTH OVPN_SNAME OVPN_SNAME_TYPE OVPN_CIPHERS)

# ---------------------------------------------------------------- 基础工具
warning() { echo -e "\033[31m\033[01m$*\033[0m"; }
error()   { echo -e "\033[31m\033[01m$*\033[0m"; exit 1; }
info()    { echo -e "\033[32m\033[01m$*\033[0m"; }
hint()    { echo -e "\033[33m\033[01m$*\033[0m"; }
reading() { read -rp "$(info "$1")" "$2"; }
# ask 变量名 提示语 —— 变量已有值（环境变量预置）则跳过提问
ask()     { local _v=$1; shift; [ -n "${!_v}" ] || reading " $* " "$_v"; }

cleanup() { rm -rf "$TEMP_DIR"; }

check_root() { [ "$(id -u)" = 0 ] || error "\n 必须以 root 运行，可先执行 sudo -i \n"; }

check_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  SB_ARCH=amd64 ;;
    aarch64|arm64) SB_ARCH=arm64 ;;
    armv7l)        SB_ARCH=armv7 ;;
    *) error "\n 暂不支持的架构: $(uname -m) \n" ;;
  esac
}

check_system() {
  local sys=''
  [ -s /etc/os-release ] && sys=$(. /etc/os-release; echo "${ID} ${ID_LIKE}")
  sys=${sys,,}
  if   [[ $sys =~ alpine ]]; then
    SYSTEM=Alpine; PKG_UPDATE='apk update -f'; PKG_INSTALL='apk add --no-cache'
  elif [[ $sys =~ debian|ubuntu ]]; then
    SYSTEM=Debian; PKG_UPDATE='apt-get -y update'; PKG_INSTALL='apt-get -y install'
  elif [[ $sys =~ centos|rhel|fedora|rocky|alma ]]; then
    SYSTEM=CentOS; PKG_UPDATE=''; PKG_INSTALL='yum -y install'
    command -v dnf >/dev/null 2>&1 && PKG_INSTALL='dnf -y install'
  elif [[ $sys =~ arch ]]; then
    SYSTEM=Arch; PKG_UPDATE='pacman -Sy'; PKG_INSTALL='pacman -S --noconfirm'
  else
    error "\n 仅支持 Debian / Ubuntu / CentOS / Alpine / Arch \n"
  fi
}

# 服务管理: svc enable|disable|restart|start|stop|status 服务名
svc() {
  local act=$1 app=$2
  if [ "$SYSTEM" = Alpine ]; then
    case "$act" in
      enable)  rc-update add "$app" default >/dev/null 2>&1; rc-service "$app" restart >/dev/null 2>&1 ;;
      disable) rc-service "$app" stop >/dev/null 2>&1; rc-update del "$app" default >/dev/null 2>&1 ;;
      status)  rc-service "$app" status >/dev/null 2>&1 ;;
      *)       rc-service "$app" "$act" >/dev/null 2>&1 ;;
    esac
  else
    case "$act" in
      enable)  systemctl daemon-reload; systemctl enable --now "$app" >/dev/null 2>&1 ;;
      disable) systemctl disable --now "$app" >/dev/null 2>&1 ;;
      status)  systemctl is-active --quiet "$app" ;;
      *)       systemctl daemon-reload; systemctl "$act" "$app" >/dev/null 2>&1 ;;
    esac
  fi
}

install_deps() {
  local pkgs=()
  command -v wget    >/dev/null 2>&1 || pkgs+=(wget)
  if [ "$SYSTEM" = Alpine ] && ! wget --version 2>&1 | grep -qi 'GNU Wget'; then pkgs+=(wget); fi
  command -v tar     >/dev/null 2>&1 || pkgs+=(tar)
  command -v unzip   >/dev/null 2>&1 || pkgs+=(unzip)
  command -v openssl >/dev/null 2>&1 || pkgs+=(openssl)
  command -v jq      >/dev/null 2>&1 || pkgs+=(jq)
  command -v ss      >/dev/null 2>&1 || pkgs+=(iproute2)
  command -v bash    >/dev/null 2>&1 || pkgs+=(bash)
  [ -d /etc/ssl/certs ] || pkgs+=(ca-certificates)
  if [ "$SYSTEM" = Alpine ] && [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then pkgs+=(ca-certificates); fi
  if [ "${#pkgs[@]}" -gt 0 ]; then
    info "\n 安装依赖: ${pkgs[*]} \n"
    [ -n "$PKG_UPDATE" ] && $PKG_UPDATE >/dev/null 2>&1
    $PKG_INSTALL "${pkgs[@]}" >/dev/null 2>&1
  fi
  local c
  for c in wget tar unzip openssl jq ss; do
    command -v "$c" >/dev/null 2>&1 || error "\n 依赖 $c 安装失败，请手动安装后重试 \n"
  done
  wget --help 2>&1 | grep -q -- '--method' || error "\n 需要 GNU wget（当前 wget 不支持 --method） \n"
}

# ---------------------------------------------------------------- 端口 / 输入
is_port_in_use() { ss -nlt 2>/dev/null | awk 'NR>1{print $4}' | grep -qE "[:.]$1\$"; }

input_port() {
  local n=0
  while true; do
    ((n++)); [ "$n" -gt 5 ] && error "\n 输入错误次数过多，退出 \n"
    ask BASE_PORT "请输入本机监听端口（VLESS-WS 仅监听 127.0.0.1，1024-65535，默认 ${BASE_PORT_DEFAULT}）:"
    BASE_PORT=${BASE_PORT:-$BASE_PORT_DEFAULT}
    if [[ $BASE_PORT =~ ^[0-9]+$ ]] && [ "$BASE_PORT" -ge 1024 ] && [ "$BASE_PORT" -le 65535 ]; then
      is_port_in_use "$BASE_PORT" || break
      warning " 端口 $BASE_PORT 已被占用"
    else
      warning " 端口不合法"
    fi
    unset BASE_PORT
  done
}

input_uuid() {
  local n=0 re='^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$'
  until [[ ${UUID,,} =~ $re ]]; do
    ((n++)); [ "$n" -gt 5 ] && error "\n 输入错误次数过多，退出 \n"
    local def; def=$(cat /proc/sys/kernel/random/uuid)
    ask UUID "请输入 UUID（默认 ${def}）:"
    UUID=${UUID:-$def}
    [[ ${UUID,,} =~ $re ]] || { warning " UUID 格式不正确"; unset UUID; }
  done
  UUID=${UUID,,}
}

input_ws_path() {
  local n=0 def
  def=$(head -c 512 /dev/urandom | tr -dc 'a-z0-9' | head -c 16)
  ask WS_PATH "请输入 WS 路径（回车随机生成 16 位字符）:"
  WS_PATH=${WS_PATH:-$def}
  until [[ $WS_PATH =~ ^[A-Za-z0-9_.@-]+$ ]]; do
    ((n++)); [ "$n" -gt 4 ] && error "\n 输入错误次数过多，退出 \n"
    warning " 只允许字母、数字、- _ . @"
    reading " 请重新输入（回车随机生成 16 位字符）: " WS_PATH
    WS_PATH=${WS_PATH:-$def}
  done
  info " WS 路径: /${WS_PATH}"
}

input_node_name() {
  local host; host=$(hostname 2>/dev/null || echo ArgoX)
  ask NODE_NAME "请输入节点名称（默认 ${host}）:"
  NODE_NAME=${NODE_NAME:-$host}
  NODE_NAME=${NODE_NAME//\"/}
}

input_cdn() {
  if [ -z "$CDN" ]; then
    local i
    echo
    for i in "${!CDN_DOMAIN[@]}"; do hint " $((i + 1)). ${CDN_DOMAIN[i]}"; done
    reading "\n 请选择序号或输入优选域名/IP，可带端口如 ip.sb:2053（默认 ${CDN_DOMAIN[0]}）: " CDN
  fi
  if [[ $CDN =~ ^[0-9]+$ ]] && [ "$CDN" -ge 1 ] && [ "$CDN" -le "${#CDN_DOMAIN[@]}" ]; then
    CDN=${CDN_DOMAIN[$((CDN - 1))]}
  fi
  CDN=${CDN:-${CDN_DOMAIN[0]}}
  if [[ $CDN =~ ^([^:]+):([0-9]{1,5})$ ]]; then CDN=${BASH_REMATCH[1]}; CDN_PORT=${BASH_REMATCH[2]}; fi
  CDN_PORT=${CDN_PORT:-443}
}

# ---------------------------------------------------------------- 配置读写
save_conf() {
  local k
  mkdir -p "$WORK_DIR"
  : > "$CONF_FILE"; chmod 600 "$CONF_FILE"
  for k in "${CONF_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k}" >> "$CONF_FILE"; done
}

load_conf() {
  [ -s "$CONF_FILE" ] && . "$CONF_FILE"
  [ -s "$WARP_FILE" ] && . "$WARP_FILE"
  [ -s "$CWG_FILE" ]  && . "$CWG_FILE"
  [ -s "$OVPN_FILE" ] && . "$OVPN_FILE"
  [ -s "$PSI_FILE" ]  && . "$PSI_FILE"
  [ -s "$SS_FILE" ]   && . "$SS_FILE"
  WARP_MODE=${WARP_MODE:-off}
  WARP_SOURCE=${WARP_SOURCE:-warp}
  WARP_STACK=${WARP_STACK:-d}
}

save_warp() {
  : > "$WARP_FILE"; chmod 600 "$WARP_FILE"
  local k
  for k in WG_PRIV WG_V4 WG_V6 WG_PEER WG_RESERVED WG_ENDPOINT; do printf '%s=%q\n' "$k" "${!k}" >> "$WARP_FILE"; done
}

save_cwg() {
  : > "$CWG_FILE"; chmod 600 "$CWG_FILE"
  local k
  for k in "${CWG_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k}" >> "$CWG_FILE"; done
}

save_ovpn() {
  : > "$OVPN_FILE"; chmod 600 "$OVPN_FILE"
  local k
  for k in "${OVPN_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k}" >> "$OVPN_FILE"; done
}

save_psi() {
  : > "$PSI_FILE"; chmod 600 "$PSI_FILE"
  local k
  for k in "${PSI_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k}" >> "$PSI_FILE"; done
}

save_ss() {
  : > "$SS_FILE"; chmod 600 "$SS_FILE"
  local k
  for k in "${SS_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k}" >> "$SS_FILE"; done
}

is_installed() { [ -s "$CONF_FILE" ] && [ -x "$WORK_DIR/sing-box" ]; }

# 清理旧版（Xray + cloudflared 二进制）遗留的服务与文件
cleanup_legacy() {
  local s found=''
  for s in argox-argo argox-xray; do
    if [ -e "/etc/systemd/system/${s}.service" ] || [ -e "/etc/init.d/${s}" ]; then
      svc disable "$s"
      rm -f "/etc/systemd/system/${s}.service" "/etc/init.d/${s}"
      found=1
    fi
  done
  if [ -n "$found" ]; then
    [ "$SYSTEM" = Alpine ] || systemctl daemon-reload
    rm -f "$WORK_DIR"/{xray,cloudflared,inbound.json,outbound.json,tunnel.json,tunnel.yml,geoip.dat,geosite.dat,list}
    hint " 已清理旧版 Xray / cloudflared 服务与文件"
  fi
}

# ---------------------------------------------------------------- 下载 sing-box
verify_singbox_tags() {
  local tags
  tags=$("$WORK_DIR/sing-box" version 2>/dev/null | awk -F': *' '/^Tags/{print $2}')
  if [ -n "$tags" ] && ! grep -q 'with_cloudflared' <<< "$tags"; then
    rm -f "$WORK_DIR/sing-box"
    error "\n 当前 sing-box 没有编译 with_cloudflared 标签，无法使用 cloudflared 入站。\n 已有标签: ${tags}\n 请自行编译（-tags 加入 with_cloudflared）后，用 SINGBOX_URL=<下载地址> 重新运行。\n"
  fi
}

download_singbox() {
  local ver=${1:-$SINGBOX_VERSION} base url bin tmp="$TEMP_DIR/sb"
  local urls=()
  rm -rf "$tmp"; mkdir -p "$tmp" "$WORK_DIR"
  base="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${SB_ARCH}"
  if [ -n "$SINGBOX_URL" ]; then
    urls=("$SINGBOX_URL")
  else
    [ "$SYSTEM" = Alpine ] && urls+=("${base}-musl.tar.gz")   # Alpine(musl) 优先尝试 musl 构建，不存在则回退
    urls+=("${base}.tar.gz")
  fi
  for url in "${urls[@]}"; do
    wget -qO "$tmp/sb.pkg" "${GH_PROXY}${url}" && [ -s "$tmp/sb.pkg" ] && break
    rm -f "$tmp/sb.pkg"
  done
  [ -s "$tmp/sb.pkg" ] || error "\n 下载 sing-box ${ver} 失败（可设置 GH_PROXY 或 SINGBOX_URL 后重试） \n"
  if tar -tzf "$tmp/sb.pkg" >/dev/null 2>&1; then
    tar -xzf "$tmp/sb.pkg" -C "$tmp" || error "\n 解压 sing-box 失败 \n"
    bin=$(find "$tmp" -type f -name sing-box | head -n1)
  else
    bin="$tmp/sb.pkg"   # SINGBOX_URL 直接给的是二进制
  fi
  [ -n "$bin" ] && [ -f "$bin" ] || error "\n 安装包内没有找到 sing-box 可执行文件 \n"
  cp -f "$bin" "$WORK_DIR/sing-box.new" && chmod +x "$WORK_DIR/sing-box.new"
  "$WORK_DIR/sing-box.new" version >/dev/null 2>&1 || { rm -f "$WORK_DIR/sing-box.new"; error "\n 下载的 sing-box 无法运行（架构或 libc 不匹配？） \n"; }
  mv -f "$WORK_DIR/sing-box.new" "$WORK_DIR/sing-box"
  verify_singbox_tags
}

# ---------------------------------------------------------------- Argo 隧道（仅固定隧道: Token / Cloudflare API）
cf_api() { # cf_api METHOD PATH [JSON]
  local m=$1 p=$2 d=$3
  if [ -n "$d" ]; then
    wget -qO- --content-on-error --timeout=20 --method="$m" --body-data="$d" \
      --header="Authorization: Bearer ${CF_API_TOKEN}" --header='Content-Type: application/json' \
      "https://api.cloudflare.com/client/v4${p}" 2>/dev/null
  else
    wget -qO- --content-on-error --timeout=20 --method="$m" \
      --header="Authorization: Bearer ${CF_API_TOKEN}" --header='Content-Type: application/json' \
      "https://api.cloudflare.com/client/v4${p}" 2>/dev/null
  fi
}

# 通过 Cloudflare API 创建（或复用同名）隧道 + 回源配置 + DNS，成功后设置 ARGO_TOKEN
create_argo_tunnel() {
  local domain=$1 port=$2 name acct zid tid resp secret rid
  hint "\n 使用 Cloudflare API 创建隧道、回源与 DNS ..."
  name="argox-${domain//./-}"

  # 逐级向上查找域名所属 Zone，同时从 Zone 信息里取 Account ID，令牌无需「账户设置:读取」权限
  local cand=$domain
  while [[ $cand == *.* ]]; do
    resp=$(cf_api GET "/zones?name=${cand}")
    zid=$(jq -r '.result[0].id // empty' <<< "$resp" 2>/dev/null)
    [ -n "$zid" ] && break
    if [ "$(jq -r '.success' <<< "$resp" 2>/dev/null)" != true ]; then
      warning " API 请求失败（令牌无效/权限不足）: $(jq -c '.errors' <<< "$resp" 2>/dev/null)"
      [ -z "$resp" ] && warning " 没有收到响应，请检查 VPS 能否访问 api.cloudflare.com"
      return 1
    fi
    cand=${cand#*.}
  done
  [ -n "$zid" ] || { warning " 令牌授权的区域中找不到 ${domain} 的根域名（区域资源是否选了对应域名？）"; return 1; }
  acct=$CF_ACCOUNT_ID
  [ -n "$acct" ] || acct=$(jq -r '.result[0].account.id // empty' <<< "$resp" 2>/dev/null)
  if [ -z "$acct" ]; then
    resp=$(cf_api GET /accounts)
    acct=$(jq -r '.result[0].id // empty' <<< "$resp" 2>/dev/null)
  fi
  [ -n "$acct" ] || { warning " 未获取到 Account ID，可手动指定: CF_ACCOUNT_ID=你的账户ID bash argox-lite.sh"; return 1; }

  resp=$(cf_api GET "/accounts/${acct}/cfd_tunnel?name=${name}&is_deleted=false")
  tid=$(jq -r '.result[0].id // empty' <<< "$resp" 2>/dev/null)
  if [ -z "$tid" ]; then
    secret=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    resp=$(cf_api POST "/accounts/${acct}/cfd_tunnel" "{\"name\":\"${name}\",\"config_src\":\"cloudflare\",\"tunnel_secret\":\"${secret}\"}")
    tid=$(jq -r '.result.id // empty' <<< "$resp" 2>/dev/null)
    [ -n "$tid" ] || { warning " 创建隧道失败: $(jq -c '.errors' <<< "$resp" 2>/dev/null)"; return 1; }
  else
    hint " 发现同名隧道 ${name}，复用并更新其回源配置"
  fi

  resp=$(cf_api PUT "/accounts/${acct}/cfd_tunnel/${tid}/configurations" \
    "{\"config\":{\"ingress\":[{\"hostname\":\"${domain}\",\"service\":\"http://127.0.0.1:${port}\"},{\"service\":\"http_status:404\"}]}}")
  [ "$(jq -r '.success' <<< "$resp" 2>/dev/null)" = true ] || { warning " 写入回源配置失败: $(jq -c '.errors' <<< "$resp" 2>/dev/null)"; return 1; }

  resp=$(cf_api GET "/zones/${zid}/dns_records?name=${domain}")
  rid=$(jq -r '.result[0].id // empty' <<< "$resp" 2>/dev/null)
  local rec="{\"type\":\"CNAME\",\"name\":\"${domain}\",\"content\":\"${tid}.cfargotunnel.com\",\"proxied\":true}"
  if [ -n "$rid" ]; then resp=$(cf_api PUT "/zones/${zid}/dns_records/${rid}" "$rec")
  else resp=$(cf_api POST "/zones/${zid}/dns_records" "$rec"); fi
  [ "$(jq -r '.success' <<< "$resp" 2>/dev/null)" = true ] || { warning " 写入 DNS 失败: $(jq -c '.errors' <<< "$resp" 2>/dev/null)"; return 1; }

  resp=$(cf_api GET "/accounts/${acct}/cfd_tunnel/${tid}/token")
  ARGO_TOKEN=$(jq -r '.result // empty' <<< "$resp" 2>/dev/null)
  [ -n "$ARGO_TOKEN" ] || { warning " 获取隧道 Token 失败"; return 1; }
  info " 隧道创建完成: ${domain} -> http://127.0.0.1:${port}"
  return 0
}

# 确定 ARGO_DOMAIN 与 ARGO_TOKEN（Token 直接使用；Cloudflare API 令牌则自动创建后取得 Token）
argo_setup() {
  local n=0
  while true; do
    ((n++)); [ "$n" -gt 3 ] && error "\n 固定隧道信息多次无效，退出 \n"
    hint "\n 固定隧道所需信息（必须填写，不再支持临时隧道 / Json）:\n [*] Token: https://dash.cloudflare.com/ → Zero Trust → 网络 → 连接器 → 创建隧道 → Cloudflared，\n           并把 Public Hostname 的 Service 设为 HTTP  127.0.0.1:${BASE_PORT}\n [*] API  : https://dash.cloudflare.com/profile/api-tokens 创建自定义令牌，权限:\n           账户 > Cloudflare One 连接器: Cloudflared > 编辑；区域 > DNS > 编辑（脚本自动完成回源与 DNS）\n"
    ask ARGO_DOMAIN "请输入 Argo 域名:"
    ask ARGO_AUTH "请输入 Tunnel Token 或 Cloudflare API 令牌:"
    ARGO_DOMAIN=${ARGO_DOMAIN//[[:space:]]/}
    ARGO_DOMAIN=${ARGO_DOMAIN#http://}; ARGO_DOMAIN=${ARGO_DOMAIN#https://}; ARGO_DOMAIN=${ARGO_DOMAIN%%/*}
    ARGO_TOKEN=''

    if [[ $ARGO_AUTH =~ TunnelSecret ]]; then
      warning " 已不支持 Argo Json，请使用 Token 或 Cloudflare API 令牌"
    elif [[ $ARGO_AUTH =~ [A-Za-z0-9=+/_-]{120,250}$ ]]; then
      ARGO_TOKEN=$(awk '{print $NF}' <<< "$ARGO_AUTH")
    elif [ -n "$ARGO_DOMAIN" ] && [ "${#ARGO_AUTH}" -ge 30 ] && [ "${#ARGO_AUTH}" -le 69 ]; then
      CF_API_TOKEN=$ARGO_AUTH
      create_argo_tunnel "$ARGO_DOMAIN" "$BASE_PORT" || ARGO_TOKEN=''
    fi

    [ -n "$ARGO_TOKEN" ] && [ -n "$ARGO_DOMAIN" ] && break
    warning "\n 域名或令牌无效，请重新输入 \n"
    unset ARGO_DOMAIN ARGO_AUTH ARGO_TOKEN
  done
  unset ARGO_AUTH CF_API_TOKEN
}

# ---------------------------------------------------------------- 分流规则 -> sing-box 配置
# 当前模式下需要走链式出站的域名规则（每行一条）
build_domain_list() {
  local arr item
  [ "$WARP_MODE" = unlock ] && printf '%s\n' "${UNLOCK_RULES[@]}"
  if [ "$WARP_MODE" != global ] && [ -n "$WARP_CUSTOM" ]; then
    IFS=',' read -ra arr <<< "$WARP_CUSTOM"
    for item in "${arr[@]}"; do [ -n "$item" ] && echo "$item"; done
  fi
}

# sing-box 已移除 geosite 数据库，改用 rule-set；这里下载 sing-geosite 的 .srs 到本地
fetch_ruleset() { # fetch_ruleset 名称
  local f="${RULES_DIR}/geosite-$1.srs"
  [ -s "$f" ] && return 0
  mkdir -p "$RULES_DIR"
  wget -qO "$f" "${GH_PROXY}https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-$1.srs" 2>/dev/null && [ -s "$f" ] && return 0
  rm -f "$f"
  return 1
}

json_arr() { if [ $# -gt 0 ]; then printf '%s\n' "$@" | jq -R . | jq -s -c .; else echo '[]'; fi; }

# ---------------------------------------------------------------- 四种出站来源 -> endpoint JSON（标签统一为 warp）
# 来源: warp(Cloudflare WARP) / wgconf(自定义 WireGuard) / ovpn(自定义 OpenVPN) / psiphon(赛风)
source_label() {
  case "$WARP_SOURCE" in
    wgconf) echo '自定义 WireGuard' ;;
    ovpn)   echo '自定义 OpenVPN' ;;
    psiphon) echo '赛风 Psiphon' ;;
    ss)     echo '自有 VPS（Shadowsocks）' ;;
    *)      echo 'Cloudflare WARP' ;;
  esac
}

# 当前来源的凭据/参数是否已就绪
source_ready() {
  case "$WARP_SOURCE" in
    wgconf) [ -n "$CWG_PRIV" ] && [ -n "$CWG_PEER" ] && [ -n "$CWG_HOST" ] ;;
    ovpn)   [ -n "$OVPN_SERVER" ] && [ -n "$OVPN_USER" ] && [ -n "$OVPN_PASS" ] ;;
    psiphon) [ -n "$PSI_PORT" ] && [ -n "$PSI_COUNTRY" ] && [ -x "$PSI_BIN" ] ;;
    ss)     [ -n "$SS_SERVER" ] && [ -n "$SS_PORT" ] && [ -n "$SS_METHOD" ] && [ -n "$SS_PASS" ] ;;
    *)      [ -n "$WG_PRIV" ] && [ -n "$WG_V4" ] ;;
  esac
}

# 凭据缺失时获取：WARP 自动注册（失败可手动填）/ 导入 WireGuard 配置 / 导入 OpenVPN 配置
setup_source() {
  local rc
  case "$WARP_SOURCE" in
    wgconf) import_wg_conf ;;
    ovpn)   import_ovpn_conf ;;
    psiphon) setup_psiphon ;;
    ss)     import_ss ;;
    *)      warp_register || warp_manual ;;
  esac
  rc=$?
  [ "$rc" = 0 ] && SOURCE_DIRTY=1
  return "$rc"
}

# 输出 WARP 的 WireGuard endpoint JSON
endpoint_warp() {
  local dr='null' host port a4 a6
  case "$WARP_STACK" in
    4) dr='{"server":"local","strategy":"ipv4_only"}' ;;
    6) dr='{"server":"local","strategy":"ipv6_only"}' ;;
  esac
  host=${WG_ENDPOINT%:*}; host=${host#[}; host=${host%]}; port=${WG_ENDPOINT##*:}
  a4=${WG_V4:+${WG_V4}/32}; a6=${WG_V6:+${WG_V6}/128}
  jq -n -c --arg k "$WG_PRIV" --arg a4 "$a4" --arg a6 "$a6" --arg pub "$WG_PEER" \
    --arg h "$host" --arg p "$port" --arg res "$WG_RESERVED" --argjson dr "$dr" '
    { type: "wireguard", tag: "warp", mtu: 1280,
      address: ([$a4, $a6] | map(select(. != ""))),
      private_key: $k,
      peers: [ ({ address: $h, port: ($p | tonumber), public_key: $pub, allowed_ips: ["0.0.0.0/0", "::/0"] }
                + (if $res == "" then {} else { reserved: ($res | split(",") | map(tonumber)) } end)) ] }
    + (if $dr == null then {} else { domain_resolver: $dr } end)'
}

# 输出自定义 WireGuard（配置文件导入）的 endpoint JSON
endpoint_wgconf() {
  local allowed
  allowed=${CWG_ALLOWED:-0.0.0.0/0,::/0}
  allowed=$(jq -R -c 'split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(. != ""))' <<< "$allowed")
  jq -n -c --arg k "$CWG_PRIV" --arg a4 "$CWG_V4" --arg a6 "$CWG_V6" --arg pub "$CWG_PEER" \
    --arg h "$CWG_HOST" --arg p "$CWG_PORT" --arg psk "$CWG_PSK" --arg ka "$CWG_KEEPALIVE" \
    --arg mtu "$CWG_MTU" --argjson al "$allowed" '
    { type: "wireguard", tag: "warp",
      address: ([$a4, $a6] | map(select(. != ""))),
      private_key: $k,
      peers: [ ({ address: $h, port: ($p | tonumber), public_key: $pub, allowed_ips: $al }
                + (if $psk == "" then {} else { pre_shared_key: $psk } end)
                + (if $ka == "" then {} else { persistent_keepalive_interval: ($ka | tonumber) } end)) ] }
    + (if $mtu == "" then {} else { mtu: ($mtu | tonumber) } end)'
}

# 输出自定义 OpenVPN（openvpn-client）的 endpoint JSON
# 注意: auth 摘要同时决定 tls-auth 控制通道 HMAC，默认 SHA1；.ovpn 里写 auth SHA512（如 Windscribe）时必须传入，否则握手包被服务器丢弃
endpoint_ovpn() {
  jq -n -c --arg s "$OVPN_SERVER" --argjson port "${OVPN_PORT:-1194}" --arg net "${OVPN_PROTO:-udp}" \
    --arg u "$OVPN_USER" --arg p "$OVPN_PASS" --arg ca "$OVPN_CA" \
    --arg wt "$OVPN_WRAP_TYPE" --arg wk "$OVPN_WRAP_KEY" --arg wd "$OVPN_WRAP_DIR" \
    --arg au "$OVPN_AUTH" --arg sn "$OVPN_SNAME" --arg snt "$OVPN_SNAME_TYPE" --arg dc "$OVPN_CIPHERS" '
    { type: "openvpn-client", tag: "warp", server: $s, server_port: $port, network: $net,
      username: $u, password: $p, auth_retry: "nointeract",
      tls: ({ certificate_path: $ca }
            + (if $sn == "" then {} else { server_name: $sn, server_name_type: $snt } end)
            + (if $wt == "" or $wk == "" then {}
               else { control_wrap: ({ type: $wt, key_path: $wk }
                                     + (if $wd == "" then {} else { direction: $wd } end)) } end)) }
    + (if $au == "" then {} else { auth: ($au | ascii_upcase) } end)
    + (if $dc == "" then {} else { data_ciphers: ($dc | split(":")) } end)'
}

build_endpoint() {
  case "$WARP_SOURCE" in
    wgconf) endpoint_wgconf ;;
    ovpn)   endpoint_ovpn ;;
    psiphon) endpoint_psiphon ;;
    ss)     endpoint_ss ;;
    *)      endpoint_warp ;;
  esac
}

gen_config() {
  local ep='' wr='[]' rs='[]' final='direct' line val
  local -a sets=() suf=() full=() kw=() tags=()

  if [ "$WARP_MODE" != off ] && source_ready; then
    ep=$(build_endpoint) && [ -n "$ep" ] || error "\n 链式出站（$(source_label)）配置生成失败 \n"

    case "$WARP_MODE" in
      global)
        # 内网地址直连，其余全部走链式出站
        final='warp'
        wr='[{"ip_is_private":true,"outbound":"direct"}]'
        ;;
      unlock|custom)
        # 先嗅探 TLS/HTTP 域名，再按域名规则分流到链式出站，其余直连
        wr='[{"inbound":["vless-in"],"action":"sniff"}]'
        while IFS= read -r line; do
          [ -z "$line" ] && continue
          val=${line#*:}
          case "$line" in
            geosite:*) if fetch_ruleset "$val"; then sets+=("$val"); else warning " 规则集 geosite-${val} 下载失败，已跳过" >&2; fi ;;
            domain:*)  suf+=("$val") ;;
            full:*)    full+=("$val") ;;
            keyword:*) kw+=("$val") ;;
          esac
        done < <(build_domain_list)
        if [ "${#sets[@]}" -gt 0 ]; then
          mapfile -t sets < <(printf '%s\n' "${sets[@]}" | sort -u)
          tags=("${sets[@]/#/geosite-}")
          rs=$(printf '%s\n' "${sets[@]}" | jq -R --arg d "$RULES_DIR" \
            '{ type: "local", tag: ("geosite-" + .), format: "binary", path: ($d + "/geosite-" + . + ".srs") }' | jq -s -c .)
          wr=$(jq -c --argjson a "$(json_arr "${tags[@]}")" '. + [{ rule_set: $a, outbound: "warp" }]' <<< "$wr")
        fi
        [ "${#suf[@]}"  -gt 0 ] && wr=$(jq -c --argjson a "$(json_arr "${suf[@]}")"  '. + [{ domain_suffix: $a,  outbound: "warp" }]' <<< "$wr")
        [ "${#full[@]}" -gt 0 ] && wr=$(jq -c --argjson a "$(json_arr "${full[@]}")" '. + [{ domain: $a,         outbound: "warp" }]' <<< "$wr")
        [ "${#kw[@]}"   -gt 0 ] && wr=$(jq -c --argjson a "$(json_arr "${kw[@]}")"   '. + [{ domain_keyword: $a, outbound: "warp" }]' <<< "$wr")
        ;;
    esac
  fi
  [ -n "$ep" ] || ep='null'

  jq -n -c --arg token "$ARGO_TOKEN" --arg uuid "$UUID" --arg path "/${WS_PATH}" --argjson port "$BASE_PORT" \
    --argjson ep "$ep" --argjson rs "$rs" --argjson wr "$wr" --arg final "$final" --arg lvl "${SB_LOG_LEVEL:-warn}" '
    { log: { level: $lvl, timestamp: true },
      dns: { servers: [ { type: "local", tag: "local" } ] },
      inbounds: [
        { type: "cloudflared", tag: "cf-in", token: $token, grace_period: "3s" },
        { type: "vless", tag: "vless-in", listen: "127.0.0.1", listen_port: $port,
          users: [ { uuid: $uuid } ], transport: { type: "ws", path: $path } }
      ],
      outbounds: ([ { type: "direct", tag: "direct" } ] + (if $ep != null and ($ep.type == "socks" or $ep.type == "shadowsocks") then [ $ep ] else [] end)),
      route: ({ default_domain_resolver: "local",
                rules: ([ { inbound: ["cf-in"], outbound: "direct" } ] + $wr),
                final: $final }
              + (if ($rs | length) > 0 then { rule_set: $rs } else {} end)) }
    + (if $ep == null or $ep.type == "socks" or $ep.type == "shadowsocks" then {} else { endpoints: [ $ep ] } end)' | jq . > "$SB_CONFIG" \
    || error "\n config.json 生成失败 \n"
  chmod 600 "$SB_CONFIG"
}

test_config() {
  "$WORK_DIR/sing-box" check -c "$SB_CONFIG" 2>&1
}

# ---------------------------------------------------------------- 守护进程
write_daemon() {
  local run="${WORK_DIR}/sing-box run -c ${SB_CONFIG}"
  if [ "$SYSTEM" = Alpine ]; then
    cat > "/etc/init.d/${SVC}" << EOF
#!/sbin/openrc-run

name="${SVC}"
command="${WORK_DIR}/sing-box"
command_args="run -c ${SB_CONFIG}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="${WORK_DIR}/sing-box.log"
error_log="${WORK_DIR}/sing-box.log"

depend() {
    need net
    after firewall
}
EOF
    chmod +x "/etc/init.d/${SVC}"
  else
    cat > "/etc/systemd/system/${SVC}.service" << EOF
[Unit]
Description=ArgoX sing-box (cloudflared inbound)
After=network.target network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORK_DIR}
ExecStart=${run}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  fi
}

create_shortcut() {
  local self; self=$(readlink -f "$0" 2>/dev/null)
  if [ -f "$self" ]; then
    cp -f "$self" "$WORK_DIR/ax.sh" && chmod +x "$WORK_DIR/ax.sh"
    ln -sf "$WORK_DIR/ax.sh" /usr/bin/argox
    info " 已创建快捷命令: argox"
  else
    hint " 提示: 脚本不是以文件方式运行，未创建 argox 快捷命令（先保存为文件再执行即可）"
  fi
}

# ---------------------------------------------------------------- 来源 1: WARP（账号注册）
default_endpoint() {
  if [ -n "$WARP_ENDPOINT" ]; then echo "$WARP_ENDPOINT"
  elif ip -4 route show default 2>/dev/null | grep -q .; then echo '162.159.192.1:2408'
  else echo '[2606:4700:d0::a29f:c001]:2408'; fi
}

# 通过 Cloudflare 客户端注册接口自动申请 WARP 账号（与 wgcf 同一接口）
warp_register() {
  local pem="$TEMP_DIR/wg.pem" priv pub resp cid
  info "\n 正在注册 WARP 账号 ..."
  mkdir -p "$TEMP_DIR"
  openssl genpkey -algorithm x25519 -out "$pem" 2>/dev/null || return 1
  priv=$(openssl pkey -in "$pem" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
  pub=$(openssl pkey -in "$pem" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\n')
  rm -f "$pem"
  [ -n "$priv" ] && [ -n "$pub" ] || return 1

  resp=$(wget -qO- --timeout=10 --tries=2 --method=POST \
    --header='Content-Type: application/json' --header='User-Agent: okhttp/3.12.1' --header='CF-Client-Version: a-6.3-1922' \
    --body-data="{\"key\":\"${pub}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"type\":\"Android\",\"model\":\"PC\",\"locale\":\"en_US\"}" \
    https://api.cloudflareclient.com/v0a2158/reg 2>/dev/null)

  WG_V4=$(jq -r '.config.interface.addresses.v4 // empty' <<< "$resp" 2>/dev/null)
  WG_V6=$(jq -r '.config.interface.addresses.v6 // empty' <<< "$resp" 2>/dev/null)
  WG_PEER=$(jq -r '.config.peers[0].public_key // empty' <<< "$resp" 2>/dev/null)
  cid=$(jq -r '.config.client_id // empty' <<< "$resp" 2>/dev/null)
  if [ -z "$WG_V4" ] || [ -z "$WG_PEER" ]; then
    unset WG_PRIV WG_V4 WG_V6 WG_PEER WG_RESERVED WG_ENDPOINT
    return 1
  fi
  WG_PRIV=$priv
  WG_RESERVED=''
  [ -n "$cid" ] && WG_RESERVED=$(printf '%s' "$cid" | base64 -d 2>/dev/null | od -An -tu1 | tr -d '\n' | tr -s ' ' ',' | sed 's/^,//; s/,$//')
  WG_ENDPOINT=$(default_endpoint)
  save_warp
  info " WARP 账号注册成功（IPv4: ${WG_V4}）"
}

# 自动注册失败时，手动导入 WireGuard 参数（可用 wgcf 生成）
warp_manual() {
  warning "\n WARP 自动注册失败。可手动填入 WireGuard 参数（例如用 wgcf 生成），直接回车放弃。"
  reading " PrivateKey: " WG_PRIV
  [ -z "$WG_PRIV" ] && { unset WG_PRIV; return 1; }
  reading " 接口 IPv4 地址（如 172.16.0.2）: " WG_V4
  reading " 接口 IPv6 地址（可留空）: " WG_V6
  reading " 对端 PublicKey（默认 bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=）: " WG_PEER
  WG_PEER=${WG_PEER:-bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=}
  reading " Reserved（如 78,135,76，可留空）: " WG_RESERVED
  WG_RESERVED=${WG_RESERVED//[[:space:]]/}
  WG_ENDPOINT=$(default_endpoint)
  [ -n "$WG_V4" ] || { unset WG_PRIV WG_V4 WG_V6 WG_PEER WG_RESERVED WG_ENDPOINT; return 1; }
  save_warp
}

# ---------------------------------------------------------------- 来源 2: 自定义 WireGuard 配置文件
# 只解析标准 WireGuard 客户端配置（[Interface] / [Peer]），不调用任何第三方接口。
# 典型来源: ProtonVPN 官方后台 -> Downloads -> WireGuard 配置 导出的 .conf
# 配置文件路径: 环境变量 WG_CONF_FILE，或交互输入。仅读取第一个 [Peer]。
_looks_like_wg_key() { [ "${#1}" -eq 44 ] && [[ $1 == *= ]]; }

import_wg_conf() {
  local f=$WG_CONF_FILE sec='' line key val a addr='' arr
  local t_priv='' t_v4='' t_v6='' t_peer='' t_psk='' t_host='' t_port='' t_allowed='' t_ka='' t_mtu=''

  if [ -z "$f" ] || [ ! -f "$f" ]; then
    reading "\n 请输入 WireGuard 配置文件（.conf）路径: " f
  fi
  [ -f "$f" ] || { warning " 文件不存在: ${f}"; return 1; }

  while IFS= read -r line || [ -n "$line" ]; do
    line=${line//$'\r'/}
    line=${line%%#*}; line=${line%%;*}
    line=$(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<< "$line")
    [ -z "$line" ] && continue
    case "${line,,}" in
      '[interface]') sec=i; continue ;;
      '[peer]') [ "$sec" = p ] && { hint " 配置文件包含多个 [Peer]，仅使用第一个"; break; }; sec=p; continue ;;
    esac
    [[ $line == *=* ]] || continue
    key=$(sed 's/[[:space:]]*$//' <<< "${line%%=*}")
    val=$(sed 's/^[[:space:]]*//' <<< "${line#*=}")
    case "${sec}:${key,,}" in
      i:privatekey)           t_priv=$val ;;
      i:address)              addr=$val ;;
      i:mtu)                  t_mtu=$val ;;
      p:publickey)            t_peer=$val ;;
      p:presharedkey)         t_psk=$val ;;
      p:allowedips)           t_allowed=$val ;;
      p:persistentkeepalive)  t_ka=$val ;;
      p:endpoint)
        if [[ $val == \[*\]:* ]]; then t_host=${val#\[}; t_host=${t_host%%\]*}
        else t_host=${val%:*}; fi
        t_port=${val##*:}
        ;;
    esac
  done < "$f"

  # Address 可能同时含 IPv4 / IPv6（逗号分隔），缺掩码时补全
  IFS=',' read -ra arr <<< "$addr"
  for a in "${arr[@]}"; do
    a=${a//[[:space:]]/}
    [ -z "$a" ] && continue
    if [[ $a == *:* ]]; then [[ $a == */* ]] || a="${a}/128"; t_v6=$a
    else [[ $a == */* ]] || a="${a}/32"; t_v4=$a; fi
  done
  t_allowed=${t_allowed//[[:space:]]/}

  local missing=()
  [ -z "$t_priv" ] && missing+=("[Interface] PrivateKey")
  [ -z "$t_v4" ] && [ -z "$t_v6" ] && missing+=("[Interface] Address")
  [ -z "$t_peer" ] && missing+=("[Peer] PublicKey")
  [ -z "$t_host" ] && missing+=("[Peer] Endpoint")
  [[ $t_port =~ ^[0-9]+$ ]] || missing+=("[Peer] Endpoint 端口")
  if [ "${#missing[@]}" -gt 0 ]; then
    warning " WireGuard 配置缺少/无效字段: ${missing[*]}（文件: ${f}）"
    return 1
  fi
  _looks_like_wg_key "$t_priv" || hint " 提示: PrivateKey 长度不像标准 WireGuard 密钥，请确认是否复制完整"
  _looks_like_wg_key "$t_peer" || hint " 提示: Peer PublicKey 长度不像标准 WireGuard 密钥，请确认是否复制完整"
  [[ -z $t_ka  || $t_ka  =~ ^[0-9]+$ ]] || { hint " 忽略无效的 PersistentKeepalive: ${t_ka}"; t_ka=''; }
  [[ -z $t_mtu || $t_mtu =~ ^[0-9]+$ ]] || { hint " 忽略无效的 MTU: ${t_mtu}"; t_mtu=''; }
  [ "$t_ka" = 0 ] && t_ka=''

  CWG_PRIV=$t_priv; CWG_V4=$t_v4; CWG_V6=$t_v6; CWG_PEER=$t_peer; CWG_PSK=$t_psk
  CWG_HOST=$t_host; CWG_PORT=$t_port; CWG_ALLOWED=$t_allowed; CWG_KEEPALIVE=$t_ka; CWG_MTU=$t_mtu
  save_cwg
  info " WireGuard 配置解析成功: ${CWG_V4:-$CWG_V6} -> ${CWG_HOST}:${CWG_PORT}"
}

# ---------------------------------------------------------------- 来源 3: 自定义 OpenVPN（用户名密码）
# 解析标准 .ovpn 客户端配置: remote/proto、CA、tls-crypt / tls-auth(含 key-direction)；
# 账号密码优先级: .ovpn 内嵌 <auth-user-pass> > auth-user-pass 指向的文件 > 环境变量
#               OVPN_USERNAME / OVPN_PASSWORD > 交互输入（密码不回显）
# 配置文件路径: 环境变量 OVPN_CONF_FILE，或交互输入。需要 sing-box >= 1.14。
ovpn_block() { # ovpn_block 文件 标签 —— 输出 <标签>...</标签> 的内容
  awk -v tag="$2" '
    $0 ~ "^[[:space:]]*<"tag">[[:space:]]*$"  { on = 1; next }
    $0 ~ "^[[:space:]]*</"tag">[[:space:]]*$" { on = 0; next }
    on { print }' "$1"
}
ovpn_has_block() { grep -qE "^[[:space:]]*<$2>[[:space:]]*\$" "$1"; }
ovpn_arg() { # ovpn_arg 文件 指令 序号 —— 取指令的第 N 个参数（忽略注释行）
  awk -v k="$2" -v n="$3" '$1 == k { print $(n + 1); exit }' "$1"
}
ovpn_path() { # 相对路径按 .ovpn 所在目录解析
  local p=${2%\"}; p=${p#\"}
  if [[ $p == /* ]]; then echo "$p"; else echo "$(cd "$(dirname "$1")" && pwd)/${p}"; fi
}

import_ovpn_conf() {
  local f=$OVPN_CONF_FILE clean="$TEMP_DIR/ovpn.clean" src ref u='' p='' kd='' rp=''
  local t_srv='' t_port='' t_proto='' t_ca='' t_wt='' t_wk='' t_wd=''
  local t_auth='' t_sn='' t_snt='' t_dc=''

  if [ -z "$f" ] || [ ! -f "$f" ]; then
    reading "\n 请输入 OpenVPN 客户端配置文件（.ovpn）路径: " f
  fi
  [ -f "$f" ] || { warning " 文件不存在: ${f}"; return 1; }
  mkdir -p "$TEMP_DIR" "$WORK_DIR"
  tr -d '\r' < "$f" > "$clean"

  # remote / proto
  read -r t_srv t_port rp <<< "$(awk '$1 == "remote" { print $2, $3, $4; exit }' "$clean")"
  t_port=${t_port:-1194}
  t_proto=$(ovpn_arg "$clean" proto 1); t_proto=${t_proto:-$rp}
  case "${t_proto,,}" in tcp*) t_proto=tcp ;; *) t_proto=udp ;; esac

  # auth 摘要（默认 SHA1；tls-auth 控制通道 HMAC 也用它）
  t_auth=$(ovpn_arg "$clean" auth 1)
  # verify-x509-name <名称> [name|name-prefix|subject]
  read -r t_sn t_snt <<< "$(awk '$1 == "verify-x509-name" { print $2, $3; exit }' "$clean")"
  t_sn=${t_sn%\"}; t_sn=${t_sn#\"}
  case "$t_snt" in name-prefix|subject) ;; *) t_snt=name ;; esac
  # data-ciphers / ncp-ciphers（冒号分隔）
  t_dc=$(awk '$1 == "data-ciphers" || $1 == "ncp-ciphers" { print $2; exit }' "$clean")

  # CA 证书: 内联 <ca> 优先，其次 ca 文件
  if ovpn_has_block "$clean" ca; then
    t_ca="${WORK_DIR}/ovpn_ca.pem"; ovpn_block "$clean" ca > "$t_ca"
  else
    ref=$(ovpn_arg "$clean" ca 1)
    if [ -n "$ref" ]; then
      src=$(ovpn_path "$f" "$ref")
      [ -f "$src" ] && { t_ca="${WORK_DIR}/ovpn_ca.pem"; cp -f "$src" "$t_ca"; }
    fi
  fi
  [ -n "$t_ca" ] && chmod 600 "$t_ca"

  # tls-crypt / tls-auth 控制通道密钥（可选）
  if ovpn_has_block "$clean" tls-crypt; then
    t_wt=tls_crypt; t_wk="${WORK_DIR}/ovpn_wrap.key"; ovpn_block "$clean" tls-crypt > "$t_wk"
  elif ovpn_has_block "$clean" tls-auth; then
    t_wt=tls_auth; t_wk="${WORK_DIR}/ovpn_wrap.key"; ovpn_block "$clean" tls-auth > "$t_wk"
  else
    ref=$(ovpn_arg "$clean" tls-crypt 1)
    if [ -n "$ref" ]; then t_wt=tls_crypt
    else
      ref=$(ovpn_arg "$clean" tls-auth 1)
      if [ -n "$ref" ]; then t_wt=tls_auth; kd=$(ovpn_arg "$clean" tls-auth 2); fi
    fi
    if [ -n "$ref" ]; then
      src=$(ovpn_path "$f" "$ref")
      if [ -f "$src" ]; then t_wk="${WORK_DIR}/ovpn_wrap.key"; cp -f "$src" "$t_wk"
      else warning " 找不到控制通道密钥文件: ${src}"; t_wt=''; fi
    fi
  fi
  [ -n "$t_wk" ] && [ -f "$t_wk" ] && chmod 600 "$t_wk"
  if [ "$t_wt" = tls_auth ]; then
    [ -n "$(ovpn_arg "$clean" key-direction 1)" ] && kd=$(ovpn_arg "$clean" key-direction 1)
    case "$kd" in 0) t_wd=server ;; 1) t_wd=client ;; esac
  fi

  local missing=()
  [ -z "$t_srv" ] && missing+=("remote 服务器地址")
  [ -z "$t_ca" ] && missing+=("CA 证书（<ca> 内联块或 ca 文件）")
  if [ "${#missing[@]}" -gt 0 ]; then
    warning " OpenVPN 配置缺少字段: ${missing[*]}（文件: ${f}）"
    return 1
  fi

  # 用户名 / 密码
  u=${OVPN_USERNAME:-}; p=${OVPN_PASSWORD:-}
  if [ -z "$u" ] || [ -z "$p" ]; then
    local up_content=''
    if ovpn_has_block "$clean" auth-user-pass; then
      up_content=$(ovpn_block "$clean" auth-user-pass)
    else
      ref=$(ovpn_arg "$clean" auth-user-pass 1)
      if [ -n "$ref" ]; then
        src=$(ovpn_path "$f" "$ref")
        [ -f "$src" ] && up_content=$(tr -d '\r' < "$src")
      fi
    fi
    [ -n "$up_content" ] && {
      [ -n "$u" ] || u=$(sed -n '1p' <<< "$up_content")
      [ -n "$p" ] || p=$(sed -n '2p' <<< "$up_content")
    }
  fi
  [ -n "$u" ] || reading " 请输入 OpenVPN 用户名: " u
  if [ -z "$p" ]; then read -rsp " 请输入 OpenVPN 密码: " p; echo; fi
  if [ -z "$u" ] || [ -z "$p" ]; then warning " OpenVPN 用户名或密码不能为空"; return 1; fi

  OVPN_SERVER=$t_srv; OVPN_PORT=$t_port; OVPN_PROTO=$t_proto; OVPN_USER=$u; OVPN_PASS=$p
  OVPN_CA=$t_ca; OVPN_WRAP_TYPE=$t_wt; OVPN_WRAP_KEY=$t_wk; OVPN_WRAP_DIR=$t_wd
  OVPN_AUTH=$t_auth; OVPN_SNAME=$t_sn; OVPN_SNAME_TYPE=$t_snt; OVPN_CIPHERS=$t_dc
  save_ovpn
  info " OpenVPN 配置解析成功: ${OVPN_SERVER}:${OVPN_PORT}/${OVPN_PROTO}${OVPN_WRAP_TYPE:+ (${OVPN_WRAP_TYPE})}${OVPN_AUTH:+ auth=${OVPN_AUTH}}${OVPN_SNAME:+ verify=${OVPN_SNAME}}"
}

# ---------------------------------------------------------------- 选择来源 / 应用
# 规范化自定义规则: 含点的当作 domain:，否则当作 geosite:
normalize_rules() {
  local raw=$1 arr item out=()
  raw=$(sed 's/[，、;|[:space:]]\+/,/g' <<< "$raw")
  IFS=',' read -ra arr <<< "$raw"
  for item in "${arr[@]}"; do
    [ -z "$item" ] && continue
    [[ $item =~ ^[A-Za-z0-9:._@!-]+$ ]] || { warning " 忽略非法规则: $item" >&2; continue; }
    case "$item" in
      geoip:*)  warning " 忽略 geoip 规则（仅支持域名类）: $item" >&2 ;;
      geosite:*|domain:*|full:*|keyword:*) out+=("$item") ;;
      *.*)      out+=("domain:${item}") ;;
      *)        out+=("geosite:${item}") ;;
    esac
  done
  local IFS=','; echo "${out[*]}"
}

# ---------------------------------------------------------------- 来源 4: 赛风 Psiphon（本机 SOCKS5 代理）
# 思路: 本机运行 Psiphon tunnel core（ConsoleClient，不设上游代理，直连 Psiphon 网络），按 -config 读取
# psiphon-core.json，在 127.0.0.1:端口 提供 SOCKS5；再由 sing-box 的 socks 出站连到该端口。
# 本脚本把它做成系统服务（argox-psiphon），不用 crontab。
# 官方 psiphon-tunnel-core-x86_64 依赖 glibc（UPX 压缩后看不出来），Alpine 不能用；默认下载的是
# 用官方源码 CGO_ENABLED=0 静态编译的版本，可用 PSIPHON_URL / PSIPHON_BIN_FILE 换成自己编译的。
endpoint_psiphon() {
  jq -n -c --argjson port "$PSI_PORT" '{ type: "socks", tag: "warp", server: "127.0.0.1", server_port: $port, version: "5" }'
}

_is_elf() { [ "$(head -c4 "$1" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; }

# 获取 Psiphon tunnel core 二进制
# 优先级: 已存在的 PSI_BIN > 本地文件 PSIPHON_BIN_FILE > PSI_BIN_URL（默认自托管静态版 zip，仅 x86_64）
download_psiphon() {
  [ -x "$PSI_BIN" ] && return 0
  local url="$PSI_BIN_URL" tmp="$TEMP_DIR/psi" bin sum
  rm -rf "$tmp"; mkdir -p "$tmp/x" "$WORK_DIR"

  if [ -n "$PSIPHON_BIN_FILE" ]; then
    [ -f "$PSIPHON_BIN_FILE" ] || { warning " PSIPHON_BIN_FILE 指向的文件不存在: ${PSIPHON_BIN_FILE}"; return 1; }
    bin="$PSIPHON_BIN_FILE"
  else
    if [ -z "$PSIPHON_URL" ] && [ "$SB_ARCH" != amd64 ]; then
      warning " 默认的静态版 tunnel core 只有 x86_64，当前架构 ${SB_ARCH} 请用 PSIPHON_URL 或 PSIPHON_BIN_FILE 指定"; return 1
    fi
    hint " 下载 Psiphon tunnel core: ${url}"
    wget -qO "$tmp/pkg" "${GH_PROXY}${url}" && [ -s "$tmp/pkg" ] \
      || { rm -rf "$tmp"; warning " tunnel core 下载失败（可设置 GH_PROXY，或用 PSIPHON_URL / PSIPHON_BIN_FILE 指定）"; return 1; }
    if unzip -tq "$tmp/pkg" >/dev/null 2>&1; then
      unzip -oq "$tmp/pkg" -d "$tmp/x" || { warning " 解压 tunnel core（zip）失败"; return 1; }
    elif tar -tzf "$tmp/pkg" >/dev/null 2>&1; then
      tar -xzf "$tmp/pkg" -C "$tmp/x" || { warning " 解压 tunnel core（tar.gz）失败"; return 1; }
    else
      cp -f "$tmp/pkg" "$tmp/x/psiphon-tunnel-core"   # 直接给的是二进制
    fi
    bin=$(find "$tmp/x" -type f -name 'psiphon-tunnel-core*' | head -n1)
    [ -n "$bin" ] || bin=$(find "$tmp/x" -type f | head -n1)
  fi

  [ -n "$bin" ] && [ -f "$bin" ] || { warning " 没有找到 tunnel core 二进制"; return 1; }
  [ "$(stat -c %s "$bin" 2>/dev/null || echo 0)" -gt 1000000 ] || { warning " 文件体积异常，疑似下载不完整"; return 1; }
  _is_elf "$bin" || { warning " 获取到的文件不是 Linux 可执行文件（ELF）"; return 1; }
  # Alpine（musl）上拒绝依赖 glibc 的二进制（ELF 头里带 ld-linux 解释器路径）；UPX 加壳的文件看不出来，以实际运行为准
  if [ "$SYSTEM" = Alpine ] && head -c 4096 "$bin" | grep -aq 'ld-linux'; then
    warning " 该二进制依赖 glibc（ld-linux），Alpine 上无法运行。请换成 CGO_ENABLED=0 静态编译的版本"; return 1
  fi
  sum=$(sha256sum "$bin" | awk '{print $1}')
  if [ -n "$PSIPHON_SHA256" ] && [ "${PSIPHON_SHA256,,}" != "$sum" ]; then
    warning " SHA256 不匹配: 期望 ${PSIPHON_SHA256}，实际 ${sum}"
    warning " （如果你更新了仓库里的二进制，请用新的校验值: PSIPHON_SHA256=${sum}，或设为空跳过校验）"; return 1
  fi
  hint " tunnel core 二进制 SHA256: ${sum}"
  cp -f "$bin" "$PSI_BIN" && chmod +x "$PSI_BIN"
  rm -rf "$tmp"
  rm -f "${WORK_DIR}/warp-plus"   # 清理旧版 warp-plus
}

# 生成 tunnel core 配置（不设 UpstreamProxyURL，直连 Psiphon，不经过 WARP）
psi_conf_json() {
  jq -n --argjson port "$PSI_PORT" --arg cc "$PSI_COUNTRY" --arg dir "$PSI_DATA" \
    --arg sp "$PSI_SPONSOR" --arg url "$PSI_LIST_URL" --arg pk "$PSI_PUBKEY" '
    { EgressRegion: $cc,
      LocalSocksProxyPort: $port,
      DisableLocalHTTPProxy: true,
      PropagationChannelId: $sp,
      SponsorId: $sp,
      RemoteServerListUrl: $url,
      RemoteServerListSignaturePublicKey: $pk,
      RemoteServerListDownloadFilename: "remote_server_list",
      DataRootDirectory: $dir,
      NetworkID: "test",
      EstablishTunnelTimeoutSeconds: 60 }'
}

psi_cmdline() {
  echo "${PSI_BIN} -config ${PSI_CONF}"
}

# 写配置文件与系统服务；两者都没变化返回 1（避免无谓重启，赛风重新建立连接要 10~60 秒）
write_psiphon_daemon() {
  local unit tmp="$TEMP_DIR/psi.unit" ctmp="$TEMP_DIR/psi.json" cchg=1 uchg=1
  mkdir -p "$TEMP_DIR" "$PSI_DATA"

  psi_conf_json > "$ctmp" || return 1
  if [ -f "$PSI_CONF" ] && cmp -s "$ctmp" "$PSI_CONF"; then cchg=0; rm -f "$ctmp"
  else mv -f "$ctmp" "$PSI_CONF"; fi
  chmod 600 "$PSI_CONF"

  if [ "$SYSTEM" = Alpine ]; then
    unit="/etc/init.d/${PSI_SVC}"
    cat > "$tmp" << EOF
#!/sbin/openrc-run

name="${PSI_SVC}"
command="${PSI_BIN}"
command_args="-config ${PSI_CONF}"
command_background="yes"
pidfile="/run/\${RC_SVCNAME}.pid"
directory="${WORK_DIR}"
output_log="${WORK_DIR}/psiphon.log"
error_log="${WORK_DIR}/psiphon.log"

depend() {
    need net
}
EOF
  else
    unit="/etc/systemd/system/${PSI_SVC}.service"
    cat > "$tmp" << EOF
[Unit]
Description=ArgoX Psiphon SOCKS5 proxy (tunnel core, 127.0.0.1:${PSI_PORT}, ${PSI_COUNTRY})
After=network.target network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${WORK_DIR}
ExecStart=$(psi_cmdline)
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  fi
  if [ -f "$unit" ] && cmp -s "$tmp" "$unit"; then rm -f "$tmp"; uchg=0
  else mv -f "$tmp" "$unit"; [ "$SYSTEM" = Alpine ] && chmod +x "$unit"; fi

  [ "$cchg" = 0 ] && [ "$uchg" = 0 ] && return 1
  return 0
}

psi_unit_exists() { [ -e "/etc/systemd/system/${PSI_SVC}.service" ] || [ -e "/etc/init.d/${PSI_SVC}" ]; }

# 让赛风服务与当前设置一致: 来源为赛风且出站未关闭 -> 运行；否则停掉并禁用
psiphon_sync() {
  psi_unit_exists || [ "$WARP_SOURCE" = psiphon ] || return 0
  if [ "$WARP_MODE" != off ] && [ "$WARP_SOURCE" = psiphon ] && [ -n "$PSI_PORT" ] && [ -n "$PSI_COUNTRY" ]; then
    if write_psiphon_daemon; then svc enable "$PSI_SVC"; svc restart "$PSI_SVC"
    else svc status "$PSI_SVC" || svc enable "$PSI_SVC"; fi
  else
    psi_unit_exists && svc disable "$PSI_SVC"
  fi
}

# 选国家 + 端口 -> 下载二进制 -> 写服务并启动（连通性由 test_outbound 验证）
setup_psiphon() {
  local c n=0 port
  download_psiphon || return 1

  c=${PSIPHON_COUNTRY:-$PSI_COUNTRY}
  until [ -n "$c" ] && [[ " ${PSI_COUNTRIES[*]} " == *" ${c^^} "* ]]; do
    ((n++)); [ "$n" -gt 4 ] && { warning " 国家码输入错误次数过多"; return 1; }
    hint "\n 可选国家码: ${PSI_COUNTRIES[*]}"
    reading " 请输入国家码（默认 US）: " c
    c=${c:-US}
  done
  PSI_COUNTRY=${c^^}

  port=${PSIPHON_PORT:-${PSI_PORT:-40000}}
  n=0
  # 已有同名服务占用自己的端口属于正常情况，先停掉再检查
  psi_unit_exists && svc stop "$PSI_SVC"
  until [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] && ! is_port_in_use "$port"; do
    ((n++)); [ "$n" -gt 4 ] && { warning " 端口输入错误次数过多"; return 1; }
    [ -n "$port" ] && warning " 端口 ${port} 不合法或已被占用"
    reading " 请输入赛风本机 SOCKS5 端口（1024-65535，默认 40000）: " port
    port=${port:-40000}
  done
  PSI_PORT=$port
  PSI_STACK=''; PSI_ENDPOINT=''   # tunnel core 不需要 WARP endpoint / 地址族
  save_psi

  # 写配置与服务并启动，连通性由 test_outbound 验证（首次要下载服务器列表，较慢）
  write_psiphon_daemon
  svc enable "$PSI_SVC"; svc restart "$PSI_SVC"
  info " 赛风 tunnel core 已启动: 127.0.0.1:${PSI_PORT}（${PSI_COUNTRY}）"
}

# ---------------------------------------------------------------- 来源 5: 自有 VPS 落地（Shadowsocks，纯 TCP 链路）
# 落地机先运行 ss-exit.sh 一键部署服务端，它会输出 ss:// 链接；这里粘贴链接（或手动填参数）即可。
# 入口机 → 落地机全程 TCP，适合出站 UDP 被封、WireGuard 走不通的 NAT 小鸡；目标域名交给落地机解析，
# 出口 IP 就是你自己 VPS 的 IP。默认只走 TCP（SS_NETWORK=tcp）；本机 UDP 可用时可设 both / udp。
# 环境变量: SS_URI=ss://...  或  SS_SERVER / SS_PORT / SS_METHOD / SS_PASSWORD（可选 SS_NETWORK）
_ss_b64dec() { # base64 / base64url（容忍缺失的 = 填充）
  local s; s=$(printf '%s' "$1" | tr '_-' '/+')
  case $(( ${#s} % 4 )) in 2) s="${s}==" ;; 3) s="${s}=" ;; esac
  printf '%s' "$s" | base64 -d 2>/dev/null
}

_ss_urldecode() { # 百分号解码（先转义反斜杠，避免被 printf %b 误解释）
  local s=${1//\\/\\\\}
  s=${s//\%/\\x}
  printf '%b' "$s"
}

# 解析 ss://；成功时设置 _p_method _p_pass _p_host _p_port
# 支持 SIP002（ss://base64url(method:pass)@host:port 或 ss://method:pass@host:port，userinfo 可百分号编码）
# 与旧格式（ss://base64(method:pass@host:port)）；忽略 ?plugin= 与 #备注
_ss_parse_uri() {
  local u=${1#ss://} ui hp d
  u=${u%%#*}; u=${u%%\?*}; u=${u%/}
  _p_method=''; _p_pass=''; _p_host=''; _p_port=''
  if [[ $u == *@* ]]; then
    ui=${u%@*}; hp=${u##*@}
    d=$(_ss_urldecode "$ui")
    [[ $d == *:* ]] || d=$(_ss_b64dec "$d")
  else
    d=$(_ss_b64dec "$u")
    [[ $d == *@* ]] || return 1
    hp=${d##*@}; d=${d%@*}
  fi
  [[ $d == *:* ]] || return 1
  _p_method=${d%%:*}; _p_pass=${d#*:}
  _p_host=${hp%:*}; _p_port=${hp##*:}
  _p_host=${_p_host#\[}; _p_host=${_p_host%\]}
  [ -n "$_p_method" ] && [ -n "$_p_pass" ] && [ -n "$_p_host" ] && [[ $_p_port =~ ^[0-9]+$ ]]
}

# 输出自有 VPS（Shadowsocks）的 outbound JSON（普通出站，不是 endpoint）
endpoint_ss() {
  jq -n -c --arg s "$SS_SERVER" --argjson p "$SS_PORT" --arg m "$SS_METHOD" --arg pw "$SS_PASS" --arg n "${SS_NETWORK:-tcp}" '
    { type: "shadowsocks", tag: "warp", server: $s, server_port: $p, method: $m, password: $pw }
    + (if $n == "tcp" or $n == "udp" then { network: $n } else {} end)'
}

import_ss() {
  local uri=$SS_URI srv=$SS_SERVER port=$SS_PORT method=$SS_METHOD pass=${SS_PASSWORD:-$SS_PASS} net=${SS_NETWORK:-tcp}
  if [ -z "$uri" ] && { [ -z "$srv" ] || [ -z "$port" ] || [ -z "$method" ] || [ -z "$pass" ]; }; then
    hint "\n 在你的落地 VPS 上运行 ss-exit.sh，会输出一条 ss:// 链接。粘贴到这里；直接回车则手动输入各项参数。"
    reading " 请输入 ss:// 链接: " uri
  fi
  if [ -n "$uri" ]; then
    uri=${uri//[[:space:]]/}
    _ss_parse_uri "$uri" || { warning " ss:// 链接无法解析（应为 ss://方法:密码@地址:端口 的标准格式）"; return 1; }
    method=$_p_method; pass=$_p_pass; srv=$_p_host; port=$_p_port
  else
    [ -n "$srv" ]    || reading " 落地机地址（IP 或域名）: " srv
    [ -n "$port" ]   || reading " 端口: " port
    [ -n "$method" ] || reading " 加密方式（如 chacha20-ietf-poly1305）: " method
    [ -n "$pass" ]   || { read -rsp " 密码: " pass; echo; }
  fi
  if [ -z "$srv" ] || [ -z "$pass" ]; then warning " 落地机地址和密码不能为空"; return 1; fi
  if ! { [[ $port =~ ^[0-9]+$ ]] && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; }; then warning " 端口无效: ${port}"; return 1; fi
  if ! [[ $method =~ ^(2022-blake3-(aes-128-gcm|aes-256-gcm|chacha20-poly1305)|aes-(128|192|256)-gcm|chacha20-ietf-poly1305|xchacha20-ietf-poly1305|none)$ ]]; then
    warning " 不支持的加密方式: ${method}"; return 1
  fi
  case "$net" in tcp|udp|both) ;; *) net=tcp ;; esac
  SS_SERVER=$srv; SS_PORT=$port; SS_METHOD=$method; SS_PASS=$pass; SS_NETWORK=$net
  save_ss
  info " Shadowsocks 参数: ${SS_SERVER}:${SS_PORT}（${SS_METHOD}，${SS_NETWORK}）"
}

# 选择出站来源，写入 WARP_SOURCE；失败返回 1
choose_source() {
  local c
  hint "\n 链式出站来源（五选一，互斥，不做二跳）:\n 1. Cloudflare WARP（自动注册）\n 2. 自定义 WireGuard 配置文件（如 ProtonVPN 导出的 .conf；需要本机能出站 UDP）\n 3. 自定义 OpenVPN（.ovpn + 用户名密码，需 sing-box >= 1.14）\n 4. 赛风 Psiphon（本机 SOCKS5 代理，可按国家选出口；使用 Psiphon 官方 tunnel core）\n 5. 自有 VPS 落地（Shadowsocks，纯 TCP；先在你的 VPS 上运行 ss-exit.sh，再粘贴它输出的 ss:// 链接）"
  reading "\n 请选择 [1-5]，默认 1: " c
  case "$c" in
    2) WARP_SOURCE=wgconf ;;
    3) WARP_SOURCE=ovpn ;;
    4) WARP_SOURCE=psiphon ;;
    5) WARP_SOURCE=ss ;;
    1|'') WARP_SOURCE=warp ;;
    *) warning " 请输入 1、2、3、4 或 5"; return 1 ;;
  esac
}

# ---- 来源文件快照：导入/注册失败时恢复，避免未验证的新参数覆盖旧参数
snap_files() { echo "$WARP_FILE" "$CWG_FILE" "$OVPN_FILE" "$PSI_FILE" "$SS_FILE" "${WORK_DIR}/ovpn_ca.pem" "${WORK_DIR}/ovpn_wrap.key"; }

snapshot_src() {
  local f
  rm -rf "$TEMP_DIR/snap"; mkdir -p "$TEMP_DIR/snap"
  for f in $(snap_files); do
    [ -f "$f" ] && cp -f "$f" "$TEMP_DIR/snap/$(basename "$f")"
  done
}

restore_src() {
  local f
  for f in $(snap_files); do
    if [ -f "$TEMP_DIR/snap/$(basename "$f")" ]; then cp -f "$TEMP_DIR/snap/$(basename "$f")" "$f"
    else rm -f "$f"; fi
  done
  unset WG_PRIV WG_V4 WG_V6 WG_PEER WG_RESERVED WG_ENDPOINT "${CWG_KEYS[@]}" "${OVPN_KEYS[@]}" "${PSI_KEYS[@]}" "${SS_KEYS[@]}"
}

# 失败后回到操作前的状态（来源文件 + 配置变量）
revert_src() { restore_src; load_conf; SOURCE_DIRTY=0; psiphon_sync; }

# 测试未通过时询问是否仍然强制应用（公共节点可能偶发超时，非交互环境默认不强制）
confirm_force() { local c; reading " 测试未通过。仍然强制应用？[y/N]: " c; [[ ${c,,} = y ]]; }

# ---- 出站连通性测试
# 起一个临时 sing-box 实例: 127.0.0.1 随机端口的 HTTP/SOCKS 入站 -> 新出站，
# 经它访问 Cloudflare trace，成功即说明隧道握手/认证/解析都通。不改动正在运行的服务与 config.json。
# OpenVPN 来源测试期间会临时停掉正在运行的服务（避免同账号并发连接被服务商拒绝），测完恢复。
_test_outbound_inner() {
  local tmo t0 ep port cfg="$TEMP_DIR/test.json" log="$TEMP_DIR/test.log" pid i out='' ip loc warp dip was_up=0 ok=1 chk
  local url='https://www.cloudflare.com/cdn-cgi/trace'
  mkdir -p "$TEMP_DIR"
  source_ready || { warning " 没有可测试的出站配置"; return 1; }
  ep=$(build_endpoint) && [ -n "$ep" ] || { warning " 出站配置生成失败"; return 1; }

  port=$((20000 + RANDOM % 30000))
  while is_port_in_use "$port"; do port=$((20000 + RANDOM % 30000)); done
  jq -n -c --argjson ep "$ep" --argjson port "$port" --arg lvl "${TEST_LOG_LEVEL:-info}" '
    { log: { level: ($lvl // "info") },
      dns: { servers: [ { type: "local", tag: "local" } ] },
      inbounds: [ { type: "mixed", tag: "t-in", listen: "127.0.0.1", listen_port: $port } ],
      outbounds: ([ { type: "direct", tag: "direct" } ] + (if ($ep.type == "socks" or $ep.type == "shadowsocks") then [ $ep ] else [] end)),
      endpoints: (if ($ep.type == "socks" or $ep.type == "shadowsocks") then [] else [ $ep ] end),
      route: { default_domain_resolver: "local", final: "warp" } }' > "$cfg" || { warning " 测试配置生成失败"; return 1; }
  chmod 600 "$cfg"

  if ! chk=$("$WORK_DIR/sing-box" check -c "$cfg" 2>&1); then
    warning " 出站配置未通过 sing-box 自检:\n$(head -n 10 <<< "$chk")"
    return 1
  fi

  if [ "$WARP_SOURCE" = ovpn ] && svc status "$SVC"; then svc stop "$SVC"; was_up=1; fi
  # 赛风: 代理进程必须在跑（首次建立隧道要 10~60 秒，测试会等待）
  if [ "$WARP_SOURCE" = psiphon ] && ! svc status "$PSI_SVC"; then
    psi_unit_exists || write_psiphon_daemon; svc enable "$PSI_SVC"
  fi

  # 赛风: 先确认本地 SOCKS 端口真的在监听，20 秒内没起来就直接失败，不再空等整个超时
  if [ "$WARP_SOURCE" = psiphon ]; then
    local w=0
    while [ "$w" -lt 20 ] && ! is_port_in_use "$PSI_PORT"; do sleep 1; w=$((w + 1)); done
    if ! is_port_in_use "$PSI_PORT"; then
      warning " 赛风本地端口 127.0.0.1:${PSI_PORT} 20 秒内没有开始监听，进程没有正常启动。服务日志末尾:"
      if [ "$SYSTEM" = Alpine ]; then tail -n 15 "${WORK_DIR}/psiphon.log" 2>/dev/null
      else journalctl -u "$PSI_SVC" -n 15 --no-pager 2>/dev/null; fi
      return 1
    fi
  fi

  # OpenVPN 握手慢（公共节点如 VPN Gate 常需 20~60 秒），给更长的等待；可用 TEST_TIMEOUT=秒 覆盖
  if [ -n "$TEST_TIMEOUT" ]; then tmo=$TEST_TIMEOUT
  elif [ "$WARP_SOURCE" = ovpn ] || [ "$WARP_SOURCE" = psiphon ]; then tmo=90
  else tmo=30; fi
  info "\n 正在测试 $(source_label) 连通性（最长等待 ${tmo} 秒，握手成功会立即结束）..."
  "$WORK_DIR/sing-box" run -c "$cfg" > "$log" 2>&1 &
  pid=$!
  t0=$SECONDS
  while [ $((SECONDS - t0)) -lt "$tmo" ]; do
    sleep 2
    kill -0 "$pid" 2>/dev/null || { warning " sing-box 测试实例提前退出"; break; }
    out=$(https_proxy="http://127.0.0.1:${port}" HTTPS_PROXY="http://127.0.0.1:${port}" \
          wget -qO- --timeout=8 --tries=1 "$url" 2>/dev/null)
    grep -q '^ip=' <<< "$out" && { ok=0; break; }
    printf '.' >&2
  done
  echo >&2
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  rm -f "$cfg"
  [ "$was_up" = 1 ] && svc start "$SVC"

  if [ "$ok" = 0 ]; then
    ip=$(sed -n 's/^ip=//p' <<< "$out"); loc=$(sed -n 's/^loc=//p' <<< "$out"); warp=$(sed -n 's/^warp=//p' <<< "$out")
    dip=$(env -u https_proxy -u HTTPS_PROXY wget -qO- --timeout=6 --tries=1 "$url" 2>/dev/null | sed -n 's/^ip=//p')
    info " 测试通过: 出口 IP ${ip}（${loc:-?}）| warp=${warp:-?}"
    if [ -n "$dip" ] && [ "$dip" = "$ip" ]; then
      warning " 注意: 出口 IP 与本机直连 IP 相同（${dip}），流量可能没有真正经过该出站"
    elif [ -n "$dip" ]; then
      hint " 本机直连 IP: ${dip}（与出口不同，说明已走链式出站）"
    fi
    return 0
  fi
  cp -f "$log" "${WORK_DIR}/test.log" 2>/dev/null && chmod 600 "${WORK_DIR}/test.log"
  warning " 测试失败（等待 ${tmo} 秒内未能通过该出站访问外网）。sing-box 日志末尾（完整日志: ${WORK_DIR}/test.log）:\n$(grep -vE '^\s*$' "$log" 2>/dev/null | tail -n 15)"
  case "$WARP_SOURCE" in
    ovpn)   hint " 常见原因: 用户名/密码错误、服务器拒绝连接、协议/端口被封、CA 或 tls-auth 密钥不匹配、auth 摘要不一致（如 SHA512）。可用 TEST_LOG_LEVEL=debug 重试查看握手细节" ;;
    wgconf) hint " 常见原因: 私钥/预共享密钥不对、Endpoint 不通或 UDP 被拦、域名解析失败（可在 [Peer] 加 PersistentKeepalive = 25）" ;;
    psiphon) hint " 常见原因: 赛风基础设施不可达、该国家暂无可用节点（换个国家码重试）、二进制与系统不兼容。服务日志: $([ "$SYSTEM" = Alpine ] && echo "tail -n 30 ${WORK_DIR}/psiphon.log" || echo "journalctl -u ${PSI_SVC} -n 30 --no-pager")" ;;
    ss)     hint " 常见原因: 落地机端口没放行（TCP；云厂商安全组也要放行）、密码或加密方式与落地机不一致、落地机 ss 服务没运行（落地机上执行 ss-exit.sh status 查看）。使用 2022-blake3 加密方式时，两端时间误差必须小于 30 秒" ;;
    *)      hint " 常见原因: WARP 的 UDP 2408 被拦、账号注册异常" ;;
  esac
  return 1
}

# 生成 config.json -> 自检 -> 重启 sing-box；失败自动回滚。成功返回 0
apply_warp() {
  local bak="$TEMP_DIR/config.bak" out
  mkdir -p "$TEMP_DIR"
  cp -f "$SB_CONFIG" "$bak" 2>/dev/null

  if [ "$WARP_MODE" != off ] && ! source_ready; then
    setup_source || { warning "\n 没有可用的 $(source_label) 配置，已保持原配置 \n"; return 1; }
  fi
  if [ "$WARP_MODE" = custom ] && [ -z "$WARP_CUSTOM" ]; then
    warning "\n 自定义规则为空，请先添加规则 \n"; return 1
  fi
  # 来源刚导入/注册/切换过 -> 先实测连通，不通就不应用
  if [ "$WARP_MODE" != off ] && [ "$SOURCE_DIRTY" = 1 ]; then
    test_outbound || confirm_force || { warning "\n 连通性测试未通过，未应用新配置（原配置保持不变） \n"; return 1; }
  fi

  gen_config
  if ! out=$(test_config); then
    warning "\n sing-box 配置自检失败，已回滚:\n$(head -n 15 <<< "$out")\n"
    cp -f "$bak" "$SB_CONFIG" 2>/dev/null
    return 1
  fi
  svc restart "$SVC"
  sleep 2
  svc status "$SVC" || { warning "\n sing-box 重启失败，已回滚 \n"; cp -f "$bak" "$SB_CONFIG"; svc restart "$SVC"; return 1; }
  save_conf
  SOURCE_DIRTY=0
  psiphon_sync
  return 0
}

warp_summary() {
  local m='关闭'
  case "$WARP_MODE" in
    unlock) m='流媒体 / AI 解锁（预设规则）' ;;
    global) m='全局走链式出站（隐藏源站 IP）' ;;
    custom) m='仅自定义规则' ;;
  esac
  local s='双栈'; [ "$WARP_STACK" = 4 ] && s='仅 IPv4'; [ "$WARP_STACK" = 6 ] && s='仅 IPv6'
  local st; source_ready && st='已配置' || st='未配置'
  local extra=''
  [ "$WARP_SOURCE" = warp ] || [ -z "$WARP_SOURCE" ] && extra=" | 解析栈: ${s}"
  [ "$WARP_SOURCE" = psiphon ] && extra=" | 国家: ${PSI_COUNTRY:-?} | 本机端口: ${PSI_PORT:-?}"
  [ "$WARP_SOURCE" = ss ] && extra=" | 落地: ${SS_SERVER:-?}:${SS_PORT:-?} | 方式: ${SS_NETWORK:-tcp}"
  hint " 出站模式: ${m} | 来源: $(source_label) (${st})${extra} | 自定义规则: ${WARP_CUSTOM:-无}"
}

warp_menu() {
  is_installed || error "\n ArgoX 尚未安装 \n"
  load_conf
  local c new_mode
  while true; do
    snapshot_src; SOURCE_DIRTY=0
    echo; warp_summary
    hint "\n 1. 解锁流媒体 / AI（Netflix、Disney+、Hulu、HBO、Spotify、ChatGPT 走链式出站，其余直连）\n 2. 全局走链式出站（隐藏源站 IP，目标站看到的是出口 IP）\n 3. 仅使用自定义规则\n 4. 关闭链式出站\n 5. 编辑自定义规则（域名 / geosite）\n 6. 切换 WARP 解析栈（双栈 / 仅 IPv4 / 仅 IPv6，仅 WARP 来源）\n 7. 切换出站来源（WARP / 自定义 WireGuard / 自定义 OpenVPN / 赛风 / 自有 VPS）\n 8. 重新注册 / 重新导入当前来源的账号或配置文件\n 9. 测试当前来源的连通性\n 0. 退出"
    reading "\n 请选择: " c
    case "$c" in
      1) WARP_MODE=unlock; apply_warp && info " 已启用: 流媒体 / AI 解锁（$(source_label)）" || revert_src ;;
      2) WARP_MODE=global; apply_warp && info " 已启用: 全局出站（$(source_label)）" || revert_src ;;
      3) WARP_MODE=custom; apply_warp && info " 已启用: 自定义规则（$(source_label)）" || revert_src ;;
      4) WARP_MODE=off;    apply_warp && info " 已关闭链式出站" || revert_src ;;
      5)
        hint "\n 当前: ${WARP_CUSTOM:-无}\n 输入域名后缀或 geosite 名，逗号分隔（如 google.com,telegram）；回车保持不变，输入 - 清空"
        reading " 规则: " new_mode
        if [ "$new_mode" = '-' ]; then WARP_CUSTOM=''
        elif [ -n "$new_mode" ]; then WARP_CUSTOM=$(normalize_rules "$new_mode"); fi
        if [ "$WARP_MODE" = off ]; then save_conf; info " 已保存（当前链式出站为关闭状态，启用后生效）"
        else apply_warp && info " 规则已更新" || revert_src; fi
        ;;
      6)
        [ "$WARP_SOURCE" = warp ] || { warning " 当前来源是 $(source_label)，解析栈设置仅对 WARP 来源有效"; continue; }
        hint "\n 1. 双栈（默认）\n 2. 仅 IPv4\n 3. 仅 IPv6（部分站点用 WARP IPv6 解锁效果更好）"
        reading " 请选择: " new_mode
        case "$new_mode" in 2) WARP_STACK=4 ;; 3) WARP_STACK=6 ;; 1) WARP_STACK=d ;; *) continue ;; esac
        if [ "$WARP_MODE" = off ]; then save_conf; else apply_warp && info " 已切换" || revert_src; fi
        ;;
      7)
        choose_source || continue
        if ! source_ready; then
          setup_source || { warning " 未能配置 $(source_label)，保持原来源"; revert_src; continue; }
        fi
        SOURCE_DIRTY=1
        if [ "$WARP_MODE" = off ]; then
          save_conf; info " 来源已切换为 $(source_label)（当前出站为关闭状态，启用后生效）"
          test_outbound || warning " 注意: 该来源连通性测试未通过，启用前请先检查"
        else apply_warp && info " 来源已切换为 $(source_label)" || revert_src; fi
        ;;
      8)
        case "$WARP_SOURCE" in
          wgconf) WG_CONF_FILE='' ;;
          ovpn)   OVPN_CONF_FILE=''; OVPN_USERNAME=''; OVPN_PASSWORD='' ;;
          psiphon) PSIPHON_COUNTRY=''; PSIPHON_PORT=''; PSI_COUNTRY=''; PSI_PORT='' ;;
          ss)     SS_URI=''; SS_SERVER=''; SS_PORT=''; SS_METHOD=''; SS_PASS=''; SS_PASSWORD='' ;;
          *)      unset WG_PRIV WG_V4 WG_V6 WG_PEER WG_RESERVED WG_ENDPOINT ;;
        esac
        if setup_source; then
          if [ "$WARP_MODE" = off ]; then
            save_conf; info " $(source_label) 账号 / 配置已更新（当前出站为关闭状态）"
            test_outbound || warning " 注意: 该来源连通性测试未通过，启用前请先检查"
          elif apply_warp; then info " $(source_label) 账号 / 配置已更新并通过连通性测试"
          else revert_src; fi
        else revert_src; fi
        ;;
      9)
        if [ "$WARP_MODE" = off ]; then test_outbound
        else test_outbound && info " 当前来源可用" || warning " 当前来源不可用，可用 8 重新导入或 7 切换来源"; fi
        ;;
      0|'') break ;;
      *) warning " 请输入正确数字" ;;
    esac
  done
  [ "$WARP_SOURCE" = warp ] && hint "\n 验证方法: 客户端连上节点后访问 https://www.cloudflare.com/cdn-cgi/trace ，看到 warp=on 即走了 WARP（全局模式）\n"
}

# ---------------------------------------------------------------- 节点信息
export_list() {
  is_installed || error "\n ArgoX 尚未安装 \n"
  load_conf
  svc status "$SVC" || { warning "\n sing-box 服务未运行，请先开启（argox -s） \n"; return 1; }
  local d=$ARGO_DOMAIN host=$CDN port=${CDN_PORT:-443} name=${NODE_NAME// /%20} vless
  vless="vless://${UUID}@${host}:${port}?encryption=none&security=tls&sni=${d}&fp=chrome&type=ws&host=${d}&path=%2F${WS_PATH}#${name}-vless"
  {
    echo "Argo 域名 : ${d}"
    echo "优选地址  : ${host}:${port}"
    echo
    echo "VLESS + WS + TLS:"
    echo "$vless"
  } | tee "$WORK_DIR/list" | while IFS= read -r l; do info "$l"; done
  echo
  warp_summary
  hint "\n 回源检查: Cloudflare 控制台 → 隧道 → Public Hostname 必须是  ${d}  →  HTTP  127.0.0.1:${BASE_PORT}"
  hint " 隧道日志:  $([ "$SYSTEM" = Alpine ] && echo "tail -n 30 ${WORK_DIR}/sing-box.log" || echo "journalctl -u ${SVC} -n 30 --no-pager")\n"
}

# ---------------------------------------------------------------- 安装 / 变更 / 升级 / 卸载
install_all() {
  is_installed && error "\n 已安装 ArgoX，请使用 argox 管理 \n"
  info "\n ArgoX Lite ${VERSION}\n"
  install_deps
  mkdir -p "$WORK_DIR" "$TEMP_DIR" "$RULES_DIR"
  cleanup_legacy
  [ -s "$WARP_FILE" ] && . "$WARP_FILE"   # 沿用旧版已注册的 WARP 账号

  input_port
  input_uuid
  input_ws_path
  input_node_name
  input_cdn
  argo_setup

  info "\n 下载 sing-box ${SINGBOX_VERSION} ..."
  download_singbox

  if [ -z "$WARP_MODE" ]; then
    hint "\n 链式出站（之后可用 argox -w 修改）:\n 1. 不启用（默认）\n 2. 解锁流媒体 / AI\n 3. 全局走链式出站（隐藏源站 IP）"
    reading "\n 请选择 [1-3]: " c
    case "$c" in 2) WARP_MODE=unlock ;; 3) WARP_MODE=global ;; *) WARP_MODE=off ;; esac
  fi
  case "$WARP_MODE" in off|unlock|global|custom) ;; *) WARP_MODE=off ;; esac
  WARP_STACK=${WARP_STACK:-d}

  if [ "$WARP_MODE" != off ]; then
    case "${WARP_SOURCE,,}" in
      warp|1) WARP_SOURCE=warp ;;
      wgconf|conf|wireguard|2) WARP_SOURCE=wgconf ;;
      ovpn|openvpn|3) WARP_SOURCE=ovpn ;;
      psiphon|psi|4) WARP_SOURCE=psiphon ;;
      ss|own|shadowsocks|5) WARP_SOURCE=ss ;;
      '') until choose_source; do :; done ;;
      *) warning " 无效的 WARP_SOURCE: ${WARP_SOURCE}，使用 warp"; WARP_SOURCE=warp ;;
    esac
    if source_ready || setup_source; then
      test_outbound || confirm_force || { warning "\n 出站连通性测试未通过，已暂不启用链式出站（安装后可用 argox -w 重新配置） \n"; WARP_MODE=off; }
    else
      warning "\n 未能配置 $(source_label)，安装后可用 argox -w 再设置 \n"; WARP_MODE=off
    fi
  fi
  WARP_SOURCE=${WARP_SOURCE:-warp}

  gen_config
  local out
  if ! out=$(test_config); then
    warning "\n sing-box 配置自检失败:\n$(head -n 20 <<< "$out")\n"
    if [ "$WARP_MODE" != off ]; then
      hint " 尝试关闭链式出站后重新生成 ..."
      WARP_MODE=off; gen_config
      out=$(test_config) || error "\n 仍然失败，退出:\n$(head -n 20 <<< "$out")\n"
      hint " 已自动关闭链式出站以继续安装（WireGuard 来源可能缺少 with_wireguard / with_gvisor 标签；OpenVPN 来源需 sing-box >= 1.14 且编译了 openvpn-client）"
    else
      error "\n 退出 \n"
    fi
  fi
  save_conf
  write_daemon
  psiphon_sync
  svc enable "$SVC"
  sleep 3
  if svc status "$SVC"; then info " sing-box 运行中"
  else warning " sing-box 未运行，请检查: ${WORK_DIR}/sing-box run -c ${SB_CONFIG}"; fi
  create_shortcut
  export_list
}

change_tunnel() {
  is_installed || error "\n ArgoX 尚未安装 \n"
  load_conf
  unset ARGO_DOMAIN ARGO_AUTH ARGO_TOKEN
  argo_setup
  gen_config
  local out
  out=$(test_config) || error "\n 配置自检失败:\n$(head -n 20 <<< "$out")\n"
  save_conf
  svc restart "$SVC"
  sleep 3
  export_list
}

toggle_svc() {
  is_installed || error "\n ArgoX 尚未安装 \n"
  load_conf
  if svc status "$SVC"; then svc disable "$SVC"; psi_unit_exists && svc disable "$PSI_SVC"; warning " sing-box 已关闭"
  else psiphon_sync; svc enable "$SVC"; sleep 2; svc status "$SVC" && info " sing-box 已开启" || warning " sing-box 启动失败"; fi
}

upgrade_bins() {
  is_installed || error "\n ArgoX 尚未安装 \n"
  local lv ov c
  lv=$("$WORK_DIR/sing-box" version 2>/dev/null | awk 'NR==1{print $3}')
  ov=$(wget -qO- --timeout=8 https://api.github.com/repos/SagerNet/sing-box/releases/latest 2>/dev/null | jq -r '.tag_name // empty' | sed 's/^v//')
  [ -z "$ov" ] && error "\n 无法访问 api.github.com（可能被限流），请稍后重试；或指定版本: SINGBOX_VERSION=x.y.z argox -v \n"
  info "\n sing-box 本地 ${lv:-?} / 最新 ${ov} \n"
  if [ "$lv" != "$ov" ]; then
    reading " 升级请按 [y]，默认不升级: " c
    [[ ${c,,} = y ]] && { svc stop "$SVC"; download_singbox "$ov"; svc restart "$SVC"; info " sing-box 已升级到 ${ov}"; }
  else
    info " 已是最新版本"
  fi
}

uninstall_all() {
  is_installed || error "\n ArgoX 尚未安装 \n"
  local c; reading "\n 确认卸载 ArgoX？[y/N]: " c
  [[ ${c,,} = y ]] || { info " 已取消"; return; }
  svc disable "$SVC"
  psi_unit_exists && svc disable "$PSI_SVC"
  if [ "$SYSTEM" = Alpine ]; then rm -f "/etc/init.d/${SVC}" "/etc/init.d/${PSI_SVC}"
  else rm -f "/etc/systemd/system/${SVC}.service" "/etc/systemd/system/${PSI_SVC}.service"; systemctl daemon-reload; fi
  rm -rf "$WORK_DIR" /usr/bin/argox
  info "\n ArgoX 已彻底卸载 \n"
}

# ---------------------------------------------------------------- 菜单 / 入口
status_line() {
  local s
  svc status "$SVC" && s='运行中' || s='未运行'
  hint " sing-box（含 cloudflared 入站）: ${s}"
  warp_summary
}

menu() {
  local c
  echo; info " ArgoX Lite ${VERSION}  (sing-box + cloudflared inbound + WARP / WireGuard / OpenVPN / Psiphon / 自有 VPS)"
  if is_installed; then
    load_conf; echo; status_line
    hint "\n 1. 查看节点信息 (argox -n)\n 2. 更换 Argo 隧道 (argox -t)\n 3. 链式出站设置 WARP / WireGuard / OpenVPN / 赛风 / 自有 VPS (argox -w)\n 4. 开关 sing-box (argox -s)\n 5. 同步 sing-box 到最新版 (argox -v)\n 6. 卸载 (argox -u)\n 0. 退出"
    reading "\n 请选择: " c
    case "$c" in
      1) export_list ;; 2) change_tunnel ;; 3) warp_menu ;;
      4) toggle_svc ;; 5) upgrade_bins ;; 6) uninstall_all ;; *) exit 0 ;;
    esac
  else
    hint "\n 1. 安装 ArgoX Lite (sing-box + cloudflared 入站 + VLESS，可选 WARP / WireGuard / OpenVPN / 赛风 / 自有 VPS 链式出站)\n 0. 退出"
    reading "\n 请选择: " c
    [ "$c" = 1 ] && install_all || exit 0
  fi
}

main() {
  trap cleanup EXIT
  trap 'cleanup; echo; exit 1' INT QUIT TERM
  check_root; check_system; check_arch
  mkdir -p "$TEMP_DIR"
  case "$1" in
    -n|-N) export_list ;;
    -t|-T) change_tunnel ;;
    -w|-W) warp_menu ;;
    -s|-S) toggle_svc ;;
    -v|-V) upgrade_bins ;;
    -u|-U) uninstall_all ;;
    *)     menu ;;
  esac
}

# test_outbound 外包一层: 赛风服务若是测试时才拉起的，在「出站关闭」或「测试失败」时停掉并禁用，
# 避免它在后台空转（应用配置时 psiphon_sync 会按需重新启用）
test_outbound() {
  local was=0 rc
  svc status "$PSI_SVC" && was=1
  _test_outbound_inner; rc=$?
  if [ "$WARP_SOURCE" = psiphon ] && [ "$was" = 0 ] && { [ "$WARP_MODE" = off ] || [ "$rc" != 0 ]; }; then
    psi_unit_exists && svc disable "$PSI_SVC"
  fi
  return "$rc"
}

[[ "${BASH_SOURCE[0]}" == "$0" ]] && main "$@"
