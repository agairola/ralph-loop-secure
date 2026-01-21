# CLAUDE.md - Ralph Loop Secure

This file provides guidance to Claude Code when operating within the Ralph Loop Secure orchestration system.

## Context

You are running inside **Ralph Loop Secure**, a security-hardened orchestration system. Your code will be validated by external security scanners after each commit.

## Your Constraints

### What You CAN Do

- Read, write, and edit files in the target directory
- Run git commands (add, commit, status, diff, log)
- Run tests (npm test, cargo test, pytest)
- Run build tools (npm run, cargo build, uv)
- Use the skills: `/code-review`, `/self-check`, `/fix-security`, `/check`

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

1. **Read PRD** - `state/prd.json` contains user stories
2. **Find incomplete story** - where `passes` is `false`
3. **Implement securely** - follow security requirements above
4. **Self-check** - run `/self-check` before committing
5. **Commit** - one story per commit
6. **Update PRD** - set `passes: true` for completed story

## If Security Scan Fails

You will receive a `security-context.md` file with:
- What scanner found (Semgrep/Snyk)
- Specific findings with file:line references
- Recommended fixes

Your job is to:
1. Read the findings carefully
2. Fix each issue using secure patterns
3. Run `/self-check` to verify
4. Commit the fix

## Skills Reference

### /code-review
Security-focused code review before committing.

### /self-check
Pre-commit validation for code quality and security.

### /fix-security
Apply fixes based on scanner findings (used during remediation).

### /check
Quick status check of PRD progress.

## Important Notes

- **External scanners run on HOST** - they see your committed code
- **Commits can be rolled back** - if scans fail, you'll need to fix
- **3 retries max** - after that, human escalation
- **All operations logged** - for audit and compliance

## File Locations

| File | Purpose |
|------|---------|
| `state/prd.json` | User stories to implement |
| `state/security-context.md` | Injected when remediation needed |
| `state/security-audit.jsonl` | Audit log (don't modify) |
| `prompt.md` | Base instructions |
| `config/thresholds.json` | Scan thresholds |
