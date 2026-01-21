#!/bin/bash
#
# Rollback the last commit after a failed security scan.
# Preserves the changes in the working directory for remediation.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$PROJECT_DIR/state"

echo "=== Rolling back last commit ==="

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "ERROR: Not in a git repository"
    exit 1
fi

# Get current commit info for logging
CURRENT_COMMIT=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
CURRENT_MESSAGE=$(git log -1 --pretty=%B 2>/dev/null || echo "unknown")

echo "Rolling back commit: ${CURRENT_COMMIT:0:8}"
echo "Message: $CURRENT_MESSAGE"

# Check if there are uncommitted changes
if [ -n "$(git status --porcelain)" ]; then
    echo "WARNING: Uncommitted changes detected"
    echo "Stashing changes before rollback..."
    git stash push -m "Pre-rollback stash $(date +%s)"
fi

# Soft reset to preserve changes in working directory
# This allows Claude to fix the issues without losing work
git reset --soft HEAD~1

echo "Commit rolled back (soft reset)"
echo "Changes are preserved in staging area for remediation"

# Log the rollback event
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
ROLLBACK_LOG="$STATE_DIR/rollback.log"

echo "$TIMESTAMP - Rolled back commit $CURRENT_COMMIT: $CURRENT_MESSAGE" >> "$ROLLBACK_LOG"

# Unstage changes so Claude can review them
git reset HEAD .

echo ""
echo "Changes are now in working directory (unstaged)"
echo "Ready for remediation"

exit 0
