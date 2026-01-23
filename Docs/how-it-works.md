# How It Works

Securing Ralph Loop orchestrates Claude Code with security-hardened constraints, automated scanning, and human escalation.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    ralph-secure.sh                               │
├─────────────────────────────────────────────────────────────────┤
│  Pre-flight    →    Spawn Claude    →    Decision Gate          │
│  Checks              Code                                       │
│                         │                                        │
│                         ▼                                        │
│              ┌──────────────────────┐                           │
│              │   Claude Session     │                           │
│              │  ┌────────────────┐  │                           │
│              │  │ Read PRD       │  │                           │
│              │  │ Implement      │  │                           │
│              │  │ /security-scan │←─┼── ASH/Semgrep/Grype       │
│              │  │ Fix or Commit  │  │                           │
│              │  └────────────────┘  │                           │
│              └──────────────────────┘                           │
│                         │                                        │
│                         ▼                                        │
│              All stories pass? ──No──→ Next iteration           │
│                    │                        (max N)              │
│                   Yes                                            │
│                    ▼                                             │
│              Session complete                                    │
└─────────────────────────────────────────────────────────────────┘
```

## Phases

### 1. Pre-flight Checks

Before any iteration, the orchestrator validates:

| Check | Validation |
|-------|------------|
| `claude` CLI | Must be installed and on PATH |
| `uv` | Required for ASH scanner |
| `jq` | Required for JSON processing |
| Git repo | Target must be a git repository |
| Clean state | No uncommitted changes (optional) |

### 2. Branch Isolation

Each session creates an isolated branch:

```
ralph/{project-name}-{timestamp}
```

This prevents polluting `main` with potentially vulnerable intermediate commits.

### 3. Security Baseline

Before Claude makes any changes, the orchestrator:

1. Runs ASH scan on current HEAD
2. Captures all existing vulnerabilities as "baseline"
3. Stores in `state/{project}/security-baseline.json`

This distinguishes **new** vulnerabilities (introduced by Claude) from **pre-existing** ones (inherited debt).

### 4. Development Iterations

Each iteration:

1. **Read PRD** - Find first incomplete user story
2. **Implement** - Claude writes code following security patterns
3. **Self-check** - Run `/self-check` for code quality
4. **Security scan** - Run `/security-scan` (mandatory before commit)
5. **Decision**:
   - **PASS**: Commit changes, update PRD, continue
   - **FAIL**: Fix issues (up to 3 retries), then escalate

### 5. Security Scanning

The `/security-scan` skill runs **inside** Claude's session, giving it full context to fix issues:

```
┌─────────────────────────────────────┐
│         /security-scan              │
├─────────────────────────────────────┤
│  ASH (Automated Security Helper)    │
│  ├── Semgrep (SAST)                │
│  ├── Bandit (Python)               │
│  ├── Checkov (IaC)                 │
│  ├── detect-secrets                │
│  └── Grype (SCA)                   │
│                                     │
│  Custom rules: .ash/rules/         │
│  Config: .ash/ash.yaml             │
└─────────────────────────────────────┘
```

### 6. Decision Gate

After each scan:

| Result | Action |
|--------|--------|
| **PASS** | Commit and continue |
| **FAIL (attempt 1-2)** | Fix and retry |
| **FAIL (attempt 3)** | Escalate to human |

### 7. Escalation

When Claude cannot resolve a security issue after 3 attempts:

1. Creates local escalation report (`escalation-report-*.md`)
2. Sends desktop notification (macOS/Linux)
3. Sends Slack notification (if configured)
4. Logs to `progress.txt`
5. Moves to next story

**Note:** Escalations do NOT create GitHub issues. They require immediate human attention via local report and notifications.

### 8. Audit Trail

Every iteration is logged:

| File | Format | Purpose |
|------|--------|---------|
| `security-audit.jsonl` | JSON Lines | Machine-readable audit log |
| `progress.txt` | Plain text | Human-readable narrative |
| `transcripts/iteration-N.html` | HTML | Full Claude conversation |

## Directory Structure

```
securing-ralph-loop/
├── ralph-secure.sh          # Main orchestrator
├── prompt.md                # Base instructions for Claude
├── CLAUDE.md                # Security guidelines (injected)
├── config/
│   └── thresholds.json      # Scan thresholds
├── .ash/
│   ├── ash.yaml             # ASH configuration
│   └── rules/
│       └── semgrep-rules.yml # Custom security rules
├── scripts/
│   ├── pre-flight.sh        # Validation checks
│   ├── audit-log.sh         # Audit logging
│   ├── log-progress.sh      # Progress logging
│   ├── escalate.sh          # Human escalation
│   └── report-preexisting.sh # Pre-existing vuln reporting
└── state/{project}/
    ├── prd.json             # User stories
    ├── progress.txt         # Session notes
    ├── security-audit.jsonl # Audit log
    ├── security-baseline.json # Pre-existing vulns
    └── transcripts/         # Session transcripts
```

## Environment Variables

When running inside the loop, these are available:

| Variable | Description |
|----------|-------------|
| `RALPH_PROJECT_NAME` | Current project name |
| `RALPH_PROJECT_STATE_DIR` | Full path to state directory |
| `RALPH_TARGET_DIR` | Full path to target directory |
| `RALPH_SLACK_WEBHOOK` | Slack webhook URL (if configured) |
| `RALPH_CREATE_SECURITY_ISSUES` | Whether to create GitHub issues |

## Session Flow Example

```bash
$ ./ralph-secure.sh /path/to/my-app

╭─────────────────────────────────────────────────────────────╮
│  Securing Ralph Loop v0.1.0                                  │
╰─────────────────────────────────────────────────────────────╯

  Project          │ my-app
  Target           │ /path/to/my-app
  Max iterations   │ 10

  ✓ Pre-flight     │ passed

  Branch           │ ralph/my-app-20250123-154500

  Baseline         │ Checking for pre-existing vulnerabilities...
  ⚠ Baseline       │ 3 pre-existing findings captured

═══════════════════════════════════════════════════════════════
  Iteration 1 of 10
═══════════════════════════════════════════════════════════════

  Story            │ US-001: Add login page
  ✓ Reading code   │ US-001: Add login page [00:05]
  ✓ Implementing   │ US-001: Add login page [00:42]
  ✓ Security scan  │ US-001: Add login page [01:15]
  ✓ Committing     │ US-001: Add login page [01:22]
  ✓ Done           │ US-001: Add login page [01:25]

  Summary          │ 12 reads, 4 edits, 8 commands, 1 skills
  Remaining        │ 2 stories

═══════════════════════════════════════════════════════════════
  Session Complete
═══════════════════════════════════════════════════════════════

  ✓ Status         │ All stories completed
  Branch           │ ralph/my-app-20250123-154500
  Transcripts      │ 3 iterations saved

  Next steps:
    git log main..ralph/my-app-20250123-154500
    gh pr create --base main
```
