#!/usr/bin/env bash
# switch-model.sh — 交互式 Claude Code 模型配置切换脚本
#
# 用法:
#   直接运行（交互模式）: ./scripts/switch-model.sh
#   非交互模式:          ./scripts/switch-model.sh [序号或配置名]
#
# 配置文件查找顺序:
#   1. $CLAUDE_MODELS_FILE 环境变量
#   2. $HOME/.claude/claude-models.json

set -euo pipefail

SETTINGS_FILE="$HOME/.claude/settings.json"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

# 检查依赖
if ! command -v python3 &>/dev/null; then
    echo -e "${RED}错误: 缺少依赖 'python3'，请先安装。${RESET}" >&2
    exit 1
fi

# 配置文件查找
if [[ -n "${CLAUDE_MODELS_FILE:-}" && -f "$CLAUDE_MODELS_FILE" ]]; then
    MODELS_FILE="$CLAUDE_MODELS_FILE"
elif [[ -f "$HOME/.claude/claude-models.json" ]]; then
    MODELS_FILE="$HOME/.claude/claude-models.json"
else
    echo -e "${RED}错误: 找不到模型配置文件。" >&2
    echo -e "请将配置文件放置于 \$HOME/.claude/claude-models.json，" >&2
    echo -e "或通过 CLAUDE_MODELS_FILE 环境变量指定路径。${RESET}" >&2
    exit 1
fi

if [[ ! -f "$SETTINGS_FILE" ]]; then
    echo -e "${RED}错误: Claude 设置文件不存在: $SETTINGS_FILE${RESET}" >&2
    exit 1
fi

# 使用 python3 读取所有数据，输出为 tab 分隔行
_read_data() {
    python3 - "$MODELS_FILE" "$SETTINGS_FILE" <<'PYEOF'
import sys, json

models_file, settings_file = sys.argv[1], sys.argv[2]

with open(models_file, 'r', encoding='utf-8') as f:
    models = json.load(f)

with open(settings_file, 'r', encoding='utf-8') as f:
    settings = json.load(f)

env = settings.get('env', {})
current_token = env.get('ANTHROPIC_AUTH_TOKEN', '')
current_url   = env.get('ANTHROPIC_BASE_URL', '')

# 第一行：当前激活的 token 和 url
print(f"{current_token}\t{current_url}")

# 后续行：每条模型配置
for m in models:
    name  = m.get('name', '')
    model = m.get('default_model', '')
    key   = m.get('api_key', '')
    url   = m.get('api_base_url', '')
    print(f"{name}\t{model}\t{key}\t{url}")
PYEOF
}

# 解析数据
_data=$(_read_data)
current_token=$(echo "$_data" | head -1 | cut -f1)
current_url=$(echo "$_data"   | head -1 | cut -f2)

declare -a CFG_NAMES CFG_MODELS CFG_KEYS CFG_URLS

while IFS=$'\t' read -r name model key url; do
    CFG_NAMES+=("$name")
    CFG_MODELS+=("$model")
    CFG_KEYS+=("$key")
    CFG_URLS+=("$url")
done < <(echo "$_data" | tail -n +2)

total=${#CFG_NAMES[@]}

if [[ $total -eq 0 ]]; then
    echo -e "${RED}错误: 配置文件中没有任何配置项。${RESET}" >&2
    exit 1
fi

# 打印配置列表
print_list() {
    echo ""
    echo -e "${BOLD}可用的 Claude Code 模型配置:${RESET}"
    printf "${CYAN}%-4s  %-22s  %-32s  %-22s  %s${RESET}\n" \
        "序号" "名称" "API URL" "模型" "状态"
    echo -e "${CYAN}$(printf '%.0s─' {1..90})${RESET}"

    for i in "${!CFG_NAMES[@]}"; do
        local num=$((i + 1))
        local name="${CFG_NAMES[$i]}"
        local url="${CFG_URLS[$i]}"
        local model="${CFG_MODELS[$i]}"
        local key="${CFG_KEYS[$i]}"

        if [[ "$key" == "$current_token" && "$url" == "$current_url" ]]; then
            printf "${GREEN}%-4s  %-22s  %-32s  %-22s${RESET}  ${GREEN}● 当前使用${RESET}\n" \
                "$num" "$name" "$url" "$model"
        else
            printf "%-4s  %-22s  %-32s  %-22s\n" \
                "$num" "$name" "$url" "$model"
        fi
    done
    echo ""
}

# 应用配置
apply_config() {
    local idx=$1
    local name="${CFG_NAMES[$idx]}"
    local key="${CFG_KEYS[$idx]}"
    local url="${CFG_URLS[$idx]}"
    local model="${CFG_MODELS[$idx]}"

    echo -e "${YELLOW}正在切换到配置: ${BOLD}$name${RESET}"

    python3 - "$SETTINGS_FILE" "$key" "$url" "$model" <<'PYEOF'
import sys, json

settings_file, api_key, base_url, model_name = sys.argv[1:]

with open(settings_file, 'r', encoding='utf-8') as f:
    data = json.load(f)

if 'env' not in data:
    data['env'] = {}

data['env']['ANTHROPIC_AUTH_TOKEN'] = api_key
data['env']['ANTHROPIC_BASE_URL']   = base_url
data['env']['ANTHROPIC_MODEL']      = model_name

with open(settings_file, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')
PYEOF

    echo -e "${GREEN}✓ 已切换到: ${BOLD}$name${RESET}"
    echo -e "  API URL : ${CYAN}$url${RESET}"
    echo -e "  模型    : ${CYAN}$model${RESET}"
    echo -e "  Token   : ${CYAN}${key:0:14}...${RESET}"
    echo ""
    echo -e "${YELLOW}提示: 重启 Claude Code 后生效。${RESET}"
}

# 解析用户输入 → 返回索引
resolve_input() {
    local input="$1"

    if [[ "$input" =~ ^[0-9]+$ ]]; then
        local idx=$((input - 1))
        if [[ $idx -ge 0 && $idx -lt $total ]]; then
            echo "$idx"
            return
        fi
        echo -e "${RED}错误: 序号 $input 超出范围 (1-$total)${RESET}" >&2
        return 1
    fi

    for i in "${!CFG_NAMES[@]}"; do
        if [[ "${CFG_NAMES[$i]}" == "$input" ]]; then
            echo "$i"
            return
        fi
    done

    echo -e "${RED}错误: 找不到名称为 '$input' 的配置。${RESET}" >&2
    return 1
}

# 主流程
main() {
    print_list

    if [[ $# -ge 1 ]]; then
        local idx
        idx=$(resolve_input "$1")
        apply_config "$idx"
        return
    fi

    while true; do
        echo -n -e "${BOLD}请输入序号或配置名称 (q 退出): ${RESET}"
        read -r input </dev/tty

        case "$input" in
            q|Q|quit|exit)
                echo "已取消。"
                exit 0
                ;;
            "")
                continue
                ;;
            *)
                local idx
                if idx=$(resolve_input "$input" 2>/dev/null); then
                    apply_config "$idx"
                    break
                else
                    resolve_input "$input" 2>&1 || true
                fi
                ;;
        esac
    done
}

main "$@"
