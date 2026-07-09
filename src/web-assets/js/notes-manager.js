// XDOX — notes sidebar.
// Xojo calls: loadNotes(notesArray) — array of
//   {id, title, preview, tags: [], version_warned, docs_version, updated}
// JS posts: newNote, openNote (id), deleteNote (id)

let _allNotes = [];
let _activeTags = [];   // '__stale__' is the internal value for ⚠️ Needs Review
let _noteSearchQuery = '';
let _notePortalMenu = null;

function loadNotes(notes) {
  _allNotes = notes || [];
  renderTagStrip();
  renderNotesList();
}

function filterNotes(query) {
  _noteSearchQuery = (query || '').toLowerCase();
  renderNotesList();
}

function _noteEsc(s) {
  const d = document.createElement('div');
  d.textContent = s == null ? '' : String(s);
  return d.innerHTML;
}

// ── Tag filter strip ──────────────────────────────────────────────────────

function renderTagStrip() {
  const strip = document.getElementById('tagFilterStrip');
  if (!strip) return;
  strip.innerHTML = '';

  const counts = {};
  let anyStale = false;
  _allNotes.forEach(n => {
    if (n.version_warned) anyStale = true;
    (n.tags || []).forEach(t => { counts[t] = (counts[t] || 0) + 1; });
  });

  if (anyStale) {
    strip.appendChild(_tagPill('__stale__', '⚠️ Needs review', 'tag-pill-stale'));
  }
  Object.keys(counts)
    .sort((a, b) => counts[b] - counts[a])
    .forEach(t => strip.appendChild(_tagPill(t, t, '')));
}

function _tagPill(value, label, extraClass) {
  const pill = document.createElement('button');
  pill.className = 'tag-filter-pill' + (extraClass ? ' ' + extraClass : '')
    + (_activeTags.includes(value) ? ' tag-pill-active' : '');
  pill.textContent = label;
  pill.onclick = () => toggleTagFilter(value);
  return pill;
}

function toggleTagFilter(tag) {
  const i = _activeTags.indexOf(tag);
  if (i >= 0) _activeTags.splice(i, 1);
  else _activeTags.push(tag);
  renderTagStrip();
  renderNotesList();
}

// ── Notes list ────────────────────────────────────────────────────────────

function renderNotesList() {
  const list = document.getElementById('notesList');
  if (!list) return;
  list.innerHTML = '';

  const filtered = _allNotes.filter(n => {
    for (const t of _activeTags) {
      if (t === '__stale__') {
        if (!n.version_warned) return false;
      } else if (!(n.tags || []).includes(t)) {
        return false;
      }
    }
    if (_noteSearchQuery) {
      const hay = ((n.title || '') + ' ' + (n.preview || '') + ' ' + (n.tags || []).join(' ')).toLowerCase();
      if (!hay.includes(_noteSearchQuery)) return false;
    }
    return true;
  });

  if (filtered.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'notes-empty';
    if (_allNotes.length === 0) {
      empty.innerHTML = '<p>No notes yet.</p><p>Ask a question and click "Save as note" on any answer to start your personal Xojo knowledge base.</p>';
    } else {
      empty.innerHTML = '<p>No notes match your filter.</p>';
    }
    list.appendChild(empty);
    return;
  }

  filtered.forEach(n => {
    const item = document.createElement('div');
    item.className = 'note-item';
    item.dataset.id = n.id;

    const header = document.createElement('div');
    header.className = 'note-title-row';
    header.innerHTML =
      (n.version_warned ? '<span class="note-warning" title="Written for ' + _noteEsc(n.docs_version) + '">⚠️</span>' : '')
      + '<span class="note-title">' + _noteEsc(n.title) + '</span>';
    const menuBtn = document.createElement('button');
    menuBtn.className = 'note-menu-btn';
    menuBtn.textContent = '⋯';
    menuBtn.onclick = (e) => { e.stopPropagation(); toggleNoteMenu(e, n); };
    header.appendChild(menuBtn);
    item.appendChild(header);

    if (n.preview) {
      const prev = document.createElement('div');
      prev.className = 'note-preview';
      prev.textContent = n.preview;
      item.appendChild(prev);
    }

    const meta = document.createElement('div');
    meta.className = 'note-meta';
    const tagsWrap = document.createElement('span');
    tagsWrap.className = 'note-tags';
    (n.tags || []).forEach(t => {
      const pill = document.createElement('span');
      pill.className = 'note-tag';
      pill.textContent = t;
      tagsWrap.appendChild(pill);
    });
    meta.appendChild(tagsWrap);
    const date = document.createElement('span');
    date.className = 'note-date';
    date.textContent = relativeDate(n.updated);
    meta.appendChild(date);
    item.appendChild(meta);

    item.onclick = () => postToXojo('openNote', n.id);
    list.appendChild(item);
  });
}

// ── ⋯ menu (Edit / Delete) — body-appended portal ────────────────────────

function toggleNoteMenu(e, note) {
  closeAllNoteMenus();
  const menu = document.createElement('div');
  menu.className = 'note-portal-menu';

  const edit = document.createElement('button');
  edit.textContent = 'Edit';
  edit.onclick = () => { closeAllNoteMenus(); postToXojo('openNote', note.id); };
  menu.appendChild(edit);

  const del = document.createElement('button');
  del.className = 'danger';
  del.textContent = 'Delete';
  del.onclick = () => {
    closeAllNoteMenus();
    // Confirmation is a native MessageDialog on the Xojo side — JS
    // confirm() silently returns false in WKWebView.
    postToXojo('deleteNote', note.id);
  };
  menu.appendChild(del);

  const rect = e.currentTarget.getBoundingClientRect();
  const menuHeight = 72;
  menu.style.position = 'fixed';
  menu.style.left = Math.max(4, rect.right - 110) + 'px';
  menu.style.top = (rect.bottom + menuHeight > window.innerHeight
    ? rect.top - menuHeight : rect.bottom + 2) + 'px';
  document.body.appendChild(menu);
  _notePortalMenu = menu;
}

function closeAllNoteMenus() {
  if (_notePortalMenu) { _notePortalMenu.remove(); _notePortalMenu = null; }
}

document.addEventListener('click', closeAllNoteMenus);

// ── Relative dates ────────────────────────────────────────────────────────

function relativeDate(iso) {
  if (!iso) return '';
  const then = new Date(iso);
  if (isNaN(then.getTime())) return '';
  const secs = Math.floor((Date.now() - then.getTime()) / 1000);
  if (secs < 90) return 'just now';
  const mins = Math.floor(secs / 60);
  if (mins < 60) return mins + ' min ago';
  const hours = Math.floor(mins / 60);
  if (hours < 24) return hours + (hours === 1 ? ' hour ago' : ' hours ago');
  const days = Math.floor(hours / 24);
  if (days === 1) return 'yesterday';
  if (days < 14) return days + ' days ago';
  const weeks = Math.floor(days / 7);
  if (weeks < 9) return weeks + ' weeks ago';
  const months = Math.floor(days / 30);
  if (months < 12) return months + ' months ago';
  const years = Math.floor(days / 365);
  return years + (years === 1 ? ' year ago' : ' years ago');
}
