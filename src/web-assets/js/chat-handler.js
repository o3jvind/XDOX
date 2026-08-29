// Chat message rendering — user bubbles, assistant bubbles, error states.
// Depends on: marked (global), sanitizeHTML, postToXojo, addSaveNoteButton, lastUserMessage.

let currentAssistantBubble = null;
let currentRawText = '';

function showUserMessage(text) {
  const div = document.createElement('div');
  div.className = 'message user';
  div.textContent = text;
  chatArea().appendChild(div);
  scrollToBottom();
}

function appendToken(text) {
  currentRawText += text;
  if (!currentAssistantBubble) {
    removeThinkingIndicator();
    currentAssistantBubble = document.createElement('div');
    currentAssistantBubble.className = 'message assistant';
    chatArea().appendChild(currentAssistantBubble);
  }
  currentAssistantBubble.innerHTML = sanitizeHTML(marked.parse(currentRawText));
  scrollToBottom();
}

function showCannedResponse(text) {
  // Deterministic non-streamed replies (e.g. the retrieval no-match gate)
  // must render as one atomic operation — calling appendToken(text) then
  // finalizeMessage() back-to-back with no real time between them (unlike
  // normal streaming, which is naturally paced by network-arriving SSE
  // chunks) risks the two separate EvaluateJavaScript calls racing in the
  // WebView's JS queue, observed live as the rendered bubble being cut off
  // mid-word. A single call has no such race.
  appendToken(text);
  finalizeMessage();
}

function finalizeMessage() {
  // Always clear the thinking spinner — on an early stop during request prep,
  // no assistant bubble was ever created (appendToken never ran), so this is
  // the only place the orphaned indicator gets removed.
  removeThinkingIndicator();
  if (!currentAssistantBubble) return;

  const bubble = currentAssistantBubble;
  const rawText = currentRawText;
  currentAssistantBubble = null;
  currentRawText = '';

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

function flagUnverifiedCode(symbols) {
  // Called from Xojo's OnCodeUnverified, AFTER finalizeMessage already ran
  // (currentAssistantBubble is null by then) — so this finds the most
  // recently rendered assistant bubble directly rather than relying on a
  // module-level reference to it. Attaches a warning banner rather than
  // touching the bubble's own rendered markdown, so nothing about the
  // model's actual reply is edited or hidden.
  if (!symbols || symbols.length === 0) return;
  const bubbles = chatArea().querySelectorAll('.message.assistant');
  if (bubbles.length === 0) return;
  const bubble = bubbles[bubbles.length - 1];
  if (bubble.querySelector('.code-unverified-warning')) return; // don't double-flag

  const warning = document.createElement('div');
  warning.className = 'code-unverified-warning';
  warning.textContent = 'This code could not be fully verified against the documentation — check before using: '
    + symbols.join(', ');
  bubble.appendChild(warning);
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

function showError(message) {
  removeThinkingIndicator();
  currentAssistantBubble = null;
  currentRawText = '';
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
