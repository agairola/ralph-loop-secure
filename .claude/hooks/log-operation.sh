#!/bin/bash
#
# Post-tool-use hook to log all operations for audit purposes.
# Appends to state/operations.jsonl in JSON Lines format.
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
STATE_DIR="${RALPH_PROJECT_STATE_DIR:-$PROJECT_DIR/state}"
PROJECT_NAME="${RALPH_PROJECT_NAME:-unknown}"
LOG_FILE="$STATE_DIR/operations.jsonl"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Get tool name and input from arguments
TOOL_NAME="${1:-unknown}"
TOOL_INPUT="${2:-}"

# Get current timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Get git info
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Truncate tool input if too long (keep first 500 chars)
if [ ${#TOOL_INPUT} -gt 500 ]; then
    TOOL_INPUT="${TOOL_INPUT:0:500}...(truncated)"
fi

# Escape special characters for JSON
escape_json() {
    local input="$1"
    # Escape backslashes, quotes, and control characters
    echo -n "$input" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

# Build JSON log entry
ESCAPED_INPUT=$(escape_json "$TOOL_INPUT")

# Create JSON entry (removing outer quotes from escaped input since it's already a JSON string)
JSON_ENTRY=$(cat <<EOF
{"timestamp":"$TIMESTAMP","project":"$PROJECT_NAME","tool":"$TOOL_NAME","input":$ESCAPED_INPUT,"git_branch":"$GIT_BRANCH","git_commit":"$GIT_COMMIT","pid":$$}
EOF
)

# Append to log file
echo "$JSON_ENTRY" >> "$LOG_FILE"

# Exit success (don't block the operation)
exit 0
