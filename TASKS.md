# Open Tasks & Design Decisions

This file tracks what still needs to be designed, implemented, or decided before the loop engineering worker is production-ready.

---

## Architecture / Design

- [ ] **Multi-issue concurrency model** — Should one container process multiple issues in parallel (one worktree per issue), or should it be strictly sequential? Sequential is safe but slow. Parallel requires careful DB isolation per worktree.
    - A container should only handle a single issue at a time
- [ ] **Issue prioritization** — Currently picks `.[0]` from the GitHub search result. Define a priority ordering (e.g., by label age, by repo, by assignee).
    - Oldest issue with tag
    - If a PR exists with the given label, the outstanding PR should take highest priority
- [ ] **State persistence across container restarts** — If the container crashes mid-loop, the issue stays labeled with `TRIGGER_LABEL` and will be re-picked. Is that safe? Should a `PROCESSING` label be applied immediately on pickup?
    - There should be a label indicating the agent has picked it up and started working on it.
    - That processing indicator should take highest priority in the next container run
    - The next run should try to identify the last failure. If unable to, it should apply the label needing human review with as much detail about the failure as possible in an issue comment.
- [ ] **Secret injection strategy** — How are per-repo secrets (e.g., a plugin's own API keys needed for tests) provided to the agent? Options: mount a secrets volume, pull from a vault, encode in the issue body.
    - There should be a way that certain values can be written to wp_options. The WP CLI has a way to do that. Is there a way with a special ENV file that it can be done?
- [ ] **Telemetry / observability** — Structured logging format TBD. Consider shipping logs to a webhook or S3 for post-mortem review.

---

## `01_plan` — Blueprint Generation

- [ ] **Finalize Gemini prompt template** — The system prompt in `generate_blueprint.js` needs to be tuned. What constraints force the model to output a machine-parseable `BLUEPRINT.md` structure?
- [ ] **Blueprint schema validation** — After generation, validate that `BLUEPRINT.md` contains required sections (Task, Files, Acceptance Criteria). Fail fast with a GitHub issue comment if malformed.
- [ ] **Context window management** — Large repos may have `CLAUDE.md` / `README.md` files that exceed token limits. Add truncation or summarization logic.
- [ ] **Repo context discovery** — What additional context files should be fed to the planner? (e.g., `composer.json` deps, recent git log, open PRs referencing the same files)

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
