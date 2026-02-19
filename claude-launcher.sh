#!/bin/bash
# Claude Code 自动启动器
# 循环领取 data/dev-tasks.md 中的 pending 任务（- [ ]），完成后标记 - [x]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TASK_FILE="${SCRIPT_DIR}/dev-tasks.md"
LOCK_FILE="${TASK_FILE}.lock"
LOG_DIR="${SCRIPT_DIR}/logs/$(date '+%Y%m%d_%H%M%S')"
mkdir -p "$LOG_DIR"

# 原子领取: flock，找第一个 "- [ ]" 行，改为 "- [>]"，返回任务内容
claim_task() {
    (
        flock -x 200
        # 找第一个 pending 行
        local line
        line=$(grep -n '^\- \[ \?\] ' "$TASK_FILE" | head -1) || true

        if [ -z "$line" ]; then
            echo ""
            return
        fi

        local lineno content
        lineno=$(echo "$line" | cut -d: -f1)
        content=$(echo "$line" | cut -d: -f2-)
        # 提取 id 和 prompt: "- [ ] 1: some prompt"
        local tid prompt
        tid=$(echo "$content" | sed 's/^- \[ \?\] \([0-9]*\):.*/\1/')
        prompt=$(echo "$content" | sed 's/^- \[ \?\] [0-9]*: //')

        # 标记 running: [ ] → [>]
        sed -i "${lineno}s/- \[ \?\]/- [>]/" "$TASK_FILE"

        echo "${tid}|${prompt}"
    ) 200>"$LOCK_FILE"
}

# 标记任务完成/失败: [>] → [x] 或 [!]
mark_task() {
    local tid=$1 marker=$2
    (
        flock -x 200
        # 找到对应 id 的 running 行，替换标记
        sed -i "/^\- \[>\] ${tid}:/s/- \[>\]/- [${marker}]/" "$TASK_FILE"
    ) 200>"$LOCK_FILE"
}

echo "=== Claude Code Launcher ==="
echo "任务文件: $TASK_FILE"
echo ""

while true; do
    result=$(claim_task)
    if [ -z "$result" ]; then
        echo "[$(date '+%H:%M:%S')] 没有 pending 任务了，退出"
        break
    fi

    tid=$(echo "$result" | cut -d'|' -f1)
    prompt=$(echo "$result" | cut -d'|' -f2-)
    logfile="$LOG_DIR/task_${tid}_$(date '+%Y%m%d_%H%M%S').log"

    echo "[$(date '+%H:%M:%S')] 领取任务 #${tid}: ${prompt}"
    echo "[$(date '+%H:%M:%S')] 日志: $logfile"

    claude_prompt="你的任务: ${prompt}

干完活后用 exit 退出。不要问我确认，直接干。"

    if claude --dangerously-skip-permissions -p "$claude_prompt" > "$logfile" 2>&1; then
        mark_task "$tid" "x"
        echo "[$(date '+%H:%M:%S')] 任务 #${tid} 完成 ✓"
    else
        mark_task "$tid" "!"
        echo "[$(date '+%H:%M:%S')] 任务 #${tid} 失败 ✗ (见日志)"
    fi

    echo ""
done

echo "=== 全部任务处理完毕 ==="
cat "$TASK_FILE"
