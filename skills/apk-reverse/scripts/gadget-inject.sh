#!/usr/bin/env bash
# gadget-inject.sh — 把 Frida Gadget 注入 APK（无需 root / 无需 Frida Server）
#
# 适用场景：
#   - 模拟器或真机没有 root（Play Store 镜像、非调试固件）
#   - 需要 hook 目标 App，但不能运行 frida-server
#
# 用法:
#   bash gadget-inject.sh <input.apk> [选项]
#
# 选项:
#   --out <path>        输出 APK（默认 <input>-gadget.apk）
#   --abi <abi>         目标 ABI（默认自动读取设备；不可用时 x86_64）
#   --lib <path>        gadget .so 路径（默认 ~/tools/frida-gadget/frida-gadget-<abi>.so）
#   --config <json>     gadget 配置；不传则用 listen 模式（默认 0.0.0.0:27042）
#   --install           注入并签名后安装到设备
#   --device <serial>   adb 设备序列号（默认使用当前唯一设备）
#   --keep-work         保留 apktool 中间目录
#
# 依赖: apktool、apksigner、zipalign、keytool（android-sdk build-tools + JDK）
#
# 说明:
#   - 注入点优先复用 App 已有的 Application 类（写入 <clinit>）；
#     若 Manifest 未声明 android:name，则新建一个 Application 子类并写入 Manifest。
#   - 系统 App 无法用不同签名覆盖安装，脚本会提示改用其他样本。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GADGET_HOME="${GADGET_HOME:-$HOME/tools/frida-gadget}"

log_info() { echo -e "\033[36m[INFO]\033[0m $*"; }
log_ok()   { echo -e "\033[32m[OK]\033[0m $*"; }
log_warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
log_err()  { echo -e "\033[31m[ERR]\033[0m $*" >&2; }

INPUT_APK=""
OUT_APK=""
ABI=""
GADGET_LIB=""
CONFIG_JSON=""
DO_INSTALL=false
DEVICE_SERIAL=""
KEEP_WORK=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --out) OUT_APK="$2"; shift 2 ;;
        --abi) ABI="$2"; shift 2 ;;
        --lib) GADGET_LIB="$2"; shift 2 ;;
        --config) CONFIG_JSON="$2"; shift 2 ;;
        --install) DO_INSTALL=true; shift ;;
        --device) DEVICE_SERIAL="$2"; shift 2 ;;
        --keep-work) KEEP_WORK=true; shift ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        -*) log_err "未知选项: $1"; exit 1 ;;
        *) INPUT_APK="$1"; shift ;;
    esac
done

[[ -n "$INPUT_APK" && -f "$INPUT_APK" ]] || { log_err "用法: $0 <input.apk> [--out ...] [--abi ...] [--install]"; exit 1; }

for tool in apktool apksigner zipalign keytool; do
    command -v "$tool" >/dev/null 2>&1 || { log_err "缺少工具: $tool（见 docs/KALI-LOCAL-SETUP.md §3）"; exit 1; }
done

# ─── 设备与 ABI ────────────────────────────────────────────────────────────────────

ADB=(adb)
[[ -n "$DEVICE_SERIAL" ]] && ADB=(adb -s "$DEVICE_SERIAL")

if [[ -z "$ABI" ]]; then
    if command -v adb >/dev/null 2>&1 && adb get-state >/dev/null 2>&1; then
        ABI="$("${ADB[@]}" shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')"
    fi
    ABI="${ABI:-x86_64}"
fi
case "$ABI" in
    x86_64|arm64-v8a|armeabi-v7a|x86) ;;
    *) log_err "不支持的 ABI: $ABI"; exit 1 ;;
esac

if [[ -z "$GADGET_LIB" ]]; then
    GADGET_LIB="$GADGET_HOME/frida-gadget-${ABI}.so"
fi
[[ -f "$GADGET_LIB" ]] || { log_err "找不到 gadget .so: $GADGET_LIB"; log_err "从 frida release 下载 frida-gadget-<ver>-android-${ABI}.so.xz 并解压到 $GADGET_HOME"; exit 1; }

log_info "输入: $INPUT_APK"
log_info "ABI:  $ABI"
log_info "Gadget: $GADGET_LIB"

# ─── 反编译 ────────────────────────────────────────────────────────────────────────

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gadget-inject-XXXXXX")"
cleanup() {
    if [[ "$KEEP_WORK" == "true" ]]; then
        log_info "保留工作目录: $WORK_DIR"
    else
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

log_info "apktool 反编译 ..."
apktool d -f -o "$WORK_DIR/app" "$INPUT_APK" >/dev/null

MANIFEST="$WORK_DIR/app/AndroidManifest.xml"
[[ -f "$MANIFEST" ]] || { log_err "反编译失败：缺少 AndroidManifest.xml"; exit 1; }

# ─── 放置 gadget ───────────────────────────────────────────────────────────────────

LIB_DIR="$WORK_DIR/app/lib/$ABI"
mkdir -p "$LIB_DIR"
cp "$GADGET_LIB" "$LIB_DIR/libgadget.so"

if [[ -n "$CONFIG_JSON" ]]; then
    [[ -f "$CONFIG_JSON" ]] || { log_err "配置文件不存在: $CONFIG_JSON"; exit 1; }
    cp "$CONFIG_JSON" "$LIB_DIR/libgadget.config.so"
    log_ok "gadget 配置已写入: lib/$ABI/libgadget.config.so"
else
    log_info "未指定 --config：gadget 将以 listen 模式启动（0.0.0.0:27042）"
fi

# ─── 注入 loadLibrary ──────────────────────────────────────────────────────────────

APP_CLASS="$(python3 - "$MANIFEST" <<'PY'
import re, sys
xml = open(sys.argv[1], encoding='utf-8').read()
m = re.search(r'<application\b[^>]*>', xml, re.S)
if not m:
    print(""); raise SystemExit
name = re.search(r'android:name\s*=\s*"([^"]+)"', m.group(0))
print(name.group(1) if name else "")
PY
)"

SMALI_LINE1='    const-string v0, "gadget"'
SMALI_LINE2='    invoke-static {v0}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V'

if [[ -n "$APP_CLASS" ]]; then
    log_info "App Application 类: $APP_CLASS"
    SMALI_PATH="$(find "$WORK_DIR/app" -path '*/smali*' -type f -name "$(basename "${APP_CLASS//./\/}").smali" | head -n1 || true)"
    if [[ -z "$SMALI_PATH" ]]; then
        log_err "在 smali 中找不到 Application 类: $APP_CLASS"
        log_err "可改用 — 在 Manifest 中声明自定义 Application（见脚本注释）"
        exit 1
    fi
    python3 - "$SMALI_PATH" "$SMALI_LINE1" "$SMALI_LINE2" <<'PY'
import re, sys
path, l1, l2 = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(path, encoding='utf-8').read()
if 'loadLibrary(Ljava/lang/String;)V' in src:
    print("already-injected"); raise SystemExit

clinit = re.search(r'\.method static constructor <clinit>\(\)V\n', src)
if clinit:
    # 在 .locals/.registers 之后插入
    idx = src.find('\n', clinit.end())
    body_start = clinit.end()
    reg = re.search(r'^(\s*\.(?:locals|registers)\s+\d+\s*)$', src[body_start:], re.M)
    insert_at = body_start + reg.end() if reg else body_start
    src = src[:insert_at] + "\n" + l1 + "\n" + l2 + src[insert_at:]
else:
    method = "\n.method static constructor <clinit>()V\n    .locals 1\n" + l1 + "\n" + l2 + "\n    return-void\n.end method\n"
    src = src.rstrip() + "\n" + method
open(path, 'w', encoding='utf-8').write(src)
print("injected")
PY
else
    log_info "Manifest 未声明 Application，新建注入类"
    NEW_CLASS="com/reverse/gadget/GadgetApp"
    mkdir -p "$WORK_DIR/app/smali/${NEW_CLASS%/*}"
    cat > "$WORK_DIR/app/smali/${NEW_CLASS}.smali" <<'SMALI'
.class public Lcom/reverse/gadget/GadgetApp;
.super Landroid/app/Application;

.method public constructor <init>()V
    .locals 0
    invoke-direct {p0}, Landroid/app/Application;-><init>()V
    return-void
.end method

.method static constructor <clinit>()V
    .locals 1
    const-string v0, "gadget"
    invoke-static {v0}, Ljava/lang/System;->loadLibrary(Ljava/lang/String;)V
    return-void
.end method
SMALI
    python3 - "$MANIFEST" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
if 'com.reverse.gadget.GadgetApp' in s:
    raise SystemExit
m = re.search(r'<application\b', s)
if not m:
    raise SystemExit("no <application> tag")
# 在 <application 的 '>' 前插入 android:name（若没有）
end = s.index('>', m.start())
tag = s[m.start():end]
if 'android:name' in tag:
    tag2 = re.sub(r'android:name\s*=\s*"[^"]*"', 'android:name="com.reverse.gadget.GadgetApp"', tag)
else:
    tag2 = tag + '\n        android:name="com.reverse.gadget.GadgetApp"'
s = s[:m.start()] + tag2 + s[end:]
open(p, 'w', encoding='utf-8').write(s)
PY
    log_ok "已创建并用 GadgetApp 覆盖 Application"
fi

# ─── 重建 + 签名 ───────────────────────────────────────────────────────────────────

log_info "apktool 重建 ..."
# apktool 3.x 默认使用 aapt2，无需 --use-aapt2
apktool b "$WORK_DIR/app" -o "$WORK_DIR/unsigned.apk" >/dev/null

OUT_APK="${OUT_APK:-${INPUT_APK%.apk}-gadget.apk}"
ALIGNED="$WORK_DIR/aligned.apk"
zipalign -f -p 4 "$WORK_DIR/unsigned.apk" "$ALIGNED"

KEYSTORE="$HOME/.android/debug.keystore"
if [[ ! -f "$KEYSTORE" ]]; then
    mkdir -p "$(dirname "$KEYSTORE")"
    keytool -genkeypair -v -keystore "$KEYSTORE" -storepass android -keypass android \
        -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 10000 \
        -dname "CN=Android Debug,O=Android,C=US" >/dev/null 2>&1
    log_ok "已生成调试签名: $KEYSTORE"
fi

apksigner sign --ks "$KEYSTORE" --ks-pass pass:android --key-pass pass:android \
    --ks-key-alias androiddebugkey --out "$OUT_APK" "$ALIGNED" >/dev/null
apksigner verify "$OUT_APK" >/dev/null
log_ok "已生成签名 APK: $OUT_APK"

# ─── 安装 ──────────────────────────────────────────────────────────────────────────

if [[ "$DO_INSTALL" == "true" ]]; then
    log_info "安装到设备 ..."
    if ! "${ADB[@]}" install -r "$OUT_APK"; then
        log_warn "安装失败：系统 App / 签名冲突 / 与设备已有包不兼容"
        log_warn "请改用可覆盖安装的样本，或先卸载同包名应用"
        exit 1
    fi
    log_ok "安装完成；启动 App 后使用: adb forward tcp:27042 tcp:27042 && frida -H 127.0.0.1:27042"
fi

cat <<EOF

下一步（listen 模式）：
  adb forward tcp:27042 tcp:27042
  frida-ps -H 127.0.0.1:27042          # 进程名显示为 "Gadget"
  frida -H 127.0.0.1:27042 -n Gadget -q -e "console.log(Process.id)"
  # 或脚本模式：--config 指向 {"interaction":{"type":"script","path":"/data/local/tmp/hook.js"}}

注意：
  - Gadget 随 App 启动，只影响该 App；系统 App 无法跨签名覆盖安装。
  - listen 模式需要目标 App 声明 android.permission.INTERNET，否则 Frida 会报
    "Unable to create socket: Operation not permitted"。
EOF
