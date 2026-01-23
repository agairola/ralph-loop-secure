# CLAUDE.md - Securing Ralph Loop

This file provides guidance to Claude Code when operating within the Securing Ralph Loop orchestration system.

## Context

You are running inside **Securing Ralph Loop**, a security-hardened orchestration system. Security scanning runs INSIDE your session via the `/security-scan` skill, giving you direct control over the scan-fix-retry cycle.

## Your Constraints

### What You CAN Do

- Read, write, and edit files in the target directory
- Run git commands (add, commit, status, diff, log)
- Run tests (npm test, cargo test, pytest)
- Run build tools (npm run, cargo build, uv)
- Use the skills: `/code-review`, `/self-check`, `/security-scan`, `/fix-security`, `/check`

### What You CANNOT Do

- Run curl, wget, or network commands (blocked by sandbox)
- Use sudo or escalate privileges
- Delete root directories (rm -rf /)
- Access SSH keys or credentials files

## Security Requirements

### Never Do This

```python
# BAD: Hardcoded secrets
API_KEY = "sk-abc123..."

# BAD: SQL injection
query = f"SELECT * FROM users WHERE id = {user_id}"

# BAD: Command injection
os.system(f"ls {user_input}")

# BAD: eval with user input
eval(user_input)
```

### Always Do This

```python
# GOOD: Environment variables
import os
API_KEY = os.getenv('API_KEY')

# GOOD: Parameterized queries
query = "SELECT * FROM users WHERE id = ?"
cursor.execute(query, (user_id,))

# GOOD: subprocess without shell
import subprocess
subprocess.run(['ls', user_input], check=True)

# GOOD: Safe alternatives to eval
import ast
result = ast.literal_eval(safe_input)
```

## Workflow

1. **Read PRD** - `state/{project}/prd.json` contains user stories
2. **Find incomplete story** - where `passes` is `false`
3. **Implement securely** - follow security requirements above
4. **Self-check** - run `/self-check` for code quality
5. **Security scan** - run `/security-scan` before committing
6. **If PASS** - commit and update PRD
7. **If FAIL** - fix issues (max 3 attempts), then escalate via GitHub issue

Note: The `{project}` placeholder is automatically derived from your target directory name, or can be set explicitly with `--project`.

## Security Scan: New vs Pre-Existing Findings

The security scan distinguishes between **NEW** and **PRE-EXISTING** findings:

- **NEW Findings**: Introduced by your current changes - these block commits
- **PRE-EXISTING Findings**: Existed before your work started - tracked but don't block

This allows you to proceed with legitimate work without being blocked by inherited security debt.

### How It Works

1. At session start, a **baseline** is captured (`security-baseline.json`)
2. When you run `/security-scan`, findings are compared against the baseline
3. Only NEW findings (not in baseline) cause a FAIL
4. Pre-existing findings are logged and optionally create GitHub issues

### If Security Scan Fails

When `/security-scan` returns FAIL (due to NEW findings):

1. **Read findings carefully** - file:line, severity, message
2. **Fix each issue** using secure patterns above
3. **Stage fixes** - `git add -A`
4. **Re-run** `/security-scan`
5. **Repeat** up to 3 times total

### After 3 Failed Attempts

1. **DO NOT commit** vulnerable code
2. **Create GitHub issue** for human review:
   ```bash
   gh issue create \
     --title "Security: [STORY_ID] - Unable to resolve [VULN_TYPE]" \
     --body "..." \
     --label "security,ralph-escalation"
   ```
3. **Add note** to progress.txt
4. **Move to next** incomplete story

## Skills Reference

**IMPORTANT: Use these EXACT skill names. Do NOT prefix with `ralph-loop:` or any other namespace.**

| Skill | Purpose |
|-------|---------|
| `/check` | Quick status check of PRD progress |
| `/security-scan` | Run ASH security scanner (MANDATORY before commit) |
| `/code-review` | Security-focused code review before committing |
| `/self-check` | Pre-commit validation for code quality and security |
| `/fix-security` | Apply fixes based on scanner findings |

**Examples:**
- Correct: `/security-scan`
- Wrong: `ralph-loop:security-scan`

If a skill fails with "Unknown skill", ensure you're using the exact name without any prefix.

## Important Notes

- **Security scans run INSIDE your session** - you have full context to fix issues
- **Scan BEFORE committing** - never commit code that fails security scan
- **3 retries max** - after that, escalate via GitHub issue
- **All operations logged** - for audit and compliance
- **Transcripts extracted** - detailed audit trail of each iteration

## File Locations

All paths below with `{project}` are per-project (e.g., `state/my-app/prd.json`).

| File | Purpose |
|------|---------|
| `state/{project}/prd.json` | User stories to implement |
| `state/{project}/progress.txt` | Learnings from previous iterations |
| `state/{project}/security-audit.jsonl` | Audit log (don't modify) |
| `state/{project}/security-baseline.json` | Pre-existing vulnerabilities baseline |
| `state/{project}/preexisting-findings.json` | Current session's pre-existing findings |
| `state/{project}/transcripts/` | Session transcripts for each iteration |
| `prompt.md` | Base instructions |
| `.ash/ash.yaml` | ASH security scanner configuration |
| `.ash/ash_output/` | ASH scan results (don't commit) |
| `config/thresholds.json` | Scan thresholds |
| `rules/semgrep-rules.yml` | Custom Semgrep rules (used by ASH) |

## Environment Variables

When running inside the loop, these environment variables are available:

| Variable | Description |
|----------|-------------|
| `RALPH_PROJECT_NAME` | Current project name |
| `RALPH_PROJECT_STATE_DIR` | Full path to project state directory |
| `RALPH_TARGET_DIR` | Full path to target directory |
| `RALPH_CREATE_SECURITY_ISSUES` | Create GitHub issues for pre-existing vulns (default: `true`) |

### Opt-out of GitHub Issue Creation

To disable automatic GitHub issue creation for pre-existing vulnerabilities:

```bash
RALPH_CREATE_SECURITY_ISSUES=false ./ralph-secure.sh /path/to/project
```

When disabled:
- Pre-existing findings are still tracked in the audit log
- They are still displayed in the session summary
- No GitHub issues are created
