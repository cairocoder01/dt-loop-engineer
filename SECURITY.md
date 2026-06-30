# Security Considerations

The loop engineer container holds powerful credentials and runs AI-generated code. This document maps the attack surface and describes the mitigations in place.

---

## Access Tokens in Scope

| Credential | Scope | Where Used |
|-----------|-------|-----------|
| `GH_TOKEN` | `repo`, `issues:write`, `pull_requests:write` | Discovering issues, cloning repos, opening PRs, mutating labels |
| `GEMINI_API_TOKEN` | AI API calls | Planning (generate_blueprint.sh) and execution (run_opencode_agent.sh) |
| `WP_DB_PASS` / `MYSQL_ROOT_PASSWORD` | MySQL only | WordPress test database — local container only |

---

## Threat 1: Prompt Injection via Issue Content

**Risk**: A malicious GitHub issue title or body instructs the AI to exfiltrate secrets, run destructive commands, or write files outside the repo directory.

**Mitigations**:
- The planning and execution prompts open with an explicit security instruction that prohibits the model from acting on instructions embedded in issue content.
- The execute prompt restricts the agent's working directory to `$REPO_DIR` and explicitly forbids touching any path outside it.
- A scope check after `opencode` exits (`find /workspace -newer $SCOPE_SENTINEL`) warns if files outside `$REPO_DIR` were modified.

**Residual risk**: AI instruction-following is not 100% reliable. Do not apply `TRIGGER_LABEL` to issues from untrusted users without reviewing the issue content first.

---

## Threat 2: Secret Exfiltration via Committed Files

**Risk**: A prompt injection attack instructs the agent to write the value of `GH_TOKEN` or `GEMINI_API_TOKEN` into a source file, which then gets committed and pushed to a public repo.

**Mitigations**:
- `open_github_pr.sh` scans the staged git diff for the literal values of `GH_TOKEN` and `GEMINI_API_TOKEN` before committing. If either is found, the commit is aborted and a clear error is logged.
- Loop artifact files (`BLUEPRINT.md`, `PROGRESS.md`, `VERIFY_ERRORS.md`, `QUESTIONS.md`) are explicitly unstaged before every commit.

**Residual risk**: The scanner checks exact values, not patterns. A crafty injection could encode the token differently (base64, split across lines). For high-security deployments, consider running [`git-secrets`](https://github.com/awslabs/git-secrets) or [`trufflehog`](https://github.com/trufflesecurity/trufflehog) as a verify-stage step.

---

## Threat 3: Token Exposure in Process List / Git History

**Risk**: Embedding `GH_TOKEN` in the clone URL (`https://x-access-token:TOKEN@github.com/...`) exposes it in `git remote -v`, `ps aux` output, and shell history.

**Mitigation**: `core-runner.sh` uses a plain HTTPS clone URL (`https://github.com/...`) after `gh auth login --with-token`. The `gh` CLI configures a git credential helper that injects the token transparently, so it never appears in the remote URL, process list, or reflog.

---

## Threat 4: Label-Based Access Control

**Risk**: Any GitHub user with write access to your organization's repos can add `TRIGGER_LABEL` to any issue, causing the agent to pick it up.

**Mitigations**:
- The `gh search issues --owner "$GITHUB_OWNER"` query constrains discovery to repos owned by `GITHUB_OWNER`. Issues from other organizations are never discovered.
- The agent only clones repos from `$GITHUB_OWNER` — `TARGET_REPO` comes from the discovered issue's repository metadata, not from user-controlled content.
- Use GitHub's branch protection rules and team permissions to restrict who can add labels to issues in sensitive repos.

**Recommendation**: Create a dedicated GitHub organization for the agent's target repos, separate from your main org, so blast radius is contained.

---

## Threat 5: Destructive Operations by AI

**Risk**: The AI executes a destructive command (e.g., `DROP TABLE`, `rm -rf`, schema migration) that was not in the blueprint.

**Mitigations**:
- The blueprint prompt includes an explicit "Never Do" list (from `skills/WP_STANDARDS.md`): no raw SQL for DT_Posts operations, no dropping tables, no renaming existing field keys or post type slugs.
- PHPUnit runs before the PR is opened, so broken migrations are caught before merge.
- The PR requires human review before merging.

---

## Dry-Run Mode

Set `DRY_RUN=true` in `.env` to run the full loop without any GitHub write operations (no push, no PR, no label mutations). Useful for:
- Testing a new model against your issues without side-effects
- Debugging stage scripts locally via `tests/run_stage.sh`

---

## Reporting Vulnerabilities

Open a GitHub issue with the `security` label, or contact the maintainer directly. Do not post exploit details publicly until a fix is available.
