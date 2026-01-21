#!/bin/bash
#
# Append security scan results to the audit log.
# Creates a JSON Lines audit trail for compliance and debugging.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$PROJECT_DIR/state"
AUDIT_LOG="$STATE_DIR/security-audit.jsonl"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Arguments
ITERATION="${1:-0}"
SEMGREP_RESULT="${2:-UNKNOWN}"
SNYK_RESULT="${3:-UNKNOWN}"

# Get timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Get git info
GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT_SHORT=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

# Get changed files
CHANGED_FILES=$(git diff --name-only HEAD~1 2>/dev/null | tr '\n' ',' | sed 's/,$//')

# Determine overall status
if [[ "$SEMGREP_RESULT" == "PASS" ]] && [[ "$SNYK_RESULT" == "PASS" || "$SNYK_RESULT" == SKIP:* ]]; then
    STATUS="PASS"
elif [[ "$SEMGREP_RESULT" == FAIL:* ]] || [[ "$SNYK_RESULT" == FAIL:* ]]; then
    STATUS="FAIL"
else
    STATUS="UNKNOWN"
fi

# Read detailed findings if available
SEMGREP_FINDINGS=""
if [ -f "$STATE_DIR/semgrep-findings.json" ]; then
    SEMGREP_FINDINGS=$(cat "$STATE_DIR/semgrep-findings.json" | jq -c '.')
fi

SNYK_FINDINGS=""
if [ -f "$STATE_DIR/snyk-findings.json" ]; then
    SNYK_FINDINGS=$(cat "$STATE_DIR/snyk-findings.json" | jq -c '.')
fi

# Build JSON entry
JSON_ENTRY=$(jq -n \
    --arg timestamp "$TIMESTAMP" \
    --arg iteration "$ITERATION" \
    --arg status "$STATUS" \
    --arg semgrep "$SEMGREP_RESULT" \
    --arg snyk "$SNYK_RESULT" \
    --arg branch "$GIT_BRANCH" \
    --arg commit "$GIT_COMMIT" \
    --arg commit_short "$GIT_COMMIT_SHORT" \
    --arg changed "$CHANGED_FILES" \
    --argjson semgrep_findings "${SEMGREP_FINDINGS:-null}" \
    --argjson snyk_findings "${SNYK_FINDINGS:-null}" \
    '{
        timestamp: $timestamp,
        iteration: ($iteration | tonumber),
        status: $status,
        scans: {
            semgrep: $semgrep,
            snyk: $snyk
        },
        git: {
            branch: $branch,
            commit: $commit,
            commit_short: $commit_short
        },
        changed_files: ($changed | split(",") | map(select(. != ""))),
        findings: {
            semgrep: $semgrep_findings,
            snyk: $snyk_findings
        }
    }'
)

# Append to audit log
echo "$JSON_ENTRY" >> "$AUDIT_LOG"

# Also output to stdout for visibility
echo "Audit logged: iteration=$ITERATION status=$STATUS"

# Clean up temporary findings files
rm -f "$STATE_DIR/semgrep-findings.json" "$STATE_DIR/snyk-findings.json"

exit 0
