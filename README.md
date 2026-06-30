# dt-loop-engineer

An autonomous, containerized Loop Engineering Worker for WordPress plugins and themes in the Disciple.Tools ecosystem. Inspired by [CodeRabbit's Loop Engineering model](https://www.coderabbit.ai/blog/loop-engineering), this framework picks up GitHub issues labeled for agent work, executes a recursive plan→build→verify→deliver cycle, and opens a PR when all checks pass — entirely without human intervention in the loop.

---

## How Loop Engineering Works

Traditional CI runs tests after a human writes code. Loop engineering inverts this: **the agent writes the code, tests validate it, and the loop retries until tests pass.**

```
GitHub Issue (labeled)
        │
        ▼
  ┌─────────────┐
  │  DISCOVERY  │  Scan org for open issues/PRs with TRIGGER_LABEL
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  BOOTSTRAP  │  One-time container init (WP-CLI, test DB, base theme)
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  PRE-ISSUE  │  Reset DB, update deps, clean worktree
  └──────┬──────┘
         │
         ▼
  ┌──────────────────────────────────────────────────────────────┐
  │             RECURSIVE LOOP (up to MAX_LOOP_RETRIES)          │
  │                                                              │
  │  01_plan ──► 02_execute ──► 03_verify ──────► 04_deliver     │
  │  (blueprint)  (opencode/    (PHP lint +        (open PR +    │
  │               Gemini agent)  PHPUnit + E2E)    label issue)  │
  │                                    │                         │
  │            ◄── retry with errors ──┘ (if verify fails)       │
  └──────────────────────────────────────────────────────────────┘
```

Each loop iteration feeds the previous test failure output back into the agent as context, creating a self-correcting cycle.

---

## Directory Structure

```
dt-loop-engineer/
├── README.md
├── SECURITY.md                          # Attack surface and mitigations
├── TASKS.md                             # Design and implementation task log
├── Dockerfile                           # Multi-dependency Alpine base image
├── docker-compose.yml                   # Recommended deployment (MySQL + worker)
├── .env.example                         # Environment variable template
├── core-runner.sh                       # Main orchestration loop
│
├── hooks/
│   ├── bootstrap/                       # Runs ONCE on container start
│   │   ├── 01_install_wp_cli.sh
│   │   ├── 02_setup_test_db.sh
│   │   └── 03_install_base_theme.sh    # Installs disciple-tools-theme as base
│   └── pre-issue/                       # Runs ONCE before each issue
│       ├── 00_inject_wp_options.sh
│       ├── 01_reset_wp_db.sh
│       ├── 02_update_core_deps.sh
│       └── 03_clean_worktree.sh
│
├── loop-stages/                         # Recursive execution stages
│   ├── 01_plan/
│   │   └── generate_blueprint.sh        # opencode: issue → BLUEPRINT.md or QUESTIONS.md
│   ├── 02_execute/
│   │   └── run_opencode_agent.sh        # opencode CLI with Playwright MCP
│   ├── 03_verify/                       # All must exit 0 to proceed
│   │   ├── 01_php_lint.sh
│   │   ├── 02_phpunit.sh
│   │   ├── 02b_prep_e2e_site.sh        # Syncs code and starts WordPress PHP server
│   │   └── 03_chrome_mcp_e2e.js
│   └── 04_deliver/
│       └── open_github_pr.sh            # Commit, push, create PR, apply READY_LABEL
│
├── skills/
│   └── WP_STANDARDS.md                  # DT-specific API standards for the agent
│
└── tests/
    ├── mock-env.sh                      # Sourceable mock environment for local testing
    ├── run_stage.sh                     # Run a single stage with mock env
    ├── run_fixture_test.sh              # CI-safe fixture tests (no credentials needed)
    └── fixtures/
        ├── sample-issue.json
        └── sample-repo/                 # Minimal plugin for verify stages
```

---

## Prerequisites

- **Docker** and **Docker Compose**
- **GitHub Personal Access Token** with `repo` + `issues:write` + `pull_requests:write` scopes
- **Gemini API key** (Google AI Studio)
- Issues in target repos must be labeled with `TRIGGER_LABEL` to be picked up

---

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/cairocoder01/dt-loop-engineer.git
cd dt-loop-engineer
cp .env.example .env
# Edit .env — fill in GH_TOKEN, GEMINI_API_TOKEN, GITHUB_OWNER at minimum
```

### 2. Start with Docker Compose (recommended)

```bash
docker compose up -d
```

This starts MySQL and the worker together. The worker processes one issue per run, then exits. `restart: unless-stopped` in `docker-compose.yml` brings it back up automatically, creating a polling loop with `IDLE_SLEEP` seconds between polls when the workspace is idle.

To run once (e.g., for testing):
```bash
docker compose run --rm worker
```

### 3. Alternative: bare Docker run

If you're providing your own MySQL:

```bash
docker build -t dt-loop-engineer .
docker run --env-file .env \
  -e WP_DB_HOST=host.docker.internal \
  dt-loop-engineer
```

---

## Environment Variables

Copy `.env.example` to `.env` and fill in the values below. All variables with defaults are optional.

### Required

| Variable | Description |
|---|---|
| `GEMINI_API_TOKEN` | Google AI Studio API key |
| `GH_TOKEN` | GitHub PAT for issue/PR mutation |
| `GITHUB_OWNER` | GitHub org or username (e.g. `cairocoder01`) |

### Issue Lifecycle Labels

| Variable | Default | Description |
|---|---|---|
| `TRIGGER_LABEL` | — | Issue label to pick up (e.g. `dt-agent-build`) |
| `PROCESSING_LABEL` | — | Applied immediately on pickup to prevent double-processing |
| `WAITING_LABEL` | — | Applied when agent needs human input |
| `READY_LABEL` | — | Applied on successful PR delivery |

### Loop Control

| Variable | Default | Description |
|---|---|---|
| `MAX_LOOP_RETRIES` | — | Max recursive iterations per issue (e.g. `5`) |
| `AGENT_TIMEOUT` | `1800` | Seconds before opencode is killed; `0` disables |
| `IDLE_SLEEP` | `900` | Seconds to sleep when no issues found (15 min polling interval) |
| `DRY_RUN` | `false` | Run all stages but skip push, PR creation, and label mutations |
| `LOG_RETENTION_DAYS` | `30` | Log files older than this many days are deleted at container start |

### WordPress

| Variable | Default | Description |
|---|---|---|
| `WP_DB_NAME` | — | MySQL database name |
| `WP_DB_USER` | — | MySQL user |
| `WP_DB_PASS` | — | MySQL password |
| `WP_DB_HOST` | `mysql` (compose) | MySQL host; set to override when not using docker-compose |
| `MYSQL_ROOT_PASSWORD` | — | Root password for the `mysql` compose service |
| `WP_VERSION` | `latest` | WordPress version to test against |
| `WP_TEST_URL` | `http://localhost:8080` | URL of the E2E WordPress site inside the container |
| `WP_E2E_PORT` | `8080` | Port the PHP built-in server listens on for E2E tests |
| `DT_BASE_THEME_REPO` | `DiscipleTools/disciple-tools-theme` | GitHub repo to install as the base WordPress theme |
| `WP_OPTIONS_FILE` | _(empty)_ | Path inside container to a `KEY=VALUE` secrets file written to `wp_options` before each issue |

### AI / Agent

| Variable | Default | Description |
|---|---|---|
| `OPENCODE_MODEL` | `google/gemini-3-flash-preview` | opencode model in `provider/model` format |
| `BASE_BRANCH` | _(auto-detected)_ | Branch PRs target; auto-detects `develop → main → master` if blank |

---

## How Each Stage Works

### `01_plan` — Blueprint Generation

`generate_blueprint.sh` runs opencode with the issue body plus up to 12,000 characters of repo context files, in priority order: `AGENTS.md`, `CLAUDE.md`, `README.md`, `.phpcs.xml`, `phpunit.xml`, `.editorconfig`. Files beyond the budget are skipped with a log line.

The last 5 comments from the issue (and PR, if in PR mode) are also included so that human answers to prior questions are always visible to the planner.

The planner writes exactly one of two files:

**`BLUEPRINT.md`** — when the issue is clear. Contains: task summary, files to modify, numbered implementation steps, acceptance criteria, and edge cases. This becomes the agent's instruction set for stage 02.

**`QUESTIONS.md`** — when the issue is ambiguous or requires a human decision before code can be written. The runner posts the questions as a comment, applies `WAITING_LABEL`, and exits. The human answers and re-applies `TRIGGER_LABEL` to resume.

### `02_execute` — Agent Execution

`run_opencode_agent.sh` launches `opencode` with:
- The `BLUEPRINT.md` as the initial prompt
- Any prior verify-stage errors appended under a `## Previous Attempt: Verification Failures` heading
- Playwright MCP enabled for browser automation
- A `PROGRESS.md` protocol: the agent must write a running status log and end with either `COMPLETE` or `BLOCKED: <reason>`

### `03_verify` — Validation Checklist

Scripts run in alphanumeric order; all must exit `0`. If any fail, their output is collected into `VERIFY_ERRORS.md` (the loop does not stop at first failure — all errors are gathered before retrying so the agent can fix them in one pass).

| Script | What it checks |
|---|---|
| `01_php_lint.sh` | PHP syntax (`php -l`) + PHPCS on changed files only |
| `02_phpunit.sh` | Full PHPUnit suite in WordPress multisite mode |
| `02b_prep_e2e_site.sh` | Syncs repo code into the WordPress test install; starts a PHP built-in server on `WP_E2E_PORT` |
| `03_chrome_mcp_e2e.js` | Playwright baseline: front page loads, admin login accessible; per-repo specs from `.loop-engineer/e2e/*.js` |

Per-repo verify scripts in `.loop-engineer/verify/*.sh|js` are run after the system scripts and can add domain-specific checks without replacing the baseline.

### `04_deliver` — PR Creation

`open_github_pr.sh`:
1. Scans staged changes for secret values (`GH_TOKEN`, `GEMINI_API_TOKEN`) before committing — aborts if found
2. Commits with identity `DT Loop Engineer <loop-engineer[bot]@disciple.tools>`
3. Pushes with `--force-with-lease` (safe to retry; fails if someone else pushed to the agent branch)
4. Opens a PR with a metadata table (issue, model, iterations), verify checklist, and collapsible blueprint
5. Removes `PROCESSING_LABEL`, adds `READY_LABEL` to the source issue

PRs are opened ready for review (not as drafts) — all checks passed means the work is complete.

---

## Per-Repo Customization

Repos can extend the system behavior without modifying this framework by shipping a `.loop-engineer/` directory:

```
my-plugin/.loop-engineer/
├── STANDARDS.md        # Appended after WP_STANDARDS.md in the planning prompt
├── verify/
│   └── 04_custom.sh   # Additional verify checks (run after system scripts)
└── e2e/
    └── my-flows.js    # Per-repo Playwright specs; export async function run(page, baseUrl)
```

System scripts always run first. Per-repo scripts add on top.

---

## Standards Injection

The planning prompt always loads `skills/WP_STANDARDS.md` (DT-specific APIs, field formats, never-do list). If the repo ships `.loop-engineer/STANDARDS.md`, it is appended under a `## Repo-Specific Standards` heading. The system standards take precedence; per-repo rules add to them.

The agent is also told that `.phpcs.xml`, `.editorconfig`, `AGENTS.md`, and `CLAUDE.md` from the repo context take precedence for style and project-specific patterns, so `WP_STANDARDS.md` covers only things the model can't derive from those files.

---

## WordPress E2E Site

Before E2E tests run, `02b_prep_e2e_site.sh` syncs the agent's code changes into the WordPress test install at `/tmp/wordpress` and starts a PHP built-in server on `WP_E2E_PORT`. This means:

- PHPUnit and E2E tests share the same WordPress installation
- The base theme (`DT_BASE_THEME_REPO`) is installed once at bootstrap; plugin repos activate on top of it
- When working on the theme itself, rsync overwrites the bootstrapped version with the agent's changes

---

## Issue Label Lifecycle

```
[TRIGGER_LABEL]
      │  Worker picks up the issue
      ▼
[PROCESSING_LABEL]          ← applied atomically before any work begins
      │
      ├─ agent blocked    → [WAITING_LABEL]  (human must re-apply TRIGGER_LABEL)
      ├─ max retries      → [WAITING_LABEL]  (human must review + re-apply TRIGGER_LABEL)
      ├─ recovery failed  → [WAITING_LABEL]
      └─ success          → [READY_LABEL]    (PR opened)
```

A container run that finds `PROCESSING_LABEL` on an issue knows the previous run was interrupted. It enters recovery mode, finds the existing agent branch, resumes the loop, and posts a comment with the last few commits and any prior verify errors.

---

## Viewing Run Logs

Each container run writes a timestamped log file to `./logs/` on the host (mounted from `/var/log/loop-engineer` inside the container). All output from `core-runner.sh` and every stage script it calls is captured in a single file per run.

```bash
# List runs, most recent first
ls -lt logs/

# Follow a live run
tail -f logs/$(ls -t logs/ | head -1)

# Read a specific run
cat logs/20240115-143022.log

# Search across all runs for a keyword (e.g. an issue number)
grep -l "issue #42" logs/*.log
```

Log files survive container restarts because the `./logs` directory is a host volume. They are excluded from git via `.gitignore`. Log filenames sort chronologically (`YYYYMMDD-HHMMSS.log`).

Files older than `LOG_RETENTION_DAYS` (default 30) are deleted automatically at the start of each container run. Set `LOG_RETENTION_DAYS=0` to disable cleanup entirely.

To stream live output without writing a file (e.g., in a one-shot test):

```bash
docker compose logs -f worker
```

---

## Local Development

### Run a single stage with mock environment

```bash
# Load mock env vars (DRY_RUN=true by default, REPO_DIR=tests/fixtures/sample-repo)
source tests/mock-env.sh

# Then run any stage directly
bash loop-stages/01_plan/generate_blueprint.sh
bash loop-stages/03_verify/01_php_lint.sh

# Or use the helper script
./tests/run_stage.sh 01          # plan
./tests/run_stage.sh 03/01       # php lint
./tests/run_stage.sh 03/02b      # E2E site prep
./tests/run_stage.sh 04          # deliver (dry-run by default)
```

Override individual vars without touching the file:

```bash
ISSUE_NUM=99 ISSUE_TITLE="Fix the bug" ./tests/run_stage.sh 01
```

### Dry-run mode

Set `DRY_RUN=true` to run the full loop against real GitHub issues without side-effects — all stages execute normally but `git push`, `gh pr create`, and all label mutations are skipped.

```bash
DRY_RUN=true docker compose run --rm worker
```

### Fixture tests (CI-safe)

```bash
./tests/run_fixture_test.sh          # blueprint validation + secret scanner
./tests/run_fixture_test.sh shell    # shellcheck only
```

---

## Security

Multiple high-privilege credentials live in this container. Key mitigations:

- **Prompt injection**: Both planning and execution prompts open with an explicit security boundary; the model is instructed to write `BLOCKED`/`QUESTIONS.md` if it detects injection attempts in issue content.
- **Secret exfiltration**: `open_github_pr.sh` refuses to commit if the staged diff contains the literal values of `GH_TOKEN` or `GEMINI_API_TOKEN`.
- **Token exposure**: The clone uses plain HTTPS; the `gh` credential helper injects the token invisibly so it never appears in `git remote -v` or process lists.

See [SECURITY.md](SECURITY.md) for a full threat model.

---

## Adding a New Verify Step

1. Create `loop-stages/03_verify/04_<name>.sh`
2. Exit `0` on pass, non-zero on failure
3. Write failure details to stdout/stderr (captured to `VERIFY_ERRORS.md` automatically)

Scripts are discovered and run in alphanumeric order. Alternatively, add a per-repo check in `.loop-engineer/verify/` to avoid modifying the framework.

---

## See Also

- [TASKS.md](TASKS.md) — design and implementation task log
- [SECURITY.md](SECURITY.md) — threat model and mitigations
- [Loop Engineering (CodeRabbit blog)](https://www.coderabbit.ai/blog/loop-engineering) — conceptual background
- [opencode CLI](https://opencode.ai) — agent runner used in stage 02
- [Playwright MCP](https://github.com/microsoft/playwright-mcp) — browser tool bindings
