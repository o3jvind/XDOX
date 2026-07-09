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
