#!/bin/bash
#
# Pre-flight checks before starting the secure Ralph loop.
# Validates that all required tools and files are available.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

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
check_command "docker" "required" "brew install --cask docker"
check_command "claude" "required" "npm install -g @anthropic-ai/claude-code"
check_command "semgrep" "required" "pip install semgrep OR brew install semgrep"
check_command "jq" "required" "brew install jq"
check_command "git" "required" "brew install git"

echo ""
echo "--- Optional Tools ---"
check_command "snyk" "optional" "npm install -g snyk && snyk auth"
check_command "gh" "optional" "brew install gh"

echo ""
echo "--- Docker Check ---"
if docker info &> /dev/null; then
    echo -e "${GREEN}[OK]${NC} Docker daemon is running"

    # Check if docker sandbox is available
    if docker help 2>&1 | grep -q "sandbox"; then
        echo -e "${GREEN}[OK]${NC} Docker sandbox feature available"
    else
        echo -e "${YELLOW}[WARN]${NC} Docker sandbox feature not detected"
        echo "       Requires Docker Desktop 4.50+ with sandbox support"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo -e "${RED}[FAIL]${NC} Docker daemon is not running"
    echo "       Start Docker Desktop"
    ERRORS=$((ERRORS + 1))
fi

echo ""
echo "--- Project Files ---"
check_file "$PROJECT_DIR/prompt.md" "required"
check_file "$PROJECT_DIR/.claude/settings.local.json" "required"
check_file "$PROJECT_DIR/rules/semgrep-rules.yml" "required"
check_file "$PROJECT_DIR/config/thresholds.json" "optional"

echo ""
echo "--- PRD File ---"
if [ -f "$PROJECT_DIR/state/prd.json" ]; then
    echo -e "${GREEN}[OK]${NC} PRD file exists at state/prd.json"

    # Validate JSON structure
    if jq empty "$PROJECT_DIR/state/prd.json" 2>/dev/null; then
        echo -e "${GREEN}[OK]${NC} PRD is valid JSON"

        # Check for required fields
        if jq -e '.userStories' "$PROJECT_DIR/state/prd.json" > /dev/null 2>&1; then
            STORY_COUNT=$(jq '.userStories | length' "$PROJECT_DIR/state/prd.json")
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
    echo -e "${YELLOW}[INFO]${NC} No PRD file at state/prd.json"
    echo "       Copy prd.json.example to state/prd.json and customize"
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
