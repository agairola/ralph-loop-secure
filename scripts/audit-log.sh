#!/bin/bash
#
# Append security scan results to the audit log.
# Creates a JSON Lines audit trail for compliance and debugging.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${RALPH_PROJECT_STATE_DIR:-$PROJECT_DIR/state}"
PROJECT_NAME="${RALPH_PROJECT_NAME:-unknown}"
AUDIT_LOG="$STATE_DIR/security-audit.jsonl"

# Target directory for git operations (fixes bug: was using ralph-loop-secure instead of target)
TARGET_DIR="${RALPH_TARGET_DIR:-$(pwd)}"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Arguments
ITERATION="${1:-0}"
ASH_RESULT="${2:-UNKNOWN}"
CLAUDE_EXIT_CODE="${3:-0}"
DURATION_SECONDS="${4:-0}"
STORY_ID="${5:-}"
STORY_TITLE="${6:-}"
TRANSCRIPT_PATH="${7:-}"

# Get timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Get git info from TARGET directory (not from ralph-loop-secure!)
GIT_BRANCH=$(cd "$TARGET_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT=$(cd "$TARGET_DIR" && git rev-parse HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT_SHORT=$(cd "$TARGET_DIR" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
GIT_COMMIT_MSG=$(cd "$TARGET_DIR" && git log -1 --pretty=%s 2>/dev/null || echo "")

# Get changed files from TARGET directory (write to temp file to avoid ARG_MAX limits)
CHANGED_FILES_TMP=$(mktemp)
ASH_FINDINGS_TMP=$(mktemp)
cleanup_tmp() { rm -f "$CHANGED_FILES_TMP" "$ASH_FINDINGS_TMP"; }
trap cleanup_tmp EXIT
cd "$TARGET_DIR" && git diff --name-only HEAD~1 2>/dev/null > "$CHANGED_FILES_TMP" || true

# Determine overall status from ASH result
if [[ "$ASH_RESULT" == "PASS" ]]; then
    STATUS="PASS"
elif [[ "$ASH_RESULT" == FAIL:* ]] || [[ "$ASH_RESULT" == "FAIL" ]]; then
    STATUS="FAIL"
elif [[ "$ASH_RESULT" == SKIP:* ]]; then
    STATUS="SKIP"
else
    STATUS="UNKNOWN"
fi

# Read detailed findings from ASH output if available (write to temp file to avoid ARG_MAX limits)
ASH_OUTPUT_DIR="$TARGET_DIR/.ash/ash_output"
if [ -f "$ASH_OUTPUT_DIR/ash_aggregated_results.json" ]; then
    jq -c '.' "$ASH_OUTPUT_DIR/ash_aggregated_results.json" > "$ASH_FINDINGS_TMP" 2>/dev/null || echo "null" > "$ASH_FINDINGS_TMP"
else
    echo "null" > "$ASH_FINDINGS_TMP"
fi

# Get PRD progress snapshot
PRD_FILE="$STATE_DIR/prd.json"
PRD_SNAPSHOT="null"
if [ -f "$PRD_FILE" ]; then
    PRD_SNAPSHOT=$(jq -c '{
        total: (.userStories | length),
        completed: ([.userStories[] | select(.passes == true)] | length),
        remaining: ([.userStories[] | select(.passes == false or .passes == null)] | length),
        stories: [.userStories[] | {id, title, passes}]
    }' "$PRD_FILE" 2>/dev/null || echo "null")
fi

# Determine run mode
RUN_MODE="docker"
if [ "${RALPH_SKIP_DOCKER:-false}" = "true" ]; then
    RUN_MODE="no_docker"
fi

# Build JSON entry with session metadata
JSON_ENTRY=$(jq -n \
    --arg timestamp "$TIMESTAMP" \
    --arg project "$PROJECT_NAME" \
    --arg iteration "$ITERATION" \
    --arg status "$STATUS" \
    --arg ash_result "$ASH_RESULT" \
    --arg branch "$GIT_BRANCH" \
    --arg commit "$GIT_COMMIT" \
    --arg commit_short "$GIT_COMMIT_SHORT" \
    --arg commit_msg "$GIT_COMMIT_MSG" \
    --rawfile changed_raw "$CHANGED_FILES_TMP" \
    --arg exit_code "$CLAUDE_EXIT_CODE" \
    --arg duration "$DURATION_SECONDS" \
    --arg story_id "$STORY_ID" \
    --arg story_title "$STORY_TITLE" \
    --arg mode "$RUN_MODE" \
    --arg transcript "$TRANSCRIPT_PATH" \
    --slurpfile ash_findings "$ASH_FINDINGS_TMP" \
    --argjson prd_progress "${PRD_SNAPSHOT:-null}" \
    '{
        timestamp: $timestamp,
        project: $project,
        iteration: ($iteration | tonumber? // $iteration),
        status: $status,
        session: {
            exit_code: ($exit_code | tonumber),
            duration_seconds: ($duration | tonumber),
            mode: $mode,
            transcript_path: (if $transcript == "" then null else $transcript end)
        },
        story: {
            id: (if $story_id == "" then null else $story_id end),
            title: (if $story_title == "" then null else $story_title end),
            status: (if $status == "PASS" then "completed" else "in_progress" end)
        },
        scans: {
            ash: $ash_result
        },
        git: {
            branch: $branch,
            commit: $commit,
            commit_short: $commit_short,
            commit_message: $commit_msg
        },
        changed_files: ($changed_raw | split("\n") | map(select(. != ""))),
        findings: {
            ash: $ash_findings[0]
        },
        prd_progress: $prd_progress
    }'
)

# Append to audit log
echo "$JSON_ENTRY" >> "$AUDIT_LOG"

# Also output to stdout for visibility
echo "Audit logged: iteration=$ITERATION status=$STATUS"

exit 0
