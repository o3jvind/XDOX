// Chat message rendering — user bubbles, assistant bubbles, error states.
// Depends on: marked (global), sanitizeHTML, postToXojo, addSaveNoteButton, lastUserMessage.

// Split-bubble redesign (reactive-coalescing-thimble plan, 2026-08-30): up to
// two independent assistant bubbles can be in flight for one turn — one per
// pool ("native"/"mbs") — each arriving whenever ITS OWN search completes,
// not in lockstep. pendingBubbles replaces the old single currentAssistantBubble/
// currentRawText module-level pair (which could only track one in-flight
// bubble at a time) with one entry per pool. Finalizing one pool's bubble no
// longer flips isGenerating/setSendState — that's main.js's onTurnDone,
// called only once ALL expected pools have completed (see main.js).
let pendingBubbles = {}; // pool -> { bubble, rawText }

function showUserMessage(text) {
  const div = document.createElement('div');
  div.className = 'message user';
  div.textContent = text;
  chatArea().appendChild(div);
  scrollToBottom();
}

function renderReplyForPool(pool, text) {
  removeSearchStatus(pool);
  const bubble = document.createElement('div');
  bubble.className = 'message assistant';
  bubble.innerHTML = sanitizeHTML(marked.parse(text));
  // Insert BEFORE the status container, not just appendChild — the status
  // container (still showing the OTHER pool's "Searching…" row, if any) is
  // created once up front and must stay pinned at the bottom as "what's
  // still coming," never sandwiched between two bubbles. Found live
  // (2026-08-30): appendChild alone put a later-arriving bubble AFTER the
  // still-visible status container, so a fast MBS bubble rendered ABOVE the
  // native pool's still-pending status row instead of below it.
  const container = document.getElementById('searchStatusContainer');
  if (container) {
    chatArea().insertBefore(bubble, container);
  } else {
    chatArea().appendChild(bubble);
  }
  pendingBubbles[pool] = { bubble: bubble, rawText: text };
  scrollToBottom();
}

function showCannedResponseForPool(pool, text) {
  // XDOXSession no longer calls the chat-completion model at all
  // (2026-08-29 redesign) — every reply, matched-documentation or
  // no-match alike, renders through this single atomic JS call rather
  // than token-by-token streaming. render+finalize happen as one call:
  // the original race this atomicity guards against was two calls for
  // the SAME bubble landing back-to-back in the WebView's JS queue with
  // no real time between them (pre-split-bubble era) — a different
  // pool's call, arriving independently whenever ITS OWN worker
  // finishes (seconds apart, not same-tick), targets its OWN bubble via
  // pendingBubbles and carries no analogous risk.
  renderReplyForPool(pool, text);
  finalizeMessageForPool(pool);
}

function finalizeMessageForPool(pool) {
  const pending = pendingBubbles[pool];
  if (!pending) return; // guards an edge case where no bubble was ever created
  delete pendingBubbles[pool];

  const bubble = pending.bubble;
  const rawText = pending.rawText;

  // Mark long bubbles as collapsible but start expanded — user collapses manually.
  if (bubble.scrollHeight > 320) {
    bubble.classList.add('bubble-collapsible');
  }

  // Action row: collapse + copy
  const actions = document.createElement('div');
  actions.className = 'message-actions';

  const collapseBtn = document.createElement('button');
  collapseBtn.className = 'bubble-collapse-btn';
  collapseBtn.title = 'Collapse / Expand';
  collapseBtn.textContent = '⌃';
  collapseBtn.addEventListener('click', () => {
    bubble.classList.toggle('bubble-collapsed');
    collapseBtn.textContent = bubble.classList.contains('bubble-collapsed') ? '⌄' : '⌃';
  });
  actions.appendChild(collapseBtn);

  const copyBtn = document.createElement('button');
  copyBtn.className = 'copy-button';
  copyBtn.title = 'Copy';
  copyBtn.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
    <rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/>
  </svg>`;
  copyBtn.addEventListener('click', () => {
    navigator.clipboard.writeText(rawText).then(() => {
      copyBtn.classList.add('copied');
      setTimeout(() => copyBtn.classList.remove('copied'), 1500);
    });
  });
  actions.appendChild(copyBtn);

  bubble.appendChild(actions);

  // Save as Note button — gets the raw markdown so the note keeps formatting.
  addSaveNoteButton(bubble, lastUserMessage, rawText);

  scrollToBottom();
}

const NO_MATCH_TEXT = {
  native: 'No native Xojo documentation was found for this.',
  mbs: 'No MBS plugin documentation was found for this.'
};

function showNoMatchForPool(pool) {
  // This pool's own search came up empty — rendered IMMEDIATELY (right
  // where its "Searching…" status row was, already cleared by the
  // OnPoolDone call Xojo makes just before this one), not held back until
  // the whole turn finishes. Same assistant-bubble styling as a real reply
  // (a plain italic line was tried first and looked inconsistent sitting
  // next to an actual bubble — feedback live, 2026-08-30) — not tied to
  // pendingBubbles since there's no copy/save-as-note action for it.
  const div = document.createElement('div');
  div.className = 'message assistant';
  div.textContent = NO_MATCH_TEXT[pool] || 'No documentation was found for this.';
  // Insert before the status container so the OTHER pool's still-pending
  // "Searching…" row stays pinned at the bottom — same reasoning as
  // renderReplyForPool's insertBefore.
  const container = document.getElementById('searchStatusContainer');
  if (container) {
    chatArea().insertBefore(div, container);
  } else {
    chatArea().appendChild(div);
  }
  scrollToBottom();
}

function showThinkingIndicator() {
  removeThinkingIndicator();
  const el = document.createElement('div');
  el.className = 'thinking-indicator';
  el.id = 'thinkingIndicator';
  for (let i = 0; i < 3; i++) {
    const dot = document.createElement('div');
    dot.className = 'thinking-dot';
    el.appendChild(dot);
  }
  chatArea().appendChild(el);
  scrollToBottom();
}

function removeThinkingIndicator() {
  const el = document.getElementById('thinkingIndicator');
  if (el) el.remove();
}

// Per-pool "Searching Xojo docs…" / "Searching MBS docs…" status, shown in
// the same thinking-indicator slot the old single spinner used — cleared
// per-pool as that pool's own bubble arrives (removeSearchStatus, called
// from renderReplyForPool), not all at once. See main.js's sendMessage for
// where these are created (it knows which pools were actually searched).
function showSearchStatus(statuses) {
  // statuses: array of { pool, text }
  removeThinkingIndicator();
  removeAllSearchStatus();
  const container = document.createElement('div');
  container.className = 'thinking-indicator search-status';
  container.id = 'searchStatusContainer';
  statuses.forEach(s => {
    const row = document.createElement('div');
    row.className = 'search-status-row';
    row.id = 'searchStatus-' + s.pool;

    const dots = document.createElement('span');
    dots.className = 'search-status-dots';
    for (let i = 0; i < 3; i++) {
      const dot = document.createElement('span');
      dot.className = 'thinking-dot';
      dots.appendChild(dot);
    }
    row.appendChild(dots);

    const label = document.createElement('span');
    label.textContent = s.text;
    row.appendChild(label);

    container.appendChild(row);
  });
  chatArea().appendChild(container);
  scrollToBottom();
}

function removeSearchStatus(pool) {
  const row = document.getElementById('searchStatus-' + pool);
  if (row) row.remove();
  const container = document.getElementById('searchStatusContainer');
  if (container && !container.hasChildNodes()) container.remove();
}

function removeAllSearchStatus() {
  const container = document.getElementById('searchStatusContainer');
  if (container) container.remove();
}

function showError(pool, message) {
  removeSearchStatus(pool);
  delete pendingBubbles[pool];
  const div = document.createElement('div');
  div.className = 'message assistant';
  div.style.borderColor = 'var(--color-danger)';
  div.textContent = message;
  chatArea().appendChild(div);
  scrollToBottom();
}

function chatArea() { return document.getElementById('chatArea'); }

function scrollToBottom() {
  const ca = chatArea();
  ca.scrollTop = ca.scrollHeight;
}
