import { capturePageMetadata } from './extract.mjs';
import { ConnectorClient, ConnectorError } from './core.mjs';

const browserAPI = globalThis.browser || globalThis.chrome;
const element = id => document.getElementById(id);
let client, captured = {}, tabURL = '', currentStatus;
const types = {article:'期刊论文',book:'图书',inbook:'图书章节',incollection:'论文集章节',inproceedings:'会议论文',proceedings:'会议论文集',thesis:'学位论文',report:'报告',online:'在线资源',dataset:'数据集',software:'软件',patent:'专利',manuscript:'手稿',preprint:'预印本',misc:'其他'};
for (const [value, title] of Object.entries(types)) element('type').add(new Option(title, value));
function message(text, error = false) { element('result').textContent = text; element('result').dataset.error = String(error); }
function selected(id) { return Array.from(element(id).selectedOptions, item => item.value); }
function fillSelect(id, values, valueKey) {
  element(id).replaceChildren();
  for (const item of values) element(id).add(new Option(item.path || item.name, item[valueKey]));
}
function canReadPagePDF() {
  try { return Boolean(captured.pdfURL) && new URL(captured.pdfURL).origin === new URL(tabURL).origin; }
  catch { return false; }
}
async function boundedPDF(response) {
  const length = Number(response.headers.get('content-length') || 0);
  if (length > 200000000) throw new ConnectorError('PDF 超过 200 MB，尚未保存文献。');
  const reader = response.body?.getReader();
  if (!reader) {
    const data = await response.arrayBuffer();
    if (data.byteLength > 200000000) throw new ConnectorError('PDF 超过 200 MB，尚未保存文献。');
    return data;
  }
  const chunks = []; let size = 0;
  for (;;) {
    const { done, value } = await reader.read(); if (done) break;
    size += value.byteLength;
    if (size > 200000000) { await reader.cancel(); throw new ConnectorError('PDF 超过 200 MB，尚未保存文献。'); }
    chunks.push(value);
  }
  const data = new Uint8Array(size); let offset = 0;
  for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.byteLength; }
  return data;
}
async function connect() {
  element('save').disabled = true;
  try {
    client = new ConnectorClient(element('port').value);
    const [status, choices] = await Promise.all([client.status(), client.options()]);
    currentStatus = status;
    await browserAPI.storage.local.set({ port: element('port').value });
    fillSelect('collections', choices.collections, 'path'); fillSelect('tags', choices.tags, 'name');
    element('connection').textContent = status.readOnly ? '已连接 · 只读模式' : '已连接本地文库';
    const available = status.fileLibrary?.available && status.capabilities.includes('pdf-upload');
    element('file-state').textContent = available ? 'PDF 将复制到已配置的文件库。' : '当前只能保存元数据；请在应用中配置或修复文件库后上传 PDF。';
    element('page-pdf').disabled = !available || !canReadPagePDF();
    element('pdf-file').disabled = !available;
    element('replace-pdf').disabled = !available;
    element('save').disabled = status.readOnly || status.fileLibrary?.state === 'legacyConflict';
    if (status.fileLibrary?.state === 'legacyConflict') message('请先在应用设置中解决旧文件库位置冲突。', true);
    else if (!canReadPagePDF() && captured.pdfURL) element('file-state').textContent += ' 跨站 PDF 请先下载，再选择文件。';
  } catch (error) { element('connection').textContent = '未连接'; message(error.message, true); }
}
async function capture() {
  const tabs = await browserAPI.tabs.query({ active: true, currentWindow: true });
  const tab = tabs[0];
  if (!tab?.id || !/^https?:\/\//i.test(tab.url || '')) throw new ConnectorError('请在普通学术网页中打开扩展；浏览器内部页面无法读取。');
  tabURL = tab.url;
  try {
    const results = await browserAPI.scripting.executeScript({ target: { tabId: tab.id }, func: capturePageMetadata });
    captured = results[0]?.result || {};
  } catch { captured = { title: tab.title || '', url: tab.url, authors: [], paperType: 'article' }; }
  for (const id of ['title','journal','doi','eprint','isbn','url','abstract']) element(id).value = captured[id] || '';
  element('authors').value = (captured.authors || []).join('\n');
  element('year').value = captured.year || '';
  element('type').value = captured.paperType || 'article';
}
element('save-form').addEventListener('submit', async event => {
  event.preventDefault(); element('save').disabled = true; message('正在保存…请保持此窗口打开，直到操作完成。');
  try {
    const metadata = {};
    for (const id of ['title','journal','doi','eprint','isbn','url','abstract']) metadata[id] = element(id).value;
    metadata.authors = element('authors').value.split('\n').map(value => value.trim()).filter(Boolean);
    metadata.year = element('year').value; metadata.paperType = element('type').value;
    if (metadata.eprint) metadata.eprintType = captured.eprintType || 'arXiv';
    let pdf = null;
    if (element('pdf-file').files[0]) {
      const file = element('pdf-file').files[0];
      if (file.size > 200000000) throw new ConnectorError('PDF 超过 200 MB，尚未保存文献。');
      pdf = await file.arrayBuffer();
    }
    else if (element('page-pdf').checked) {
      if (!canReadPagePDF()) throw new ConnectorError('当前 PDF 位于另一网站，请先下载后选择文件。');
      const response = await fetch(captured.pdfURL, { redirect: 'error', credentials: 'include' });
      if (!response.ok) throw new ConnectorError(`PDF 下载失败 (${response.status})；尚未保存文献。`);
      pdf = await boundedPDF(response);
    }
    const result = await client.save(metadata, { collections: selected('collections'), tags: selected('tags'), strategy: element('strategy').value,
      pdf, replacePDF: element('replace-pdf').checked });
    const headline = result.kind === 'duplicate' ? '已有文献，已跳过。' : (result.pdfUploaded ? '元数据和 PDF 已保存。' : '元数据已保存。');
    message([headline, ...result.warnings].join('\n'));
  } catch (error) { message(error.message, true); }
  finally { element('save').disabled = currentStatus?.readOnly !== false || currentStatus?.fileLibrary?.state === 'legacyConflict'; }
});
element('reconnect').addEventListener('click', connect);
try {
  const settings = await browserAPI.storage.local.get('port');
  element('port').value = settings.port || 29467;
  await capture();
  await connect();
} catch (error) { message(error.message, true); }
