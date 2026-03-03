---
description: Show current Claude Code model config and recent auto-switch log entries.
---

Show the current active model configuration and recent auto-switch activity.

Steps:
1. Read `$HOME/.claude/settings.json` and extract `env.ANTHROPIC_AUTH_TOKEN` (show only first 14 chars), `env.ANTHROPIC_BASE_URL`, `env.ANTHROPIC_MODEL`.
2. Read `$HOME/.claude/claude-models.json` and list all configs, marking the active one.
3. Show the last 10 lines of `$HOME/.claude/model-switch.log` if it exists.
4. Present the information clearly to the user.
