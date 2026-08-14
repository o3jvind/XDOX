# Changelog

All notable changes to XDOX are documented here. Versions follow
`MAJOR.MINOR.PATCH`; see `RELEASING.md` for the tagging convention.

## [0.2.0] — Unreleased

MBS Xojo Plugins documentation is now indexed and searchable alongside the
built-in Xojo docs, plus retrieval-quality fixes surfaced while building it.

### Added

- **MBS docset ingestion** (`MBSDocsetParser`, `MBSIndexerThread`,
  `MBSIndexer`): **Tools → Index MBS Docs…** lets you point at a downloaded
  MBS Xojo Plugins Dash docset (`MBS.docset`) and index it into the same
  chunk/embedding pipeline as the Xojo docs. The whole `Documents/` folder is
  scanned directly via `FileListMBS` rather than trusting the docset's own
  `docSet.dsidx` index — about a third of the docset's HTML files (including
  `DesktopWKWebViewControlMBS`'s own method pages) are never referenced by
  the index despite holding real content, so an dsidx-only scan silently
  missed them. A `.docset` bundle is picked via an `OpenFileDialog` filtered
  to the extension, not a folder picker — macOS folder pickers can't select
  or navigate into bundles.
  - **Incremental re-indexing**: a new `content_hash` column
    (`chunks.content_hash`) lets a later MBS docset update skip re-embedding
    every chunk whose text hasn't changed — only new/edited entries hit the
    embedding server. On the second full run this session, 8,802 of 60,435
    chunks were skipped as unchanged.
  - MBS chunks carry their own `docs_version` sentinel (`"mbs"`) instead of
    the version-independent `''` used by curated migration chunks — sharing
    `''` meant a routine Xojo-docs reindex (`ClearChunksForVersion`) silently
    deleted all indexed MBS content, and `"mbs"` briefly surfaced as a fake
    "orphaned Xojo version" in the housekeeping dialog since it sorted ahead
    of real version strings. Both are fixed; `DBHelper.IndexedVersions()` now
    explicitly excludes it.
  - The HTML `<table class=FunctionHeaderTable>` (Type/Topic/Plugin/Version/
    platform columns) that accompanies every documented member is rewritten
    into `Key: Value` lines before general tag-stripping runs, instead of
    linearizing into two disconnected columns of words with no header-to-
    value pairing — without this, nothing in the indexed text said whether a
    given member was a method, property, or event.
  - Retrieval now applies a flat score boost when a question names a chunk's
    class exactly (`Retrieval.ExtractClassName` + `kClassNameBoost`): cosine
    similarity alone couldn't reliably separate similarly-named MBS classes
    (e.g. `DesktopWKWebViewControlMBS` vs `DesktopWebView2ControlMBS`, ~0.75
    vs ~0.77) within the top few retrieved chunks. Ported to XMCP's
    `SemanticSearch` to keep both sides of the scoring recipe in sync.

### Changed

- **Schema migrations**: `DBHelper.InitDB` no longer wipes the whole database
  on every `kSchemaVersion` bump. A release with real users now exists, so
  from schema 4 onward, changes migrate in place (see `MigrateSchema`)
  instead of deleting notes and all indexed chunks. Only a DB below schema 4
  still gets the old recreate-from-template treatment, once.

## [0.1.1] — 2026-08-13

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
