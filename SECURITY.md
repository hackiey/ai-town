# Security Policy

## Supported Versions

This project is pre-release. Security fixes target `main`.

## Reporting A Vulnerability

Do not open a public issue containing API keys, tokens, database dumps, private prompts, or exploit details.

Use GitHub private vulnerability reporting if it is enabled for the repository. If it is not enabled, contact the maintainer privately first and share only the minimum reproduction details needed to validate the issue.

## Secret Handling

- Real provider keys belong only in local `backend/.env` files or external secret managers.
- `backend/.env.example` must contain placeholders and non-sensitive development defaults only.
- Runtime SQLite databases under `backend/data/` can contain agent memory, event history, debug traces, and prompt-adjacent data. Do not publish them.
- If a secret was committed, rotate it at the provider. Rewriting Git history is cleanup, not containment.

Recommended local scan:

```bash
gitleaks detect --source . --redact=100 --verbose --no-banner
gitleaks dir . --redact=100 --verbose --no-banner
```
