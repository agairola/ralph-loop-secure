#!/usr/bin/env python3
"""
Pre-execution hook to validate Bash commands before execution.
Blocks dangerous commands that could compromise security.
"""

import json
import re
import sys
from pathlib import Path

# Dangerous patterns that should be blocked
BLOCKED_PATTERNS = [
    # Network exfiltration
    r'\bcurl\s+.*\|\s*bash',  # curl | bash
    r'\bwget\s+.*\|\s*bash',  # wget | bash
    r'\bcurl\s+.*-o\s*-\s*\|\s*sh',  # curl -o - | sh
    r'\bnc\s+-e',  # netcat reverse shell
    r'\bnetcat\s+-e',

    # Destructive operations
    r'\brm\s+-rf\s+/',  # rm -rf /
    r'\brm\s+-rf\s+\*',  # rm -rf *
    r'\bdd\s+if=.*of=/dev/',  # dd to device
    r'\bmkfs\.',  # format filesystem

    # Privilege escalation
    r'\bsudo\s+',  # sudo anything
    r'\bsu\s+-',  # su -
    r'\bchmod\s+777\s+/',  # chmod 777 /
    r'\bchown\s+.*:.*\s+/',  # chown on root

    # Credential theft
    r'cat\s+.*\.ssh/id_',  # Read SSH keys
    r'cat\s+.*/etc/passwd',  # Read passwd
    r'cat\s+.*/etc/shadow',  # Read shadow
    r'cat\s+.*\.aws/credentials',  # AWS credentials
    r'cat\s+.*\.env',  # Environment files (be careful)

    # Code execution from remote
    r'eval\s+"\$\(curl',  # eval "$(curl ...)"
    r'python\s+-c\s+.*urllib',  # Python URL fetch and exec
    r'python\s+-c\s+.*requests\.get',

    # History/log tampering
    r'history\s+-c',  # Clear history
    r'>\s+~/.bash_history',  # Overwrite history
    r'shred\s+.*history',  # Shred history

    # Reverse shells
    r'bash\s+-i\s+>&\s+/dev/tcp/',  # Bash reverse shell
    r'/dev/tcp/',  # Any /dev/tcp usage
    r'/dev/udp/',  # Any /dev/udp usage
    r'python\s+-c.*socket',  # Python socket
    r'perl\s+-e.*socket',  # Perl socket
    r'ruby\s+-rsocket',  # Ruby socket

    # Cron/persistence
    r'crontab\s+-e',  # Edit crontab
    r'echo\s+.*>>\s*/etc/cron',  # Write to cron

    # Package manager abuse (installing untrusted packages)
    r'pip\s+install\s+--index-url',  # Custom PyPI
    r'npm\s+install\s+--registry',  # Custom npm registry
]

# Allowed command prefixes (whitelist approach as secondary check)
ALLOWED_PREFIXES = [
    'git ', 'npm test', 'npm run', 'npm install',
    'cargo test', 'cargo build', 'cargo check',
    'uv ', 'python ', 'pytest ', 'ls ', 'mkdir ',
    'cat ', 'grep ', 'jq ', 'echo ', 'pwd', 'cd ',
    'head ', 'tail ', 'wc ', 'sort ', 'uniq ',
]


def validate_command(command: str) -> tuple[bool, str]:
    """
    Validate a command for security issues.
    Returns (is_valid, reason).
    """
    if not command or not command.strip():
        return True, "Empty command"

    command = command.strip()

    # Check against blocked patterns
    for pattern in BLOCKED_PATTERNS:
        if re.search(pattern, command, re.IGNORECASE):
            return False, f"Blocked pattern detected: {pattern}"

    # Additional checks for chained commands
    if '|' in command:
        # Check each part of a pipeline
        parts = command.split('|')
        for part in parts:
            part = part.strip()
            # Dangerous executors at end of pipe
            if part.startswith(('bash', 'sh', 'python', 'perl', 'ruby')):
                if parts.index(part) > 0:  # Not the first command
                    return False, "Piping to shell interpreter is blocked"

    # Check for encoded/obfuscated commands
    if 'base64' in command.lower() and ('decode' in command.lower() or '-d' in command):
        if '|' in command:
            return False, "Base64 decode in pipeline is suspicious"

    return True, "Command allowed"


def main():
    """Main entry point for the hook."""
    # Claude Code passes hook data via stdin as JSON
    # Structure: {"tool_name": "Bash", "tool_input": {"command": "..."}, ...}
    try:
        input_data = sys.stdin.read().strip()
        if not input_data:
            # No input, allow
            sys.exit(0)

        data = json.loads(input_data)

        # Extract command from tool_input
        tool_input = data.get('tool_input', {})
        if isinstance(tool_input, dict):
            command = tool_input.get('command', '')
        else:
            command = str(tool_input)

    except json.JSONDecodeError:
        # If not valid JSON, treat as raw command (fallback)
        command = input_data

    if not command:
        # No command to validate
        sys.exit(0)

    is_valid, reason = validate_command(command)

    if not is_valid:
        # Output error in format Claude Code expects
        print(json.dumps({
            "status": "blocked",
            "reason": reason,
            "command": command[:100] + "..." if len(command) > 100 else command
        }))
        sys.exit(1)

    # Command is valid
    sys.exit(0)


if __name__ == "__main__":
    main()
