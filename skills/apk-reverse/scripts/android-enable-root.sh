#!/usr/bin/env bash
# android-enable-root.sh — 为已连接设备启用 root（支持 Genymotion 动态 rooting）
#
# 原理：
#   Genymotion 镜像带 ro.genyd.caps.dynamicrooting=on 与 setup-root.sh，
#   persist.sys.root_access 取值 0=禁用 / 1=仅应用 / 2=仅 ADB / 3=全部。
#   AVD（userdebug）本身已 root，本脚本只做校验。
#
# 用法:
#   bash android-enable-root.sh [选项]
#
# 选项:
#   --serial <serial>   指定设备（默认所有在线设备）
#   --all               对全部在线设备执行（与默认行为一致）
#   --level <0|1|2|3>   root 级别（默认 3=应用+ADB 全部）
#   --check             只检查，不修改
#   --timeout <sec>     等待 root 生效的秒数（默认 15）
#
# 注意：
#   - Genymotion 的 quickboot/hibernation 恢复可能把 root 状态还原；
#     每次启动设备后重新执行本脚本即可（或使用 gmtool admin start --coldboot）。
#   - GUI 里的 Root access 开关需要有效 license；本脚本走的是镜像自带的动态 rooting 通道。

set -euo pipefail

SERIALS=()
LEVEL=3
CHECK_ONLY=false
TIMEOUT=15

while [[ $# -gt 0 ]]; do
    case "$1" in
        --serial) SERIALS+=("$2"); shift 2 ;;
        --all) shift ;;
        --level) LEVEL="$2"; shift 2 ;;
        --check) CHECK_ONLY=true; shift ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
        *) echo "未知选项: $1" >&2; exit 1 ;;
    esac
done

command -v adb >/dev/null 2>&1 || { echo "ERR: 找不到 adb" >&2; exit 1; }

case "$LEVEL" in 0|1|2|3) ;; *) echo "ERR: --level 只能是 0/1/2/3" >&2; exit 1 ;; esac

if [[ ${#SERIALS[@]} -eq 0 ]]; then
    while IFS= read -r line; do
        [[ "$line" == *$'\tdevice'* ]] || continue
        SERIALS+=("${line%%$'\t'*}")
    done < <(adb devices | tail -n +2)
fi

[[ ${#SERIALS[@]} -gt 0 ]] || { echo "ERR: 没有在线设备"; exit 1; }

is_root() { [[ "$("$@" shell id -u 2>/dev/null | tr -d '\r')" == "0" ]]; }
has_su()  { "$@" shell 'command -v su' >/dev/null 2>&1; }

overall=0
for serial in "${SERIALS[@]}"; do
    A=(adb -s "$serial")
    echo "== $serial"

    if ! "${A[@]}" get-state >/dev/null 2>&1; then
        echo "   SKIP: 设备不可用"; overall=1; continue
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        uid="$("${A[@]}" shell id -u 2>/dev/null | tr -d '\r')"
        prop="$("${A[@]}" shell getprop persist.sys.root_access 2>/dev/null | tr -d '\r')"
        echo "   uid=$uid persist.sys.root_access=${prop:-<未定义>}"
        [[ "$uid" == "0" ]] || overall=1
        continue
    fi

    if is_root "${A[@]}"; then
        echo "   已是 root（uid=0），跳过"
        continue
    fi

    echo "   设置 persist.sys.root_access=$LEVEL ..."
    "${A[@]}" shell "setprop persist.sys.root_access $LEVEL" 2>/dev/null || true

    # 3=全部：同时尝试让 adbd 以 root 重启
    if [[ "$LEVEL" == "3" || "$LEVEL" == "2" ]]; then
        "${A[@]}" root >/dev/null 2>&1 || true
    fi

    for _ in $(seq 1 "$TIMEOUT"); do
        is_root "${A[@]}" && break
        sleep 1
    done

    if is_root "${A[@]}"; then
        echo "   OK: adb shell 已是 root"
    elif has_su "${A[@]}"; then
        if [[ "$("${A[@]}" shell 'su -c id -u' 2>/dev/null | tr -d '\r')" == "0" ]]; then
            echo "   OK: adb shell 非 root，但 su 可用（root 生效）"
        else
            echo "   WARN: su 存在但无法取得 uid=0"; overall=1
        fi
    else
        echo "   ERR: root 未生效（该镜像可能不支持动态 rooting，或需要重启设备）"; overall=1
    fi
done

if [[ "$overall" -ne 0 ]]; then
    echo "结论: 存在未获得 root 的设备" >&2
    exit 1
fi
echo "结论: 全部设备 root 可用"
