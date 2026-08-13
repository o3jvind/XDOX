# Changelog

All notable changes to XDOX are documented here. Versions follow
`MAJOR.MINOR.PATCH`; see `RELEASING.md` for the tagging convention.

## [0.1.1] — Unreleased

Security and robustness fixes from an external code review, verified
against the code and, where practical, against a running debug build
before landing.

### Security

- **XSS in the chat/note renderer** (`src/web-assets/js/sanitize.js`):
  the link-href check only blocked the exact lowercase string
  `javascript:`, missing case, whitespace, and control-character
  variants. Replaced with a `URL()`-based protocol allowlist
  (`http:`/`https:`/`mailto:`). The sanitizer's "unwrap disallowed
  element" path also skipped re-sanitizing the children it moved up,
  letting filtered attributes/links survive inside a nested disallowed
  container — fixed to recurse after unwrapping.
- **Unverified model downloads**: chat/embedding models were only
  checked against HTTP status and byte count. Downloads are now
  verified against a pinned SHA-256 (shelled out to `shasum`, since the
  files run up to ~17 GB) before being installed; a mismatch deletes
  the file instead of running it.
- **Hardened Runtime inconsistency**: the Xojo IDE's own project
  signing step had Hardened Runtime disabled, while `build-release.sh`
  already re-signed everything correctly for actual releases — brought
  the IDE setting in line so the declared policy isn't misleading for
  anyone signing outside the release script.

### Reliability

- **Model server crash detection** (`ModelManager`) only armed while a
  server was still starting up — a chat or embedding server that
  crashed *after* becoming ready was never detected, so the UI kept
  reporting "ready" while every request failed. Detection now covers
  the whole server lifetime, resets state, and notifies the UI (the
  embedding server previously gave no UI signal on crash at all).
  Adopted servers (reused from a prior debug session, no process
  handle to watch) get a periodic async `/health` watchdog instead.
- **SSE stream truncation** (`XDOXSession`): if the model server closed
  the connection right after its last `data: ...` line without a
  trailing newline, that line was silently dropped — cutting off the
  end of a reply. The final flush now treats a still-buffered line as
  complete instead of holding it back for data that will never arrive.
- **IndexerThread transaction safety**: an exception raised mid-index
  left the SQLite transaction open and the worker's connection
  unclosed, and the version being reindexed could be wiped by
  `ClearChunksForVersion` before the replacement rows were committed —
  a failure partway through left neither the old nor the new index
  intact. Deletion, inserts, and link updates are now one transaction
  with guaranteed rollback/close on error.
- **Retrieval cache race** (`Retrieval`): the query-result and
  embedding caches are module-global state read on a worker thread
  (`ChatPrepThread`) and cleared from the main thread on
  reindex/version/model switches, with no synchronization. Added a
  lock, plus a generation counter so a search that straddles a
  `ClearCache` can't write a stale result back into the freshly
  cleared cache.
- **`selectDocsVersion` bridge handler** (`ChatView`) accepted any
  non-empty string from the JS side instead of validating it against
  the indexed version list.

## [0.1.0] — first tagged build

Initial public build: local RAG chat over the Xojo docs, notes with
semantic search, multi-version indexing, model catalog, signed-release
tooling.
