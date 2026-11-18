# pi-install — pi 编码代理管理器

在小服务器上一条命令安装 [pi](https://pi.dev)（`earendil-works/pi` 编码代理），再用交互式菜单管理任意多个中转站（OpenAI 兼容 API）、切换默认模型。

单文件、免 sudo、幂等可重跑、不碰系统自带的 Node。

## 特性

- **一键安装 / 更新 pi**：自动经 nvm 安装合适的 Node（pi 1.x 要求 >= 22.19），安装最新版 pi，可固定版本
- **多中转站管理**：逐个录入 provider 名、baseUrl、API 类型、模型列表、API Key，随时增删改
- **单模型参数修改**：上下文窗口（contextWindow）与最大输出 token（maxTokens）可单独更新，不用重填整个 provider
- **默认模型切换**：列出所有 provider 的全部模型，编号选择
- **Key 安全存放**：API Key 只存 `~/.pi/agent/keys.env`（权限 600），`models.json` 仅存 `$环境变量` 引用，换 Key 不用动 pi 配置
- **自愈**：启动时检测旧版脚本遗留的损坏 JSON 配置并自动备份清理
- **快速别名**：每个 provider 自动生成 `pi-<名字>` 命令

## 快速开始

把脚本传到服务器，然后**用 bash 运行**：

```bash
# 本地（PowerShell / macOS / Linux 均可）
scp pi-install.sh root@你的服务器:~/

# 服务器上
ssh root@你的服务器
bash pi-install.sh     # 注意：不要用 sh，Debian/Ubuntu 的 sh 是 dash
```

首次使用流程：选 `1` 安装 pi → 按提示添加第一个 provider → `source ~/.bashrc` → 输入 `pi` 开用。

## 菜单

```
1) 安装 / 更新 pi
2) 添加 / 修改 provider（baseUrl、模型、API Key）
3) 查看当前配置和默认模型
4) 切换默认模型
5) 重设 API Key
6) 删除 provider
7) 修改单个模型（参数 / 追加 / 删除）
0) 退出
```

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
