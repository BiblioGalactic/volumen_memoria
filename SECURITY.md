# Security Policy

## Scope

This policy covers all shell scripts, Python modules, and configuration files in this repository. Since scripts interact with local AI models (llama.cpp/llama-cli), file systems, and network downloads, security is a priority.

## Supported Versions

| Branch  | Supported          |
| ------- | ------------------ |
| main    | :white_check_mark: |
| develop | :white_check_mark: |
| others  | :x:                |

## Reporting a Vulnerability

**Do NOT open a public issue for security vulnerabilities.**

1. Email: gsilvadacosta0@gmail.com
2. Subject: `[SECURITY] <module-name> — brief description`
3. Include: affected file(s), steps to reproduce, potential impact
4. Response time: within 72 hours for acknowledgment, patch within 14 days for critical issues

## Security Measures

- **Input sanitization**: All user-provided paths are validated before use in shell commands or code generation (see `lib/bash-common.sh:sanitize_path`)
- **No privilege escalation**: Scripts never execute `sudo` automatically; missing dependencies produce instructions for the user
- **Download integrity**: Model downloads are verified with SHA256 checksums
- **Portable shebangs**: All scripts use `#!/usr/bin/env bash` for cross-platform compatibility
- **Temporary files**: Created with `mktemp` and cleaned up via `trap cleanup EXIT`
- **No secrets in code**: API keys, tokens, and credentials must never be committed

## Known Considerations

- Scripts generate and compile C code at runtime (`RAM-IA.sh`). User input is passed as argv, never embedded in source
- llama-cli prompts are written to temporary files, not passed as shell arguments, to avoid injection
- Log files may contain AI model outputs; treat them as potentially sensitive data
