#!/bin/bash
#
# Ralph Loop Secure - Security-hardened orchestration for Claude Code
#
# This script spawns Claude Code instances with built-in security validation.
# Security scanning happens OUTSIDE Claude Code using external tools (Semgrep, Snyk).
#
# Usage:
#   ./ralph-secure.sh [max_iterations] [target_dir]
#   ./ralph-secure.sh --project my-app --target /path/to/project --max-iterations 10
#   ./ralph-secure.sh -p my-app -t /path/to/project -m 10
#
# Environment Variables:
#   RALPH_MAX_RETRIES    - Max remediation attempts per failure (default: 3)
#   RALPH_SLACK_WEBHOOK  - Slack webhook for escalation notifications
#   RALPH_CREATE_ISSUE   - Set to "true" to create GitHub issues on escalation
#   RALPH_SKIP_DOCKER    - Set to "true" to run without Docker sandbox
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
            # Positional arguments (legacy support)
            if [ -z "$MAX_ITERATIONS" ]; then
                MAX_ITERATIONS="$1"
            elif [ -z "$TARGET_DIR" ]; then
                TARGET_DIR="$1"
            fi
            shift
            ;;
    esac
done

# Apply defaults
MAX_ITERATIONS="${MAX_ITERATIONS:-10}"
TARGET_DIR="${TARGET_DIR:-.}"
MAX_RETRIES=${RALPH_MAX_RETRIES:-3}

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
}

# Ensure base state directory exists
mkdir -p "$SCRIPT_DIR/state"

# Initialize project-specific state
initialize_project_state "$PROJECT_STATE_DIR"

# Export for child scripts
export RALPH_PROJECT_NAME="$PROJECT_NAME"
export RALPH_PROJECT_STATE_DIR="$PROJECT_STATE_DIR"

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
        echo -e "  ${RED}Status: Escalation required${NC}"
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
echo -e "${CYAN}║           Ralph Loop Secure - v1.0.0                       ║${NC}"
echo -e "${CYAN}║     Security-hardened Claude Code Orchestration            ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "Project: $PROJECT_NAME"
log_info "Max iterations: $MAX_ITERATIONS"
log_info "Target directory: $TARGET_DIR"
log_info "State directory: $PROJECT_STATE_DIR"
log_info "Max retries per failure: $MAX_RETRIES"

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

for i in $(seq 1 $MAX_ITERATIONS); do
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Iteration $i of $MAX_ITERATIONS${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
    echo ""

    # Build prompt (base + any security context from previous failure)
    PROMPT_CONTENT=$(cat "$SCRIPT_DIR/prompt.md")

    if [ -f "$PROJECT_STATE_DIR/security-context.md" ]; then
        log_warn "Security context detected - remediation mode"
        PROMPT_CONTENT="$PROMPT_CONTENT

---

$(cat "$PROJECT_STATE_DIR/security-context.md")"
    fi

    # Track start time
    START_TIME=$(date +%s)

    # ----------------------------------------
    # SPAWN CLAUDE CODE
    # ----------------------------------------
    log_info "Spawning Claude Code..."

    CLAUDE_EXIT_CODE=0

    if [ "${RALPH_SKIP_DOCKER:-false}" = "true" ]; then
        # Run without Docker sandbox (for testing or when Docker unavailable)
        log_warn "Running without Docker sandbox (RALPH_SKIP_DOCKER=true)"

        cd "$TARGET_DIR"
        claude --dangerously-skip-permissions \
            --project-dir "$SCRIPT_DIR" \
            -p "$PROMPT_CONTENT" || CLAUDE_EXIT_CODE=$?
        cd - > /dev/null
    else
        # Run in Docker sandbox for isolation
        # Note: docker sandbox run is a Docker Desktop 4.50+ feature
        # If not available, fall back to regular docker run

        if docker help 2>&1 | grep -q "sandbox"; then
            docker sandbox run \
                -w "$TARGET_DIR" \
                -v "$SCRIPT_DIR:/ralph:ro" \
                claude --dangerously-skip-permissions \
                --project-dir /ralph \
                -p "$PROMPT_CONTENT" || CLAUDE_EXIT_CODE=$?
        else
            # Fallback: run without sandbox feature
            log_warn "Docker sandbox not available, running with volume mount"
            docker run --rm -it \
                -v "$TARGET_DIR:/workspace" \
                -v "$SCRIPT_DIR:/ralph:ro" \
                -w /workspace \
                --network none \
                node:20-slim \
                npx -y @anthropic-ai/claude-code --dangerously-skip-permissions \
                --project-dir /ralph \
                -p "$PROMPT_CONTENT" || CLAUDE_EXIT_CODE=$?
        fi
    fi

    # Track duration
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    log_info "Claude Code session completed in ${DURATION}s (exit code: $CLAUDE_EXIT_CODE)"

    # Clear security context after use
    rm -f "$PROJECT_STATE_DIR/security-context.md"

    # ----------------------------------------
    # CHECK FOR CHANGES
    # ----------------------------------------

    cd "$TARGET_DIR"
    CHANGED=$(git diff --name-only HEAD~1 2>/dev/null || echo "")
    cd - > /dev/null

    if [ -z "$CHANGED" ]; then
        log_info "No changes detected in this iteration"

        # Check completion status
        if [ -f "$PROJECT_STATE_DIR/prd.json" ]; then
            INCOMPLETE=$(jq '[.userStories[] | select(.passes == false or .passes == null)] | length' "$PROJECT_STATE_DIR/prd.json" 2>/dev/null || echo "1")
            if [ "$INCOMPLETE" = "0" ]; then
                log_success "All stories complete!"
                exit 0
            fi
            log_info "$INCOMPLETE stories remaining"
        fi

        continue
    fi

    log_info "Changed files:"
    echo "$CHANGED" | while read -r f; do
        echo "  - $f"
    done

    # ----------------------------------------
    # EXTERNAL SECURITY SCAN (ON HOST)
    # ----------------------------------------

    echo ""
    log_info "Running external security scans..."

    # Run Semgrep
    cd "$TARGET_DIR"
    SEMGREP_RESULT=$("$SCRIPT_DIR/scripts/run-semgrep.sh" "$CHANGED" 2>&1) || true
    cd - > /dev/null

    if [[ "$SEMGREP_RESULT" == "PASS" ]]; then
        log_success "Semgrep: PASS"
    elif [[ "$SEMGREP_RESULT" == FAIL:* ]]; then
        log_error "Semgrep: $SEMGREP_RESULT"
    else
        log_warn "Semgrep: $SEMGREP_RESULT"
    fi

    # Run Snyk (if dependency files changed)
    SNYK_RESULT="SKIP:no_deps_changed"
    if echo "$CHANGED" | grep -qE "(package\.json|package-lock\.json|Cargo\.toml|Cargo\.lock|requirements\.txt|pyproject\.toml|go\.mod|go\.sum)"; then
        cd "$TARGET_DIR"
        SNYK_RESULT=$("$SCRIPT_DIR/scripts/run-snyk.sh" "." 2>&1) || true
        cd - > /dev/null

        if [[ "$SNYK_RESULT" == "PASS" ]]; then
            log_success "Snyk: PASS"
        elif [[ "$SNYK_RESULT" == FAIL:* ]]; then
            log_error "Snyk: $SNYK_RESULT"
        else
            log_warn "Snyk: $SNYK_RESULT"
        fi
    else
        log_info "Snyk: Skipped (no dependency files changed)"
    fi

    # ----------------------------------------
    # LOG RESULTS
    # ----------------------------------------

    "$SCRIPT_DIR/scripts/audit-log.sh" "$i" "$SEMGREP_RESULT" "$SNYK_RESULT"

    # ----------------------------------------
    # DECISION GATE
    # ----------------------------------------

    if [[ "$SEMGREP_RESULT" == "PASS" ]] && [[ "$SNYK_RESULT" == "PASS" || "$SNYK_RESULT" == SKIP:* ]]; then
        log_success "Security scan PASSED"

        # Check completion status
        if [ -f "$PROJECT_STATE_DIR/prd.json" ]; then
            INCOMPLETE=$(jq '[.userStories[] | select(.passes == false or .passes == null)] | length' "$PROJECT_STATE_DIR/prd.json" 2>/dev/null || echo "1")
            if [ "$INCOMPLETE" = "0" ]; then
                echo ""
                echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
                echo -e "${GREEN}║                    ALL STORIES COMPLETE!                    ║${NC}"
                echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
                show_session_summary "success"
                exit 0
            fi
            log_info "$INCOMPLETE stories remaining"
        fi

        continue
    fi

    # ----------------------------------------
    # SECURITY FAILURE - REMEDIATION LOOP
    # ----------------------------------------

    log_warn "Security scan FAILED - entering remediation loop"

    for retry in $(seq 1 $MAX_RETRIES); do
        echo ""
        log_info "Remediation attempt $retry of $MAX_RETRIES"

        # Rollback the commit
        cd "$TARGET_DIR"
        "$SCRIPT_DIR/scripts/rollback.sh"
        cd - > /dev/null

        # Inject security context for next iteration
        "$SCRIPT_DIR/scripts/inject-security-context.sh" "$SEMGREP_RESULT" "$SNYK_RESULT"

        # Build remediation prompt
        REMEDIATION_PROMPT=$(cat "$SCRIPT_DIR/prompt.md")
        REMEDIATION_PROMPT="$REMEDIATION_PROMPT

---

$(cat "$PROJECT_STATE_DIR/security-context.md")"

        # Spawn Claude Code for remediation
        log_info "Spawning Claude Code for remediation..."

        if [ "${RALPH_SKIP_DOCKER:-false}" = "true" ]; then
            cd "$TARGET_DIR"
            claude --dangerously-skip-permissions \
                --project-dir "$SCRIPT_DIR" \
                -p "$REMEDIATION_PROMPT" || true
            cd - > /dev/null
        else
            if docker help 2>&1 | grep -q "sandbox"; then
                docker sandbox run \
                    -w "$TARGET_DIR" \
                    -v "$SCRIPT_DIR:/ralph:ro" \
                    claude --dangerously-skip-permissions \
                    --project-dir /ralph \
                    -p "$REMEDIATION_PROMPT" || true
            else
                docker run --rm -it \
                    -v "$TARGET_DIR:/workspace" \
                    -v "$SCRIPT_DIR:/ralph:ro" \
                    -w /workspace \
                    --network none \
                    node:20-slim \
                    npx -y @anthropic-ai/claude-code --dangerously-skip-permissions \
                    --project-dir /ralph \
                    -p "$REMEDIATION_PROMPT" || true
            fi
        fi

        # Re-scan
        cd "$TARGET_DIR"
        CHANGED=$(git diff --name-only HEAD~1 2>/dev/null || echo "")
        SEMGREP_RESULT=$("$SCRIPT_DIR/scripts/run-semgrep.sh" "$CHANGED" 2>&1) || true
        cd - > /dev/null

        # Log remediation attempt
        "$SCRIPT_DIR/scripts/audit-log.sh" "$i.$retry" "$SEMGREP_RESULT" "SKIP:remediation"

        if [[ "$SEMGREP_RESULT" == "PASS" ]]; then
            log_success "Remediation successful!"
            rm -f "$PROJECT_STATE_DIR/security-context.md"
            break
        fi

        log_error "Remediation attempt $retry failed: $SEMGREP_RESULT"
    done

    # Check if remediation was successful
    if [[ "$SEMGREP_RESULT" != "PASS" ]]; then
        log_error "Remediation exhausted after $MAX_RETRIES attempts"
        "$SCRIPT_DIR/scripts/escalate.sh" "$i" "$SEMGREP_RESULT"
        show_session_summary "escalation"
        exit 1
    fi

    # Clean up
    rm -f "$PROJECT_STATE_DIR/security-context.md"

done

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
