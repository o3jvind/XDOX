# XDOX

**A fully local AI assistant for Xojo development.** XDOX chats about the Xojo documentation you already have installed, remembers your own notes, and answers with retrieval-augmented context — all on your Mac, with nothing leaving your machine.

Notes are the part that grows over time: a fix or convention you write down once is retrieved into later answers automatically, so you don't re-derive it. The docs describe how Xojo works; your notes record how you work with it.

XDOX is also the knowledge-base engine for the wider ecosystem: it indexes the docs, computes embeddings, and hosts the embedding server that XMCP (the companion MCP server) uses. Because XMCP speaks the standard Model Context Protocol, any MCP-capable coding agent — Claude Code, OpenAI's Codex CLI, Claude Desktop, and others — searches the exact same knowledge base you curate here.

## Features

- **Chat with the Xojo docs** — streaming answers from a local LLM, grounded in hybrid retrieval (semantic embeddings + BM25 full-text) over the official documentation installed with the Xojo IDE.
- **MBS Xojo Plugins docs** — index a downloaded [MBS](https://www.monkeybreadsoftware.net/) Dash docset (Tools → Index MBS Docs…) so plugin classes, methods, and FAQs are searchable alongside the built-in docs. Re-indexing after an MBS update only re-embeds changed entries.
- **Personal notes** — write notes in Markdown (edit/preview), with auto-tag suggestions and semantic search. Notes are retrieved alongside the docs and take precedence where they disagree, so your own conventions and fixes inform the answer. The same notes are available to coding agents through XMCP.
- **Multiple Xojo versions** — index several installed Xojo versions side by side and switch which one chat/retrieval uses; old versions can be cleaned up when uninstalled.
- **Staleness tracking** — notes can be marked *global* (version-independent) or tied to a specific Xojo version; only version-specific notes are flagged ⚠️ for review when a newer version is indexed, and the model is told to caveat them.
- **Model choice** — a curated catalog of six chat models from five vendors (Alibaba, Google, Microsoft, OpenAI, Mistral), downloaded straight from Hugging Face. Pick what fits your Mac's RAM.
- **100 % local** — inference runs on a bundled [llama.cpp](https://github.com/ggml-org/llama.cpp) server over loopback HTTP. No API keys, no cloud, no telemetry.

## How it works

```text
┌─────────────────────────── XDOX.app ───────────────────────────┐
│  Window1 (DesktopWKWebViewControlMBS)                           │
│    chat UI · notes sidebar · model picker      (src/web-assets) │
│                          │ JS bridge                            │
│  ChatView / XDOXSession ── SSE ──► llama-server :8091 (chat)    │
│  Indexer / Embedder ────── HTTP ─► llama-server :8089 (embed)   │
│                          │                          ▲           │
│  SQLite (WAL)  ~/Library/…/xdox.db                  │           │
│    chunks+docs_version · embeddings · chunks_fts · notes+scope  │
└─────────────────────────────────────────────────────┼───────────┘
                                                      │
              XMCP (MCP server for coding agents) ────┘
              reads xdox.db + queries :8089 directly
```

- **Indexing:** on first run (and whenever a newly-installed version is detected) XDOX parses the documentation bundle (`llms-full.txt`) installed with the Xojo IDE, chunks it, and embeds every chunk with `nomic-embed-text-v1.5` (768-dim). Multiple Xojo versions can be indexed side by side (each chunk carries a `docs_version`); adding a version is non-destructive to the others. Indexing is resumable; if the embedding server isn't up yet, the index completes BM25-only and embeddings are backfilled silently.
- **Retrieval:** each question is scored 0.7·cosine + 0.3·normalised BM25 across docs and notes, with neighbour-chunk expansion, filtered to the active Xojo version (plus version-independent chunks). If the embedding server is down, search falls back to keyword-only — the status bar shows which tier is active.
- **Chat:** OpenAI-style streaming completions against the bundled `llama-server`. Conversation history lives in Xojo; the RAG context is rebuilt fresh for every message, with a token guard that trims context before it overflows the model's window.

## Chat models

| Model | Vendor | Download | Runs on |
| --- | --- | --- | --- |
| Qwen3 4B Instruct (Q4) — *recommended* | Alibaba | 2.3 GB | 8 GB Macs |
| Gemma 3 4B (Q4) | Google | 2.3 GB | 8 GB Macs |
| Phi-4 Mini 3.8B (Q4) | Microsoft | 2.3 GB | 8 GB Macs |
| Qwen2.5 Coder 7B (Q6) | Alibaba | 5.8 GB | 16 GB+ Macs |
| GPT-OSS 20B (MXFP4) | OpenAI | 11.3 GB | 16 GB+ Macs |
| Mistral Small 3.2 24B (Q4) | Mistral | 13.3 GB | 24 GB+ Macs |

The embedding model (`nomic-embed-text-v1.5` Q8_0) is fixed — the database schema and XMCP both assume it.

## Requirements

- macOS on Apple Silicon
- [Xojo 2026r1+](https://www.xojo.com) with local documentation installed (XDOX indexes it)
- [MBS Xojo Plugins](https://www.monkeybreadsoftware.de) installed in the IDE (WebKit + Cocoa plugins), with a licence

## Getting started (development)

1. Clone the repo and enable the secrets guard hook on this machine:

   ```bash
   git config core.hooksPath .githooks
   ```

2. Add your MBS licence to the macOS keychain (used by debug builds):

   ```bash
   security add-generic-password -s MBS -a Owner -w "Your Name"
   security add-generic-password -s MBS -a Product -w "Your Product"
   security add-generic-password -s MBS -a Year -w "2026"
   security add-generic-password -s MBS -a Key -w "YOUR_KEY"
   ```

3. Debug builds need a local `llama-server` binary (arm64) at `Binaries/llama-server` — it's gitignored and not distributed in this repo. Build it yourself from [llama.cpp](https://github.com/ggml-org/llama.cpp) or drop in a prebuilt arm64 binary.

4. Open `XDOX.xojo_project` in the Xojo IDE and Run. On first launch XDOX indexes the docs, then prompts you to download a chat model.

There is no CLI build pipeline — run, debug, and build happen in the Xojo IDE.

### Release builds

Release builds embed the MBS credentials instead of reading the keychain, and package the `llama-server` binary into the app automatically via the IDE's Build Automation step:

```bash
./inject-secrets.sh     # writes real credentials into SecretsBuiltin.xojo_code
# build in the Xojo IDE (⌘B) — revert SecretsBuiltin to disk first if the project was open
./restore-secrets.sh    # restore the empty stub immediately after
```

A pre-commit hook blocks any commit where `SecretsBuiltin.xojo_code` still contains injected credentials.

## Data locations

| What | Where |
| --- | --- |
| Database (chunks, embeddings, notes) | `~/Library/Application Support/<bundle-id>/xdox.db` |
| Downloaded models | `~/Library/Application Support/<bundle-id>/models/` |
| Debug log | `~/Library/Application Support/<bundle-id>/XDOX_debug.log` |
| Xojo docs (read-only input) | `~/Library/Application Support/Xojo/Xojo/` |

## Ecosystem: XDOX and XMCP

XMCP is the companion MCP server that gives MCP-capable coding agents — Claude Code, OpenAI's Codex CLI, Claude Desktop, and any other Model Context Protocol client — `search_docs` and `search_notes` tools over the same knowledge base. The two programs never talk to each other directly — the contract between them is the shared SQLite database plus one port:

| Concern | Owner |
| --- | --- |
| Indexing, embeddings, notes, all database writes | XDOX |
| Both llama-server processes (chat `8091`, embeddings `8089`) | XDOX |
| MCP tools, search-time scoring, fallbacks | XMCP (reads `xdox.db`, queries `8089`) |

### Why semantic search needs XDOX running

Every docs chunk and note is stored in the database with its embedding ("meaning fingerprint") precomputed. But answering a search semantically also requires embedding the *question* at search time — and that needs the embedding server on port `8089`, which only XDOX starts. The database alone is enough for keyword search; the live server is what upgrades it to meaning-based search.

### Behaviour when XDOX is running

- Both llama-servers are up. XDOX's chat and XMCP's search tools deliver the same hybrid quality: 0.7·semantic + 0.3·keyword, over docs *and* your notes.
- XDOX's status bar shows "Semantic search" (green); XMCP result headers say `(semantic, Xojo <version>)`.
- Quitting XDOX (⌘Q) shuts down both servers — including servers a previous instance left behind and the current one merely adopted.

### Behaviour when XDOX is not running

XMCP degrades through tiers, checked fresh on every search:

| Tier | Requires | Quality |
| --- | --- | --- |
| 1. Semantic (hybrid) | `xdox.db` + embedding server on `8089` | Understands meaning — "first 10 characters of a string" finds `String.Left` |
| 2. Keyword (BM25) | only `xdox.db` | The words must actually appear in the text |
| 3. Plain text scan | only the Xojo docs (`llms-full.txt`) | Last resort, substring matching |

- The downgrade and upgrade are automatic: start XDOX and XMCP's searches return to semantic within ~30 seconds — no restart, and the order the two programs start in never matters. (XMCP re-probes the database and the server lazily at search time, rate-limited while they're down.)
- Notes exist only in `xdox.db`, so `search_notes` works in tiers 1–2 but is semantic only in tier 1.
- Practical rule of thumb: keep XDOX open in the background while coding — it costs nothing and gives your coding agent the best search (and your notes are curated there anyway).

### Multiple Xojo versions

XDOX can index several installed Xojo versions side by side in the one `xdox.db` (schema v3). Rather than a destructive re-index on every version bump, each docs chunk carries a `chunks.docs_version` column, and a **version-independent** set of curated migration chunks is stored with `docs_version = ''` so it surfaces regardless of the active version.

- **Active version.** `metadata.active_docs_version` names the version chat/retrieval currently filters on (a status-bar dropdown lets the user switch it; it defaults to the newest indexed version). Retrieval restricts docs to `docs_version = <active> OR docs_version = ''`.
- **Housekeeping.** At launch XDOX offers to delete indexed versions whose Xojo docs folder is no longer installed (dismissable; `metadata.skip_orphan_cleanup = '1'` turns it off).
- **Notes and version relevance.** Each note has a `notes.scope` of `all` (global — version-independent, **never** flagged stale) or `version` (tied to `notes.docs_version`). Only `version`-scoped notes participate in staleness warnings on a re-index. A notes-search toggle (`metadata.notes_search_scope`) chooses between searching all notes or only global + active-version notes.

> **XMCP must mirror this.** Since XMCP reads `xdox.db` directly, its `SemanticSearch`/`search_docs` must add the same `WHERE docs_version = <active> OR docs_version = ''` filter (reading `metadata.active_docs_version`), and `search_notes` should honour `notes.scope` the same way. Until XMCP is updated it will return chunks blended across versions. Coordinate the two releases.

### Lifecycle details

- **IDE debug-stop** (in Xojo) skips the app's `Closing` event and leaves the llama-servers running as orphans. This is expected: the next XDOX launch detects a healthy server with the right model on the known port (a `GET /props` probe) and *adopts* it instead of starting a duplicate. A real quit (⌘Q) cleans up adopted servers too.
- **Fixed ports are deliberate.** `8091`/`8089` never change precisely so that orphan adoption and XMCP's hardcoded address keep working.
- **Scoring recipe duplication is deliberate.** The hybrid formula (0.7/0.3, note relevance floor 0.45) exists in both XDOX (`Retrieval`) and XMCP (`SemanticSearch`) by choice — a shared search API was considered and rejected as more moving parts than it saves. If the recipe ever changes on one side, port the change to the other.
- **The per-version filter is duplicated too.** Like the scoring recipe, the `docs_version`/`scope` filtering lives in both `Retrieval` (XDOX) and `SemanticSearch` (XMCP). Port any change to both.

## Credits

- [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT) — bundled `llama-server` binary powers all inference
- [nomic-embed-text-v1.5](https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF) — embedding model
- [marked](https://github.com/markedjs/marked) (MIT) — Markdown rendering in the chat UI (vendored)
- [EasyMDE](https://github.com/Ionaru/easy-markdown-editor) (MIT) — Markdown editor in the note window (vendored)
- Chat models are downloaded from their respective Hugging Face repos under their own licences (Apache 2.0, MIT, Gemma, Qwen)
