# Quick Validation Check

Run a quick validation of the current state before proceeding.

## Instructions

1. Check git status for uncommitted changes
2. Verify the PRD file exists and is valid JSON
3. Check if there are any failing stories
4. Report current progress

## Output Format

```
=== Quick Check ===
Git Status: [clean/dirty]
PRD Status: [valid/invalid/missing]
Progress: X/Y stories complete
Current Story: [story name or "none"]
Blockers: [list any issues]
```

## Actions

- If PRD is missing: Alert and stop
- If git is dirty with unrelated changes: Warn
- If all stories complete: Report success
- Otherwise: Report next story to work on
