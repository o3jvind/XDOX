# Changelog

All notable changes to XDOX are documented here. Versions follow
`MAJOR.MINOR.PATCH`; see `RELEASING.md` for the tagging convention.

## [0.2.0] — 2026-09-19

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
- **Native docs and MBS docs are searched, gated, and rendered as two fully
  independent pools** instead of one merged search
  (`Retrieval.SearchOnePool`/`MatchStatusForPool`/`BuildUserFacingAnswerForPool`).
  Each pool computes its own rerank score and gates itself against
  `Reranker.kNoMatchThreshold` independently, fixing a generic native chunk
  (e.g. "What is Xojo?") outranking a strong MBS match at the source instead
  of filtering it out after the fact. `XDOXSession` runs one `ChatPrepThread`
  per pool and posts each reply as soon as its own search finishes; the chat
  UI renders up to two bubbles per turn in true completion order, each with
  its own "Searching Xojo docs…"/"Searching MBS docs…" status, and a pool
  that finds nothing posts an immediate "no documentation found" bubble
  rather than staying silent until the whole turn resolves. A docs-search-
  scope selector (Xojo + MBS / Xojo only / MBS only) lets you constrain
  which pool(s) run.
- **Doc parsing and embedding are parallelized.** `MBSDocsetParser` and
  `RSTParser` split work across `System.CoreCount` preemptive Threads
  pulling from a shared queue (`MBSFileQueue`) instead of a fixed per-worker
  file slice, so one worker landing on several large/slow files no longer
  leaves the others idle at the end of a run. The embed phase replaces its
  serial loop with a single-writer/queue pipeline (`EmbedWriter` plus a pool
  of `EmbedWorker`s) matched to the embedding server's `--parallel` slot
  count, avoiding the SQLite WAL write-lock contention an earlier
  multi-connection design hit live. The slot count itself is sized from
  physical RAM (`ModelManager.ChooseEmbedParallelCount`) rather than a fixed
  constant, though it's currently capped at 2 — testing up to 8 slots on a
  32GB M1 Max showed no throughput gain past 2, since embedding is
  GPU-compute-bound on this hardware, not slot-count-bound.
- Indexing gained a **Pause button** (`IndexProgressWindow`) for the embed
  phase: stopping only halts new claims, already-claimed batches still embed
  and write normally, and unclaimed chunks resume automatically on the next
  reindex.
- Chat/note links now open in the OS default browser via the existing
  `openURL` bridge handler instead of `target="_blank"`, which has no
  meaningful effect inside a `WKWebView`.

### Removed

- **The chat-completion model layer** (`ModelManager`'s catalog, download
  pipeline, and server lifecycle for a reply-generating LLM) is fully
  removed. Replies had already stopped using it in favor of rendering
  retrieved documentation directly, after it fabricated facts and code too
  often to trust — this removes the now-dormant infrastructure, which had
  drifted out of sync with `README.md`. `AutoStart` now unconditionally
  downloads/starts only the embedding and reranker models, with a non-modal
  first-run disclosure banner replacing the old model picker.

### Fixed

- **Residual non-determinism in MBS docset reindexing**: two collision
  shapes were conflated when disambiguating same-title chunks
  (`MBSIndexerThread.DisambiguateSplitSources`) — a single oversized page's
  own stable `Chunker` split, and genuinely different pages that happen to
  render the same title (e.g. many FAQ pages titled "FAQ"). Chunks now carry
  an `OriginGroupID` so the two cases are told apart correctly instead of by
  title-suffix shape alone, which had wrongly treated some cross-file
  collisions as already-stable and skipped sorting them.
  - A smaller, separate race remains **open**: concurrent 10-worker MBS
    parsing occasionally leaves a small number of chunks (~0.1-0.2%) with an
    HTML entity left undecoded (e.g. a stray `&quot;`) that varies between
    otherwise-identical reindexes of an unchanged docset. No content is lost
    or corrupted — the practical cost is a handful of chunks re-embedded
    unnecessarily per run. `anchorsByFile`/`anchorSet` were moved to
    `AtomicDictionaryMBS` and `MBSFileQueue`'s array reads moved inside its
    lock as hardening, but neither closed the gap; root cause still open.
- RSTParser's code-block indentation: trimming a code line discarded its own
  relative indentation along with the wrapping `.rst` file's indentation,
  flattening nested code structure (e.g. an `If` body one level deeper than
  its enclosing block). Now only the block's own leading indent is cut.

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
