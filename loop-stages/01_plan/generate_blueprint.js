#!/usr/bin/env node
/**
 * Stage 01: Blueprint Generation
 *
 * Calls the Gemini API with issue context + repo standards to produce a
 * structured BLUEPRINT.md that guides the agent in stage 02.
 */

const fs = require('fs');
const path = require('path');
const https = require('https');

const REPO_DIR = process.env.REPO_DIR || path.join(__dirname, '../../repo');
const SCRIPT_DIR = path.join(__dirname, '../..');
const GEMINI_API_TOKEN = process.env.GEMINI_API_TOKEN;
const ISSUE_TITLE = process.env.ISSUE_TITLE || '';
const ISSUE_BODY = process.env.ISSUE_BODY || '';
const ISSUE_NUM = process.env.ISSUE_NUM || '';
const TARGET_REPO = process.env.TARGET_REPO || '';

if (!GEMINI_API_TOKEN) {
    console.error('GEMINI_API_TOKEN is not set');
    process.exit(1);
}

function readFileIfExists(filePath) {
    try {
        return fs.readFileSync(filePath, 'utf8');
    } catch {
        return null;
    }
}

function buildSystemPrompt(repoContext, standards) {
    return `You are a senior WordPress engineer planning a code change for the Disciple.Tools ecosystem.
Your job is to produce a structured engineering blueprint that another AI agent will execute.

## Coding Standards
${standards}

## Repository Context
${repoContext}

## Output Requirements
Respond with ONLY valid Markdown for a file called BLUEPRINT.md.
The blueprint MUST contain these exact sections:

### Task Summary
One paragraph describing what needs to be done and why.

### Files to Modify
A bulleted list of file paths (relative to repo root) the agent should read and possibly change.

### Implementation Plan
Numbered steps the agent should follow. Be specific — name functions, hooks, and patterns.

### Acceptance Criteria
A checklist the agent can verify against when done. Each item should be testable.

### Edge Cases & Constraints
Anything the agent must not do, or corner cases it must handle.

Do not include any text outside the Markdown blueprint.`;
}

function buildUserPrompt() {
    return `Repository: ${TARGET_REPO}
Issue #${ISSUE_NUM}: ${ISSUE_TITLE}

Issue description:
${ISSUE_BODY}

Produce a BLUEPRINT.md for implementing this issue.`;
}

async function callGemini(systemPrompt, userPrompt) {
    const body = JSON.stringify({
        system_instruction: { parts: [{ text: systemPrompt }] },
        contents: [{ role: 'user', parts: [{ text: userPrompt }] }],
        generationConfig: {
            temperature: 0.3,
            maxOutputTokens: 4096,
        },
    });

    const model = 'gemini-1.5-pro-latest';
    const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${GEMINI_API_TOKEN}`;

    return new Promise((resolve, reject) => {
        const parsed = new URL(url);
        const options = {
            hostname: parsed.hostname,
            path: parsed.pathname + parsed.search,
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(body),
            },
        };

        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', (chunk) => { data += chunk; });
            res.on('end', () => {
                if (res.statusCode !== 200) {
                    reject(new Error(`Gemini API error ${res.statusCode}: ${data}`));
                    return;
                }
                const parsed = JSON.parse(data);
                const text = parsed?.candidates?.[0]?.content?.parts?.[0]?.text;
                if (!text) {
                    reject(new Error('No text in Gemini response: ' + JSON.stringify(parsed)));
                    return;
                }
                resolve(text);
            });
        });
        req.on('error', reject);
        req.write(body);
        req.end();
    });
}

async function main() {
    console.log('Generating blueprint for issue #' + ISSUE_NUM + '...');

    // Gather repo context (prefer local overrides)
    const contextFiles = ['CLAUDE.md', 'README.md', '.phpcs.xml', 'phpunit.xml'];
    let repoContext = '';
    for (const file of contextFiles) {
        const content = readFileIfExists(path.join(REPO_DIR, file));
        if (content) {
            repoContext += `\n### ${file}\n${content.slice(0, 3000)}\n`;
        }
    }
    if (!repoContext) {
        repoContext = '(No context files found in repo root)';
    }

    // Load standards: local override takes precedence
    const localStandards = readFileIfExists(path.join(REPO_DIR, '.loop-engineer/STANDARDS.md'));
    const systemStandards = readFileIfExists(path.join(SCRIPT_DIR, 'skills/WP_STANDARDS.md'));
    const standards = localStandards || systemStandards || '(No standards file found — apply WordPress coding standards defaults)';

    const systemPrompt = buildSystemPrompt(repoContext, standards);
    const userPrompt = buildUserPrompt();

    const blueprint = await callGemini(systemPrompt, userPrompt);

    const outputPath = path.join(REPO_DIR, 'BLUEPRINT.md');
    fs.writeFileSync(outputPath, blueprint, 'utf8');
    console.log('Blueprint written to BLUEPRINT.md');
}

main().catch((err) => {
    console.error('Blueprint generation failed:', err.message);
    process.exit(1);
});
