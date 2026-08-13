#tag Module
Protected Module Retrieval

	#tag Method, Flags = &h0
		Sub InitLock()
		  // Modules have no constructor, so the CriticalSection guarding mCache
		  // can't use an "As New" property initializer — call this once from
		  // App.Opening (main thread, before any ChatPrepThread can start)
		  // instead.
		  If mCacheLock = Nil Then mCacheLock = New CriticalSection
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function SearchChunks(query As String, limit As Integer = 4, conn As SQLiteDatabase = Nil) As RetrievalResult()
		  // Hybrid semantic+BM25 search when the embedding server answers,
		  // BM25-only otherwise. Scoring constants are kept identical to XMCP's
		  // SemanticSearch so both apps rank the same DB the same way.
		  Var db As SQLiteDatabase = If(conn <> Nil, conn, DBHelper.DB)
		  Var results() As RetrievalResult
		  If db = Nil Then Return results

		  // Retrieval is scoped to the active Xojo version (plus version-independent
		  // chunks, docs_version=''). The cache key includes it so switching version
		  // never returns another version's cached results.
		  Var activeVersion As String = DBHelper.GetActiveVersion

		  Var cacheKey As String = activeVersion + "|" + query + "|" + limit.ToString

		  Var generationAtMiss As Integer
		  mCacheLock.Enter
		  If mCache <> Nil And mCache.HasKey(cacheKey) Then
		    Var cached() As RetrievalResult = mCache.Value(cacheKey)
		    mCacheLock.Leave
		    Return cached
		  End If
		  generationAtMiss = mCacheGeneration
		  mCacheLock.Leave

		  Var queryEmb As MemoryBlock = GetQueryEmbedding(query)

		  If queryEmb = Nil Then
		    // Record the tier; the actual WebView update is flushed on the main
		    // thread (SearchChunks may run on a worker — see ChatPrepThread).
		    RecordSemanticState(False)
		    results = KeywordSearchChunks(query, limit, db, activeVersion)
		  Else
		    RecordSemanticState(True)
		    results = HybridSearchChunks(query, queryEmb, limit, db, activeVersion)
		    If results.Count = 0 Then results = KeywordSearchChunks(query, limit, db, activeVersion)
		  End If

		  mCacheLock.Enter
		  // A ClearCache (reindex/version/model switch) may have landed while
		  // the search above was running against the now-stale index — only
		  // cache the result if the generation is still the one we searched
		  // under, so a stale result can't be written back after invalidation.
		  If mCacheGeneration = generationAtMiss Then
		    If mCache = Nil Then mCache = New Dictionary
		    If mCache.Count >= kCacheMaxEntries Then mCache = New Dictionary
		    mCache.Value(cacheKey) = results
		  End If
		  mCacheLock.Leave
		  Return results
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function HybridSearchChunks(query As String, queryEmb As MemoryBlock, maxResults As Integer, db As SQLiteDatabase, activeVersion As String) As RetrievalResult()
		  Var results() As RetrievalResult

		  // Cosine over every embedded chunk for the active version plus the
		  // version-independent chunks (docs_version=''). Filtering here also shrinks
		  // the in-memory cosine scan. Keep this WHERE in sync with XMCP SemanticSearch.
		  Var chunkIDs() As Integer
		  Var titles() As String
		  Var texts() As String
		  Var sources() As String
		  Var chunkIndexes() As Integer
		  Var prevIDs() As Integer
		  Var nextIDs() As Integer
		  Var cosScores() As Double

		  Try
		    Var rs As RowSet = db.SelectSQL("SELECT c.id, c.title, c.chunk_text, c.source, c.chunk_index, c.prev_id, c.next_id, e.embedding FROM embeddings e JOIN chunks c ON e.chunk_id = c.id WHERE c.docs_version = ? OR c.docs_version = ''", activeVersion)
		    While Not rs.AfterLastRow
		      Var embBlob As MemoryBlock = rs.Column("embedding").BlobValue
		      If embBlob <> Nil And embBlob.Size > 0 Then
		        chunkIDs.Add(rs.Column("id").IntegerValue)
		        titles.Add(rs.Column("title").StringValue)
		        texts.Add(rs.Column("chunk_text").StringValue)
		        sources.Add(rs.Column("source").StringValue)
		        chunkIndexes.Add(rs.Column("chunk_index").IntegerValue)
		        prevIDs.Add(rs.Column("prev_id").IntegerValue)
		        nextIDs.Add(rs.Column("next_id").IntegerValue)
		        cosScores.Add(Embedder.CosineSimilarity(queryEmb, embBlob))
		      End If
		      rs.MoveToNextRow
		    Wend
		    rs.Close
		  Catch e As DatabaseException
		    App.AppendDebugLog("Retrieval.HybridSearchChunks: " + e.Message + EndOfLine)
		    Return results
		  End Try
		  If chunkIDs.Count = 0 Then Return results

		  // BM25 leg: bm25() is negative-is-better; normalise via 1/(1+e^(0.5x)).
		  Var ftsScores() As Double
		  For i As Integer = 0 To chunkIDs.LastIndex
		    ftsScores.Add(0.0)
		  Next
		  Var safe As String = SanitizeQuery(query)
		  If safe <> "" Then
		    Try
		      Var ftsMap As New Dictionary
		      Var ftsRS As RowSet = db.SelectSQL("SELECT rowid, bm25(chunks_fts) AS bm25_score FROM chunks_fts WHERE chunks_fts MATCH ? LIMIT 200", safe)
		      While Not ftsRS.AfterLastRow
		        Var norm As Double = 1.0 / (1.0 + Exp(ftsRS.Column("bm25_score").DoubleValue * 0.5))
		        ftsMap.Value(ftsRS.Column("rowid").IntegerValue) = norm
		        ftsRS.MoveToNextRow
		      Wend
		      ftsRS.Close
		      For i As Integer = 0 To chunkIDs.LastIndex
		        If ftsMap.HasKey(chunkIDs(i)) Then ftsScores(i) = CDbl(ftsMap.Value(chunkIDs(i)))
		      Next
		    Catch e As DatabaseException
		      // FTS query failed — vector-only scores.
		    End Try
		  End If

		  // Combined: 70% vector + 30% FTS.
		  Var combined() As Double
		  For i As Integer = 0 To cosScores.LastIndex
		    combined.Add(cosScores(i) * 0.7 + ftsScores(i) * 0.3)
		  Next

		  // Partial selection sort for the top maxResults*2 candidates.
		  Var candidateCount As Integer = maxResults * 2
		  If combined.Count < candidateCount Then candidateCount = combined.Count
		  Var used() As Boolean
		  For i As Integer = 0 To combined.LastIndex
		    used.Add(False)
		  Next
		  Var topIdxs() As Integer
		  For r As Integer = 0 To candidateCount - 1
		    Var bestIdx As Integer = -1
		    Var bestScore As Double = -2.0
		    For i As Integer = 0 To combined.LastIndex
		      If Not used(i) And combined(i) > bestScore Then
		        bestScore = combined(i)
		        bestIdx = i
		      End If
		    Next
		    If bestIdx < 0 Then Exit
		    used(bestIdx) = True
		    topIdxs.Add(bestIdx)
		  Next

		  // Dedup: skip same-source chunks with near-identical scores.
		  Var includedIDs As New Dictionary
		  Var sourceLastScore As New Dictionary
		  Var finalIdxs() As Integer
		  For Each idx As Integer In topIdxs
		    If finalIdxs.Count >= maxResults Then Exit
		    Var src As String = sources(idx)
		    Var sc As Double = combined(idx)
		    If sourceLastScore.HasKey(src) Then
		      If Abs(sc - CDbl(sourceLastScore.Value(src))) < kDedupeScoreDelta Then Continue
		    End If
		    sourceLastScore.Value(src) = sc
		    includedIDs.Value(chunkIDs(idx)) = True
		    finalIdxs.Add(idx)
		  Next

		  // Neighbour expansion for high-cosine hits.
		  Var neighbourIdxs() As Integer
		  For Each idx As Integer In finalIdxs
		    If cosScores(idx) < kNeighbourThreshold Then Continue
		    Var sideIDs() As Integer
		    sideIDs.Add(prevIDs(idx))
		    sideIDs.Add(nextIDs(idx))
		    For Each sideID As Integer In sideIDs
		      If sideID <= 0 Or includedIDs.HasKey(sideID) Then Continue
		      Try
		        Var nrs As RowSet = db.SelectSQL("SELECT title, chunk_text, source, chunk_index, prev_id, next_id FROM chunks WHERE id = ?", sideID)
		        If Not nrs.AfterLastRow Then
		          includedIDs.Value(sideID) = True
		          chunkIDs.Add(sideID)
		          titles.Add(nrs.Column("title").StringValue)
		          texts.Add(nrs.Column("chunk_text").StringValue)
		          sources.Add(nrs.Column("source").StringValue)
		          chunkIndexes.Add(nrs.Column("chunk_index").IntegerValue)
		          prevIDs.Add(nrs.Column("prev_id").IntegerValue)
		          nextIDs.Add(nrs.Column("next_id").IntegerValue)
		          combined.Add(combined(idx) - 0.01)
		          neighbourIdxs.Add(chunkIDs.LastIndex)
		        End If
		        nrs.Close
		      Catch e As DatabaseException
		        App.AppendDebugLog("Retrieval (neighbour expansion): " + e.Message + EndOfLine)
		      End Try
		    Next
		  Next

		  // Group by source (score order), chunks within a source by chunk_index.
		  Var sourceOrder() As String
		  Var sourceSeen As New Dictionary
		  For Each idx As Integer In finalIdxs
		    If Not sourceSeen.HasKey(sources(idx)) Then
		      sourceSeen.Value(sources(idx)) = True
		      sourceOrder.Add(sources(idx))
		    End If
		  Next

		  Var sourceChunks As New Dictionary
		  Var allIdxs() As Integer
		  For Each idx As Integer In finalIdxs
		    allIdxs.Add(idx)
		  Next
		  For Each idx As Integer In neighbourIdxs
		    allIdxs.Add(idx)
		  Next
		  For Each idx As Integer In allIdxs
		    Var src As String = sources(idx)
		    If Not sourceChunks.HasKey(src) Then sourceChunks.Value(src) = New Dictionary
		    Dictionary(sourceChunks.Value(src)).Value(chunkIndexes(idx)) = idx
		  Next

		  For Each src As String In sourceOrder
		    If Not sourceChunks.HasKey(src) Then Continue
		    Var srcMap As Dictionary = sourceChunks.Value(src)
		    Var idxKeys() As Integer
		    For Each k As Variant In srcMap.Keys
		      idxKeys.Add(k.IntegerValue)
		    Next
		    idxKeys.Sort
		    For Each cidx As Integer In idxKeys
		      Var ai As Integer = srcMap.Value(cidx)
		      Var res As New RetrievalResult
		      res.Title = titles(ai)
		      res.Text = texts(ai)
		      res.Source = "docs"
		      res.Score = combined(ai)
		      results.Add(res)
		    Next
		  Next
		  Return results
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function KeywordSearchChunks(query As String, limit As Integer, db As SQLiteDatabase, activeVersion As String) As RetrievalResult()
		  // BM25-only fallback — always works, no servers needed. Scoped to the
		  // active version plus version-independent chunks (docs_version='').
		  Var results() As RetrievalResult
		  If db = Nil Then Return results

		  Var safe As String = SanitizeQuery(query)
		  If safe = "" Then Return results

		  Try
		    Var sql As String = "SELECT c.id, c.title, c.chunk_text, c.prev_id, c.next_id, rank " _
		      + "FROM chunks_fts " _
		      + "JOIN chunks c ON c.id = chunks_fts.rowid " _
		      + "WHERE chunks_fts MATCH ? " _
		      + "AND (c.docs_version = ? OR c.docs_version = '') " _
		      + "ORDER BY rank LIMIT ?"
		    Var rs As RowSet = db.SelectSQL(sql, safe, activeVersion, limit)

		    Var seenIds() As Integer
		    While Not rs.AfterLastRow
		      Var r As New RetrievalResult
		      Var chunkId As Integer = rs.Column("id").IntegerValue
		      r.Text = rs.Column("chunk_text").StringValue
		      r.Title = rs.Column("title").StringValue
		      r.Source = "docs"
		      r.Score = rs.Column("rank").DoubleValue
		      results.Add(r)
		      seenIds.Add(chunkId)

		      // Neighbour expansion — prev
		      Var prevId As Integer = rs.Column("prev_id").IntegerValue
		      If prevId > 0 And Not AlreadySeen(seenIds, prevId) Then
		        Var prevText As String = DBHelper.GetChunkById(prevId, db)
		        If prevText <> "" Then
		          Var rp As New RetrievalResult
		          rp.Text = prevText
		          rp.Source = "docs"
		          rp.Score = r.Score - 0.01
		          rp.Title = ""
		          results.Add(rp)
		          seenIds.Add(prevId)
		        End If
		      End If

		      // Neighbour expansion — next
		      Var nextId As Integer = rs.Column("next_id").IntegerValue
		      If nextId > 0 And Not AlreadySeen(seenIds, nextId) Then
		        Var nextText As String = DBHelper.GetChunkById(nextId, db)
		        If nextText <> "" Then
		          Var rn As New RetrievalResult
		          rn.Text = nextText
		          rn.Source = "docs"
		          rn.Score = r.Score - 0.01
		          rn.Title = ""
		          results.Add(rn)
		          seenIds.Add(nextId)
		        End If
		      End If

		      rs.MoveToNextRow
		    Wend
		    rs.Close
		  Catch e As DatabaseException
		    App.AppendDebugLog("Retrieval.KeywordSearchChunks: " + e.Message + EndOfLine)
		  End Try

		  Return results
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function SearchNotes(query As String, limit As Integer = 2, conn As SQLiteDatabase = Nil) As RetrievalResult()
		  // Hybrid over the user's notes when the embedding server answers,
		  // BM25-only otherwise. Same 0.7/0.3 blend as docs; no neighbours
		  // (notes have none). Stale notes stay searchable — they just carry a
		  // version label in the Title so the model can caveat its answer.
		  //
		  // Scope: metadata 'notes_search_scope' = 'all' (default) searches every
		  // note; 'version' restricts to global notes (scope='all') plus notes tied
		  // to the active version. Global notes always count.
		  Var db As SQLiteDatabase = If(conn <> Nil, conn, DBHelper.DB)
		  Var versionOnly As Boolean = (DBHelper.GetMetadata("notes_search_scope") = "version")
		  Var activeVersion As String = DBHelper.GetActiveVersion
		  Var queryEmb As MemoryBlock = GetQueryEmbedding(query)
		  If queryEmb <> Nil Then
		    Var hybrid() As RetrievalResult = HybridSearchNotes(query, queryEmb, limit, db, versionOnly, activeVersion)
		    If hybrid.Count > 0 Then Return hybrid
		  End If
		  Return KeywordSearchNotes(query, limit, db, versionOnly, activeVersion)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function HybridSearchNotes(query As String, queryEmb As MemoryBlock, maxResults As Integer, db As SQLiteDatabase, versionOnly As Boolean, activeVersion As String) As RetrievalResult()
		  Var results() As RetrievalResult
		  If db = Nil Then Return results

		  Var ids() As String
		  Var titles() As String
		  Var bodies() As String
		  Var rowids() As Integer
		  Var warned() As Boolean
		  Var versions() As String
		  Var scopes() As String
		  Var cosScores() As Double

		  Try
		    // When versionOnly, restrict to global notes plus notes for the active
		    // version; global notes (scope='all') always count.
		    Var sql As String = "SELECT n.rowid AS rid, n.id, n.title, n.body, n.version_warned, n.scope, n.docs_version, e.embedding " _
		      + "FROM note_embeddings e JOIN notes n ON e.note_id = n.id"
		    Var rs As RowSet
		    If versionOnly Then
		      rs = db.SelectSQL(sql + " WHERE n.scope='all' OR (n.scope='version' AND n.docs_version=?)", activeVersion)
		    Else
		      rs = db.SelectSQL(sql)
		    End If
		    While Not rs.AfterLastRow
		      Var embBlob As MemoryBlock = rs.Column("embedding").BlobValue
		      If embBlob <> Nil And embBlob.Size > 0 Then
		        ids.Add(rs.Column("id").StringValue)
		        rowids.Add(rs.Column("rid").IntegerValue)
		        titles.Add(rs.Column("title").StringValue)
		        bodies.Add(rs.Column("body").StringValue)
		        warned.Add(rs.Column("version_warned").IntegerValue = 1)
		        scopes.Add(rs.Column("scope").StringValue)
		        versions.Add(rs.Column("docs_version").StringValue)
		        cosScores.Add(Embedder.CosineSimilarity(queryEmb, embBlob))
		      End If
		      rs.MoveToNextRow
		    Wend
		    rs.Close
		  Catch e As DatabaseException
		    App.AppendDebugLog("Retrieval.HybridSearchNotes: " + e.Message + EndOfLine)
		    Return results
		  End Try
		  If ids.Count = 0 Then Return results

		  // BM25 leg over notes_fts (rowid-keyed).
		  Var ftsScores() As Double
		  For i As Integer = 0 To ids.LastIndex
		    ftsScores.Add(0.0)
		  Next
		  Var safe As String = SanitizeQuery(query)
		  If safe <> "" Then
		    Try
		      Var ftsMap As New Dictionary
		      Var ftsRS As RowSet = db.SelectSQL("SELECT rowid, bm25(notes_fts) AS s FROM notes_fts WHERE notes_fts MATCH ? LIMIT 100", safe)
		      While Not ftsRS.AfterLastRow
		        ftsMap.Value(ftsRS.Column("rowid").IntegerValue) = 1.0 / (1.0 + Exp(ftsRS.Column("s").DoubleValue * 0.5))
		        ftsRS.MoveToNextRow
		      Wend
		      ftsRS.Close
		      For i As Integer = 0 To rowids.LastIndex
		        If ftsMap.HasKey(rowids(i)) Then ftsScores(i) = CDbl(ftsMap.Value(rowids(i)))
		      Next
		    Catch e As DatabaseException
		      App.AppendDebugLog("Retrieval (FTS score merge): " + e.Message + EndOfLine)
		    End Try
		  End If

		  // Combined 0.7/0.3, take top maxResults above a relevance floor.
		  Var combined() As Double
		  For i As Integer = 0 To cosScores.LastIndex
		    combined.Add(cosScores(i) * 0.7 + ftsScores(i) * 0.3)
		  Next
		  Var used() As Boolean
		  For i As Integer = 0 To combined.LastIndex
		    used.Add(False)
		  Next
		  For r As Integer = 1 To maxResults
		    Var bestIdx As Integer = -1
		    Var bestScore As Double = kNoteRelevanceFloor
		    For i As Integer = 0 To combined.LastIndex
		      If Not used(i) And combined(i) > bestScore Then
		        bestScore = combined(i)
		        bestIdx = i
		      End If
		    Next
		    If bestIdx < 0 Then Exit
		    used(bestIdx) = True
		    Var res As New RetrievalResult
		    res.Title = titles(bestIdx)
		    If scopes(bestIdx) = "version" And warned(bestIdx) And versions(bestIdx) <> "" Then
		      res.Title = res.Title + " (written for Xojo " + versions(bestIdx) + " — may be outdated)"
		    End If
		    res.Text = bodies(bestIdx)
		    res.Source = "notes"
		    res.Score = combined(bestIdx)
		    results.Add(res)
		  Next
		  Return results
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function KeywordSearchNotes(query As String, limit As Integer, db As SQLiteDatabase, versionOnly As Boolean, activeVersion As String) As RetrievalResult()
		  Var results() As RetrievalResult
		  If db = Nil Then Return results

		  Var safe As String = SanitizeQuery(query)
		  If safe = "" Then Return results

		  Try
		    // When versionOnly, restrict to global notes plus active-version notes.
		    Var scopeClause As String = ""
		    If versionOnly Then scopeClause = "AND (n.scope='all' OR (n.scope='version' AND n.docs_version=?)) "
		    Var sql As String = "SELECT n.id, n.title, n.body, n.version_warned, n.scope, n.docs_version, rank " _
		      + "FROM notes_fts " _
		      + "JOIN notes n ON n.rowid = notes_fts.rowid " _
		      + "WHERE notes_fts MATCH ? " _
		      + scopeClause _
		      + "ORDER BY rank LIMIT ?"
		    Var rs As RowSet
		    If versionOnly Then
		      rs = db.SelectSQL(sql, safe, activeVersion, limit)
		    Else
		      rs = db.SelectSQL(sql, safe, limit)
		    End If

		    While Not rs.AfterLastRow
		      Var r As New RetrievalResult
		      r.Title = rs.Column("title").StringValue
		      If rs.Column("scope").StringValue = "version" And rs.Column("version_warned").IntegerValue = 1 And rs.Column("docs_version").StringValue <> "" Then
		        r.Title = r.Title + " (written for Xojo " + rs.Column("docs_version").StringValue + " — may be outdated)"
		      End If
		      r.Text = rs.Column("body").StringValue
		      r.Source = "notes"
		      r.Score = rs.Column("rank").DoubleValue
		      results.Add(r)
		      rs.MoveToNextRow
		    Wend
		    rs.Close
		  Catch e As DatabaseException
		    App.AppendDebugLog("Retrieval.KeywordSearchNotes: " + e.Message + EndOfLine)
		  End Try

		  Return results
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function GetQueryEmbedding(query As String) As MemoryBlock
		  // One embedding per user message even though both SearchChunks and
		  // SearchNotes need it — single-entry cache keyed on the query text.
		  // Concurrent chat requests (e.g. stop-then-resend) can run overlapping
		  // ChatPrepThread workers, so this single-entry cache needs the same
		  // lock as mCache even though nothing here touches the main thread.
		  If Not ModelManager.EmbedServerReady Then Return Nil

		  mCacheLock.Enter
		  If query = mLastEmbQuery And mLastEmb <> Nil Then
		    Var hit As MemoryBlock = mLastEmb
		    mCacheLock.Leave
		    Return hit
		  End If
		  mCacheLock.Leave

		  Var emb As MemoryBlock = Embedder.FetchEmbedding(query, 5)
		  If emb <> Nil Then
		    mCacheLock.Enter
		    mLastEmbQuery = query
		    mLastEmb = emb
		    mCacheLock.Leave
		  End If
		  Return emb
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function BuildContext(query As String, conn As SQLiteDatabase = Nil) As String
		  // Docs only — notes are injected into the user message instead
		  // (BuildNotesPreamble). A [Your Notes] section in the system context
		  // gets ignored by small models once the docs context is large.
		  // Pinned legacy→modern mapping chunks go first, then search hits
		  // that aren't the same chunk.
		  // conn lets a worker thread (ChatPrepThread) pass its OWN connection so
		  // reads never share the main-thread handle.
		  Var pinned() As RetrievalResult = PinnedMigrationResults(query, conn)
		  Var docResults() As RetrievalResult = SearchChunks(query, 4, conn)

		  Var results() As RetrievalResult
		  For Each p As RetrievalResult In pinned
		    results.Add(p)
		  Next
		  For Each d As RetrievalResult In docResults
		    Var dup As Boolean = False
		    For Each p As RetrievalResult In pinned
		      If d.Text = p.Text Then dup = True
		    Next
		    If Not dup Then results.Add(d)
		  Next
		  If results.Count = 0 Then Return ""

		  Var sb As String = "[Xojo Docs]" + EndOfLine
		  For di As Integer = 0 To results.Count - 1
		    If di > 0 Then sb = sb + EndOfLine + "---" + EndOfLine + EndOfLine
		    sb = sb + results(di).Text
		  Next

		  Return sb
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function PinnedMigrationResults(query As String, conn As SQLiteDatabase = Nil) As RetrievalResult()
		  // Deterministic glossary pinning: when the question names a legacy
		  // API 1 identifier (MsgBox, RecordSet, UBound…), its curated mapping
		  // chunk ALWAYS enters the context. Ranking alone is a gamble here:
		  // FTS multi-term matching is implicit AND ("loop through a RecordSet"
		  // never matches the short mapping chunk, which lacks "loop"), and
		  // cosine can rank it below generic guide pages — which is exactly how
		  // the model ended up inventing a RecordSet iterator API in testing.
		  Var results() As RetrievalResult
		  Try
		    Var db As SQLiteDatabase = If(conn <> Nil, conn, DBHelper.DB)
		    If db = Nil Then Return results

		    // Normalise for whole-word matching: lowercase, everything except
		    // letters/digits/dots becomes a space (dots survive for the
		    // "xojo.core" trigger).
		    Var lower As String = " " + query.Lowercase + " "
		    Var cleaned As String
		    For i As Integer = 0 To lower.Length - 1
		      Var ch As String = lower.Middle(i, 1)
		      If (ch >= "a" And ch <= "z") Or (ch >= "0" And ch <= "9") Or ch = "." Then
		        cleaned = cleaned + ch
		      Else
		        cleaned = cleaned + " "
		      End If
		    Next

		    Var triggers As Dictionary = APIMigrationMap.PinTriggers
		    Var pinnedTitles() As String
		    For Each key As Variant In triggers.Keys
		      Var trig As String = key.StringValue
		      If cleaned.IndexOf(" " + trig + " ") >= 0 Then
		        Var title As String = triggers.Value(trig)
		        If pinnedTitles.IndexOf(title) < 0 Then pinnedTitles.Add(title)
		        If pinnedTitles.Count >= 3 Then Exit
		      End If
		    Next

		    For Each title As String In pinnedTitles
		      Var rs As RowSet = db.SelectSQL("SELECT title, chunk_text FROM chunks WHERE source = 'curated > API 2 migration' AND title = ? LIMIT 1", title)
		      If rs <> Nil Then
		        If Not rs.AfterLastRow Then
		          Var r As New RetrievalResult
		          r.Title = rs.Column("title").StringValue
		          r.Text = rs.Column("chunk_text").StringValue
		          r.Source = "docs"
		          r.Score = 1.0
		          results.Add(r)
		        End If
		        rs.Close
		      End If
		    Next
		  Catch e As RuntimeException
		    App.AppendDebugLog("Retrieval.PinnedMigrationResults: " + e.Message + EndOfLine)
		  End Try
		  Return results
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function BuildNotesPreamble(query As String, conn As SQLiteDatabase = Nil) As String
		  // Relevant notes are prepended to the *user message*, not the system
		  // prompt: small local models reliably honour material adjacent to the
		  // question but ignore a notes section buried before a large docs
		  // context (verified empirically against Qwen2.5 Coder 7B — see the
		  // burger test). Stale-note titles keep their "may be outdated" caveat.
		  Var noteResults() As RetrievalResult = SearchNotes(query, 2, conn)
		  If noteResults.Count = 0 Then Return ""

		  Var sb As String = "Before answering, consider these notes of mine. " _
		    + "They are authoritative for me and override the official documentation where they differ:" + EndOfLine
		  For ni As Integer = 0 To noteResults.Count - 1
		    If ni > 0 Then sb = sb + EndOfLine + "---" + EndOfLine
		    Var nr As RetrievalResult = noteResults(ni)
		    If nr.Title <> "" Then sb = sb + nr.Title + EndOfLine
		    sb = sb + nr.Text
		  Next
		  sb = sb + EndOfLine + EndOfLine + "My question: "
		  Return sb
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub ClearCache()
		  // Called from the main thread (reindex/version-switch/model-switch)
		  // while SearchChunks may be reading or writing mCache on the
		  // ChatPrepThread worker — same lock protects both. Bumping the
		  // generation here (not just nil-ing mCache) lets an in-flight
		  // SearchChunks that missed the cache before this call detect that
		  // its result is now stale and skip writing it back — see the
		  // generationAtMiss check in SearchChunks.
		  mCacheLock.Enter
		  mCache = Nil
		  mCacheGeneration = mCacheGeneration + 1
		  mCacheLock.Leave
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub NotifySemanticState()
		  // Push the current search tier to the status bar. Called on the MAIN
		  // thread when the embedding server flips ready and after (re)indexing.
		  RecordSemanticState(ModelManager.EmbedServerReady)
		  FlushSemanticState
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub RecordSemanticState(active As Boolean)
		  // Thread-safe: just records the desired tier. Search runs on a worker
		  // thread (ChatPrepThread), so it must NOT touch the WebView here — the
		  // UI update is flushed separately on the main thread (FlushSemanticState).
		  If mSemanticKnown And active = mSemanticActive Then Return
		  mSemanticActive = active
		  mSemanticKnown = True
		  mSemanticDirty = True
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub FlushSemanticState()
		  // MAIN THREAD ONLY. Pushes the recorded tier to the WebView if it changed.
		  If Not mSemanticDirty Then Return
		  mSemanticDirty = False
		  Try
		    Window1.MainView.EvaluateJavaScript("receiveSemanticState(" + If(mSemanticActive, """semantic""", """keyword""") + ");")
		  Catch e As RuntimeException
		    App.AppendDebugLog("Retrieval.FlushSemanticState: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function SanitizeQuery(query As String) As String
		  Var s As String = query

		  // Strip FTS5-special characters
		  Var specials() As String
		  specials.Add("""")
		  specials.Add("'")
		  specials.Add("*")
		  specials.Add("^")
		  specials.Add("(")
		  specials.Add(")")
		  specials.Add("[")
		  specials.Add("]")
		  specials.Add("{")
		  specials.Add("}")
		  specials.Add("~")
		  specials.Add(":")
		  specials.Add("\")
		  specials.Add("/")
		  For Each ch As String In specials
		    s = s.ReplaceAll(ch, " ")
		  Next

		  // Collapse multiple spaces
		  While s.IndexOf("  ") >= 0
		    s = s.ReplaceAll("  ", " ")
		  Wend
		  s = s.Trim

		  If s = "" Then Return ""
		  Return s
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function AlreadySeen(ids() As Integer, id As Integer) As Boolean
		  For Each existing As Integer In ids
		    If existing = id Then Return True
		  Next
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub SelfTest()
		  Var query As String = "FolderItem"
		  App.AppendDebugLog("Retrieval.SelfTest: querying for '" + query + "'" + EndOfLine)
		  Var ctx As String = BuildContext(query)
		  If ctx = "" Then
		    App.AppendDebugLog("Retrieval.SelfTest: no results" + EndOfLine)
		  Else
		    Var preview As String = ctx
		    If preview.Length > 500 Then preview = preview.Left(500) + "..."
		    App.AppendDebugLog("Retrieval.SelfTest: context (" + ctx.Length.ToString + " chars):" + EndOfLine + preview + EndOfLine)
		  End If
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mCache As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mCacheLock As CriticalSection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mCacheGeneration As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLastEmb As MemoryBlock
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLastEmbQuery As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSemanticActive As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSemanticKnown As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSemanticDirty As Boolean
	#tag EndProperty


	#tag Constant, Name = kCacheMaxEntries, Type = Double, Dynamic = False, Default = \"50", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kDedupeScoreDelta, Type = Double, Dynamic = False, Default = \"0.04", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kNeighbourThreshold, Type = Double, Dynamic = False, Default = \"0.72", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kNoteRelevanceFloor, Type = Double, Dynamic = False, Default = \"0.45", Scope = Private
	#tag EndConstant


End Module
#tag EndModule
