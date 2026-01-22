#!/bin/bash
#
# Reset State - Ralph Loop Secure
# Resets target directory and cleans state (preserves prd.json)
#
# Usage:
#   ./reset-state.sh /path/to/target-project
#   ./reset-state.sh /path/to/target-project --project my-app
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Parse arguments
TARGET_DIR=""
PROJECT_NAME=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -p|--project)
            PROJECT_NAME="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [options] <target-directory>"
            echo ""
            echo "Options:"
            echo "  -p, --project NAME   Project name (derived from target dir if not specified)"
            echo "  -h, --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0 /path/to/my-project"
            echo "  $0 /path/to/my-project --project my-app"
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            exit 1
            ;;
        *)
            TARGET_DIR="$1"
            shift
            ;;
    esac
done

if [ -z "$TARGET_DIR" ]; then
    log_error "Target directory is required"
    echo "Usage: $0 <target-directory>"
    exit 1
fi

if [ ! -d "$TARGET_DIR" ]; then
    log_error "Target directory does not exist: $TARGET_DIR"
    exit 1
fi

# Derive project name from target directory if not specified
derive_project_name() {
    local dir="$1"
    local name
    name=$(basename "$(cd "$dir" 2>/dev/null && pwd)" 2>/dev/null || basename "$dir")
    echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9._-]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//'
}

if [ -z "$PROJECT_NAME" ]; then
    PROJECT_NAME=$(derive_project_name "$TARGET_DIR")
fi

PROJECT_STATE_DIR="$SCRIPT_DIR/state/$PROJECT_NAME"

echo ""
echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║           Ralph Loop Secure - Reset State                   ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "Target directory: $TARGET_DIR"
log_info "Project name: $PROJECT_NAME"
log_info "State directory: $PROJECT_STATE_DIR"
echo ""

# ===========================================
# CLEAN TARGET DIRECTORY
# ===========================================

log_info "Cleaning target directory..."

cd "$TARGET_DIR"

# Get current branch before reset
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

# Switch to main if on a ralph branch
if [[ "$CURRENT_BRANCH" == ralph/* ]]; then
    log_info "Switching from $CURRENT_BRANCH to main..."
    git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
fi

# Reset to HEAD
git reset --hard HEAD
log_success "Git reset to HEAD"

# Clean untracked files
git clean -fd
log_success "Cleaned untracked files"

# Delete all ralph branches
RALPH_BRANCHES=$(git branch | grep ralph || true)
if [ -n "$RALPH_BRANCHES" ]; then
    echo "$RALPH_BRANCHES" | xargs -I {} git branch -D {} 2>/dev/null || true
    log_success "Deleted ralph branches"
else
    log_info "No ralph branches to delete"
fi

cd - > /dev/null

# ===========================================
# CLEAN STATE DIRECTORY (PRESERVE PRD)
# ===========================================

if [ -d "$PROJECT_STATE_DIR" ]; then
    log_info "Cleaning state directory (preserving prd.json)..."

    # Save prd.json if it exists
    if [ -f "$PROJECT_STATE_DIR/prd.json" ]; then
        cp "$PROJECT_STATE_DIR/prd.json" "/tmp/prd-$PROJECT_NAME-backup.json"
        log_info "Backed up prd.json"
    fi

    # Remove everything in state directory
    rm -rf "$PROJECT_STATE_DIR"/*
    rm -rf "$PROJECT_STATE_DIR"/.[!.]* 2>/dev/null || true

    # Restore prd.json
    if [ -f "/tmp/prd-$PROJECT_NAME-backup.json" ]; then
        mv "/tmp/prd-$PROJECT_NAME-backup.json" "$PROJECT_STATE_DIR/prd.json"
        log_success "Restored prd.json"
    fi

    # Recreate transcripts directory
    mkdir -p "$PROJECT_STATE_DIR/transcripts"
    log_success "Recreated transcripts directory"

    # Reset passes to false in prd.json
    if [ -f "$PROJECT_STATE_DIR/prd.json" ]; then
        # Reset all passes to false
        jq '.userStories = [.userStories[] | .passes = false | .notes = ""]' \
            "$PROJECT_STATE_DIR/prd.json" > "$PROJECT_STATE_DIR/prd.json.tmp" \
            && mv "$PROJECT_STATE_DIR/prd.json.tmp" "$PROJECT_STATE_DIR/prd.json"
        log_success "Reset all user stories to passes: false"
    fi
else
    log_warn "State directory does not exist: $PROJECT_STATE_DIR"
fi

echo ""
log_success "Clean complete!"
echo ""
echo -e "${BLUE}Ready to run:${NC}"
echo "  ./ralph-secure.sh $TARGET_DIR --max-iterations 2"
echo ""
