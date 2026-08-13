// Minimal HTML sanitiser — strips tags/attributes not in the allow-list.
// Used before inserting AI-generated content into the DOM.

const ALLOWED_TAGS = new Set([
  'p','br','strong','em','b','i','u','s','del','code','pre','blockquote',
  'h1','h2','h3','h4','h5','h6',
  'ul','ol','li',
  'table','thead','tbody','tr','th','td',
  'hr','a','span','div',
]);

const ALLOWED_ATTRS = {
  'a':   ['href','title','target','rel'],
  'img': ['src','alt','width','height'],
  '*':   ['class'],
};

function sanitizeHTML(dirty) {
  const doc = new DOMParser().parseFromString(dirty, 'text/html');
  sanitizeNode(doc.body);
  return doc.body.innerHTML;
}

function sanitizeNode(node) {
  for (let i = node.childNodes.length - 1; i >= 0; i--) {
    const child = node.childNodes[i];
    if (child.nodeType === Node.TEXT_NODE) continue;
    if (child.nodeType !== Node.ELEMENT_NODE) { child.remove(); continue; }

    const tag = child.tagName.toLowerCase();
    if (!ALLOWED_TAGS.has(tag)) {
      // Unwrap — keep inner text/children, then sanitise what was moved up
      while (child.firstChild) node.insertBefore(child.firstChild, child);
      child.remove();
      sanitizeNode(node);
      continue;
    }

    // Strip disallowed attributes
    const allowed = [...(ALLOWED_ATTRS[tag] || []), ...(ALLOWED_ATTRS['*'] || [])];
    for (const attr of [...child.attributes]) {
      if (!allowed.includes(attr.name)) child.removeAttribute(attr.name);
    }

    // Safety: only allow http(s)/mailto/relative links; force external links
    // to open safely. Blocks javascript:, data:, vbscript: and obfuscated
    // variants (case, whitespace, control chars) rather than blocklisting
    // one exact string.
    if (tag === 'a') {
      child.setAttribute('target', '_blank');
      child.setAttribute('rel', 'noopener noreferrer');
      const href = child.getAttribute('href') || '';
      if (!isSafeHref(href)) child.removeAttribute('href');
    }

    sanitizeNode(child);
  }
}

function isSafeHref(href) {
  // Strip ASCII control chars (\x00-\x1F, \x7F), matching how browsers
  // ignore them when parsing a URL scheme, so "jav\tascript:" etc. can't
  // sneak past the protocol check below.
  const trimmed = href.replace(/[\x00-\x1F\x7F]+/g, '').trim();
  if (trimmed === '') return true;
  if (trimmed.startsWith('#') || trimmed.startsWith('/')) return true;
  try {
    const url = new URL(trimmed, 'https://xdox.invalid/');
    return ['http:', 'https:', 'mailto:'].includes(url.protocol);
  } catch (e) {
    return false;
  }
}
