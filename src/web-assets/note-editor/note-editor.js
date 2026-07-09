// XDOX note editor — runs in NoteEditorWindow's own WKWebView.
// Xojo calls: loadNote(note), loadTagSuggestions(tags), showSuggestedTags(tags),
//             showStalenessBanner(version), hideStalenessBanner(), noteSaved()
// JS posts:   editorReady, saveNote, deleteNote, setDirty, markAsReviewed,
//             dismissStaleness, closeEditor

let _note = null;
let _dirty = false;
let _mode = 'edit';
let _allTags = [];   // existing tags across all notes (for datalist autocomplete)
let _mde = null;     // EasyMDE instance (created on DOMContentLoaded)
let _loading = false; // suppress dirty tracking while Xojo populates fields

function postToXojo(handler, body) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers[handler]) {
    window.webkit.messageHandlers[handler].postMessage(body);
  }
}

// ── Called from Xojo ──────────────────────────────────────────────────────

function loadNote(note) {
  _note = note;
  _loading = true;  // CodeMirror fires 'change' on programmatic value() —
                    // don't let that register as user edits
  document.getElementById('titleInput').value = note.title || '';
  _setBodyValue(note.body || '');
  document.getElementById('tagsInput').value = (note.tags || []).join(', ');
  document.getElementById('btnDelete').style.display = note.exists ? '' : 'none';
  _applyScopeUI(note.scope || 'all', note.docs_version || '');
  const meta = document.getElementById('footerMeta');
  if (meta && note.docs_version) meta.textContent = 'Saved with ' + note.docs_version + ' docs';
  setMode(note.exists && note.body ? 'preview' : 'edit');
  _loading = false;
  _dirty = false;
}

// Relevance: 'all' (global — never flagged stale) or 'version' (tied to the
// note's docs_version). The "Specific version" label carries the version so the
// choice is unambiguous.
function _applyScopeUI(scope, version) {
  const sel = document.getElementById('scopeSelect');
  if (!sel) return;
  const versionOpt = sel.querySelector('option[value="version"]');
  if (versionOpt) {
    versionOpt.textContent = version ? ('Only ' + version) : 'Specific version';
  }
  sel.value = (scope === 'version') ? 'version' : 'all';
}

function onScopeChange() {
  // Switching to version scope stamps the note with the current docs_version so
  // it's tied to a concrete version; switching to all clears the staleness path.
  setDirty(true);
}

function _bodyValue() {
  return _mde ? _mde.value() : document.getElementById('bodyInput').value;
}

function _setBodyValue(v) {
  if (_mde) _mde.value(v);
  else document.getElementById('bodyInput').value = v;
}

function loadTagSuggestions(tags) {
  _allTags = tags || [];
  let dl = document.getElementById('tagDatalist');
  if (!dl) {
    dl = document.createElement('datalist');
    dl.id = 'tagDatalist';
    document.body.appendChild(dl);
    document.getElementById('tagsInput').setAttribute('list', 'tagDatalist');
  }
  dl.innerHTML = '';
  _allTags.forEach(t => {
    const opt = document.createElement('option');
    opt.value = t;
    dl.appendChild(opt);
  });
}

function showSuggestedTags(tags) {
  const wrap = document.getElementById('suggestedTags');
  if (!wrap) return;
  wrap.innerHTML = '';
  (tags || []).forEach(t => {
    const current = currentTagList();
    if (current.includes(t)) return;
    const pill = document.createElement('button');
    pill.className = 'suggested-tag';
    pill.textContent = '+ ' + t;
    pill.title = 'Add suggested tag';
    pill.onclick = () => {
      const list = currentTagList();
      if (!list.includes(t)) list.push(t);
      document.getElementById('tagsInput').value = list.join(', ');
      pill.remove();
      setDirty(true);
    };
    wrap.appendChild(pill);
  });
}

function showStalenessBanner(version) {
  const b = document.getElementById('stalenessBanner');
  const t = document.getElementById('stalenessText');
  if (t && version) t.textContent = '⚠️ This note was saved with Xojo ' + version + ' docs. The API may have changed.';
  if (b) b.style.display = '';
}

function hideStalenessBanner() {
  const b = document.getElementById('stalenessBanner');
  if (b) b.style.display = 'none';
}

// ── User actions ──────────────────────────────────────────────────────────

function currentFields() {
  const scopeSel = document.getElementById('scopeSelect');
  return {
    title: document.getElementById('titleInput').value.trim(),
    body: _bodyValue(),
    tags: currentTagList().join(','),
    scope: scopeSel ? scopeSel.value : 'all',
  };
}

function currentTagList() {
  return document.getElementById('tagsInput').value
    .split(',').map(t => t.trim()).filter(t => t !== '');
}

function saveNote() {
  const f = currentFields();
  if (!f.title) { f.title = 'Untitled note'; }
  postToXojo('saveNote', JSON.stringify(f));
  _dirty = false;
}

// Called by Xojo only after DBHelper.SaveNote succeeded — the flash is
// confirmation of a real write, not of the button click.
let _savedFlashTimer = null;
function noteSaved() {
  const meta = document.getElementById('footerMeta');
  if (!meta) return;
  if (_savedFlashTimer) clearTimeout(_savedFlashTimer);
  if (meta.dataset.restore === undefined) meta.dataset.restore = meta.textContent;
  meta.textContent = '✓ Saved';
  meta.classList.add('saved-flash');
  _savedFlashTimer = setTimeout(() => {
    meta.textContent = meta.dataset.restore || '';
    delete meta.dataset.restore;
    meta.classList.remove('saved-flash');
    _savedFlashTimer = null;
  }, 2000);
}

function deleteNote() {
  // Confirmation happens on the Xojo side (native MessageDialog) —
  // WKWebView never shows JS confirm() without a UI-delegate, it just
  // returns false.
  postToXojo('deleteNote', '');
}

function markAsReviewed() {
  postToXojo('markAsReviewed', '');
  hideStalenessBanner();
}

function dismissStaleness() {
  postToXojo('dismissStaleness', '');
  hideStalenessBanner();
}

function setDirty(val) {
  _dirty = !!val;
  postToXojo('setDirty', JSON.stringify(Object.assign({ dirty: _dirty }, currentFields())));
}

// ── Edit / Preview modes ──────────────────────────────────────────────────

function setMode(m) {
  _mode = m;
  document.getElementById('editPanel').classList.toggle('hidden', m === 'preview');
  document.getElementById('previewPanel').classList.toggle('hidden', m !== 'preview');
  if (m === 'preview') renderPreview();
  // CodeMirror rendered while hidden is blank until refreshed.
  else if (_mde) setTimeout(() => _mde.codemirror.refresh(), 0);
  document.getElementById('btnEdit').classList.toggle('active', m === 'edit');
  document.getElementById('btnPreview').classList.toggle('active', m === 'preview');
}

function renderPreview() {
  const body = _bodyValue();
  const panel = document.getElementById('previewPanel');
  if (typeof marked !== 'undefined' && typeof sanitizeHTML === 'function') {
    panel.innerHTML = sanitizeHTML(marked.parse(body));
  } else {
    panel.textContent = body;
  }
}

function onBodyInput() {  // fallback path only — EasyMDE has its own change handler
  setDirty(true);
  if (_mode !== 'edit') renderPreview();
}

// document.execCommand('selectAll') selects the page body, not CodeMirror's
// own buffer — CodeMirror keeps its own selection model and ignores it.
function selectAllInEditor() {
  if (_mde && _mode === 'edit') {
    _mde.codemirror.execCommand('selectAll');
  } else {
    document.execCommand('selectAll');
  }
}

// ── Init ──────────────────────────────────────────────────────────────────

document.addEventListener('DOMContentLoaded', () => {
  if (typeof EasyMDE !== 'undefined') {
    _mde = new EasyMDE({
      element: document.getElementById('bodyInput'),
      autoDownloadFontAwesome: false,  // WebView has no network — icons are CSS glyphs
      spellChecker: false,             // would fetch dictionaries from a CDN
      status: false,
      placeholder: 'Write in Markdown…',
      toolbar: ['bold', 'italic', 'heading', '|', 'quote', 'code', 'unordered-list', 'ordered-list', '|', 'link', 'table'],
      // Our own Edit/Preview toggle replaces EasyMDE's preview modes.
      shortcuts: { togglePreview: null, toggleSideBySide: null, toggleFullScreen: null },
      tabSize: 2,
      indentWithTabs: false,
    });
    _mde.codemirror.on('change', () => {
      if (_loading) return;
      setDirty(true);
      if (_mode === 'preview') renderPreview();
    });
  }
  postToXojo('editorReady', '');
});
