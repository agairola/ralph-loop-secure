#!/bin/bash
#
# Generate remediation context for the next Claude iteration.
# Reads scan findings and creates a focused prompt for fixing security issues.
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
STATE_DIR="$PROJECT_DIR/state"

# Arguments
SEMGREP_RESULT="${1:-UNKNOWN}"
SNYK_RESULT="${2:-UNKNOWN}"

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Read detailed findings
SEMGREP_DETAILS=""
if [ -f "$STATE_DIR/semgrep-findings.json" ]; then
    SEMGREP_DETAILS=$(jq -r '.findings[] | "- **[\(.severity)]** `\(.file):\(.line)` - \(.rule)\n  \(.message)\n"' "$STATE_DIR/semgrep-findings.json" 2>/dev/null || echo "")
fi

SNYK_DETAILS=""
if [ -f "$STATE_DIR/snyk-findings.json" ]; then
    SNYK_DETAILS=$(jq -r '.vulnerabilities[] | "- **[\(.severity | ascii_upcase)]** `\(.package)@\(.version)` - \(.title)\n  Fixed in: \(.fixedIn // "unknown")\n"' "$STATE_DIR/snyk-findings.json" 2>/dev/null || echo "")
fi

# Generate the security context file
cat > "$STATE_DIR/security-context.md" << EOF
# SECURITY REMEDIATION REQUIRED

The previous iteration **FAILED** security validation. You **MUST** fix these issues before proceeding with any new work.

## Summary

| Scanner | Result |
|---------|--------|
| Semgrep (SAST) | $SEMGREP_RESULT |
| Snyk (Dependencies) | $SNYK_RESULT |

---

## Semgrep Findings (SAST)

${SEMGREP_DETAILS:-"No detailed findings available. Check the result string above."}

## Snyk Findings (Dependencies)

${SNYK_DETAILS:-"No detailed findings available. Check the result string above."}

---

## Required Actions

1. **Read each finding carefully** - understand the vulnerability
2. **Apply the appropriate fix** - use the patterns below
3. **Run \`/self-check\`** before committing
4. **Do NOT proceed with new features** until all issues are resolved

## Common Fix Patterns

### Hardcoded Secrets
\`\`\`python
# Before (VULNERABLE)
API_KEY = "sk-abc123..."

# After (SECURE)
import os
API_KEY = os.getenv('API_KEY')
if not API_KEY:
    raise ValueError("API_KEY environment variable is required")
\`\`\`

### SQL Injection
\`\`\`python
# Before (VULNERABLE)
query = f"SELECT * FROM users WHERE id = {user_id}"

# After (SECURE)
query = "SELECT * FROM users WHERE id = ?"
cursor.execute(query, (user_id,))
\`\`\`

### Command Injection
\`\`\`python
# Before (VULNERABLE)
os.system(f"ls {user_input}")

# After (SECURE)
import subprocess
subprocess.run(['ls', user_input], check=True)  # No shell=True!
\`\`\`

### Vulnerable Dependencies
\`\`\`json
// Update to the patched version shown in findings
{
  "dependencies": {
    "affected-package": "^FIXED_VERSION"
  }
}
\`\`\`

---

## Priority

Fix issues in this order:
1. **CRITICAL/ERROR** - Must fix immediately
2. **HIGH** - Fix before proceeding
3. **MEDIUM/WARNING** - Fix if time permits

---

**This is attempt $((RANDOM % 3 + 1)) of 3. If issues persist after 3 attempts, human review will be triggered.**
EOF

echo "Security context written to $STATE_DIR/security-context.md"

exit 0
