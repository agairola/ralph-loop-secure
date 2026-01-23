#!/bin/bash
#
# Ralph Loop Secure - Security-hardened orchestration for Claude Code
#
# This script spawns Claude Code instances that handle security scanning internally.
# Claude runs /security-scan (ASH) to validate code before committing.
#
# Usage:
#   ./ralph-secure.sh /path/to/project --max-iterations 10
#   ./ralph-secure.sh --project my-app --target /path/to/project --max-iterations 10
#   ./ralph-secure.sh -p my-app -t /path/to/project -m 10
#
# Environment Variables:
#   RALPH_SLACK_WEBHOOK           - Slack webhook for escalation notifications
#   RALPH_CREATE_SECURITY_ISSUES  - Create GitHub issues for pre-existing vulns (default: true)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="0.1.0"

# ===========================================
# ARGUMENT PARSING
# ===========================================

# Defaults
MAX_ITERATIONS=""
TARGET_DIR=""
PROJECT_NAME=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--project)
            PROJECT_NAME="$2"
            shift 2
            ;;
        -t|--target)
            TARGET_DIR="$2"
            shift 2
            ;;
        -m|--max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [options] [max_iterations] [target_dir]"
            echo ""
            echo "Options:"
            echo "  -p, --project NAME       Project name for state isolation"
            echo "  -t, --target DIR         Target directory to work in"
            echo "  -m, --max-iterations N   Maximum iterations (default: 10)"
            echo "  -v, --verbose            Show raw Claude output instead of progress bar"
            echo "  -h, --help               Show this help message"
            echo ""
            echo "Positional arguments (legacy):"
            echo "  max_iterations           Same as --max-iterations"
            echo "  target_dir               Same as --target"
            echo ""
            echo "Examples:"
            echo "  $0 10 /path/to/project"
            echo "  $0 --project my-app --target /path/to/project"
            echo "  $0 -p my-app -t /path/to/project -m 10"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            # Positional arguments - detect if it's a path or a number
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                # It's a number - treat as max_iterations
                MAX_ITERATIONS="$1"
            elif [[ "$1" == /* ]] || [[ "$1" == .* ]] || [[ -d "$1" ]]; then
                # It's a path - treat as target_dir
                TARGET_DIR="$1"
            elif [ -z "$MAX_ITERATIONS" ]; then
                # Fallback: first unknown arg is max_iterations
                MAX_ITERATIONS="$1"
            else
                # Fallback: second unknown arg is target_dir
                TARGET_DIR="$1"
            fi
            shift
            ;;
    esac
done

# Apply defaults
MAX_ITERATIONS="${MAX_ITERATIONS:-10}"
TARGET_DIR="${TARGET_DIR:-.}"

# ===========================================
# INJECTION CLEANUP
# ===========================================

# Track injected files for cleanup
INJECTED_CLAUDE_DIR=""
INJECTED_CLAUDE_MD=""
INJECTED_ASH_DIR=""
INJECTED_GIT_EXCLUDE=""
INJECTED_HOOK=""

# Track progress monitor for cleanup
PROGRESS_MONITOR_PID=""

# Progress monitoring
PROGRESS_TMPFILE=""
VERBOSE=false
MAGENTA='\033[0;35m'

# Marker for entries we add to .git/info/exclude
RALPH_EXCLUDE_MARKER="# ralph-loop-secure injected (auto-removed)"

# Cleanup function - runs on exit, interrupt, or termination
cleanup_injected_files() {
    # Stop progress monitor if running
    if [ -n "$PROGRESS_MONITOR_PID" ]; then
        kill "$PROGRESS_MONITOR_PID" 2>/dev/null || true
        # Clear progress line using tput
        tput cr 2>/dev/null || printf "\r"
        tput el 2>/dev/null || printf "%-80s\r" " "
    fi

    # Cleanup progress temp file
    if [ -n "$PROGRESS_TMPFILE" ] && [ -f "$PROGRESS_TMPFILE" ]; then
        rm -f "$PROGRESS_TMPFILE"
    fi

    # Cleanup .claude directory (silent)
    if [ -n "$INJECTED_CLAUDE_DIR" ] && [ -d "$INJECTED_CLAUDE_DIR" ]; then
        rm -rf "$INJECTED_CLAUDE_DIR"
        local backup="${INJECTED_CLAUDE_DIR}.ralph-backup"
        [ -d "$backup" ] && mv "$backup" "$INJECTED_CLAUDE_DIR"
    fi

    # Cleanup CLAUDE.md (silent)
    if [ -n "$INJECTED_CLAUDE_MD" ] && [ -f "$INJECTED_CLAUDE_MD" ]; then
        rm -f "$INJECTED_CLAUDE_MD"
        local backup="${INJECTED_CLAUDE_MD}.ralph-backup"
        [ -f "$backup" ] && mv "$backup" "$INJECTED_CLAUDE_MD"
    fi

    # Cleanup .ash directory (silent)
    if [ -n "$INJECTED_ASH_DIR" ] && [ -d "$INJECTED_ASH_DIR" ]; then
        rm -rf "$INJECTED_ASH_DIR"
        local backup="${INJECTED_ASH_DIR}.ralph-backup"
        [ -d "$backup" ] && mv "$backup" "$INJECTED_ASH_DIR"
    fi

    # Cleanup .git/info/exclude entries (silent)
    if [ -n "$INJECTED_GIT_EXCLUDE" ] && [ -f "$INJECTED_GIT_EXCLUDE" ]; then
        grep -v "$RALPH_EXCLUDE_MARKER" "$INJECTED_GIT_EXCLUDE" > "$INJECTED_GIT_EXCLUDE.tmp" 2>/dev/null || true
        mv "$INJECTED_GIT_EXCLUDE.tmp" "$INJECTED_GIT_EXCLUDE"
    fi

    # Cleanup pre-commit hook (silent)
    if [ -n "$INJECTED_HOOK" ]; then
        rm -f "$INJECTED_HOOK"
        local backup="${INJECTED_HOOK}.ralph-backup"
        [ -f "$backup" ] && mv "$backup" "$INJECTED_HOOK"
    fi
}

# Register cleanup on exit, interrupt (Ctrl+C), and termination
trap cleanup_injected_files EXIT INT TERM

# ===========================================
# PROJECT NAME DERIVATION
# ===========================================

# Derive project name from target directory if not specified
derive_project_name() {
    local dir="$1"
    local name

    # Resolve to absolute path and get basename
    if [ "$dir" = "." ]; then
        name=$(basename "$(pwd)")
    else
        name=$(basename "$(cd "$dir" 2>/dev/null && pwd)" 2>/dev/null || basename "$dir")
    fi

    # Sanitize: lowercase, replace spaces/special chars with hyphens
    echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//'
}

if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME=$(derive_project_name "$TARGET_DIR")
fi

# ===========================================
# PROJECT STATE INITIALIZATION
# ===========================================

PROJECT_STATE_DIR="$SCRIPT_DIR/state/$PROJECT_NAME"

# Initialize project state directory
initialize_project_state() {
    local state_dir="$1"

    if [ ! -d "$state_dir" ]; then
        mkdir -p "$state_dir"

        # Copy prd.json.example if no prd.json exists
        if [ ! -f "$state_dir/prd.json" ] && [ -f "$SCRIPT_DIR/prd.json.example" ]; then
            cp "$SCRIPT_DIR/prd.json.example" "$state_dir/prd.json"
            echo "Initialized $state_dir/prd.json from template"
        fi
    fi

    # Create transcripts directory
    mkdir -p "$state_dir/transcripts"
}

# Ensure base state directory exists
mkdir -p "$SCRIPT_DIR/state"

# Initialize project-specific state
initialize_project_state "$PROJECT_STATE_DIR"

# Export for child scripts
export RALPH_PROJECT_NAME="$PROJECT_NAME"
export RALPH_PROJECT_STATE_DIR="$PROJECT_STATE_DIR"
export RALPH_TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m' # No Color

# ===========================================
# SECURITY BASELINE MANAGEMENT
# ===========================================

# Create security baseline from current HEAD (before Claude makes changes)
# This captures pre-existing vulnerabilities for comparison
create_security_baseline() {
    local target_dir="$1"
    local baseline_file="$PROJECT_STATE_DIR/security-baseline.json"
    local baseline_output_dir="$PROJECT_STATE_DIR/.ash_baseline"

    # Only create baseline once per branch (at first iteration)
    if [ -f "$baseline_file" ]; then
        return 0
    fi

    # Check if ASH is available
    if ! command -v uvx &> /dev/null; then
        echo "[]" > "$baseline_file"
        return 0
    fi

    # Create baseline output directory
    mkdir -p "$baseline_output_dir"

    # Temporarily inject .ash/ config for baseline scan (needed for custom rules)
    local temp_ash_injected=false
    if [ -d "$SCRIPT_DIR/.ash" ] && [ ! -d "$target_dir/.ash" ]; then
        cp -r "$SCRIPT_DIR/.ash" "$target_dir/.ash"
        temp_ash_injected=true
    fi

    # Run ASH scan on current HEAD (silently)
    cd "$target_dir"
    uvx --from git+https://github.com/awslabs/automated-security-helper.git@v3.1.5 \
        ash --mode local --source-dir . --output-dir "$baseline_output_dir" \
        > /dev/null 2>&1 || true

    # Run custom semgrep rules separately (ASH doesn't honor custom semgrep config)
    local custom_semgrep_output="$baseline_output_dir/custom-semgrep.json"
    if [ -f ".ash/rules/semgrep-rules.yml" ]; then
        uvx semgrep --config .ash/rules/semgrep-rules.yml \
            --json --quiet \
            . > "$custom_semgrep_output" 2>/dev/null || true
    fi
    cd - > /dev/null

    # Clean up temporarily injected .ash/ directory
    if [ "$temp_ash_injected" = true ]; then
        rm -rf "$target_dir/.ash"
    fi

    # Extract ASH findings (OCSF format)
    local ocsf_results="$baseline_output_dir/reports/ash.ocsf.json"
    local ash_findings="[]"
    if [ -f "$ocsf_results" ]; then
        ash_findings=$(jq -c '[
            .[]? |
            .vulnerabilities[0] as $v |
            {
                file: $v.affected_code[0].file.path,
                line: $v.affected_code[0].start_line,
                rule_id: $v.cve.uid,
                severity: $v.severity,
                message: $v.desc
            }
        ]' "$ocsf_results" 2>/dev/null || echo "[]")
    fi

    # Extract custom semgrep findings and merge
    local custom_findings="[]"
    if [ -f "$custom_semgrep_output" ]; then
        custom_findings=$(jq -c '[
            .results[]? |
            {
                file: .path,
                line: .start.line,
                rule_id: .check_id,
                severity: (if .extra.severity == "ERROR" then "ERROR" elif .extra.severity == "WARNING" then "WARNING" else "INFO" end),
                message: .extra.message
            }
        ]' "$custom_semgrep_output" 2>/dev/null || echo "[]")
    fi

    # Merge and deduplicate findings
    echo "$ash_findings" "$custom_findings" | jq -s 'add | unique_by(.file + ":" + (.line|tostring) + ":" + .rule_id)' > "$baseline_file" 2>/dev/null || echo "[]" > "$baseline_file"

    # Store baseline creation timestamp
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "$PROJECT_STATE_DIR/.baseline-timestamp"
}

# Report pre-existing vulnerabilities (creates GitHub issues with dedup)
report_preexisting_vulnerabilities() {
    local findings_file="$1"

    # Check if GitHub issue creation is enabled
    local create_issues="${RALPH_CREATE_SECURITY_ISSUES:-true}"

    if [ "$create_issues" = "false" ]; then
        return 0
    fi

    # Only report if we have findings
    if [ ! -f "$findings_file" ] || [ "$(jq 'length' "$findings_file" 2>/dev/null)" = "0" ]; then
        return 0
    fi

    # Call the report script
    "$SCRIPT_DIR/scripts/report-preexisting.sh" "$findings_file" "$PROJECT_NAME"
}

# Logging - unified output format
log_label() { printf "  %-16s │ %s\n" "$1" "$2"; }
log_ok()    { printf "  ${GREEN}✓${NC} %-14s │ %s\n" "$1" "$2"; }
log_info()  { printf "  %-16s │ %s\n" "$1" "$2"; }
log_warn()  { printf "  ${YELLOW}⚠${NC} %-14s │ %s\n" "$1" "$2"; }
log_error() { printf "  ${RED}✗${NC} %-14s │ %s\n" "$1" "$2"; }
log_success() { printf "  ${GREEN}✓${NC} %-14s │ %s\n" "$1" "$2"; }

# ===========================================
# PROGRESS MONITORING (Real-time Step Detection)
# ===========================================

# Show session summary after Claude completes
# Parses the session JSONL to report what happened
show_iteration_summary() {
    local session_file="$1"
    local duration="$2"

    if [ -z "$session_file" ] || [ ! -f "$session_file" ]; then
        return 0
    fi

    # Count tool uses from session file (sanitize to single integer)
    local reads=$(grep -c '"tool":"Read"' "$session_file" 2>/dev/null | head -1 | tr -d '[:space:]')
    reads=${reads:-0}
    local edits=$(grep -c '"tool":"Edit"' "$session_file" 2>/dev/null | head -1 | tr -d '[:space:]')
    edits=${edits:-0}
    local writes=$(grep -c '"tool":"Write"' "$session_file" 2>/dev/null | head -1 | tr -d '[:space:]')
    writes=${writes:-0}
    local bashes=$(grep -c '"tool":"Bash"' "$session_file" 2>/dev/null | head -1 | tr -d '[:space:]')
    bashes=${bashes:-0}
    local tasks=$(grep -c '"tool":"Task"' "$session_file" 2>/dev/null | head -1 | tr -d '[:space:]')
    tasks=${tasks:-0}
    local skills=$(grep -c '"tool":"Skill"' "$session_file" 2>/dev/null | head -1 | tr -d '[:space:]')
    skills=${skills:-0}

    # Build summary line
    local summary=""
    [ "$reads" -gt 0 ] && summary="${summary}${reads} reads, "
    [ "$edits" -gt 0 ] && summary="${summary}${edits} edits, "
    [ "$writes" -gt 0 ] && summary="${summary}${writes} writes, "
    [ "$bashes" -gt 0 ] && summary="${summary}${bashes} commands, "
    [ "$tasks" -gt 0 ] && summary="${summary}${tasks} agents, "
    [ "$skills" -gt 0 ] && summary="${summary}${skills} skills, "

    # Remove trailing comma and space
    summary="${summary%, }"

    if [ -n "$summary" ]; then
        echo ""
        log_label "Summary" "$summary"
    fi
}

# Real-time progress monitor (runs in background)
# Tails Claude output and detects current step from patterns
monitor_progress() {
    local output_file="$1"
    local task="$2"
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local spin_idx=0
    local start_time=$(date +%s)
    local current_step="Thinking"
    local prev_step=""

    task="${task:0:40}"

    while true; do
        local elapsed=$(($(date +%s) - start_time))
        local mins=$((elapsed / 60))
        local secs=$((elapsed % 60))

        # Detect current step from output file
        if [ -f "$output_file" ] && [ -s "$output_file" ]; then
            local content
            content=$(tail -c 5000 "$output_file" 2>/dev/null || true)

            # Detect tools from stream-json output format: "name":"ToolName" in tool_use blocks
            # Order matters: more specific patterns first, then general tool detection

            # Check for actual tool invocations (stream-json format uses "name":"ToolName")
            if echo "$content" | grep -qE '"name":"Skill".*security-scan|"skill":\s*"security-scan"'; then
                current_step="Security scan"
            elif echo "$content" | grep -qE '"command":\s*"git commit|"input":\{[^}]*git commit'; then
                current_step="Committing"
            elif echo "$content" | grep -qE '"command":\s*"git add|"input":\{[^}]*git add'; then
                current_step="Staging"
            elif echo "$content" | grep -qE '"file_path":[^}]*progress\.txt'; then
                current_step="Logging"
            elif echo "$content" | grep -qE '"file_path":[^}]*prd\.json'; then
                current_step="Updating PRD"
            elif echo "$content" | grep -qE '"command":\s*"[^"]*\b(lint|eslint|biome|prettier)\b'; then
                current_step="Linting"
            elif echo "$content" | grep -qE '"command":\s*"[^"]*\b(vitest|jest|npm test|pytest|go test|cargo test)\b'; then
                current_step="Testing"
            elif echo "$content" | grep -qE '"file_path":[^}]*(\.test\.|\.spec\.|__tests__|_test\.go|_test\.py)'; then
                current_step="Writing tests"
            elif echo "$content" | grep -qE '"name":"Write"|"name":"Edit"'; then
                current_step="Implementing"
            elif echo "$content" | grep -qE '"name":"Read"|"name":"Glob"|"name":"Grep"|"name":"Task"'; then
                current_step="Reading code"
            fi
        fi

        # Color-code by phase
        local step_color=""
        case "$current_step" in
            "Thinking"|"Reading code") step_color="$CYAN" ;;
            "Implementing"|"Writing tests") step_color="$MAGENTA" ;;
            "Testing"|"Linting"|"Security scan") step_color="$YELLOW" ;;
            "Staging"|"Committing") step_color="$GREEN" ;;
            *) step_color="$BLUE" ;;
        esac

        # When step changes, finalize old line and start new
        local spinner_char="${spinstr:$spin_idx:1}"
        if [ "$current_step" != "$prev_step" ] && [ -n "$prev_step" ]; then
            # Finalize previous step with checkmark
            tput cr 2>/dev/null || printf "\r"
            tput el 2>/dev/null || true
            printf "  ${GREEN}✓${NC} %-14s │ %s ${DIM}[%02d:%02d]${NC}\n" \
                "$prev_step" "$task" "$mins" "$secs"
        fi
        prev_step="$current_step"

        # Display current step (overwrites same line until step changes)
        tput cr 2>/dev/null || printf "\r"
        tput el 2>/dev/null || true
        printf "  %s ${step_color}%-14s${NC} │ %s ${DIM}[%02d:%02d]${NC}" \
            "$spinner_char" "$current_step" "$task" "$mins" "$secs"

        spin_idx=$(( (spin_idx + 1) % ${#spinstr} ))
        sleep 0.12
    done
}

# Start progress monitor (runs in background)
start_progress_monitor() {
    local output_file="$1"
    local task="$2"

    monitor_progress "$output_file" "$task" &
    PROGRESS_MONITOR_PID=$!
}

# Stop progress monitor (if still running)
stop_progress_monitor() {
    if [ -n "$PROGRESS_MONITOR_PID" ]; then
        kill "$PROGRESS_MONITOR_PID" 2>/dev/null || true
        wait "$PROGRESS_MONITOR_PID" 2>/dev/null || true
        PROGRESS_MONITOR_PID=""
        # Clear any lingering progress line using tput
        tput cr 2>/dev/null || printf "\r"
        tput el 2>/dev/null || printf "%-80s\r" " "
    fi
}

# ===========================================
# TRANSCRIPT EXTRACTION
# ===========================================

extract_transcript() {
    local iteration="$1"
    local output_dir="$PROJECT_STATE_DIR/transcripts"

    # Try to extract transcript using claude-code-transcripts (silent)
    if command -v uvx &> /dev/null; then
        uvx claude-code-transcripts local \
            -o "$output_dir" \
            --json \
            --limit 1 2>/dev/null || true

        # Rename to iteration-based filename if extraction succeeded
        if [ -f "$output_dir/index.html" ]; then
            mv "$output_dir/index.html" "$output_dir/iteration-${iteration}.html" 2>/dev/null || true
        fi

        # Also save JSON if available
        if [ -f "$output_dir/transcripts.json" ]; then
            mv "$output_dir/transcripts.json" "$output_dir/iteration-${iteration}.json" 2>/dev/null || true
        fi
    fi
}

# Session summary - called on exit
show_session_summary() {
    local exit_status="$1"
    local session_branch=$(cat "$PROJECT_STATE_DIR/.session-branch" 2>/dev/null || echo "unknown")
    local original_branch=$(cat "$PROJECT_STATE_DIR/.original-branch" 2>/dev/null || echo "main")

    echo ""
    echo -e "═══════════════════════════════════════════════════════════════"
    echo -e "  Session Complete"
    echo -e "═══════════════════════════════════════════════════════════════"
    echo ""

    if [ "$exit_status" = "success" ]; then
        log_ok "Status" "All stories completed"
    elif [ "$exit_status" = "max_iterations" ]; then
        log_warn "Status" "Max iterations reached"
    else
        log_label "Status" "Session ended"
    fi

    log_label "Branch" "$session_branch"

    # Show transcript locations
    if [ -d "$PROJECT_STATE_DIR/transcripts" ]; then
        TRANSCRIPT_COUNT=$(ls -1 "$PROJECT_STATE_DIR/transcripts"/*.html 2>/dev/null | wc -l | tr -d ' ')
        if [ "$TRANSCRIPT_COUNT" -gt 0 ]; then
            log_label "Transcripts" "$TRANSCRIPT_COUNT iterations saved"
        fi
    fi

    # Show pre-existing security findings summary
    local baseline_file="$PROJECT_STATE_DIR/security-baseline.json"
    local preexisting_report="$PROJECT_STATE_DIR/preexisting-findings.json"
    if [ -f "$preexisting_report" ]; then
        local preexisting_count=$(jq 'length' "$preexisting_report" 2>/dev/null || echo "0")
        if [ "$preexisting_count" != "0" ] && [ "$preexisting_count" != "null" ]; then
            echo ""
            echo -e "  ${YELLOW}⚠${NC} Pre-existing Security Issues Detected:"
            echo "  ────────────────────────────────────────────────────────────"

            # Group by file and show summary table
            local files=$(jq -r '[.[].file] | unique[]' "$preexisting_report" 2>/dev/null)
            printf "  │ %-35s │ %-8s │ %-6s │\n" "File" "Severity" "Issues"
            echo "  ├─────────────────────────────────────┼──────────┼────────┤"

            while IFS= read -r file; do
                [ -z "$file" ] && continue
                local truncated_file="${file:0:35}"
                local file_count=$(jq "[.[] | select(.file == \"$file\")] | length" "$preexisting_report" 2>/dev/null)
                local max_severity=$(jq -r "[.[] | select(.file == \"$file\") | .severity] | if any(. == \"ERROR\") then \"ERROR\" elif any(. == \"HIGH\") then \"HIGH\" elif any(. == \"WARNING\") then \"WARNING\" else \"INFO\" end" "$preexisting_report" 2>/dev/null)
                printf "  │ %-35s │ %-8s │ %-6s │\n" "$truncated_file" "$max_severity" "$file_count"
            done <<< "$files"

            echo "  └─────────────────────────────────────┴──────────┴────────┘"

            # Show GitHub issues if created
            if [ "${RALPH_CREATE_SECURITY_ISSUES:-true}" = "true" ]; then
                log_info "GitHub" "Issues created for tracking (label: security-debt)"
            fi
        fi
    fi

    echo ""
    echo "  Next steps:"
    echo "    git log $original_branch..$session_branch"
    echo "    gh pr create --base $original_branch"
    echo ""
}

# Header - minimal unified output
echo ""
echo -e "${CYAN}╭─────────────────────────────────────────────────────────────╮${NC}"
printf "${CYAN}│${NC}  Securing Ralph Loop v%-38s${CYAN}│${NC}\n" "$VERSION"
echo -e "${CYAN}╰─────────────────────────────────────────────────────────────╯${NC}"
echo ""
log_label "Project" "$PROJECT_NAME"
log_label "Target" "$TARGET_DIR"
log_label "Max iterations" "$MAX_ITERATIONS"
echo ""

# ===========================================
# PHASE 1: PRE-FLIGHT CHECKS
# ===========================================

if ! "$SCRIPT_DIR/scripts/pre-flight.sh" > /dev/null 2>&1; then
    log_error "Pre-flight" "checks failed - run scripts/pre-flight.sh for details"
    exit 1
fi
log_ok "Pre-flight" "passed"
echo ""

# ===========================================
# PHASE 2: BRANCH ISOLATION
# ===========================================

cd "$TARGET_DIR"

# Save original branch for reference
ORIGINAL_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
echo "$ORIGINAL_BRANCH" > "$PROJECT_STATE_DIR/.original-branch"

# Create session branch
SESSION_TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SESSION_BRANCH="ralph/${PROJECT_NAME}-${SESSION_TIMESTAMP}"

git checkout -b "$SESSION_BRANCH" > /dev/null 2>&1
echo "$SESSION_BRANCH" > "$PROJECT_STATE_DIR/.session-branch"

log_label "Branch" "$SESSION_BRANCH"

cd - > /dev/null
echo ""

# ===========================================
# PHASE 2.5: SECURITY BASELINE
# ===========================================

# Capture pre-existing vulnerabilities before Claude makes changes
# This allows us to distinguish new vs inherited security debt
log_info "Baseline" "Checking for pre-existing vulnerabilities..."
create_security_baseline "$TARGET_DIR"

if [ -f "$PROJECT_STATE_DIR/security-baseline.json" ]; then
    BASELINE_COUNT=$(jq 'length' "$PROJECT_STATE_DIR/security-baseline.json" 2>/dev/null || echo "0")
    if [ "$BASELINE_COUNT" != "0" ] && [ "$BASELINE_COUNT" != "null" ]; then
        log_warn "Baseline" "$BASELINE_COUNT pre-existing findings captured"
    else
        log_ok "Baseline" "No pre-existing vulnerabilities"
    fi
fi
echo ""

# ===========================================
# PHASE 3: MAIN LOOP
# ===========================================

# Initialize session tracking file
SESSION_IDS_FILE="$PROJECT_STATE_DIR/.session-ids"
> "$SESSION_IDS_FILE"  # Clear/create file

for i in $(seq 1 $MAX_ITERATIONS); do
    echo ""
    echo -e "═══════════════════════════════════════════════════════════════"
    echo -e "  Iteration $i of $MAX_ITERATIONS"
    echo -e "═══════════════════════════════════════════════════════════════"
    echo ""

    # Extract current story being worked on
    CURRENT_STORY_ID=""
    CURRENT_STORY_TITLE=""
    if [ -f "$PROJECT_STATE_DIR/prd.json" ]; then
        CURRENT_STORY_ID=$(jq -r '.userStories[] | select(.passes == false or .passes == null) | .id' "$PROJECT_STATE_DIR/prd.json" 2>/dev/null | head -1)
        if [ -n "$CURRENT_STORY_ID" ]; then
            CURRENT_STORY_TITLE=$(jq -r --arg id "$CURRENT_STORY_ID" '.userStories[] | select(.id == $id) | .title' "$PROJECT_STATE_DIR/prd.json" 2>/dev/null)
            log_label "Story" "$CURRENT_STORY_ID: $CURRENT_STORY_TITLE"
        fi
    fi

    # Build prompt (base only - Claude handles security scanning internally)
    PROMPT_CONTENT=$(cat "$SCRIPT_DIR/prompt.md")

    # Track start time
    START_TIME=$(date +%s)

    # ----------------------------------------
    # SPAWN CLAUDE CODE
    # ----------------------------------------

    CLAUDE_EXIT_CODE=0

    # ----------------------------------------
    # INJECT SKILLS AND CLAUDE.MD INTO TARGET
    # ----------------------------------------
    # Claude discovers skills from cwd/.claude/skills/ and CLAUDE.md from cwd
    # --add-dir only grants file access, not config discovery
    inject_claude_config() {
        local target="$1"
        local source_claude="$SCRIPT_DIR/.claude"
        local source_md="$SCRIPT_DIR/CLAUDE.md"
        local target_claude="$target/.claude"
        local target_md="$target/CLAUDE.md"
        local git_exclude="$target/.git/info/exclude"

        # Backup and inject .claude directory
        if [ -d "$target_claude" ]; then
            mv "$target_claude" "$target_claude.ralph-backup"
        fi
        cp -r "$source_claude" "$target_claude"
        INJECTED_CLAUDE_DIR="$target_claude"

        # Backup and inject CLAUDE.md
        if [ -f "$target_md" ]; then
            mv "$target_md" "$target_md.ralph-backup"
        fi
        cp "$source_md" "$target_md"
        INJECTED_CLAUDE_MD="$target_md"

        # Backup and inject .ash directory (ASH configuration + custom Semgrep rules)
        local source_ash="$SCRIPT_DIR/.ash"
        local target_ash="$target/.ash"
        if [ -d "$source_ash" ]; then
            if [ -d "$target_ash" ]; then
                mv "$target_ash" "$target_ash.ralph-backup"
            fi
            cp -r "$source_ash" "$target_ash"
            INJECTED_ASH_DIR="$target_ash"
        fi

        # Add entries to .git/info/exclude (local-only, never committed)
        # This protects against files being staged if script crashes before cleanup
        if [ -d "$target/.git/info" ]; then
            mkdir -p "$target/.git/info"
            {
                echo ".claude/ $RALPH_EXCLUDE_MARKER"
                echo "CLAUDE.md $RALPH_EXCLUDE_MARKER"
                echo ".claude.ralph-backup/ $RALPH_EXCLUDE_MARKER"
                echo "CLAUDE.md.ralph-backup $RALPH_EXCLUDE_MARKER"
                echo ".ash/ $RALPH_EXCLUDE_MARKER"
                echo ".ash.ralph-backup/ $RALPH_EXCLUDE_MARKER"
            } >> "$git_exclude"
            INJECTED_GIT_EXCLUDE="$git_exclude"
        fi

        # Inject pre-commit hook to prevent committing ralph files
        # This is the primary defense - automatically unstages injected files before any commit
        local hook_file="$target/.git/hooks/pre-commit"
        if [ -d "$target/.git/hooks" ]; then
            # Backup existing hook if present
            if [ -f "$hook_file" ]; then
                cp "$hook_file" "$hook_file.ralph-backup"
            fi

            cat > "$hook_file" << 'HOOK'
#!/bin/bash
# Ralph Loop: Auto-unstage injected files before commit
# This prevents accidentally committing ralph-loop configuration files
git reset HEAD -- .claude/ CLAUDE.md .ash/ 2>/dev/null || true

# Run original pre-commit hook if it existed
if [ -f "$0.ralph-backup" ]; then
    exec "$0.ralph-backup" "$@"
fi
HOOK
            chmod +x "$hook_file"
            INJECTED_HOOK="$hook_file"
        fi
    }

    inject_claude_config "$TARGET_DIR"

    cd "$TARGET_DIR"

    # Derive Claude projects directory for this target
    CLAUDE_PROJECTS_PATH="$HOME/.claude/projects/-$(echo "$RALPH_TARGET_DIR" | sed 's|^/||' | tr '/' '-')"

    # Ensure projects directory exists (Claude may not have created it yet)
    mkdir -p "$CLAUDE_PROJECTS_PATH" 2>/dev/null || true

    # Get list of session files BEFORE running Claude
    SESSIONS_BEFORE=$(ls -1 "$CLAUDE_PROJECTS_PATH"/*.jsonl 2>/dev/null | sort)

    # Task display for progress
    TASK_DISPLAY="${CURRENT_STORY_ID:-US-XXX}: ${CURRENT_STORY_TITLE:-Working...}"
    TASK_DISPLAY="${TASK_DISPLAY:0:50}"

    # Create temp file for output
    PROGRESS_TMPFILE=$(mktemp)

    if [ "$VERBOSE" = true ]; then
        # Verbose mode: show raw output (original behavior)
        if [[ "$OSTYPE" == "darwin"* ]]; then
            script -q /dev/null claude --dangerously-skip-permissions \
                --add-dir "$SCRIPT_DIR" \
                -p "$PROMPT_CONTENT" || true
        else
            script -q -c "claude --dangerously-skip-permissions \
                --add-dir \"$SCRIPT_DIR\" \
                -p \"$PROMPT_CONTENT\"" /dev/null || true
        fi
        CLAUDE_EXIT_CODE=$?
    else
        # Progress monitor mode: capture output, show progress bar
        start_progress_monitor "$PROGRESS_TMPFILE" "$TASK_DISPLAY"

        # Run Claude with stream-json for progress detection
        claude --dangerously-skip-permissions \
            --verbose \
            --output-format stream-json \
            --add-dir "$SCRIPT_DIR" \
            -p "$PROMPT_CONTENT" > "$PROGRESS_TMPFILE" 2>&1 || true
        CLAUDE_EXIT_CODE=$?

        # Stop monitor and show final status
        stop_progress_monitor

        # Calculate elapsed time for final status
        elapsed=$(($(date +%s) - START_TIME))
        mins=$((elapsed / 60))
        secs=$((elapsed % 60))
        printf "  ${GREEN}✓${NC} %-14s │ %s ${DIM}[%02d:%02d]${NC}\n" "Done" "$TASK_DISPLAY" "$mins" "$secs"
    fi

    # Cleanup temp file
    rm -f "$PROGRESS_TMPFILE"
    PROGRESS_TMPFILE=""

    # Find new session file by comparing before/after
    SESSIONS_AFTER=$(ls -1 "$CLAUDE_PROJECTS_PATH"/*.jsonl 2>/dev/null | sort)
    NEW_SESSION_FILE=$(comm -13 <(echo "$SESSIONS_BEFORE") <(echo "$SESSIONS_AFTER") | tail -1)

    # Extract session ID from filename and save it
    if [ -n "$NEW_SESSION_FILE" ]; then
        SESSION_ID=$(basename "$NEW_SESSION_FILE" .jsonl)
        echo "$SESSION_ID" >> "$SESSION_IDS_FILE"
    fi

    cd - > /dev/null

    # Track duration
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))

    # Show iteration summary with tool usage stats
    if [ -n "$NEW_SESSION_FILE" ]; then
        show_iteration_summary "$NEW_SESSION_FILE" "$DURATION"
    fi

    # ----------------------------------------
    # LOG RESULTS
    # ----------------------------------------

    # Get git info for audit
    cd "$TARGET_DIR"
    CHANGED=$(git diff --name-only HEAD~1 2>/dev/null || echo "")
    cd - > /dev/null

    # Log to audit (JSON Lines format)
    # Security scan results are now internal to Claude's session (ASH runs inside Claude)
    "$SCRIPT_DIR/scripts/audit-log.sh" \
        "$i" \
        "INTERNAL" \
        "$CLAUDE_EXIT_CODE" \
        "$DURATION" \
        "$CURRENT_STORY_ID" \
        "$CURRENT_STORY_TITLE" \
        "$PROJECT_STATE_DIR/transcripts/iteration-${i}.html"

    # Log to progress (human-readable narrative)
    if [ -f "$SCRIPT_DIR/scripts/log-progress.sh" ]; then
        "$SCRIPT_DIR/scripts/log-progress.sh" \
            "$i" \
            "INTERNAL" \
            "$DURATION" \
            "$CURRENT_STORY_ID" \
            "$CURRENT_STORY_TITLE"
    fi

    # ----------------------------------------
    # CHECK COMPLETION
    # ----------------------------------------

    if [ -f "$PROJECT_STATE_DIR/prd.json" ]; then
        INCOMPLETE=$(jq '[.userStories[] | select(.passes == false or .passes == null)] | length' "$PROJECT_STATE_DIR/prd.json" 2>/dev/null || echo "1")
        if [ "$INCOMPLETE" = "0" ]; then
            ALL_STORIES_COMPLETE=true
            break
        fi
        log_label "Remaining" "$INCOMPLETE stories"
    fi

done

# ----------------------------------------
# EXTRACT TRANSCRIPTS FOR THIS SESSION
# ----------------------------------------
if [ -f "$SESSION_IDS_FILE" ] && [ -s "$SESSION_IDS_FILE" ]; then
    ITERATION_COUNT=$(wc -l < "$SESSION_IDS_FILE" | tr -d ' ')

    # Derive Claude projects directory from target path
    # Claude stores sessions in ~/.claude/projects/-{path-with-dashes}/
    CLAUDE_PROJECTS_PATH="$HOME/.claude/projects/-$(echo "$RALPH_TARGET_DIR" | sed 's|^/||' | tr '/' '-')"

    # Extract each session's transcript
    TRANSCRIPT_INDEX=1
    while read -r session_id; do
        if [ -n "$session_id" ]; then
            SESSION_FILE="$CLAUDE_PROJECTS_PATH/${session_id}.jsonl"
            if [ -f "$SESSION_FILE" ]; then
                uvx claude-code-transcripts json "$SESSION_FILE" \
                    -o "$PROJECT_STATE_DIR/transcripts" \
                    --json > /dev/null 2>&1 || true

                # Rename to iteration-based filename if extraction succeeded
                if [ -f "$PROJECT_STATE_DIR/transcripts/index.html" ]; then
                    mv "$PROJECT_STATE_DIR/transcripts/index.html" "$PROJECT_STATE_DIR/transcripts/iteration-${TRANSCRIPT_INDEX}.html" 2>/dev/null || true
                fi
            fi
            TRANSCRIPT_INDEX=$((TRANSCRIPT_INDEX + 1))
        fi
    done < "$SESSION_IDS_FILE"

    # Show clean summary
    if [ -d "$PROJECT_STATE_DIR/transcripts" ]; then
        TRANSCRIPT_COUNT=$(ls -1 "$PROJECT_STATE_DIR/transcripts"/*.html 2>/dev/null | wc -l | tr -d ' ')
        if [ "$TRANSCRIPT_COUNT" -gt 0 ]; then
            log_ok "Transcripts" "$TRANSCRIPT_COUNT iteration(s) saved to state/$PROJECT_NAME/transcripts/"
        fi
    fi
fi

# ----------------------------------------
# REPORT PRE-EXISTING VULNERABILITIES
# ----------------------------------------
# Compare final scan results against baseline to identify pre-existing issues
# and create GitHub issues for tracking them

PREEXISTING_REPORT="$PROJECT_STATE_DIR/preexisting-findings.json"
BASELINE_FILE="$PROJECT_STATE_DIR/security-baseline.json"

if [ -f "$BASELINE_FILE" ]; then
    # Copy baseline findings to preexisting report for summary display
    # (In delta detection, these would be filtered by the security-scan skill)
    cp "$BASELINE_FILE" "$PREEXISTING_REPORT" 2>/dev/null || true

    # Report pre-existing vulnerabilities (create GitHub issues if enabled)
    report_preexisting_vulnerabilities "$PREEXISTING_REPORT"
fi

# ----------------------------------------
# SESSION COMPLETION
# ----------------------------------------
if [ "${ALL_STORIES_COMPLETE:-false}" = "true" ]; then
    show_session_summary "success"
    exit 0
fi

show_session_summary "max_iterations"
exit 1
