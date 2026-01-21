#!/bin/bash
#
# Run Semgrep security scan on specified files.
# This runs on the HOST machine, outside of Claude Code.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
RULES_DIR="$PROJECT_DIR/rules"
STATE_DIR="${RALPH_PROJECT_STATE_DIR:-$PROJECT_DIR/state}"

# Files to scan (passed as argument or from git diff)
FILES="$1"

# If no files specified, exit with PASS
if [ -z "$FILES" ]; then
    echo "PASS"
    exit 0
fi

# Check if semgrep is available
if ! command -v semgrep &> /dev/null; then
    echo "ERROR:semgrep_not_found"
    exit 2
fi

# Create a temporary file for results
RESULT_FILE=$(mktemp)
trap "rm -f $RESULT_FILE" EXIT

# Run Semgrep with custom rules and auto config
# --json outputs machine-readable format
# --no-git-ignore to ensure we scan all specified files
# --severity ERROR,WARNING to catch important issues
semgrep scan \
    --config="$RULES_DIR/semgrep-rules.yml" \
    --config=auto \
    --json \
    --severity ERROR \
    --severity WARNING \
    --no-git-ignore \
    $FILES > "$RESULT_FILE" 2>/dev/null || true

# Parse results
if [ ! -s "$RESULT_FILE" ]; then
    # Empty file means no results or error
    echo "PASS"
    exit 0
fi

# Count errors and warnings
ERROR_COUNT=$(jq '.results | map(select(.extra.severity == "ERROR")) | length' "$RESULT_FILE" 2>/dev/null || echo "0")
WARNING_COUNT=$(jq '.results | map(select(.extra.severity == "WARNING")) | length' "$RESULT_FILE" 2>/dev/null || echo "0")
TOTAL_COUNT=$(jq '.results | length' "$RESULT_FILE" 2>/dev/null || echo "0")

if [ "$TOTAL_COUNT" -eq 0 ]; then
    echo "PASS"
    exit 0
fi

# If we have findings, output them
echo "FAIL:$TOTAL_COUNT"

# Output detailed findings to stderr for logging
jq -r '.results[] | "[\(.extra.severity)] \(.path):\(.start.line) - \(.check_id): \(.extra.message)"' "$RESULT_FILE" >&2

# Save findings to state for remediation context
jq '{
    findings: [.results[] | {
        rule: .check_id,
        severity: .extra.severity,
        file: .path,
        line: .start.line,
        message: .extra.message,
        fix: .extra.fix
    }]
}' "$RESULT_FILE" > "$STATE_DIR/semgrep-findings.json" 2>/dev/null || true

exit 1
