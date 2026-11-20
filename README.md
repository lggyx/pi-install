# pi-install — pi 编码代理管理器

在小服务器上一条命令安装 [pi](https://pi.dev)（`earendil-works/pi` 编码代理），再用交互式菜单管理任意多个中转站（OpenAI 兼容 API）、切换默认模型。

单文件、免 sudo、幂等可重跑、不碰系统自带的 Node。支持 Linux 服务器与 Android/Termux（自动识别）。

## 特性

- **一键安装 / 更新 pi**：自动经 nvm 安装合适的 Node（pi 1.x 要求 >= 22.19），安装最新版 pi，可固定版本
- **多中转站管理**：逐个录入 provider 名、baseUrl、API 类型、模型列表、API Key，随时增删改
- **单模型参数修改**：上下文窗口（contextWindow）与最大输出 token（maxTokens）可单独更新，不用重填整个 provider
- **默认模型切换**：列出所有 provider 的全部模型，编号选择
- **Key 安全存放**：API Key 只存 `~/.pi/agent/keys.env`（权限 600），`models.json` 仅存 `$环境变量` 引用，换 Key 不用动 pi 配置
- **自愈**：启动时检测旧版脚本遗留的损坏 JSON 配置并自动备份清理
- **快速别名**：每个 provider 自动生成 `pi-<名字>` 命令

## License

[MIT](./LICENSE)

## 快速开始

### 方式一：curl 一键运行（服务器能直连 GitHub 时）

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lggyx/pi-install/main/pi-install.sh)
```

> **为什么不是 `curl … | bash`？** 本工具是交互式菜单，需要终端输入。`bash <(curl …)` 把脚本作为文件描述符读入，终端交互不受影响，效果和下载后运行完全一样。

国内网络直连 `raw.githubusercontent.com` 不稳定时，可用 jsDelivr CDN 镜像：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/lggyx/pi-install@main/pi-install.sh)
```

CDN 有缓存，刚推送的更新可能延迟数小时才生效。

### 方式二：下载后运行（可先审查再执行）

```bash
curl -fsSL https://raw.githubusercontent.com/lggyx/pi-install/main/pi-install.sh -o pi-install.sh
bash pi-install.sh
```

### Android / Termux

脚本自动识别 Termux（通过 `$PREFIX`），并按 pi 官方 Termux 文档的方式安装：**跳过 nvm**（nvm 的 Node 是 glibc 二进制，在 Termux 跑不起来），改用 pkg：

```bash
pkg update
bash <(curl -fsSL https://raw.githubusercontent.com/lggyx/pi-install/main/pi-install.sh)
# 提示无 curl 就先: pkg install curl
```

脚本会通过 `pkg install nodejs git` 装依赖，再用官方同款 `npm install -g --ignore-scripts` 装 pi。卸载时 Node 部分请用 `pkg uninstall nodejs`（菜单 8 会提示）。

### 方式三：scp 上传（最传统，不依赖服务器网络）

```bash
# 本地（PowerShell / macOS / Linux 均可）
scp pi-install.sh root@你的服务器:~/

# 服务器上
ssh root@你的服务器
bash pi-install.sh     # 注意：不要用 sh，Debian/Ubuntu 的 sh 是 dash
```

### 首次使用

选 `1` 安装 pi → 按提示添加第一个 provider → `source ~/.bashrc` → 输入 `pi` 开用。

## 菜单

```
1) 安装 / 更新 pi
2) 添加 / 修改 provider（baseUrl、模型、API Key）
3) 查看当前配置和默认模型
4) 切换默认模型
5) 重设 API Key
6) 删除 provider
7) 修改单个模型（参数 / 追加 / 删除）
8) 卸载（pi / Node / nvm / 配置）
0) 退出
```

## 卸载

菜单 `8` 是分步卸载向导，覆盖本脚本安装/写入的全部内容，可整包卸载也可单独执行某一步：

- **pi 本体**（npm 全局包）
- **.bashrc 痕迹**（托管块、`pi-*` 别名、旧版脚本残留）
- **pi 配置与数据**（`~/.pi`：可整体删除，或只删配置保留会话历史）
- **Node**（仅本脚本装的 nvm 版本；nvm 里用户自己的其他版本不动）
- **nvm 本体**（`~/.nvm` 目录 + `.bashrc` 引导行）

系统自带的 Node、包管理器内容全程不受影响；每一步删除前都有确认。

与官方卸载方式的关系：本工具经 npm 安装 pi，`npm uninstall -g @earendil-works/pi-coding-agent` 即官方文档为此安装方式给出的卸载命令；官方明确说明卸载不会删除 `~/.pi/agent/`（配置、凭证、会话、已装 pi 包），所以向导把数据清理做成了独立的第 3 步。若你还用 `pi.dev/install.sh` 装过一份 pi，请重跑该脚本并选择 "Uninstall Pi"。

## 数据存放

| 文件 | 内容 |
| --- | --- |
| `~/.pi/agent/models.json` | provider / 模型定义（pi 官方格式，含上下文与输出限制） |
| `~/.pi/agent/settings.json` | 默认模型等设置 |
| `~/.pi/agent/keys.env` | API Key（`chmod 600`，仅引用不写进 models.json） |
| `~/.bashrc` 托管块 | 加载 keys.env + `pi-<名字>` 别名 |

脚本本身不保存任何配置——删掉脚本不影响已配置的中转站，重传脚本配置依然都在。

## 可调参数（环境变量）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NODE_WANT_MAJOR` | `24` | nvm 安装的 Node 主版本 |
| `PI_VERSION` | `latest` | pi 版本，如 `PI_VERSION=1.4.0` 固定版本 |

## 说明与排错

- **必须用 bash 运行**。Debian/Ubuntu 的 `sh` 是 dash；脚本带自动切回 bash 的保护，但直接 `bash pi-install.sh` 最稳
- pi 首次启动提示是否信任当前目录时，选 **Trust**
- 部分老系统 Node 装完无法运行，缺系统库：`sudo apt-get install -y libatomic1`
- 新终端里 Node 版本不对：通常是 `.bashrc` 里 nvm 引导块之后还有 `export PATH=...` 行，调整行顺序即可
- 支持的 API 类型：`openai-completions`（多数中转站）、`openai-responses`、`anthropic-messages`、`google-generative-ai`
