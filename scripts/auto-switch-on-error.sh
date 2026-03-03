#!/usr/bin/env bash
# auto-switch-on-error.sh
#
# Claude Code 自动切换模型配置 hook
#
# 触发时机:
#   - Stop hook:         每次 Claude 回复结束时，从 transcript 检测 api_error
#   - Notification hook: 兜底，检测通知消息中的错误关键字
#
# 触发条件: transcript 中出现 status 401/403 的 api_error 记录
#
# 配置文件查找顺序（CLAUDE_MODELS_FILE 环境变量可覆盖）:
#   1. $CLAUDE_MODELS_FILE
#   2. $HOME/.claude/claude-models.json
#
# 日志: $HOME/.claude/model-switch.log
# 状态: $HOME/.claude/model-switch.state （记录已扫描的 transcript 行数）

set -uo pipefail

SETTINGS_FILE="$HOME/.claude/settings.json"
LOG_FILE="$HOME/.claude/model-switch.log"
STATE_FILE="$HOME/.claude/model-switch.state"

# 配置文件查找
if [[ -n "${CLAUDE_MODELS_FILE:-}" && -f "$CLAUDE_MODELS_FILE" ]]; then
    MODELS_FILE="$CLAUDE_MODELS_FILE"
elif [[ -f "$HOME/.claude/claude-models.json" ]]; then
    MODELS_FILE="$HOME/.claude/claude-models.json"
else
    # 找不到配置文件，静默退出
    exit 0
fi

_log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$LOG_FILE"
    # 超过 200 行则裁剪
    local lines
    lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [[ $lines -gt 200 ]]; then
        tail -200 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

# 轮换到下一个配置，写入 settings.json
# stdout: "name\turl\tmodel"，或 "SKIP"（无法切换时）
_do_switch() {
    python3 - "$MODELS_FILE" "$SETTINGS_FILE" <<'PYEOF'
import sys, json

models_file, settings_file = sys.argv[1], sys.argv[2]

try:
    with open(models_file, 'r', encoding='utf-8') as f:
        models = json.load(f)
    with open(settings_file, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception as e:
    print(f"ERROR:{e}", file=sys.stderr)
    sys.exit(1)

env = data.get('env', {})
current_token = env.get('ANTHROPIC_AUTH_TOKEN', '')
current_url   = env.get('ANTHROPIC_BASE_URL', '')

total = len(models)
if total <= 1:
    print("SKIP")
    sys.exit(0)

current_idx = None
for i, m in enumerate(models):
    if m.get('api_key') == current_token and m.get('api_base_url') == current_url:
        current_idx = i
        break

next_idx = 0 if current_idx is None else (current_idx + 1) % total

if next_idx == current_idx:
    print("SKIP")
    sys.exit(0)

m = models[next_idx]
name     = m.get('name', f'config-{next_idx}')
api_key  = m.get('api_key', '')
base_url = m.get('api_base_url', '')
model    = m.get('default_model', '')

if 'env' not in data:
    data['env'] = {}
data['env']['ANTHROPIC_AUTH_TOKEN'] = api_key
data['env']['ANTHROPIC_BASE_URL']   = base_url
data['env']['ANTHROPIC_MODEL']      = model

with open(settings_file, 'w', encoding='utf-8') as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write('\n')

print(f"{name}\t{base_url}\t{model}")
PYEOF
}

_notify_user() {
    local name="$1" url="$2" model="$3"
    echo "" >&2
    echo "🔄 [model-switch] 检测到 API 认证错误，已自动切换 → ${name}" >&2
    echo "   API URL : ${url}" >&2
    echo "   模型    : ${model}" >&2
    echo "" >&2
}

# ── Stop hook：扫描 transcript 中新出现的 401/403 错误 ──────────────────────
handle_stop() {
    local input="$1"

    local transcript_path
    transcript_path=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('transcript_path', ''))
except Exception:
    print('')
" <<< "$input")

    if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
        _log "Stop hook: transcript 不可用，跳过"
        return
    fi

    # 读取上次扫描到的行数
    local state_key
    state_key=$(python3 -c "import hashlib, sys; print(hashlib.md5(sys.argv[1].encode()).hexdigest())" "$transcript_path")
    local last_line=0
    if [[ -f "$STATE_FILE" ]]; then
        last_line=$(grep "^${state_key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 || echo 0)
    fi

    local total_lines
    total_lines=$(wc -l < "$transcript_path")

    # 扫描新增行，找 status 401/403 的 api_error
    local found_error
    found_error=$(python3 - "$transcript_path" "$last_line" <<'PYEOF'
import sys, json

transcript_path = sys.argv[1]
last_line = int(sys.argv[2])

with open(transcript_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

for line in lines[last_line:]:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
        if (d.get('type') == 'system'
                and d.get('subtype') == 'api_error'
                and d.get('error', {}).get('status') in (401, 403)):
            print("YES")
            sys.exit(0)
    except Exception:
        pass

print("NO")
PYEOF
)

    # 更新已扫描行数
    if [[ -f "$STATE_FILE" ]]; then
        grep -v "^${state_key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    echo "${state_key}=${total_lines}" >> "$STATE_FILE"

    if [[ "$found_error" != "YES" ]]; then
        return
    fi

    _log "Stop hook: transcript 检测到 401/403 api_error，触发自动切换"
    local result
    result=$(_do_switch)

    if [[ "$result" == "SKIP" ]]; then
        _log "没有其他可用配置，无法自动切换"
        echo "⚠️  [model-switch] 检测到 API 认证错误，但没有其他可用配置，请手动处理。" >&2
        return
    fi

    local name url model
    name=$(echo "$result"  | cut -f1)
    url=$(echo "$result"   | cut -f2)
    model=$(echo "$result" | cut -f3)

    _log "已自动切换到: name=$name url=$url model=$model"
    _notify_user "$name" "$url" "$model"
}

# ── Notification hook：兜底，检测通知消息关键字 ─────────────────────────────
handle_notification() {
    local input="$1"

    local message notification_type
    message=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('message', ''))
except Exception:
    print('')
" <<< "$input")

    notification_type=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('notification_type', ''))
except Exception:
    print('')
" <<< "$input")

    _log "Notification: type=$notification_type message=${message:0:100}"

    if ! echo "$message" | grep -qiE \
        '(401|403|forbidden|unauthorized|authentication|invalid.*(api.?key|token)|token.*(expired|invalid|exhausted))'; then
        return
    fi

    _log "Notification hook: 检测到认证错误关键字，触发自动切换"
    local result
    result=$(_do_switch)

    if [[ "$result" == "SKIP" ]]; then
        _log "没有其他可用配置，无法自动切换"
        return
    fi

    local name url model
    name=$(echo "$result"  | cut -f1)
    url=$(echo "$result"   | cut -f2)
    model=$(echo "$result" | cut -f3)

    _log "已自动切换到: name=$name url=$url model=$model"
    _notify_user "$name" "$url" "$model"
}

# ── 主入口：根据 hook_event_name 分发 ────────────────────────────────────────
main() {
    local input
    input=$(cat)

    local event
    event=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    print(d.get('hook_event_name', ''))
except Exception:
    print('')
" <<< "$input")

    case "$event" in
        Stop)         handle_stop "$input" ;;
        Notification) handle_notification "$input" ;;
        *)            _log "未知事件: $event，跳过" ;;
    esac
}

main
