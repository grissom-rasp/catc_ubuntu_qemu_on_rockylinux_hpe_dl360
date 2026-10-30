#!/usr/bin/env bash
# Claude Code PostToolUse helper: sync to SAS only after a "git sync" Bash command.
set -euo pipefail

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)

case "$CMD" in
  *"git sync"*)
    /home/grissom/rockylinux_remote/scripts/sync-to-sas.sh
    ;;
  *)
    exit 0
    ;;
esac