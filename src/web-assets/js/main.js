// XDOX — main UI controller.
// Xojo calls these global functions via EvaluateJavaScript:
//   showCannedResponseForPool(pool, text) — defined in chat-handler.js; renders one pool's reply
//   showNoMatchForPool(pool)              — defined in chat-handler.js; that pool's search found nothing
//   showError(pool, message)              — defined in chat-handler.js
//   onTurnDone()                          — defined below; the WHOLE turn is done (all
//                                            expected pools completed), resets Send/isGenerating
//   updateIndexStatus(msg)
//   clearIndexStatus()

// Split-bubble redesign (reactive-coalescing-thimble plan, 2026-08-30): a
// turn can produce 0-2 independently-timed bubbles (one per pool). Per-bubble
// finalize (chat-handler.js) no longer flips isGenerating/setSendState —
// only onTurnDone does, fired once by Xojo's real OnDone when ALL expected
// pools for the turn have completed. See XDOXSession.FinishTurn's comment
// for why Send deliberately stays disabled until then, not after the first
// bubble.
let isGenerating = false;
let lastUserMessage = '';

// ── JS → Xojo bridge ──────────────────────────────────────────────────────

function postToXojo(handler, body) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler]) {
    window.webkit.messageHandlers[handler].postMessage(body);
  }
}

function onTurnDone() {
  isGenerating = false;
  setSendState(false);
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

  // Which pools will actually be searched is known synchronously from the
  // scope selector's own last-received value (receiveDocsSearchScope keeps
  // docsScopeSelect's value in sync — see below) — mirrors XDOXSession.
  // SendMessage computing mExpectedPools from DBHelper.GetDocsSearchScope()
  // before either worker starts, so the status rows shown here match
  // exactly which pool(s) Xojo is about to search.
  const scope = (document.getElementById('docsScopeSelect') || {}).value || 'all';
  const statuses = [];
  if (scope !== 'mbs') statuses.push({ pool: 'native', text: 'Searching Xojo docs…' });
  if (scope !== 'native') statuses.push({ pool: 'mbs', text: 'Searching MBS docs…' });
  showSearchStatus(statuses);

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

// ── Docs search scope ─────────────────────────────────────────────────────
// 'all' searches both Xojo and MBS docs; 'native'/'mbs' restrict to one
// source. Xojo persists the choice in DB metadata.

function receiveDocsSearchScope(scope) {
  const sel = document.getElementById('docsScopeSelect');
  if (sel) sel.value = scope || 'all';
}

function setDocsSearchScope(scope) {
  // Old bubbles were computed under the PREVIOUS scope (e.g. a "both
  // sources" turn from before switching to "MBS only") — leaving them
  // visible reads as if the new scope still applies to them. Clearing on
  // every switch, not just when it would visibly matter, keeps this simple
  // and predictable rather than trying to guess which past turns are still
  // valid under the new scope. Reuses clearChat's own isGenerating guard —
  // switching scope mid-search doesn't cancel the in-flight search itself
  // (docs_search_scope is only read at the START of a new SendMessage), it
  // just declines to also wipe the chat while a turn is still rendering.
  clearChat();
  postToXojo('setDocsSearchScope', scope);
}

// ── Backend / model management ────────────────────────────────────────────
// Xojo calls: receiveModelStatus(embedNeeded, rerankNeeded) once at startup,
// receiveDownloadProgress(id, pct), receiveDownloadDone(id, ok, err),
// receiveEmbedCrashed(). XDOX only ever downloads two fixed models — the
// search (embedding) model and the reranker — never a user-chosen one.

let embedDownloading = false;  // fixed search model (id 'embedding') in flight
let rerankDownloading = false; // fixed reranker model (id 'reranker') in flight
// Tracks which fixed models are still outstanding so the combined disclosure
// banner only hides once BOTH are confirmed installed, regardless of which
// download happens to finish first.
let embedModelDone = false;
let rerankModelDone = false;

function receiveEmbedCrashed() {
  showToast('Semantic search stopped unexpectedly — falling back to keyword search.');
}

// Xojo calls this once at startup (from AutoStart) so the disclosure banner
// reflects reality on relaunch instead of always assuming a fresh install.
function receiveModelStatus(embedNeeded, rerankNeeded) {
  embedModelDone = !embedNeeded;
  rerankModelDone = !rerankNeeded;
  updateEmbedBanner();
}

// One-time disclosure: on first launch XDOX downloads two fixed models that
// power search. Non-modal — nothing to choose, so nothing blocks on it.
// Hidden once BOTH are on disk — tracked separately (embedModelDone/
// rerankModelDone) so whichever of the two finishes first doesn't
// prematurely hide the banner while the other is still missing.
function updateEmbedBanner() {
  const banner = document.getElementById('embedBanner');
  if (!banner) return;
  if (!embedModelDone || !rerankModelDone) {
    banner.textContent = 'XDOX runs local AI models on your Mac — nothing leaves your machine. '
      + 'First-time setup downloads two fixed models that power search — a search model '
      + '(nomic-embed-text, 146 MB) and a reranker (Qwen3-Reranker-4B, 4.3 GB). '
      + 'This happens only once — later launches download nothing.';
    banner.style.display = '';
  } else {
    banner.style.display = 'none';
  }
}

function receiveDownloadProgress(id, pct) {
  // Only ever 'embedding' or 'reranker' — the fixed models — and both
  // report into the status bar's search-tier slot.
  if (id === 'embedding') {
    embedDownloading = true;
    const el = document.getElementById('semanticStatus');
    if (el) {
      el.textContent = 'Downloading search model… ' + Math.round(pct) + '%';
      el.className = 'semantic-status';
    }
    return;
  }
  if (id === 'reranker') {
    rerankDownloading = true;
    const el = document.getElementById('semanticStatus');
    // Don't stomp the embedding model's own progress text if both happen to
    // be downloading at once — whichever posts last wins the slot, which is
    // harmless since both resolve to the same "warming up" toast.
    if (el) {
      el.textContent = 'Downloading reranker… ' + Math.round(pct) + '%';
      el.className = 'semantic-status';
    }
    return;
  }
}

// Search tier indicator: 'semantic' (hybrid, embedding server up) or
// 'keyword' (BM25-only fallback).
function receiveSemanticState(state) {
  const el = document.getElementById('semanticStatus');
  if (!el) return;
  // Don't let a keyword-tier ping wipe the download progress text.
  if (state !== 'semantic' && (embedDownloading || rerankDownloading)) return;
  if (state === 'semantic') {
    el.textContent = 'Semantic search';
    el.className = 'semantic-status ready';
  } else {
    el.textContent = 'Keyword search';
    el.className = 'semantic-status';
  }
}

function receiveDownloadDone(id, ok, err) {
  // Only ever 'embedding' or 'reranker' — the fixed models.
  if (id === 'embedding') {
    embedDownloading = false;
    if (ok) {
      embedModelDone = true;
      updateEmbedBanner();
      showToast('Search model installed — semantic search is warming up');
    } else {
      const el = document.getElementById('semanticStatus');
      if (el) { el.textContent = 'Keyword search'; el.className = 'semantic-status'; }
      if (err && err !== 'cancelled') showToast('Search model download failed: ' + err);
    }
    return;
  }
  if (id === 'reranker') {
    rerankDownloading = false;
    if (ok) {
      rerankModelDone = true;
      updateEmbedBanner();
      showToast('Reranker installed — retrieval quality is improving');
    } else {
      if (err && err !== 'cancelled') showToast('Reranker download failed: ' + err);
    }
    return;
  }
}

// ── Link handling ────────────────────────────────────────────────────────
// Chat/note content renders <a href> links (sanitize.js allows the tag and
// forces target="_blank" as a defence-in-depth default), but this is a
// WKWebView, not a real browser tab strip — target="_blank" alone has no
// reliable "open in the user's actual default browser" behavior here.
// Delegate every link click in the chat area to Xojo's openURL bridge
// handler (ChatView.xojo_code's didReceiveScriptMessage, which calls
// ShowURL) instead, same mechanism already used for other Xojo-side actions.
document.addEventListener('click', (e) => {
  const link = e.target.closest('a[href]');
  if (!link) return;
  if (!document.getElementById('chatArea')?.contains(link)) return;
  e.preventDefault();
  postToXojo('openURL', link.getAttribute('href'));
});

// ── Init ──────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  restoreSidebarState();
  postToXojo('pageReady', '');
});
