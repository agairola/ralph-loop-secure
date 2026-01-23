# Security Model

Securing Ralph Loop implements defense-in-depth to prevent AI-generated vulnerabilities from reaching production.

## Threat Model

| Threat | Mitigation |
|--------|------------|
| **Hardcoded secrets** | Semgrep rules detect API keys, passwords, AWS credentials, private keys |
| **SQL injection** | Rules detect string concatenation/interpolation in queries |
| **Command injection** | Rules detect `shell=True`, `os.system()`, `exec()` |
| **Path traversal** | Rules detect unsanitized path concatenation |
| **Vulnerable dependencies** | Grype scans for CVEs in packages |
| **IaC misconfigurations** | Checkov validates Terraform, CloudFormation, Dockerfiles |
| **Weak cryptography** | Rules flag MD5, SHA1 for security purposes |
| **Unsafe deserialization** | Rules detect `pickle.load()`, `eval()` |
| **Prototype pollution** | Rules detect dynamic property assignment |
| **SSRF** | Rules detect user-controlled URLs in fetch/axios |

## Security Scanning Stack

### ASH (Automated Security Helper)

[ASH](https://github.com/awslabs/automated-security-helper) is the core scanner, orchestrating multiple tools:

```yaml
Scanners enabled:
  - Semgrep (SAST - multi-language)
  - Bandit (Python-specific SAST)
  - Checkov (IaC security)
  - detect-secrets (credential detection)
  - Grype (vulnerability scanning)
  - npm-audit (JS dependency audit)
  - Syft (SBOM generation)
```

### Semgrep Rules

Custom rules in `.ash/rules/semgrep-rules.yml` cover:

| Category | Rules |
|----------|-------|
| **Secrets** | Hardcoded credentials, AWS keys, private keys |
| **Injection** | SQL, command, NoSQL injection patterns |
| **Dangerous Functions** | `eval()`, `exec()`, `pickle.load()` |
| **Path Traversal** | Unsanitized file paths |
| **Cryptography** | Weak hash algorithms (MD5, SHA1) |
| **SSRF** | User-controlled URLs |
| **Prototype Pollution** | Dynamic property assignment |

Example rule:

```yaml
- id: python-sql-injection-fstring
  pattern: |
    $QUERY = f"...$VAR..."
    ...
    $CURSOR.execute($QUERY)
  message: "Potential SQL injection via f-string. Use parameterized queries."
  severity: ERROR
  languages:
    - python
  metadata:
    cwe: "CWE-89: SQL Injection"
```

### Grype (Software Composition Analysis)

Scans dependencies for known CVEs:

- Checks `package.json`, `requirements.txt`, `Cargo.toml`, etc.
- Fails on HIGH or CRITICAL severity
- Reports CVE IDs with remediation advice

### Checkov (Infrastructure as Code)

Validates:

- Dockerfiles (security best practices)
- Terraform (AWS, GCP, Azure misconfigurations)
- CloudFormation templates
- Kubernetes manifests
- Helm charts

## Baseline Delta Detection

The system distinguishes between **new** and **pre-existing** vulnerabilities:

```
┌─────────────────────────────────────────────────────────────┐
│                  Baseline Detection                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  [Session Start]                                             │
│       │                                                      │
│       ▼                                                      │
│  Scan current HEAD → security-baseline.json                 │
│       │                                                      │
│       ▼                                                      │
│  [Claude makes changes]                                      │
│       │                                                      │
│       ▼                                                      │
│  /security-scan → Compare against baseline                  │
│       │                                                      │
│       ├── In baseline? → PRE-EXISTING (tracked, not blocked)│
│       │                                                      │
│       └── Not in baseline? → NEW (blocks commit)            │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Why This Matters

Without baseline detection:
- Claude would be blocked by existing security debt
- Progress would halt on legacy codebases
- Every vulnerability would require immediate fixing

With baseline detection:
- Claude can proceed with legitimate work
- Pre-existing issues are tracked via GitHub issues
- Only NEW vulnerabilities introduced by Claude block commits

## Sandbox Constraints

Claude Code runs with restricted capabilities:

### Allowed

- File read/write/edit in target directory
- Git commands (add, commit, status, diff, log)
- Test runners (npm test, pytest, cargo test)
- Build tools (npm run, cargo build, uv)
- Security skills (`/security-scan`, `/fix-security`)

### Blocked

- Network commands (curl, wget)
- Privilege escalation (sudo)
- Dangerous deletions (rm -rf /)
- Access to SSH keys or credentials files

## Secure Coding Patterns

Claude is instructed to follow these patterns (from CLAUDE.md):

### Credentials

```python
# BAD
API_KEY = "sk-abc123..."

# GOOD
import os
API_KEY = os.getenv('API_KEY')
```

### SQL Queries

```python
# BAD
query = f"SELECT * FROM users WHERE id = {user_id}"

# GOOD
query = "SELECT * FROM users WHERE id = ?"
cursor.execute(query, (user_id,))
```

### Command Execution

```python
# BAD
os.system(f"ls {user_input}")

# GOOD
import subprocess
subprocess.run(['ls', user_input], check=True)
```

### Dynamic Code

```python
# BAD
eval(user_input)

# GOOD
import ast
result = ast.literal_eval(safe_input)
```

## Remediation Workflow

When a security issue is found:

1. **Attempt 1**: Claude reads findings, applies fix, re-scans
2. **Attempt 2**: Claude tries alternative approach, re-scans
3. **Attempt 3**: Claude tries final approach, re-scans
4. **Escalation**: Creates GitHub issue, notifies human

```
/security-scan
     │
     ▼
  FAIL?
     │
     ├── Attempt < 3: Fix and retry
     │
     └── Attempt = 3: Escalate
            │
            ├── Create GitHub issue
            ├── Send Slack notification
            └── Log to progress.txt
```

## Audit Trail

All security-relevant events are logged:

### security-audit.jsonl

```json
{
  "timestamp": "2025-01-23T15:45:00Z",
  "iteration": 1,
  "story_id": "US-001",
  "scan_result": "PASS",
  "duration_seconds": 125,
  "exit_code": 0
}
```

### Transcripts

Full Claude conversation history for each iteration, including:
- Files read and modified
- Security scan output
- Remediation attempts
- Final commit message

## GitHub Issue Integration

Pre-existing vulnerabilities create trackable issues:

```
Title: Security Debt: SQL Injection in user_service.py
Labels: security-debt, ralph-detected

## Finding Details
- File: src/user_service.py
- Line: 45
- Rule: python-sql-injection-fstring
- Severity: ERROR

## Description
Potential SQL injection via f-string. Use parameterized queries.

## Recommended Fix
```python
# Instead of:
query = f"SELECT * FROM users WHERE id = {user_id}"

# Use:
query = "SELECT * FROM users WHERE id = ?"
cursor.execute(query, (user_id,))
```

---
Detected by Securing Ralph Loop
```
