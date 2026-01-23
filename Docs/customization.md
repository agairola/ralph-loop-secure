# Customization

Configure security rules, thresholds, skills, and multi-project setups.

## Adding Semgrep Rules

Custom rules go in `.ash/rules/semgrep-rules.yml`:

```yaml
rules:
  - id: my-custom-rule
    pattern: dangerous_function($X)
    message: "Avoid dangerous_function. Use safe_alternative instead."
    severity: ERROR
    languages:
      - python
    metadata:
      category: security
      cwe: "CWE-XXX: Description"
```

### Rule Anatomy

| Field | Description |
|-------|-------------|
| `id` | Unique identifier (used in suppressions) |
| `pattern` | Code pattern to match (Semgrep syntax) |
| `message` | Explanation shown to Claude |
| `severity` | `ERROR`, `WARNING`, or `INFO` |
| `languages` | Target languages |
| `metadata` | Additional context (CWE, category) |

### Pattern Examples

**Simple function call:**
```yaml
pattern: eval($X)
```

**Method chain:**
```yaml
pattern: $DB.query(`...${$VAR}...`)
```

**Multi-line with ellipsis:**
```yaml
pattern: |
  $QUERY = f"...$VAR..."
  ...
  $CURSOR.execute($QUERY)
```

**Multiple patterns (OR):**
```yaml
patterns:
  - pattern: crypto.createHash("md5")
  - pattern: crypto.createHash('md5')
```

**Pattern with negation:**
```yaml
patterns:
  - pattern: fetch($URL)
  - pattern-not: fetch("...")
```

## Adjusting Thresholds

Edit `config/thresholds.json`:

```json
{
  "semgrep": {
    "enabled": true,
    "failOn": {
      "error": true,
      "warning": false,
      "info": false
    },
    "maxFindings": {
      "error": 0,
      "warning": 10,
      "info": -1
    },
    "ignoredRules": [],
    "ignoredPaths": [
      "**/test/**",
      "**/tests/**"
    ]
  },
  "remediation": {
    "maxRetries": 3,
    "rollbackOnFailure": true,
    "escalateAfterRetries": true
  },
  "iteration": {
    "maxIterations": 10,
    "timeoutSeconds": 3600
  }
}
```

### Key Settings

| Setting | Description | Default |
|---------|-------------|---------|
| `semgrep.failOn.error` | Fail on ERROR severity | `true` |
| `semgrep.failOn.warning` | Fail on WARNING severity | `false` |
| `semgrep.maxFindings.error` | Max allowed ERRORs | `0` |
| `remediation.maxRetries` | Fix attempts before escalation | `3` |
| `iteration.maxIterations` | Max loop iterations | `10` |

### Ignoring Specific Rules

```json
{
  "semgrep": {
    "ignoredRules": [
      "js-insecure-random",
      "rust-unwrap-in-production"
    ]
  }
}
```

### Ignoring Paths

```json
{
  "semgrep": {
    "ignoredPaths": [
      "**/test/**",
      "**/fixtures/**",
      "**/migrations/**"
    ]
  }
}
```

## ASH Configuration

Edit `.ash/ash.yaml` for scanner-level settings:

```yaml
global_settings:
  severity_threshold: MEDIUM  # CRITICAL, HIGH, MEDIUM, LOW
  fail_on_findings: true

  ignore_paths:
    - path: 'node_modules/**'
      reason: 'Third-party dependencies'
    - path: 'venv/**'
      reason: 'Virtual environment'

scanners:
  semgrep:
    enabled: true
    options:
      config: ./.ash/rules/semgrep-rules.yml
      rulesets:
        - p/security-audit
        - p/secrets
        - p/owasp-top-ten

  grype:
    enabled: true
    options:
      fail_on_severity: high

  checkov:
    enabled: true
    options:
      frameworks:
        - dockerfile
        - terraform
        - kubernetes
```

### Disabling Scanners

```yaml
scanners:
  bandit:
    enabled: false  # Disable Python-specific scanning

  cfn-nag:
    enabled: false  # Disable CloudFormation scanning
```

### Adjusting Severity Thresholds

```yaml
scanners:
  semgrep:
    options:
      severity_threshold: WARNING  # ERROR, WARNING, INFO

  grype:
    options:
      fail_on_severity: critical  # critical, high, medium, low
```

## Custom Skills

Skills live in `.claude/skills/`. Each skill has:

```
.claude/skills/
└── my-skill/
    └── SKILL.md
```

### Skill Structure

```markdown
# My Custom Skill

## Description
Brief description of what this skill does.

## Instructions

When invoked, do the following:

1. Step one
2. Step two
3. Step three

## Example Output

Expected result format.
```

### Available Skills

| Skill | Purpose |
|-------|---------|
| `/check` | Quick PRD progress status |
| `/security-scan` | Run ASH security scanner |
| `/code-review` | Security-focused code review |
| `/self-check` | Pre-commit validation |
| `/fix-security` | Apply fixes from scan findings |

### Creating a New Skill

1. Create directory: `.claude/skills/my-skill/`
2. Create `SKILL.md` with instructions
3. Invoke with `/my-skill`

Example custom skill:

```markdown
# Performance Audit

## Description
Analyze code for performance issues.

## Instructions

1. Read the target file(s)
2. Look for:
   - N+1 queries
   - Unnecessary re-renders
   - Missing memoization
   - Large bundle imports
3. Report findings with line numbers
4. Suggest optimizations

## Output Format

```
## Performance Findings

### [File: path/to/file.ts]

**Line 45**: N+1 query in loop
- Issue: Database query inside forEach
- Fix: Use batch query outside loop

**Line 102**: Missing useMemo
- Issue: Expensive computation on every render
- Fix: Wrap in useMemo with [deps]
```
```

## Multi-Project Support

Run on multiple projects with isolated state:

```bash
# Project A
./ralph-secure.sh --project app-a --target /path/to/app-a

# Project B
./ralph-secure.sh --project app-b --target /path/to/app-b
```

### State Isolation

Each project gets its own state directory:

```
state/
├── app-a/
│   ├── prd.json
│   ├── progress.txt
│   ├── security-audit.jsonl
│   ├── security-baseline.json
│   └── transcripts/
└── app-b/
    ├── prd.json
    ├── progress.txt
    ├── security-audit.jsonl
    ├── security-baseline.json
    └── transcripts/
```

### Project Name Derivation

If `--project` is not specified, the name is derived from the target directory:

```bash
./ralph-secure.sh /path/to/My-App
# Project name: my-app (lowercase, sanitized)
```

### Shared Configuration

All projects share:
- Security rules (`.ash/rules/`)
- ASH configuration (`.ash/ash.yaml`)
- Thresholds (`config/thresholds.json`)
- Skills (`.claude/skills/`)

### Per-Project PRD

Each project has its own PRD in `state/{project}/prd.json`:

```json
{
  "projectName": "App A",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add authentication",
      "description": "OAuth2 login with Google",
      "passes": false
    }
  ]
}
```

## Notification Configuration

### Slack Notifications

```bash
./ralph-secure.sh \
  --slack-webhook https://hooks.slack.com/services/XXX/YYY/ZZZ \
  /path/to/project
```

Notifications sent for:
- Session start
- Escalations
- Session completion

### GitHub Issues

By default, pre-existing vulnerabilities create GitHub issues:

```bash
# Disable issue creation
./ralph-secure.sh --no-create-issues /path/to/project
```

Configure labels in `config/thresholds.json`:

```json
{
  "baseline": {
    "issue_labels": ["security-debt", "ralph-detected"],
    "dedup_by_file": true
  }
}
```

## Secrets Baseline

For known false positives in secret detection, edit `.ash/secrets.baseline`:

```json
{
  "version": "1.0",
  "filters_used": [],
  "results": {
    "config/example.yaml": [
      {
        "type": "Base64 High Entropy String",
        "line_number": 10,
        "is_secret": false
      }
    ]
  }
}
```

Run `detect-secrets scan --update .ash/secrets.baseline` to add new exclusions.
