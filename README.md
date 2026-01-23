# Securing Ralph Loop

Adding security practices to the Ralph Loop - scan, fix, repeat.

## The Philosophy

<p align="center">
  <img src="Docs/images/Ralph_Wiggum_3_transparent.png" alt="Ralph Wiggum with magnifying glass" width="200">
</p>

**"AFK (Away From Keyboard) movement"** - run this, walk away, come back to secure code.

The name "Ralph Wiggum Loop" is intentionally ironic. Ralph Wiggum (from The Simpsons) is famously oblivious to danger. This system is the opposite: it's **hyper-aware** of security issues, so you don't have to be.

Traditional AI-assisted development:
- AI writes code → human hopes it's secure → CI finds issues → human fixes

Securing Ralph Loop:
- AI writes code → scans immediately → AI fixes issues → repeats until secure → escalates if stuck

The security loop runs **inside** Claude's session, giving it full context to fix problems iteratively. You can step away knowing that vulnerable code won't reach your branch.

## Security Tenets

This project is built on 10 security principles:

| # | Tenet | Description |
|---|-------|-------------|
| 1 | **Branch Isolation** | Each session creates its own branch (`ralph/{project}-{timestamp}`) - main stays clean |
| 2 | **Baseline Delta** | Pre-existing vulns tracked separately; only NEW findings block commits |
| 3 | **Internal Loop** | Security scans run inside Claude's session, not in external CI |
| 4 | **Iterative Fixes** | Up to 3 remediation attempts before giving up |
| 5 | **Graceful Escalation** | GitHub issues + Slack notification when AI can't fix |
| 6 | **Sandbox Constraints** | No network, no sudo, no dangerous deletions |
| 7 | **Pre-commit Guard** | Hook prevents accidental commit of injected config files |
| 8 | **Full Audit Trail** | Every iteration logged, every conversation transcribed |
| 9 | **Open Source Stack** | ASH, Semgrep, Grype, Checkov - battle-tested tools |
| 10 | **Human Override** | You can always step back in; nothing is fully autonomous |

## How Security Is Enforced

Security scanning is **mandatory** through Claude Code's [skills system](https://docs.anthropic.com/en/docs/claude-code/skills):

### The Enforcement Stack

1. **Workflow Instructions** (CLAUDE.md)
   - Explicitly requires `/security-scan` before every commit
   - Documents the scan-fix-retry loop

2. **Claude Code Skills** (`.claude/skills/`)
   - `/security-scan` - Runs ASH with 5 scanners, enforces PASS/FAIL
   - `/fix-security` - Applies secure coding patterns
   - `/self-check` - Pre-commit validation
   - `/code-review` - Security-focused review checklist

3. **Pre-Execution Hooks** (`.claude/hooks/`)
   - Validates every Bash command before execution
   - Blocks: network commands, privilege escalation, dangerous deletions

4. **Permission Controls** (`.claude/settings.local.json`)
   - Whitelist of allowed tools
   - Explicit deny list for dangerous operations
   - No `curl`, `wget`, `sudo`, `ssh`

### The Mandatory Loop

```
Code changes → /self-check → /security-scan → Compare baseline
                                    ↓
                        NEW findings? → FAIL (block commit)
                                    ↓
                        No NEW? → PASS (allow commit)
                                    ↓
                        3 failures? → Escalate to human
```

## Acknowledgments

### The Ralph Loop

This project builds on the **Ralph Loop** methodology created by [Geoffrey Huntley](https://x.com/GeoffreyHuntley). His original work on autonomous AI development loops ([ghuntley.com/ralph](https://ghuntley.com/ralph/), [ghuntley.com/loop](https://ghuntley.com/loop/)) pioneered the concept of "AFK movement" - letting AI agents work autonomously while humans step away. This project explores adding security practices into that loop: scan before commit, fix iteratively, escalate when stuck.

### Open Source Tools

- **[ASH](https://github.com/awslabs/automated-security-helper)** - AWS Labs' security scanner orchestrator
- **[claude-code-transcripts](https://github.com/simonw/claude-code-transcripts)** - Simon Willison's transcript extractor
- **[Semgrep](https://semgrep.dev)** - Multi-language static analysis
- **[Grype](https://github.com/anchore/grype)** - Vulnerability scanner for containers and filesystems
- **[Checkov](https://www.checkov.io)** - Infrastructure-as-Code security scanner
- **[detect-secrets](https://github.com/Yelp/detect-secrets)** - Credential detection by Yelp

## Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/yourorg/securing-ralph-loop.git
cd securing-ralph-loop

# 2. Install prerequisites
npm install -g @anthropic-ai/claude-code
curl -LsSf https://astral.sh/uv/install.sh | sh
brew install jq

# 3. Run on your project
./ralph-secure.sh /path/to/your-project

# 4. Edit the PRD with your user stories
nano state/your-project/prd.json
```

## Prerequisites

| Tool | Installation |
|------|--------------|
| Claude Code CLI | `npm install -g @anthropic-ai/claude-code` |
| uv | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |
| jq | `brew install jq` |

## Usage

```bash
# Basic - run on a project directory
./ralph-secure.sh /path/to/project

# With options
./ralph-secure.sh --max-iterations 5 --target /path/to/project

# All options
./ralph-secure.sh \
  --project my-app \
  --target /path/to/project \
  --max-iterations 10 \
  --slack-webhook https://hooks.slack.com/... \
  --no-create-issues
```

### Options

| Option | Short | Description |
|--------|-------|-------------|
| `--target DIR` | `-t` | Target project directory |
| `--project NAME` | `-p` | Project name (default: derived from directory) |
| `--max-iterations N` | `-m` | Max iterations (default: 10) |
| `--slack-webhook URL` | `-s` | Slack webhook for escalations |
| `--no-create-issues` | | Skip GitHub issues for pre-existing vulns |
| `--verbose` | `-v` | Show raw Claude output |
| `--help` | `-h` | Show help |

## PRD Format

User stories go in `state/{project}/prd.json`:

```json
{
  "projectName": "My App",
  "userStories": [
    {
      "id": "US-001",
      "title": "Add login page",
      "description": "As a user, I want to log in with email/password",
      "acceptanceCriteria": ["Form validates email", "Shows error on failure"],
      "passes": false
    }
  ]
}
```

Set `passes: false` for stories you want Claude to implement.

## What It Does

1. Spawns Claude Code on your project
2. Claude implements user stories from the PRD
3. Before each commit, runs security scan (ASH/Semgrep/Grype)
4. If scan fails, Claude fixes issues (up to 3 retries)
5. If still failing, escalates to human review
6. Repeats until all stories pass or max iterations reached

## Documentation

- [How It Works](Docs/how-it-works.md) - Architecture and flow
- [Security Model](Docs/security-model.md) - Threat mitigations
- [Customization](Docs/customization.md) - Custom rules and thresholds
- [Troubleshooting](Docs/troubleshooting.md) - Common issues

## License

MIT
