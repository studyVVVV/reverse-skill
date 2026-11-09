# Kali 本机配置记录（机器级 setup）

> **定位**：本文件记录「仓库之外、只存在于本机」的配置，换机或重装时照此复现。
> 仓库自身的行为链与路由以 [kali/RULES-kali.md](../kali/RULES-kali.md) 和 [skills/MASTER-ROUTING.md](../skills/MASTER-ROUTING.md) 为准，本文件不定义路由。
>
> 记录时间：2026-11-09 · 基线：Kali GNU/Linux Rolling 2026.3 / 内核 7.1.5+kali-amd64 / 普通用户 `m`（通过 `sudo` 提权）。
> 所有版本号均来自本机实测，不是估计值。

---

## 0. 前置条件与约束

| 项 | 值 |
|---|---|
| 发行版 | Kali Rolling（`PRETTY_NAME="Kali GNU/Linux Rolling"`，`VERSION_ID=2026.3`） |
| 默认 Python | 3.14.8（`/usr/bin/python3`）→ 部分工具需另装 3.13 |
| 默认 JDK | OpenJDK 25 |
| Shell | bash；`~/.local/bin` 在 `PATH` 中 |
| 权限 | 安装系统包需要 `sudo`；仓库脚本不写客户端全局配置 |

**本机网络实测限制**（决定了下文很多绕行做法）：

| 目标 | 现象 | 应对 |
|---|---|---|
| `github.com` 直连 | 连接超时 / 504 | 走 `api.github.com` 的 release asset 接口（可正常访问） |
| `proxy.golang.org` | 连接超时 | `GOPROXY=https://goproxy.cn,direct` |
| Docker Hub (`registry-1.docker.io`) | 超时 | 配 registry mirror，见 §6 |
| `raw.githubusercontent.com` | 通常可用（慢） | 可读 README／文档 |
| PyPI / Kali 源 | 可用 | 正常使用 |

---

## 1. 仓库与工具索引

```bash
git clone git@github.com:studyVVVV/reverse-skill.git
cd reverse-skill

# 生成 skills/tool-index.md（gitignored 的本机文件）
bash kali/scripts/refresh-tool-index.sh

# 回归自检
bash skills/scripts/test-routing.sh            # 180 条路由用例
bash skills/scripts/test-bootstrap-manifest.sh
bash skills/scripts/test-client-neutral-bootstrap.sh
```

---

## 2. 系统包（apt）

```bash
sudo apt-get update
sudo apt-get install -y \
  python3.13 python3.13-venv python3.13-dev \
  yara crackmapexec bloodhound golang-go docker.io
```

| 包 | 版本 | 用途 |
|---|---|---|
| `python3.13` | 3.13.15-1 | PyGhidra 只支持 3.10–3.13；系统默认 3.14 不可用 |
| `python3.13-venv` / `-dev` | 3.13.15-1 | 建 venv、编译扩展 |
| `yara` | 4.5.8 | 规则扫描 |
| `crackmapexec` | 5.4.0 | 内网枚举（历史工具，netexec 的替代品仍保留） |
| `bloodhound` | 9.8.0~rc3 | AD 攻击路径（连带 neo4j / sharphound / azurehound） |
| `golang-go` | go1.27.3 | `go install` 类工具 |
| `docker.io` | 28.5.2+dfsg4 | 容器运行时（dex-pentester toolbox） |

> 注：`docker-compose-v2` 在 Kali 源中不存在，不要写进安装清单。
> `hexstrike-ai`、`adaptixc2`、`certipy-ad` 等随 Kali 源预装，但**可执行名与包名不同**：`hexstrike_mcp` / `hexstrike_server`、`adaptixserver`、`certipy-ad`（已建 `~/.local/bin/certipy` 软链）。

---

## 3. 用户级逆向工具（无需 root）

统一约定：程序放 `~/tools/<name>/`，入口软链或 wrapper 放 `~/.local/bin/`（已在 `PATH`）。

### 3.1 jadx / apktool / adb / APK 签名链

```bash
# jadx：走仓库 bootstrap，版本与 SHA-256 由 manifest 固定
bash kali/scripts/bootstrap-reverse.sh jadx
#   -> ~/tools/jadx（1.5.6，sha256 545ea2be...）

# apktool：apt 需要 root，改用官方 jar + wrapper
#   jar 放 ~/tools/apktool/apktool_3.0.3.jar（sha256 dbf930b0...）
#   ~/.local/bin/apktool: exec java -jar "$HOME/tools/apktool/apktool_3.0.3.jar" "$@"

# Android platform-tools（adb/fastboot），版本 37.0.2，sha1 736a08af...
#   解压到 ~/tools/platform-tools，软链 adb/fastboot 到 ~/.local/bin

# Android build-tools 36.0.0（apksigner/zipalign/aapt2/d8），sha1 b0b63769...
#   解压到 ~/tools/android-build-tools/36.0.0，wrapper 写入 ~/.local/bin
```

验收：

```bash
jadx --version          # 1.5.6
apktool --version       # 3.0.3
adb version             # 1.0.41 (37.0.2)
apksigner --version     # 0.9
zipalign -h 2>&1 | head -1
```

### 3.2 浏览器自动化

```bash
bash kali/scripts/bootstrap-reverse.sh agent-browser
#   agent-browser 0.31.1（nvm 全局）+ Playwright chromium-headless-shell
#   浏览器缓存：~/.cache/ms-playwright
npm install -g playwright@1.56.0    # 提供 playwright CLI
```

Chromium 运行依赖（本机已具备）：`libnss3`、`libnspr4`、`libatk-1.0`、`libgbm`、`libasound`。

### 3.3 其他

| 工具 | 版本 | 安装方式 |
|---|---|---|
| proxycat | 固定 commit `2309b713` | `bash kali/scripts/bootstrap-reverse.sh proxycat`（git clone + pip） |
| bkcrack | 1.8.1 | GitHub release tar.gz（sha256 `45dc7d81...`）→ `~/tools/bkcrack` |
| frida / frida-tools | 17.26.2 | `pip install --user frida-tools`（已有 `~/.local/bin/frida`） |

---

## 4. Ghidra 与 GhidraMCP

Ghidra 是本仓库的**默认**反编译路线（R22），IDA 仅在显式点名时使用（R6）。

### 4.1 Ghidra 本体

```bash
sudo apt-get install -y ghidra      # 12.1.4+ds-0kali1
ghidra --help                       # /usr/bin/ghidra
/usr/share/ghidra/support/analyzeHeadless   # headless 入口
```

### 4.2 GhidraMCP 2.0（适配 Ghidra 12.1.4）

发布包 `GhidraMCP-release-2-0.zip`（sha256 `ebf904fd...`），包含 Ghidra 扩展与 Python MCP 客户端。

```bash
# 1) 扩展：解压到 Ghidra 用户扩展目录（无需 root）
#    ~/.config/ghidra/ghidra_12.1.4_DEV/Extensions/GhidraMCP/
#    目录内应有 extension.properties、Module.manifest、lib/GhidraMCP.jar

# 2) 客户端：pyghidra 需要 Python 3.10–3.13，因此用 3.13 venv
python3.13 -m venv ~/.local/venvs/ghidra-mcp
~/.local/venvs/ghidra-mcp/bin/pip install \
  '/path/to/ghidra_mcp-2.0.0-py3-none-any.whl[headless]'

# 3) wrapper：~/.local/bin/ghidra-mcp
#    export GHIDRA_INSTALL_DIR="${GHIDRA_INSTALL_DIR:-/usr/share/ghidra}"
#    exec "$HOME/.local/venvs/ghidra-mcp/bin/ghidra-mcp" "$@"
```

> 不要用系统默认的 Python 3.14 重建该 venv——pyghidra 不支持 3.14。

### 4.3 验收

```bash
# GUI 模式：Ghidra 打开程序后插件在 127.0.0.1:8080 提供 HTTP 后端
# headless 模式：自行用 PyGhidra 导入并分析
ghidra-mcp --headless --binary /bin/true
#   发 initialize 应返回 serverInfo=ghidra-mcp
#   tools/list 应为 28 个工具
#   tools/call get_program_info 应返回 ELF 元数据（x86:LE:64、gcc）

# Ghidra 本体 headless 冒烟
/usr/share/ghidra/support/analyzeHeadless /tmp/ghproj proj1 -import /bin/true -deleteProject
```

端口：GhidraMCP 2.0 默认 **8080**（旧文档里的 8765 已废弃）。

---

## 5. MCP 客户端配置（可选，客户端相关）

配置文件示例（Claude 风格，`~/.claude/mcp.json`）：

```json
{
  "mcpServers": {
    "kali-server":    { "command": "kali-server-mcp", "args": ["--port", "5000"] },
    "metasploit-mcp": { "command": "metasploitmcp", "args": ["--transport", "stdio"] },
    "hexstrike":      { "command": "hexstrike_mcp", "args": [] },
    "jshook":         { "command": "npx", "args": ["-y", "@jshookmcp/jshook@0.3.4"],
                        "env": { "JSHOOK_BASE_PROFILE": "search" } },
    "ghidra":         { "command": "/home/<user>/.local/bin/ghidra-mcp",
                        "args": ["--ghidra-server", "http://127.0.0.1:8080/"] }
  }
}
```

要点：

- `hexstrike` 的 MCP 入口是 **`hexstrike_mcp`**（不是 `hexstrike-ai`）；调用前需先启动 API 服务 `hexstrike_server`（默认 `http://127.0.0.1:8888`）。
- `ghidra` 使用绝对路径，避免客户端 PATH 不含 `~/.local/bin`。
- 这些是**客户端全局配置**，仓库脚本不会写入；按需自行维护。

---

## 6. 可选：dsh-pentester（DeepSeek Harness 插件）

> 属于客户端侧能力，仓库不依赖它；这里只记录本机启用方式。

### 6.1 版本前提

- `dsh-pentester@6.5.0`，要求 `dsh >=0.2.0-rc.1 <0.3.0`（本机 dsh 0.2.2-rc.1）
- 启用后新增 `pentester` agent preset 与 `pentester_run / pentester_delegate / pentester_advance_stage` 等工具面

### 6.2 Docker 运行时

```bash
sudo apt-get install -y docker.io
sudo usermod -aG docker "$USER"            # 新会话生效
sudo setfacl -m u:"$USER":rw /var/run/docker.sock   # 让已运行的 dsh 进程立即可用
```

镜像加速（`/etc/docker/daemon.json`，Docker Hub 直连超时时必需）：

```json
{
  "registry-mirrors": [
    "https://dockerproxy.net",
    "https://hub.rat.dev",
    "https://docker.1ms.run"
  ]
}
```

```bash
sudo systemctl enable --now docker
sudo systemctl reload docker     # 热加载 mirror，不重启 daemon
docker info | grep -A4 'Registry Mirrors'
```

Toolbox 镜像（插件默认名，必须保持一致）：

```bash
docker pull dockerproxy.net/fb0sh/dsh-pentester-kali:latest
docker tag  dockerproxy.net/fb0sh/dsh-pentester-kali:latest fb0sh/dsh-pentester-kali:latest
docker run --rm --cap-add=NET_RAW --cap-add=NET_ADMIN \
  fb0sh/dsh-pentester-kali:latest sh -c 'nmap --version | head -1'
```

> 镜像约 7.4 GB，内含 Kali 工具链（nmap / sqlmap / nuclei / ffuf 等）。
> `nmap` 需要 `NET_RAW`；插件自行加 capability，手工验证时要显式加。

### 6.3 内置技能包（1011 个）

插件 UI 的下载走 `github.com`，本网络不可达；改为按插件内嵌 manifest 手动安装：

| 项 | 值 |
|---|---|
| tag / asset | `skill-pack-v1.1.0` / `dsh-pentester-skills-v1.1.0.tar.gz` |
| sha256 | `e6449d344b81a08bc6c1c6fde7e75b56b7b41b60073942cd3e23e6e9127b6cb6` |
| 目标目录 | `~/.dsh/dsh-pentester/skill-packs/1.1.0/skills` |
| 标记文件 | 同目录 `.installation.json`（schemaVersion / version / sha256 / installedAt / leafSkills） |

```bash
# 通过 api.github.com 的 asset 接口下载（github.com 直连会被 504）
curl -sSL -H 'Accept: application/octet-stream' \
  -o skillpack.tar.gz https://api.github.com/repos/fb0sh/dsh-pentester/releases/assets/<asset-id>
sha256sum skillpack.tar.gz     # 必须等于上表 sha256

SP="$HOME/.dsh/dsh-pentester/skill-packs/1.1.0"
mkdir -p "$SP" && tar -xzf skillpack.tar.gz -C "$SP"
find "$SP/skills" -name SKILL.md | wc -l    # 应为 1011
```

安装标记示例：

```json
{
  "schemaVersion": 1,
  "version": "1.1.0",
  "sha256": "e6449d344b81a08bc6c1c6fde7e75b56b7b41b60073942cd3e23e6e9127b6cb6",
  "installedAt": "2026-11-09T03:20:00Z",
  "leafSkills": 1011
}
```

### 6.4 会话侧确认

1. 刷新 GUI → `Settings → Pentester → Overview`：Docker ✓、Skills 1011、Agents 19
2. 新建会话选择 **pentester preset**，`pentester_run` 启动 PTES 流程

---

## 7. 网络受限时的通用手法

| 场景 | 做法 |
|---|---|
| GitHub Release 下载 | `api.github.com/repos/<owner>/<repo>/releases/assets/<id>` + `Accept: application/octet-stream`，可断点续传 |
| Go 模块 | `GOPROXY=https://goproxy.cn,direct go install <pkg>@<ver>` |
| Docker 镜像 | `daemon.json` 配 mirror；或先 `docker pull <mirror>/<image>` 再 `docker tag` 回原名 |
| 下载完整性 | 一律核对 manifest / release 里的 sha256；不要接受「下载成功即安装」 |

---

## 8. 已知坑（已修复或需注意）

| 问题 | 说明 |
|---|---|
| `bootstrap-reverse.sh` 假阳性 | 下载失败后仍报 `✓`；已在 commit `788116a` 修复（分支退出码透传 + manifest `verifyCommand` 复核） |
| 可执行名错配 | `hexstrike-ai`→`hexstrike_mcp`、`AdaptixServer`→`adaptixserver`、`certipy`→`certipy-ad`（manifest / catalog 已对齐） |
| Ghidra 端口 | GhidraMCP 2.0 为 8080，历史文档的 8765 已全部替换 |
| Python 3.14 与 PyGhidra | pyghidra 仅支持 3.10–3.13，headless 必须用 3.13 venv |
| Docker Hub 限流 | 镜像站会返回 `toomanyrequests`，换 mirror 或稍后重试 |
| `docker-compose-v2` | Kali 源无此包，安装清单中不要包含 |

---

## 9. 一键验收清单

```bash
# 仓库
bash skills/scripts/test-routing.sh && bash skills/scripts/test-bootstrap-manifest.sh

# 逆向工具
jadx --version && apktool --version && adb version && apksigner --version
frida --version && bkcrack --help 2>&1 | head -1

# Ghidra
ghidra-mcp --headless --binary /bin/true    # initialize / tools/list / get_program_info

# Docker + toolbox
docker info | grep -A4 'Registry Mirrors'
docker run --rm --cap-add=NET_RAW fb0sh/dsh-pentester-kali:latest nmap --version | head -1

# dsh-pentester 技能包
find ~/.dsh/dsh-pentester/skill-packs/*/skills -name SKILL.md | wc -l   # 1011
```

---

## 10. 安全与合规

- 渗透/逆向操作必须落在 `work/<case>/scope.md` 的授权范围内（见 [kali/RULES-kali.md](../kali/RULES-kali.md)）
- LLM API Key 只放环境变量、OS keychain 或 `600` 权限配置文件；不要写进报告、日志或提交
- `sudo` 临时授权用完立即删除（本机不保留 NOPASSWD 配置）
- 下载的第三方 Release / 镜像一律校验 sha256；镜像走 mirror 时同样核对 digest
