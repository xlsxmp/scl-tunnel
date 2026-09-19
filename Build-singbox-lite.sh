#!/bin/sh
# =====================================================
# sing-box 精简版二进制构建脚本 (Alpine Linux / 1c1g 优化版)
# 仅编译，不做任何部署/配置/服务相关操作，不改名、不压缩。
#
# 基于 sing-box 源码，只启用 with_cloudflared 一个可选 tag，
# 其余可选功能（quic/grpc/dhcp/wireguard/utls/acme/gvisor/
# embedded_tor/tailscale/clash_api/v2ray_api 等）一律不编译进去。
#
# 关键设计:
#   1. 编译前自动检测内存，不够则建临时 swap，编译完自动删除
#   2. 编译前检测磁盘空间是否充足
#   3. 编译限制并行度 (-p=1 / GOMAXPROCS=1)，降低峰值内存
#   4. TMPDIR 指向非 tmpfs 目录，避免小容量 /tmp 导致编译中途报盘满
#   5. -trimpath -ldflags "-s -w"：去符号表/调试信息/绝对路径，减小体积
#   6. 全部关键输出带颜色：成功=绿色 错误=红色 警告=黄色
#
# 用法：
#   bash build-singbox-minimal.sh
#   指定版本： SB_VERSION=v1.14.1 bash build-singbox-minimal.sh
#   指定输出位置： OUT_PATH=/usr/local/bin/sing-box bash build-singbox-minimal.sh
#
# 产物默认输出到当前目录下的 ./sing-box
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

APP_NAME="sing-box"
SB_VERSION="${SB_VERSION:-v1.14.1}"
OUT_PATH="${OUT_PATH:-$(pwd)/${APP_NAME}}"

BUILD_DIR=""
SWAP_FILE=""
SWAP_CREATED=0

log_info "================================="
log_info "${APP_NAME} 精简版二进制构建 (${SB_VERSION})"
log_info "================================="

if [ "$(id -u)" != "0" ]; then
    log_err "请使用root运行（需要 apk 安装依赖 / 可能需要建 swap）"
    exit 1
fi

cleanup() {
    if [ -n "$BUILD_DIR" ] && [ -d "$BUILD_DIR" ]; then
        rm -rf "$BUILD_DIR"
    fi
    if [ "$SWAP_CREATED" -eq 1 ] && [ -n "$SWAP_FILE" ]; then
        swapoff "$SWAP_FILE" 2>/dev/null || true
        rm -f "$SWAP_FILE"
    fi
}
trap cleanup EXIT INT TERM

# ---- 选一个非 tmpfs 的编译工作目录 ----
is_tmpfs() {
    local fstype
    fstype=$(df -T "$1" 2>/dev/null | awk 'NR==2{print $2}')
    [ "$fstype" = "tmpfs" ]
}

for candidate in /root/.${APP_NAME}-build /var/tmp/${APP_NAME}-build; do
    mkdir -p "$candidate" 2>/dev/null || continue
    if ! is_tmpfs "$candidate"; then
        BUILD_DIR="$candidate"
        break
    else
        rmdir "$candidate" 2>/dev/null || true
    fi
done
if [ -z "$BUILD_DIR" ]; then
    log_warn "警告: 未找到非 tmpfs 候选目录，回退使用 /tmp（低内存环境下有 OOM 风险）"
    BUILD_DIR="/tmp/${APP_NAME}-build"
    mkdir -p "$BUILD_DIR"
fi
log_ok "编译工作目录: ${BUILD_DIR}"

# ---- 磁盘空间检测：编译期间源码+依赖模块+编译缓存加起来可能要几个GB ----
AVAIL_KB=$(df -Pk "$BUILD_DIR" | awk 'NR==2{print $4}')
NEED_DISK_KB=$((3 * 1024 * 1024))   # 建议至少预留 3GB 可用空间
if [ -n "$AVAIL_KB" ] && [ "$AVAIL_KB" -lt "$NEED_DISK_KB" ]; then
    log_warn "警告: ${BUILD_DIR} 所在分区可用空间仅 $((AVAIL_KB / 1024))MB，编译过程中拉取依赖+缓存可能超过这个量"
    log_warn "建议: df -h 检查磁盘占用，清理无用文件后再继续，否则大概率会在编译中途报 'no space left on device'"
    read -p "是否仍然继续？(y/N): " DISK_CONFIRM
    if [ "$DISK_CONFIRM" != "y" ] && [ "$DISK_CONFIRM" != "Y" ]; then
        log_info "已取消"
        exit 1
    fi
else
    log_ok "磁盘空间检查通过 (可用 $((AVAIL_KB / 1024))MB)"
fi

# ---- 内存检测，不够则建临时 swap ----
MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo)
SWAP_KB=$(awk '/SwapTotal/{print $2}' /proc/meminfo)
TOTAL_KB=$((MEM_KB + SWAP_KB))
NEED_KB=$((1800 * 1024))   # 期望物理内存+swap 合计达到 ~1.8G 再编译，更稳

if [ "$TOTAL_KB" -lt "$NEED_KB" ]; then
    SWAP_FILE="${BUILD_DIR%/*}/.${APP_NAME}-build-swap"
    log_warn "检测到内存偏低 (物理+swap 共 $((TOTAL_KB / 1024))MB)，临时创建 1536MB swap 用于编译"
    if dd if=/dev/zero of="$SWAP_FILE" bs=1M count=1536 >/dev/null 2>&1 \
        && chmod 600 "$SWAP_FILE" \
        && mkswap "$SWAP_FILE" >/dev/null 2>&1 \
        && swapon "$SWAP_FILE" >/dev/null 2>&1; then
        SWAP_CREATED=1
        log_ok "临时 swap 创建成功: ${SWAP_FILE}"
    else
        log_warn "临时 swap 创建失败，将直接尝试编译（低内存下有 OOM 风险）"
        SWAP_FILE=""
    fi
else
    log_ok "内存充足 (物理+swap 共 $((TOTAL_KB / 1024))MB)，无需额外 swap"
fi

# ---- 安装编译依赖 ----
log_info "安装编译依赖: go git ..."
apk update
apk add --no-cache go git

log_info "拉取 sing-box 源码 (${SB_VERSION})..."
git clone --depth 1 --branch "$SB_VERSION" \
    https://github.com/SagerNet/sing-box.git \
    "${BUILD_DIR}/src"

cd "${BUILD_DIR}/src"

# ---- 编译：只启用 with_cloudflared，限制并行度以降低内存峰值 ----
export CGO_ENABLED=0
export GOPATH="${BUILD_DIR}/gopath"
export GOCACHE="${BUILD_DIR}/gocache"
export TMPDIR="${BUILD_DIR}/tmp"
mkdir -p "$TMPDIR"
export GOFLAGS="-p=1"
export GOMAXPROCS=1
export GOGC=50

log_info "开始编译 (单核串行编译，1c1g 下预计耗时较长，请耐心等待)..."
VERSION_STR="$(go run ./cmd/internal/read_tag 2>/dev/null || echo "${SB_VERSION#v}")"

if ! go build -trimpath \
    -tags "with_cloudflared" \
    -ldflags "-s -w -X 'github.com/sagernet/sing-box/constant.Version=${VERSION_STR}'" \
    -o "${BUILD_DIR}/${APP_NAME}" \
    ./cmd/sing-box; then
    log_err "编译失败，请查看上方报错信息（常见原因：内存不足 / go 版本过低 / 网络中断导致依赖下载失败）"
    exit 1
fi

log_ok "编译成功: $(du -h "${BUILD_DIR}/${APP_NAME}" | cut -f1)"

if ! "${BUILD_DIR}/${APP_NAME}" version >/dev/null 2>&1; then
    log_err "编译出的二进制无法运行，可能与当前系统不兼容"
    exit 1
fi

mkdir -p "$(dirname "$OUT_PATH")"
install -m 755 "${BUILD_DIR}/${APP_NAME}" "$OUT_PATH"

# 编译缓存用完即删，释放磁盘空间
go clean -cache >/dev/null 2>&1 || true

echo
log_ok "=============================="
log_ok "构建完成"
log_info "输出文件: ${OUT_PATH}"
log_info "文件大小: $(du -h "$OUT_PATH" | cut -f1)"
log_info "版本信息: $("$OUT_PATH" version 2>/dev/null | head -n1)"
log_ok "=============================="
