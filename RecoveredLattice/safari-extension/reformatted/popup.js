import { b as H } from "./browser-polyfill-DgstG05v.js";
(function () {
  const e = document.createElement("link").relList;
  if (e && e.supports && e.supports("modulepreload")) return;
  for (const r of document.querySelectorAll('link[rel="modulepreload"]')) n(r);
  new MutationObserver((r) => {
    for (const c of r)
      if (c.type === "childList")
        for (const u of c.addedNodes)
          u.tagName === "LINK" && u.rel === "modulepreload" && n(u);
  }).observe(document, { childList: !0, subtree: !0 });
  function i(r) {
    const c = {};
    return (
      r.integrity && (c.integrity = r.integrity),
      r.referrerPolicy && (c.referrerPolicy = r.referrerPolicy),
      r.crossOrigin === "use-credentials"
        ? (c.credentials = "include")
        : r.crossOrigin === "anonymous"
          ? (c.credentials = "omit")
          : (c.credentials = "same-origin"),
      c
    );
  }
  function n(r) {
    if (r.ep) return;
    r.ep = !0;
    const c = i(r);
    fetch(r.href, c);
  }
})();
const Zt = { origins: ["<all_urls>"] };
async function Ue(t) {
  const e = t.permissions;
  if (!e || typeof e.contains != "function" || typeof e.request != "function")
    return !1;
  try {
    return (await e.contains(Zt)) ? !0 : await e.request(Zt);
  } catch {
    return !1;
  }
}
function Fe() {
  var Wt, Gt;
  const t =
      ((Wt = globalThis.location) == null ? void 0 : Wt.href) ??
      ((Gt = globalThis.document) == null ? void 0 : Gt.URL) ??
      "",
    e = globalThis.document,
    i = E(t),
    n = {
      url: t,
      pageKind: xt(),
      titleCandidates: [],
      authorCandidates: [],
      abstractCandidates: [],
      doiCandidates: [],
      journalCandidates: [],
      yearCandidates: [],
      volumeCandidates: [],
      issueCandidates: [],
      pagesCandidates: [],
      arxivIdCandidates: [],
      isbnCandidates: [],
      pdfCandidates: [],
    };
  if (!e) return n;
  S(n, e);
  const r = Be(e),
    c = ke(e);
  if (
    (f(n.titleCandidates, m(e, ["citation_title"]), "citation_title", "high"),
    f(
      n.titleCandidates,
      m(e, ["citation_article_title"]),
      "citation_article_title",
      "high",
    ),
    f(n.titleCandidates, m(e, ["dc.title"]), "dc.title", "high"),
    f(n.titleCandidates, m(e, ["og:title"], "property"), "og:title", "medium"),
    !i)
  ) {
    for (const o of Ct(e, ["citation_author"]))
      f(n.authorCandidates, o, "citation_author", "high");
    for (const o of Ct(e, ["dc.creator"]))
      f(n.authorCandidates, o, "dc.creator", "high");
    for (const o of Ft(m(e, ["author"])))
      f(n.authorCandidates, o, "meta[name=author]", "medium");
  }
  f(
    n.abstractCandidates,
    m(e, ["citation_abstract"]),
    "citation_abstract",
    "high",
  ),
    f(n.abstractCandidates, m(e, ["description"]), "description", "medium"),
    f(
      n.abstractCandidates,
      m(e, ["og:description"], "property"),
      "og:description",
      "medium",
    ),
    i ||
      (f(n.doiCandidates, m(e, ["citation_doi"]), "citation_doi", "high"),
      f(
        n.doiCandidates,
        m(e, ["dc.identifier.doi"]),
        "dc.identifier.doi",
        "high",
      ),
      f(n.doiCandidates, m(e, ["dc.identifier"]), "dc.identifier", "medium")),
    K(n.isbnCandidates, m(e, ["citation_isbn"]), "citation_isbn", "high"),
    K(
      n.isbnCandidates,
      m(e, [
        "dc.identifier.isbn",
        "dc.identifier.isbn13",
        "dc.identifier.isbn10",
      ]),
      "dc.identifier.isbn",
      "high",
    ),
    f(
      n.journalCandidates,
      m(e, ["citation_journal_title"]),
      "citation_journal_title",
      "high",
    ),
    f(n.journalCandidates, m(e, ["dc.source"]), "dc.source", "medium"),
    f(
      n.journalCandidates,
      m(e, ["og:site_name"], "property"),
      "og:site_name",
      "low",
    ),
    f(
      n.yearCandidates,
      m(e, ["citation_publication_date", "citation_date"]),
      "citation_date",
      "high",
    ),
    f(n.yearCandidates, m(e, ["dc.date"]), "dc.date", "medium"),
    f(n.volumeCandidates, m(e, ["citation_volume"]), "citation_volume", "high"),
    f(n.issueCandidates, m(e, ["citation_issue"]), "citation_issue", "high");
  const u = m(e, ["citation_pages"]);
  if (u) f(n.pagesCandidates, u, "citation_pages", "high");
  else {
    const o = m(e, ["citation_firstpage"]),
      a = m(e, ["citation_lastpage"]),
      s = o && a ? `${o}-${a}` : (o ?? a);
    f(n.pagesCandidates, s, "citation_firstpage/lastpage", "high");
  }
  f(
    n.arxivIdCandidates,
    m(e, ["citation_arxiv_id", "citation_technical_report_number"]),
    "citation_arxiv_id",
    "high",
  ),
    F(n.pdfCandidates, m(e, ["citation_pdf_url"]), "citation_pdf_url", "high"),
    f(n.titleCandidates, J(r, ["headline", "name"]), "jsonld.title", "medium");
  for (const o of Re(r)) f(n.authorCandidates, o, "jsonld.author", "medium");
  f(
    n.abstractCandidates,
    J(r, ["description", "abstract"]),
    "jsonld.abstract",
    "medium",
  ),
    f(n.doiCandidates, qe(r), "jsonld.doi", "medium"),
    f(n.journalCandidates, je(r), "jsonld.isPartOf", "medium"),
    f(
      n.yearCandidates,
      J(r, ["datePublished", "dateCreated"]),
      "jsonld.datePublished",
      "medium",
    ),
    f(
      n.volumeCandidates,
      J(r, ["volumeNumber", "volume"]),
      "jsonld.volume",
      "medium",
    ),
    f(
      n.issueCandidates,
      J(r, ["issueNumber", "issue"]),
      "jsonld.issue",
      "medium",
    ),
    f(n.pagesCandidates, Oe(r), "jsonld.pages", "medium"),
    K(n.isbnCandidates, Me(r), "jsonld.isbn", "medium"),
    y(n, e),
    A(n, e),
    L(n, e),
    f(n.titleCandidates, D(e, "main h1"), "main h1", "medium"),
    f(n.titleCandidates, D(e, "h1 .title-text"), "h1 .title-text", "medium"),
    f(n.titleCandidates, D(e, "h1"), "h1", "low"),
    f(n.titleCandidates, Le(e.title), "document.title", "low");
  for (const o of [
    '[data-testid="abstract"]',
    ".abstract.author",
    ".abstract:not(.abstractHighlights)",
    "#preview-section-abstract",
    "section#preview-section-abstract",
    "#abstract",
    "section.abstract",
    ".article__abstract",
    ".c-article-section__content",
  ])
    for (const a of Array.from(e.querySelectorAll(o))) {
      const s = zt(a);
      f(n.abstractCandidates, s, o, "medium");
    }
  f(
    n.journalCandidates,
    D(e, ".publication-title-link"),
    ".publication-title-link",
    "medium",
  ),
    f(
      n.journalCandidates,
      D(e, '[data-testid="journal-link"]'),
      '[data-testid="journal-link"]',
      "medium",
    );
  const p = we($e(e, c));
  f(n.doiCandidates, p, "body doi label", "low");
  for (const o of Array.from(e.querySelectorAll("a[href]"))) {
    const a = j(o.getAttribute("href"), t);
    if (!a) continue;
    const s = x(o.textContent) ?? "";
    if (
      (Ht(o, c) &&
        (f(n.doiCandidates, q(o.href), "doi link href", "medium"),
        f(n.doiCandidates, q(s), "doi link text", "low")),
      Pt(a, s))
    ) {
      const l =
        /\.pdf(?:$|[?#])/i.test(a) || /(?:^|\b)pdf(?:\b|$)/i.test(s)
          ? "medium"
          : "low";
      F(n.pdfCandidates, a, "pdf link", l);
    }
  }
  return (
    (n.pageKind !== "html" || Pt(t, "")) &&
      F(n.pdfCandidates, t, "current-url", "medium"),
    (n.titleCandidates = O(n.titleCandidates)),
    (n.authorCandidates = O(n.authorCandidates)),
    (n.abstractCandidates = O(n.abstractCandidates)),
    (n.doiCandidates = O(n.doiCandidates)),
    (n.journalCandidates = O(n.journalCandidates)),
    (n.yearCandidates = O(n.yearCandidates)),
    (n.volumeCandidates = O(n.volumeCandidates)),
    (n.issueCandidates = O(n.issueCandidates)),
    (n.pagesCandidates = O(n.pagesCandidates)),
    (n.arxivIdCandidates = O(n.arxivIdCandidates)),
    (n.isbnCandidates = O(n.isbnCandidates)),
    (n.pdfCandidates = De(n.pdfCandidates)),
    n
  );
  function y(o, a) {
    var et, At, lt;
    const s = Q(t);
    if (
      !s ||
      !/^scholar\.google\./i.test(s.hostname) ||
      s.pathname !== "/citations" ||
      s.searchParams.get("view_op") !== "view_citation"
    )
      return;
    const l = D(a, ".gsc_oci_title_link");
    f(o.titleCandidates, l, "google-scholar.title", "high");
    const d = new Map();
    for (const St of Array.from(a.querySelectorAll("#gsc_oci_table .gs_scl"))) {
      const Kt =
          (et = D(St, ".gsc_oci_field")) == null ? void 0 : et.toLowerCase(),
        Yt = Ut(St.querySelector(".gsc_oci_value"));
      Kt && Yt && d.set(Kt, Yt);
    }
    for (const St of Ft(d.get("authors")))
      f(o.authorCandidates, St, "google-scholar.authors", "high");
    f(
      o.yearCandidates,
      d.get("publication date") ?? d.get("date"),
      "google-scholar.date",
      "high",
    ),
      f(
        o.journalCandidates,
        d.get("journal") ??
          d.get("conference") ??
          d.get("book") ??
          d.get("source"),
        "google-scholar.journal",
        "high",
      ),
      f(o.volumeCandidates, d.get("volume"), "google-scholar.volume", "high"),
      f(o.issueCandidates, d.get("issue"), "google-scholar.issue", "high"),
      f(
        o.pagesCandidates,
        d.get("pages") ?? d.get("page"),
        "google-scholar.pages",
        "high",
      ),
      K(o.isbnCandidates, d.get("isbn"), "google-scholar.isbn", "high"),
      f(
        o.abstractCandidates,
        d.get("description"),
        "google-scholar.description",
        "high",
      );
    const g = j(
        (At = a.querySelector(".gsc_oci_title_link")) == null
          ? void 0
          : At.getAttribute("href"),
        t,
      ),
      b = j(
        (lt = a.querySelector("#gsc_oci_title_gg a")) == null
          ? void 0
          : lt.getAttribute("href"),
        t,
      ),
      B = D(a, "#gsc_oci_title_gg .gsc_vcd_title_ggt") ?? "";
    f(o.doiCandidates, q(g), "google-scholar.doi", "high"),
      f(o.doiCandidates, q(b), "google-scholar.attachment-doi", "medium"),
      b &&
        (/\bpdf\b/i.test(B) || /\.pdf(?:$|[?#])/i.test(b)) &&
        F(o.pdfCandidates, b, "google-scholar.pdf", "high");
  }
  function A(o, a) {
    var l;
    const s = Q(t);
    if (
      !(
        !s ||
        !/(^|\.)science-?direct\.com$/i.test(s.hostname) ||
        !/^\/science\/article(?:\/abs)?\//i.test(s.pathname)
      )
    ) {
      f(
        o.titleCandidates,
        D(a, "h1 .title-text"),
        "sciencedirect.title",
        "high",
      );
      for (const d of [
        D(a, ".publication-title-link"),
        D(a, '[data-testid="journal-link"]'),
      ])
        f(o.journalCandidates, d, "sciencedirect.journal", "high");
      for (const d of [
        ".abstract.author",
        ".abstract:not(.abstractHighlights)",
        "#preview-section-abstract",
        "section#preview-section-abstract",
        '[data-testid="abstract"]',
      ])
        for (const g of Array.from(a.querySelectorAll(d)))
          f(o.abstractCandidates, zt(g), `sciencedirect:${d}`, "high");
      for (const d of [
        "#pdfLink",
        ".pdf-download-btn-link",
        'a[href*="/pdfft"]',
      ]) {
        const g = j(
          (l = a.querySelector(d)) == null ? void 0 : l.getAttribute("href"),
          t,
        );
        F(o.pdfCandidates, g, `sciencedirect:${d}`, "high");
      }
    }
  }
  function L(o, a) {
    const s = Q(t);
    if (
      !s ||
      !/(^|\.)inspirehep\.net$/i.test(s.hostname) ||
      !/^\/literature\/\d+/i.test(s.pathname)
    )
      return;
    const l = a.querySelector("main") ?? a.body;
    if (!l) return;
    f(o.titleCandidates, D(l, "h1"), "inspirehep.h1", "high");
    const d = l.querySelector("h1"),
      g = Ee(l, d),
      b = Pe(l, D(l, "h1") ?? "") ?? l,
      B = Ne(b, g);
    for (const et of gt(a, b, g))
      f(o.authorCandidates, et, "inspirehep.author", "high");
    f(o.abstractCandidates, mt(l), "inspirehep.abstract", "high"),
      f(o.doiCandidates, bt(a, b, g, B), "inspirehep.doi", "high"),
      F(o.pdfCandidates, yt(a, b, g), "inspirehep.pdf", "high"),
      f(o.arxivIdCandidates, vt(a, B), "inspirehep.arxiv", "high");
  }
  function S(o, a) {
    if (!E(t)) return;
    const s = ht(
      wt(
        m(a, ["citation_title", "citation_article_title", "dc.title"]),
        D(a, "h1"),
        m(a, ["og:title"], "property"),
        a.title,
      ),
    );
    f(o.titleCandidates, s, "acm.title", "high");
    for (const l of I(a)) f(o.authorCandidates, l, "acm.author", "high");
    f(o.doiCandidates, N(a), "acm.doi", "high"),
      f(
        o.journalCandidates,
        wt(
          m(a, ["citation_journal_title"]),
          D(a, "span.epub-section__title"),
          m(a, ["citation_conference_title"]),
          m(a, ["dc.source"]),
          m(a, ["citation_book_title"]),
        ),
        "acm.source",
        "high",
      ),
      f(o.abstractCandidates, V(a), "acm.abstract", "high"),
      F(o.pdfCandidates, w(a), "acm.pdf", "high");
  }
  function E(o) {
    const a = Q(o);
    return !a ||
      !/(^|\.)dl\.acm\.org$/i.test(a.hostname) ||
      a.pathname.includes("/doi/proceedings")
      ? !1
      : a.pathname.includes("/doi/") || a.pathname.includes("/do/");
  }
  function I(o) {
    const a = Ct(o, ["citation_author"]);
    return a.length > 0
      ? a
      : st(
          Array.from(
            o.querySelectorAll(
              "div.citation span.loa__author-name, span.loa__author-name",
            ),
          )
            .map((s) => x(s.textContent))
            .filter((s) => !!s),
        );
  }
  function N(o) {
    var a;
    return wt(
      M(t),
      q(m(o, ["citation_doi", "dc.identifier.doi"])),
      q(
        j(
          (a = o.querySelector('a[href*="doi.org/"]')) == null
            ? void 0
            : a.getAttribute("href"),
          t,
        ),
      ),
    );
  }
  function M(o) {
    var d;
    const a = Q(o);
    if (!a) return;
    let s = a.pathname;
    try {
      s = decodeURIComponent(a.pathname);
    } catch {
      s = a.pathname;
    }
    const l =
      (d = s.match(/\/doi\/(?:[^/]+\/)?(10\.\d{4,9}\/[^\s"'<>?#]+)/i)) == null
        ? void 0
        : d[1];
    return q(l);
  }
  function V(o) {
    let a;
    for (const s of ["div.article__abstract", "div.abstractSection"])
      for (const l of Array.from(o.querySelectorAll(s))) {
        const d = Array.from(l.querySelectorAll("p"))
            .map((B) => x(B.textContent))
            .filter((B) => !!B),
          g = x(d.length > 0 ? d.join(" ") : l.textContent);
        if (!g || /^no abstract available\.?$/i.test(g)) continue;
        const b = g.replace(/^abstract\s*:?\s*/i, "").trim();
        b && (!a || b.length > a.length) && (a = b);
      }
    return a;
  }
  function w(o) {
    const a = Q(t);
    if (!a || !/(^|\.)dl\.acm\.org$/i.test(a.hostname)) return;
    const s = o.querySelector("#downloadPdfUrl"),
      l = j(
        (s == null ? void 0 : s.getAttribute("href")) ??
          (s == null ? void 0 : s.getAttribute("value")) ??
          m(o, ["citation_pdf_url"]),
        t,
      );
    if (l) return l;
    const d = N(o);
    if (d && (a.pathname.includes("/doi/pdf/") || s))
      return `${a.origin}/doi/pdf/${d}?download=true`;
  }
  function ht(o) {
    let a = x(o);
    if (a) {
      for (const s of [
        /\s+\|\s+ACM Digital Library$/i,
        /\s+\|\s+The ACM Digital Library$/i,
        /\s+\|\s+ACM Books$/i,
      ])
        a = a.replace(s, "").trim();
      return a || void 0;
    }
  }
  function gt(o, a, s) {
    const l = Ct(o, ["citation_author"]);
    if (l.length > 0) return l;
    const d = [];
    for (const g of Et(a, s)) {
      const b = j(g.getAttribute("href"), t),
        B = x(g.textContent);
      b && B && /\/authors?\//i.test(b) && d.push(B);
    }
    return st(d);
  }
  function mt(o) {
    let a;
    for (const s of Array.from(o.querySelectorAll("section, article, div"))) {
      const l = x(s.textContent);
      if (!l || !/^Abstract\b/i.test(l)) continue;
      const d = l
        .replace(/^Abstract\s*:?\s*(?:\([^)]*\))?\s*/i, "")
        .replace(/\s+Note:\s+.*$/i, "")
        .replace(/\s+References\s*\(\d+\).*$/i, "")
        .replace(/\s+Figures\s*\(\d+\).*$/i, "")
        .trim();
      d.length >= 80 && (!a || d.length > a.length) && (a = d);
    }
    return a;
  }
  function bt(o, a, s, l) {
    var b;
    const d = m(o, ["citation_doi", "dc.identifier.doi"]);
    if (d) return q(d);
    const g =
      (b =
        l == null
          ? void 0
          : l.match(/\bDOI\s*:?\s*(10\.\d{4,9}\/[^\s"'<>]+)/i)) == null
        ? void 0
        : b[1];
    if (g) return q(g);
    for (const B of Et(a, s)) {
      const et = j(B.getAttribute("href"), t),
        At = x(B.textContent),
        lt = q(At) ?? q(et);
      if (lt) return lt;
    }
  }
  function yt(o, a, s) {
    const l = j(m(o, ["citation_pdf_url"]), t);
    if (l) return l;
    for (const d of Et(a, s)) {
      const g = j(d.getAttribute("href"), t),
        b = x(d.textContent) ?? "";
      if (
        g &&
        (/^pdf$/i.test(b) ||
          /\/pdf(?:[/?#]|$)/i.test(g) ||
          /[?&](?:download|format)=pdf\b/i.test(g))
      )
        return g;
    }
  }
  function vt(o, a) {
    const s = [
      m(o, ["citation_arxiv_id", "citation_technical_report_number"]),
      a,
    ];
    for (const l of s) {
      const d = x(l);
      if (!d) continue;
      const g = d.match(
        /\b(?:e-Print|arXiv)\s*:?\s*([a-z.-]+\/\d{7}(?:v\d+)?|\d{4}\.\d{4,5}(?:v\d+)?)/i,
      );
      if (g != null && g[1]) return g[1];
    }
  }
  function xt() {
    return ((e == null ? void 0 : e.contentType) ?? "")
      .toLowerCase()
      .includes("pdf")
      ? "pdf-viewer"
      : Pt(t, "")
        ? "pdf-url"
        : (e != null &&
              e.querySelector(
                'embed[type="application/pdf"], object[type="application/pdf"]',
              )) ||
            (e != null && e.querySelector('iframe[src*=".pdf"]'))
          ? "pdf-viewer"
          : "html";
  }
  function f(o, a, s, l) {
    const d = x(a);
    d && o.push({ value: d, source: s, confidence: l });
  }
  function K(o, a, s, l) {
    const d = _t(a);
    d && o.push({ value: d, source: s, confidence: l });
  }
  function F(o, a, s, l) {
    const d = j(a, t);
    d && o.push({ url: d, source: s, confidence: l });
  }
  function m(o, a, s = "name") {
    for (const l of a) {
      const d = `meta[${s}="${Ot(l)}" i]`,
        g = o.querySelector(d),
        b = x(g == null ? void 0 : g.getAttribute("content"));
      if (b) return b;
    }
  }
  function Ct(o, a) {
    const s = [];
    for (const l of a) {
      const d = `meta[name="${Ot(l)}" i]`;
      for (const g of Array.from(o.querySelectorAll(d))) {
        const b = x(g.getAttribute("content"));
        b && s.push(b);
      }
    }
    return st(s);
  }
  function Ot(o) {
    return o.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
  }
  function Q(o) {
    try {
      return new URL(o);
    } catch {
      return null;
    }
  }
  function j(o, a) {
    const s = x(o);
    if (s)
      try {
        return new URL(s, a).toString();
      } catch {
        return;
      }
  }
  function x(o) {
    return (o == null ? void 0 : o.replace(/\s+/g, " ").trim()) || void 0;
  }
  function wt(...o) {
    var a;
    return (a = o.find((s) => !!(s != null && s.trim()))) == null
      ? void 0
      : a.trim();
  }
  function D(o, a) {
    var s;
    return x((s = o.querySelector(a)) == null ? void 0 : s.textContent);
  }
  function Ut(o) {
    if (!o) return;
    const a = [];
    return kt(o, a), x(a.join(" "));
  }
  function kt(o, a) {
    if (o.nodeType === Node.TEXT_NODE) {
      const l = x(o.textContent);
      l && a.push(l);
      return;
    }
    if (o.nodeType !== Node.ELEMENT_NODE) return;
    const s = o;
    if (!["SCRIPT", "STYLE", "NOSCRIPT"].includes(s.tagName))
      for (const l of Array.from(o.childNodes)) kt(l, a);
  }
  function st(o) {
    const a = new Set(),
      s = [];
    for (const l of o) {
      const d = l.toLowerCase();
      a.has(d) || (a.add(d), s.push(l));
    }
    return s;
  }
  function q(o) {
    var d;
    const a = x(o);
    if (!a) return;
    const l = a
      .replace(/^doi:\s*/i, "")
      .replace(/^https?:\/\/(?:dx\.)?doi\.org\//i, "")
      .match(/10\.\d{4,9}\/[^\s"'<>]+/i);
    return (d = l == null ? void 0 : l[0]) == null
      ? void 0
      : d.replace(/[).,;]+$/g, "");
  }
  function _t(o) {
    const a = $t(o);
    if (a) return a;
    const s = x(o);
    if (!s) return;
    const l = s.matchAll(
      /ISBN(?:-1[03])?\s*:?\s*((?:97[89][-\s]?)?(?:\d[-\s]?){9,12}[\dXx])/gi,
    );
    for (const g of l) {
      const b = $t(g[1]);
      if (b) return b;
    }
    const d = s.matchAll(/\b(97[89](?:[-\s]?\d){10})\b/g);
    for (const g of d) {
      const b = $t(g[1]);
      if (b) return b;
    }
  }
  function $t(o) {
    const a = x(o);
    if (!a || !/^(?:ISBN(?:-1[03])?\s*:?\s*)?[\dXx][\dXx\s-]*$/i.test(a))
      return;
    const s = a
      .replace(/^(?:ISBN(?:-1[03])?\s*:?\s*)/i, "")
      .toUpperCase()
      .replace(/[\s-]/g, "");
    if (/^(?:\d{9}[\dX]|\d{13})$/.test(s))
      return s.length === 10 ? (Te(s) ? s : void 0) : Se(s) ? s : void 0;
  }
  function Se(o) {
    if (o.length !== 13) return !1;
    let a = 0;
    for (let s = 0; s < o.length; s += 1) {
      const l = Number.parseInt(o[s] ?? "", 10);
      if (!Number.isFinite(l)) return !1;
      a += s % 2 === 0 ? l : l * 3;
    }
    return a % 10 === 0;
  }
  function Te(o) {
    if (o.length !== 10) return !1;
    let a = 0;
    for (let s = 0; s < o.length; s += 1) {
      const l = o[s];
      if (!l) return !1;
      let d;
      if (l === "X") {
        if (s !== o.length - 1) return !1;
        d = 10;
      } else if (((d = Number.parseInt(l, 10)), !Number.isFinite(d))) return !1;
      a += d * (10 - s);
    }
    return a % 11 === 0;
  }
  function Ft(o) {
    return o
      ? st(
          o
            .split(/\s*;\s*|\s*,\s*/g)
            .map((a) => a.trim())
            .filter(Boolean),
        )
      : [];
  }
  function Le(o) {
    const a = x(o);
    return a
      ? (a
          .split(/\s[|\-–:]\s/)
          .map((l) => l.trim())
          .filter(Boolean)
          .sort((l, d) => d.length - l.length)[0] ?? a)
      : void 0;
  }
  function zt(o) {
    const a = Array.from(o.querySelectorAll("p"))
        .filter((d) => !d.closest(".abstractHighlights"))
        .map((d) => x(d.textContent))
        .filter((d) => !!d),
      s = a.length > 0 ? a.join(" ") : x(o.textContent);
    if (!s) return;
    const l = s
      .replace(/^(abstract|summary)\s*[:-]?\s*/i, "")
      .replace(/\s*show more\s*$/i, "")
      .trim();
    return l.length >= 80 ? l : void 0;
  }
  function Pt(o, a) {
    return (
      /\.pdf(?:$|[?#])/i.test(o) ||
      /\/pdf(?:[/?#]|$)/i.test(o) ||
      /\/pdfft(?:[/?#]|$)/i.test(o) ||
      /[?&](?:download|format)=pdf\b/i.test(o) ||
      /(?:^|\b)(pdf|download pdf|full text pdf|view pdf)(?:\b|$)/i.test(a)
    );
  }
  function we(o) {
    const a = o.match(
      /(?:doi\s*:?\s*|https?:\/\/(?:dx\.)?doi\.org\/)\s*(10\.\d{4,9}\/[^\s"'<>]+)/i,
    );
    return q(a == null ? void 0 : a[1]);
  }
  function ke(o) {
    const a = o.body;
    if (!a) return null;
    const s = o.createTreeWalker(a, NodeFilter.SHOW_ELEMENT);
    let l = s.currentNode;
    for (; l; ) {
      const d = x(l.textContent);
      if (d && /^references(?:\s*\(\d+\))?$/i.test(d)) return l;
      l = s.nextNode();
    }
    return null;
  }
  function $e(o, a) {
    var g, b;
    const s = ((g = o.documentElement) == null ? void 0 : g.textContent) ?? "";
    if (!a) return s;
    const l = (b = a.textContent) == null ? void 0 : b.trim();
    if (!l) return s;
    const d = s.indexOf(l);
    return d < 0 ? s : s.slice(0, d);
  }
  function Ht(o, a) {
    return a
      ? !!(o.compareDocumentPosition(a) & Node.DOCUMENT_POSITION_FOLLOWING)
      : !0;
  }
  function Et(o, a) {
    return Array.from(o.querySelectorAll("a[href]")).filter((s) => Ht(s, a));
  }
  function Pe(o, a) {
    const s = o.querySelector("h1");
    if (!s) return null;
    let l = s.parentElement;
    for (let d = s.parentElement; d && o.contains(d); d = d.parentElement) {
      const g = x(d.textContent);
      if (!g || !g.includes(a)) continue;
      if (/Abstract:/i.test(g) || /References\s*\(\d+\)/i.test(g)) break;
      if (
        !!d.querySelector(
          'a[href*="/authors/"], a[href*="/pdf"], a[href*="arxiv.org/abs/"]',
        ) ||
        /\be-Print\s*:|\bView in\s*:|reference search|claim\b|\bcite\b/i.test(g)
      )
        return d;
      l = d;
    }
    return l;
  }
  function Ee(o, a) {
    if (!a) return null;
    for (const s of Array.from(
      o.querySelectorAll("section, article, div, nav, button"),
    )) {
      if (s === a || s.contains(a) || !Ie(a, s)) continue;
      const l = x(s.textContent);
      if (
        l &&
        (/^Abstract\b/i.test(l) ||
          /^References\s*\(\d+\)/i.test(l) ||
          /^Figures\s*\(\d+\)/i.test(l))
      )
        return s;
    }
    return null;
  }
  function Ie(o, a) {
    return !!(o.compareDocumentPosition(a) & Node.DOCUMENT_POSITION_FOLLOWING);
  }
  function Ne(o, a) {
    if (!a) return Ut(o instanceof Element ? o : null);
    const s = [];
    for (const l of Array.from(o.childNodes)) {
      if (l === a) break;
      kt(l, s);
    }
    return x(s.join(" "));
  }
  function O(o) {
    const a = new Set(),
      s = [];
    for (const l of o) {
      const d = `${l.value.toLowerCase()}::${l.source}`;
      a.has(d) || (a.add(d), s.push(l));
    }
    return s;
  }
  function De(o) {
    const a = new Set(),
      s = [];
    for (const l of o) {
      const d = l.url.toLowerCase();
      a.has(d) || (a.add(d), s.push(l));
    }
    return s;
  }
  function Be(o) {
    var s;
    const a = [];
    for (const l of Array.from(
      o.querySelectorAll('script[type="application/ld+json"]'),
    )) {
      const d = (s = l.textContent) == null ? void 0 : s.trim();
      if (d)
        try {
          It(JSON.parse(d), a);
        } catch {
          continue;
        }
    }
    return a;
  }
  function It(o, a) {
    if (o) {
      if (Array.isArray(o)) {
        for (const s of o) It(s, a);
        return;
      }
      if (ct(o) && (a.push(o), Array.isArray(o["@graph"])))
        for (const s of o["@graph"]) It(s, a);
    }
  }
  function J(o, a) {
    for (const s of o)
      for (const l of a) {
        const d = s[l];
        if (typeof d == "string" && d.trim()) return d.trim();
      }
  }
  function Re(o) {
    for (const a of o) {
      const s = Vt(a.author ?? a.creator);
      if (s.length > 0) return s;
    }
    return [];
  }
  function Vt(o) {
    if (Array.isArray(o)) return st(o.flatMap((d) => Vt(d)));
    if (typeof o == "string") return [o.trim()];
    if (!ct(o)) return [];
    if (typeof o.name == "string" && o.name.trim()) return [o.name.trim()];
    const a = typeof o.givenName == "string" ? o.givenName.trim() : "",
      s = typeof o.familyName == "string" ? o.familyName.trim() : "",
      l = [a, s].filter(Boolean).join(" ").trim();
    return l ? [l] : [];
  }
  function qe(o) {
    for (const a of o) {
      const s = tt(a, ["doi", "identifier"]) ?? Jt(a.identifier),
        l = q(s);
      if (l) return l;
    }
  }
  function Me(o) {
    for (const a of o) {
      const s = tt(a, ["isbn"]) ?? Xt(a.identifier),
        l = _t(s);
      if (l) return l;
    }
  }
  function Jt(o) {
    var l;
    if (!o) return;
    if (typeof o == "string") return o;
    if (Array.isArray(o)) {
      for (const d of o) {
        const g = Jt(d);
        if (g) return g;
      }
      return;
    }
    if (!ct(o)) return;
    const a =
        (l = tt(o, ["propertyID", "name"])) == null ? void 0 : l.toLowerCase(),
      s = tt(o, ["value", "@value"]);
    return a != null && a.includes("doi") && s, s;
  }
  function Xt(o) {
    var l;
    if (!o) return;
    if (typeof o == "string") return _t(o);
    if (Array.isArray(o)) {
      for (const d of o) {
        const g = Xt(d);
        if (g) return g;
      }
      return;
    }
    if (!ct(o)) return;
    const a =
        (l = tt(o, ["propertyID", "name"])) == null ? void 0 : l.toLowerCase(),
      s = tt(o, ["value", "@value"]);
    if (a != null && a.includes("isbn") && s) return _t(s);
  }
  function je(o) {
    for (const a of o) {
      const s = a.isPartOf;
      if (ct(s) && typeof s.name == "string") return s.name.trim();
    }
  }
  function Oe(o) {
    const a = J(o, ["pagination"]);
    if (a) return a;
    const s = J(o, ["pageStart"]),
      l = J(o, ["pageEnd"]);
    return s && l ? `${s}-${l}` : (s ?? l ?? void 0);
  }
  function tt(o, a) {
    for (const s of a) {
      const l = o[s];
      if (typeof l == "string" && l.trim()) return l.trim();
    }
  }
  function ct(o) {
    return typeof o == "object" && o !== null;
  }
}
async function Qt(t) {
  var n;
  const e = new AbortController(),
    i = setTimeout(() => e.abort(), 15e3);
  try {
    const r = await globalThis.fetch(t, {
      credentials: "include",
      redirect: "follow",
      signal: e.signal,
      headers: {
        Accept:
          "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
      },
    });
    if (!r.ok) return null;
    const c =
      ((n = r.headers.get("content-type")) == null
        ? void 0
        : n.toLowerCase()) ?? "";
    return c && !c.includes("html") && !c.includes("xml")
      ? null
      : { url: r.url || t, html: await r.text(), contentType: c || void 0 };
  } catch {
    return null;
  } finally {
    clearTimeout(i);
  }
}
var ne;
const te = ((ne = globalThis.navigator) == null ? void 0 : ne.userAgent) ?? "",
  ie = /Version\/\d+.*Safari/.test(te) && !/Chrome|Chromium|Edg\//.test(te),
  ze = ie ? 280 : 300,
  He = /10\.\d{4,9}\/[^\s"'<>]+/i,
  Ve = /\/doi\/(?:abs\/|full\/|pdf\/)?(10\.\d{4,9}\/[^\s"'<>?#]+)/i,
  Je = /^\/works\/(10\.\d{4,9}\/.+)$/i,
  Xe = /^(?:\d{9}[\dX]|\d{13})$/,
  We = /^(?:ISBN(?:-1[03])?\s*:?\s*)?[\dXx][\dXx\s-]*$/i,
  Ge = /ISBN(?:-1[03])?\s*:?\s*((?:97[89][-\s]?)?(?:\d[-\s]?){9,12}[\dXx])/gi,
  Ke = /\b(97[89](?:[-\s]?\d){10})\b/g;
function R(t) {
  try {
    return new URL(t);
  } catch {
    return null;
  }
}
function _(t) {
  return (t == null ? void 0 : t.replace(/\s+/g, " ").trim()) || void 0;
}
function X(t, e) {
  var i;
  return _((i = t.querySelector(e)) == null ? void 0 : i.textContent);
}
function Bt(t, e) {
  return qt(t.querySelector(e));
}
function qt(t) {
  if (!t) return;
  const e = [];
  return oe(t, e), _(e.join(" "));
}
function rt(t, e, i) {
  var r;
  const n = (r = t.querySelector(e)) == null ? void 0 : r.getAttribute("href");
  if (n) return U(n, i);
}
function h(t, e, i = "name") {
  var n;
  for (const r of e) {
    const c = `meta[${i}="${ae(r)}" i]`,
      u = (n = t.querySelector(c)) == null ? void 0 : n.getAttribute("content"),
      p = _(u);
    if (p) return p;
  }
}
function ft(t, e) {
  const i = [];
  for (const n of e) {
    const r = `meta[name="${ae(n)}" i]`;
    for (const c of Array.from(t.querySelectorAll(r))) {
      const u = _(c.getAttribute("content"));
      u && i.push(u);
    }
  }
  return Z(i);
}
function U(t, e) {
  if (t)
    try {
      return new URL(t, e).toString();
    } catch {
      return;
    }
}
function P(t) {
  const e = t == null ? void 0 : t.match(He);
  if (e) return e[0].replace(/[).,;]+$/g, "");
}
function re(t) {
  var r, c;
  const e = t ? R(t) : null;
  if (!e) return;
  for (const [u, p] of e.searchParams.entries())
    if (u.toLowerCase() === "doi") {
      const y = P(p);
      if (y) return y;
    }
  const i = Ye(e.pathname);
  if (/^(?:dx\.)?doi\.org$/i.test(e.hostname)) return P(i.replace(/^\/+/, ""));
  const n = (r = i.match(Ve)) == null ? void 0 : r[1];
  if (n) return P(n);
  if (/^api\.crossref\.org$/i.test(e.hostname)) {
    const u = (c = i.match(Je)) == null ? void 0 : c[1];
    if (u) return P(u);
  }
}
function Nt(t) {
  const e = _(t);
  if (!e || !We.test(e)) return;
  const i = e
    .replace(/^(?:ISBN(?:-1[03])?\s*:?\s*)/i, "")
    .toUpperCase()
    .replace(/[\s-]/g, "");
  if (Xe.test(i)) {
    if (i.length === 10) return Qe(i) ? i : void 0;
    if (i.length === 13) return Ze(i) ? i : void 0;
  }
}
function G(t) {
  const e = Nt(t);
  if (e) return e;
  const i = _(t);
  if (i) {
    for (const n of i.matchAll(Ge)) {
      const r = Nt(n[1]);
      if (r) return r;
    }
    for (const n of i.matchAll(Ke)) {
      const r = Nt(n[1]);
      if (r) return r;
    }
  }
}
function at(t) {
  const e = t == null ? void 0 : t.match(/\b(19|20)\d{2}\b/);
  if (!e) return;
  const i = Number.parseInt(e[0], 10);
  return Number.isFinite(i) ? i : void 0;
}
function v(...t) {
  var e;
  return (e = t.find((i) => !!(i != null && i.trim()))) == null
    ? void 0
    : e.trim();
}
function Z(t) {
  const e = new Set(),
    i = [];
  for (const n of t) {
    const r = _(n);
    if (!r) continue;
    const c = r.toLowerCase();
    e.has(c) || (e.add(c), i.push(r));
  }
  return i;
}
function oe(t, e) {
  var r, c;
  if (t.nodeType === t.TEXT_NODE) {
    const u = (r = t.textContent) == null ? void 0 : r.trim();
    u && e.push(u);
    return;
  }
  if (t.nodeType !== t.ELEMENT_NODE) return;
  const i = t,
    n = e.length;
  for (const u of Array.from(i.childNodes)) oe(u, e);
  if (e.length === n) {
    const u = (c = i.getAttribute("aria-label")) == null ? void 0 : c.trim();
    u && e.push(u);
  }
}
function Ye(t) {
  try {
    return decodeURIComponent(t);
  } catch {
    return t;
  }
}
function Ze(t) {
  if (t.length !== 13) return !1;
  let e = 0;
  for (let i = 0; i < t.length; i += 1) {
    const n = Number.parseInt(t[i] ?? "", 10);
    if (!Number.isFinite(n)) return !1;
    e += i % 2 === 0 ? n : n * 3;
  }
  return e % 10 === 0;
}
function Qe(t) {
  if (t.length !== 10) return !1;
  let e = 0;
  for (let i = 0; i < t.length; i += 1) {
    const n = t[i];
    if (!n) return !1;
    let r;
    if (n === "X") {
      if (i !== t.length - 1) return !1;
      r = 10;
    } else if (((r = Number.parseInt(n, 10)), !Number.isFinite(r))) return !1;
    e += r * (10 - i);
  }
  return e % 11 === 0;
}
function ae(t) {
  return t.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}
function tn(t) {
  return en(t) ?? nn(t) ?? rn(t) ?? on(t) ?? an(t) ?? sn(t);
}
function en(t) {
  const e = R(t);
  if (!e || !/(^|\.)arxiv\.org$/i.test(e.hostname)) return null;
  const i = e.pathname.match(/^\/pdf\/(.+?)(?:\.pdf)?$/i);
  return i != null && i[1] ? `https://arxiv.org/abs/${i[1]}` : null;
}
function nn(t) {
  const e = R(t);
  if (!e || !/(^|\.)science-?direct\.com$/i.test(e.hostname)) return null;
  const i = e.pathname.match(/^\/science\/article\/pii\/([^/]+)\/pdfft$/i);
  if (i != null && i[1]) return `${e.origin}/science/article/abs/pii/${i[1]}`;
  const n = e.pathname.match(/^\/science\/article\/abs\/pii\/([^/]+)\/pdf$/i);
  return n != null && n[1]
    ? `${e.origin}/science/article/abs/pii/${n[1]}`
    : null;
}
function rn(t) {
  const e = R(t);
  if (
    !e ||
    !/(^|\.)openreview\.net$/i.test(e.hostname) ||
    e.pathname !== "/pdf"
  )
    return null;
  const i = e.searchParams.get("id");
  return i ? `${e.origin}/forum?id=${encodeURIComponent(i)}` : null;
}
function on(t) {
  const e = R(t);
  return !e ||
    !/(^|\.)proceedings\.mlr\.press$/i.test(e.hostname) ||
    !/\.pdf$/i.test(e.pathname)
    ? null
    : `${e.origin}${e.pathname.replace(/\.pdf$/i, ".html")}`;
}
function an(t) {
  const e = R(t);
  if (
    !e ||
    !/(^|\.)proceedings\.neurips\.cc$/i.test(e.hostname) ||
    !/\/paper_files\/paper\/\d{4}\//i.test(e.pathname) ||
    !/\.pdf$/i.test(e.pathname)
  )
    return null;
  const i = e.pathname
    .replace(/-Paper-/i, "-Abstract-")
    .replace(/\.pdf$/i, ".html");
  return `${e.origin}${i}`;
}
function sn(t) {
  const e = R(t);
  if (!e || !/(^|\.)link\.springer\.com$/i.test(e.hostname)) return null;
  const i = e.pathname.match(/^\/content\/pdf\/(.+)\.pdf$/i);
  return i != null && i[1] ? `${e.origin}/article/${i[1]}` : null;
}
const se = /(^|\.)dl\.acm\.org$/i,
  cn = ["div.article__abstract", "div.abstractSection"];
function ln(t, e) {
  if (!dn(e)) return null;
  const i = yn(
    v(
      h(t, ["citation_title", "citation_article_title", "dc.title"]),
      X(t, "h1"),
      h(t, ["og:title"], "property"),
      t.title,
    ),
  );
  if (!i) return null;
  const n = un(t),
    r = at(
      v(
        h(t, ["citation_publication_date", "citation_date", "dc.date"]),
        t.title,
      ),
    ),
    c = v(
      h(t, ["citation_journal_title"]),
      X(t, "span.epub-section__title"),
      h(t, ["citation_conference_title"]),
      h(t, ["dc.source"]),
      h(t, ["citation_book_title"]),
    ),
    u = fn(t),
    p = pn(t, e),
    y = h(t, ["citation_volume"]),
    A = h(t, ["citation_issue"]),
    L = gn(t),
    S = v(
      G(h(t, ["citation_isbn"])),
      G(
        h(t, [
          "dc.identifier.isbn",
          "dc.identifier.isbn13",
          "dc.identifier.isbn10",
        ]),
      ),
    ),
    E = mn(t, e, S),
    I = bn(t, e, p);
  return !(p || n.length > 0 || r || c || u || y || A || L || S || E || I)
    ? null
    : {
        title: i,
        authors: n,
        year: r,
        journal: c,
        abstract: u,
        doi: p,
        volume: y,
        issue: A,
        pages: L,
        isbn: S,
        paperType: E,
        pdfUrl: I,
        sourceUrl: e,
      };
}
function dn(t) {
  const e = R(t);
  return !e || !se.test(e.hostname) || e.pathname.includes("/doi/proceedings")
    ? !1
    : e.pathname.includes("/doi/") || e.pathname.includes("/do/");
}
function un(t) {
  const e = ft(t, ["citation_author"]);
  if (e.length > 0) return e;
  const i = Array.from(
    t.querySelectorAll(
      "div.citation span.loa__author-name, span.loa__author-name",
    ),
  )
    .map((n) => _(n.textContent))
    .filter((n) => !!n);
  return Z(i);
}
function fn(t) {
  let e;
  for (const i of cn)
    for (const n of Array.from(t.querySelectorAll(i))) {
      const r = Array.from(n.querySelectorAll("p"))
          .map((p) => _(p.textContent))
          .filter((p) => !!p),
        c = _(r.length > 0 ? r.join(" ") : n.textContent);
      if (!c || /^no abstract available\.?$/i.test(c)) continue;
      const u = c.replace(/^abstract\s*:?\s*/i, "").trim();
      u && (!e || u.length > e.length) && (e = u);
    }
  return e;
}
function pn(t, e) {
  var i;
  return v(
    hn(e),
    P(h(t, ["citation_doi", "dc.identifier.doi"])),
    P(
      U(
        ((i = t.querySelector('a[href*="doi.org/"]')) == null
          ? void 0
          : i.getAttribute("href")) ?? void 0,
        e,
      ),
    ),
  );
}
function hn(t) {
  var r;
  const e = R(t);
  if (!e) return;
  let i = e.pathname;
  try {
    i = decodeURIComponent(e.pathname);
  } catch {
    i = e.pathname;
  }
  const n =
    (r = i.match(/\/doi\/(?:[^/]+\/)?(10\.\d{4,9}\/[^\s"'<>?#]+)/i)) == null
      ? void 0
      : r[1];
  return P(n);
}
function gn(t) {
  const e = h(t, ["citation_pages"]);
  if (e) return e;
  const i = h(t, ["citation_firstpage"]),
    n = h(t, ["citation_lastpage"]);
  return i && n ? `${i}-${n}` : (i ?? n ?? void 0);
}
function mn(t, e, i) {
  var u, p;
  const n = R(e);
  if (n != null && n.pathname.startsWith("/doi/book/")) return "book";
  const r = h(t, ["pbContext"]);
  switch (
    (p =
      (u = r == null ? void 0 : r.match(/csubtype:string:(\w+)/i)) == null
        ? void 0
        : u[1]) == null
      ? void 0
      : p.toLowerCase()
  ) {
    case "conference":
      return "inproceedings";
    case "journal":
    case "periodical":
    case "magazine":
    case "newsletter":
      return "article";
    case "report":
    case "rfc":
      return "report";
    case "thesis":
      return "thesis";
    case "book":
      return "book";
    default:
      return i ? "book" : void 0;
  }
}
function bn(t, e, i) {
  const n = R(e);
  if (!n || !se.test(n.hostname)) return;
  const r = t.querySelector("#downloadPdfUrl"),
    c = U(
      (r == null ? void 0 : r.getAttribute("href")) ??
        (r == null ? void 0 : r.getAttribute("value")) ??
        h(t, ["citation_pdf_url"]),
      e,
    );
  if (c) return c;
  if (i && (n.pathname.includes("/doi/pdf/") || r))
    return `${n.origin}/doi/pdf/${i}?download=true`;
}
function yn(t) {
  let e = _(t);
  if (e) {
    for (const i of [
      /\s+\|\s+ACM Digital Library$/i,
      /\s+\|\s+The ACM Digital Library$/i,
      /\s+\|\s+ACM Books$/i,
    ])
      e = e.replace(i, "").trim();
    return e || void 0;
  }
}
function vn(t, e) {
  var w, ht, gt, mt, bt, yt, vt, xt, f, K, F, m;
  if (!xn(t, e)) return null;
  const i = Bt(t, ".gsc_oci_title_link");
  if (!i) return null;
  const n = Cn(t),
    r = rt(t, ".gsc_oci_title_link", e),
    c = rt(t, "#gsc_oci_title_gg a", e),
    u = Bt(t, "#gsc_oci_title_gg .gsc_vcd_title_ggt"),
    p = _n((w = n.get("authors")) == null ? void 0 : w.text),
    y = at(
      v(
        (ht = n.get("publication date")) == null ? void 0 : ht.text,
        (gt = n.get("date")) == null ? void 0 : gt.text,
      ),
    ),
    A = v(
      (mt = n.get("journal")) == null ? void 0 : mt.text,
      (bt = n.get("conference")) == null ? void 0 : bt.text,
      (yt = n.get("book")) == null ? void 0 : yt.text,
      (vt = n.get("source")) == null ? void 0 : vt.text,
    ),
    L = (xt = n.get("description")) == null ? void 0 : xt.text,
    S = (f = n.get("volume")) == null ? void 0 : f.text,
    E = (K = n.get("issue")) == null ? void 0 : K.text,
    I = v(
      (F = n.get("pages")) == null ? void 0 : F.text,
      (m = n.get("page")) == null ? void 0 : m.text,
    ),
    N = An([r, c]),
    M = Sn(c, u) ? c : void 0;
  return !(p.length > 0 || y || A || L || S || E || I || N || M)
    ? null
    : {
        title: i,
        authors: p,
        year: y,
        journal: A,
        abstract: L,
        doi: N,
        volume: S,
        issue: E,
        pages: I,
        pdfUrl: M,
        sourceUrl: e,
      };
}
function xn(t, e) {
  const i = R(e);
  return !i ||
    !/^scholar\.google\./i.test(i.hostname) ||
    i.pathname !== "/citations" ||
    i.searchParams.get("view_op") !== "view_citation"
    ? !1
    : !!(
        t.querySelector(".gsc_oci_title_link") &&
        t.querySelector("#gsc_oci_table")
      );
}
function Cn(t) {
  var i;
  const e = new Map();
  for (const n of Array.from(t.querySelectorAll("#gsc_oci_table .gs_scl"))) {
    const r = (i = Bt(n, ".gsc_oci_field")) == null ? void 0 : i.toLowerCase(),
      c = qt(n.querySelector(".gsc_oci_value"));
    !r || !c || e.set(r, { text: c });
  }
  return e;
}
function _n(t) {
  return t
    ? Z(
        t
          .split(/\s*,\s*/g)
          .map((e) => e.trim())
          .filter(Boolean),
      )
    : [];
}
function An(t) {
  for (const e of t) {
    const i = P(e);
    if (i) return i;
  }
}
function Sn(t, e) {
  return t
    ? /\bpdf\b/i.test(e ?? "")
      ? !0
      : /(?:\/pdf\/|\.pdf(?:$|[?#]))/i.test(t)
    : !1;
}
const Tn = [
  /\s+Note:\s+.*$/i,
  /\s+References\s*\(\d+\).*$/i,
  /\s+Figures\s*\(\d+\).*$/i,
];
function Ln(t, e) {
  if (!wn(e)) return null;
  const i = t.querySelector("main") ?? t.body,
    n = v(
      h(t, ["citation_title", "citation_article_title"]),
      X(i, "h1"),
      h(t, ["og:title"], "property"),
    );
  if (!n) return null;
  const r = i.querySelector("h1"),
    c = kn(i, n),
    u = $n(i, r),
    p = c ?? i,
    y = Mn(p, u),
    A = !!u || !jn(p, i),
    L = Pn(t, p, e, u),
    S = at(
      v(
        h(t, ["citation_publication_date", "citation_date", "dc.date"]),
        y,
        t.title,
      ),
    ),
    E = v(h(t, ["citation_journal_title", "dc.source"])),
    I = v(
      En(i),
      h(t, ["citation_abstract", "description"]),
      h(t, ["og:description"], "property"),
    ),
    N = Nn(t, p, y, e, u, A),
    M = Dn(t, p, e, u),
    V = Bn(t, y, M);
  return !(L.length > 0 || S || E || I || N || V || M)
    ? null
    : {
        title: n,
        authors: L,
        year: S,
        journal: E,
        abstract: I,
        doi: N,
        arxivId: V,
        pdfUrl: M,
        sourceUrl: e,
      };
}
function wn(t) {
  const e = R(t);
  return !e || !/(^|\.)inspirehep\.net$/i.test(e.hostname)
    ? !1
    : /^\/literature\/\d+/i.test(e.pathname);
}
function kn(t, e) {
  const i = t.querySelector("h1");
  if (!i) return null;
  let n = i.parentElement;
  for (let r = i.parentElement; r && t.contains(r); r = r.parentElement) {
    const c = _(r.textContent);
    if (!c || !c.includes(e)) continue;
    if (/Abstract:/i.test(c) || /References\s*\(\d+\)/i.test(c)) break;
    if (
      !!r.querySelector(
        'a[href*="/authors/"], a[href*="/pdf"], a[href*="arxiv.org/abs/"]',
      ) ||
      /\be-Print\s*:|\bView in\s*:|reference search|claim\b|\bcite\b/i.test(c)
    )
      return r;
    n = r;
  }
  return n;
}
function $n(t, e) {
  if (!e) return null;
  for (const i of Array.from(
    t.querySelectorAll("section, article, div, nav, button"),
  )) {
    if (i === e || i.contains(e) || !le(e, i)) continue;
    const n = _(i.textContent);
    if (
      n &&
      (/^Abstract\b/i.test(n) ||
        /^References\s*\(\d+\)/i.test(n) ||
        /^Figures\s*\(\d+\)/i.test(n))
    )
      return i;
  }
  return null;
}
function Pn(t, e, i, n) {
  const r = ft(t, ["citation_author"]);
  if (r.length > 0) return r;
  const c = [];
  for (const u of Mt(e, n)) {
    const p = _(u.textContent),
      y = U(u.getAttribute("href") ?? void 0, i);
    !p || !y || (/\/authors?\//i.test(y) && c.push(p));
  }
  return Z(c);
}
function En(t) {
  let e;
  for (const i of Array.from(t.querySelectorAll("section, article, div"))) {
    const n = _(i.textContent);
    if (!n || !/^Abstract\b/i.test(n)) continue;
    const r = In(n);
    r && (!e || r.length > e.length) && (e = r);
  }
  return e;
}
function In(t) {
  let e = t.replace(/^Abstract\s*:?\s*(?:\([^)]*\))?\s*/i, "").trim();
  for (const i of Tn) e = e.replace(i, "").trim();
  return e.length >= 80 ? e : void 0;
}
function Nn(t, e, i, n, r, c) {
  var A;
  const u = c ? qn(e, n, r) : void 0,
    p = c
      ? (A =
          i == null
            ? void 0
            : i.match(/\bDOI\s*:?\s*(10\.\d{4,9}\/[^\s"'<>]+)/i)) == null
        ? void 0
        : A[1]
      : void 0,
    y = v(h(t, ["citation_doi", "dc.identifier.doi"]), u, p);
  return P(y);
}
function Dn(t, e, i, n) {
  const r = U(h(t, ["citation_pdf_url"]), i);
  if (r) return r;
  for (const c of Mt(e, n)) {
    const u = _(c.textContent),
      p = U(c.getAttribute("href") ?? void 0, i);
    if (
      p &&
      (/^pdf$/i.test(u ?? "") ||
        /\/pdf(?:[/?#]|$)/i.test(p) ||
        /[?&](?:download|format)=pdf\b/i.test(p))
    )
      return p;
  }
}
function Bn(t, e, i) {
  const n = [
    h(t, ["citation_arxiv_id", "citation_technical_report_number"]),
    e,
    i,
  ];
  for (const r of n) {
    const c = Rn(r);
    if (c) return c;
  }
}
function Rn(t) {
  var n;
  const e = _(t);
  if (!e) return;
  const i = e.match(
    /\b(?:e-Print|arXiv)\s*:?\s*([a-z.-]+\/\d{7}(?:v\d+)?|\d{4}\.\d{4,5}(?:v\d+)?)/i,
  );
  return i != null && i[1]
    ? i[1]
    : (n = e.match(
          /\b(\d{4}\.\d{4,5}(?:v\d+)?|[a-z.-]+\/\d{7}(?:v\d+)?)(?:\.pdf)?\b/i,
        )) == null
      ? void 0
      : n[1];
}
function qn(t, e, i) {
  for (const n of Mt(t, i)) {
    const r = P(_(n.textContent));
    if (r) return r;
    if (!U(n.getAttribute("href") ?? void 0, e)) continue;
    const u = _(n.getAttribute("aria-label"));
    if (P(u)) return P(u);
  }
}
function Mt(t, e) {
  const i = Array.from(t.querySelectorAll("a[href]"));
  return e ? i.filter((n) => le(n, e)) : i;
}
function Mn(t, e) {
  if (!e) return qt(t instanceof Element ? t : null);
  const i = [];
  return ce(t, e, i), _(i.join(" "));
}
function ce(t, e, i) {
  var n;
  if (t === e) return !0;
  if (t.nodeType === t.TEXT_NODE) {
    const r = (n = t.textContent) == null ? void 0 : n.trim();
    return r && i.push(r), !1;
  }
  if (t.nodeType !== t.ELEMENT_NODE && t.nodeType !== t.DOCUMENT_FRAGMENT_NODE)
    return !1;
  for (const r of Array.from(t.childNodes)) if (ce(r, e, i)) return !0;
  return !1;
}
function le(t, e) {
  return t === e || e.contains(t)
    ? !1
    : !!(t.compareDocumentPosition(e) & Node.DOCUMENT_POSITION_FOLLOWING);
}
function jn(t, e) {
  return t === e;
}
const On = [
  ".abstract.author",
  ".abstract:not(.abstractHighlights)",
  "#preview-section-abstract",
  "section#preview-section-abstract",
  '[data-testid="abstract"]',
];
function Un(t, e) {
  if (!Fn(t, e)) return null;
  const i = zn(t);
  if (!i) return null;
  const n = v(
    h(t, ["citation_title", "citation_article_title"]),
    X(t, "h1 .title-text"),
    X(t, "h1"),
    h(t, ["og:title"], "property"),
  );
  if (!n) return null;
  const r = ft(t, ["citation_author"]),
    c = at(
      v(
        h(t, ["citation_publication_date", "citation_date", "dc.date"]),
        t.title,
      ),
    ),
    u = v(
      h(t, ["citation_journal_title", "dc.source"]),
      X(t, ".publication-title-link"),
      X(t, '[data-testid="journal-link"]'),
    ),
    p = Vn(t, e),
    y = h(t, ["citation_volume"]),
    A = h(t, ["citation_issue"]),
    L = Jn(t),
    S = Xn(t, e);
  return {
    title: n,
    authors: r,
    year: c,
    journal: u,
    abstract: i,
    doi: p,
    volume: y,
    issue: A,
    pages: L,
    pdfUrl: S,
    sourceUrl: e,
  };
}
function Fn(t, e) {
  const i = R(e);
  return !i ||
    !/(^|\.)science-?direct\.com$/i.test(i.hostname) ||
    !/^\/science\/article(?:\/abs)?\//i.test(i.pathname)
    ? !1
    : !!(
        X(t, "h1 .title-text") ||
        h(t, ["citation_title", "citation_article_title"])
      );
}
function zn(t) {
  let e;
  for (const i of On)
    for (const n of Array.from(t.querySelectorAll(i))) {
      if (n.classList.contains("abstractHighlights")) continue;
      const r = Hn(n);
      r && (!e || r.length > e.length) && (e = r);
    }
  return e;
}
function Hn(t) {
  const e = Array.from(t.querySelectorAll("p"))
      .filter((r) => !r.closest(".abstractHighlights"))
      .map((r) => _(r.textContent))
      .filter(Boolean),
    i = e.length > 0 ? e.join(" ") : _(t.textContent);
  if (!i) return;
  const n = i
    .replace(/^(abstract|summary)\s*[:-]?\s*/i, "")
    .replace(/\s*show more\s*$/i, "")
    .trim();
  return n.length >= 80 ? n : void 0;
}
function Vn(t, e) {
  const i = v(
    h(t, ["citation_doi", "dc.identifier.doi", "dc.identifier"]),
    rt(t, 'a[href*="doi.org/"]', e),
  );
  if (i) return P(i);
}
function Jn(t) {
  const e = h(t, ["citation_pages"]);
  if (e) return e;
  const i = h(t, ["citation_firstpage"]),
    n = h(t, ["citation_lastpage"]);
  return i && n ? `${i}-${n}` : (i ?? n ?? void 0);
}
function Xn(t, e) {
  const i = [
    h(t, ["citation_pdf_url"]),
    rt(t, "#pdfLink", e),
    rt(t, ".pdf-download-btn-link", e),
    rt(t, 'a[href*="/pdfft"]', e),
  ];
  for (const n of i) {
    const r = U(n, e);
    if (r) return r;
  }
}
const Wn = [
  { id: "acm-dl", parse: ln },
  { id: "google-scholar", parse: vn },
  { id: "inspirehep", parse: Ln },
  { id: "sciencedirect", parse: Un },
];
function Gn(t, e) {
  for (const i of Wn) {
    const n = i.parse(t, e);
    if (n) return n;
  }
  return null;
}
const Kn = /^10\.48550\/arxiv\.(.+)$/i,
  Yn = /^10\.\d{4,9}\/[^\s"'<>]+$/i,
  Zn = /^[^/\\]+\.pdf$/i;
function Qn(t, e = t.URL) {
  const i = ge(e),
    n = Gn(t, i);
  if (n) return Tt(n);
  const r = bi(t),
    c = ni(t, r),
    u = Z(ii(t, r)),
    p = ri(t, r),
    y = v(
      h(t, ["citation_journal_title"]),
      h(t, ["dc.source"]),
      h(t, ["og:site_name"], "property"),
      pi(r),
    ),
    A = v(
      h(t, ["citation_abstract"]),
      h(t, ["description"]),
      h(t, ["og:description"], "property"),
      W(r, ["description", "abstract"]),
    ),
    L = si(t, r, i),
    S = gi(t, r),
    E = jt(v(h(t, ["citation_volume"]), W(r, ["volumeNumber", "volume"]))),
    I = v(h(t, ["citation_issue"]), W(r, ["issueNumber", "issue"])),
    N = oi(t, r),
    M = ai(t, i);
  return !c.value ||
    (!!!(L || u.length > 0 || p || y || A || E || I || N || S || M) &&
      c.source === "document-title")
    ? ut(i)
    : Tt({
        title: c.value,
        authors: u,
        year: p,
        journal: y,
        abstract: A,
        doi: L,
        volume: E,
        issue: I,
        pages: N,
        isbn: S,
        pdfUrl: M,
        sourceUrl: i,
      });
}
function ti(t) {
  const e = ge(t.url),
    i = me(t.titleCandidates),
    n = Z(t.authorCandidates.map((w) => T(w.value)).filter((w) => !!w)),
    r = Ai(t.yearCandidates.map((w) => w.value)),
    c = nt(t.journalCandidates),
    u = nt(t.abstractCandidates),
    p = Ci(t.doiCandidates.map((w) => w.value)) ?? re(e),
    y = jt(nt(t.volumeCandidates)),
    A = nt(t.issueCandidates),
    L = nt(t.pagesCandidates),
    S = v(
      nt(t.arxivIdCandidates),
      ot(p),
      i != null && i.value ? ot(i.value) : void 0,
      ot(e),
    ),
    E = _i(t.isbnCandidates.map((w) => w.value)),
    I = xi(t.pdfCandidates);
  if (!(i != null && i.value)) return ut(e);
  const N = !!(p || n.length > 0 || r || c || u || y || A || L || E),
    V = !!(!!(N || S) || I);
  if (t.pageKind !== "html" && !N) {
    const w = ut(e);
    if (w) return w;
  }
  return !V && i.source === "document.title"
    ? ut(e)
    : Tt({
        title: i.value,
        authors: n,
        year: r,
        journal: c,
        abstract: u,
        doi: p,
        arxivId: S,
        volume: y,
        issue: A,
        pages: L,
        isbn: E,
        pdfUrl: I,
        sourceUrl: e,
      });
}
function de(t) {
  return ue(t) ? (be(t) ? !0 : !Si(t)) : !1;
}
function ue(t) {
  const e = T(t.doi);
  if (e) return { doi: e };
  const i = Li(t);
  if (i) return { arxivId: i };
  const n = T(t.isbn);
  if (n) return { isbn: n };
  const r = T(t.title);
  return r && Ti(r) ? { title: r } : null;
}
function ut(t) {
  return ei(t);
}
function ei(t) {
  let e;
  try {
    e = new URL(t);
  } catch {
    return null;
  }
  if (!/(^|\.)arxiv\.org$/i.test(e.hostname)) return null;
  const i = e.pathname.match(/^\/(abs|pdf)\/(.+)$/i);
  if (!i) return null;
  const n = i[2];
  if (!n) return null;
  let r = n;
  if (
    (r.endsWith("/") && (r = r.slice(0, -1)),
    r.toLowerCase().endsWith(".pdf") && (r = r.slice(0, -4)),
    !r)
  )
    return null;
  const c = r.replace(/v\d+$/i, "");
  return Tt({
    title: `arXiv:${r}`,
    authors: [],
    doi: `10.48550/arXiv.${c}`,
    pdfUrl: `https://arxiv.org/pdf/${r}.pdf`,
    journal: "arXiv",
    sourceUrl: t,
  });
}
function Tt(t) {
  return {
    ...t,
    journal: T(t.journal),
    abstract: T(t.abstract),
    doi: T(t.doi),
    arxivId: T(t.arxivId),
    volume: jt(t.volume),
    issue: T(t.issue),
    pages: T(t.pages),
    isbn: T(t.isbn),
    paperType: T(t.paperType),
    pdfUrl: T(t.pdfUrl),
  };
}
function ni(t, e) {
  const i = v(h(t, ["citation_title"]), h(t, ["citation_article_title"]));
  if (i) return { value: i, source: "citation" };
  const n = v(h(t, ["dc.title"]));
  if (n) return { value: n, source: "dc" };
  const r = h(t, ["og:title"], "property");
  if (r) return { value: r, source: "og" };
  const c = W(e, ["headline", "name"]);
  if (c) return { value: c, source: "jsonld" };
  const u = yi(t.title);
  return u
    ? { value: u, source: "document-title" }
    : { value: null, source: "none" };
}
function ii(t, e) {
  const i = ft(t, ["citation_author"]);
  if (i.length > 0) return i;
  const n = ft(t, ["dc.creator"]);
  if (n.length > 0) return n;
  for (const r of e) {
    const c = fe(r.author ?? r.creator);
    if (c.length > 0) return c;
  }
  return [];
}
function ri(t, e) {
  const i = [
    h(t, ["citation_publication_date", "citation_date"]),
    h(t, ["dc.date"]),
    W(e, ["datePublished", "dateCreated"]),
    t.title,
  ];
  for (const n of i) {
    const r = at(n);
    if (r) return r;
  }
}
function oi(t, e) {
  const i = v(h(t, ["citation_pages"]));
  if (i) return i;
  const n = v(h(t, ["citation_firstpage"]), W(e, ["pageStart"])),
    r = v(h(t, ["citation_lastpage"]), W(e, ["pageEnd"]));
  return n && r ? `${n}-${r}` : (n ?? r ?? W(e, ["pagination"]));
}
function ai(t, e) {
  const i = h(t, ["citation_pdf_url"]);
  if (i) return U(i, e);
  const n = ee(e);
  if (n)
    for (const r of Array.from(t.querySelectorAll("a[href]"))) {
      const c = r.getAttribute("href");
      if (!c || !/\.pdf(?:$|[?#])/i.test(c)) continue;
      const u = U(c, e);
      if (u && ee(u) === n) return u;
    }
}
function si(t, e, i) {
  const n = v(
    h(t, ["citation_doi"]),
    h(t, ["dc.identifier", "dc.identifier.doi"]),
    hi(e),
  );
  if (n) return P(n);
  const r = re(i);
  if (r) return r;
  const c = di(t),
    u = ci(t, i, c);
  if (u) return u;
  const p = fi(ui(t, c));
  if (p) return p;
}
function ci(t, e, i) {
  for (const n of Array.from(t.querySelectorAll("a[href]"))) {
    if (!li(n, i)) continue;
    const r = n.getAttribute("href"),
      c = U(r ?? void 0, e),
      u = P(c);
    if (u) return u;
    const p = P(n.textContent ?? void 0);
    if (p) return p;
  }
}
function li(t, e) {
  return e
    ? !!(t.compareDocumentPosition(e) & Node.DOCUMENT_POSITION_FOLLOWING)
    : !0;
}
function di(t) {
  var r;
  const e = t.body;
  if (!e) return null;
  const i = t.createTreeWalker(e, NodeFilter.SHOW_ELEMENT);
  let n = i.currentNode;
  for (; n; ) {
    const c =
      (r = n.textContent) == null ? void 0 : r.replace(/\s+/g, " ").trim();
    if (c && /^references(?:\s*\(\d+\))?$/i.test(c)) return n;
    n = i.nextNode();
  }
  return null;
}
function ui(t, e) {
  var c, u;
  const i = ((c = t.documentElement) == null ? void 0 : c.textContent) ?? "";
  if (!e) return i;
  const n = (u = e.textContent) == null ? void 0 : u.trim();
  if (!n) return i;
  const r = i.indexOf(n);
  return r < 0 ? i : i.slice(0, r);
}
function fi(t) {
  const e = t.matchAll(
    /(?:doi\s*:?\s*|https?:\/\/(?:dx\.)?doi\.org\/)\s*(10\.\d{4,9}\/[^\s"'<>]+?)(?=$|[\s"'<>])/gi,
  );
  for (const i of e) {
    const n = P(i[1]);
    if (n) return n;
  }
}
function pi(t) {
  for (const e of t) {
    const i = e.isPartOf;
    if (pt(i) && typeof i.name == "string") return i.name.trim();
  }
}
function hi(t) {
  for (const e of t) {
    const i = v(z(e, ["doi", "identifier"]), pe(e.identifier));
    if (i) return i;
  }
}
function gi(t, e) {
  return v(
    G(h(t, ["citation_isbn"])),
    G(
      h(t, [
        "dc.identifier.isbn",
        "dc.identifier.isbn13",
        "dc.identifier.isbn10",
      ]),
    ),
    mi(e),
  );
}
function mi(t) {
  for (const e of t) {
    const i = v(G(z(e, ["isbn"])), he(e.identifier));
    if (i) return i;
  }
}
function W(t, e) {
  for (const i of t) {
    const n = z(i, e);
    if (n) return n;
  }
}
function fe(t) {
  if (Array.isArray(t)) return Z(t.flatMap((e) => fe(e)));
  if (typeof t == "string") return [t.trim()];
  if (pt(t)) {
    const e = z(t, ["name"]);
    if (e) return [e];
    const i = z(t, ["givenName", "given"]),
      n = z(t, ["familyName", "family"]),
      r = [i, n].filter(Boolean).join(" ").trim();
    if (r) return [r];
  }
  return [];
}
function pe(t) {
  var e;
  if (t) {
    if (typeof t == "string") return t;
    if (Array.isArray(t)) {
      for (const i of t) {
        const n = pe(i);
        if (n) return n;
      }
      return;
    }
    if (pt(t)) {
      const i =
          (e = z(t, ["propertyID", "name"])) == null ? void 0 : e.toLowerCase(),
        n = z(t, ["value", "@value"]);
      return i != null && i.includes("doi") && n, n;
    }
  }
}
function he(t) {
  var e;
  if (t) {
    if (typeof t == "string") return G(t);
    if (Array.isArray(t)) {
      for (const i of t) {
        const n = he(i);
        if (n) return n;
      }
      return;
    }
    if (pt(t)) {
      const i =
          (e = z(t, ["propertyID", "name"])) == null ? void 0 : e.toLowerCase(),
        n = z(t, ["value", "@value"]);
      if (i != null && i.includes("isbn") && n) return G(n);
    }
  }
}
function bi(t) {
  var i;
  const e = [];
  for (const n of Array.from(
    t.querySelectorAll('script[type="application/ld+json"]'),
  )) {
    const r = (i = n.textContent) == null ? void 0 : i.trim();
    if (r)
      try {
        const c = JSON.parse(r);
        Rt(c, e);
      } catch {
        continue;
      }
  }
  return e;
}
function Rt(t, e) {
  if (t) {
    if (Array.isArray(t)) {
      for (const i of t) Rt(i, e);
      return;
    }
    if (pt(t) && (e.push(t), Array.isArray(t["@graph"])))
      for (const i of t["@graph"]) Rt(i, e);
  }
}
function yi(t) {
  const e = t.trim();
  if (!e) return null;
  const i = e
    .split(/\s[|\-–:]\s/)
    .map((r) => r.trim())
    .filter(Boolean);
  if (i.length === 0) return e;
  const n = [...i].sort((r, c) => c.length - r.length)[0];
  return n && n.length >= 8 ? n : e;
}
function z(t, e) {
  for (const i of e) {
    const n = t[i];
    if (typeof n == "string" && n.trim()) return n.trim();
  }
}
function ge(t) {
  try {
    return new URL(t).toString();
  } catch {
    return t;
  }
}
function ee(t) {
  try {
    return new URL(t).origin;
  } catch {
    return;
  }
}
function T(t) {
  return t != null && t.trim() ? t.trim() : void 0;
}
function jt(t) {
  const e = T(t);
  if (e) return vi(e) ? void 0 : e;
}
function vi(t) {
  return /^abs\/(?:[a-z.-]+\/\d{7}|\d{4}\.\d{4,5})(?:v\d+)?$/i.test(t.trim());
}
function me(t) {
  return t.find((e) => !!T(e.value));
}
function nt(t) {
  var e;
  return T((e = me(t)) == null ? void 0 : e.value);
}
function xi(t) {
  var e;
  return (e = t.find((i) => !!T(i.url))) == null ? void 0 : e.url;
}
function Ci(t) {
  for (const e of t) {
    const i = P(e);
    if (i) return i;
  }
}
function _i(t) {
  for (const e of t) {
    const i = G(e);
    if (i) return i;
  }
}
function Ai(t) {
  for (const e of t) {
    const i = at(e);
    if (i) return i;
  }
}
function be(t) {
  return ye(t.title);
}
function Si(t) {
  return t.authors.length === 0 || !t.year ? !1 : !!(T(t.journal) || T(t.doi));
}
function ye(t) {
  const e = t.trim();
  return e ? /^arxiv:/i.test(e) || Yn.test(e) || Zn.test(e) : !1;
}
function Ti(t) {
  const e = t.trim();
  if (ye(e)) return !1;
  const i = e.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  return e.length >= 20 && i.length >= 4;
}
function Li(t) {
  return dt(t.arxivId ?? "") ?? ot(t.doi) ?? ot(t.title) ?? ot(t.sourceUrl);
}
function ot(t) {
  const e = t == null ? void 0 : t.trim();
  if (!e) return;
  const i = e.match(Kn);
  if (i != null && i[1]) return i[1];
  const n = e.match(/^arxiv:\s*(.+)$/i);
  if (n != null && n[1]) return dt(n[1]);
  const r = e.match(
    /\b(?:e-Print|arXiv)\s*:?\s*([a-z.-]+\/\d{7}(?:v\d+)?|\d{4}\.\d{4,5}(?:v\d+)?)/i,
  );
  if (r != null && r[1]) return dt(r[1]);
  try {
    const c = new URL(e);
    if (!/(^|\.)arxiv\.org$/i.test(c.hostname)) return;
    const u = c.pathname.match(/^\/(?:abs|pdf)\/(.+)$/i);
    return u != null && u[1] ? dt(u[1]) : void 0;
  } catch {
    const c = e.match(
      /\b(\d{4}\.\d{4,5}(?:v\d+)?|[a-z.-]+\/\d{7}(?:v\d+)?)(?:\.pdf)?\b/i,
    );
    return c != null && c[1] ? dt(c[1]) : void 0;
  }
}
function dt(t) {
  let e = t.trim();
  if (e)
    return (
      (e = e.replace(/\.pdf$/i, "")),
      e.endsWith("/") && (e = e.slice(0, -1)),
      e || void 0
    );
}
function pt(t) {
  return typeof t == "object" && t !== null;
}
function wi(t, e) {
  const i = ki(e.authors),
    n = be(t);
  return {
    ...t,
    title: n ? (k(e.title) ?? t.title) : t.title,
    authors: n
      ? i.length > 0
        ? i
        : t.authors
      : t.authors.length > 0
        ? t.authors
        : i,
    year: e.year ?? t.year,
    journal: k(t.journal) ?? k(e.journal),
    abstract: n
      ? (k(e.abstract) ?? t.abstract)
      : (k(t.abstract) ?? k(e.abstract)),
    doi: k(t.doi) ?? k(e.doi),
    volume: k(t.volume) ?? k(e.volume),
    issue: k(t.issue) ?? k(e.issue),
    pages: k(t.pages) ?? k(e.pages),
    isbn: k(t.isbn) ?? k(e.isbn),
    paperType: k(t.paperType) ?? k(e.paperType),
  };
}
function ki(t) {
  return t != null && t.trim()
    ? t
        .split(/\s*;\s*/g)
        .map((e) => e.trim())
        .filter(Boolean)
    : [];
}
function k(t) {
  return t != null && t.trim() ? t.trim() : void 0;
}
function $i(t, e) {
  return t
    ? {
        ...e,
        arxivId: e.arxivId ?? t.arxivId,
        isbn: e.isbn ?? t.isbn,
        paperType: e.paperType ?? t.paperType,
        pdfUrl: t.pdfUrl ?? e.pdfUrl,
      }
    : e;
}
async function Pi(t, e, i) {
  for (const n of i) {
    const r = await n(),
      c = Ei(r, t);
    if (c) return $i(e, c);
  }
  return null;
}
function Ei(t, e) {
  if (!(t != null && t.html)) return null;
  const i = new DOMParser().parseFromString(t.html, "text/html");
  return Qn(i, t.url || e);
}
function Ii(t, e) {
  var i, n;
  (t.innerHTML = `
    <div class="stack">
      <div class="banner error">
        <strong>${Dt(e.state.title)}</strong>
        ${e.state.detail ? `<div style="margin-top: 6px;">${Dt(e.state.detail)}</div>` : ""}
      </div>
      <div class="row" style="justify-content: flex-end;">
        ${e.state.canRetry ? '<button id="retry-button" class="secondary">Retry</button>' : ""}
        ${e.state.actionLabel ? `<button id="action-button">${Dt(e.state.actionLabel)}</button>` : ""}
      </div>
    </div>
  `),
    (i = t.querySelector("#retry-button")) == null ||
      i.addEventListener("click", () => {
        var r;
        return (r = e.onRetry) == null ? void 0 : r.call(e);
      }),
    (n = t.querySelector("#action-button")) == null ||
      n.addEventListener("click", () => {
        var r;
        return (r = e.onAction) == null ? void 0 : r.call(e);
      });
}
function Dt(t) {
  return t
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
function Ni(t) {
  t.innerHTML = `
    <div class="row">
      <span class="spinner" aria-hidden="true"></span>
      <span class="muted">Loading page metadata…</span>
    </div>
  `;
}
function Di(t, e) {
  const i = document.createElement("select"),
    n = document.createElement("option");
  (n.value = ""), (n.textContent = "Inbox"), i.appendChild(n);
  for (const r of e.collections) {
    const c = document.createElement("option");
    c.value = r.id;
    const u = Math.max(r.depth ?? 0, 0);
    (c.textContent = `${"  ".repeat(u)}${r.name}`),
      (c.title = r.path ?? r.name),
      (c.selected = r.id === e.selected),
      i.appendChild(c);
  }
  i.addEventListener("change", () => {
    e.onChange(i.value || null);
  }),
    t.appendChild(i);
}
function Bi(t, e, i = !1) {
  const n = document.createElement("section");
  n.className = "card stack";
  const r = document.createElement("h2");
  r.textContent = e.title;
  const c = document.createElement("div");
  (c.className = "muted"), (c.textContent = Ri(e));
  const u = document.createElement("div");
  if (
    ((u.className = "muted"),
    (u.style.fontSize = "0.82rem"),
    (u.textContent = qi(e)),
    n.appendChild(r),
    c.textContent && n.appendChild(c),
    u.textContent && n.appendChild(u),
    e.abstract)
  ) {
    const p = document.createElement("p");
    (p.className = "muted"),
      (p.style.fontSize = "0.84rem"),
      (p.textContent =
        e.abstract.length > 180
          ? `${e.abstract.slice(0, 177)}...`
          : e.abstract),
      n.appendChild(p);
  }
  if (i) {
    const p = document.createElement("div");
    (p.className = "row muted"),
      (p.style.fontSize = "0.82rem"),
      (p.innerHTML = `
      <span class="spinner" aria-hidden="true"></span>
      <span>Fetching fuller metadata from Lattice…</span>
    `),
      n.appendChild(p);
  }
  t.appendChild(n);
}
function Ri(t) {
  const e = [];
  return (
    t.authors.length > 0 && e.push(Mi(t.authors)),
    t.year && e.push(String(t.year)),
    t.journal && e.push(t.journal),
    e.join(" · ")
  );
}
function qi(t) {
  const e = [];
  return (
    t.doi && e.push(t.doi),
    t.pages && e.push(`pp. ${t.pages}`),
    t.pdfUrl && e.push("PDF detected"),
    e.join(" · ")
  );
}
function Mi(t) {
  return t.length === 0 ? "" : t.length <= 2 ? t.join(", ") : `${t[0]} et al.`;
}
function ji(t, e) {
  if (e.tags.length === 0) {
    const n = document.createElement("div");
    (n.className = "muted"),
      (n.textContent = "No tags available yet."),
      t.appendChild(n);
    return;
  }
  const i = document.createElement("div");
  i.className = "pill-list";
  for (const n of e.tags) {
    const r = document.createElement("label");
    r.className = "pill";
    const c = document.createElement("input");
    if (
      ((c.type = "checkbox"),
      (c.value = n.id),
      (c.checked = e.selected.includes(n.id)),
      (c.style.width = "auto"),
      (c.style.margin = "0"),
      c.addEventListener("change", () => {
        const p = Array.from(i.querySelectorAll('input[type="checkbox"]'))
          .filter((y) => y.checked)
          .map((y) => y.value);
        e.onChange(p);
      }),
      r.appendChild(c),
      n.colorHex)
    ) {
      const p = document.createElement("span");
      (p.className = "pill-dot"),
        (p.style.background = Oi(n.colorHex)),
        r.appendChild(p);
    }
    const u = document.createElement("span");
    (u.textContent = n.name), r.appendChild(u), i.appendChild(r);
  }
  t.appendChild(i);
}
function Oi(t) {
  return t.startsWith("#") ? t : `#${t}`;
}
function Ui(t) {
  var i;
  const e = document.createElement("div");
  (e.className = "banner warning"),
    (e.innerHTML = `
    <strong>PDF upload is not available yet.</strong>
    <div style="margin-top: 4px;">
      Metadata can still be saved. Choose a browser-extension PDF folder, or configure PDF organization in Lattice, to enable PDF saving.
    </div>
    <button id="open-settings-button" class="secondary" style="margin-top: 8px;">
      Open Lattice Settings
    </button>
  `),
    (i = e.querySelector("#open-settings-button")) == null ||
      i.addEventListener("click", () => {
        window.open("lattice://settings", "_blank", "noopener,noreferrer");
      }),
    t.appendChild(e);
}
function Fi(t, e) {
  (t.innerHTML = ""),
    e.state.pdfUploadCapable || Ui(t),
    Bi(t, e.state.metadata, e.state.isEnrichingMetadata);
  const i = document.createElement("section");
  (i.className = "stack"),
    (i.innerHTML = '<div class="section-label">Collection</div>'),
    Di(i, {
      collections: e.state.collections,
      selected: e.state.selectedCollectionID,
      onChange: e.onCollectionChange,
    }),
    t.appendChild(i);
  const n = document.createElement("section");
  (n.className = "stack"),
    (n.innerHTML = '<div class="section-label">Tags</div>'),
    ji(n, {
      tags: e.state.tags,
      selected: e.state.selectedTagIDs,
      onChange: e.onTagsChange,
    }),
    t.appendChild(n);
  const r = document.createElement("button");
  (r.className = "primary-button"),
    (r.textContent = "Save to Lattice"),
    r.addEventListener("click", e.onSave),
    t.appendChild(r);
}
function zi(t, e = "Saving to Lattice…") {
  t.innerHTML = `
    <div class="row">
      <span class="spinner" aria-hidden="true"></span>
      <span>${e}</span>
    </div>
  `;
}
function Hi(t, e) {
  var i, n, r;
  (t.innerHTML = `
    <div class="stack">
      <div class="banner warning">
        <strong>Already in your library.</strong>
        <div style="margin-top: 6px;">
          ${Vi(e.state.existingTitle ?? "An existing paper matched this item.")}
        </div>
      </div>
      <div class="row">
        <button id="replace-button" class="secondary" style="flex: 1;">Replace</button>
        <button id="skip-button" class="secondary" style="flex: 1;">Skip</button>
        <button id="open-button" style="flex: 1;">Open</button>
      </div>
      <p class="muted">Replace replays the save using the server's duplicate-replacement path when available.</p>
    </div>
  `),
    (i = t.querySelector("#replace-button")) == null ||
      i.addEventListener("click", e.onReplace),
    (n = t.querySelector("#skip-button")) == null ||
      n.addEventListener("click", e.onSkip),
    (r = t.querySelector("#open-button")) == null ||
      r.addEventListener("click", e.onOpen);
}
function Vi(t) {
  return t
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
document.documentElement.style.setProperty("--popup-width", `${ze}px`);
const ve = document.getElementById("root");
if (!ve) throw new Error("Missing popup root");
const it = ve;
let C = { kind: "loading" },
  Lt = 0,
  Y = null;
function $(t) {
  (C = t), Ji();
}
function Ji() {
  switch (C.kind) {
    case "loading":
      Ni(it);
      break;
    case "preview":
      Fi(it, {
        state: C.state,
        onCollectionChange: (t) => {
          C.kind === "preview" &&
            $({
              kind: "preview",
              state: { ...C.state, selectedCollectionID: t },
            });
        },
        onTagsChange: (t) => {
          C.kind === "preview" &&
            $({ kind: "preview", state: { ...C.state, selectedTagIDs: t } });
        },
        onSave: Gi,
      });
      break;
    case "saving":
      zi(it, C.message);
      break;
    case "duplicate":
      Hi(it, {
        state: C.state,
        onReplace: Ki,
        onSkip: () => window.close(),
        onOpen: () => {
          const t = C.kind === "duplicate" ? C.state.latticeURL : void 0;
          t && window.open(t, "_blank", "noopener,noreferrer"), window.close();
        },
      });
      break;
    case "success":
      it.innerHTML = `<div class="success-banner">${tr(C.message)}</div>`;
      break;
    case "error": {
      const t = C.state;
      Ii(it, {
        state: t,
        onRetry: t.canRetry ? xe : void 0,
        onAction: t.actionURL
          ? () => {
              window.open(t.actionURL, "_blank", "noopener,noreferrer");
            }
          : void 0,
      });
      break;
    }
  }
}
async function xe() {
  const t = ++Lt;
  (Y = null), $({ kind: "loading" });
  try {
    const e = await H.runtime.sendMessage({ kind: "fetch-bootstrap" });
    if (!e.browserExtensionEnabled) {
      $({
        kind: "error",
        state: {
          title: "Browser extension is disabled",
          detail:
            "Enable it in Lattice → Settings → Local API → Browser Extension.",
          canRetry: !0,
          actionLabel: "Open Lattice Settings",
          actionURL: "lattice://settings",
        },
      });
      return;
    }
    const i = await Xi();
    if (!i) {
      $({
        kind: "error",
        state: {
          title: "No paper metadata found",
          detail: "This page does not expose standard citation metadata.",
          canRetry: !0,
        },
      });
      return;
    }
    const n = await H.runtime.sendMessage({ kind: "get-storage" }),
      r = de(i);
    $({
      kind: "preview",
      state: {
        metadata: i,
        collections: e.collections,
        tags: e.tags,
        pdfUploadCapable: e.capabilities.includes("pdf-upload"),
        isEnrichingMetadata: r,
        selectedCollectionID: n.lastUsedCollectionID ?? null,
        selectedTagIDs: n.lastUsedTagIDs ?? [],
      },
    }),
      r && Ae(i, { generation: t, applyToPreview: !0 });
  } catch (e) {
    $({
      kind: "error",
      state: {
        title: "Couldn't reach Lattice",
        detail: String(e.message),
        canRetry: !0,
        actionLabel: "Open Lattice",
        actionURL: "lattice://",
      },
    });
  }
}
async function Xi() {
  const [t] = await H.tabs.query({ active: !0, currentWindow: !0 });
  if (!(t != null && t.id)) return null;
  const e = await Ce(t.id, Fe);
  if (!(e != null && e.url)) return null;
  const i = ti(e);
  return (await Wi(t.id, e, i)) ?? i;
}
async function Wi(t, e, i) {
  const n = tn(e.url);
  return !n || n === e.url || e.pageKind === "html"
    ? null
    : Pi(n, i, [() => Qt(n), () => Ce(t, Qt, [n])]);
}
async function Ce(t, e, i) {
  const [n] = await H.scripting.executeScript({
    target: { tabId: t },
    func: e,
    args: i,
  });
  return n == null ? void 0 : n.result;
}
async function Gi() {
  if (C.kind !== "preview") return;
  const t = C.state;
  try {
    const e = await Yi(t),
      i = { ...t, metadata: e, isEnrichingMetadata: !1 },
      n = Zi(i);
    !ie && n.pdfUploadCapable && n.metadata.pdfUrl && (await Ue(H));
    const r = {
      request: n,
      selectedCollectionID: i.selectedCollectionID,
      selectedTagIDs: i.selectedTagIDs,
    };
    $({ kind: "saving", message: "Saving to Lattice…" });
    const c = await H.runtime.sendMessage({ kind: "save-flow", request: n });
    await _e(c, r);
  } catch (e) {
    $({
      kind: "error",
      state: { title: "Save failed", detail: String(e.message), canRetry: !0 },
    });
  }
}
async function Ki() {
  if (C.kind !== "duplicate") return;
  const t = C.lastContext;
  try {
    $({ kind: "saving", message: "Saving to Lattice…" });
    const e = await H.runtime.sendMessage({
      kind: "save-flow",
      request: { ...t.request, replace: !0 },
    });
    await _e(e, t);
  } catch (e) {
    $({
      kind: "error",
      state: { title: "Save failed", detail: String(e.message), canRetry: !0 },
    });
  }
}
async function Yi(t) {
  return de(t.metadata)
    ? ($({ kind: "saving", message: "Fetching metadata from Lattice…" }),
      (await (Y ?? Ae(t.metadata, { generation: Lt, applyToPreview: !1 }))) ??
        t.metadata)
    : t.metadata;
}
async function _e(t, e) {
  switch (t.status) {
    case "created":
      await H.runtime.sendMessage({
        kind: "set-storage",
        patch: {
          lastUsedCollectionID: e.selectedCollectionID,
          lastUsedTagIDs: e.selectedTagIDs,
        },
      }),
        $({ kind: "success", message: Qi(t) }),
        window.setTimeout(() => window.close(), 1200);
      return;
    case "duplicate":
      $({
        kind: "duplicate",
        state: {
          existingPaperID: t.conflict.existingPaperID,
          existingTitle: t.conflict.existingTitle,
          latticeURL:
            t.conflict.latticeURL ??
            `lattice://paper/${t.conflict.existingPaperID}`,
        },
        lastContext: e,
      });
      return;
    case "library-full":
      $({
        kind: "error",
        state: {
          title: "Library full",
          detail:
            "Lattice rejected the save because the current library is at its paper limit.",
          actionLabel: "Upgrade to Pro",
          actionURL: "lattice://upgrade",
        },
      });
      return;
    case "error":
      $({
        kind: "error",
        state: { title: "Save failed", detail: t.message, canRetry: !0 },
      });
      return;
  }
}
function Zi(t) {
  const e = t.collections.find((n) => n.id === t.selectedCollectionID),
    i = t.tags.filter((n) => t.selectedTagIDs.includes(n.id));
  return {
    metadata: t.metadata,
    collectionPath:
      (e == null ? void 0 : e.path) ?? (e == null ? void 0 : e.name) ?? null,
    tagNames: i.map((n) => n.name),
    pdfUploadCapable: t.pdfUploadCapable,
  };
}
function Ae(t, e) {
  const i = ue(t);
  if (!i) return Promise.resolve(null);
  const n = (async () => {
    const r = await H.runtime.sendMessage({
      kind: "lookup-metadata",
      params: i,
    });
    return r ? wi(t, r) : null;
  })();
  return (
    (Y = n),
    n
      .then((r) => {
        Y === n && (Y = null),
          !(!e.applyToPreview || e.generation !== Lt) &&
            C.kind === "preview" &&
            $({
              kind: "preview",
              state: {
                ...C.state,
                metadata: r ?? C.state.metadata,
                isEnrichingMetadata: !1,
              },
            });
      })
      .catch(() => {
        Y === n && (Y = null),
          !(!e.applyToPreview || e.generation !== Lt) &&
            C.kind === "preview" &&
            $({
              kind: "preview",
              state: { ...C.state, isEnrichingMetadata: !1 },
            });
      }),
    n
  );
}
function Qi(t) {
  return t.pdfUploaded
    ? "Saved with PDF."
    : t.pdfSkippedReason
      ? `Saved metadata only (${t.pdfSkippedReason}).`
      : "Saved.";
}
function tr(t) {
  return t
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
xe();
