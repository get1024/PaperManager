import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, realpath, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer } from 'node:net';
import { createServer as createHTTPServer } from 'node:http';
import { createInterface } from 'node:readline';
import { capturePageMetadata } from '../../BrowserExtension/extract.mjs';
import { ConnectorClient, connectorBaseURL, normalizeMetadata } from '../../BrowserExtension/core.mjs';

const [cliPath, fixturePath] = process.argv.slice(2);
const root = await mkdtemp(join(tmpdir(), 'papermanager-connector-fixture-'));
const probe = createServer();
await new Promise(resolve => probe.listen(0, '127.0.0.1', resolve));
const port = probe.address().port;
await new Promise(resolve => probe.close(resolve));
const fixture = spawn(fixturePath, [root, String(port)], { stdio: ['pipe', 'pipe', 'pipe'] });
const lines = createInterface({ input: fixture.stdout });
const lineQueue = [], lineWaiters = [];
lines.on('line', line => { const waiter = lineWaiters.shift(); if (waiter) waiter(JSON.parse(line)); else lineQueue.push(JSON.parse(line)); });
fixture.stderr.on('data', chunk => process.stderr.write(chunk));
const nextLine = () => lineQueue.length ? Promise.resolve(lineQueue.shift()) : new Promise((resolve, reject) => {
  const timeout = setTimeout(() => reject(new Error('Fixture/MCP response timeout')), 20000);
  lineWaiters.push(value => { clearTimeout(timeout); resolve(value); });
});
const info = await nextLine();
assert.equal(info.ready, true);
const environment = { ...process.env, PAPERMANAGER_CLI_BASE_URL: `http://127.0.0.1:${port}`, PAPERMANAGER_CLI_READONLY: '1' };
const client = new ConnectorClient(port);
let passed = 0;
const tests = [];
const test = (name, body) => tests.push([name, body]);
async function cli(args, extra = {}) {
  return await new Promise((resolve, reject) => {
    const child = spawn(cliPath, args, { env: { ...environment, ...extra }, stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '', stderr = '';
    child.stdout.on('data', value => stdout += value); child.stderr.on('data', value => stderr += value);
    child.once('error', reject); child.once('exit', code => resolve({ code, stdout, stderr, json: () => JSON.parse(stdout) }));
  });
}
async function control(object) { fixture.stdin.write(JSON.stringify(object) + '\n'); assert.equal((await nextLine()).control, 'ok'); }
function fakeDocument(entries, title = 'Fallback title', structured = []) {
  return { title, baseURI: 'https://example.test/article', querySelector: () => null,
    querySelectorAll: selector => selector === 'meta' ? entries.map(([name, content]) => ({ getAttribute: key => key === 'name' ? name : key === 'content' ? content : null })) : structured.map(value => ({ textContent: JSON.stringify(value) })) };
}

test('Native CLI version/help and default read-only status', async () => {
  assert.equal((await cli(['--version'])).stdout.trim(), '1.0.0');
  assert.match((await cli(['--help'])).stdout, /get-csl-item/);
  const result = await cli(['status']); assert.equal(result.code, 0); assert.equal(result.stderr, '');
  assert.equal(result.json().effectiveReadOnly, true); assert.equal(result.json().clientReadOnly, true);
});
test('Native CLI read operations use exact identities and unchanged CSL', async () => {
  const search = await cli(['search', '--query', 'Ada Connector', '--limit', '20']);
  assert.equal(search.code, 0); assert.equal(search.json().papers[0].id, info.id);
  const detail = await cli(['get-paper', '--id', info.id, '--include', 'abstract', '--include', 'pdf_path', '--include', 'library']);
  assert.equal(detail.code, 0); assert.equal(detail.json().abstract, 'Fixture abstract'); assert.equal(detail.json().pdfPath, info.pdf);
  assert.equal((await cli(['get-paper-by-reference', '--reference', ' FIXTURE2026 '])).json().id, info.id);
  assert.equal((await cli(['get-csl-item', '--reference', 'fixture2026'])).json().title, 'Connector fixture');
  assert.equal((await cli(['collections'])).json().collections[0].path, info.collection);
  assert.equal((await cli(['tags'])).json().tags[0].name, info.tag);
  for (const reference of ['fixture', 'collision']) assert.equal((await cli(['get-paper-by-reference', '--reference', reference])).code, 1);
});
test('CLI rejects remote configurations, malformed inputs and UTF-8 overflow before writing', async () => {
  for (const url of ['https://example.test:29467', 'http://127.0.0.1:29467/api', 'http://user:pass@127.0.0.1:29467', 'http://localhost.evil.test:29467']) {
    assert.equal((await cli(['--base-url', url, 'status'])).code, 2);
  }
  assert.equal((await cli(['search', '--limit', '51'])).code, 2);
  assert.equal((await cli(['create-paper', '--allow-write', '--title', '汉'.repeat(342)])).code, 2);
  assert.equal((await cli(['create-paper', '--allow-write', '--title', 'Bad authors', '--authors', '[""]'])).code, 2);
  assert.equal((await cli(['get-paper', '--id', 'bad'])).code, 2);
});
test('CLI writes require both client and server policy and preserve duplicate conflicts', async () => {
  assert.equal((await cli(['create-paper', '--title', 'Forbidden fixture'])).code, 2);
  await control({ readOnly: true });
  assert.equal((await cli(['create-paper', '--allow-write', '--title', 'Server blocked fixture'])).code, 1);
  await control({ readOnly: false });
  const result = await cli(['create-paper', '--allow-write', '--title', '新建文献 fixture', '--authors', '["姓名一","Ada"]', '--type', 'incollection', '--collection', info.collection, '--tag', info.tag]);
  assert.equal(result.code, 0); assert.equal(result.json().title, '新建文献 fixture');
  const duplicate = await cli(['create-paper', '--allow-write', '--title', 'Duplicate', '--doi', '10.5555/connector-fixture']);
  assert.equal(duplicate.code, 1); assert.equal(duplicate.stdout, ''); assert.equal(JSON.parse(duplicate.stderr).response.alreadyExists, true);
});
test('CLI PDF upload requires explicit force and preserves the protected source', async () => {
  const before = await readFile(info.pdf);
  assert.equal((await cli(['attach-pdf', '--allow-write', '--id', info.id, '--pdf-path', info.pdf])).code, 1);
  const upload = await cli(['attach-pdf', '--allow-write', '--id', info.id, '--pdf-path', info.pdf, '--force']);
  assert.equal(upload.code, 0); assert.equal(upload.json().reason, 'uploaded');
  assert.deepEqual(await readFile(info.pdf), before);
});
test('CLI refuses redirects to any other API endpoint', async () => {
  let reached = false;
  const redirected = createHTTPServer((req, res) => { reached = true; res.end('{}'); });
  await new Promise(resolve => redirected.listen(0, '127.0.0.1', resolve));
  const redirector = createHTTPServer((req, res) => { res.writeHead(302, { Location: `http://127.0.0.1:${redirected.address().port}/api/v1/status` }); res.end(); });
  await new Promise(resolve => redirector.listen(0, '127.0.0.1', resolve));
  try { assert.equal((await cli(['--base-url', `http://127.0.0.1:${redirector.address().port}`, 'status'])).code, 1); assert.equal(reached, false); }
  finally { await Promise.all([new Promise(resolve => redirector.close(resolve)), new Promise(resolve => redirected.close(resolve))]); }
});
test('MCP stdio initializes, lists read-only tools and calls the actual local API', async () => {
  const child = spawn(cliPath, ['mcp'], { env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
  const responses = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const rpc = async (id, method, params = {}) => { child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n'); return JSON.parse((await responses.next()).value); };
  try {
    assert.equal((await rpc(1, 'initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'fixture', version: '1' } })).result.protocolVersion, '2025-11-25');
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
    const list = await rpc(2, 'tools/list'); assert.ok(list.result.tools.some(tool => tool.name === 'papermanager_search'));
    assert.ok(!list.result.tools.some(tool => tool.name === 'papermanager_create_paper'));
    const result = await rpc(3, 'tools/call', { name: 'papermanager_get_paper', arguments: { id: info.id } });
    assert.equal(result.result.structuredContent.id, info.id); assert.equal(result.result.isError, false);
    const denied = await rpc(4, 'tools/call', { name: 'papermanager_create_paper', arguments: { metadata: { title: 'MCP denied fixture' } } });
    assert.equal(denied.result.isError, true);
    assert.equal((await rpc(5, 'unknown')).error.code, -32601);
    const limitOne = await rpc(6, 'tools/call', { name: 'papermanager_search', arguments: { limit: 1 } });
    assert.equal(limitOne.result.isError, false); assert.equal(limitOne.result.structuredContent.papers.length, 1);
  } finally { child.stdin.end(); child.kill('SIGTERM'); }
});
test('MCP writes require opt-in and enforce metadata/force schemas and server read-only', async () => {
  const child = spawn(cliPath, ['mcp', '--allow-write'], { env: environment, stdio: ['pipe', 'pipe', 'pipe'] });
  const responses = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
  const rpc = async (id, method, params = {}) => { child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n'); return JSON.parse((await responses.next()).value); };
  try {
    await rpc(1, 'initialize', { protocolVersion: '2025-11-25' });
    assert.ok((await rpc(2, 'tools/list')).result.tools.some(tool => tool.name === 'papermanager_create_paper'));
    const created = await rpc(3, 'tools/call', { name: 'papermanager_create_paper', arguments: { metadata: { title: 'MCP explicit write fixture' } } });
    assert.equal(created.result.isError, false); assert.ok(created.result.structuredContent.id);
    const invalid = await rpc(4, 'tools/call', { name: 'papermanager_create_paper', arguments: { metadata: { title: 'Bad year fixture', year: true } } });
    assert.equal(invalid.result.isError, true);
    const badForce = await rpc(5, 'tools/call', { name: 'papermanager_attach_pdf', arguments: { id: info.id, path: info.pdf, force: 1 } });
    assert.equal(badForce.result.isError, true);
    await control({ readOnly: true });
    const blocked = await rpc(6, 'tools/call', { name: 'papermanager_create_paper', arguments: { metadata: { title: 'MCP server blocked fixture' } } });
    assert.equal(blocked.result.isError, true);
  } finally { await control({ readOnly: false }); child.stdin.end(); child.kill('SIGTERM'); }
});
test('Agent exporters produce portable text/configuration without installing anything', async () => {
  const skill = await cli(['export-skill']); assert.equal(skill.code, 0); assert.match(skill.stdout, /name: papermanager-cli/);
  const customSkill = await cli(['--port', '31415', '--read-only', 'export-skill']);
  assert.equal(customSkill.code, 0);
  assert.match(customSkill.stdout, /--base-url http:\/\/127\.0\.0\.1:31415 --read-only status/);
  const config = (await cli(['export-mcp-config'])).json(); assert.equal(config.mcpServers.papermanager.env.PAPERMANAGER_CLI_READONLY, '1');
  assert.equal(await realpath(config.mcpServers.papermanager.command), await realpath(cliPath));
  const target = join(root, 'SKILL.md');
  assert.equal((await cli(['export-skill', '--output', target])).code, 0);
  assert.match(await readFile(target, 'utf8'), /Executable for this exported integration/);
  assert.equal((await cli(['export-skill', '--output', target])).code, 2);
});
test('Academic metadata capture reads local highwire/JSON-LD fixtures without executing page scripts', async () => {
  const captured = capturePageMetadata(fakeDocument([['citation_title', '学术 fixture'], ['citation_author', 'Ada'], ['citation_author', 'Grace'], ['citation_doi', 'https://doi.org/10.5555/browser-fixture'], ['citation_publication_date', '2026/10/18'], ['citation_pdf_url', '/paper.pdf']]), 'https://example.test/article');
  assert.equal(captured.title, '学术 fixture'); assert.deepEqual(captured.authors, ['Ada', 'Grace']); assert.equal(captured.doi, '10.5555/browser-fixture'); assert.equal(captured.year, 2026); assert.equal(captured.pdfURL, 'https://example.test/paper.pdf');
  const structured = capturePageMetadata(fakeDocument([], '', [{ '@type': 'ScholarlyArticle', headline: 'Structured fixture', author: [{ name: 'Ada' }], datePublished: '2020-01-01' }]), 'https://example.test/article');
  assert.equal(structured.title, 'Structured fixture'); assert.equal(structured.year, 2020);
  assert.throws(() => connectorBaseURL('29467/evil'));
  assert.throws(() => normalizeMetadata({ title: '汉'.repeat(342) }));
});
test('Browser connector saves metadata/PDF, returns duplicate state, and does not escalate PDF conflicts', async () => {
  const pdf = await readFile(info.pdf);
  const first = await client.save({ title: 'Browser local fixture', authors: ['Ada'], doi: '10.5555/browser-fixture' }, { collections: [info.collection], tags: [info.tag], pdf });
  assert.equal(first.kind, 'saved'); assert.equal(first.pdfUploaded, true);
  const duplicate = await client.save({ title: 'Browser duplicate', doi: '10.5555/browser-fixture' }, { pdf });
  assert.equal(duplicate.kind, 'duplicate'); assert.equal(duplicate.metadataSaved, false); assert.equal(duplicate.pdfUploaded, false);
  const replace = await client.save({ title: 'Browser replacement', doi: '10.5555/browser-fixture' }, { strategy: 'replace', pdf });
  assert.equal(replace.metadataSaved, true); assert.equal(replace.kind, 'partial'); assert.match(replace.warnings.join(' '), /PDF/);
});
test('Browser connector clearly falls back to metadata-only and blocks legacy conflict/read-only states', async () => {
  const pdf = await readFile(info.pdf);
  await control({ fileLibrary: 'unavailable' });
  const result = await client.save({ title: 'Metadata only fixture' }, { pdf });
  assert.equal(result.metadataSaved, true); assert.equal(result.pdfUploaded, false); assert.equal(result.kind, 'partial'); assert.match(result.warnings[0], /只保存元数据/);
  await control({ fileLibrary: 'legacyConflict' });
  await assert.rejects(client.save({ title: 'Legacy blocked fixture' }), /旧文件库/);
  await control({ fileLibrary: 'configured', readOnly: true });
  await assert.rejects(client.save({ title: 'Read-only blocked fixture' }), /只读/);
  await control({ readOnly: false });
});

try {
  for (const [name, body] of tests) { await body(); passed++; console.log(`PASS: ${name}`); }
  console.log(`Connector regression: ${passed} passed, 0 failed`);
} catch (error) { console.error(error); process.exitCode = 1; console.error(`Connector regression: ${passed} passed before failure`); }
finally { fixture.stdin.end(); fixture.kill('SIGTERM'); lines.close(); await rm(root, { recursive: true, force: true }); }
