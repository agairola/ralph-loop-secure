#!/bin/bash
#
# Log iteration progress to progress.txt
# Creates a narrative log (like original ralph-loop) for human readability
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${RALPH_PROJECT_STATE_DIR:-$PROJECT_DIR/state}"
PROGRESS_FILE="$STATE_DIR/progress.txt"

# Target directory for git operations
TARGET_DIR="${RALPH_TARGET_DIR:-$(pwd)}"

# Arguments
ITERATION="${1:-0}"
ASH_RESULT="${2:-UNKNOWN}"
DURATION_SECONDS="${3:-0}"
STORY_ID="${4:-}"
STORY_TITLE="${5:-}"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Initialize progress file with header if it doesn't exist
if [ ! -f "$PROGRESS_FILE" ]; then
    cat > "$PROGRESS_FILE" << 'EOF'
# Progress Log

## Codebase Patterns
<!-- Claude will append learnings here that apply across stories -->

---

EOF
fi

# Get timestamp
TIMESTAMP=$(date +"%Y-%m-%d %H:%M")

# Determine overall status
if [[ "$ASH_RESULT" == "PASS" ]] || [[ "$ASH_RESULT" == "INTERNAL" ]]; then
    STATUS="$ASH_RESULT"
elif [[ "$ASH_RESULT" == FAIL:* ]] || [[ "$ASH_RESULT" == "FAIL" ]]; then
    STATUS="FAIL"
else
    STATUS="$ASH_RESULT"
fi

# Get git info from target directory
GIT_COMMIT_SHORT=$(cd "$TARGET_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT_MSG=$(cd "$TARGET_DIR" && git log -1 --pretty=%s 2>/dev/null || echo "")

# Get changed files from target directory
CHANGED_FILES=$(cd "$TARGET_DIR" && git diff --name-only HEAD~1 2>/dev/null || echo "")

# Build progress entry
{
    echo ""
    echo "## [$TIMESTAMP] - Iteration $ITERATION${STORY_ID:+ - $STORY_ID}"

    if [ -n "$STORY_TITLE" ]; then
        echo "**Story:** $STORY_TITLE"
    fi

    echo "**Status:** $STATUS"
    echo "**Duration:** ${DURATION_SECONDS}s"
    echo "**Security:** ASH $ASH_RESULT (internal scan)"
    echo ""

    if [ -n "$CHANGED_FILES" ]; then
        echo "**Changes:**"
        echo "$CHANGED_FILES" | while read -r file; do
            if [ -n "$file" ]; then
                echo "- $file"
            fi
        done
        echo ""
    fi

    if [ -n "$GIT_COMMIT_MSG" ] && [ "$GIT_COMMIT_SHORT" != "unknown" ]; then
        echo "**Commit:** $GIT_COMMIT_SHORT - $GIT_COMMIT_MSG"
        echo ""
    fi

    echo "**Learnings:**"
    echo "<!-- Claude should append learnings here -->"
    echo ""
    echo "---"

} >> "$PROGRESS_FILE"
