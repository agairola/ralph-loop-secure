---
name: security-scan
description: Run ASH (Automated Security Helper) security scan with delta detection
allowed-tools: Read, Grep, Glob, Bash(uvx:*), Bash(ash:*), Bash(jq:*), Bash(git:diff|status|log), Bash(cat:*), Bash(mkdir:*)
---

# Security Scan

Run ASH (Automated Security Helper) - a comprehensive security scanning tool that bundles multiple scanners into a unified interface. This skill includes **delta detection** to distinguish NEW findings (your changes) from PRE-EXISTING findings (inherited security debt).

## Purpose

This skill performs security scanning using ASH, which includes:
- **Semgrep** (SAST) - Static code analysis with custom rules support
- **Bandit** (SAST) - Python-specific security analysis
- **Grype** (SCA) - Dependency vulnerability scanning (replaces Snyk, no auth needed)
- **detect-secrets** - Hardcoded secret detection
- **Checkov** (IaC) - Terraform, CloudFormation, Kubernetes, Dockerfile scanning

## What It Scans

| Scanner | Type | What It Does |
|---------|------|--------------|
| Semgrep | SAST | Multi-language code analysis (includes custom rules) |
| Bandit | SAST | Python-specific security analysis |
| Grype | SCA | Multi-language dependency scanning |
| detect-secrets | Secrets | All text files for hardcoded secrets |
| Checkov | IaC | Infrastructure-as-code validation |

## Usage

```
/security-scan
```

Run this skill after implementing a story and staging changes, but BEFORE committing.

## Scan Process

1. **Run ASH**: Execute ASH scan against the project
2. **Load Baseline**: Read `state/{project}/security-baseline.json` (pre-existing findings)
3. **Classify Findings**: Compare each finding against baseline
   - **NEW**: Finding not in baseline (introduced by your changes)
   - **PRE-EXISTING**: Finding exists in baseline (inherited security debt)
4. **Report**: Output both categories separately
5. **PASS/FAIL**: Decision based on **NEW findings only**

## Scan Execution

### Step 1: Run ASH

```bash
# Create output directory
mkdir -p .ash/ash_output

# Run ASH in local mode (Python tools via UV)
uvx --from git+https://github.com/awslabs/automated-security-helper.git@v3.1.5 \
  ash --mode local --source-dir . --output-dir .ash/ash_output
```

### Step 2: Load Baseline

```bash
# Read baseline from Ralph Loop state directory
# The baseline was captured at the start of the session, before you made changes
cat "$RALPH_PROJECT_STATE_DIR/security-baseline.json" | jq '.'
```

The baseline file contains findings captured before you started working:
```json
[
  {"file": "src/old-file.ts", "line": 15, "rule_id": "dangerous-eval", "severity": "ERROR"},
  ...
]
```

### Step 3: Classify Findings

Compare current scan results against the baseline:

```bash
# Read current findings
CURRENT=$(cat .ash/ash_output/ash_aggregated_results.json | jq -c '[.findings[]?]')

# Read baseline
BASELINE=$(cat "$RALPH_PROJECT_STATE_DIR/security-baseline.json" 2>/dev/null || echo "[]")

# A finding is NEW if it's not in the baseline
# Compare by: file + line + rule_id (signature matching)
```

**Classification Logic:**
- **NEW Finding**: `{file, line, rule_id}` tuple NOT found in baseline
- **PRE-EXISTING Finding**: `{file, line, rule_id}` tuple found in baseline AND file not modified in current changes

### Step 4: Check Results

```bash
# Read aggregated results
cat .ash/ash_output/ash_aggregated_results.json | jq '.'

# Or read the summary
cat .ash/ash_output/reports/ash.summary.txt
```

## Output Locations

ASH generates unified output in `.ash/ash_output/`:

| File | Description |
|------|-------------|
| `ash_aggregated_results.json` | Machine-readable results |
| `reports/ash.summary.txt` | Human-readable summary |
| `reports/ash.summary.md` | Markdown summary |
| `reports/ash.sarif` | SARIF format for IDE integration |
| `reports/ash.html` | Interactive HTML report |

## Output Format

After running ASH and classifying findings, report in this format:

```
=== Security Scan Results ===
Status: PASS | FAIL (based on NEW findings only)

NEW Findings (N total):
- [ERROR] file:line - scanner/rule-id
  Message: Description of the vulnerability
  Fix: Recommended remediation

- [WARNING] file:line - scanner/rule-id
  Message: Description
  Fix: Recommendation

PRE-EXISTING Findings (M total):
  ⚠ These findings existed before your changes
  ⚠ They do NOT block your commit

- [ERROR] src/lib/old-file.ts:15 - dangerous-eval
  This file was not modified in your changes.
  Recommendation: Create GitHub issue for tracking.

Dependency Vulnerabilities (P total):
- [HIGH] package@version - CVE-YYYY-XXXXX
  Title: Vulnerability title
  Fix: Upgrade to version X.Y.Z

=== Summary ===
NEW: X findings (blocking)
PRE-EXISTING: Y findings (tracked, non-blocking)
Overall: PASS | FAIL
```

## Decision Logic

**PASS/FAIL is based on NEW findings only:**

- **PASS**: No NEW ERROR-level findings, no NEW HIGH severity vulnerabilities
- **FAIL**: Any NEW ERROR-level finding OR any NEW HIGH severity vulnerability

**Pre-existing findings are:**
- Reported for visibility
- Logged to audit trail
- Tracked via GitHub issues (if enabled)
- **NOT blocking** - they don't cause FAIL

This allows you to proceed with legitimate work without being blocked by inherited security debt.

## After Scanning

### If PASS (new code is clean)
- Proceed to commit
- Update PRD to mark story complete
- Pre-existing issues are tracked but don't block you

### If FAIL (new code has issues)
1. Read each NEW finding carefully (file:line provided)
2. Apply fix using secure coding patterns from CLAUDE.md
3. Stage the fixes: `git add -A`
4. Re-run `/security-scan`
5. Repeat until PASS (max 3 attempts)

### If Still Failing After 3 Attempts
1. DO NOT commit vulnerable code
2. Create GitHub issue with findings (using `gh` CLI)
3. Add note to progress.txt
4. Move to next incomplete story

## GitHub Issue Escalation

When stuck after 3 attempts on NEW findings:

```bash
gh issue create \
  --title "Security: [STORY_ID] - Unable to resolve [VULN_TYPE]" \
  --body "## Findings

[Paste scanner findings here]

## Attempted Fixes

1. [Description of first fix attempt]
2. [Description of second fix attempt]
3. [Description of third fix attempt]

## Context

Story: [STORY_ID] - [STORY_TITLE]
Files affected: [list files]

Generated by Securing Ralph Loop" \
  --label "security,ralph-escalation"
```

## Pre-Existing Findings Tracking

Pre-existing vulnerabilities found in the baseline are:
1. **Logged** in the audit trail with classification
2. **Reported** to GitHub issues (if `RALPH_CREATE_SECURITY_ISSUES=true`, which is the default)
3. **Displayed** in session summary

You can disable GitHub issue creation for pre-existing findings:
```bash
RALPH_CREATE_SECURITY_ISSUES=false ./ralph-secure.sh ...
```

## Thresholds

ASH uses thresholds from `.ash/ash.yaml`:

```yaml
global_settings:
  severity_threshold: MEDIUM
  fail_on_findings: true
```

## Custom Rules

Your existing Semgrep rules are preserved. ASH runs Semgrep with both its default rulesets AND your custom rules:

```yaml
# In .ash/ash.yaml
scanners:
  semgrep:
    enabled: true
    options:
      config_paths:
        - rules/semgrep-rules.yml
```

## Troubleshooting

### ASH not found
ASH runs via uvx, ensure UV is installed:
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### UV not found
```bash
brew install uv
# or
pip install uv
```

### Permission denied
Ensure the output directory exists and is writable:
```bash
mkdir -p .ash/ash_output
```

### Scanner-specific issues
Check individual scanner logs in `.ash/ash_output/logs/`

### Baseline not found
If `$RALPH_PROJECT_STATE_DIR/security-baseline.json` doesn't exist:
- All findings will be treated as NEW
- This is expected on first run or if baseline wasn't captured
- Run `ralph-secure.sh` which handles baseline creation automatically
