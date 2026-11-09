#!/usr/bin/env bash
# frida-server-android.sh — 在已 root 的 Android 设备/模拟器上部署并启动 frida-server
#
# 适用：
#   - AVD（Google APIs / default 镜像，userdebug，adb root 可用）
#   - 已 root 的真机
#   - 不适用：Play Store 镜像、未 root 设备 → 用 gadget-inject.sh
#
# 用法:
#   bash frida-server-android.sh [选项]
#
# 选项:
#   --device <serial>   adb 设备序列号（默认当前唯一设备）
#   --version <ver>     frida-server 版本（默认 17.26.2）
#   --port <port>       监听端口（默认 27042）
#   --lib-dir <dir>     frida-server 二进制所在目录（默认 ~/tools/frida）
#   --stop              停止设备上的 frida-server 后退出
#
# 依赖: adb；frida-tools（可选，用于最终校验）
# 二进制命名: <lib-dir>/frida-server-<version>-android-<abi>

set -euo pipefail

DEVICE=""
VERSION="17.26.2"
PORT="27042"
LIB_DIR="${FRIDA_SERVER_DIR:-$HOME/tools/frida}"
DO_STOP=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --lib-dir) LIB_DIR="$2"; shift 2 ;;
        --stop) DO_STOP=true; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "未知选项: $1" >&2; exit 1 ;;
    esac
done

command -v adb >/dev/null 2>&1 || { echo "ERR: 找不到 adb" >&2; exit 1; }

ADB=(adb)
[[ -n "$DEVICE" ]] && ADB=(adb -s "$DEVICE")
[[ -z "$DEVICE" ]] && DEVICE="$("${ADB[@]}" get-serialno)"

"${ADB[@]}" get-state >/dev/null 2>&1 || { echo "ERR: 设备不可用: $DEVICE" >&2; exit 1; }

stop_server() {
    "${ADB[@]}" shell 'pkill -f /data/local/tmp/frida-server' >/dev/null 2>&1 || true
}

if [[ "$DO_STOP" == "true" ]]; then
    stop_server
    echo "已停止 frida-server ($DEVICE)"
    exit 0
fi

ABI="$("${ADB[@]}" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
ABI="${ABI:-x86_64}"
SERVER="$LIB_DIR/frida-server-${VERSION}-android-${ABI}"

if [[ ! -f "$SERVER" ]]; then
    cat >&2 <<EOF
ERR: 找不到 $SERVER

下载（本网络建议用 GitHub 代理）：
  curl -L -o frida-server.xz \\
    'https://gh-proxy.com/https://github.com/frida/frida/releases/download/${VERSION}/frida-server-${VERSION}-android-${ABI}.xz'
  unxz frida-server.xz
  mv frida-server "$SERVER"
EOF
    exit 1
fi

if [[ "$("${ADB[@]}" shell id -u 2>/dev/null | tr -d '\r')" != "0" ]]; then
    echo "WARN: 当前 adb shell 不是 root；frida-server 需要 root（先执行 'adb root'）" >&2
fi

echo "INFO: 设备 $DEVICE (ABI=$ABI)"
echo "INFO: 推送 $SERVER ..."
"${ADB[@]}" push "$SERVER" /data/local/tmp/frida-server >/dev/null
"${ADB[@]}" shell chmod 755 /data/local/tmp/frida-server

stop_server
sleep 1

echo "INFO: 启动 frida-server (0.0.0.0:${PORT}) ..."
"${ADB[@]}" shell "setsid /data/local/tmp/frida-server -l 0.0.0.0:${PORT} >/dev/null 2>&1 &" || true

for _ in $(seq 1 20); do
    if "${ADB[@]}" shell "pidof frida-server" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

if ! "${ADB[@]}" shell "pidof frida-server" >/dev/null 2>&1; then
    echo "ERR: frida-server 未启动（查看: adb shell /data/local/tmp/frida-server）" >&2
    exit 1
fi

echo "OK: frida-server 运行中 (pid=$("${ADB[@]}" shell pidof frida-server | tr -d '\r'))"

if command -v frida-ps >/dev/null 2>&1; then
    if "${ADB[@]}" shell "true" >/dev/null 2>&1; then
        echo "INFO: 校验 frida 连接 ..."
        frida-ps -U >/dev/null 2>&1 && echo "OK: frida-ps -U 可用" || echo "WARN: frida-ps -U 校验失败"
    fi
fi

cat <<EOF

后续：
  frida-ps -U
  frida -U -f <package> -q -e "console.log(Process.id)"
  # Gadget 模式（非 root 设备）：bash $(dirname "$0")/gadget-inject.sh app.apk --install
EOF
