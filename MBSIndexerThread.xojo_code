#tag Class
Public Class MBSIndexerThread
Inherits Thread
Implements MBSParseProgressDelegate

	#tag Method, Flags = &h0
		Constructor()
		  StopEmbeddingRequested = New StopSignal
		End Constructor
	#tag EndMethod

	#tag Property, Flags = &h0
		StopEmbeddingRequested As StopSignal
	#tag EndProperty

	#tag Property, Flags = &h0
		DocsetFolder As FolderItem
	#tag EndProperty

	#tag Property, Flags = &h0
		ProgressDelegate As IndexerDelegate
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mTransactionOpen As Boolean
	#tag EndProperty

	#tag Event
		Sub Run()
		  // Own connection, same reasoning as IndexerThread: WAL lets this writer
		  // run alongside the main thread's readers without two connections
		  // interleaving transactions on one shared handle.
		  Var db As SQLiteDatabase
		  mTransactionOpen = False
		  Try
		    db = DBHelper.OpenConnection
		    If db = Nil Then
		      AddUserInterfaceUpdate(New Pair("type", "error"), New Pair("msg", "Database not available"))
		      Return
		    End If

		    AddUserInterfaceUpdate(New Pair("type", "parsing"))
		    Var parser As New MBSDocsetParser
		    Var rawChunks() As DocChunk = parser.Parse(DocsetFolder, Self)
		    If rawChunks.Count = 0 Then
		      db.Close
		      AddUserInterfaceUpdate(New Pair("type", "error"), New Pair("msg", "No chunks produced from MBS docset — check it points at a MBS.docset bundle."))
		      Return
		    End If

		    // Tag every pre-split chunk with a unique OriginGroupID BEFORE
		    // Chunker.SplitIfNeeded runs — Chunker copies it onto every
		    // sub-chunk it produces from a given raw chunk (see Chunker.
		    // SplitChunk), so DisambiguateSplitSources can tell "these N
		    // chunks all came from the SAME original page" apart from "these
		    // N chunks came from DIFFERENT pages that happen to render the
		    // same Source string" — the second case still needs the
		    // ContentHash sort even when every individual chunk also
		    // carries Chunker's own "(part N)" Title suffix (confirmed live,
		    // 2026-09-07: two distinct pages, plugins-mbsmacframeworksplugin.
		    // html and plugincontent-mbsmacframeworksplugin.html, both got
		    // Chunker-split into ~100 parts each under the SAME Source —
		    // checking only for the Title suffix wrongly treated all ~200
		    // as one already-stable group and skipped sorting them,
		    // reintroducing non-determinism this fix was supposed to close).
		    For i As Integer = 0 To rawChunks.LastIndex
		      rawChunks(i).OriginGroupID = i
		    Next

		    Var splitter As New Chunker(kMaxChars, kTargetChars)
		    Var chunks() As DocChunk = splitter.SplitIfNeeded(rawChunks)
		    // Chunker assigns every split part the SAME Source as the original
		    // (only Title gets a "(part N)" suffix) — fine for Xojo-doc chunks,
		    // which are addressed by id, but MBS upserts key on Source. Disambiguate
		    // here so two parts of one oversized page don't collide into one row.
		    DisambiguateSplitSources(chunks)

		    Var total As Integer = chunks.Count
		    Var existingHashes As Dictionary = DBHelper.MBSChunkHashes(db)
		    Var keepSources As New Dictionary
		    Var unchanged As Integer = 0

		    db.BeginTransaction
		    mTransactionOpen = True
		    For ci As Integer = 0 To chunks.LastIndex
		      Var chunk As DocChunk = chunks(ci)
		      keepSources.Value(chunk.Source) = True
		      Var hash As String = ContentHash(chunk.ChunkText)
		      If existingHashes.HasKey(chunk.Source) And existingHashes.Value(chunk.Source) = hash Then
		        unchanged = unchanged + 1
		      Else
		        DBHelper.UpsertMBSChunk(chunk.Source, chunk.Title, chunk.ChunkText, hash, db)
		      End If
		      Var done As Integer = ci + 1
		      If done Mod 1000 = 0 Then
		        AddUserInterfaceUpdate(New Pair("type", "progress"), New Pair("done", done), New Pair("total", total))
		      End If
		    Next
		    AddUserInterfaceUpdate(New Pair("type", "progress"), New Pair("done", total), New Pair("total", total))

		    DBHelper.DeleteMBSChunksExcept(keepSources, db)
		    db.CommitTransaction
		    mTransactionOpen = False

		    Var changedCount As Integer = total - unchanged
		    App.AppendDebugLog("MBSIndexerThread: " + total.ToString + " chunks, " + unchanged.ToString _
		      + " unchanged (skipped re-embed), " + changedCount.ToString + " new/updated" + EndOfLine)

		    If ModelManager.EmbeddingModelInstalled And WaitForEmbedServer(90) Then
		      Embedder.EmbedPendingChunks(db, Self, DBHelper.kMBSSourcePrefix + "%", StopEmbeddingRequested)
		    Else
		      App.AppendDebugLog("MBSIndexerThread: embedding server not ready — skipping embed phase (will resume later)" + EndOfLine)
		    End If

		    db.Close
		    AddUserInterfaceUpdate(New Pair("type", "complete"), New Pair("isReindex", False))
		  Catch e As RuntimeException
		    App.AppendDebugLog("MBSIndexerThread: " + e.Message + EndOfLine)
		    If db <> Nil Then
		      If mTransactionOpen Then
		        Try
		          db.RollbackTransaction
		        Catch e2 As DatabaseException
		        End Try
		        mTransactionOpen = False
		      End If
		      db.Close
		    End If
		    AddUserInterfaceUpdate(New Pair("type", "error"), New Pair("msg", e.Message))
		  End Try
		End Sub
	#tag EndEvent

	#tag Method, Flags = &h0
		Sub MBSParseProgress(filesDone As Integer, totalFiles As Integer)
		  // Called by MBSDocsetParser.Parse from this same thread (Parse runs
		  // synchronously inside Run) — safe to call AddUserInterfaceUpdate
		  // directly, same as every other progress point in this class.
		  AddUserInterfaceUpdate(New Pair("type", "file-scan-progress"), New Pair("done", filesDone), New Pair("total", totalFiles))
		End Sub
	#tag EndMethod

	#tag Event
		Sub UserInterfaceUpdate(data() As Dictionary)
		  For Each d As Dictionary In data
		    Var kind As String = d.Value("type")
		    If kind = "complete" Or kind = "error" Then MBSIndexer.MBSIsRunning = False
		    If ProgressDelegate = Nil Then Continue
		    Select Case kind
		    Case "parsing"
		      ProgressDelegate.IndexerParsing
		    Case "file-scan-progress"
		      ProgressDelegate.IndexerFileScanProgress(d.Value("done"), d.Value("total"))
		    Case "progress"
		      ProgressDelegate.IndexerProgress(d.Value("done"), d.Value("total"))
		    Case "embed-progress"
		      ProgressDelegate.IndexerEmbedProgress(d.Value("done"), d.Value("total"))
		    Case "complete"
		      ProgressDelegate.IndexerComplete(d.Value("isReindex"))
		    Case "error"
		      ProgressDelegate.IndexerError(d.Value("msg"))
		    End Select
		  Next
		End Sub
	#tag EndEvent

	#tag Method, Flags = &h21
		Private Sub DisambiguateSplitSources(chunks() As DocChunk)
		  // Two collision shapes share this one Source-uniqueness pass:
		  // (1) Chunker's OWN split parts of one oversized page (the case
		  // this method was originally written for — see its call site's
		  // comment) — these already arrive in a stable, deterministic
		  // order relative to each other, since Chunker.SplitChunk itself
		  // processes one source chunk's paragraphs sequentially.
		  // (2) UNRELATED pages that merely happen to render the same page
		  // title — confirmed live, 2026-09-07: 1,747 of this docset's
		  // 17,103 files share a <TITLE>/<H2> with at least one other file
		  // (e.g. many FAQ pages all render "<H2>FAQ</H2>" regardless of
		  // which actual question they answer), so ExtractPageTitle/
		  // ParseFile legitimately produce the same Source string for
		  // genuinely different content. THIS group's relative order used
		  // to depend on chunks()' own arrival order — which changed
		  // between runs once MBSDocsetParser.Parse switched to the
		  // pull-based MBSFileQueue (worker completion timing, not a fixed
		  // per-worker file slice, now decides which file's chunks land in
		  // the array first). That made the SAME set of colliding pages get
		  // a DIFFERENT "(part N)" assignment on different runs of the
		  // identical, unchanged docset — which in turn made
		  // MBSIndexerThread's content-hash comparison (keyed on Source)
		  // spuriously flag hundreds of genuinely-unchanged chunks as
		  // "new" every single reindex, discovered via three back-to-back
		  // reindexes of the same unmodified docset reporting 3 different
		  // "new/updated" counts (0-ish expected, got 353 then 229) instead
		  // of converging to ~0.
		  //
		  // Fix (2026-09-07): sort ONLY group (2) — collision groups where
		  // NO member's Title already carries a Chunker-assigned "(part N)"
		  // suffix — by ContentHash(ChunkText) before assigning Source's
		  // "(part N)" suffix, instead of using whatever order chunks()
		  // happened to arrive in. Group (1) is left on its already-stable
		  // arrival order, completely untouched.
		  //
		  // A FIRST version of this fix (same day) sorted BOTH groups the
		  // same way — that "fixed" the intended case-(2) bug but broke
		  // case (1): live-tested and confirmed WORSE, not better —
		  // "new/updated" jumped to 17,579 (vs. 229-353 before any fix)
		  // because it silently reassigned Source for ~20,000 already-
		  // stable Chunker-split chunks that never needed touching. Do NOT
		  // repeat that mistake — the two collision shapes are NOT
		  // interchangeable and must be told apart (via the Title "(part N)"
		  // check below) before deciding whether to touch a group's
		  // ordering at all.
		  Var counts As New Dictionary
		  For Each c As DocChunk In chunks
		    counts.Value(c.Source) = counts.Lookup(c.Source, 0).IntegerValue + 1
		  Next

		  Var collidingSources As New Dictionary
		  For Each key As Variant In counts.Keys
		    If counts.Value(key).IntegerValue > 1 Then collidingSources.Value(key) = True
		  Next
		  If collidingSources.KeyCount = 0 Then Return

		  // Group colliding chunks by Source. Dictionary values can't hold a
		  // DocChunk() array directly as a mutable-in-place Variant, so each
		  // group is a small wrapper class (ChunkGroup) instead — simpler
		  // than fighting Variant/array boxing here for what's always a
		  // handful of items per group (largest observed: 13 FAQ pages).
		  Var groups As New Dictionary
		  For Each c As DocChunk In chunks
		    If Not collidingSources.HasKey(c.Source) Then Continue
		    Var grp As ChunkGroup
		    If groups.HasKey(c.Source) Then
		      grp = groups.Value(c.Source)
		    Else
		      grp = New ChunkGroup
		      groups.Value(c.Source) = grp
		    End If
		    grp.Items.Add(c)
		  Next

		  For Each key As Variant In groups.Keys
		    Var grp As ChunkGroup = groups.Value(key)
		    Var sortedItems() As DocChunk = grp.Items

		    // Tell the two collision shapes apart: if EVERY member already
		    // carries Chunker's own "(part N)" Title suffix, this group is
		    // case (1) — Chunker's own split of one oversized page, already
		    // in a stable, meaningful order (the order the original page's
		    // paragraphs actually appeared in) that must NOT be touched.
		    // Only a group where at least one member has NO such suffix is
		    // case (2) — a genuine cross-file title collision — and needs
		    // the ContentHash sort below to make its ordering reproducible.
		    // A Title "(part N)" suffix ALONE is not enough to prove "this
		    // whole group is one page's own split" — confirmed live,
		    // 2026-09-07: plugins-mbsmacframeworksplugin.html and
		    // plugincontent-mbsmacframeworksplugin.html are two DIFFERENT
		    // pages that both render the same overview text and BOTH get
		    // Chunker-split into ~100 parts each, landing in the same
		    // Source-collision group — every one of those ~200 sub-chunks
		    // carries a "(part N)" Title suffix, so the earlier Title-only
		    // check wrongly treated the whole combined group as "already
		    // stable" and skipped sorting, which is exactly the non-
		    // determinism this fix exists to remove (their relative order
		    // still depends on which worker parsed which file first).
		    // OriginGroupID (set once per raw chunk in MBSIndexerThread.Run,
		    // BEFORE Chunker.SplitIfNeeded, and copied onto every sub-chunk
		    // by Chunker.SplitChunk) is the real test: only skip sorting
		    // when EVERY member of this Source-collision group traces back
		    // to the SAME original raw chunk.
		    Var allAlreadyChunkerSplit As Boolean = True
		    Var firstOriginGroupID As Integer = sortedItems(0).OriginGroupID
		    For Each item As DocChunk In sortedItems
		      If item.OriginGroupID <> firstOriginGroupID Then
		        allAlreadyChunkerSplit = False
		        Exit
		      End If
		    Next
		    If allAlreadyChunkerSplit Then
		      For n As Integer = 0 To sortedItems.LastIndex
		        Var partNum As Integer = n + 1
		        sortedItems(n).Source = sortedItems(n).Source + " (part " + partNum.ToString + ")"
		      Next
		      Continue
		    End If

		    // SortWith against a parallel key array — the documented
		    // technique for sorting a class array (Array.Sort takes a
		    // comparison delegate instead; either works, SortWith was
		    // simpler to reason about here). sortKeys must be built from
		    // the SAME group before sorting since SortWith reorders both
		    // arrays together in lockstep.
		    //
		    // Sort key is ContentHash(item.ChunkText), not the raw text —
		    // Xojo's String comparison operators are case-INSENSITIVE by
		    // default (CLAUDE.md's documented "'d' >= 'A'" pitfall), which
		    // could make two chunks whose text differs only in case compare
		    // as equal and land in an unstable relative order, reintroducing
		    // the exact non-determinism this fix exists to remove. A SHA-256
		    // hex digest (already lowercase-only hex via ContentHash) has no
		    // case ambiguity to exploit.
		    Var sortKeys() As String
		    For Each item As DocChunk In sortedItems
		      sortKeys.Add(ContentHash(item.ChunkText))
		    Next
		    sortKeys.SortWith(sortedItems)
		    For n As Integer = 0 To sortedItems.LastIndex
		      Var partNum As Integer = n + 1
		      sortedItems(n).Source = sortedItems(n).Source + " (part " + partNum.ToString + ")"
		    Next
		  Next
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ContentHash(text As String) As String
		  // String -> MemoryBlock is an implicit raw-bytes conversion in Xojo;
		  // DefineEncoding first guarantees those bytes are UTF-8 regardless of
		  // whatever encoding chunk text happened to carry after HTML parsing.
		  Var mb As MemoryBlock = DefineEncoding(text, Encodings.UTF8)
		  Return EncodeHex(Crypto.SHA2_256(mb)).Lowercase
		End Function
	#tag EndMethod


	#tag Method, Flags = &h21
		Private Function WaitForEmbedServer(graceSeconds As Integer) As Boolean
		  Var waited As Integer = 0
		  While waited < graceSeconds
		    If ModelManager.EmbedServerHealthy(2) Then Return True
		    Me.Sleep(2000)
		    waited = waited + 2
		  Wend
		  Return False
		End Function
	#tag EndMethod

	#tag Constant, Name = kMaxChars, Type = Integer, Dynamic = False, Default = \"8000", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kTargetChars, Type = Integer, Dynamic = False, Default = \"3000", Scope = Private
	#tag EndConstant

End Class
#tag EndClass
