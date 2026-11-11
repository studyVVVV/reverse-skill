#!/usr/bin/env bash
# android-lab-up.sh — 一条命令拉起 Android 实验环境：启动设备 → 等开机 → 拿 root → 起 frida-server
#
# 支持 AVD（userdebug，adb root 直接可用）与 Genymotion（动态 rooting，需每次启动后补 root）。
#
# 用法:
#   bash android-lab-up.sh                      # 自动挑选：已在线模拟器 > 启动第一个 AVD
#   bash android-lab-up.sh --target avd --avd Pixel_10_Pro
#   bash android-lab-up.sh --target genymotion --genymotion qn
#   bash android-lab-up.sh --device emulator-5554 --no-start   # 只做 root + frida
#
# 选项:
#   --target auto|avd|genymotion   启动哪类设备（默认 auto）
#   --avd <name>                   AVD 名称（默认 emulator -list-avds 第一个）
#   --genymotion <name>            Genymotion 设备名（默认 gmtool admin list 第一个）
#   --device <serial>              直接指定已在线设备，跳过启动
#   --no-start                     不启动设备，只做 root + frida
#   --no-frida                     只做启动 + root
#   --coldboot                     Genymotion 冷启动（默认 resume）
#   --timeout <sec>                等待开机完成的秒数（默认 240）
#   --port <port>                  frida-server 端口（默认 27042）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="auto"
AVD_NAME=""
GY_NAME=""
SERIAL=""
DO_START=true
DO_FRIDA=true
COLD=""
WAIT_TIMEOUT=240
PORT=27042

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --avd) AVD_NAME="$2"; shift 2 ;;
        --genymotion) GY_NAME="$2"; shift 2 ;;
        --device) SERIAL="$2"; shift 2 ;;
        --no-start) DO_START=false; shift ;;
        --no-frida) DO_FRIDA=false; shift ;;
        --coldboot) COLD="--coldboot"; shift ;;
        --timeout) WAIT_TIMEOUT="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "未知选项: $1" >&2; exit 1 ;;
    esac
done

log()  { echo -e "\033[36m[lab]\033[0m $*"; }
ok()   { echo -e "\033[32m[ok]\033[0m $*"; }
warn() { echo -e "\033[33m[warn]\033[0m $*"; }
die()  { echo -e "\033[31m[err]\033[0m $*" >&2; exit 1; }

command -v adb >/dev/null 2>&1 || die "找不到 adb"

EMULATOR="${ANDROID_HOME:-$HOME/Android/Sdk}/emulator/emulator"
GMTOOL=""
for p in "$HOME/applications/genymotion/genymotion/gmtool" /opt/genymobile/genymotion/gmtool; do
    [[ -x "$p" ]] && { GMTOOL="$p"; break; }
done

online_devices() {
    adb devices | awk 'NR>1 && $2=="device"{print $1}'
}

pick_online_emulator() {
    local d
    for d in $(online_devices); do
        case "$d" in emulator-*) echo "$d"; return 0 ;; esac
    done
    for d in $(online_devices); do
        case "$d" in 127.0.0.1:*) echo "$d"; return 0 ;; esac
    done
    return 1
}

avd_serial() {
    local name="$1" s
    for s in $(online_devices); do
        [[ "$s" == emulator-* ]] || continue
        if [[ "$(adb -s "$s" emu avd name 2>/dev/null | head -n1 | tr -d '\r')" == "$name" ]]; then
            echo "$s"; return 0
        fi
    done
    return 1
}

genymotion_serial() {
    local name="$1"
    [[ -n "$GMTOOL" ]] || return 1
    "$GMTOOL" admin list 2>/dev/null | awk -F'|' -v n="$name" 'NF>=4 { for(i=1;i<=4;i++) gsub(/^ +| +$/,"",$i); if ($4==n) print $2 }' | head -n1
}

first_avd() {
    [[ -x "$EMULATOR" ]] || return 1
    "$EMULATOR" -list-avds 2>/dev/null | head -n1
}

first_genymotion() {
    [[ -n "$GMTOOL" ]] || return 1
    "$GMTOOL" admin list 2>/dev/null | awk -F'|' 'NF>=4 { gsub(/^ +| +$/,"",$4); print $4 }' | head -n1
}

wait_boot() {
    local serial="$1" i
    for i in $(seq 1 "$WAIT_TIMEOUT"); do
        if [[ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == "1" ]]; then
            return 0
        fi
        sleep 1
    done
    return 1
}

wait_avd_online() {
    local name="$1" i s
    for i in $(seq 1 "$WAIT_TIMEOUT"); do
        if s="$(avd_serial "$name")" && [[ -n "$s" ]]; then
            echo "$s"; return 0
        fi
        sleep 1
    done
    return 1
}

wait_genymotion_online() {
    local name="$1" i s
    for i in $(seq 1 "$WAIT_TIMEOUT"); do
        if s="$(genymotion_serial "$name")" && [[ -n "$s" ]] && adb -s "$s" get-state >/dev/null 2>&1; then
            echo "$s"; return 0
        fi
        sleep 1
    done
    return 1
}

wait_device_online() {
    local i
    for i in $(seq 1 "$WAIT_TIMEOUT"); do
        pick_online_emulator >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

start_avd() {
    local name="$1"
    [[ -x "$EMULATOR" ]] || die "找不到 emulator: $EMULATOR"
    log "启动 AVD: $name"
    setsid "$EMULATOR" -avd "$name" -no-snapshot-load -no-boot-anim -gpu auto \
        >"/tmp/avd-${name}.log" 2>&1 < /dev/null &
    disown || true
}

start_genymotion() {
    local name="$1"
    [[ -n "$GMTOOL" ]] || die "找不到 gmtool（Genymotion 未安装？）"
    log "启动 Genymotion: $name $COLD"
    # 已在运行则先停，保证启动参数生效
    "$GMTOOL" admin stop "$name" >/dev/null 2>&1 || true
    sleep 2
    # shellcheck disable=SC2086
    "$GMTOOL" admin start "$name" $COLD >/dev/null 2>&1 || die "Genymotion 启动失败: $name"
}

# ── 1. 选择/启动设备 ────────────────────────────────────────────────────────────

if [[ -n "$SERIAL" ]]; then
    log "使用指定设备: $SERIAL"
elif [[ "$DO_START" == "false" ]]; then
    SERIAL="$(pick_online_emulator)" || die "没有在线模拟器设备"
    log "复用在线设备: $SERIAL"
else
    case "$TARGET" in
        avd)
            AVD_NAME="${AVD_NAME:-$(first_avd)}"
            [[ -n "$AVD_NAME" ]] || die "没有可用 AVD"
            if SERIAL="$(avd_serial "$AVD_NAME")" && [[ -n "$SERIAL" ]]; then
                log "AVD 已在运行: $AVD_NAME ($SERIAL)"
            else
                start_avd "$AVD_NAME"
                SERIAL="$(wait_avd_online "$AVD_NAME")" || die "AVD 启动超时（日志: /tmp/avd-${AVD_NAME}.log）"
                log "设备已上线: $SERIAL"
            fi
            ;;
        genymotion)
            GY_NAME="${GY_NAME:-$(first_genymotion)}"
            [[ -n "$GY_NAME" ]] || die "没有可用 Genymotion 设备"
            if SERIAL="$(genymotion_serial "$GY_NAME")" && [[ -n "$SERIAL" ]] && adb -s "$SERIAL" get-state >/dev/null 2>&1; then
                log "Genymotion 已在运行: $GY_NAME ($SERIAL)"
            else
                start_genymotion "$GY_NAME"
                SERIAL="$(wait_genymotion_online "$GY_NAME")" || die "Genymotion 启动超时"
                log "设备已上线: $SERIAL"
            fi
            ;;
        auto)
            if SERIAL="$(pick_online_emulator)" && [[ -n "$SERIAL" ]]; then
                log "已有在线设备: $SERIAL（如需重启请加 --target/--no-start 组合）"
            elif AVD_NAME="$(first_avd)" && [[ -n "$AVD_NAME" ]]; then
                start_avd "$AVD_NAME"
                SERIAL="$(wait_avd_online "$AVD_NAME")" || die "AVD 启动超时（日志: /tmp/avd-${AVD_NAME}.log）"
                log "设备已上线: $SERIAL"
            elif [[ -n "$GMTOOL" ]]; then
                GY_NAME="$(first_genymotion)"
                start_genymotion "$GY_NAME"
                SERIAL="$(wait_genymotion_online "$GY_NAME")" || die "Genymotion 启动超时"
                log "设备已上线: $SERIAL"
            else
                die "既没有可用 AVD，也没有 Genymotion"
            fi
            ;;
        *) die "未知 --target: $TARGET" ;;
    esac
fi

log "等待开机完成 ..."
wait_boot "$SERIAL" || die "开机超时: $SERIAL"
ok "已开机: $SERIAL"

# ── 2. root ────────────────────────────────────────────────────────────────────

log "确保 root ..."
bash "$SCRIPT_DIR/android-enable-root.sh" --serial "$SERIAL" --level 3 || warn "root 启用失败（继续尝试 frida）"

# ── 3. frida-server ────────────────────────────────────────────────────────────

if [[ "$DO_FRIDA" == "true" ]]; then
    log "启动 frida-server ..."
    bash "$SCRIPT_DIR/frida-server-android.sh" --device "$SERIAL" --port "$PORT"
    if timeout 20 frida-ps -U >/dev/null 2>&1; then
        ok "frida 就绪: frida-ps -U"
    else
        warn "frida-ps -U 校验失败，请检查设备是否在线"
    fi
fi

ROOT_STATE="$("${ADB:-adb}" -s "$SERIAL" shell 'id -u' 2>/dev/null | tr -d '\r')"
cat <<EOF

环境就绪：
  device : $SERIAL
  root   : ${ROOT_STATE:-unknown}
  frida  : $(command -v frida >/dev/null 2>&1 && frida --version 2>/dev/null || echo "未安装")

常用：
  frida-ps -U
  frida -U -f <package> -q -e "console.log(Process.id)"
  adb -s $SERIAL shell su -c '<cmd>'
EOF
