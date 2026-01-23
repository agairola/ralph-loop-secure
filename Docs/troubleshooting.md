# Troubleshooting

Common issues and their solutions.

## Pre-flight Failures

### "claude: command not found"

**Cause**: Claude Code CLI not installed or not on PATH.

**Fix**:
```bash
npm install -g @anthropic-ai/claude-code
```

Verify:
```bash
which claude
claude --version
```

### "uv: command not found"

**Cause**: UV package manager not installed.

**Fix**:
```bash
curl -LsSf https://astral.sh/uv/install.sh | sh
```

Add to PATH if needed:
```bash
export PATH="$HOME/.local/bin:$PATH"
```

### "jq: command not found"

**Cause**: jq JSON processor not installed.

**Fix**:
```bash
# macOS
brew install jq

# Ubuntu/Debian
sudo apt-get install jq

# Fedora
sudo dnf install jq
```

### "Not a git repository"

**Cause**: Target directory is not a git repository.

**Fix**:
```bash
cd /path/to/project
git init
git add .
git commit -m "Initial commit"
```

## Remediation Loop Stuck

### Claude keeps failing the same security scan

**Symptoms**:
- Same vulnerability reported repeatedly
- 3 retries exhausted
- Escalation triggered

**Causes & Fixes**:

1. **Rule too strict for codebase**

   Edit `config/thresholds.json`:
   ```json
   {
     "semgrep": {
       "ignoredRules": ["problematic-rule-id"]
     }
   }
   ```

2. **False positive in detection**

   Add path exclusion:
   ```json
   {
     "semgrep": {
       "ignoredPaths": ["**/affected/path/**"]
     }
   }
   ```

3. **Legitimate vulnerability that's hard to fix**

   Check the GitHub issue created by escalation. Consider:
   - Manual intervention
   - Architectural changes
   - Accepting the risk (document decision)

### Claude not running security scan before commit

**Symptoms**:
- Commits happening without scan
- No security findings even for vulnerable code

**Fix**: Check that Claude is using the skill correctly:

```markdown
# In progress.txt or transcript, verify:
Running /security-scan...
```

If not appearing, the CLAUDE.md instructions may not be injected properly. Verify:
```bash
ls /path/to/target/.claude/
ls /path/to/target/CLAUDE.md
```

### Security scan timing out

**Symptoms**:
- Scan takes very long
- Eventually fails or hangs

**Fix**: Adjust timeout in `.ash/ash.yaml`:
```yaml
execution:
  scanner_timeout: 600  # Increase from default 300
```

Or exclude large directories:
```yaml
global_settings:
  ignore_paths:
    - path: 'large-data/**'
      reason: 'Data files - not code'
```

## Escalation Triggered

### "Unable to resolve [VULNERABILITY]"

**What happened**: Claude tried 3 times to fix a security issue and couldn't.

**Next steps**:

1. **Check the GitHub issue**
   ```bash
   gh issue list --label "ralph-escalation"
   ```

2. **Review the transcript**
   ```bash
   ls state/{project}/transcripts/
   # Open the latest iteration HTML
   ```

3. **Understand the vulnerability**
   - Read the finding details
   - Check the file and line number
   - Review Claude's attempted fixes

4. **Manual resolution**
   - Fix the issue manually
   - Run `./ralph-secure.sh` again to continue

### Escalation to wrong place

**Symptoms**:
- GitHub issues not appearing
- Slack notifications not received

**Fix for GitHub**:
```bash
# Ensure gh is authenticated
gh auth status

# Ensure repo has issues enabled
gh repo view --web
```

**Fix for Slack**:
```bash
# Verify webhook URL
./ralph-secure.sh \
  --slack-webhook "https://hooks.slack.com/services/YOUR/WEBHOOK/URL" \
  /path/to/project
```

## Session Issues

### "Max iterations reached with N stories incomplete"

**Cause**: Reached iteration limit before completing all stories.

**Options**:

1. **Increase limit**:
   ```bash
   ./ralph-secure.sh --max-iterations 20 /path/to/project
   ```

2. **Simplify stories**: Break large stories into smaller ones

3. **Check blockers**: Review `progress.txt` for patterns

### Branch conflicts

**Symptoms**:
- Git errors during session
- Branch already exists

**Fix**:
```bash
# Delete old ralph branches
git branch | grep 'ralph/' | xargs git branch -D

# Or specify a unique project name
./ralph-secure.sh --project my-app-v2 /path/to/project
```

### State corruption

**Symptoms**:
- JSON parse errors
- Unexpected behavior

**Fix**:
```bash
# Reset project state
rm -rf state/{project}

# Re-run (will reinitialize)
./ralph-secure.sh /path/to/project
```

## Scan-Specific Issues

### Semgrep not finding issues

**Check**:
1. Rules are enabled in `.ash/ash.yaml`
2. Language is supported
3. Files aren't excluded

**Debug**:
```bash
# Run semgrep directly
uvx semgrep --config .ash/rules/semgrep-rules.yml /path/to/project
```

### Grype missing vulnerabilities

**Check**:
1. Lock files exist (`package-lock.json`, `Cargo.lock`, etc.)
2. Dependencies are installed

**Debug**:
```bash
# Run grype directly
uvx grype /path/to/project
```

### detect-secrets flagging false positives

**Fix**: Add to baseline:
```bash
cd /path/to/project
uvx detect-secrets scan --baseline .ash/secrets.baseline
```

## Performance Issues

### Sessions taking too long

**Causes & Fixes**:

1. **Large codebase**: Add more exclusions
   ```yaml
   # .ash/ash.yaml
   global_settings:
     ignore_paths:
       - path: 'docs/**'
       - path: 'assets/**'
   ```

2. **Too many scanners**: Disable unused ones
   ```yaml
   scanners:
     cfn-nag:
       enabled: false
     npm-audit:
       enabled: false
   ```

3. **Slow network**: ASH downloads tools on first run. Pre-cache:
   ```bash
   uvx --from git+https://github.com/awslabs/automated-security-helper.git@v3.1.5 ash --help
   ```

### High memory usage

**Fix**: Limit parallel execution:
```yaml
# .ash/ash.yaml
execution:
  parallel: true
  max_workers: 2  # Reduce from default 4
```

## Debugging Tips

### Enable verbose mode

```bash
./ralph-secure.sh --verbose /path/to/project
```

Shows raw Claude output instead of progress spinner.

### Check audit log

```bash
cat state/{project}/security-audit.jsonl | jq .
```

### Review transcripts

```bash
# Open in browser
open state/{project}/transcripts/iteration-1.html
```

### Test security scan manually

```bash
cd /path/to/project

# Run ASH directly
uvx --from git+https://github.com/awslabs/automated-security-helper.git@v3.1.5 \
  ash --mode local --source-dir . --output-dir .ash_output
```

### Check injected files

During a session, verify injection:
```bash
ls -la /path/to/target/.claude/
ls -la /path/to/target/CLAUDE.md
ls -la /path/to/target/.ash/
```

These are automatically cleaned up on session end.

## Getting Help

1. **Check logs**: `state/{project}/progress.txt`
2. **Review transcripts**: `state/{project}/transcripts/`
3. **File an issue**: https://github.com/anthropics/claude-code/issues

When reporting issues, include:
- Output of `./ralph-secure.sh --verbose`
- Contents of `security-audit.jsonl`
- Relevant portion of transcript
