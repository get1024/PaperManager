export class ConnectorError extends Error {
  constructor(message, status = 0, details = null) { super(message); this.status = status; this.details = details; }
}

export function connectorBaseURL(port = 29467) {
  if (!/^\d+$/.test(String(port)) || !Number.isInteger(Number(port)) || Number(port) < 1024 || Number(port) > 65535)
    throw new ConnectorError('本地 API 端口必须在 1024–65535 之间。');
  return `http://127.0.0.1:${Number(port)}`;
}

export function normalizeMetadata(input, collections = [], tags = [], strategy = 'skip') {
  const payload = {};
  const strings = ['title', 'journal', 'abstract', 'doi', 'volume', 'issue', 'pages', 'isbn', 'url', 'eprint', 'eprintType', 'eprintClass'];
  for (const key of strings) {
    if (input[key] !== undefined && typeof input[key] !== 'string') throw new ConnectorError(`${key} 必须是文本。`);
    if (typeof input[key] === 'string' && input[key].trim()) payload[key] = input[key].trim();
  }
  const bytes = value => new TextEncoder().encode(value || '').length;
  if (!payload.title || bytes(payload.title) > 1024) throw new ConnectorError('标题不能为空，且不能超过 1024 UTF-8 字节。');
  if (input.authors !== undefined) {
    if (!Array.isArray(input.authors) || input.authors.some(value => typeof value !== 'string' || !value.trim())) throw new ConnectorError('作者必须是非空姓名的列表。');
    if (input.authors.length) payload.authors = input.authors.map(value => value.trim());
  }
  if (bytes(payload.authors?.join('; ')) > 16384 || bytes(payload.abstract) > 65536) throw new ConnectorError('作者或摘要超过 API 的 UTF-8 长度限制。');
  if (input.year !== undefined && input.year !== '') {
    const year = Number(input.year);
    if (!Number.isSafeInteger(year)) throw new ConnectorError('年份必须是整数。');
    payload.year = year;
  }
  const types = ['article', 'book', 'inbook', 'incollection', 'inproceedings', 'proceedings', 'thesis', 'report', 'online', 'dataset', 'software', 'patent', 'manuscript', 'preprint', 'misc'];
  if (input.paperType && !types.includes(input.paperType)) throw new ConnectorError('不支持的文献类型。');
  if (input.paperType) payload.paperType = input.paperType;
  for (const [key, values] of [['collections', collections], ['tags', tags]]) {
    if (!Array.isArray(values) || values.length > 100 || values.some(value => typeof value !== 'string' || !value.trim() || bytes(value) > 256)) throw new ConnectorError(`${key} 超过数量或 UTF-8 长度限制。`);
    payload[key] = [...new Set(values)];
  }
  if (!['skip', 'replace'].includes(strategy)) throw new ConnectorError('重复处理只能选择跳过或替换。');
  payload.strategy = strategy;
  return payload;
}

export class ConnectorClient {
  constructor(port = 29467, fetcher = globalThis.fetch) { this.baseURL = connectorBaseURL(port); this.fetcher = fetcher; }
  async request(path, options = {}) {
    if (!path.startsWith('/connector/')) throw new ConnectorError('无效的本地 API 路径。');
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 30000);
    try {
      const response = await this.fetcher(this.baseURL + path, {
        ...options, redirect: 'error', credentials: 'omit', cache: 'no-store', signal: controller.signal
      });
      let result;
      try { result = await response.json(); } catch { throw new ConnectorError('本地 API 返回了无效的 JSON。', response.status); }
      if (!response.ok) throw new ConnectorError(result.error || `本地 API 错误 ${response.status}`, response.status, result);
      return result;
    } catch (error) {
      if (error instanceof ConnectorError) throw error;
      throw new ConnectorError(`无法连接本地 PaperManager：${error.message}`);
    } finally { clearTimeout(timeout); }
  }
  async status() {
    const result = await this.request('/connector/status');
    if (result.ok !== true || typeof result.readOnly !== 'boolean' || !Array.isArray(result.capabilities)) throw new ConnectorError('本地 API 状态格式不完整。');
    return result;
  }
  async options() {
    const [collections, tags] = await Promise.all([this.request('/connector/collections'), this.request('/connector/tags')]);
    if (!Array.isArray(collections.collections) || !Array.isArray(tags.tags)) throw new ConnectorError('文集或标签格式不完整。');
    return { collections: collections.collections, tags: tags.tags };
  }
  async save(metadata, { collections = [], tags = [], strategy = 'skip', pdf = null, replacePDF = false } = {}) {
    const payload = normalizeMetadata(metadata, collections, tags, strategy);
    const status = await this.status();
    if (status.readOnly || !status.capabilities.includes('create-paper')) throw new ConnectorError('本地 API 当前只读，未创建文献。');
    if (status.fileLibrary?.state === 'legacyConflict') throw new ConnectorError('请先在 PaperManager 设置中解决旧文件库位置冲突，再保存文献。');
    const warnings = [];
    let pdfBytes = null;
    if (pdf) {
      if (!status.fileLibrary?.available || !status.capabilities.includes('pdf-upload')) {
        warnings.push('只保存元数据；PDF 未上传。请先在 PaperManager 中配置或修复文件库。');
      } else {
        pdfBytes = pdf instanceof Uint8Array ? pdf : new Uint8Array(pdf);
        if (pdfBytes.byteLength > 200000000 || new TextDecoder().decode(pdfBytes.subarray(0, 5)) !== '%PDF-') throw new ConnectorError('所选文件不是 PDF，或超过 200 MB；尚未创建文献。');
      }
    }
    let created;
    try {
      created = await this.request('/connector/papers', { method: 'POST', headers: { 'Content-Type': 'application/json; charset=utf-8' }, body: JSON.stringify(payload) });
    } catch (error) {
      if (error.status === 409 && strategy === 'skip' && error.details?.existingPaperID) {
        return { kind: 'duplicate', id: error.details.existingPaperID, metadataSaved: false, pdfUploaded: false,
          warnings: ['发现已有文献，已跳过；没有替换记录或上传 PDF。'], conflict: error.details };
      }
      throw error;
    }
    if (typeof created.id !== 'string' || !/^[0-9a-f-]{36}$/i.test(created.id)) throw new ConnectorError('API 未返回有效文献 ID；请在应用中检查导入结果。');
    warnings.push(...(Array.isArray(created.warnings) ? created.warnings : []));
    let pdfUploaded = false;
    if (pdfBytes) {
      try {
        const uploaded = await this.request(`/connector/papers/${encodeURIComponent(created.id)}/pdf${replacePDF ? '?force=true' : ''}`, {
          method: 'PUT', headers: { 'Content-Type': 'application/pdf' }, body: pdfBytes
        });
        pdfUploaded = uploaded.reason === 'uploaded' || uploaded.pdfAttached === true;
        if (!pdfUploaded) warnings.push('元数据已保存，但 API 未确认 PDF 上传完成。');
      } catch (error) { warnings.push(`元数据已保存；PDF 未上传：${error.message}`); }
    }
    return { kind: warnings.length ? 'partial' : 'saved', id: created.id, metadataSaved: true, pdfUploaded, warnings,
      alreadyExists: created.alreadyExists === true, enrichmentStatus: created.enrichmentStatus || 'none' };
  }
}
