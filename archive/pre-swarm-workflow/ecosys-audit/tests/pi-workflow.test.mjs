// Native Node 24 TypeScript loading; fake Pi API, no providers/auth/network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import workflow, { inside, noisy, BOOTSTRAP } from '../../.pi/extensions/ecosys-workflow.ts';

function fixture(t, herdr = false) {
  const root = mkdtempSync(resolve(tmpdir(), 'ecosys-pi-test-'));
  const oldEnv = process.env.HERDR_ENV, oldPane = process.env.HERDR_PANE_ID;
  if (herdr) { process.env.HERDR_ENV = '1'; process.env.HERDR_PANE_ID = 'fixture:p2'; }
  else delete process.env.HERDR_ENV;
  const events = {};
  workflow({ on(name, fn) { events[name] = fn; } });
  const ctx = { cwd: root, sessionManager: { getSessionId: () => 'pi-fixture' } };
  events.session_start({}, ctx);
  t.after(() => {
    if (oldEnv === undefined) delete process.env.HERDR_ENV; else process.env.HERDR_ENV = oldEnv;
    if (oldPane === undefined) delete process.env.HERDR_PANE_ID; else process.env.HERDR_PANE_ID = oldPane;
    rmSync(root, { recursive: true, force: true });
  });
  return { root, events, ctx };
}

function state(root, value) {
  mkdirSync(resolve(root, 'audit/workflow/runtime'), { recursive: true });
  writeFileSync(resolve(root, 'audit/workflow/runtime/state.json'), JSON.stringify(value));
}

test('stable bootstrap section works with omitted sections and adds no model request', t => {
  const { events } = fixture(t);
  const e = { systemPromptOptions: {} };
  assert.equal(events.before_agent_start(e), undefined);
  assert.equal(e.systemPromptOptions.sections.ecosys_workflow, BOOTSTRAP);
  assert.ok(BOOTSTRAP.length < 1200);
});

test('native registration reports session identity and settled state', t => {
  const { root, events, ctx } = fixture(t, true);
  events.agent_start({}, ctx);
  let r = JSON.parse(readFileSync(resolve(root, 'audit/workflow/runtime/reviewer.json')));
  assert.equal(r.activity, 'working');
  events.agent_settled({}, ctx);
  r = JSON.parse(readFileSync(resolve(root, 'audit/workflow/runtime/reviewer.json')));
  assert.equal(r.activity, 'idle');
  assert.equal(r.session_id, 'pi-fixture');
});

test('reviewer direct file writes stay in lane', t => {
  const { root, events } = fixture(t, true);
  state(root, { phase: 'review', task: 'fixture', revision: 1 });
  assert.equal(events.tool_call({ toolName: 'write', input: { path: 'ecosys-ng/source.zig' } }).block, true);
  assert.equal(events.tool_call({ toolName: 'write', input: { path: 'audit/reviews/finding.md' } }), undefined);
  assert.throws(() => inside(root, '../escape'));
});

test('handoff writes require checkpoint helper', t => {
  const { events } = fixture(t);
  assert.equal(events.tool_call({ toolName: 'edit', input: { path: 'audit/handoff.md' } }).block, true);
});

test('raw commands route to log wrapper without blocking source search', () => {
  assert.equal(noisy('zig build test'), true);
  assert.equal(noisy('uv run run_logged.py --timeout 60 -- zig build test'), false);
  assert.equal(noisy('rg init ecosys-ng/src/ecosys_ng.zig'), false);
});

test('oversized shell output persists losslessly but response is bounded', t => {
  const { root, events } = fixture(t);
  const text = 'failure and warning\n'.repeat(3000);
  const result = events.tool_result({ toolName: 'powershell', content: [{ type: 'text', text }], isError: true });
  assert.ok(result.content[0].text.length < 5000);
  assert.match(result.content[0].text, /may already have truncated/);
  const path = result.content[0].text.match(/File: (.*?) SHA256=/)[1];
  assert.equal(readFileSync(resolve(root, path), 'utf8'), text);
  assert.equal(result.isError, undefined); // omitted field preserves underlying error via Pi middleware
});

test('source reads and non-text content are never silently shortened', t => {
  const { events } = fixture(t);
  const text = 'x'.repeat(20000);
  assert.equal(events.tool_result({ toolName: 'read', content: [{ type: 'text', text }] }), undefined);
  assert.equal(events.tool_result({ toolName: 'powershell', content: [{ type: 'text', text }, { type: 'image' }] }), undefined);
});

test('missing review gets only one assigned continuation, never an endless loop', t => {
  const { root, events, ctx } = fixture(t, true);
  state(root, { phase: 'review', task: 'fixture', revision: 1 });
  writeFileSync(resolve(root, 'audit/workflow/runtime/dispatch.json'), JSON.stringify({ role: 'reviewer', session_id: 'pi-fixture' }));
  assert.equal(events.agent_before_settle({ entries: [] }, ctx).continue, true);
  assert.equal(events.agent_before_settle({ entries: [] }, ctx), undefined);
});

test('valid receipt needs no reminder or extra model turn', t => {
  const { root, events, ctx } = fixture(t, true);
  state(root, { phase: 'review', task: 'fixture', revision: 1 });
  writeFileSync(resolve(root, 'audit/workflow/runtime/dispatch.json'), JSON.stringify({ role: 'reviewer', session_id: 'pi-fixture' }));
  mkdirSync(resolve(root, 'audit/reviews'), { recursive: true });
  writeFileSync(resolve(root, 'audit/reviews/fixture-r1.json'), '{}');
  assert.equal(events.agent_before_settle({ entries: [] }, ctx), undefined);
});
