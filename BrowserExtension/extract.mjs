// This function is self-contained because scripting.executeScript serializes it
// into the active page. Page metadata is data; no page-provided code is run here.
export function capturePageMetadata(doc = globalThis.document, pageURL = globalThis.location?.href ?? doc.baseURI) {
  const metadata = new Map();
  for (const node of doc.querySelectorAll('meta')) {
    const key = (node.getAttribute('name') || node.getAttribute('property') || '').toLowerCase();
    const value = (node.getAttribute('content') || '').trim();
    if (key && value) metadata.set(key, [...(metadata.get(key) || []), value]);
  }
  const first = (...keys) => keys.flatMap(key => metadata.get(key) || []).find(Boolean) || '';
  const safeURL = value => {
    try { const url = new URL(value, pageURL); return ['http:', 'https:'].includes(url.protocol) ? url.href : ''; }
    catch { return ''; }
  };
  let structured = {};
  for (const script of doc.querySelectorAll('script[type="application/ld+json"]')) {
    if ((script.textContent || '').length > 1_048_576) continue;
    try {
      const parsed = JSON.parse(script.textContent);
      const nodes = Array.isArray(parsed) ? parsed : (Array.isArray(parsed?.['@graph']) ? parsed['@graph'] : [parsed]);
      const article = nodes.find(node => node && [node['@type']].flat().some(type => ['ScholarlyArticle', 'Article', 'MedicalScholarlyArticle'].includes(type)));
      if (article) { structured = article; break; }
    } catch { /* Malformed structured data does not stop capture. */ }
  }
  const authors = [...new Set((metadata.get('citation_author') || metadata.get('dc.creator') ||
    [structured.author].flat().filter(Boolean).map(author => typeof author === 'string' ? author : author.name).filter(Boolean))
    .flatMap(value => value.split(';')).map(value => value.trim()).filter(Boolean))];
  const doiHint = first('citation_doi', 'dc.identifier', 'prism.doi') || String(structured.identifier || '') || pageURL;
  const doi = doiHint.match(/10\.\d{4,9}\/[^\s<>"']+/i)?.[0] || '';
  const date = first('citation_publication_date', 'citation_date', 'dc.date', 'article:published_time') || structured.datePublished || '';
  const yearMatch = String(date).match(/\b(1\d{3}|2\d{3})\b/);
  const canonical = doc.querySelector('link[rel="canonical"]')?.getAttribute('href');
  const url = safeURL(canonical || pageURL);
  const arxiv = url.match(/arxiv\.org\/(?:abs|pdf)\/((?:[a-z.-]+\/\d{7}|\d{4}\.\d{4,5})(?:v\d+)?)/i)?.[1] || '';
  const directPDF = (() => { try { return new URL(pageURL).pathname.toLowerCase().endsWith('.pdf'); } catch { return false; } })();
  return {
    title: first('citation_title', 'dc.title', 'og:title') || structured.headline || structured.name || doc.title || '',
    authors,
    ...(yearMatch ? { year: Number(yearMatch[1]) } : {}),
    journal: first('citation_journal_title', 'citation_conference_title', 'dc.source') || '',
    abstract: first('citation_abstract', 'dc.description', 'description', 'og:description') || structured.abstract || '',
    doi, isbn: first('citation_isbn'), url,
    paperType: arxiv ? 'preprint' : 'article',
    ...(arxiv ? { eprint: arxiv, eprintType: 'arXiv' } : {}),
    pdfURL: safeURL(first('citation_pdf_url') || (directPDF ? pageURL : ''))
  };
}
