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
#   RALPH_SLACK_WEBHOOK  - Slack webhook for escalation notifications
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
        -h|--help)
            echo "Usage: $0 [options] [max_iterations] [target_dir]"
            echo ""
            echo "Options:"
            echo "  -p, --project NAME       Project name for state isolation"
            echo "  -t, --target DIR         Target directory to work in"
            echo "  -m, --max-iterations N   Maximum iterations (default: 10)"
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
NC='\033[0m' # No Color

# Logging
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ===========================================
# TRANSCRIPT EXTRACTION
# ===========================================

extract_transcript() {
    local iteration="$1"
    local output_dir="$PROJECT_STATE_DIR/transcripts"

    # Try to extract transcript using claude-code-transcripts
    if command -v uvx &> /dev/null; then
        log_info "Extracting transcript for iteration $iteration..."

        # Extract latest session to HTML + JSON
        uvx claude-code-transcripts local \
            -o "$output_dir" \
            --json \
            --limit 1 2>/dev/null || true

        # Rename to iteration-based filename if extraction succeeded
        if [ -f "$output_dir/index.html" ]; then
            mv "$output_dir/index.html" "$output_dir/iteration-${iteration}.html" 2>/dev/null || true
            log_success "Transcript saved: transcripts/iteration-${iteration}.html"
        fi

        # Also save JSON if available
        if [ -f "$output_dir/transcripts.json" ]; then
            mv "$output_dir/transcripts.json" "$output_dir/iteration-${iteration}.json" 2>/dev/null || true
        fi
    else
        log_warn "Transcript extraction skipped (uvx not available)"
    fi
}

# Session summary - called on exit
show_session_summary() {
    local exit_status="$1"
    local session_branch=$(cat "$PROJECT_STATE_DIR/.session-branch" 2>/dev/null || echo "unknown")
    local original_branch=$(cat "$PROJECT_STATE_DIR/.original-branch" 2>/dev/null || echo "main")

    echo ""
    echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║                    SESSION SUMMARY                          ║${NC}"
    echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${BLUE}Project:${NC}         $PROJECT_NAME"
    echo -e "  ${BLUE}Session branch:${NC}  $session_branch"
    echo -e "  ${BLUE}Original branch:${NC} $original_branch"
    echo -e "  ${BLUE}Target directory:${NC} $TARGET_DIR"
    echo -e "  ${BLUE}State directory:${NC} $PROJECT_STATE_DIR"
    echo ""

    if [ "$exit_status" = "success" ]; then
        echo -e "  ${GREEN}Status: All stories completed successfully!${NC}"
    elif [ "$exit_status" = "max_iterations" ]; then
        echo -e "  ${YELLOW}Status: Max iterations reached (incomplete stories remain)${NC}"
    else
        echo -e "  ${RED}Status: Session ended${NC}"
    fi

    # Show transcript locations
    if [ -d "$PROJECT_STATE_DIR/transcripts" ]; then
        TRANSCRIPT_COUNT=$(ls -1 "$PROJECT_STATE_DIR/transcripts"/*.html 2>/dev/null | wc -l | tr -d ' ')
        if [ "$TRANSCRIPT_COUNT" -gt 0 ]; then
            echo ""
            echo -e "  ${BLUE}Transcripts:${NC} $TRANSCRIPT_COUNT iteration(s) recorded"
            echo -e "  ${BLUE}Location:${NC} $PROJECT_STATE_DIR/transcripts/"
        fi
    fi

    echo ""
    echo -e "${CYAN}─────────────────────────────────────────────────────────────${NC}"
    echo -e "  ${BLUE}Next steps:${NC}"
    echo ""
    echo "  # Review changes:"
    echo "  cd $TARGET_DIR && git log --oneline $original_branch..$session_branch"
    echo ""
    echo "  # Create PR (if using GitHub):"
    echo "  cd $TARGET_DIR && gh pr create --base $original_branch"
    echo ""
    echo "  # Or merge directly:"
    echo "  cd $TARGET_DIR && git checkout $original_branch && git merge $session_branch"
    echo ""
    echo -e "${CYAN}─────────────────────────────────────────────────────────────${NC}"
}

# Header
echo ""
echo -e "${CYAN}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║           Ralph Loop Secure - v2.1.0                       ║${NC}"
echo -e "${CYAN}║     Security-hardened Claude Code Orchestration            ║${NC}"
echo -e "${CYAN}║     Security: ASH (Automated Security Helper)              ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "Project: $PROJECT_NAME"
log_info "Max iterations: $MAX_ITERATIONS"
log_info "Target directory: $TARGET_DIR"
log_info "State directory: $PROJECT_STATE_DIR"

# ===========================================
# PHASE 1: PRE-FLIGHT CHECKS
# ===========================================

log_info "Running pre-flight checks..."
if ! "$SCRIPT_DIR/scripts/pre-flight.sh"; then
    log_error "Pre-flight checks failed. Please fix the issues above."
    exit 1
fi
log_success "Pre-flight checks passed"
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

log_info "Creating isolated branch: $SESSION_BRANCH"
git checkout -b "$SESSION_BRANCH"
echo "$SESSION_BRANCH" > "$PROJECT_STATE_DIR/.session-branch"

log_success "Working on branch: $SESSION_BRANCH"
log_info "Original branch: $ORIGINAL_BRANCH"

cd - > /dev/null
echo ""

# ===========================================
# PHASE 3: MAIN LOOP
# ===========================================

# Initialize session tracking file
SESSION_IDS_FILE="$PROJECT_STATE_DIR/.session-ids"
> "$SESSION_IDS_FILE"  # Clear/create file

for i in $(seq 1 $MAX_ITERATIONS); do
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Iteration $i of $MAX_ITERATIONS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # Extract current story being worked on
    CURRENT_STORY_ID=""
    CURRENT_STORY_TITLE=""
    if [ -f "$PROJECT_STATE_DIR/prd.json" ]; then
        CURRENT_STORY_ID=$(jq -r '.userStories[] | select(.passes == false or .passes == null) | .id' "$PROJECT_STATE_DIR/prd.json" 2>/dev/null | head -1)
        if [ -n "$CURRENT_STORY_ID" ]; then
            CURRENT_STORY_TITLE=$(jq -r --arg id "$CURRENT_STORY_ID" '.userStories[] | select(.id == $id) | .title' "$PROJECT_STATE_DIR/prd.json" 2>/dev/null)
            log_info "Working on: $CURRENT_STORY_ID - $CURRENT_STORY_TITLE"
        fi
    fi

    # Build prompt (base only - Claude handles security scanning internally)
    PROMPT_CONTENT=$(cat "$SCRIPT_DIR/prompt.md")

    # Track start time
    START_TIME=$(date +%s)

    # ----------------------------------------
    # SPAWN CLAUDE CODE
    # ----------------------------------------
    log_info "Spawning Claude Code..."
    log_info "Security scanning via /security-scan skill (ASH)"
    echo ""

    CLAUDE_EXIT_CODE=0

    cd "$TARGET_DIR"
    # Use -p with --verbose --output-format stream-json for progress visibility
    # Capture session_id from first JSON line, then continue streaming tool calls
    claude --dangerously-skip-permissions \
        --add-dir "$SCRIPT_DIR" \
        -p "$PROMPT_CONTENT" \
        --verbose \
        --output-format stream-json 2>&1 | tee >(
            # Extract session_id from first line and save it
            head -1 | sed -n 's/.*"session_id":"\([^"]*\)".*/\1/p' >> "$SESSION_IDS_FILE"
        ) | stdbuf -oL sed -n \
            -e 's/.*"type":"tool_use".*"name":"\([^"]*\)".*/  [Tool] \1/p' \
            -e 's/.*"type":"result".*"total_cost_usd":\([0-9.]*\).*/  [Done] Cost: $\1/p'
    CLAUDE_EXIT_CODE=${PIPESTATUS[0]}
    cd - > /dev/null

    # Track duration
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    log_info "Claude Code session completed in ${DURATION}s (exit code: $CLAUDE_EXIT_CODE)"

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
        log_info "$INCOMPLETE stories remaining"
    fi

done

# ----------------------------------------
# EXTRACT TRANSCRIPTS FOR THIS SESSION
# ----------------------------------------
if [ -f "$SESSION_IDS_FILE" ] && [ -s "$SESSION_IDS_FILE" ]; then
    ITERATION_COUNT=$(wc -l < "$SESSION_IDS_FILE" | tr -d ' ')
    log_info "Extracting transcripts for $ITERATION_COUNT iteration(s)..."

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
                    --json 2>/dev/null || true

                # Rename to iteration-based filename if extraction succeeded
                if [ -f "$PROJECT_STATE_DIR/transcripts/index.html" ]; then
                    mv "$PROJECT_STATE_DIR/transcripts/index.html" "$PROJECT_STATE_DIR/transcripts/iteration-${TRANSCRIPT_INDEX}.html" 2>/dev/null || true
                fi
                # Keep the JSONL with session ID name (already copied by --json flag)
            else
                log_warn "Session file not found: $SESSION_FILE"
            fi

            TRANSCRIPT_INDEX=$((TRANSCRIPT_INDEX + 1))
        fi
    done < "$SESSION_IDS_FILE"

    log_success "Transcripts saved to: $PROJECT_STATE_DIR/transcripts/"
fi

# ----------------------------------------
# SESSION COMPLETION
# ----------------------------------------
if [ "${ALL_STORIES_COMPLETE:-false}" = "true" ]; then
    echo ""
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║                    ALL STORIES COMPLETE!                    ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    show_session_summary "success"
    exit 0
fi

echo ""
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"
log_warn "Max iterations ($MAX_ITERATIONS) reached"
echo -e "${YELLOW}═══════════════════════════════════════════════════════════${NC}"

# Final status
if [ -f "$PROJECT_STATE_DIR/prd.json" ]; then
    INCOMPLETE=$(jq '[.userStories[] | select(.passes == false or .passes == null)] | length' "$PROJECT_STATE_DIR/prd.json" 2>/dev/null || echo "?")
    log_info "$INCOMPLETE stories still incomplete"
fi

show_session_summary "max_iterations"
exit 1
