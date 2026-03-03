# model-switch — Claude Code Plugin

自动在 API 认证失败（401/403）时切换模型配置，并提供交互式手动切换功能。

## 功能

- **自动切换**：检测到 API 返回 401/403 错误时，自动轮换到下一个配置
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
若发现 401/403 错误，立即轮换到配置文件中的下一个配置，并在终端提示：

```
🔄 [model-switch] 检测到 API 认证错误，已自动切换 → my-provider-backup
   API URL : https://api.example.com
   模型    : claude-sonnet-4-6
   ✓ 配置已生效
```

### 手动切换

**在 Claude Code 内使用 Skill（注意当api已经失效后无法使用该方式，只能用命令行方式）：**

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

## 日志

- 切换日志：`~/.claude/model-switch.log`（最多保留 200 行）
- 状态文件：`~/.claude/model-switch.state`（记录已扫描的 transcript 行数，可安全删除）

## 配置文件路径

默认读取 `~/.claude/claude-models.json`，可通过环境变量覆盖：

```bash
export CLAUDE_MODELS_FILE=/path/to/your/models.json
```

## 工作原理

```
API 返回 401/403
  → transcript 写入 api_error 记录（type: system, subtype: api_error）
  → Claude 回复结束，触发 Stop hook
  → auto-switch-on-error.sh 扫描 transcript 新增行
  → 检测到 status 401/403
  → 读取 claude-models.json，轮换到下一个配置
  → 写入 ~/.claude/settings.json
  → 终端显示切换提示
```

## 依赖

- `python3`（标准库，无需额外安装）
- `bash` 4.0+
