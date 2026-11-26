# Migration Plan: `dt-loop-engineer` → Containerized `dt-factory`

## 1. Objective & Architectural Shift

We are evolving `dt-loop-engineer` (v1) into a clean, containerized **Software Factory** (`dt-factory` / `ghcr.io/cairocoder01/dt-factory:latest`).

Instead of running a persistent polling daemon (`core-runner.sh`) with external bash retry loops and file-based stage handoffs (`BLUEPRINT.md`), the new architecture packages the entire WordPress + WP-CLI + PHPUnit + Playwright + `opencode` runtime into an **Ubuntu-based Docker image** published to GitHub Container Registry (`ghcr.io`).

### Key Benefits
1. **Per-Repo Native Execution:** Any Disciple.Tools plugin or theme repository can adopt the factory using a thin GitHub Actions workflow (or reusable `workflow_call`) triggered on `issues: [labeled]`.
2. **Zero Cross-Repo Token Management:** Workflows running inside the target repo automatically receive a scoped `GITHUB_TOKEN` with `contents`, `issues`, and `pull-requests` write permissions.
3. **Dual-Mode Compatibility:** The exact same container image runs on standard GitHub-hosted `ubuntu-latest` runners (paired with `services: mysql:8.0`) **or** locally/self-hosted via `docker-compose.yml` (supporting local models like Ollama or self-hosted runners).
4. **Agent-Owned Verification Loop:** Instead of an external bash `MAX_LOOP_RETRIES` wrapper that cold-starts the agent on every test failure, `opencode` runs in a single continuous session and calls `./verify.sh` directly via its bash tool until checks pass.

---

## 2. What to Keep, Modify, and Rip Out from `dt-loop-engineer`

| Component in `dt-loop-engineer` | Action | Target in `dt-factory` | Notes |
| :--- | :--- | :--- | :--- |
| `hooks/bootstrap/*` | **KEEP & ADAPT** | `/opt/factory/bootstrap/` | Pre-install WordPress core, WP-CLI, PHPUnit, and base `disciple-tools-theme` into the Docker image at build time so container startup takes seconds. |
| `hooks/pre-issue/*` | **KEEP & ADAPT** | `/opt/factory/scripts/prepare-env.sh` | Reset MySQL test DB (`DB_HOST` configurable), symlink `$GITHUB_WORKSPACE` into `wp-content/plugins/` or `wp-content/themes/`, and activate the plugin/theme. |
| `skills/*` | **KEEP** | `/opt/factory/skills/` | Retain Disciple.Tools coding conventions, hook/filter patterns, and Playwright E2E playbooks. |
| Playwright & PHPUnit scripts | **KEEP & UNIFY** | `/opt/factory/scripts/verify.sh` | Consolidate PHP lint (`phpcs`), PHPUnit, and headless Playwright tests into a single deterministic `verify.sh` script that exits `0` on pass or non-zero with concise failure output. |
| `Dockerfile` | **REWRITE** | `Dockerfile` | Switch base image from Alpine to `ubuntu:24.04` for native compatibility with GitHub Actions container jobs, Playwright Chromium dependencies, and `opencode`. |
| `core-runner.sh` | **RIP OUT** | `/opt/factory/run.sh` | Remove infinite GitHub API polling and `MAX_LOOP_RETRIES` bash loop. Replace with a single-issue execution script driven by environment variables. |
| `loop-stages/01_plan.sh` (`BLUEPRINT.md`) | **RIP OUT** | *(Merged into prompt)* | Remove disk-based `BLUEPRINT.md` IPC handoffs. Let `opencode` plan and execute within a single session. |
| `loop-stages/02_execute.sh` | **SIMPLIFY** | `/opt/factory/scripts/execute.sh` | Invoke `opencode` non-interactively with layered instructions (base factory `AGENTS.md` + repo `./AGENTS.md` if present) and instruct it to run `/opt/factory/scripts/verify.sh` before finishing. |
| `loop-stages/03_verify.sh` | **SIMPLIFY** | `/opt/factory/scripts/verify.sh` | Run once after `opencode` exits as a final binary gatekeeper before opening a PR. |
| `loop-stages/04_deliver.sh` | **ADAPT** | `/opt/factory/scripts/deliver.sh` | Create feature branch (`factory/issue-<N>`), commit changes, push using `GITHUB_TOKEN`, open a Draft PR linking `Closes #<N>`, and swap issue labels (`agent-ready` → `agent-review` or `agent-failed`). |

---

## 3. Target Repository Structure (`dt-factory`)

```text
dt-factory/
├── .github/
│   └── workflows/
│       ├── build-image.yml        # Builds & pushes ghcr.io/cairocoder01/dt-factory:latest
│       └── reusable-factory.yml   # Reusable workflow (workflow_call) for target DT repos
├── factory/
│   ├── AGENTS.base.md             # Shared Disciple.Tools & WordPress agent rules
│   ├── run.sh                     # Main container entrypoint for a single issue run
│   ├── bootstrap/
│   │   └── install-wp.sh          # Build-time WP + DT theme installation into /var/www/html
│   ├── scripts/
│   │   ├── prepare-env.sh         # Runtime DB reset + workspace symlink into WP
│   │   ├── execute.sh             # Configures & runs headless opencode session
│   │   ├── verify.sh              # Runs phpcs, phpunit, and Playwright E2E checks
│   │   └── deliver.sh             # Commits, pushes branch, opens Draft PR, updates labels
│   └── skills/                    # Copied & refined from dt-loop-engineer/skills
├── Dockerfile
├── docker-compose.yml             # Local / self-hosted execution with MySQL + optional Ollama
└── README.md
```

---

## 4. Detailed Implementation Specifications

### A. `Dockerfile` (Ubuntu 24.04 + Pre-baked WordPress/Playwright)
* **Base image:** `ubuntu:24.04` (required by GitHub Actions `container:` jobs, which mount `/__w` and expect standard GNU coreutils, `bash`, `tar`, and `glibc`).
* **System packages:** `php8.3-cli`, `php8.3-mysql`, `php8.3-xml`, `php8.3-mbstring`, `php8.3-curl`, `php8.3-zip`, `mysql-client`, `git`, `curl`, `jq`, `unzip`, `composer`, Node.js 22 LTS, and GitHub CLI (`gh`).
* **Tools:** Install `opencode` globally and Playwright + Chromium (`npx playwright install --with-deps chromium`).
* **Pre-baked WordPress:** Run `/opt/factory/bootstrap/install-wp.sh` during `docker build` to download WordPress core, WP-CLI, PHPUnit/WordPress test suite libraries, and the latest `disciple-tools-theme` into `/opt/wp-base` (copied or linked into `/var/www/html` at runtime so workspace mounts don't overwrite it).
* **Permissions note:** GitHub Actions `container:` jobs run as `root` or the host UID; ensure `/opt/factory` and `/var/www/html` have permissive read/write access and `git config --global --add safe.directory '*'`.

### B. Environment Variables Contract (`run.sh`)
`run.sh` must be completely agnostic to whether it is running in GitHub Actions or local `docker compose`:

| Variable | Required | Default | Description |
| :--- | :--- | :--- | :--- |
| `GITHUB_TOKEN` | Yes | — | Token for `gh` CLI and `git push` |
| `GITHUB_REPOSITORY` | Yes | — | `owner/repo` format (auto-set by GitHub Actions) |
| `ISSUE_NUMBER` | Yes | — | Target GitHub issue number |
| `PROJECT_TYPE` | No | `auto` | `plugin`, `theme`, or `auto` (detect via `style.css` Theme Name header vs. plugin header) |
| `AGENT_MODEL` | No | `google/gemini-2.5-pro` | Model identifier passed to `opencode` |
| `GEMINI_API_KEY` / `ANTHROPIC_API_KEY` / `OPENAI_API_KEY` | Conditional | — | Required unless using a local endpoint (`OLLAMA_HOST`) |
| `OLLAMA_HOST` | No | — | Optional local LLM endpoint (e.g., `http://host.docker.internal:11434`) |
| `DB_HOST` | No | `mysql` | Use `127.0.0.1` in GitHub Actions `services:`, `mysql` in `docker-compose.yml` |
| `DB_NAME` / `DB_USER` / `DB_PASS` | No | `wordpress_test` / `root` / `root` | Test database credentials |
| `MAX_STEPS` | No | `40` | Hard step/turn ceiling for `opencode` to bound token spend |

### C. Execution Lifecycle (`run.sh`)
1. **Validate inputs:** Verify `ISSUE_NUMBER` matches `^[0-9]+$` and `GITHUB_REPOSITORY` matches `^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$`.
2. **Fetch issue context:** Use `gh issue view "$ISSUE_NUMBER" --json title,body,labels,comments` to capture the specification. Swap label `agent-ready` → `agent-in-progress`.
3. **Prepare environment (`prepare-env.sh`):**
   * Wait for MySQL readiness (`mysqladmin ping -h "$DB_HOST"`).
   * Drop and recreate `$DB_NAME`, install WordPress via `wp core install`, and activate `disciple-tools-theme`.
   * Auto-detect `PROJECT_TYPE` if set to `auto`:
     * If `style.css` contains `Theme Name:`, symlink workspace to `/var/www/html/wp-content/themes/<repo-name>` and run `wp theme activate`.
     * Otherwise, symlink workspace to `/var/www/html/wp-content/plugins/<repo-name>` and run `wp plugin activate`.
4. **Assemble layered context:**
   * Copy `/opt/factory/AGENTS.base.md` and `/opt/factory/skills/` into a temporary context directory (or system prompt).
   * If the target repository contains its own `./AGENTS.md`, append/prioritize it so repo-specific rules override defaults.
5. **Run agent (`execute.sh`):**
   * Start PHP's built-in server or Apache in the background serving `/var/www/html` on `http://127.0.0.1:8080` for Playwright E2E tests.
   * Invoke `opencode` in headless/non-interactive mode with `--max-steps "$MAX_STEPS"` and prompt:
     > "Resolve GitHub Issue #$ISSUE_NUMBER. Before finishing, you MUST run `/opt/factory/scripts/verify.sh` and fix any linting, PHPUnit, or Playwright failures until it exits 0."
6. **Final Verification Gate (`verify.sh`):**
   * Run `/opt/factory/scripts/verify.sh` deterministically after `opencode` exits.
   * **If exit code != 0:** Post a diagnostic comment on the issue with the tail of the verification log, swap label to `agent-failed`, and exit `1` without opening a broken PR.
7. **Deliver (`deliver.sh`):**
   * Verify `git status --porcelain` is non-empty.
   * Checkout branch `factory/issue-${ISSUE_NUMBER}`, commit changes, push to `origin`.
   * Open a **Draft PR** via `gh pr create --draft` referencing `Closes #${ISSUE_NUMBER}` and summarizing changes + verification results.
   * Swap label `agent-in-progress` → `agent-review`.

### D. Reusable GitHub Actions Workflow (`.github/workflows/reusable-factory.yml`)
Target repositories can trigger the factory with a ~15-line workflow file calling `reusable-factory.yml`:

```yaml
# Example caller workflow in a Disciple.Tools plugin repository:
# .github/workflows/factory.yml
name: Software Factory
on:
  issues:
    types: [labeled]

jobs:
  factory:
    if: github.event.label.name == 'agent-ready'
    uses: cairocoder01/dt-factory/.github/workflows/reusable-factory.yml@main
    with:
      project-type: plugin
      issue-number: ${{ github.event.issue.number }}
    secrets: inherit
```

*(Note: Inside `reusable-factory.yml`, configure `container: ghcr.io/cairocoder01/dt-factory:latest`, `services: mysql:8.0`, and `permissions: contents: write, issues: write, pull-requests: write`.)*

---

## 5. Step-by-Step Build & Verification Checklist for the Implementing Agent

- [ ] **Step 1: Scaffold `dt-factory` repository** with the directory structure defined in Section 3.
- [ ] **Step 2: Port reusable assets from `dt-loop-engineer`** (`hooks/bootstrap/`, `hooks/pre-issue/`, `skills/`, and verification scripts), removing Alpine-specific `apk` commands and `BLUEPRINT.md` logic.
- [ ] **Step 3: Write `Dockerfile` (`ubuntu:24.04`) and `docker-compose.yml`**; verify local build succeeds (`docker build -t dt-factory:local .`).
- [ ] **Step 4: Implement `run.sh`, `prepare-env.sh`, `execute.sh`, `verify.sh`, and `deliver.sh`** with strict input validation and `DB_HOST` parameterization.
- [ ] **Step 5: Smoke-test locally via `docker compose`** against a sample issue on a Disciple.Tools plugin repository to verify DB reset, `opencode` execution, `verify.sh` gate, and Draft PR creation.
- [ ] **Step 6: Add `.github/workflows/build-image.yml` and `reusable-factory.yml`**; publish initial image to `ghcr.io/cairocoder01/dt-factory:latest` and set package visibility to **Public** so target repos can pull it without registry auth.
- [ ] **Step 7: End-to-end cloud test** by adding the caller workflow to one test repository, applying the `agent-ready` label to a bounded test issue, and verifying the Draft PR opens cleanly.