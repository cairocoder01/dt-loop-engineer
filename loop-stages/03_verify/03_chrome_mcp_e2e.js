#!/usr/bin/env node
/**
 * Verify Stage 03: Browser-driven E2E via Playwright.
 *
 * Requires WP_TEST_URL to point to a running WordPress instance. If unset,
 * exits 0 with a warning (graceful skip) so the loop is not blocked on E2E
 * infrastructure that hasn't been set up yet. The docker-compose file
 * (TASKS.md → Infrastructure) provides a linked WP + MySQL service that sets
 * WP_TEST_URL automatically.
 *
 * Per-repo E2E specs:
 *   Create .js files in <repo>/.loop-engineer/e2e/. Each must export:
 *     async function run(page, baseUrl)
 *   Throw (or return a rejected promise) to fail the spec. The function
 *   receives the Playwright Page object and the WordPress base URL.
 *
 * Baseline scenarios run for every issue, regardless of per-repo specs:
 *   1. WordPress front page loads (no PHP fatal errors)
 *   2. Admin login page is accessible (no 5xx, no PHP fatals)
 */

'use strict';

const path = require('path');
const fs   = require('fs');

const WP_TEST_URL = process.env.WP_TEST_URL || '';
const REPO_DIR    = process.env.REPO_DIR    || '';
const CHROME_BIN  = process.env.CHROME_BIN  || '/usr/bin/chromium-browser';

console.log('=== Browser E2E (Playwright) ===');

if (!WP_TEST_URL) {
    console.log('WP_TEST_URL is not set — skipping E2E verification.');
    console.log('Set WP_TEST_URL to a running WordPress instance to enable E2E.');
    console.log('(Non-fatal skip; all other verify stages still apply.)');
    process.exit(0);
}

let chromium;
try {
    ({ chromium } = require('playwright'));
} catch (e) {
    console.log('WARNING: playwright package not installed — skipping E2E.');
    console.log('The Dockerfile should include: npm install -g playwright');
    process.exit(0);
}

function assert(condition, message) {
    if (!condition) throw new Error('ASSERTION FAILED: ' + message);
}

async function runBaseline(page, baseUrl) {
    // ── Test 1: Front page loads without PHP fatal errors ─────────────────────
    console.log('  [1] Front page loads...');
    const resp = await page.goto(baseUrl, { waitUntil: 'domcontentloaded', timeout: 15000 });
    assert(resp && resp.status() < 500, `Front page returned HTTP ${resp?.status()}`);

    const body = await page.content();
    const hasFatal = /(?:Fatal error|Parse error|Uncaught (?:Error|TypeError)|Call to undefined)/i.test(body);
    assert(!hasFatal, 'PHP fatal/parse error detected on WordPress front page');
    console.log('  [1] PASSED');

    // ── Test 2: Admin login page accessible ───────────────────────────────────
    console.log('  [2] Admin login page accessible...');
    const loginResp = await page.goto(
        baseUrl.replace(/\/$/, '') + '/wp-admin/',
        { waitUntil: 'domcontentloaded', timeout: 15000 }
    );
    // wp-admin redirects to /wp-login.php (302 → 200) — accept both
    const finalUrl = page.url();
    const status   = loginResp?.status() ?? 0;
    assert(
        status < 500 && (finalUrl.includes('wp-login') || finalUrl.includes('wp-admin')),
        `Admin login page: HTTP ${status} at ${finalUrl}`
    );
    const loginBody = await page.content();
    assert(
        !/(?:Fatal error|Parse error)/i.test(loginBody),
        'PHP fatal/parse error on admin login page'
    );
    console.log('  [2] PASSED');
}

async function runRepoSpecs(page, baseUrl) {
    if (!REPO_DIR) return;
    const e2eDir = path.join(REPO_DIR, '.loop-engineer', 'e2e');
    if (!fs.existsSync(e2eDir)) {
        console.log('  No per-repo specs (.loop-engineer/e2e/) — baseline only.');
        return;
    }
    const specs = fs.readdirSync(e2eDir).filter(f => f.endsWith('.js')).sort();
    if (specs.length === 0) {
        console.log('  .loop-engineer/e2e/ has no .js files — baseline only.');
        return;
    }
    for (const spec of specs) {
        console.log(`  Running repo spec: ${spec}`);
        const mod = require(path.join(e2eDir, spec));
        if (typeof mod.run !== 'function') {
            throw new Error(`${spec}: must export async function run(page, baseUrl)`);
        }
        await mod.run(page, baseUrl);
        console.log(`  PASSED: ${spec}`);
    }
}

async function main() {
    console.log('  Target:  ' + WP_TEST_URL);
    console.log('  Browser: ' + CHROME_BIN);

    const browser = await chromium.launch({
        executablePath: CHROME_BIN,
        headless: true,
        args: [
            '--no-sandbox',
            '--disable-setuid-sandbox',
            '--disable-dev-shm-usage',
            '--disable-gpu',
        ],
    });

    try {
        const page = await browser.newPage();
        await runBaseline(page, WP_TEST_URL);
        await runRepoSpecs(page, WP_TEST_URL);
        console.log('Browser E2E passed.');
    } finally {
        await browser.close();
    }
}

main().catch((err) => {
    console.error('E2E FAILED:', err.message);
    process.exit(1);
});
