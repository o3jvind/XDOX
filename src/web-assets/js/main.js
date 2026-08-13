// XDOX — main UI controller.
// Xojo calls these global functions via EvaluateJavaScript:
//   appendToken(text)       — defined in chat-handler.js
//   finalizeMessage()       — defined in chat-handler.js; also resets UI state below
//   showError(message)      — defined in chat-handler.js; also resets UI state below
//   updateIndexStatus(msg)
//   clearIndexStatus()

let isGenerating = false;
let lastUserMessage = '';

// ── JS → Xojo bridge ──────────────────────────────────────────────────────

function postToXojo(handler, body) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler]) {
    window.webkit.messageHandlers[handler].postMessage(body);
  }
}

// ── Wrappers so Xojo can call finalizeMessage / showError and also reset UI ──

var _chatHandlerFinalizeMessage = null;
var _chatHandlerShowError = null;

function _initWrappers() {
  _chatHandlerFinalizeMessage = finalizeMessage;
  _chatHandlerShowError = showError;

  finalizeMessage = function() {
    _chatHandlerFinalizeMessage();
    isGenerating = false;
    setSendState(false);
  };

  showError = function(message) {
    _chatHandlerShowError(message);
    isGenerating = false;
    setSendState(false);
  };
}

// ── User actions ──────────────────────────────────────────────────────────

function sendMessage() {
  if (isGenerating) return;
  const ta = document.getElementById('inputText');
  const text = (ta.value || '').trim();
  if (!text) return;

  ta.value = '';
  ta.style.height = '';
  lastUserMessage = text;

  showUserMessage(text);
  showThinkingIndicator();
  setSendState(true);
  isGenerating = true;

  postToXojo('sendMessage', text);
}

function stopGeneration() {
  postToXojo('stopGeneration', '');
}

function clearChat() {
  if (isGenerating) return;
  const ca = document.getElementById('chatArea');
  if (ca) ca.innerHTML = '';
  postToXojo('clearChat', '');
}

// ── Index status (called by Xojo) ─────────────────────────────────────────

function updateIndexStatus(message) {
  const el = document.getElementById('indexStatus');
  if (el) el.textContent = message || '';
}

function clearIndexStatus() {
  const el = document.getElementById('indexStatus');
  if (el) el.textContent = '';
}

// ── Save as Note ──────────────────────────────────────────────────────────

// Minimal HTML→Markdown converter for a bubble's own output — only needs to
// round-trip what marked.parse() itself produces (bold/italic/code/links/
// lists/headings/blockquotes), not arbitrary HTML.
function htmlFragmentToMarkdown(node) {
  let out = '';
  for (const child of node.childNodes) {
    if (child.nodeType === Node.TEXT_NODE) {
      out += child.textContent;
      continue;
    }
    if (child.nodeType !== Node.ELEMENT_NODE) continue;
    if (child.classList && (child.classList.contains('message-actions') || child.classList.contains('save-note-btn'))) continue;
    const tag = child.tagName.toLowerCase();
    const inner = htmlFragmentToMarkdown(child);
    switch (tag) {
      case 'strong': case 'b': out += `**${inner}**`; break;
      case 'em': case 'i': out += `*${inner}*`; break;
      case 'code':
        out += child.closest('pre') ? inner : `\`${inner}\``;
        break;
      case 'pre': out += `\`\`\`\n${inner}\n\`\`\`\n`; break;
      case 'a': out += `[${inner}](${child.getAttribute('href') || ''})`; break;
      case 'li': out += `- ${inner}\n`; break;
      case 'ul': case 'ol': out += `${inner}\n`; break;
      case 'h1': case 'h2': case 'h3': case 'h4':
        out += `${'#'.repeat(Number(tag[1]))} ${inner}\n\n`; break;
      case 'blockquote':
        out += inner.trim().split('\n').map(l => `> ${l}`).join('\n') + '\n\n'; break;
      case 'br': out += '\n'; break;
      case 'p': out += `${inner}\n\n`; break;
      default: out += inner;
    }
  }
  return out;
}

function selectedMarkdownWithin(bubble) {
  const sel = window.getSelection();
  if (!sel || sel.isCollapsed || sel.rangeCount === 0) return null;
  const range = sel.getRangeAt(0);
  // Selection must actually be inside this bubble, not spanning the page.
  if (!bubble.contains(range.commonAncestorContainer)) return null;
  const container = document.createElement('div');
  container.appendChild(range.cloneContents());
  const md = htmlFragmentToMarkdown(container).trim();
  return md || null;
}

function addSaveNoteButton(bubble, userMessage, rawText) {
  const btn = document.createElement('button');
  btn.className = 'save-note-btn';
  btn.textContent = 'Save as note';
  btn.addEventListener('click', function() {
    // Selected text inside this bubble → just that, converted back to
    // markdown so formatting survives. Nothing selected → the whole reply,
    // as the original raw markdown (keeps formatting marked.parse() would
    // otherwise lose by round-tripping through rendered HTML).
    const selected = selectedMarkdownWithin(bubble);
    const body = selected || rawText || bubble.innerText || '';
    postToXojo('saveAsNote', JSON.stringify({ title: userMessage, body: body }));
  });
  bubble.appendChild(btn);
}

// ── Input textarea helpers ────────────────────────────────────────────────

function handleTextareaKeydown(e) {
  if (e.key === 'Enter' && !e.shiftKey) {
    e.preventDefault();
    sendMessage();
  }
}

function handleTextareaInput(e) {
  const ta = e.target;
  ta.style.height = 'auto';
  ta.style.height = Math.min(ta.scrollHeight, 260) + 'px';
}

// ── UI state helpers ──────────────────────────────────────────────────────

function setSendState(generating) {
  const sendBtn = document.getElementById('sendBtn');
  const stopBtn = document.getElementById('stopBtn');
  if (sendBtn) {
    sendBtn.disabled = generating;
    sendBtn.style.display = generating ? 'none' : '';
  }
  if (stopBtn) {
    stopBtn.style.display = generating ? '' : 'none';
    if (generating) stopBtn.classList.add('generating');
    else stopBtn.classList.remove('generating');
  }
}

function applyTheme(theme) {
  const root = document.documentElement;
  if (theme === 'dark') root.setAttribute('data-theme', 'dark');
  else if (theme === 'light') root.setAttribute('data-theme', 'light');
  else root.removeAttribute('data-theme');
  postToXojo('setTheme', JSON.stringify({ theme: theme }));
}

// ── Toast ─────────────────────────────────────────────────────────────────

let toastTimer = null;

function showToast(message) {
  const el = document.getElementById('toast');
  if (!el) return;
  el.textContent = message;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2500);
}

// ── Notes sidebar ─────────────────────────────────────────────────────────
// List rendering lives in notes-manager.js (loadNotes/filterNotes).

function toggleSidebar() {
  const app = document.querySelector('.app');
  if (!app) return;
  app.classList.toggle('sidebar-collapsed');
  try {
    localStorage.setItem('sidebarOpen', app.classList.contains('sidebar-collapsed') ? '0' : '1');
  } catch (e) { /* localStorage unavailable — ignore */ }
}

function restoreSidebarState() {
  try {
    if (localStorage.getItem('sidebarOpen') === '0') {
      document.querySelector('.app').classList.add('sidebar-collapsed');
    }
  } catch (e) { /* ignore */ }
}

// ── Docs version selector ─────────────────────────────────────────────────
// Xojo calls receiveVersions(list, active) at startup and after (re)indexing
// or cleanup. The dropdown drives which Xojo version chat/retrieval uses.

function receiveVersions(list, active) {
  const sel = document.getElementById('versionSelect');
  if (!sel) return;
  const versions = list || [];
  sel.innerHTML = '';
  // Only worth showing when more than one version is indexed.
  if (versions.length < 2) {
    sel.style.display = 'none';
    return;
  }
  versions.forEach((v) => {
    const opt = document.createElement('option');
    opt.value = v;
    opt.textContent = v;
    if (v === active) opt.selected = true;
    sel.appendChild(opt);
  });
  sel.style.display = '';
}

function selectDocsVersion(version) {
  postToXojo('selectDocsVersion', version);
}

// ── Notes search scope ────────────────────────────────────────────────────
// 'all' searches every note; 'version' restricts to global + active-version
// notes. Xojo persists the choice in DB metadata.

function receiveNotesSearchScope(scope) {
  const sel = document.getElementById('notesScopeSelect');
  if (sel) sel.value = scope || 'all';
}

function setNotesSearchScope(scope) {
  postToXojo('setNotesSearchScope', scope);
}

// ── Backend / model management ────────────────────────────────────────────
// Xojo calls: receiveBackendState(state, detail), receiveCatalog(catalog,
// installed, selectedId), receiveDownloadProgress(id, pct),
// receiveDownloadDone(id, ok, err), receiveEmbedCrashed()

let modelCatalog = [];
let modelInstalled = {};
let selectedModelId = '';
let modelDownloads = {};   // id -> pct
let overlayAutoOpened = false;
let embedDownloading = false;  // fixed search model (id 'embedding') in flight

function setBackendStatus(text, cls) {
  const el = document.getElementById('backendStatus');
  if (!el) return;
  el.textContent = text;
  el.className = 'backend-status' + (cls ? ' ' + cls : '');
}

function receiveBackendState(state, detail) {
  switch (state) {
    case 'no-model':
      setBackendStatus('No model installed', 'error');
      openModelOverlay(true);
      break;
    case 'not-downloaded':
      setBackendStatus('Model not downloaded', 'error');
      openModelOverlay(true);
      break;
    case 'loading':
      setBackendStatus('Loading model…', '');
      break;
    case 'ready':
      setBackendStatus('● Model ready', 'ready');
      if (overlayAutoOpened) closeModelOverlay();
      break;
    case 'crashed':
      setBackendStatus('Model crashed', 'error');
      showToast('The model server stopped unexpectedly.');
      break;
    case 'port-conflict':
      setBackendStatus('Port conflict', 'error');
      showToast(detail || 'Another app is using the model port.');
      break;
    case 'error':
      setBackendStatus('Model error', 'error');
      showToast(detail || 'The model could not be started.');
      break;
  }
}

function receiveEmbedCrashed() {
  showToast('Semantic search stopped unexpectedly — falling back to keyword search.');
}

function openModelOverlay(auto) {
  overlayAutoOpened = !!auto;
  const ov = document.getElementById('modelOverlay');
  if (ov) ov.style.display = '';
  postToXojo('getModels', '');
}

function closeModelOverlay() {
  const ov = document.getElementById('modelOverlay');
  if (ov) ov.style.display = 'none';
  overlayAutoOpened = false;
}

function receiveCatalog(catalog, installed, selectedId, embedNeeded) {
  modelCatalog = catalog || [];
  modelInstalled = installed || {};
  selectedModelId = selectedId || '';
  updateEmbedNote(!!embedNeeded);
  renderModelList();
}

// One-time disclosure: the first chat-model choice also triggers the fixed
// search-model download. Hidden once that model is on disk.
function updateEmbedNote(needed) {
  const note = document.getElementById('embedNote');
  if (!note) return;
  if (needed) {
    note.textContent = 'First-time setup: along with your chat model, XDOX '
      + 'downloads a small search model (nomic-embed-text, 146 MB) that powers '
      + 'semantic search. This happens only once — later launches download nothing.';
    note.style.display = '';
  } else {
    note.style.display = 'none';
  }
}

function formatGB(bytes) {
  return (bytes / (1024 * 1024 * 1024)).toFixed(1) + ' GB';
}

function renderModelList() {
  const list = document.getElementById('modelList');
  if (!list) return;
  list.innerHTML = '';
  modelCatalog.forEach((m) => {
    const card = document.createElement('div');
    card.className = 'model-card' + (m.id === selectedModelId ? ' selected' : '');

    const info = document.createElement('div');
    info.className = 'model-card-info';
    const name = document.createElement('div');
    name.className = 'model-card-name';
    name.textContent = m.name;
    if (m.recommended) {
      const badge = document.createElement('span');
      badge.className = 'model-badge';
      badge.textContent = 'Recommended';
      name.appendChild(badge);
    }
    const desc = document.createElement('div');
    desc.className = 'model-card-desc';
    desc.textContent = m.description;
    const meta = document.createElement('div');
    meta.className = 'model-card-meta';
    meta.textContent = formatGB(m.bytes) + ' download · ' + m.ram + ' RAM';
    info.appendChild(name);
    info.appendChild(desc);
    info.appendChild(meta);

    const action = document.createElement('div');
    action.className = 'model-card-action';

    if (m.id in modelDownloads) {
      const bar = document.createElement('div');
      bar.className = 'model-progress';
      const fill = document.createElement('div');
      fill.className = 'model-progress-fill';
      fill.id = 'modelProgress-' + m.id;
      fill.style.width = (modelDownloads[m.id] || 0) + '%';
      bar.appendChild(fill);
      const cancel = document.createElement('button');
      cancel.className = 'model-btn secondary';
      cancel.textContent = 'Cancel';
      cancel.onclick = () => cancelModelDownload(m.id);
      action.appendChild(bar);
      action.appendChild(cancel);
    } else if (modelInstalled[m.id]) {
      if (m.id === selectedModelId) {
        const label = document.createElement('div');
        label.className = 'model-selected-label';
        label.textContent = '✓ In use';
        action.appendChild(label);
      } else {
        const use = document.createElement('button');
        use.className = 'model-btn';
        use.textContent = 'Use';
        use.onclick = () => selectModel(m.id);
        action.appendChild(use);
      }
    } else {
      const dl = document.createElement('button');
      dl.className = 'model-btn';
      dl.textContent = 'Download';
      dl.onclick = () => downloadModel(m.id);
      action.appendChild(dl);
    }

    card.appendChild(info);
    card.appendChild(action);
    list.appendChild(card);
  });
}

function downloadModel(id) {
  modelDownloads[id] = 0;
  renderModelList();
  setBackendStatus('Downloading model…', '');
  postToXojo('downloadModel', id);
}

function cancelModelDownload(id) {
  postToXojo('cancelDownload', id);
}

function selectModel(id) {
  selectedModelId = id;
  renderModelList();
  postToXojo('selectModel', id);
}

function receiveDownloadProgress(id, pct) {
  // The fixed search model has no catalog card — its progress lives in the
  // status bar's search-tier slot instead.
  if (id === 'embedding') {
    embedDownloading = true;
    const el = document.getElementById('semanticStatus');
    if (el) {
      el.textContent = 'Downloading search model… ' + Math.round(pct) + '%';
      el.className = 'semantic-status';
    }
    return;
  }
  modelDownloads[id] = pct;
  const fill = document.getElementById('modelProgress-' + id);
  if (fill) fill.style.width = pct + '%';
}

// Search tier indicator: 'semantic' (hybrid, embedding server up) or
// 'keyword' (BM25-only fallback).
function receiveSemanticState(state) {
  const el = document.getElementById('semanticStatus');
  if (!el) return;
  // Don't let a keyword-tier ping wipe the download progress text.
  if (state !== 'semantic' && embedDownloading) return;
  if (state === 'semantic') {
    el.textContent = 'Semantic search';
    el.className = 'semantic-status ready';
  } else {
    el.textContent = 'Keyword search';
    el.className = 'semantic-status';
  }
}

function receiveDownloadDone(id, ok, err) {
  // The search model must never fall through to the chat-model logic below —
  // it finishes first (it is far smaller) and would get auto-selected.
  if (id === 'embedding') {
    embedDownloading = false;
    if (ok) {
      updateEmbedNote(false);
      showToast('Search model installed — semantic search is warming up');
    } else {
      const el = document.getElementById('semanticStatus');
      if (el) { el.textContent = 'Keyword search'; el.className = 'semantic-status'; }
      if (err && err !== 'cancelled') showToast('Search model download failed: ' + err);
    }
    return;
  }
  delete modelDownloads[id];
  if (ok) {
    modelInstalled[id] = true;
    showToast('Download complete');
    // First model in — put it to use right away.
    if (!selectedModelId) { selectModel(id); return; }
  } else if (err && err !== 'cancelled') {
    setBackendStatus('Download failed', 'error');
    showToast('Download failed: ' + err);
  }
  renderModelList();
}

// ── Init ──────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  _initWrappers();
  restoreSidebarState();
  postToXojo('pageReady', '');
});
