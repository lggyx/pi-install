#!/bin/bash
# 被 sh（Debian/Ubuntu 的 sh 是 dash）误调时，自动切回 bash 重新执行
if [ -z "${BASH_VERSION:-}" ]; then exec bash "$0" "$@"; fi
set -euo pipefail

# ============================================================
# pi 管理器 —— 交互式菜单（安装 + 多中转站配置，单文件）
# 适用：小型 Linux 服务器（不需要 sudo，全部装在 nvm 和用户目录）
#
# 用法：bash pi-install.sh   （需要交互式终端）
#
# 菜单能力：
#   1. 安装/更新 pi（nvm + Node + pi 本体，幂等可重跑）
#   2. 添加/修改 provider：输入名字、baseUrl、模型列表、API Key
#   3. 查看当前配置：默认模型、所有 provider、key 状态
#   4. 切换默认模型
#   5. 重设某个 provider 的 API Key
#   6. 删除 provider
#
# 数据存放（服务器上，脚本可随意删）：
#   ~/.pi/agent/models.json   provider / 模型定义（pi 官方格式）
#   ~/.pi/agent/settings.json 默认模型等
#   ~/.pi/agent/keys.env      API Key（chmod 600，bashrc 托管块会加载它）
#   ~/.bashrc                 托管块：加载 keys.env + pi-<名字> 别名
#
# Node 版本：pi 1.x 官方要求 >= 22.19，默认装 24（LTS 线），
#           换版本先 export NODE_WANT_MAJOR=25
# pi 版本：默认 latest，固定版本先 export PI_VERSION=1.4.0
# ============================================================

# ---------- 颜色 / 日志 ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
# 菜单体系里任何单项失败都应回到菜单，所以 fail 只返回非零、不退出脚本
fail()  { echo -e "${RED}[FAIL]${NC}  $1"; return 1; }

# ---------- 路径 / 参数 ----------
NODE_WANT_MAJOR="${NODE_WANT_MAJOR:-24}"
NODE_MIN_MAJOR=22                          # pi 1.x engines: node >= 22.19.0
PI_VERSION="${PI_VERSION:-latest}"
PI_DIR="$HOME/.pi/agent"
PI_MODELS_FILE="$PI_DIR/models.json"
PI_SETTINGS_FILE="$PI_DIR/settings.json"
PI_KEYS_FILE="$PI_DIR/keys.env"
SHELL_RC="$HOME/.bashrc"
BASHRC_BLOCK_BEGIN="# >>> pi-agent (managed by pi-install.sh) >>>"
BASHRC_BLOCK_END="# <<< pi-agent (managed by pi-install.sh) <<<"

if [ ! -t 0 ]; then
    fail "本脚本需要交互式终端运行：ssh 登录后执行 bash $0"
    exit 1
fi

# ---------- 旧版遗留损坏文件的自愈 ----------
# 旧版 pi-stepfun-install.sh 的 trust.json/settings.json 生成有引号展开 bug，
# 产出非法 JSON；pi 1.x 启动读 trust.json 时会直接崩溃。
# 这里校验这三个配置文件，损坏的改名备份并删除（pi 会自行重建）。
repair_legacy_files() {
    # 自包含地加载 nvm（这里调用时，安装区的 load_nvm 还没定义）
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # shellcheck disable=SC1091
        . "$NVM_DIR/nvm.sh"
    fi
    command -v node >/dev/null 2>&1 || return 0
    [ -d "$PI_DIR" ] || return 0
    local f
    for f in "$PI_DIR/trust.json" "$PI_DIR/settings.json" "$PI_DIR/models.json"; do
        [ -s "$f" ] || continue
        if ! node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" "$f" 2>/dev/null; then
            mv "$f" "$f.broken.bak"
            warn "检测到损坏的 $(basename "$f")（旧版脚本遗留的非法 JSON），已备份为 $(basename "$f").broken.bak"
        fi
    done
}
repair_legacy_files

# ============================================================
# JSON 统一入口：所有读写 models.json / settings.json 的操作
# 都走下面这一段 node 脚本，操作类型由 PI_OP 决定：
#   show     输出 DEFAULT 行 + 每个 provider 一行
#   upsert   新增/覆盖一个 provider（PI_KEY/PI_BASEURL/PI_API/PI_MODELS_SPEC/PI_APIKEY/PI_SET_DEFAULT）
#            PI_MODELS_SPEC = "模型ID|上下文|最大输出,模型ID|上下文|最大输出,..."
#            竖线字段留空 = 用 pi 默认值（上下文 128000 / 最大输出 16384）
#   models   列出某 provider 的模型：每行 模型ID<TAB>上下文<TAB>最大输出（- 为默认）
#   model_set 只改一个模型的参数（PI_KEY/PI_MODEL/PI_CTX/PI_MAX；空=不变，0=恢复默认，数字=设置）
#   model_add 追加一个模型（PI_KEY/PI_MODEL/PI_CTX/PI_MAX；空=默认，数字=设置）
#   model_del 删除一个模型（PI_KEY/PI_MODEL；若它是默认模型则同时清空默认）
#   setkey   只改某 provider 的 apiKey 字段（PI_KEY/PI_APIKEY）
#   delete   删除一个 provider（PI_KEY）
#   defaults 写默认模型（PI_DEF_PROVIDER/PI_DEF_MODEL，传 - 表示清除）
#   touch    安装后补写 settings（PI_VER 写入 lastChangelogVersion 压更新弹窗）
# ============================================================
pi_json() {
    mkdir -p "$PI_DIR"
    env PI_MODELS="$PI_MODELS_FILE" PI_SETTINGS="$PI_SETTINGS_FILE" \
        PI_OP="${PI_OP:-}" PI_KEY="${PI_KEY:-}" PI_BASEURL="${PI_BASEURL:-}" \
        PI_API="${PI_API:-}" PI_MODELS_SPEC="${PI_MODELS_SPEC:-}" \
        PI_APIKEY="${PI_APIKEY:-}" PI_SET_DEFAULT="${PI_SET_DEFAULT:-}" \
        PI_DEF_PROVIDER="${PI_DEF_PROVIDER:-}" PI_DEF_MODEL="${PI_DEF_MODEL:-}" \
        PI_MODEL="${PI_MODEL:-}" PI_CTX="${PI_CTX:-}" PI_MAX="${PI_MAX:-}" \
        PI_VER="${PI_VER:-}" \
        node <<'PIJS'
const fs = require("fs");
const env = process.env;
const readJson = (p, fb) => {
    try { return JSON.parse(fs.readFileSync(p, "utf8")); } catch { return fb; }
};
const writeJson = (p, o) => fs.writeFileSync(p, JSON.stringify(o, null, 2) + "\n");
const models = readJson(env.PI_MODELS, {});
models.$schema = models.$schema || "https://pi.dev/schemas/models.schema.json";
models.providers = models.providers || {};
const settings = readJson(env.PI_SETTINGS, {});
const saveSettings = () => {
    settings.$schema = settings.$schema || "https://pi.dev/schemas/settings.schema.json";
    writeJson(env.PI_SETTINGS, settings);
};

if (env.PI_OP === "upsert") {
    const key = env.PI_KEY;
    // 覆盖时保留该 provider 段里已有的其他字段（如 authHeader），模型列表整体重建
    const entry = { ...(models.providers[key] || {}) };
    entry.baseUrl = env.PI_BASEURL;
    if (env.PI_API) entry.api = env.PI_API;
    // 每个模型：ID|上下文窗口|最大输出，后两项留空用 pi 默认（128000 / 16384）
    const specs = (env.PI_MODELS_SPEC || "").split(",").map(s => s.trim()).filter(Boolean);
    entry.models = specs.map(spec => {
        const [id, ctx, max] = spec.split("|").map(x => (x || "").trim());
        const m = { id };
        const c = Number(ctx), t = Number(max);
        if (ctx && Number.isFinite(c) && c > 0) m.contextWindow = c;
        if (max && Number.isFinite(t) && t > 0) m.maxTokens = t;
        return m;
    });
    if (env.PI_APIKEY) entry.apiKey = env.PI_APIKEY; else delete entry.apiKey;
    delete entry.enabled;    // 兼容旧版脚本遗留字段
    delete entry.apiKeyEnv;
    models.providers[key] = entry;
    writeJson(env.PI_MODELS, models);
    const newIds = entry.models.map(mm => mm.id);
    if (env.PI_SET_DEFAULT === "1" && newIds.length > 0) {
        settings.defaultProvider = key;
        settings.defaultModel = newIds[0];
        saveSettings();
    }
} else if (env.PI_OP === "setkey") {
    if (!models.providers[env.PI_KEY]) {
        console.error("provider 不存在: " + env.PI_KEY);
        process.exit(1);
    }
    if (env.PI_APIKEY) models.providers[env.PI_KEY].apiKey = env.PI_APIKEY;
    else delete models.providers[env.PI_KEY].apiKey;
    writeJson(env.PI_MODELS, models);
} else if (env.PI_OP === "delete") {
    delete models.providers[env.PI_KEY];
    writeJson(env.PI_MODELS, models);
    if (settings.defaultProvider === env.PI_KEY) {
        delete settings.defaultProvider;
        delete settings.defaultModel;
        saveSettings();
    }
} else if (env.PI_OP === "defaults") {
    if (env.PI_DEF_PROVIDER && env.PI_DEF_PROVIDER !== "-") {
        settings.defaultProvider = env.PI_DEF_PROVIDER;
        settings.defaultModel = env.PI_DEF_MODEL || "";
    } else {
        delete settings.defaultProvider;
        delete settings.defaultModel;
    }
    saveSettings();
} else if (env.PI_OP === "touch") {
    if (env.PI_VER) settings.lastChangelogVersion = env.PI_VER;
    saveSettings();
} else if (env.PI_OP === "models") {
    const p = models.providers[env.PI_KEY];
    if (!p) { console.error("provider 不存在: " + env.PI_KEY); process.exit(1); }
    for (const mm of (p.models || [])) {
        console.log([mm.id, mm.contextWindow || "-", mm.maxTokens || "-"].join("\t"));
    }
} else if (env.PI_OP === "model_set") {
    const p = models.providers[env.PI_KEY];
    const mm = p && (p.models || []).find(x => x.id === env.PI_MODEL);
    if (!mm) { console.error(`模型不存在: ${env.PI_KEY} / ${env.PI_MODEL}`); process.exit(1); }
    // 值语义：空=不变，0=恢复默认（删除字段），正整数=设置，其他=忽略
    const setOrDel = (obj, field, val) => {
        if (val === "" || val === undefined) return;
        if (val === "0") { delete obj[field]; return; }
        const n = Number(val);
        if (Number.isFinite(n) && n > 0) obj[field] = n;
    };
    setOrDel(mm, "contextWindow", env.PI_CTX);
    setOrDel(mm, "maxTokens", env.PI_MAX);
    writeJson(env.PI_MODELS, models);
    console.log([mm.id, mm.contextWindow || "-", mm.maxTokens || "-"].join("\t"));
} else if (env.PI_OP === "model_add") {
    const p = models.providers[env.PI_KEY];
    if (!p) { console.error("provider 不存在: " + env.PI_KEY); process.exit(1); }
    if ((p.models || []).some(x => x.id === env.PI_MODEL)) {
        console.error(`模型已存在: ${env.PI_MODEL}`); process.exit(1);
    }
    const mm = { id: env.PI_MODEL };
    const setOrDel = (obj, field, val) => {
        if (val === "" || val === undefined) return;
        const n = Number(val);
        if (Number.isFinite(n) && n > 0) obj[field] = n;
    };
    setOrDel(mm, "contextWindow", env.PI_CTX);
    setOrDel(mm, "maxTokens", env.PI_MAX);
    p.models = p.models || [];
    p.models.push(mm);
    writeJson(env.PI_MODELS, models);
    console.log([mm.id, mm.contextWindow || "-", mm.maxTokens || "-"].join("\t"));
} else if (env.PI_OP === "model_del") {
    const p = models.providers[env.PI_KEY];
    if (!p) { console.error("provider 不存在: " + env.PI_KEY); process.exit(1); }
    const before = (p.models || []).length;
    p.models = (p.models || []).filter(x => x.id !== env.PI_MODEL);
    if (p.models.length === before) {
        console.error(`模型不存在: ${env.PI_MODEL}`); process.exit(1);
    }
    writeJson(env.PI_MODELS, models);
    if (settings.defaultProvider === env.PI_KEY && settings.defaultModel === env.PI_MODEL) {
        delete settings.defaultProvider;
        delete settings.defaultModel;
        saveSettings();
    }
} else if (env.PI_OP === "show") {
    console.log(["DEFAULT", settings.defaultProvider || "-", settings.defaultModel || "-"].join("\t"));
    for (const [k, p] of Object.entries(models.providers)) {
        const ids = (p.models || []).map(m => m.id).join(",");
        // 第 5 列是带参数的展示串：glm-5.3[200000/8192]（没设置的参数不显示）
        const disp = (p.models || []).map(m => {
            let s = m.id;
            if (m.contextWindow || m.maxTokens) {
                s += `[${m.contextWindow || ""}${m.maxTokens ? "/" + m.maxTokens : ""}]`;
            }
            return s;
        }).join(", ");
        console.log([k, p.baseUrl || "-", ids || "-", p.apiKey || "-", disp || "-"].join("\t"));
    }
} else {
    console.error("未知 PI_OP: " + env.PI_OP);
    process.exit(1);
}
PIJS
}

# ---------- node 可用性（菜单 3~6 需要；没有就先去菜单 1 安装） ----------
require_node() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # shellcheck disable=SC1091
        . "$NVM_DIR/nvm.sh"
    fi
    if ! command -v node >/dev/null 2>&1; then
        warn "未检测到 Node.js —— 请先执行菜单 1 安装 pi（会一并装好 Node）"
        return 1
    fi
}

# ---------- API Key 仓库（keys.env，600 权限） ----------
key_store_set() {  # $1=环境变量名 $2=值
    mkdir -p "$PI_DIR"
    touch "$PI_KEYS_FILE"
    sed -i "/^export $1=/d" "$PI_KEYS_FILE"
    echo "export $1=$(printf '%q' "$2")" >> "$PI_KEYS_FILE"
    chmod 600 "$PI_KEYS_FILE"
    export "$1=$2"
}

key_store_del() {  # $1=环境变量名
    [ -f "$PI_KEYS_FILE" ] && sed -i "/^export $1=/d" "$PI_KEYS_FILE"
}

# ---------- .bashrc 托管块（加载 keys.env + 每个 provider 一个别名） ----------
rewrite_bashrc_block() {
    touch "$SHELL_RC"
    # 删掉本脚本上次写的托管块（含旧版直接写 export 的格式）
    sed -i "/^${BASHRC_BLOCK_BEGIN//\//\\/}\$/,/^${BASHRC_BLOCK_END//\//\\/}\$/d" "$SHELL_RC"
    # 清理最老版脚本（pi-stepfun-install.sh）遗留的散行
    sed -i '/^export STEPFUN_API_KEY=/d' "$SHELL_RC"
    sed -i '/^export OPENAI_BASE_URL=/d' "$SHELL_RC"
    sed -i "/^alias pi='pi --provider/d" "$SHELL_RC"

    {
        echo "$BASHRC_BLOCK_BEGIN"
        echo "[ -f \"\$HOME/.pi/agent/keys.env\" ] && . \"\$HOME/.pi/agent/keys.env\""
        PI_OP=show pi_json 2>/dev/null | while IFS=$'\t' read -r rk rurl rids rkey; do
            [ "$rk" = "DEFAULT" ] && continue
            [ -n "$rids" ] || continue
            echo "alias pi-${rk}='pi --provider ${rk} --model ${rids%%,*}'"
        done
        echo "$BASHRC_BLOCK_END"
    } >> "$SHELL_RC"
}

# ---------- 供菜单使用的 provider 列表 ----------
provider_rows() {   # 输出非 DEFAULT 的行：key<TAB>baseUrl<TAB>模型<TAB>apiKey
    PI_OP=show pi_json | grep -v '^DEFAULT'
}

current_default() { # 输出 "provider model" 或 "- -"
    PI_OP=show pi_json | head -1 | cut -f2,3
}

# ============================================================
# 菜单 1：安装 / 更新 pi
# ============================================================
load_nvm() {
    export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
    # 必须用 if 而不是 [ -s ... ] && . ...
    # 后者在 nvm.sh 不存在时返回非零，会被 set -e 直接终止
    if [ -s "$NVM_DIR/nvm.sh" ]; then
        # shellcheck disable=SC1091
        . "$NVM_DIR/nvm.sh"
    fi
    return 0
}

install_nvm() {
    info "正在安装 nvm ..."
    local url="https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "$url" | bash
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url" | bash
    else
        fail "无法下载 nvm：缺少 curl 或 wget"
        return 1
    fi
    # nvm 安装脚本会自动往 .bashrc 追加引导块，这里只需加载到当前会话
    load_nvm
}

node_major() {
    node -v 2>/dev/null | sed 's/^v//' | cut -d. -f1 | grep -E '^[0-9]+$' || echo 0
}

install_pi() {
    if ! command -v curl >/dev/null 2>&1; then
        fail "缺少 curl，请先安装：sudo apt-get install -y curl（或对应包管理器）"
        return 1
    fi

    # ---- nvm + Node ----
    load_nvm
    if [ ! -s "$NVM_DIR/nvm.sh" ]; then
        install_nvm
        load_nvm
    fi
    [ -s "$NVM_DIR/nvm.sh" ] || { fail "nvm 不可用：$NVM_DIR/nvm.sh 不存在"; return 1; }

    # 刻意不检查系统 node：系统自带的版本可能很低，不能用
    if [ "$(node_major)" = "$NODE_WANT_MAJOR" ] && command -v nvm >/dev/null 2>&1; then
        info "nvm 当前已是 Node $(node -v)，跳过安装"
    else
        info "正在通过 nvm 安装 Node.js v${NODE_WANT_MAJOR}.x ..."
        nvm install "$NODE_WANT_MAJOR"
    fi
    nvm use "$NODE_WANT_MAJOR" >/dev/null 2>&1 || { fail "无法切换到 nvm 的 Node v${NODE_WANT_MAJOR}"; return 1; }
    nvm alias default "$NODE_WANT_MAJOR" >/dev/null
    info "nvm 默认版本已设为 v${NODE_WANT_MAJOR}.x（新开终端自动生效）"

    local cur
    cur="$(node_major)"
    if [ "$cur" -lt "$NODE_MIN_MAJOR" ]; then
        fail "当前 node 主版本 v${cur} 不满足 >=${NODE_MIN_MAJOR}（nvm 安装失败？）"
        return 1
    fi
    if ! node -v >/dev/null 2>&1; then
        fail "Node 安装后无法运行，可能缺系统依赖。请先执行: sudo apt-get install -y libatomic1"
        return 1
    fi
    info "pi 将使用：$(command -v node) ($(node -v))，系统原有 node 未做任何修改"
    command -v npm >/dev/null 2>&1 || { fail "未检测到 npm"; return 1; }

    # ---- pi 本体 ----
    pi_version_of() {
        pi --version 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1 || true
    }
    if [ "$PI_VERSION" = "latest" ]; then
        local target
        target="$(npm view @earendil-works/pi-coding-agent version 2>/dev/null || true)"
        [ -n "$target" ] || { warn "查不到最新版本号（registry 不可达？），直接装 @latest"; target="latest"; }
        PI_VERSION="$target"
    fi
    local installed=""
    command -v pi >/dev/null 2>&1 && installed="$(pi_version_of)"
    if [ "$installed" = "$PI_VERSION" ]; then
        info "pi 已是 v${PI_VERSION}，跳过安装"
    else
        [ -n "$installed" ] && info "检测到旧版 pi v${installed}，更新到 v${PI_VERSION} ..." \
                              || info "正在安装 pi v${PI_VERSION} ..."
        npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${PI_VERSION}"
    fi
    installed="$(pi_version_of)"; [ -n "$installed" ] || installed="$PI_VERSION"
    info "pi v${installed} 位置: $(command -v pi)"

    # 补写 settings（压首启更新日志弹窗）+ 刷新 bashrc 托管块（顺便做旧格式迁移）
    PI_VER="$installed" PI_OP=touch pi_json
    rewrite_bashrc_block

    # ---- 自检：复现新终端的 PATH 顺序（只 warn 不中断） ----
    local out check_node prefix
    out="$(bash -ic 'which node; which pi' 2>/dev/null || true)"
    check_node="$(echo "$out" | grep -m1 -- '/node$' || true)"
    prefix="${NVM_DIR:-$HOME/.nvm}/versions/node/v${NODE_WANT_MAJOR}"
    if [ -n "$check_node" ] && case "$check_node" in "$prefix"*) true;; *) false;; esac; then
        info "自检通过：新终端的 node 来自 nvm"
    else
        warn "新终端里 node 不是 nvm 的 v${NODE_WANT_MAJOR}（实际: ${check_node:-未找到}）"
        echo "  常见原因：$SHELL_RC 里 nvm 引导块之后还有 export PATH=... 的行把它顶下去了，调整行顺序即可。"
    fi

    echo ""
    info "完成！新开终端（或 source $SHELL_RC）后输入 pi 使用"

    # 首次安装引导：直接进入添加 provider
    local go=""
    read -rp "现在添加一个模型 provider（中转站）? [Y/n]: " go || true
    case "$go" in n|N) ;; *) add_provider ;; esac
}

# ============================================================
# 菜单 2：添加 / 修改 provider
# ============================================================
add_provider() {
    require_node || return 1

    # ---- provider 名 ----
    local pk
    while :; do
        read -rp "provider 名（小写字母/数字/下划线，如 stepfun、myrelay）: " pk || return 1
        if echo "$pk" | grep -qE '^[a-z][a-z0-9_]*$'; then break; fi
        warn "名字不合法，只能用小写字母/数字/下划线，且以字母开头"
    done

    # 已存在则确认覆盖
    if provider_rows | cut -f1 | grep -qx "$pk"; then
        local ow=""
        read -rp "provider '$pk' 已存在，覆盖修改? [y/N]: " ow || true
        case "$ow" in y|Y) ;; *) return 0 ;; esac
    fi

    # ---- baseUrl ----
    local baseurl
    while :; do
        read -rp "baseUrl（如 https://api.stepfun.com/step_plan/v1）: " baseurl || return 1
        [ -n "$baseurl" ] && break
        warn "baseUrl 不能为空"
    done

    # ---- api 类型 ----
    echo "API 类型："
    echo "  1) openai-completions   （绝大多数中转站/OpenAI 兼容端点，默认）"
    echo "  2) openai-responses"
    echo "  3) anthropic-messages   （Claude 系中转）"
    echo "  4) google-generative-ai （Gemini 系中转）"
    local apichoice api="openai-completions"
    read -rp "选择 [1]: " apichoice || true
    case "$apichoice" in
        2) api="openai-responses" ;;
        3) api="anthropic-messages" ;;
        4) api="google-generative-ai" ;;
        *) api="openai-completions" ;;
    esac

    # ---- 模型列表（每个模型可设 上下文窗口 / 最大输出 token） ----
    local models_spec="" mid mctx mmax
    info "输入模型 ID（就是发给 API 的名字，如 step-3.7-flash、gpt-5.2），每行一个，直接回车结束"
    info "每个模型可设置上下文窗口 / 最大输出 token，直接回车用默认（128000 / 16384）"
    while :; do
        read -rp "模型ID: " mid || break
        [ -n "$mid" ] || break
        mctx=""; mmax=""
        read -rp "  $mid 上下文窗口 token（输入+输出总量）[128000]: " mctx || true
        read -rp "  $mid 最大输出 token [16384]: " mmax || true
        case "$mctx" in *[!0-9]*) warn "  上下文输入非数字，按默认处理"; mctx="" ;; esac
        case "$mmax" in *[!0-9]*) warn "  最大输出输入非数字，按默认处理"; mmax="" ;; esac
        models_spec="${models_spec:+$models_spec,}${mid}|${mctx:-}|${mmax:-}"
    done
    [ -n "$models_spec" ] || { warn "至少要有一个模型，已取消"; return 1; }
    local first_id="${models_spec%%,*}"
    first_id="${first_id%%|*}"

    # ---- API Key（可空 = 端点不需要鉴权） ----
    local env_name key_val="" apikey_arg=""
    env_name="$(echo "$pk" | tr 'a-z' 'A-Z')_API_KEY"
    echo ""
    read -rs -p "API Key（存到 $PI_KEYS_FILE，models.json 只记 \$$env_name 引用；无鉴权端点直接回车）: " key_val </dev/tty || true
    echo ""
    if [ -n "$key_val" ]; then
        key_store_set "$env_name" "$key_val"
        apikey_arg="\$${env_name}"
        info "key 已存入 $PI_KEYS_FILE（chmod 600）"
    fi

    # ---- 写入 models.json（首个 provider 自动设为默认） ----
    local setdef=""
    [ "$(current_default | cut -f1)" = "-" ] && setdef=1
    PI_OP=upsert PI_KEY="$pk" PI_BASEURL="$baseurl" PI_API="$api" \
        PI_MODELS_SPEC="$models_spec" PI_APIKEY="$apikey_arg" PI_SET_DEFAULT="$setdef" \
        pi_json || { fail "写入 models.json 失败"; return 1; }
    [ -n "$setdef" ] && info "已设为默认：$pk / ${first_id}"

    rewrite_bashrc_block
    info "provider '$pk' 已保存，别名：pi-${pk}"
    warn "当前终端执行 source $SHELL_RC 后别名和环境变量生效（新开终端自动生效）"
}

# ============================================================
# 菜单 3：查看当前配置
# ============================================================
show_config() {
    require_node || return 1
    if [ ! -s "$PI_MODELS_FILE" ]; then
        warn "还没有任何 provider 配置（$PI_MODELS_FILE 不存在），请先用菜单 2 添加"
        return 0
    fi

    echo ""
    echo -e "${CYAN}================ pi 当前配置 ================${NC}"
    if command -v pi >/dev/null 2>&1; then
        echo " pi 版本  : $(pi --version 2>/dev/null || echo unknown)    node: $(node -v)"
    else
        echo " pi 版本  : 未安装（菜单 1 可安装）    node: $(node -v)"
    fi
    local def_p def_m
    def_p="$(current_default | cut -f1)"; def_m="$(current_default | cut -f2)"
    if [ "$def_p" = "-" ]; then
        echo " 默认模型 : （未设置，pi 启动时需要手动 /model 选择）"
    else
        echo " 默认模型 : $def_p / $def_m"
    fi
    echo ""
    printf " %-14s %-36s %-16s %s\n" "PROVIDER" "BASEURL" "KEY" "MODELS[上下文/最大输出]"
    provider_rows | while IFS=$'\t' read -r rk rurl rids rkey rdisp; do
        local keymark="无"
        if [ "$rkey" != "-" ]; then
            case "$rkey" in
                \$*) keymark="$rkey" ;;
                *)   keymark="字面量" ;;
            esac
        fi
        [ "$rdisp" = "-" ] && rdisp="$rids"
        printf " %-14s %-36s %-16s %s\n" "$rk" "$rurl" "$keymark" "$rdisp"
    done
    echo ""
    echo " 文件：$PI_MODELS_FILE / $PI_SETTINGS_FILE / $PI_KEYS_FILE"
}

# ============================================================
# 菜单 4：切换默认模型
# ============================================================
choose_default() {
    require_node || return 1
    echo ""
    info "选择默认模型："
    # 全程 bash 内建过滤，不依赖 awk（部分环境的 awk 对引号处理有坑）
    local -a keys=() models=() one_models=()
    local n=1 rk rids m sel
    while IFS=$'\t' read -r rk _ rids _; do
        [ -n "$rids" ] && [ "$rids" != "-" ] || continue
        one_models=()
        IFS=',' read -ra one_models <<< "$rids"
        for m in "${one_models[@]}"; do
            [ -n "$m" ] || continue
            echo "  $n) $rk / $m"
            keys+=("$rk")
            models+=("$m")
            n=$((n + 1))
        done
    done < <(provider_rows)
    [ "${#models[@]}" -gt 0 ] || { warn "没有配置任何模型，请先用菜单 2 添加 provider"; return 1; }

    read -rp "输入序号 [1]: " sel || return 1
    case "$sel" in ""|*[!0-9]*) sel=1 ;; esac
    [ "$sel" -ge 1 ] && [ "$sel" -le "${#models[@]}" ] || sel=1

    PI_OP=defaults PI_DEF_PROVIDER="${keys[$((sel - 1))]}" PI_DEF_MODEL="${models[$((sel - 1))]}" pi_json \
        || { fail "写入 settings.json 失败"; return 1; }
    info "默认模型已设为：${keys[$((sel - 1))]} / ${models[$((sel - 1))]}"
}

# ============================================================
# 菜单 5：重设 API Key
# ============================================================
reset_key() {
    require_node || return 1
    local rows
    rows="$(provider_rows)"
    [ -n "$rows" ] || { warn "没有 provider，请先用菜单 2 添加"; return 1; }

    echo ""
    info "给哪个 provider 重设 Key："
    local keys=() n=1 rk
    while IFS=$'\t' read -r rk _; do
        echo "  $n) $rk"
        keys+=("$rk"); n=$((n + 1))
    done <<< "$rows"
    local sel
    read -rp "序号 [1]: " sel || return 1
    case "$sel" in ""|*[!0-9]*) sel=1 ;; esac
    [ "$sel" -ge 1 ] && [ "$sel" -le "${#keys[@]}" ] || sel=1
    local pk="${keys[$((sel - 1))]}"

    local env_name key_val
    env_name="$(echo "$pk" | tr 'a-z' 'A-Z')_API_KEY"
    read -rs -p "$pk 的新 API Key: " key_val </dev/tty || return 1
    echo ""
    [ -n "$key_val" ] || { warn "输入为空，未修改"; return 1; }

    key_store_set "$env_name" "$key_val"
    # 确保 models.json 里是环境变量引用（原来可能是字面量或没写）
    PI_OP=setkey PI_KEY="$pk" PI_APIKEY="\$${env_name}" pi_json || { fail "写入 models.json 失败"; return 1; }
    info "已更新 $PI_KEYS_FILE 中的 $env_name（当前终端需 source $SHELL_RC 生效）"
}

# ============================================================
# 菜单 6：删除 provider
# ============================================================
delete_provider() {
    require_node || return 1
    local rows
    rows="$(provider_rows)"
    [ -n "$rows" ] || { warn "没有 provider 可删"; return 1; }

    echo ""
    info "删除哪个 provider："
    local keys=() n=1 rk
    while IFS=$'\t' read -r rk _; do
        echo "  $n) $rk"
        keys+=("$rk"); n=$((n + 1))
    done <<< "$rows"
    local sel
    read -rp "序号 [1]: " sel || return 1
    case "$sel" in ""|*[!0-9]*) sel=1 ;; esac
    [ "$sel" -ge 1 ] && [ "$sel" -le "${#keys[@]}" ] || sel=1
    local pk="${keys[$((sel - 1))]}"

    local ok=""
    read -rp "确认删除 '$pk'（含它的模型定义）? [y/N]: " ok || true
    case "$ok" in
        y|Y) ;;
        *) return 0 ;;
    esac

    PI_OP=delete PI_KEY="$pk" pi_json || { fail "删除失败"; return 1; }

    local delkey=""
    read -rp "同时删除它的 API Key（$PI_KEYS_FILE 里的一行）? [Y/n]: " delkey || true
    case "$delkey" in
        n|N) ;;
        *) key_store_del "$(echo "$pk" | tr 'a-z' 'A-Z')_API_KEY" ;;
    esac

    rewrite_bashrc_block
    info "已删除 '$pk'；若它原是默认模型，请用菜单 4 重设默认"
}

# ============================================================
# 菜单 7：修改单个模型（参数 / 追加 / 删除，不用重填整个 provider）
# ============================================================
edit_model() {
    require_node || return 1

    # ---- 选 provider（只列有模型的） ----
    echo ""
    info "选择 provider："
    local -a pkeys=()
    local n=1 pk sel rk rids mid mctx mmax act
    while IFS=$'\t' read -r rk _ rids _ _; do
        [ -n "$rids" ] && [ "$rids" != "-" ] || continue
        echo "  $n) $rk（模型: $(echo "$rids" | tr ',' ' ')）"
        pkeys+=("$rk")
        n=$((n + 1))
    done < <(provider_rows)
    [ "${#pkeys[@]}" -gt 0 ] || { warn "没有配置任何模型，请先用菜单 2 添加 provider"; return 1; }
    read -rp "序号 [1]: " sel || return 1
    case "$sel" in ""|*[!0-9]*) sel=1 ;; esac
    [ "$sel" -ge 1 ] && [ "$sel" -le "${#pkeys[@]}" ] || sel=1
    pk="${pkeys[$((sel - 1))]}"

    # ---- 列出该 provider 的模型（含当前参数） ----
    echo ""
    info "'$pk' 的模型："
    local -a mids=()
    n=1
    while IFS=$'\t' read -r mid mctx mmax; do
        [ -n "$mid" ] || continue
        echo "  $n) $mid    上下文=${mctx}  最大输出=${mmax}（- = pi 默认值）"
        mids+=("$mid")
        n=$((n + 1))
    done < <(PI_OP=models PI_KEY="$pk" pi_json)
    [ "${#mids[@]}" -gt 0 ] || { warn "该 provider 没有模型"; return 1; }
    echo "  0) 追加一个新模型"
    read -rp "选择模型序号（0=追加新模型） [0]: " sel || return 1
    case "$sel" in ""|*[!0-9]*) sel=0 ;; esac
    [ "$sel" -le "${#mids[@]}" ] || { warn "序号超出范围"; return 1; }

    # ---- 分支：追加 ----
    if [ "$sel" = "0" ]; then
        mid=""
        while :; do
            read -rp "新模型 ID: " mid || return 1
            [ -n "$mid" ] && break
            warn "模型 ID 不能为空"
        done
        mctx=""; mmax=""
        read -rp "  上下文窗口 token [128000]: " mctx || true
        read -rp "  最大输出 token [16384]: " mmax || true
        case "$mctx" in *[!0-9]*) warn "非数字，按默认处理"; mctx="" ;; esac
        case "$mmax" in *[!0-9]*) warn "非数字，按默认处理"; mmax="" ;; esac
        PI_OP=model_add PI_KEY="$pk" PI_MODEL="$mid" PI_CTX="$mctx" PI_MAX="$mmax" pi_json \
            || { fail "追加失败"; return 1; }
        rewrite_bashrc_block
        info "已追加 $pk / $mid"
        return 0
    fi

    mid="${mids[$((sel - 1))]}"

    # ---- 分支：改参数 / 删除 ----
    echo ""
    echo "  1) 修改参数（上下文 / 最大输出）"
    echo "  2) 删除该模型"
    read -rp "操作 [1]: " act || return 1
    case "$act" in
        2)
            local okdel=""
            read -rp "确认删除 '$pk / $mid' ? [y/N]: " okdel || true
            case "$okdel" in
                y|Y) ;;
                *) return 0 ;;
            esac
            PI_OP=model_del PI_KEY="$pk" PI_MODEL="$mid" pi_json || { fail "删除失败"; return 1; }
            rewrite_bashrc_block
            info "已删除 $pk / $mid"
            warn "如果它原来是默认模型，默认已被清空，请用菜单 4 重设"
            ;;
        *)
            mctx=""; mmax=""
            info "当前值见上表；回车=不变，纯数字=修改，0=恢复 pi 默认（128000/16384）"
            read -rp "上下文窗口: " mctx || true
            read -rp "最大输出: " mmax || true
            case "$mctx" in *[!0-9]*) warn "上下文输入无效，本次不改"; mctx="" ;; esac
            case "$mmax" in *[!0-9]*) warn "最大输出输入无效，本次不改"; mmax="" ;; esac
            if [ -z "$mctx" ] && [ -z "$mmax" ]; then
                info "没有要修改的参数"
                return 0
            fi
            local res rctx rmax
            res="$(PI_OP=model_set PI_KEY="$pk" PI_MODEL="$mid" PI_CTX="$mctx" PI_MAX="$mmax" pi_json)" \
                || { fail "修改失败"; return 1; }
            rewrite_bashrc_block
            IFS=$'\t' read -r _ rctx rmax <<< "$res"
            info "已更新，现在：$mid  上下文=${rctx}  最大输出=${rmax}"
            ;;
    esac
}

# ============================================================
# 菜单 8：卸载（本脚本装过/写过的东西，分块清理）
# 注意各步顺序：全部卸载时先卸 pi（要 npm），最后才动 nvm
# ============================================================
uninstall_pi_pkg() {
    load_nvm
    if command -v pi >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
        info "正在卸载 pi（npm 全局包）..."
        npm uninstall -g @earendil-works/pi-coding-agent
        info "pi 已卸载"
    else
        info "未检测到可卸载的 pi（或 npm 不可用），跳过"
    fi
}

clean_bashrc_block() {
    if [ ! -f "$SHELL_RC" ]; then
        info "$SHELL_RC 不存在，跳过"
        return 0
    fi
    # 托管块（keys.env 加载行 + 别名都在标记内）
    sed -i "/^${BASHRC_BLOCK_BEGIN//\//\\/}\$/,/^${BASHRC_BLOCK_END//\//\\/}\$/d" "$SHELL_RC"
    # 最老版脚本（pi-stepfun-install.sh）的散行
    sed -i '/^export STEPFUN_API_KEY=/d' "$SHELL_RC"
    sed -i '/^export OPENAI_BASE_URL=/d' "$SHELL_RC"
    sed -i "/^alias pi='pi --provider/d" "$SHELL_RC"
    info ".bashrc 托管块及旧版残留已清理"
}

remove_pi_data() {
    if [ ! -d "$HOME/.pi" ]; then
        info "~/.pi 不存在，跳过"
        return 0
    fi
    echo "  1) 全部删除 ~/.pi（配置 + Key + 登录状态 + 会话历史）"
    echo "  2) 只删本工具写的配置（models/settings/keys/trust/auth），保留会话历史"
    local c=""
    read -rp "选择 [2]: " c || return 0
    case "$c" in
        1)
            rm -rf "$HOME/.pi"
            info "~/.pi 已整体删除"
            ;;
        *)
            rm -f "$PI_MODELS_FILE" "$PI_SETTINGS_FILE" "$PI_KEYS_FILE" \
                  "$PI_DIR/trust.json" "$PI_DIR/auth.json"
            info "配置文件已删除（会话历史保留在 ~/.pi）"
            ;;
    esac
}

uninstall_node() {
    load_nvm
    command -v nvm >/dev/null 2>&1 || { info "nvm 不可用，跳过"; return 0; }
    [ -d "${NVM_DIR:-$HOME/.nvm}/versions/node" ] || { info "没有 nvm 安装的 Node，跳过"; return 0; }
    # 只动本脚本管理的主版本（默认 24），用户 nvm 里其他版本不碰
    local vers v
    vers="$(ls "${NVM_DIR:-$HOME/.nvm}/versions/node" | grep "^v${NODE_WANT_MAJOR}\." || true)"
    [ -n "$vers" ] || { info "没有 v${NODE_WANT_MAJOR}.x 的 Node，跳过"; return 0; }
    warn "将卸载 Node：$(echo "$vers" | tr '\n' ' ')（装在它下面的全局 npm 包会一并消失）"
    nvm deactivate >/dev/null 2>&1 || true
    for v in $vers; do
        nvm uninstall "${v#v}" >/dev/null 2>&1 \
            || nvm uninstall "$v" >/dev/null 2>&1 \
            || warn "卸载 $v 失败，请手动执行: nvm uninstall ${v#v}"
    done
    # default 别名指向本脚本装的版本时才清除，指向其他版本则保留
    if nvm alias default 2>/dev/null | grep -q "v${NODE_WANT_MAJOR}\."; then
        nvm unalias default >/dev/null 2>&1 || true
        info "nvm default 别名已清除"
    fi
    info "Node v${NODE_WANT_MAJOR}.x 已卸载（当前终端 PATH 有残留，新开终端即正常）"
}

uninstall_nvm() {
    if [ ! -d "$HOME/.nvm" ]; then
        info "~/.nvm 不存在，跳过"
        return 0
    fi
    warn "将删除整个 ~/.nvm（含其中所有 Node 版本与全部全局 npm 包）"
    local ok=""
    read -rp "确认? [y/N]: " ok || true
    case "$ok" in
        y|Y) ;;
        *)   info "已跳过"; return 0 ;;
    esac
    rm -rf "$HOME/.nvm"
    if [ -f "$SHELL_RC" ]; then
        # 清掉 nvm 官方安装器写进 .bashrc 的三行引导
        sed -i '/^export NVM_DIR=/d' "$SHELL_RC"
        sed -i "/\$NVM_DIR\/nvm\.sh/d" "$SHELL_RC"
        sed -i "/\$NVM_DIR\/bash_completion/d" "$SHELL_RC"
    fi
    info "nvm 已卸载（.bashrc 引导行已清理）"
}

uninstall_all() {
    echo "将依次执行："
    echo "  1) 卸载 pi（npm 全局包）"
    echo "  2) 清理 .bashrc（托管块 + 旧版残留）"
    echo "  3) 删除 pi 配置与数据（会再问范围）"
    echo "  4) 卸载 Node v${NODE_WANT_MAJOR}.x（仅本脚本装的版本）"
    echo "  5) 卸载 nvm 本体（~/.nvm + 引导行）"
    local ok=""
    read -rp "确认全部卸载? [y/N]: " ok || true
    case "$ok" in
        y|Y) ;;
        *)   return 0 ;;
    esac
    uninstall_pi_pkg || true
    clean_bashrc_block || true
    remove_pi_data || true
    uninstall_node || true
    uninstall_nvm || true
    info "卸载完成。当前终端的环境变量会有残留，退出重新登录即彻底干净"
}

uninstall_menu() {
    echo ""
    info "卸载向导（本脚本装过/写过的东西，分块清理，系统原有内容不受影响）"
    echo "  a) 全部卸载（pi + .bashrc 痕迹 + 配置数据 + Node + nvm）"
    echo "  1) 只卸载 pi 本体（npm 包）"
    echo "  2) 只清理 .bashrc（托管块/旧版残留）"
    echo "  3) 只删 pi 配置与数据"
    echo "  4) 只卸载 Node v${NODE_WANT_MAJOR}.x"
    echo "  5) 只卸载 nvm 本体"
    echo "  0) 取消"
    local c=""
    read -rp "选择 [0]: " c || return 0
    case "$c" in
        a|A) uninstall_all || true ;;
        1)   uninstall_pi_pkg || true ;;
        2)   clean_bashrc_block || true ;;
        3)   remove_pi_data || true ;;
        4)   uninstall_node || true ;;
        5)   uninstall_nvm || true ;;
        *)   ;;
    esac
}

# ============================================================
# 主菜单
# ============================================================
main_menu() {
    while :; do
        echo ""
        echo -e "${CYAN}=============================================${NC}"
        echo -e "${CYAN}  pi 管理器（安装 · 中转站 · 模型切换）${NC}"
        echo -e "${CYAN}=============================================${NC}"
        echo "  1) 安装 / 更新 pi"
        echo "  2) 添加 / 修改 provider（baseUrl、模型、API Key）"
        echo "  3) 查看当前配置和默认模型"
        echo "  4) 切换默认模型"
        echo "  5) 重设 API Key"
        echo "  6) 删除 provider"
        echo "  7) 修改单个模型（参数 / 追加 / 删除）"
        echo "  8) 卸载（pi / Node / nvm / 配置）"
        echo "  0) 退出"
        local status=""
        if command -v pi >/dev/null 2>&1; then
            status="pi $(pi --version 2>/dev/null || echo '')"
        else
            status="pi 未安装"
        fi
        echo -e "  状态: ${status}"
        echo -e "${CYAN}---------------------------------------------${NC}"
        local ch=""
        read -rp "选择> " ch || exit 0
        case "$ch" in
            1) install_pi || true ;;
            2) add_provider || true ;;
            3) show_config || true ;;
            4) choose_default || true ;;
            5) reset_key || true ;;
            6) delete_provider || true ;;
            7) edit_model || true ;;
            8) uninstall_menu || true ;;
            0|q|Q) exit 0 ;;
            *) ;;
        esac
    done
}

main_menu
