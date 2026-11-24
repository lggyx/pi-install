# pi-install — pi 编码代理管理器

一条命令在 Linux 服务器或 Android/Termux 上安装 [pi](https://pi.dev) 编码代理，并用交互式菜单管理任意多个中转站（OpenAI 兼容 API）和模型。单文件、免 sudo、幂等可重跑、不碰系统自带的 Node。

## 30 秒上手

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lggyx/pi-install/main/pi-install.sh)
```

Termux 上同样这条命令（脚本自动识别环境）。菜单打开后：

1. 选 `1` 安装 pi（Termux 自动走 pkg 装 Node，服务器走 nvm）
2. 按提示录入第一个中转站（baseUrl + 模型 + API Key）
3. `source ~/.bashrc`，输入 `pi` 开用

> Windows 用户（PowerShell / cmd）？脚本跑在服务器上，本地只需「下载 + 上传」，见 [Windows 专节](#windowspowershell--cmd)。

> 为什么不是 `curl … | bash`？本工具是交互式菜单，需要终端输入；`bash <(curl …)` 让脚本从文件描述符读入，终端交互不受影响。

## 我想…

| 我想… | 菜单 |
| --- | --- |
| 安装 / 更新 pi | `1` |
| 添加一个中转站 | `2` |
| 看看当前用的模型和各中转站 | `3` |
| 切换默认模型 | `4` |
| 更换某个中转站的 API Key | `5` |
| 删除一个中转站 | `6` |
| 改单个模型的上下文 / 最大输出 token | `7` |
| 追加或删除单个模型（不重填整个 provider） | `7` |
| 彻底卸载（pi / Node / nvm / 配置） | `8` |

## 菜单详解

进入菜单后界面长这样：

```
1) 安装 / 更新 pi            5) 重设 API Key
2) 添加 / 修改 provider      6) 删除 provider
3) 查看当前配置              7) 修改单个模型（参数/追加/删除）
4) 切换默认模型              8) 卸载
0) 退出
```

- **`1` 安装 / 更新 pi**：全自动——服务器上经 nvm 装 Node 24（可用 `NODE_WANT_MAJOR` 改），Termux 上用 pkg 装 `nodejs git`，再装 pi。重复执行 = 检查更新，幂等
- **`2` 添加 / 修改 provider**：依次询问 provider 名（小写字母/数字/下划线）、baseUrl、API 类型、模型列表（每个模型可选填上下文窗口和最大输出 token）、API Key。输入已存在的名字 = 覆盖修改
- **`3` 查看当前配置**：默认模型、每个中转站的地址/模型/Key 状态一览
- **`4` 切换默认模型**：把所有 provider 的全部模型列成编号，选一个即设为默认
- **`5` 重设 API Key**：只换 Key，不动其他配置
- **`6` 删除 provider**：删整个中转站，可顺带删它的 Key
- **`7` 修改单个模型**：选 provider → 选模型 → 改上下文/最大输出（回车=不变、数字=改、0=恢复默认）；也可以追加新模型或删除单个模型，**不用重填整个 provider**
- **`8` 卸载**：分步向导，见下文

## 安装方式详解

**一键运行（推荐）**——服务器与 Termux 通用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lggyx/pi-install/main/pi-install.sh)
```

国内网络连 GitHub raw 不稳定时，用 jsDelivr CDN 镜像（有缓存，刚发布的更新可能延迟数小时）：

```bash
bash <(curl -fsSL https://cdn.jsdelivr.net/gh/lggyx/pi-install@main/pi-install.sh)
```

**下载后运行（想先审查脚本内容）**：

```bash
curl -fsSL https://raw.githubusercontent.com/lggyx/pi-install/main/pi-install.sh -o pi-install.sh
bash pi-install.sh
```

**scp 上传（服务器网络受限时）**：

```bash
scp pi-install.sh root@你的服务器:~/   # 本地执行
ssh root@你的服务器 && bash pi-install.sh   # 服务器上执行
```

### Windows（PowerShell / cmd）

脚本是 bash、跑在服务器上；Windows 本地的工作只有**下载 + 上传**。Windows 10（1803+）/ 11 自带 `curl.exe`、`scp`、`ssh`，不用装额外软件。

**PowerShell**（注意写 `curl.exe`——PowerShell 5.x 里 `curl` 是 `Invoke-WebRequest` 的别名，参数不兼容，会报错）：

```powershell
# 下载脚本（GitHub raw 与 jsDelivr CDN 二选一）
curl.exe -o pi-install.sh https://raw.githubusercontent.com/lggyx/pi-install/main/pi-install.sh
curl.exe -o pi-install.sh https://cdn.jsdelivr.net/gh/lggyx/pi-install@main/pi-install.sh

# 上传到服务器
scp pi-install.sh root@你的服务器:~/

# 登录服务器，然后执行菜单
ssh root@你的服务器
# 登录后（服务器上）执行：bash pi-install.sh
```

老系统没有 `curl.exe` 时，用 PowerShell 内置的 `Invoke-WebRequest` 下载：

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/lggyx/pi-install/main/pi-install.sh -OutFile pi-install.sh
```

**cmd**（Windows 10 1803+ 直接可用，无需加 `.exe` 后缀）：

```cmd
curl -o pi-install.sh https://raw.githubusercontent.com/lggyx/pi-install/main/pi-install.sh
scp pi-install.sh root@你的服务器:~/
ssh root@你的服务器
```

**Git Bash / WSL**：与 Linux 完全一致，一键命令直接可用：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lggyx/pi-install/main/pi-install.sh)
```

**Termux 补充**：脚本自动识别 Termux 并按 pi 官方文档处理——跳过 nvm（nvm 的 Node 是 glibc 二进制，在 Termux 跑不起来），改用 `pkg install nodejs git`；pi 的安装命令与官方文档一致（`npm install -g --ignore-scripts`）。缺 curl 就先 `pkg install curl`。

## 卸载

菜单 `8` 是分步卸载向导，可整包卸载（选 `a`）也可只执行某一步：

- **pi 本体**：`npm uninstall -g @earendil-works/pi-coding-agent`，即 pi 官方文档给 npm 安装方式的卸载命令
- **.bashrc 痕迹**：托管块、`pi-*` 别名、旧版脚本残留
- **pi 配置与数据**：`~/.pi` 可整体删除，或只删配置保留会话历史（官方卸载命令不碰这些数据，所以单独成步）
- **Node**：仅本脚本经 nvm 装的版本；你 nvm 里自己的其他版本不动。Termux 下 Node 归 pkg 管，会提示你 `pkg uninstall nodejs`
- **nvm 本体**：`~/.nvm` 目录 + `.bashrc` 引导行

系统自带的 Node、包管理器内容全程不受影响；每一步删除前都有确认。

## 数据与安全

| 文件 | 内容 |
| --- | --- |
| `~/.pi/agent/models.json` | provider / 模型定义（pi 官方格式，含上下文与输出限制） |
| `~/.pi/agent/settings.json` | 默认模型等设置 |
| `~/.pi/agent/keys.env` | API Key，`chmod 600` |
| `~/.bashrc` 托管块 | 加载 keys.env + `pi-<名字>` 别名 |

- **Key 不落 models.json**：里面只写 `$环境变量` 引用，换 Key 只改 `keys.env`（菜单 5），不用动 pi 的任何配置
- **脚本本身不存配置**：中转站配置都在 `~/.pi/agent/`，删脚本、换机器重传脚本都不影响
- **启动自愈**：脚本启动时检测损坏的 JSON 配置（旧版脚本遗留）并自动备份清理，避免 pi 崩溃
- 每个 provider 自动生成 `pi-<名字>` 命令（如 `pi-stepfun`），可跳过默认模型直接用指定中转站

## 可调参数（环境变量）

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `NODE_WANT_MAJOR` | `24` | nvm 安装的 Node 主版本（Termux 下无效，走 pkg） |
| `PI_VERSION` | `latest` | pi 版本，如 `PI_VERSION=1.4.0` 固定版本 |

## 排错

| 症状 | 处理 |
| --- | --- |
| `Illegal option -o pipefail` | 用 `sh` 跑了——必须 `bash pi-install.sh`（脚本自带自动切换保护，但直接 bash 最稳） |
| 新终端 node 版本不对 | `.bashrc` 里 nvm 引导块之后还有 `export PATH=...` 行，调整行顺序 |
| Node 装完无法运行（老系统） | `sudo apt-get install -y libatomic1` |
| Termux 下 pkg 装完 Node 仍异常 | 脚本会打印 node 的真实报错；常见处理 `pkg reinstall nodejs` 或 `pkg upgrade` |
| pi 启动报 trust.json 损坏 | 旧版脚本遗留——脚本启动时会自动清理；手动删 `~/.pi/agent/trust.json` 亦可 |
| 找不到 pi 命令 | `npm prefix -g` 确认全局 bin 目录在 PATH 里；新开一个 shell 再试 |
| Windows 提示 `curl` 参数错误 | PowerShell 5.x 的 `curl` 是 `Invoke-WebRequest` 别名——改用 `curl.exe` 或 `Invoke-WebRequest` |
| Windows 找不到 `scp` / `ssh` | 设置 → 应用 → 可选功能 → 添加「OpenSSH 客户端」（Win10 1803+ 通常自带） |

支持的 API 类型：`openai-completions`（多数中转站）、`openai-responses`、`anthropic-messages`、`google-generative-ai`。

## License

[MIT](./LICENSE)
