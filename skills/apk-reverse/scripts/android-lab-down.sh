#!/usr/bin/env bash
# android-lab-down.sh — 关闭 AVD / Genymotion 模拟器（与 android-lab-up.sh 对称）
#
# 用法:
#   bash android-lab-down.sh                    # 关闭所有在线模拟器（emulator-* / 127.0.0.1:*）
#   bash android-lab-down.sh --device emulator-5554
#   bash android-lab-down.sh --avd Pixel_10_Pro
#   bash android-lab-down.sh --genymotion qn
#   bash android-lab-down.sh --dry-run          # 只打印将执行的动作
#
# 选项:
#   --device <serial>     指定 adb 序列号
#   --avd <name>          按 AVD 名查找并关闭
#   --genymotion <name>   按 Genymotion 设备名关闭（走 gmtool admin stop）
#   --dry-run             只显示计划
#   --force               等待超时后强杀 emulator 进程（pkill）
#   --timeout <sec>       等待设备消失的秒数（默认 30）

set -euo pipefail

DEVICE=""
AVD_NAME=""
GY_NAME=""
DRY=false
FORCE=false
TIMEOUT=30

while [[ $# -gt 0 ]]; do
    case "$1" in
        --device) DEVICE="$2"; shift 2 ;;
        --avd) AVD_NAME="$2"; shift 2 ;;
        --genymotion) GY_NAME="$2"; shift 2 ;;
        --dry-run) DRY=true; shift ;;
        --force) FORCE=true; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "未知选项: $1" >&2; exit 1 ;;
    esac
done

log() { echo -e "\033[36m[down]\033[0m $*"; }
ok()  { echo -e "\033[32m[ok]\033[0m $*"; }
warn(){ echo -e "\033[33m[warn]\033[0m $*"; }

command -v adb >/dev/null 2>&1 || { echo "ERR: 找不到 adb" >&2; exit 1; }

GMTOOL=""
for p in "$HOME/applications/genymotion/genymotion/gmtool" /opt/genymobile/genymotion/gmtool; do
    [[ -x "$p" ]] && { GMTOOL="$p"; break; }
done

onlines() { adb devices | awk 'NR>1 && $2=="device"{print $1}'; }

avd_serial() {
    local name="$1" s
    for s in $(onlines); do
        [[ "$s" == emulator-* ]] || continue
        if [[ "$(adb -s "$s" emu avd name 2>/dev/null | head -n1 | tr -d '\r')" == "$name" ]]; then
            echo "$s"; return 0
        fi
    done
    return 1
}

genymotion_by_name() {
    [[ -n "$GMTOOL" ]] || return 1
    "$GMTOOL" admin list 2>/dev/null | awk -F'|' -v n="$GY_NAME" 'NF>=4 { for(i=1;i<=4;i++) gsub(/^ +| +$/,"",$i); if ($4==n) print $2 }'
}

# 收集目标序列号
TARGETS=()
if [[ -n "$DEVICE" ]]; then
    TARGETS+=("$DEVICE")
elif [[ -n "$AVD_NAME" ]]; then
    s="$(avd_serial "$AVD_NAME" || true)"
    [[ -n "$s" ]] || { warn "AVD 未在运行: $AVD_NAME"; exit 0; }
    TARGETS+=("$s")
elif [[ -n "$GY_NAME" ]]; then
    :
else
    while IFS= read -r s; do TARGETS+=("$s"); done < <(onlines)
fi

stop_emulator() {
    local serial="$1"
    local name=""
    name="$(adb -s "$serial" emu avd name 2>/dev/null | head -n1 | tr -d '\r' || true)"
    log "关闭 emulator: $serial${name:+ ($name)}"
    if [[ "$DRY" == "true" ]]; then
        echo "  would run: adb -s $serial emu kill${name:+; pkill -f 'emulator -avd $name' (fallback)}"
        return 0
    fi
    adb -s "$serial" emu kill >/dev/null 2>&1 || true
    for _ in $(seq 1 "$TIMEOUT"); do
        adb -s "$serial" get-state >/dev/null 2>&1 || { ok "已关闭: $serial"; return 0; }
        sleep 1
    done
    if [[ "$FORCE" == "true" && -n "$name" ]]; then
        warn "超时，强制结束: emulator -avd $name"
        pkill -f "emulator.*-avd $name" >/dev/null 2>&1 || true
        sleep 1
        ok "已强制关闭: $serial"
    else
        warn "超时未关闭: $serial（可加 --force）"
        return 1
    fi
}

stop_genymotion() {
    local name="$1"
    [[ -n "$GMTOOL" ]] || { warn "找不到 gmtool，无法关闭 Genymotion: $name"; return 1; }
    log "关闭 Genymotion: $name"
    if [[ "$DRY" == "true" ]]; then
        echo "  would run: $GMTOOL admin stop \"$name\""
        return 0
    fi
    "$GMTOOL" admin stop "$name" >/dev/null 2>&1 || { warn "gmtool stop 失败: $name"; return 1; }
    ok "已关闭: $name"
}

rc=0
if [[ -n "$GY_NAME" ]]; then
    stop_genymotion "$GY_NAME" || rc=1
else
    if [[ ${#TARGETS[@]} -eq 0 ]]; then
        warn "没有在线模拟器"; exit 0
    fi
    for s in "${TARGETS[@]}"; do
        case "$s" in
            emulator-*) stop_emulator "$s" || rc=1 ;;
            127.0.0.1:*|192.168.*|*:5555)
                name="$("$GMTOOL" admin list 2>/dev/null | awk -F'|' -v ser="$s" 'NF>=4 { for(i=1;i<=4;i++) gsub(/^ +| +$/,"",$i); if ($2==ser) print $4 }' | head -n1)"
                if [[ -n "$name" ]]; then
                    stop_genymotion "$name" || rc=1
                else
                    warn "无法识别设备类型: $s（可尝试 'adb -s $s emu kill'）"
                    rc=1
                fi
                ;;
            *) warn "跳过未知设备: $s" ;;
        esac
    done
fi

exit "$rc"
