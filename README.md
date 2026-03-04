# model-switch — Claude Code Plugin

自动在 API 认证失败（401/403）时切换模型配置，**自动恢复被中断的任务**，并提供交互式手动切换功能。

## 功能

- **自动切换**：检测到 API 返回 401/403 错误（含 `access_denied_error` 配额超限）时，自动轮换到下一个配置
- **自动恢复**：切换配置后自动向 Claude 发送继续指令，无需手动干预即可恢复中断的任务
- **链式切换**：当前配置失败后依次尝试所有备用配置，每个配置最多失败 2 次后跳过
- **防无限循环**：所有配置均失败 2 次后停止切换，提示手动处理
- **自动重置**：Claude Code 进程重启（含 `claude -c` 续接）后自动重置失败计数
- **手动切换**：通过 `/model-switch:switch` skill 或直接运行脚本进行交互式切换
- **状态查看**：通过 `/model-switch:status` skill 查看当前配置和切换日志

## 安装

### 方式一：通过 Marketplace 安装（推荐）

**第一步：添加 Marketplace**

在 Claude Code 中执行：

```
/plugin marketplace add shenhaofang/claude-code-model-switch-plugin
```

**第二步：安装 Plugin**

```
/plugin install model-switch@model-switch
```

**第三步：准备配置文件**

将配置文件放置到 `~/.claude/claude-models.json`（参考下方格式）。

---

### 方式二：本地加载（开发/测试）

```bash
git clone https://github.com/shenhaofang/claude-code-model-switch-plugin.git
claude --plugin-dir ./claude-code-model-switch-plugin
```

---

### 配置文件格式

创建 `~/.claude/claude-models.json`，填入你的 API 配置：

```json
[
  {
    "name": "my-provider-primary",
    "default_model": "claude-sonnet-4-6",
    "api_key": "sk-your-primary-api-key",
    "api_base_url": "https://api.example.com"
  },
  {
    "name": "my-provider-backup",
    "default_model": "claude-sonnet-4-6",
    "api_key": "sk-your-backup-api-key",
    "api_base_url": "https://api.example.com"
  }
]
```

可参考仓库中的 `claude-models.json.example`。

## 使用

### 自动切换（无需操作）

安装后，每次 Claude Code 回复结束时（Stop hook）会自动扫描 transcript，
若发现 401/403 错误（在 API 报错重试结束后触发），轮换到配置文件中的下一个配置，并自动恢复被中断的任务：

```
🔄 [model-switch] 检测到 API 认证错误，已自动切换 → my-provider-backup
   API URL : https://api.example.com
   模型    : claude-sonnet-4-6
```

若多个配置都不可用，会依次尝试所有配置（每个最多 2 次），全部失败后提示手动处理：

```
⚠️  [model-switch] 所有备用配置均不可用，请手动处理。
```

### 手动切换

**在 Claude Code 内使用 Skill（注意当 api 已经失效后无法使用该方式，只能用命令行方式）：**

```
/model-switch:switch           # 交互式列表选择
/model-switch:switch 2         # 直接切换到序号 2
/model-switch:switch backup    # 直接切换到名为 backup 的配置
```

**或直接运行脚本：**

```bash
~/.claude/plugins/cache/model-switch/scripts/switch-model.sh
```

### 查看状态

```
/model-switch:status
```

## 日志与状态文件

| 文件 | 说明 |
|------|------|
| `~/.claude/model-switch.log` | 切换日志，最多保留 200 行 |
| `~/.claude/model-switch.state` | 已扫描的 transcript 行数，可安全删除 |
| `~/.claude/model-switch.fails` | 各配置失败计数，可安全删除 |
| `~/.claude/model-switch.proc` | 进程启动时间戳，用于重启检测，可安全删除 |

## 配置文件路径

默认读取 `~/.claude/claude-models.json`，可通过环境变量覆盖：

```bash
export CLAUDE_MODELS_FILE=/path/to/your/models.json
```

## 工作原理

```
API 返回 401/403 / access_denied_error
  → Claude Code 重试直至放弃，Claude 停止回复
  → 触发 Stop hook
  → auto-switch-on-error.sh 扫描 transcript 新增行
  → 检测到错误（结构化 status 401/403 或 assistant 行中的 access_denied_error）
  → 当前配置失败计数 +1，跳过失败次数已满的配置
  → 读取 claude-models.json，轮换到下一个可用配置
  → 写入 ~/.claude/settings.json，等待 Claude Code 重新加载
  → 终端显示切换提示（stderr）
  → Stop hook 输出 {"decision":"block","reason":"..."} 阻止停止
  → Claude Code 将 reason 作为上下文传给 Claude，任务自动恢复
  → 切换成功后重置失败计数；进程重启后也自动重置
```

## 依赖

- `python3`（标准库，无需额外安装）
- `bash` 4.0+
