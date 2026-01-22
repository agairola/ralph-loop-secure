#!/bin/bash
#
# Pre-flight checks before starting the secure Ralph loop.
# Validates that all required tools and files are available.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="${RALPH_PROJECT_STATE_DIR:-$PROJECT_DIR/state}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "=== Pre-flight Checks ==="
echo ""

ERRORS=0
WARNINGS=0

# Function to check if a command exists
check_command() {
    local cmd="$1"
    local required="$2"
    local install_hint="$3"

    if command -v "$cmd" &> /dev/null; then
        echo -e "${GREEN}[OK]${NC} $cmd found"
        return 0
    else
        if [ "$required" = "required" ]; then
            echo -e "${RED}[FAIL]${NC} $cmd not found (required)"
            echo "       Install: $install_hint"
            ERRORS=$((ERRORS + 1))
            return 1
        else
            echo -e "${YELLOW}[WARN]${NC} $cmd not found (optional)"
            echo "       Install: $install_hint"
            WARNINGS=$((WARNINGS + 1))
            return 0
        fi
    fi
}

# Function to check if a file exists
check_file() {
    local file="$1"
    local required="$2"

    if [ -f "$file" ]; then
        echo -e "${GREEN}[OK]${NC} $file exists"
        return 0
    else
        if [ "$required" = "required" ]; then
            echo -e "${RED}[FAIL]${NC} $file not found (required)"
            ERRORS=$((ERRORS + 1))
            return 1
        else
            echo -e "${YELLOW}[WARN]${NC} $file not found (optional)"
            WARNINGS=$((WARNINGS + 1))
            return 0
        fi
    fi
}

echo "--- Required Tools ---"
check_command "uv" "required" "curl -LsSf https://astral.sh/uv/install.sh | sh"
check_command "claude" "required" "npm install -g @anthropic-ai/claude-code"
check_command "jq" "required" "brew install jq"
check_command "git" "required" "brew install git"

echo ""
echo "--- Optional Tools ---"
check_command "gh" "optional" "brew install gh"

# Check for ASH availability via uvx
echo ""
echo "--- ASH Availability ---"
if command -v uvx &> /dev/null; then
    # Try to check if ASH can be invoked (just check help, don't actually run)
    if uvx --from git+https://github.com/awslabs/automated-security-helper.git@v3.1.5 ash --help &>/dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} ASH available via uvx"
    else
        echo -e "${YELLOW}[INFO]${NC} ASH will be downloaded on first run via uvx"
        echo "       This is normal - ASH is fetched automatically when needed"
    fi
else
    echo -e "${RED}[FAIL]${NC} uvx not available (uv required for ASH)"
    echo "       Install uv: curl -LsSf https://astral.sh/uv/install.sh | sh"
    ERRORS=$((ERRORS + 1))
fi

# Check for claude-code-transcripts availability via uvx
if command -v uvx &> /dev/null; then
    if uvx --help claude-code-transcripts &> /dev/null 2>&1 || uvx claude-code-transcripts --help &> /dev/null 2>&1; then
        echo -e "${GREEN}[OK]${NC} claude-code-transcripts available via uvx"
    else
        echo -e "${YELLOW}[WARN]${NC} claude-code-transcripts not available (optional)"
        echo "       Transcript extraction will be skipped"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

echo ""
echo "--- Project Files ---"
check_file "$PROJECT_DIR/prompt.md" "required"
check_file "$PROJECT_DIR/.claude/settings.local.json" "required"
check_file "$PROJECT_DIR/rules/semgrep-rules.yml" "required"
check_file "$PROJECT_DIR/.ash/ash.yaml" "optional"
check_file "$PROJECT_DIR/config/thresholds.json" "optional"

echo ""
echo "--- PRD File ---"
if [ -n "$RALPH_PROJECT_NAME" ]; then
    echo -e "${GREEN}[INFO]${NC} Project: $RALPH_PROJECT_NAME"
    echo -e "${GREEN}[INFO]${NC} State directory: $STATE_DIR"
fi

if [ -f "$STATE_DIR/prd.json" ]; then
    echo -e "${GREEN}[OK]${NC} PRD file exists at $STATE_DIR/prd.json"

    # Validate JSON structure
    if jq empty "$STATE_DIR/prd.json" 2>/dev/null; then
        echo -e "${GREEN}[OK]${NC} PRD is valid JSON"

        # Check for required fields
        if jq -e '.userStories' "$STATE_DIR/prd.json" > /dev/null 2>&1; then
            STORY_COUNT=$(jq '.userStories | length' "$STATE_DIR/prd.json")
            echo -e "${GREEN}[OK]${NC} PRD has $STORY_COUNT user stories"
        else
            echo -e "${RED}[FAIL]${NC} PRD missing 'userStories' array"
            ERRORS=$((ERRORS + 1))
        fi
    else
        echo -e "${RED}[FAIL]${NC} PRD is not valid JSON"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo -e "${YELLOW}[INFO]${NC} No PRD file at $STATE_DIR/prd.json"
    echo "       Copy prd.json.example to $STATE_DIR/prd.json and customize"
fi

echo ""
echo "--- Git Repository ---"
if git rev-parse --git-dir > /dev/null 2>&1; then
    echo -e "${GREEN}[OK]${NC} Inside a git repository"

    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    echo -e "${GREEN}[OK]${NC} Current branch: $BRANCH"

    # Check for uncommitted changes
    if [ -n "$(git status --porcelain)" ]; then
        echo -e "${YELLOW}[WARN]${NC} Uncommitted changes detected"
        WARNINGS=$((WARNINGS + 1))
    else
        echo -e "${GREEN}[OK]${NC} Working directory clean"
    fi
else
    echo -e "${RED}[FAIL]${NC} Not inside a git repository"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "=== Summary ==="
if [ $ERRORS -gt 0 ]; then
    echo -e "${RED}Pre-flight failed with $ERRORS error(s) and $WARNINGS warning(s)${NC}"
    exit 1
elif [ $WARNINGS -gt 0 ]; then
    echo -e "${YELLOW}Pre-flight passed with $WARNINGS warning(s)${NC}"
    exit 0
else
    echo -e "${GREEN}All pre-flight checks passed${NC}"
    exit 0
fi
