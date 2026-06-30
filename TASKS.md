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

- [x] **opencode invocation flags** — Verified against `sst/opencode` source (`packages/opencode/src/cli/cmd/run.ts`) and official docs. Key corrections from initial scaffold: subcommand is `opencode run` (not bare `opencode`); working dir is `--dir` (not `--workdir`); prompt is piped via stdin (no `--prompt-file`); API key is `GOOGLE_API_KEY` env var (no `--token` flag); MCP servers are configured via `OPENCODE_CONFIG_CONTENT` JSON env var (no `--mcp-server` flag); `--auto` is required for unattended runs. Both stage scripts updated.
- [x] **PROGRESS.md write discipline** — Prompt now requires: (1) write an opening status line before touching any file, (2) append after each major step for crash recovery, (3) terminal state must be exactly `BLOCKED: <reason>` or `COMPLETE` as the last line. Failure to write either causes core-runner.sh to treat the run as a crash.
- [x] **Error context injection** — VERIFY_ERRORS.md is injected under a `## Previous Attempt: Verification Failures` heading with explicit instructions to fix every error before writing COMPLETE. The section distinguishes first-run from retry with an IS_RETRY flag.
- [x] **File change scope limiting** — Two-layer enforcement: (1) prompt states the exact REPO_DIR path and forbids touching anything outside it; (2) after opencode exits, a `find /workspace -newer $SCOPE_SENTINEL` check warns if any files outside REPO_DIR were modified.
- [x] **Timeout handling** — `AGENT_TIMEOUT` env var (default 1800s, set to 0 to disable) wraps opencode with the `timeout(1)` command. Exit code 124 (timeout killed) appends a `BLOCKED:` line to PROGRESS.md so core-runner.sh surfaces it as a human-input-needed state rather than a silent crash.

---

## `03_verify` — Validation

- [x] **`01_php_lint.sh` — scope of files to lint** — Changed files only (`git diff --name-only HEAD` + `git ls-files --others` for new untracked files). Uses a bash array for PHPCS args so each file is a separate argument. Falls back gracefully (exit 0) if no PHP files changed; no longer incorrectly falls back to all tracked PHP files.
- [x] **`02_phpunit.sh` — WordPress test suite install** — Exports `WP_TESTS_DIR`, `WP_TESTS_DB_*` env vars that PHPUnit bootstrap files expect. Documents the DB lifecycle: bootstrap installs test library once, pre-issue hook drops/recreates DB, PHPUnit bootstrap re-creates WP tables on each run. Safety guard: re-runs `composer install` if `vendor/bin/phpunit` is missing.
- [x] **`03_chrome_mcp_e2e.js` — E2E test design** — Rewritten with Playwright Node.js API (direct `chromium.launch`, not the broken HTTP JSON-RPC approach from the scaffold). Uses system Chromium (`CHROME_BIN=/usr/bin/chromium-browser`). Graceful skip (exit 0) if `WP_TEST_URL` is unset or `playwright` not installed. Baseline scenarios: (1) front page loads without PHP fatal errors, (2) admin login page accessible. Per-repo specs from `.loop-engineer/e2e/*.js` each export `async function run(page, baseUrl)`.
- [x] **Per-repo verify overrides** — Supplement (not replace). System scripts always run first. After them, `core-runner.sh` discovers `.loop-engineer/verify/*.sh|js` in the cloned repo and runs each through the same `run_verify_script` helper. Per-repo scripts can add domain-specific checks without disabling baseline quality gates.
- [x] **Verify output capture** — Removed the `break` that stopped at first failure. All scripts now run, each captured to a temp file. Only failed output is written to `VERIFY_ERRORS.md`, under a `### script-name (exit N)` section header. This gives the agent the full error set in one retry instead of discovering one failure per iteration.

---

## `04_deliver` — PR Creation

- [x] **PR title / body template** — Title: `[Agent] $ISSUE_TITLE`. Body: metadata table (issue, model, iteration count, branch), checklist of passing verify scripts, collapsible `<details>` for the full Blueprint. PR mode (fixing an existing PR) posts a comment with the same checklist instead of opening a new PR.
- [x] **Commit authorship** — `git config user.email "loop-engineer[bot]@disciple.tools"` / `user.name "DT Loop Engineer"` set locally in the cloned repo before commit. Agent commits are identifiable in git log and blame without touching global git config.
- [x] **Branch naming collisions** — `git fetch origin "$AGENT_BRANCH" 2>/dev/null || true` before every push updates the local tracking ref; `git push --force-with-lease` then succeeds when overwriting our own previous push (retry path) and fails safely if someone else pushed to the branch in the meantime.
- [x] **Draft vs ready PR** — Always ready (no `--draft` flag). All checks passing means the work is complete and the PR is ready for human review — that's exactly what "ready for review" signals in GitHub. Draft means work-in-progress, which is the opposite of what the agent has produced.

---

## Infrastructure

- [x] **Docker Compose file** — `docker-compose.yml` with `mysql:8.0` (healthcheck) and `worker` services. `WP_DB_HOST` is hardcoded to `mysql` on the worker service. `restart: unless-stopped` with a 60s `IDLE_SLEEP` gives a natural polling interval. `WP_OPTIONS_FILE` mount is optional (commented out template in the file). `.env.example` updated with all new vars.
- [x] **GitHub Actions workflow** — `.github/workflows/ci.yml`: shellcheck on all `.sh` files (warning severity), then Docker build with layer caching, then a smoke-test container run that verifies `opencode`, `php`, `composer`, `wp`, `node`, `gh`, and `chromium` are all on PATH.
- [x] **Kubernetes / scaling** — Not needed. The `restart: unless-stopped` + `IDLE_SLEEP` pattern in docker-compose already provides cron-like scheduling: worker sleeps `IDLE_SLEEP` seconds when idle, exits, Docker restarts it. When work is found it runs immediately. Multiple PROCESSING_LABEL claims from concurrent containers are safe for the same reason as before.
- [x] **opencode installation** — Package name `opencode-ai` kept as-is. Added `&& opencode --version` to the Dockerfile `RUN` layer so a wrong package name fails the build immediately with a clear error rather than silently at runtime. Final verification requires a live Docker build.
- [x] **Playwright MCP server startup** — No separate startup script needed. opencode reads `OPENCODE_CONFIG_CONTENT` and manages the MCP server's lifecycle itself (spawning it on first tool call, stopping it on exit). The `type: "local"` config in `run_opencode_agent.sh` is the correct hook.

---

## Skills / Standards

- [ ] **`WP_STANDARDS.md` content** — Write the actual content: WordPress coding standards summary, DT-specific patterns (post type registration, field definitions, REST endpoints), test requirements, and what the agent must never do (e.g., don't drop DB tables, don't modify `functions.php` entry point).
- [ ] **Per-repo skill overrides** — Design the convention for repos to ship their own agent instructions (a `.loop-engineer/STANDARDS.md`?) and how the runner discovers and injects them.

---

## Testing the Framework Itself

- [ ] **Dry-run mode** — Add a `DRY_RUN=true` env var that runs all stages but skips the actual `gh pr create` and label mutations.
- [ ] **Fixture issue** — Create a test GitHub issue in a sandbox repo that has a known-good implementation, so the loop can be exercised end-to-end in CI.
- [ ] **Stage isolation testing** — Each stage script should be runnable independently with a mock environment for faster iteration during development.
- [ ] **Test security vulnerabilities** - Multiple access tokens and keys are given to this agent and container. Look for vulnerabilities that could exploit them and be destructive, finding ways to mitigate each.
