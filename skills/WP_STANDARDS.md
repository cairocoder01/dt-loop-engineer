# WordPress & Disciple.Tools Agent Standards

This document is the fallback engineering standard for the DT Loop Engineer agent. Repos that define their own `.loop-engineer/STANDARDS.md` will use that file instead.

---

## 1. PHP Coding Standards

- Follow [WordPress PHP Coding Standards](https://developer.wordpress.org/coding-standards/wordpress-coding-standards/php/)
- 4-space indentation (no tabs)
- All user-facing strings must be translatable: use `esc_html__()`, `esc_html_e()`, `__()`, `_e()` with text domain `disciple_tools`
- Validate and sanitize all input at system boundaries; escape all output
- Run PHPCS before considering a task complete

## 2. Disciple.Tools Architecture Patterns

### Post Types
- Custom post types extend `DT_Module_Base`
- Register via the `dt_registered_post_types` filter
- Fields are defined via the `dt_custom_fields_settings` filter

### Supported Field Types
`text`, `textarea`, `number`, `date`, `key_select`, `multi_select`, `tags`, `connection`, `location`, `user_select`, `communication_channel`

### CRUD Operations
Use `DT_Posts::create_post()`, `update_post()`, `get_post()`, `list_posts()` — do not write raw SQL for post operations.

### REST API
- Endpoints live under `/dt-posts/v2/{post_type}/` or `/dt/v1/` namespaces
- All endpoints require authentication unless explicitly marked public
- Use `DT_Posts` methods inside REST callbacks; do not bypass the abstraction layer

### Key Files
- `functions.php` — Entry point (do not modify the module loading block)
- `dt-core/global-functions.php` — Utility functions available globally
- `dt-posts/dt-posts.php` — Core CRUD (prefer extending over modifying)
- `dt-core/configuration/class-roles.php` — User roles and capabilities

## 3. JavaScript & Frontend

- ESLint + Prettier enforced
- Do not use `_.` (lodash via underscore alias) — it conflicts
- SCSS lives in `dt-assets/scss/`; compile via Vite (`npm run build`)
- Web components come from `@disciple.tools/web-components`

## 4. Testing Requirements

- PHPUnit tests must run in WordPress multisite mode (`WP_MULTISITE=1`)
- Do not mock the database in integration tests — hit a real WordPress test database
- Test files belong in `tests/` following existing naming conventions
- All new public functions need at least a basic unit test

## 5. Security Rules (Non-Negotiable)

- Never expose raw database errors to the client
- Never store plaintext credentials or tokens in code
- Never disable nonce verification on form submissions
- Always check `current_user_can()` before mutating data in REST handlers
- Sanitize with `sanitize_text_field()`, `absint()`, `wp_kses_post()` as appropriate
- Escape output with `esc_html()`, `esc_attr()`, `esc_url()`, `wp_kses_post()`

## 6. What the Agent Must Never Do

- Drop database tables
- Modify `functions.php` module-loading block
- Remove or rename existing hooks without confirming no external plugins depend on them
- Push directly to `main` or `develop` — all work goes on a feature branch
- Commit `.env` files, credentials, or API keys
- Remove existing PHPUnit tests (only add or update them)
- Install new Composer or npm packages without noting them in the blueprint

## 7. PR Readiness Checklist

Before marking `COMPLETE` in PROGRESS.md, confirm:

- [ ] PHP syntax check passes (`php -l` on all modified files)
- [ ] PHPCS passes with no errors
- [ ] PHPUnit suite passes (multisite mode)
- [ ] All user-facing strings are wrapped in translation functions
- [ ] No hardcoded credentials or URLs
- [ ] Output is escaped at every point it touches HTML
- [ ] REST endpoints check capabilities before mutating data
