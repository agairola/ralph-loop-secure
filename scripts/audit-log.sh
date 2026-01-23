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

# Target directory for git operations (fixes bug: was using securing-ralph-loop instead of target)
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

# Get git info from TARGET directory (not from securing-ralph-loop!)
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
# Use OCSF format which is a flat array with cleaner structure
ASH_OUTPUT_DIR="$TARGET_DIR/.ash/ash_output"
OCSF_FILE="$ASH_OUTPUT_DIR/reports/ash.ocsf.json"
if [ -f "$OCSF_FILE" ]; then
    # Extract findings in normalized format from OCSF
    jq -c '[
        .[]? |
        .vulnerabilities[0] as $v |
        {
            file: $v.affected_code[0].file.path,
            line: $v.affected_code[0].start_line,
            rule_id: $v.cve.uid,
            severity: $v.severity,
            message: $v.desc
        }
    ]' "$OCSF_FILE" > "$ASH_FINDINGS_TMP" 2>/dev/null || echo "[]" > "$ASH_FINDINGS_TMP"
else
    echo "[]" > "$ASH_FINDINGS_TMP"
fi

# Classify findings as new vs pre-existing using baseline
BASELINE_FILE="$STATE_DIR/security-baseline.json"
NEW_FINDINGS_TMP=$(mktemp)
PREEXISTING_FINDINGS_TMP=$(mktemp)
GITHUB_ISSUES_TMP=$(mktemp)
cleanup_classification() { rm -f "$NEW_FINDINGS_TMP" "$PREEXISTING_FINDINGS_TMP" "$GITHUB_ISSUES_TMP"; }
trap 'cleanup_tmp; cleanup_classification' EXIT

# Initialize empty arrays
echo "[]" > "$NEW_FINDINGS_TMP"
echo "[]" > "$PREEXISTING_FINDINGS_TMP"
echo "[]" > "$GITHUB_ISSUES_TMP"

if [ -f "$BASELINE_FILE" ] && [ -f "$ASH_FINDINGS_TMP" ] && [ "$(cat "$ASH_FINDINGS_TMP")" != "[]" ]; then
    # Current findings are already in normalized format from OCSF extraction
    CURRENT_FINDINGS=$(cat "$ASH_FINDINGS_TMP" 2>/dev/null || echo "[]")

    # Load baseline (also in normalized format)
    BASELINE=$(cat "$BASELINE_FILE" 2>/dev/null || echo "[]")

    # Classify each finding by comparing signature (file:line:rule_id)
    echo "$CURRENT_FINDINGS" | jq -c --argjson baseline "$BASELINE" '
        . as $current |
        ($baseline | map({key: "\(.file):\(.line):\(.rule_id)", value: .}) | from_entries) as $baseline_map |
        {
            new: [.[] | select($baseline_map["\(.file):\(.line):\(.rule_id)"] == null)],
            preexisting: [.[] | select($baseline_map["\(.file):\(.line):\(.rule_id)"] != null)]
        }
    ' > /tmp/classified_findings.json 2>/dev/null || true

    if [ -f /tmp/classified_findings.json ]; then
        jq -c '.new // []' /tmp/classified_findings.json > "$NEW_FINDINGS_TMP" 2>/dev/null || echo "[]" > "$NEW_FINDINGS_TMP"
        jq -c '.preexisting // []' /tmp/classified_findings.json > "$PREEXISTING_FINDINGS_TMP" 2>/dev/null || echo "[]" > "$PREEXISTING_FINDINGS_TMP"
        rm -f /tmp/classified_findings.json
    fi
fi

# Check for GitHub issues created for pre-existing findings
PREEXISTING_REPORT="$STATE_DIR/preexisting-findings.json"
if [ -f "$PREEXISTING_REPORT" ]; then
    # Get unique files from pre-existing findings
    FILES=$(jq -r '[.[].file // empty] | unique[]' "$PREEXISTING_REPORT" 2>/dev/null || true)
    ISSUES=()
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        # Check if issue exists for this file
        ISSUE_NUM=$(cd "$TARGET_DIR" && gh issue list \
            --label "security-debt" \
            --search "Security: Pre-existing vulnerabilities in $file" \
            --json number -q '.[0].number' 2>/dev/null || true)
        if [ -n "$ISSUE_NUM" ]; then
            ISSUES+=("#$ISSUE_NUM")
        fi
    done <<< "$FILES"

    # Write issues array to temp file
    printf '%s\n' "${ISSUES[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))' > "$GITHUB_ISSUES_TMP" 2>/dev/null || echo "[]" > "$GITHUB_ISSUES_TMP"
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

# Determine if blocked by new findings
NEW_COUNT=$(jq 'length' "$NEW_FINDINGS_TMP" 2>/dev/null || echo "0")
PREEXISTING_COUNT=$(jq 'length' "$PREEXISTING_FINDINGS_TMP" 2>/dev/null || echo "0")
BLOCKED_BY_NEW="false"
if [ "$NEW_COUNT" != "0" ] && [ "$STATUS" = "FAIL" ]; then
    BLOCKED_BY_NEW="true"
fi

# Build JSON entry with session metadata and finding classification
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
    --slurpfile new_findings "$NEW_FINDINGS_TMP" \
    --slurpfile preexisting_findings "$PREEXISTING_FINDINGS_TMP" \
    --slurpfile github_issues "$GITHUB_ISSUES_TMP" \
    --arg blocked_by_new "$BLOCKED_BY_NEW" \
    --arg preexisting_count "$PREEXISTING_COUNT" \
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
            new: $new_findings[0],
            preexisting: $preexisting_findings[0],
            github_issues_created: $github_issues[0],
            ash: $ash_findings[0]
        },
        decision: {
            blocked_by_new: ($blocked_by_new == "true"),
            preexisting_count: ($preexisting_count | tonumber),
            action: (if $status == "PASS" then "PASS - new code clean, pre-existing tracked" elif ($blocked_by_new == "true") then "FAIL - new findings must be fixed" else "FAIL - scan error" end)
        },
        prd_progress: $prd_progress
    }'
)

# Append to audit log
echo "$JSON_ENTRY" >> "$AUDIT_LOG"

exit 0
