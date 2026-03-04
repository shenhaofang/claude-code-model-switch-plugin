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
# 切换后待恢复标记文件：记录切换后的配置名，idle_prompt 时读取并输出恢复指令
PENDING_RESUME_FILE="$HOME/.claude/model-switch.resume"
# 各配置失败计数文件：每个配置失败 >= MAX_FAILS 次后跳过，所有配置都跳过时停止
FAILS_FILE="$HOME/.claude/model-switch.fails"
MAX_FAILS=2
# 记录上次重置时对应的进程启动时间，进程更换后触发重置
PROC_STAMP_FILE="$HOME/.claude/model-switch.proc"

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
# 参数：$1=models_file $2=settings_file $3=跳过的配置名列表（逗号分隔，失败次数已满的）
# stdout: "name\turl\tmodel"，或 "SKIP"（无可用配置）, 或 "CURRENT:name"（返回当前配置名）
_do_switch() {
    local skip_names="${1:-}"
    python3 - "$MODELS_FILE" "$SETTINGS_FILE" "$skip_names" <<'PYEOF'
import sys, json

models_file, settings_file, skip_names_str = sys.argv[1], sys.argv[2], sys.argv[3]
skip_names = set(n.strip() for n in skip_names_str.split(',') if n.strip())

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
current_name = None
for i, m in enumerate(models):
    if m.get('api_key') == current_token and m.get('api_base_url') == current_url:
        current_idx = i
        current_name = m.get('name', f'config-{i}')
        break

# 找下一个未跳过的配置
next_idx = None
start = 0 if current_idx is None else (current_idx + 1) % total
for offset in range(total):
    idx = (start + offset) % total
    if idx == current_idx:
        continue
    m = models[idx]
    name = m.get('name', f'config-{idx}')
    if name not in skip_names:
        next_idx = idx
        break

if next_idx is None:
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

# 同时输出当前配置名（供调用方记录失败）
print(f"CURRENT:{current_name}")
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

# 失败计数：session_key=transcript md5，config_name=配置名
# fails 文件格式：session_key:config_name=count
_fail_key() { echo "${1}:${2}"; }

_get_fail_count() {
    local key
    key=$(_fail_key "$1" "$2")
    grep "^${key}=" "$FAILS_FILE" 2>/dev/null | cut -d= -f2 || echo 0
}

_inc_fail_count() {
    local key count
    key=$(_fail_key "$1" "$2")
    count=$(_get_fail_count "$1" "$2")
    count=$(( count + 1 ))
    if [[ -f "$FAILS_FILE" ]]; then
        grep -v "^${key}=" "$FAILS_FILE" > "${FAILS_FILE}.tmp" 2>/dev/null || true
        mv "${FAILS_FILE}.tmp" "$FAILS_FILE"
    fi
    echo "${key}=${count}" >> "$FAILS_FILE"
    echo "$count"
}

# 清除本 session 的所有失败计数（切换成功或进程重启时调用）
_reset_fail_counts() {
    local session_key="$1"
    if [[ -f "$FAILS_FILE" ]]; then
        grep -v "^${session_key}:" "$FAILS_FILE" > "${FAILS_FILE}.tmp" 2>/dev/null || true
        mv "${FAILS_FILE}.tmp" "$FAILS_FILE"
    fi
}

# 检测 Claude Code 进程是否重启过，是则重置所有失败计数
# 用 $PPID 获取父进程（Claude Code）的启动时间作为唯一标识
_check_proc_reset() {
    local session_key="$1"
    local current_stamp
    current_stamp=$(ps -o lstart= -p "$PPID" 2>/dev/null | tr -s ' ' | sed 's/^ //' || echo "")
    if [[ -z "$current_stamp" ]]; then
        return  # 获取失败，跳过
    fi
    local saved_stamp=""
    if [[ -f "$PROC_STAMP_FILE" ]]; then
        saved_stamp=$(cat "$PROC_STAMP_FILE" 2>/dev/null || echo "")
    fi
    if [[ "$current_stamp" != "$saved_stamp" ]]; then
        _log "检测到进程重启（${saved_stamp:-首次} → ${current_stamp}），重置失败计数"
        _reset_fail_counts "$session_key"
        echo "$current_stamp" > "$PROC_STAMP_FILE"
    fi
}

# Stop hook 输出 {"decision":"block","reason":"..."} 阻止 Claude 停止并触发继续执行
# 参考: https://docs.anthropic.com/en/docs/claude-code/hooks#stop-decision-control
_request_resume() {
    local name="$1"
    local reason="API 认证错误，已自动切换到备用模型配置「${name}」，请继续执行被中断的任务。"
    python3 -c "import json, sys; print(json.dumps({'decision': 'block', 'reason': sys.argv[1]}))" "$reason"
}

# ── Stop hook：扫描 transcript 中新出现的 401/403 错误 ──────────────────────
handle_stop() {
    local input="$1"

    # stop_hook_active 为 true 时，Claude 已在因 stop hook 继续执行中
    # 此时若冷却期未过，直接放行（让 Claude 正常停止），防止无限循环
    local stop_hook_active transcript_path
    # 每个字段单独一行，避免 read -r 按空格分割路径
    local _py_out
    _py_out=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
    active = 'true' if d.get('stop_hook_active') else 'false'
    path = d.get('transcript_path', '')
    print(active)
    print(path)
except Exception:
    print('false')
    print('')
" <<< "$input")
    stop_hook_active=$(echo "$_py_out" | sed -n '1p')
    transcript_path=$(echo "$_py_out" | sed -n '2p')

    if [[ -z "$transcript_path" || ! -f "$transcript_path" ]]; then
        _log "Stop hook: transcript 不可用，跳过"
        return
    fi

    # 读取上次扫描到的行数
    local state_key
    state_key=$(python3 -c "import hashlib, sys; print(hashlib.md5(sys.argv[1].encode()).hexdigest())" "$transcript_path")

    # 进程重启检测：Claude Code 重启（含 -c 续接）后重置失败计数
    _check_proc_reset "$state_key"

    local last_line=0
    if [[ -f "$STATE_FILE" ]]; then
        last_line=$(grep "^${state_key}=" "$STATE_FILE" 2>/dev/null | cut -d= -f2 | tr -d ' ' || echo 0)
    fi

    local total_lines
    total_lines=$(wc -l < "$transcript_path")

    # 扫描新增行：仅检测 type=system 的结构化记录
    # 匹配条件：
    #   1. subtype=api_error 且 error/cause.status 为 401/403（结构化）
    #   2. type=system 的行中含 access_denied_error / quota 等关键字（非结构化 system 消息兜底）
    # 跳过 type=assistant/human 的对话内容，防止讨论代码时误报
    local found_error
    found_error=$(python3 - "$transcript_path" "$last_line" <<'PYEOF'
import sys, json, re

transcript_path = sys.argv[1]
last_line = int(sys.argv[2])

# type=system 行：文本兜底匹配（access_denied_error 等语义明确的词）
SYSTEM_TEXT_PAT = re.compile(
    r'(access.denied.error|daily.quota.exceeded|quota.exceeded'
    r'|invalid.*(api.?key|token)|token.*(expired|invalid|exhausted))',
    re.IGNORECASE
)
# type=assistant 行：只匹配极精确的 API 错误消息格式，防止讨论代码时误报
# 格式：'API Error: 4xx {..."type":"access_denied_error"...}'
ASSISTANT_TEXT_PAT = re.compile(
    r'API\s+Error:\s*4\d\d\b.*"type"\s*:\s*"(access_denied_error|authentication_error|permission_error)"',
    re.IGNORECASE
)

with open(transcript_path, 'r', encoding='utf-8') as f:
    lines = f.readlines()

for raw in lines[last_line:]:
    line = raw.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    row_type = d.get('type')
    if row_type == 'system':
        # 结构化：subtype=api_error 且 status 401/403
        if (d.get('subtype') == 'api_error'
                and (d.get('error') or d.get('cause') or {}).get('status') in (401, 403)):
            print("YES")
            sys.exit(0)
        # 文本兜底：system 行中含精确错误关键字
        if SYSTEM_TEXT_PAT.search(line):
            print("YES")
            sys.exit(0)
    elif row_type == 'assistant':
        # assistant 行：只匹配 "API Error: 4xx {...type: access_denied_error...}" 格式
        # 提取实际文本内容后匹配，避免 JSON key 名称干扰
        content = str(d.get('message', {}).get('content', '') or d.get('content', ''))
        if ASSISTANT_TEXT_PAT.search(content):
            print("YES")
            sys.exit(0)

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

    _log "Stop hook: transcript 检测到 API 错误，触发自动切换"

    # 统计本 session 中失败次数已满的配置名，传给 _do_switch 跳过
    local skip_names=""
    if [[ -f "$FAILS_FILE" ]]; then
        skip_names=$(grep "^${state_key}:" "$FAILS_FILE" 2>/dev/null \
            | awk -F'[=:]' -v max="$MAX_FAILS" '$3 >= max {print $2}' \
            | paste -sd, -)
    fi
    _log "跳过失败配置: ${skip_names:-（无）}"

    local switch_out
    switch_out=$(_do_switch "$skip_names")

    # 提取当前配置名（记录失败）和切换结果
    local current_name result
    current_name=$(echo "$switch_out" | grep '^CURRENT:' | cut -d: -f2-)
    result=$(echo "$switch_out" | grep -v '^CURRENT:')

    # 当前配置失败计数 +1
    if [[ -n "$current_name" ]]; then
        local fail_count
        fail_count=$(_inc_fail_count "$state_key" "$current_name")
        _log "配置 ${current_name} 失败次数: ${fail_count}/${MAX_FAILS}"
    fi

    if [[ "$result" == "SKIP" ]]; then
        _log "所有配置均已失败 ${MAX_FAILS} 次，停止自动切换"
        echo "⚠️  [model-switch] 所有备用配置均不可用，请手动处理。" >&2
        return
    fi

    local name url model
    name=$(echo "$result"  | cut -f1)
    url=$(echo "$result"   | cut -f2)
    model=$(echo "$result" | cut -f3)

    _log "已自动切换到: name=$name url=$url model=$model"

    # 切换成功，重置本 session 所有失败计数
    _reset_fail_counts "$state_key"

    # 切换成功后将 state 推进到 transcript 最新行数
    # 避免下次 stop hook 重新扫描到刚才的历史错误行再次触发切换
    local new_total
    new_total=$(wc -l < "$transcript_path")
    if [[ -f "$STATE_FILE" ]]; then
        grep -v "^${state_key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" 2>/dev/null || true
        mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
    echo "${state_key}=${new_total}" >> "$STATE_FILE"
    _log "State 已推进至第 ${new_total} 行，跳过历史错误记录"

    _notify_user "$name" "$url" "$model"

    # 等待 Claude Code 重新加载 settings.json，再输出 block 续接指令
    # 若不等待，block 触发的下一次请求仍用旧配置
    sleep 2
    _request_resume "$name"
}

# ── Notification hook：兜底检测认证错误 + idle_prompt 时恢复被中断的任务 ────
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

    # idle_prompt：Claude 正在等待用户输入，检查是否有待恢复的中断任务
    if [[ "$notification_type" == "idle_prompt" ]]; then
        if [[ -f "$PENDING_RESUME_FILE" ]]; then
            local resume_name
            resume_name=$(cat "$PENDING_RESUME_FILE" 2>/dev/null || echo "备用配置")
            rm -f "$PENDING_RESUME_FILE"
            _log "idle_prompt: 检测到待恢复任务，输出续接指令（配置: $resume_name）"
            local reason="API 认证错误，已自动切换到备用模型配置「${resume_name}」，请继续执行被中断的任务。"
            python3 -c "import json, sys; print(json.dumps({'decision': 'block', 'reason': sys.argv[1]}))" "$reason"
        fi
        return
    fi

    if ! echo "$message" | grep -qiE \
        '(401|403|forbidden|unauthorized|authentication|invalid.*(api.?key|token)|token.*(expired|invalid|exhausted))'; then
        return
    fi

    _log "Notification hook: 检测到认证错误关键字，触发自动切换"

    local switch_out result
    switch_out=$(_do_switch "")
    result=$(echo "$switch_out" | grep -v '^CURRENT:')

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
    _request_resume "$name"
}

# ── 主入口：根据 hook_event_name 分发 ────────────────────────────────────────
main() {
    local input
    input=$(cat)

    _log "Hook 触发, input_length=${#input}"

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
        *)            _log "未知事件: ${event}, 跳过" ;;
    esac
}

main
