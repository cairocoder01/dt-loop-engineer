# Open Tasks & Design Decisions

This file tracks what still needs to be designed, implemented, or decided before the loop engineering worker is production-ready.

---

## Architecture / Design

- [x] **Multi-issue concurrency model** — One issue per container, strictly sequential. Safe by design; no DB isolation complexity needed.
- [x] **Issue prioritization** — 3-tier discovery in `core-runner.sh`:
    1. Issues with `PROCESSING_LABEL` (recovery — highest priority)
    2. Open PRs with `TRIGGER_LABEL` (existing work needs fixing)
    3. Oldest open issue with `TRIGGER_LABEL` (new work, sorted `createdAt asc`)
- [x] **State persistence across container restarts** — `PROCESSING_LABEL` is applied atomically before any work begins and removed on all exit paths. Recovery mode: finds existing `agent/<issue-num>-*` branch, resumes from it; if no branch found, posts a detailed comment and escalates to `WAITING_LABEL`.
- [x] **Secret injection strategy** — `WP_OPTIONS_FILE` env var (mounted into container) contains `KEY=VALUE` lines. `hooks/pre-issue/00_inject_wp_options.sh` reads the file and writes each entry to the test WordPress via `wp option update --allow-root`. See `.env.example` for mount pattern.
- [ ] **Telemetry / observability** — Structured logging format TBD. Consider shipping logs to a webhook or S3 for post-mortem review.

---

## `01_plan` — Blueprint Generation

- [x] **Consistent model across stages** — Stage 01 now uses the opencode harness (same `OPENCODE_MODEL` var as stage 02). No direct Gemini API calls. Both stages change together when the model is swapped.
- [x] **Planner clarification flow** — If the issue is ambiguous, opencode writes `QUESTIONS.md` instead of `BLUEPRINT.md` (exit 2). `core-runner.sh` catches this, posts the questions as a comment on the issue/PR, applies `WAITING_LABEL`, and exits. Human answers and re-applies `TRIGGER_LABEL` to resume.
- [x] **Finalize opencode prompt for planning** — Prompt uses a clear decision tree (BLUEPRINT vs QUESTIONS), names the exact section headers the validator expects, and includes a concrete DT-specific few-shot example so the model produces consistent structure.
- [x] **Blueprint schema validation** — After opencode exits, `generate_blueprint.sh` greps for all five `### ` headers. If any are missing it dumps the file and exits 1, which `core-runner.sh` treats as a hard failure (causing a retry or escalation).
- [x] **Context window management** — 12,000-char total budget allocated in priority order (CLAUDE.md → README.md → .phpcs.xml → phpunit.xml). Each file reports actual vs available bytes; files beyond the budget are skipped with a log line.
- [x] **Issue comment ingestion** — `generate_blueprint.sh` fetches the last 5 comments from the issue via `gh issue view --json comments` on every run (not just recovery), and additionally fetches the last 5 PR comments when `PR_MODE=true`. Both are appended to the prompt so the human's answers to prior questions are always visible to the planner.

---

## `02_execute` — Agent Execution

- [ ] **opencode invocation flags** — Confirm the exact CLI flags for `opencode` (model selection, MCP server binding, working directory, prompt injection). The CLI API may have changed from initial design.
- [ ] **PROGRESS.md write discipline** — The agent must be prompted to maintain `PROGRESS.md`. Design the exact prompt language that reliably produces this behavior.
- [ ] **Error context injection** — Define the exact format for appending `VERIFY_ERRORS.md` content to the re-run prompt so the agent understands it must fix the listed errors.
- [ ] **File change scope limiting** — Prevent the agent from modifying files outside the repo being worked on (e.g., shared worktree artifacts, `/workspace/skills/`).
- [ ] **Timeout handling** — What happens if `opencode` hangs? Add a timeout with `timeout` command and treat it as a blocked state.

---

## `03_verify` — Validation

- [ ] **`01_php_lint.sh` — scope of files to lint** — Should it lint only changed files (`git diff --name-only`) or the whole repo? Changed-files-only is faster but may miss regressions.
- [ ] **`02_phpunit.sh` — WordPress test suite install** — The `install-wp-tests.sh` script must run against a real DB. Document the expected DB state and how the bootstrap hook prepares it.
- [ ] **`03_chrome_mcp_e2e.js` — E2E test design** — What are the baseline E2E scenarios? This is the least defined stage. Options: smoke test WP admin login, verify plugin activation, run per-repo Playwright spec files if they exist.
- [ ] **Per-repo verify overrides** — If a repo ships its own `loop-stages/` directory, should those override or supplement the system ones?
- [ ] **Verify output capture** — Confirm that both stdout and stderr from failed verify scripts are reliably written to `VERIFY_ERRORS.md` for agent ingestion.

---

## `04_deliver` — PR Creation

- [ ] **PR title / body template** — Finalize the PR description format. Should it include the full `BLUEPRINT.md`, a summary, loop iteration count, and verify pass evidence?
- [ ] **Commit authorship** — Set a consistent git author name/email for agent commits so they're identifiable in git history.
- [ ] **Branch naming collisions** — If the agent retries and a branch already exists, `git push` will fail. Handle by appending a retry counter or force-pushing.
- [ ] **Draft vs ready PR** — Should the PR always open as draft for human review, or ready if confidence is high?

---

## Infrastructure

- [ ] **Docker Compose file** — Add `docker-compose.yml` with a linked MySQL service so the entire stack (worker + DB) can be spun up locally with one command.
- [ ] **GitHub Actions workflow** — Add a workflow that builds and tests the Docker image itself on push to this repo.
- [ ] **Kubernetes / scaling** — If multiple workers are needed, define how they avoid processing the same issue (leader election, or a `PROCESSING` label applied atomically).
- [ ] **opencode installation** — Verify `npm install -g opencode-ai` is the correct package name and that the binary is available as `opencode` after install.
- [ ] **Playwright MCP server startup** — The MCP server process must be started before `opencode` launches. Add a startup script and health check.

---

## Skills / Standards

- [ ] **`WP_STANDARDS.md` content** — Write the actual content: WordPress coding standards summary, DT-specific patterns (post type registration, field definitions, REST endpoints), test requirements, and what the agent must never do (e.g., don't drop DB tables, don't modify `functions.php` entry point).
- [ ] **Per-repo skill overrides** — Design the convention for repos to ship their own agent instructions (a `.loop-engineer/STANDARDS.md`?) and how the runner discovers and injects them.

---

## Testing the Framework Itself

- [ ] **Dry-run mode** — Add a `DRY_RUN=true` env var that runs all stages but skips the actual `gh pr create` and label mutations.
- [ ] **Fixture issue** — Create a test GitHub issue in a sandbox repo that has a known-good implementation, so the loop can be exercised end-to-end in CI.
- [ ] **Stage isolation testing** — Each stage script should be runnable independently with a mock environment for faster iteration during development.
