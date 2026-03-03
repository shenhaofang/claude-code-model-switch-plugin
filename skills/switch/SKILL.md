---
description: Interactively switch Claude Code model config. Usage: /model-switch:switch [name-or-index]
---

Run the model switch script to change the active Claude Code API configuration.

If $ARGUMENTS is provided, pass it directly to the script as the target config name or index (non-interactive mode).
Otherwise run in interactive mode.

Steps:
1. Run: `bash ${CLAUDE_PLUGIN_ROOT}/scripts/switch-model.sh $ARGUMENTS`
2. Show the output to the user.
3. Remind the user to restart Claude Code for the change to take effect.
