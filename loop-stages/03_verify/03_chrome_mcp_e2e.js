#!/usr/bin/env node
/**
 * Verify Stage 03: Browser-driven E2E via Playwright MCP
 *
 * Connects to the running MCP server and exercises the WordPress instance
 * to confirm the agent's changes work in a real browser environment.
 *
 * TODO: This is a scaffold. Actual test scenarios need to be defined
 * based on what "working" means for each issue type.
 */

const http = require('http');

const MCP_PORT = process.env.MCP_PORT || '9222';
const WP_URL = process.env.WP_TEST_URL || 'http://localhost:8080';

function mcpCall(method, params = {}) {
    const body = JSON.stringify({ jsonrpc: '2.0', id: 1, method, params });
    return new Promise((resolve, reject) => {
        const options = {
            hostname: 'localhost',
            port: parseInt(MCP_PORT),
            path: '/',
            method: 'POST',
            headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
        };
        const req = http.request(options, (res) => {
            let data = '';
            res.on('data', (c) => { data += c; });
            res.on('end', () => {
                const parsed = JSON.parse(data);
                if (parsed.error) reject(new Error(parsed.error.message));
                else resolve(parsed.result);
            });
        });
        req.on('error', reject);
        req.write(body);
        req.end();
    });
}

async function smokeTest() {
    console.log('=== Browser E2E (Chrome MCP) ===');

    // Check if Playwright MCP is reachable
    try {
        await mcpCall('browser_navigate', { url: WP_URL });
        console.log('Navigated to WordPress instance.');
    } catch (err) {
        console.error('Could not connect to Playwright MCP server on port ' + MCP_PORT);
        console.error('Is the MCP server running? Check run_opencode_agent.sh startup.');
        console.error(err.message);
        process.exit(1);
    }

    // Smoke test: WordPress site loads (no PHP fatal errors)
    const snapshot = await mcpCall('browser_snapshot', {});
    const content = JSON.stringify(snapshot);

    if (content.includes('Fatal error') || content.includes('Parse error')) {
        console.error('PHP fatal error detected on WordPress front page.');
        console.error(content.slice(0, 1000));
        process.exit(1);
    }

    console.log('WordPress front page loads without fatal errors.');

    // Per-repo E2E specs (optional)
    const repoDir = process.env.REPO_DIR || '';
    const fs = require('fs');
    const path = require('path');
    const e2eDir = path.join(repoDir, '.loop-engineer/e2e');

    if (fs.existsSync(e2eDir)) {
        const specs = fs.readdirSync(e2eDir).filter(f => f.endsWith('.js')).sort();
        for (const spec of specs) {
            console.log('Running repo E2E spec: ' + spec);
            // Dynamically require per-repo specs
            // Each spec should export async function run(mcpCall) and throw on failure
            const mod = require(path.join(e2eDir, spec));
            await mod.run(mcpCall);
            console.log('  PASSED: ' + spec);
        }
    } else {
        console.log('No per-repo E2E specs found at .loop-engineer/e2e/ — smoke test only.');
    }

    console.log('Browser E2E passed.');
}

smokeTest().catch((err) => {
    console.error('E2E failed:', err.message);
    process.exit(1);
});
