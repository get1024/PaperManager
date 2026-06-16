var R = Object.defineProperty;
var U = (e, t, a) =>
  t in e
    ? R(e, t, { enumerable: !0, configurable: !0, writable: !0, value: a })
    : (e[t] = a);
var y = (e, t, a) => U(e, typeof t != "symbol" ? t + "" : t, a);
import { b as l } from "./browser-polyfill-DgstG05v.js";
class s extends Error {
  constructor(t, a) {
    super(t), (this.statusCode = a), (this.name = "LatticeClientError");
  }
}
class w extends s {
  constructor(t) {
    super("Duplicate paper.", 409),
      (this.conflict = t),
      (this.name = "DuplicateConflictError");
  }
}
class m extends s {
  constructor() {
    super("PDF exceeds the 200MB upload limit.", 413),
      (this.name = "PayloadTooLargeError");
  }
}
class b extends s {
  constructor() {
    super("The Lattice library is at its free-tier limit.", 422),
      (this.name = "LibraryFullError");
  }
}
class E extends s {
  constructor() {
    super("Lattice is not configured to accept PDF uploads.", 503),
      (this.name = "PDFDestinationNotConfiguredError");
  }
}
class k extends s {
  constructor(t) {
    super(`Network error: ${String(t)}`),
      (this.cause = t),
      (this.name = "NetworkError");
  }
}
const L = "http://127.0.0.1:29467",
  v = 1e4,
  c = "/connector";
class u {
  constructor(t) {
    y(this, "normalizedBaseURL");
    this.normalizedBaseURL = t.replace(/\/+$/, "");
  }
  async getStatus() {
    var n;
    const a = await (await this.fetch(`${c}/status`, { method: "GET" })).json();
    return {
      ok: a.ok,
      apiVersion: a.apiVersion,
      serverVersion: a.serverVersion ?? a.appVersion ?? a.version ?? "",
      readOnly: a.readOnly,
      capabilities: Array.isArray(a.capabilities) ? a.capabilities : [],
      baseURL: ((n = a.baseURL) == null ? void 0 : n.trim()) || void 0,
      browserExtensionEnabled: a.browserExtensionEnabled,
    };
  }
  async getCollections() {
    const a = await (
      await this.fetch(`${c}/collections`, { method: "GET" })
    ).json();
    return Array.isArray(a) ? a : (a.collections ?? []);
  }
  async getTags() {
    const a = await (await this.fetch(`${c}/tags`, { method: "GET" })).json();
    return Array.isArray(a) ? a : (a.tags ?? []);
  }
  async createPaper(t) {
    const n = await (
      await this.fetch(`${c}/papers`, {
        method: "POST",
        body: JSON.stringify(t),
        contentType: "application/json",
      })
    ).json();
    return {
      id: n.id ?? "",
      title: n.title ?? t.title,
      authors: n.authors ?? null,
      year: n.year ?? null,
      doi: n.doi ?? null,
      pdfAttached: n.pdfAttached ?? !1,
      enrichmentStatus: n.enrichmentStatus ?? "none",
      warnings: Array.isArray(n.warnings) ? n.warnings : [],
      alreadyExists: n.alreadyExists ?? !1,
      conflict: n.conflict ?? null,
    };
  }
  async uploadPDF(t, a, n = !1) {
    const r = `${c}/papers/${encodeURIComponent(t)}/pdf${n ? "?force=true" : ""}`;
    await this.fetch(r, {
      method: "PUT",
      body: a,
      contentType: "application/pdf",
    });
  }
  async lookupMetadata(t) {
    const a = new URLSearchParams();
    for (const [o, i] of Object.entries(t))
      typeof i == "string" && i.trim() && a.set(o, i.trim());
    if ([...a.keys()].length === 0) return null;
    const n = new AbortController(),
      r = setTimeout(() => n.abort(), v);
    try {
      return await (
        await this.fetch(`${c}/metadata?${a.toString()}`, {
          method: "GET",
          signal: n.signal,
        })
      ).json();
    } catch {
      return null;
    } finally {
      clearTimeout(r);
    }
  }
  async fetch(t, a) {
    const n = new Headers();
    a.contentType && n.set("content-type", a.contentType);
    let r;
    try {
      r = await globalThis.fetch(`${this.normalizedBaseURL}${t}`, {
        method: a.method,
        headers: n,
        body: a.body,
        signal: a.signal,
      });
    } catch (o) {
      throw new k(o);
    }
    if (r.ok) return r;
    throw await this.mapErrorResponse(r);
  }
  async mapErrorResponse(t) {
    if (t.status === 413) return new m();
    if (t.status === 422) return new b();
    if (t.status === 503) return new E();
    if (t.status === 409) {
      const n = await this.readDuplicateConflict(t);
      if (n) return new w(n);
    }
    const a = await C(t);
    return new s(a ?? `Request failed: ${t.status} ${t.statusText}`, t.status);
  }
  async readDuplicateConflict(t) {
    try {
      const a = await t.clone().json();
      return a.existingPaperID
        ? {
            existingPaperID: a.existingPaperID,
            existingTitle: a.existingTitle,
            conflictField: a.conflictField,
            latticeURL: a.latticeURL ?? `lattice://paper/${a.existingPaperID}`,
          }
        : null;
    } catch {
      return null;
    }
  }
}
async function C(e) {
  try {
    const t = await e.clone().json();
    if (typeof t.error == "string" && t.error.trim()) return t.error.trim();
  } catch {}
  try {
    return (await e.text()).trim() || void 0;
  } catch {
    return;
  }
}
const S = ["token", "pairingLabel"];
function x(e) {
  return S.filter((t) => Object.prototype.hasOwnProperty.call(e, t));
}
function P(e) {
  const t = { ...e };
  return delete t.token, delete t.pairingLabel, { latticeBaseURL: L, ...t };
}
async function D(e, t) {
  const a = new u(t.baseURL);
  let n = null,
    r;
  if (e.pdfUploadCapable && e.metadata.pdfUrl) {
    const o = await $(e.metadata.pdfUrl);
    (n = o.bytes), (r = o.skippedReason);
  } else
    e.pdfUploadCapable
      ? e.metadata.pdfUrl || (r = "no-pdf-url")
      : (r = "pdf-upload-not-configured");
  try {
    const o = await a.createPaper({
      title: e.metadata.title,
      authors:
        e.metadata.authors.length > 0 ? e.metadata.authors.join("; ") : void 0,
      year: e.metadata.year,
      journal: e.metadata.journal,
      abstract: e.metadata.abstract,
      doi: e.metadata.doi,
      volume: e.metadata.volume,
      issue: e.metadata.issue,
      pages: e.metadata.pages,
      isbn: e.metadata.isbn,
      paperType: e.metadata.paperType,
      collections: e.collectionPath ? [e.collectionPath] : void 0,
      tags: e.tagNames.length > 0 ? e.tagNames : void 0,
      enrich: !0,
      strategy: e.replace ? "replace" : null,
    });
    let i = !1;
    if (n)
      try {
        await a.uploadPDF(o.id, n, !!e.replace), (i = !0);
      } catch (d) {
        d instanceof m
          ? (r = "pdf-too-large")
          : d instanceof E
            ? (r = "pdf-destination-not-configured")
            : (r = `pdf-upload-error:${String(d.message)}`);
      }
    return {
      status: "created",
      paperID: o.id,
      pdfUploaded: i,
      pdfSkippedReason: r,
    };
  } catch (o) {
    return o instanceof w
      ? { status: "duplicate", conflict: o.conflict }
      : o instanceof b
        ? { status: "library-full" }
        : { status: "error", message: String(o.message) };
  }
}
const A = 6e4;
async function $(e) {
  var n;
  const t = new AbortController(),
    a = setTimeout(() => t.abort(), A);
  try {
    const r = await globalThis.fetch(e, {
      credentials: "include",
      signal: t.signal,
    });
    if (!r.ok)
      return { bytes: null, skippedReason: `pdf-fetch-http-${r.status}` };
    const o =
      ((n = r.headers.get("content-type")) == null
        ? void 0
        : n.toLowerCase()) ?? "";
    return o.includes("pdf")
      ? { bytes: await r.arrayBuffer() }
      : {
          bytes: null,
          skippedReason: o ? `pdf-fetch-non-pdf:${o}` : "pdf-fetch-non-pdf",
        };
  } catch (r) {
    if (B(r)) return { bytes: null, skippedReason: "pdf-fetch-timeout" };
    const o = String(r.message);
    return r instanceof TypeError || o.includes("Failed to fetch")
      ? { bytes: null, skippedReason: "browser-blocked-cross-origin" }
      : { bytes: null, skippedReason: `pdf-fetch-error:${o}` };
  } finally {
    clearTimeout(a);
  }
}
function B(e) {
  return (
    ((typeof DOMException < "u" && e instanceof DOMException) ||
      (typeof e == "object" && e !== null)) &&
    e.name === "AbortError"
  );
}
l.runtime.onMessage.addListener((e) => O(e));
async function O(e) {
  switch (e.kind) {
    case "get-storage":
      return p();
    case "set-storage":
      return f(e.patch);
    case "fetch-bootstrap":
      return j();
    case "save-flow":
      return F(e.request);
    case "lookup-metadata":
      return M(e.params);
    default:
      throw new Error(`Unknown background message kind: ${String(e.kind)}`);
  }
}
async function p() {
  const e = await l.storage.local.get(null),
    t = x(e);
  return t.length > 0 && (await l.storage.local.remove(t)), P(e);
}
async function f(e) {
  const t = {},
    a = [];
  for (const [n, r] of Object.entries(e)) {
    if (r === void 0) {
      a.push(n);
      continue;
    }
    t[n] = r;
  }
  return (
    Object.keys(t).length > 0 && (await l.storage.local.set(t)),
    a.length > 0 && (await l.storage.local.remove(a)),
    p()
  );
}
async function j() {
  const { baseURL: e, client: t, status: a, storage: n } = await h();
  let r = [],
    o = [];
  return (
    a.browserExtensionEnabled !== !1 &&
      ([r, o] = await Promise.all([
        g(() => t.getCollections()),
        g(() => t.getTags()),
      ])),
    await f({
      latticeBaseURL: e,
      serverVersion: a.serverVersion || n.serverVersion,
      serverCapabilities: a.capabilities,
    }),
    {
      baseURL: e,
      browserExtensionEnabled: a.browserExtensionEnabled !== !1,
      serverVersion: a.serverVersion || n.serverVersion,
      capabilities: a.capabilities,
      collections: r,
      tags: o,
    }
  );
}
async function F(e) {
  const { baseURL: t } = await h();
  return D(e, { baseURL: t });
}
async function M(e) {
  const { client: t } = await h();
  return t.lookupMetadata(e);
}
async function h() {
  const e = await p(),
    t = await I(e.latticeBaseURL);
  return (
    t.baseURL !== e.latticeBaseURL && (await f({ latticeBaseURL: t.baseURL })),
    { ...t, storage: e }
  );
}
async function I(e) {
  let t = new Error("Couldn't reach Lattice");
  for (const a of _([e, L]))
    try {
      return await V(a);
    } catch (n) {
      t = n;
    }
  throw t;
}
async function V(e) {
  let t = new u(e),
    a = await t.getStatus();
  const n = T(a.baseURL) ?? e;
  return n !== e
    ? ((t = new u(n)),
      (a = await t.getStatus()),
      { baseURL: n, client: t, status: a })
    : { baseURL: e, client: t, status: a };
}
function _(e) {
  const t = new Set(),
    a = [];
  for (const n of e) {
    const r = T(n);
    !r || t.has(r) || (t.add(r), a.push(r));
  }
  return a;
}
function T(e) {
  if (e != null && e.trim())
    try {
      const t = new URL(e);
      return !["http:", "https:"].includes(t.protocol) ||
        !["127.0.0.1", "localhost"].includes(t.hostname)
        ? void 0
        : t.origin;
    } catch {
      return;
    }
}
async function g(e) {
  try {
    return await e();
  } catch (t) {
    if (t instanceof s && [404, 405, 501].includes(t.statusCode ?? 0))
      return [];
    throw t;
  }
}
