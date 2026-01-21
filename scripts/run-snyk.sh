#!/bin/bash
#
# Run Snyk dependency vulnerability scan.
# This runs on the HOST machine, outside of Claude Code.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$PROJECT_DIR/state"
RULES_DIR="$PROJECT_DIR/rules"

# Check if snyk is available
if ! command -v snyk &> /dev/null; then
    echo "SKIP:snyk_not_found"
    exit 0
fi

# Check if snyk is authenticated
if ! snyk auth check &> /dev/null 2>&1; then
    echo "SKIP:snyk_not_authenticated"
    exit 0
fi

# Get the target directory (defaults to current directory)
TARGET_DIR="${1:-.}"

# Create a temporary file for results
RESULT_FILE=$(mktemp)
trap "rm -f $RESULT_FILE" EXIT

# Determine what to scan based on available files
SCAN_TYPE=""
if [ -f "$TARGET_DIR/package.json" ]; then
    SCAN_TYPE="npm"
elif [ -f "$TARGET_DIR/Cargo.toml" ]; then
    SCAN_TYPE="cargo"
elif [ -f "$TARGET_DIR/requirements.txt" ] || [ -f "$TARGET_DIR/pyproject.toml" ]; then
    SCAN_TYPE="pip"
elif [ -f "$TARGET_DIR/go.mod" ]; then
    SCAN_TYPE="go"
else
    echo "SKIP:no_manifest_found"
    exit 0
fi

# Apply Snyk policy if it exists
POLICY_ARG=""
if [ -f "$RULES_DIR/.snyk" ]; then
    POLICY_ARG="--policy-path=$RULES_DIR/.snyk"
fi

# Run Snyk test
# --json for machine-readable output
# --severity-threshold=medium to focus on important issues
snyk test \
    --json \
    --severity-threshold=medium \
    $POLICY_ARG \
    "$TARGET_DIR" > "$RESULT_FILE" 2>/dev/null || true

# Check if we got valid JSON
if ! jq empty "$RESULT_FILE" 2>/dev/null; then
    echo "ERROR:invalid_snyk_output"
    exit 2
fi

# Check for vulnerabilities
VULN_COUNT=$(jq '.vulnerabilities | length' "$RESULT_FILE" 2>/dev/null || echo "0")

if [ "$VULN_COUNT" -eq 0 ]; then
    echo "PASS"
    exit 0
fi

# Count by severity
CRITICAL=$(jq '[.vulnerabilities[] | select(.severity == "critical")] | length' "$RESULT_FILE" 2>/dev/null || echo "0")
HIGH=$(jq '[.vulnerabilities[] | select(.severity == "high")] | length' "$RESULT_FILE" 2>/dev/null || echo "0")
MEDIUM=$(jq '[.vulnerabilities[] | select(.severity == "medium")] | length' "$RESULT_FILE" 2>/dev/null || echo "0")

echo "FAIL:$VULN_COUNT (critical:$CRITICAL, high:$HIGH, medium:$MEDIUM)"

# Output detailed findings to stderr
jq -r '.vulnerabilities[] | "[\(.severity | ascii_upcase)] \(.packageName)@\(.version) - \(.title)"' "$RESULT_FILE" >&2

# Save findings to state for remediation context
jq '{
    vulnerabilities: [.vulnerabilities[] | {
        package: .packageName,
        version: .version,
        severity: .severity,
        title: .title,
        fixedIn: .fixedIn,
        upgradePath: .upgradePath
    }]
}' "$RESULT_FILE" > "$STATE_DIR/snyk-findings.json" 2>/dev/null || true

exit 1
