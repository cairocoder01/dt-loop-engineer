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
  │  DISCOVERY  │  Scan org for open issues with TRIGGER_LABEL
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  BOOTSTRAP  │  One-time container init (WP-CLI, test DB)
  └──────┬──────┘
         │
         ▼
  ┌─────────────┐
  │  PRE-ISSUE  │  Reset DB, update deps, clean worktree
  └──────┬──────┘
         │
         ▼
  ┌──────────────────────────────────────────────────────────┐
  │           RECURSIVE LOOP (up to MAX_LOOP_RETRIES)        │
  │                                                          │
  │  01_plan ──► 02_execute ──► 03_verify ──► 04_deliver    │
  │  (blueprint)  (opencode/    (PHP lint +   (open PR +    │
  │               Gemini agent)  PHPUnit+E2E)  label issue) │
  │                                                          │
  │  If verify fails: loop back to 02_execute with errors   │
  │  If agent blocked: post comment, swap label, exit       │
  └──────────────────────────────────────────────────────────┘
```

Each loop iteration feeds the previous test failure output back into the agent as context, creating a self-correcting cycle.

---

## Directory Structure

```
dt-loop-engineer/
├── README.md
├── TASKS.md                         # Open design & implementation tasks
├── Dockerfile                       # Multi-dependency Alpine base image
├── .env.example                     # Environment variable template
├── core-runner.sh                   # Main orchestration loop
│
├── hooks/
│   ├── bootstrap/                   # Runs ONCE on container start
│   │   ├── 01_install_wp_cli.sh
│   │   └── 02_setup_test_db.sh
│   └── pre-issue/                   # Runs ONCE before each issue
│       ├── 01_reset_wp_db.sh
│       ├── 02_update_core_deps.sh
│       └── 03_clean_worktree.sh
│
├── loop-stages/                     # Recursive execution stages
│   ├── 01_plan/
│   │   └── generate_blueprint.js    # Gemini: analyze issue → structured plan
│   ├── 02_execute/
│   │   └── run_opencode_agent.sh    # opencode CLI with MCP bindings
│   ├── 03_verify/                   # All must exit 0 to proceed
│   │   ├── 01_php_lint.sh
│   │   ├── 02_phpunit.sh
│   │   └── 03_chrome_mcp_e2e.js
│   └── 04_deliver/
│       └── open_github_pr.sh        # Create PR, apply READY_LABEL
│
└── skills/
    └── WP_STANDARDS.md              # Fallback coding standards for agent
```

---

## Prerequisites

- **Docker** (or compatible runtime)
- **GitHub Personal Access Token** with `repo` + `issues:write` + `pull_requests:write` scopes
- **Gemini API key** (Google AI Studio)
- **MySQL** accessible from the container (for PHPUnit WordPress test suite)
- Issues in target repos must be labeled with `TRIGGER_LABEL` to be picked up

---

## Setup

### 1. Clone and configure

```bash
git clone https://github.com/cairocoder01/dt-loop-engineer.git
cd dt-loop-engineer
cp .env.example .env
# Edit .env — fill in all required values
```

### 2. Build the image

```bash
docker build -t dt-loop-engineer .
```

### 3. Run the worker

```bash
docker run --env-file .env dt-loop-engineer
```

The container boots, runs bootstrap hooks once, then enters the discovery-and-loop cycle. When the workspace is idle (no labeled issues), it exits cleanly.

### 4. Run continuously (cron or supervisor)

```bash
# Example: poll every 15 minutes via cron
*/15 * * * * docker run --rm --env-file /path/to/.env dt-loop-engineer >> /var/log/loop-engineer.log 2>&1
```

---

## Environment Variables

| Variable | Required | Description |
|---|---|---|
| `GEMINI_API_TOKEN` | Yes | Google AI Studio API key |
| `GH_TOKEN` | Yes | GitHub PAT for issue/PR mutation |
| `GITHUB_OWNER` | Yes | GitHub org or username (e.g. `DiscipleTools`) |
| `TRIGGER_LABEL` | Yes | Issue label to pick up (e.g. `agent-build`) |
| `WAITING_LABEL` | Yes | Label when agent needs human input (e.g. `agent-waiting-for-human`) |
| `READY_LABEL` | Yes | Label on successful delivery (e.g. `ready-for-human-review`) |
| `MAX_LOOP_RETRIES` | Yes | Max recursive iterations per issue (e.g. `5`) |
| `WP_DB_HOST` | Yes | MySQL host for test suite |
| `WP_DB_NAME` | Yes | MySQL database name |
| `WP_DB_USER` | Yes | MySQL user |
| `WP_DB_PASS` | Yes | MySQL password |
| `WP_VERSION` | No | WordPress version to test against (default: `latest`) |
| `BASE_BRANCH` | No | Branch PRs target (default: `develop`) |
| `OPENCODE_MODEL` | No | Override opencode model (default: `gemini`) |

---

## How Each Stage Works

### `01_plan` — Blueprint Generation

`generate_blueprint.js` calls the Gemini API with:
- The full GitHub issue body
- The repo's `CLAUDE.md` / `README.md` as context
- The `skills/WP_STANDARDS.md` as coding constraints

It writes a structured `BLUEPRINT.md` to the repo root. The blueprint contains: task decomposition, files to modify, acceptance criteria, and edge cases. This file is the agent's primary instruction set for the execute stage.

### `02_execute` — Agent Execution

`run_opencode_agent.sh` launches `opencode` with:
- `--agent gemini` using `GEMINI_API_TOKEN`
- MCP bindings for the local Chromium instance (`@playwright/mcp`)
- The `BLUEPRINT.md` as the initial prompt
- Any prior verify-stage error output appended as additional context

The agent reads files, modifies code, and writes changes directly into the cloned repo worktree. When it needs human clarification it writes `BLOCKED: <reason>` to `PROGRESS.md`.

### `03_verify` — Validation Checklist

Each script must return exit code `0`. They run in order:

1. **`01_php_lint.sh`** — PHP syntax check + PHPCS on modified files
2. **`02_phpunit.sh`** — Full PHPUnit suite (WordPress multisite mode)
3. **`03_chrome_mcp_e2e.js`** — Browser-driven E2E via Playwright MCP

If any script fails, its stderr is written to `VERIFY_ERRORS.md`. The runner loops back to stage 02 with this error context injected.

### `04_deliver` — PR Creation

`open_github_pr.sh`:
1. Commits all changes on a new branch (`agent/<issue-number>-<slug>`)
2. Pushes to origin
3. Opens a PR via `gh pr create` with the issue linked and the blueprint as the description
4. Removes `TRIGGER_LABEL`, adds `READY_LABEL` to the issue

---

## Skills Fallback System

The agent uses a two-tier standards lookup:

1. **Local override** — checks the cloned repo for `phpunit.xml`, `.phpcs.xml`, `CLAUDE.md`
2. **System baseline** — falls back to `/workspace/skills/WP_STANDARDS.md`

This ensures consistent behavior across repos that haven't defined their own standards while still respecting per-repo configuration.

---

## Browser MCP Integration

The container runs a headless Chromium instance and exposes it via `@playwright/mcp`. When `opencode` initializes, the MCP server is passed as a tool binding, giving the agent browser automation tools (`navigate_page`, `click`, `fill`, DOM queries) to interact with a live WordPress installation for E2E verification.

The WordPress instance accessible during tests is stood up via WP-CLI against the test database configured in `WP_DB_*` variables.

---

## PROGRESS.md Protocol

The agent maintains a `PROGRESS.md` file in the repo root during execution:

| State | Content |
|---|---|
| Running | Free-form notes; no special markers |
| Blocked | Line starting with `BLOCKED:` followed by the clarification needed |
| Complete | `COMPLETE` on its own line |

The core runner polls this file after each `opencode` invocation to determine next action.

---

## Adding a New Verify Step

1. Create `loop-stages/03_verify/04_<name>.sh`
2. Exit `0` on pass, non-zero on failure
3. Write failure details to stdout/stderr (captured to `VERIFY_ERRORS.md` automatically)

Scripts are discovered and run in alphanumeric order.

---

## See Also

- [TASKS.md](TASKS.md) — open design and implementation tasks
- [Loop Engineering (CodeRabbit blog)](https://www.coderabbit.ai/blog/loop-engineering) — conceptual background
- [opencode CLI](https://opencode.ai) — agent runner used in stage 02
- [Playwright MCP](https://github.com/microsoft/playwright-mcp) — browser tool bindings
