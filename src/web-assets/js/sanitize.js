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
      // Unwrap — keep inner text/children
      while (child.firstChild) node.insertBefore(child.firstChild, child);
      child.remove();
      continue;
    }

    // Strip disallowed attributes
    const allowed = [...(ALLOWED_ATTRS[tag] || []), ...(ALLOWED_ATTRS['*'] || [])];
    for (const attr of [...child.attributes]) {
      if (!allowed.includes(attr.name)) child.removeAttribute(attr.name);
    }

    // Safety: force external links to open safely
    if (tag === 'a') {
      child.setAttribute('target', '_blank');
      child.setAttribute('rel', 'noopener noreferrer');
      const href = child.getAttribute('href') || '';
      if (href.startsWith('javascript:')) child.removeAttribute('href');
    }

    sanitizeNode(child);
  }
}
