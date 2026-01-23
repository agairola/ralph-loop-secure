# Securing Ralph Loop

Security-hardened orchestration shell script that spawns Claude Code instances with built-in security validation.

## Overview

Securing Ralph Loop is an **external orchestrator** that runs Claude Code with automated security scanning. Security validation happens **outside** Claude Code using external tools (Semgrep, Snyk) on the HOST machine.

```
HOST MACHINE (ralph-secure.sh orchestrator)
│
├─► Pre-flight checks
│
├─► Spawn Claude Code (implements story)
│
├─► External security scan (Semgrep, Snyk)
│
├─► Decision gate
│   ├─► PASS → next iteration
│   ├─► FAIL → remediation loop (max 3x)
│   └─► EXHAUSTED → human escalation
│
└─► Completion check
```

## Quick Start

```bash
# 1. Install dependencies
pip install semgrep
npm install -g snyk && snyk auth
brew install jq

# 2. Run the loop (PRD is auto-initialized from template)
./ralph-secure.sh 10 /path/to/my-project
# Edit state/my-project/prd.json with your user stories
```

## Prerequisites

| Tool | Required | Installation |
|------|----------|--------------|
| Docker Desktop 4.50+ | Yes | [Download](https://www.docker.com/products/docker-desktop/) |
| Claude Code CLI | Yes | `npm install -g @anthropic-ai/claude-code` |
| Semgrep | Yes | `pip install semgrep` or `brew install semgrep` |
| jq | Yes | `brew install jq` |
| Snyk | Optional | `npm install -g snyk && snyk auth` |

## Usage

```bash
# Basic usage (10 iterations max, current directory)
./ralph-secure.sh

# Target a specific directory (auto-derives project name)
./ralph-secure.sh 10 /path/to/my-app
# Creates state/my-app/ with prd.json

# Explicit project name
./ralph-secure.sh --project my-app --target /path/to/project

# Short form
./ralph-secure.sh -p my-app -t /path/to/project -m 10

# Skip Docker sandbox (for testing)
RALPH_SKIP_DOCKER=true ./ralph-secure.sh
```

### Multi-Project Support

Securing Ralph Loop supports running multiple projects in parallel with isolated state:

```bash
# Project A (terminal 1)
./ralph-secure.sh 10 /path/to/project-a
# State stored in: state/project-a/

# Project B (terminal 2)
./ralph-secure.sh 10 /path/to/project-b
# State stored in: state/project-b/

# Override project name if needed
./ralph-secure.sh --project custom-name --target /path/to/project
# State stored in: state/custom-name/
```

Each project gets its own:
- `prd.json` - User stories
- `security-audit.jsonl` - Audit trail
- Session/branch tracking files
- Escalation reports

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `RALPH_MAX_RETRIES` | Max remediation attempts per failure | 3 |
| `RALPH_SKIP_DOCKER` | Run without Docker sandbox | false |
| `RALPH_SLACK_WEBHOOK` | Slack webhook for notifications | - |
| `RALPH_CREATE_ISSUE` | Create GitHub issue on escalation | false |

The following are exported for child scripts:

| Variable | Description |
|----------|-------------|
| `RALPH_PROJECT_NAME` | Current project name (derived or explicit) |
| `RALPH_PROJECT_STATE_DIR` | Full path to project's state directory |

## How It Works

### 1. Pre-flight Checks

Before starting, the orchestrator validates:
- Required tools are installed (Docker, Claude, Semgrep, jq)
- PRD file exists and is valid JSON
- Git repository is initialized

### 2. Development Iterations

Each iteration:
1. Builds a prompt from `prompt.md` (+ any security context)
2. Spawns Claude Code in a Docker sandbox
3. Claude implements one user story from the PRD
4. Commits changes

### 3. Security Scanning

After each commit, **external** tools scan the changes:
- **Semgrep**: Static analysis for code vulnerabilities
- **Snyk**: Dependency vulnerability scanning

### 4. Decision Gate

Based on scan results:
- **PASS**: Move to next iteration
- **FAIL**: Enter remediation loop
  - Rollback commit
  - Inject security context into prompt
  - Re-spawn Claude Code
  - Repeat up to 3 times
- **EXHAUSTED**: Escalate to human review

### 5. Audit Trail

All operations are logged to `state/security-audit.jsonl` in JSON Lines format for compliance and debugging.

## PRD Format

Create your PRD at `state/{project}/prd.json` (auto-initialized from `prd.json.example`):

```json
{
  "projectName": "My Project",
  "userStories": [
    {
      "id": "US-001",
      "title": "Feature Name",
      "description": "As a user, I want...",
      "acceptanceCriteria": [
        "Criterion 1",
        "Criterion 2"
      ],
      "passes": false
    }
  ]
}
```

## Security Model

| Threat | Mitigation |
|--------|------------|
| Malicious code generation | External Semgrep validates all output on HOST |
| Vulnerable dependencies | External Snyk scans dependency changes on HOST |
| Secret leakage | Semgrep rules + Claude Code hooks detect secrets |
| Sandbox escape | Docker isolation + restricted network |
| Runaway execution | Iteration limits + cost caps |
| Audit gap | Comprehensive JSON Lines logging |
| Permission creep | Minimal tool allowlist per skill |
| Compromised iteration | Rollback + human escalation |

## Directory Structure

```
securing-ralph-loop/
├── ralph-secure.sh              # Main orchestrator
├── prompt.md                    # Base instructions for Claude
├── prd.json.example             # PRD template
├── CLAUDE.md                    # Project documentation
├── README.md                    # This file
├── .gitignore                   # Excludes state/
│
├── .claude/                     # Claude Code config
│   ├── settings.local.json      # Hooks + permissions
│   ├── skills/                  # Available skills
│   │   ├── code-review/
│   │   ├── self-check/
│   │   └── fix-security/
│   ├── hooks/                   # Security hooks
│   └── commands/                # Quick commands
│
├── scripts/                     # HOST-side scripts
│   ├── pre-flight.sh
│   ├── run-semgrep.sh
│   ├── run-snyk.sh
│   ├── audit-log.sh
│   ├── rollback.sh
│   ├── inject-security-context.sh
│   └── escalate.sh
│
├── rules/                       # Scanner config
│   ├── semgrep-rules.yml
│   └── .snyk
│
├── config/
│   └── thresholds.json
│
└── state/                       # Runtime state (gitignored)
    ├── .gitkeep                 # Keeps directory in git
    ├── my-app/                  # Per-project state (auto-created)
    │   ├── prd.json
    │   ├── security-audit.jsonl
    │   ├── .session-branch
    │   ├── .original-branch
    │   └── escalation-report-*.md
    └── another-project/         # Multiple projects supported
        └── ...
```

## Customization

### Adding Semgrep Rules

Edit `.ash/rules/semgrep-rules.yml` to add custom rules:

```yaml
rules:
  - id: my-custom-rule
    patterns:
      - pattern: dangerous_function($X)
    message: "Don't use dangerous_function"
    severity: ERROR
    languages: [python]
```

### Adjusting Thresholds

Edit `config/thresholds.json` to change pass/fail criteria:

```json
{
  "semgrep": {
    "failOn": {
      "error": true,
      "warning": false
    }
  }
}
```

### Custom Skills

Add skills in `.claude/skills/<name>/SKILL.md`:

```markdown
---
name: my-skill
description: What it does
allowed-tools: Read, Edit
---

# Skill Instructions
...
```

## Troubleshooting

### Pre-flight fails: "Docker daemon not running"

Start Docker Desktop before running the script.

### Pre-flight fails: "semgrep not found"

Install Semgrep:
```bash
pip install semgrep
# or
brew install semgrep
```

### Remediation loop stuck

If Claude keeps producing the same vulnerable code:
1. Check `state/security-context.md` for the findings
2. Review the Semgrep rules - might be a false positive
3. Update the PRD with more specific security requirements

### Escalation triggered

When human review is needed:
1. Check `state/{project}/escalation-report-*.md`
2. Review the security findings
3. Manually fix the issues
4. Re-run the loop

## License

MIT
