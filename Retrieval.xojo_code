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
		    results = HybridSearchChunks(query, queryEmb, limit, db, activeVersion, cacheKey, generationAtMiss)
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
		Private Function HybridSearchChunks(query As String, queryEmb As MemoryBlock, maxResults As Integer, db As SQLiteDatabase, activeVersion As String, cacheKey As String, generationAtMiss As Integer) As RetrievalResult()
		  // Task 7: native and MBS (third-party) docs are searched as two
		  // separate scoped pools instead of one shared cosine/BM25 race, so
		  // the two sources can never crowd each other out — the model
		  // previously ended up seeing only whichever source happened to
		  // score highest on a given phrasing, then either hallucinated the
		  // other didn't exist or (post Task 6) could only say "can't
		  // confirm". Presenting both as real alternatives requires actually
		  // *finding* both first. Each pool gets its own scan, scoring,
		  // dedup and Overview-chunk guarantee (ScopedSearch, shared code) —
		  // only reranking and neighbour expansion run once, over the
		  // merged, capped set. Keep in sync with XMCP SemanticSearch.
		  Var results() As RetrievalResult

		  Var nativeHalf As Integer = (maxResults + 1) \ 2 // ceiling
		  Var mbsHalf As Integer = maxResults - nativeHalf

		  Var native As New ScopedSearchResult
		  Var mbs As New ScopedSearchResult
		  ScopedSearch(query, queryEmb, nativeHalf, db, activeVersion, False, native)
		  ScopedSearch(query, queryEmb, mbsHalf, db, activeVersion, True, mbs)

		  // Neither pool is forced to fill its half with weak matches — a
		  // pool that came back short (or empty) lets the OTHER pool use the
		  // freed slots, so a question with a real answer on only one side
		  // still gets the full maxResults budget instead of wasting half of
		  // it on nothing. "Short" is measured in candidate count, not
		  // score — ScopedSearch's own dedup/candidate selection already
		  // discards weak matches by not having anything left to pick.
		  //
		  // The other side's count must be checked with >= its own half,
		  // not >: ScopedSearch's dedup loop (`If finalIdxs.Count >=
		  // maxResults Then Exit`) makes FinalIdxs.Count <= maxResults a
		  // hard ceiling — a pool can never come back with MORE than it was
		  // asked for, so `> mbsHalf`/`> nativeHalf` can never be true and
		  // this rebalancing would never fire. ">=" means "that pool filled
		  // its entire allocated quota" — i.e. it may have MORE candidates
		  // available beyond what it was capped at, which is the actual
		  // signal that re-asking it for a larger share is worth trying.
		  If native.FinalIdxs.Count < nativeHalf And mbs.FinalIdxs.Count >= mbsHalf Then
		    Var spare As Integer = nativeHalf - native.FinalIdxs.Count
		    ScopedSearch(query, queryEmb, mbsHalf + spare, db, activeVersion, True, mbs)
		  ElseIf mbs.FinalIdxs.Count < mbsHalf And native.FinalIdxs.Count >= nativeHalf Then
		    Var spare As Integer = mbsHalf - mbs.FinalIdxs.Count
		    ScopedSearch(query, queryEmb, nativeHalf + spare, db, activeVersion, False, native)
		  End If

		  // Native first, always — deterministic ordering rather than
		  // whichever side scored higher, so "which source leads" doesn't
		  // vary between otherwise-similar questions (see BuildContext,
		  // which uses IsThirdParty to lay these out as two labeled blocks
		  // in this same order).
		  Var chunkIDs() As Integer
		  Var titles() As String
		  Var texts() As String
		  Var sources() As String
		  Var chunkIndexes() As Integer
		  Var prevIDs() As Integer
		  Var nextIDs() As Integer
		  Var combined() As Double
		  Var cosScores() As Double
		  Var finalIdxs() As Integer // indexes into the arrays above, post-merge

		  MergeScopedResult(native, chunkIDs, titles, texts, sources, chunkIndexes, prevIDs, nextIDs, combined, cosScores, finalIdxs)
		  MergeScopedResult(mbs, chunkIDs, titles, texts, sources, chunkIndexes, prevIDs, nextIDs, combined, cosScores, finalIdxs)

		  If chunkIDs.Count = 0 Then Return results

		  // Chunk IDs that MUST reach BuildContext regardless of rerank
		  // score — currently just each pool's Overview-guarantee chunk
		  // (0 = "no guarantee for this pool", never a real chunk ID). See
		  // ScopedSearchResult.OverviewChunkID's comment for why this has
		  // to survive kMinRelevanceScore filtering.
		  Var guaranteedChunkIDs As New Dictionary
		  If native.OverviewChunkID > 0 Then guaranteedChunkIDs.Value(native.OverviewChunkID) = True
		  If mbs.OverviewChunkID > 0 Then guaranteedChunkIDs.Value(mbs.OverviewChunkID) = True

		  Var includedIDs As New Dictionary
		  For Each idx As Integer In finalIdxs
		    includedIDs.Value(chunkIDs(idx)) = True
		  Next

		  // Reranking: a cross-encoder pass over the already-selected candidates
		  // that reorders by real query-document relevance instead of trusting
		  // cosine+BM25 alone. Score-threshold and rank-gap "no match" signals
		  // were tested against 16 real queries and both showed full
		  // distributional overlap between answerable and unanswerable
		  // questions — the reranker's relevance_score is the one signal that
		  // showed real separation (0/8 false positives, 1/8 false negative at
		  // threshold 0.9). Pure fallback if the server is down or the model
		  // isn't installed: finalIdxs keeps its existing cosine+BM25 order and
		  // no score is cached (BuildContext treats a cache miss as "no rerank
		  // signal available", never injects the no-match marker).
		  //
		  // Cached (not a bare field) and keyed by the SAME cacheKey SearchChunks
		  // uses for mCache: SearchChunks's early cache-hit return skips this
		  // function entirely on a repeat query, and concurrent ChatPrepThread
		  // workers can run overlapping searches for different queries — a bare
		  // module field would go stale or race exactly like mLastEmb/mLastEmbQuery
		  // would without their own lock (see GetQueryEmbedding).
		  // Per-chunk-ID rerank score, keyed by chunk ID rather than array
		  // position — finalIdxs gets reordered by rerank below, and
		  // neighbour expansion appends more entries afterward, so a
		  // position-based mapping would drift. BuildContext looks this up
		  // per RetrievalResult to filter out a chunk that only won its
		  // scoped pool's internal race without being genuinely relevant
		  // (see RetrievalResult.RerankScore).
		  Var rerankScoreByChunkID As New Dictionary
		  Var rerankBestScore As Double = -1.0
		  If finalIdxs.Count > 0 And ModelManager.RerankServerReady Then
		    // Pre-existing bug, found while diagnosing a Task 7 test failure:
		    // the target-platform label (TargetPlatformLabel — "[Web-target
		    // class...]" etc.) was only ever applied when building the final
		    // RetrievalResult.Text, AFTER reranking already ran — so the
		    // reranker itself always scored the bare, unlabeled chunk text.
		    // Confirmed live: "Does Xojo have a native way to show a webpage
		    // in a desktop app?" reranked WebPage > Overview (a Web-target,
		    // server-side class) at 0.995 — comfortably above
		    // kNoMatchThreshold (0.9) — because nothing in the text the
		    // reranker saw distinguished it from a desktop answer; the model
		    // then hallucinated a nonexistent "WebBrowser" class rather than
		    // hitting MatchStatus's no-match gate. Labeling BEFORE reranking
		    // gives the cross-encoder the same platform signal the model
		    // gets, so a platform-mismatched chunk can score low enough to
		    // trip the no-match gate instead of being confidently retrieved.
		    Var candidateTexts() As String
		    For Each idx As Integer In finalIdxs
		      candidateTexts.Add(TargetPlatformLabel(titles(idx)) + texts(idx))
		    Next
		    Var rerankScores() As Double = Reranker.RerankBatch(query, candidateTexts)
		    If rerankScores.Count = finalIdxs.Count Then
		      // Pair each finalIdxs slot with its rerank score, then sort
		      // descending — a small array (<= maxResults*2), insertion sort is
		      // plenty and keeps this dependency-free.
		      Var order() As Integer
		      For i As Integer = 0 To finalIdxs.LastIndex
		        order.Add(i)
		      Next
		      For i As Integer = 1 To order.LastIndex
		        Var key As Integer = order(i)
		        Var keyScore As Double = rerankScores(key)
		        Var j As Integer = i - 1
		        While j >= 0 And rerankScores(order(j)) < keyScore
		          order(j + 1) = order(j)
		          j = j - 1
		        Wend
		        order(j + 1) = key
		      Next
		      Var rerankedIdxs() As Integer
		      Var bestScore As Double = -2.0
		      For Each pos As Integer In order
		        rerankedIdxs.Add(finalIdxs(pos))
		        rerankScoreByChunkID.Value(chunkIDs(finalIdxs(pos))) = rerankScores(pos)
		        If rerankScores(pos) > bestScore Then bestScore = rerankScores(pos)
		      Next
		      finalIdxs = rerankedIdxs
		      rerankBestScore = bestScore
		    End If
		  End If
		  If rerankBestScore >= 0.0 Then
		    mCacheLock.Enter
		    // Same generation guard as SearchChunks's own mCache write — a
		    // ClearCache that landed mid-search must not let a stale score get
		    // written back under a cacheKey a reindex/version-switch has since
		    // invalidated.
		    If mCacheGeneration = generationAtMiss Then
		      If mRerankScoreCache = Nil Then mRerankScoreCache = New Dictionary
		      If mRerankScoreCache.Count >= kCacheMaxEntries Then mRerankScoreCache = New Dictionary
		      mRerankScoreCache.Value(cacheKey) = rerankBestScore
		    End If
		    mCacheLock.Leave
		  End If

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
		      res.Text = TargetPlatformLabel(titles(ai)) + texts(ai)
		      res.Source = "docs"
		      res.Score = combined(ai)
		      // MBS Docset chunks document a paid, third-party plugin (see
		      // sources(ai), which carries the raw DB source unlike Source
		      // above) — not part of Xojo itself. BuildContext uses this to
		      // warn the model when NO native-docs chunk made it into the
		      // context, so it doesn't imply a third-party-only answer is the
		      // only option Xojo offers. See BuildContext's kAllThirdPartyNote.
		      res.IsThirdParty = sources(ai).Left(13) = "MBS Docset > "
		      If rerankScoreByChunkID.HasKey(chunkIDs(ai)) Then
		        res.RerankScore = rerankScoreByChunkID.Value(chunkIDs(ai)).DoubleValue
		      End If
		      res.IsGuaranteed = guaranteedChunkIDs.HasKey(chunkIDs(ai))
		      results.Add(res)
		    Next
		  Next
		  Return results
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ScopedSearch(query As String, queryEmb As MemoryBlock, maxResults As Integer, db As SQLiteDatabase, activeVersion As String, mbsOnly As Boolean, ByRef result As ScopedSearchResult)
		  // One source's worth of the old single-pool HybridSearchChunks:
		  // cosine + BM25 scan, class-name boost, Overview-chunk guarantee,
		  // dedup — scoped to EITHER native docs (docs_version <> MBS,
		  // includes '' version-independent chunks) OR MBS docs alone,
		  // never both. Called twice by HybridSearchChunks (and a possible
		  // third "spare capacity" re-call for whichever side comes up
		  // short) so native and MBS chunks compete only within their own
		  // pool, never against each other. maxResults=0 is valid (the
		  // other side used up the whole budget) and short-circuits to an
		  // empty result without touching the DB.
		  If maxResults <= 0 Then Return

		  Var chunkIDs() As Integer
		  Var titles() As String
		  Var texts() As String
		  Var sources() As String
		  Var chunkIndexes() As Integer
		  Var prevIDs() As Integer
		  Var nextIDs() As Integer
		  Var cosScores() As Double

		  Try
		    Var sql As String
		    If mbsOnly Then
		      sql = "SELECT c.id, c.title, c.chunk_text, c.source, c.chunk_index, c.prev_id, c.next_id, e.embedding FROM embeddings e JOIN chunks c ON e.chunk_id = c.id WHERE c.docs_version = ?"
		    Else
		      sql = "SELECT c.id, c.title, c.chunk_text, c.source, c.chunk_index, c.prev_id, c.next_id, e.embedding FROM embeddings e JOIN chunks c ON e.chunk_id = c.id WHERE (c.docs_version = ? OR c.docs_version = '') AND c.docs_version <> ?"
		    End If
		    Var rs As RowSet
		    If mbsOnly Then
		      rs = db.SelectSQL(sql, DBHelper.kMBSDocsVersion)
		    Else
		      rs = db.SelectSQL(sql, activeVersion, DBHelper.kMBSDocsVersion)
		    End If
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
		    App.AppendDebugLog("Retrieval.ScopedSearch: " + e.Message + EndOfLine)
		    Return
		  End Try
		  If chunkIDs.Count = 0 Then Return

		  // BM25 leg, scoped the same way via an added docs_version filter —
		  // bm25() is negative-is-better; normalise via 1/(1+e^(0.5x)).
		  Var ftsScores() As Double
		  For i As Integer = 0 To chunkIDs.LastIndex
		    ftsScores.Add(0.0)
		  Next
		  Var safe As String = BuildMatchQuery(query)
		  If safe <> "" Then
		    Try
		      Var ftsMap As New Dictionary
		      // ORDER BY the raw bm25() score (ascending) BEFORE the LIMIT is
		      // load-bearing, not cosmetic — see HybridSearchChunks's history
		      // for the truncation bug this avoids (an unordered LIMIT can
		      // silently drop the true best matches). Join against chunks
		      // here (not just chunks_fts) so the docs_version scope applies
		      // to the FTS leg too — otherwise an MBS-only scan's BM25 leg
		      // would still score native chunks.
		      Var ftsSQL As String
		      If mbsOnly Then
		        ftsSQL = "SELECT chunks_fts.rowid AS rid, bm25(chunks_fts) AS bm25_score FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid WHERE chunks_fts MATCH ? AND c.docs_version = ? ORDER BY bm25(chunks_fts) LIMIT 200"
		      Else
		        ftsSQL = "SELECT chunks_fts.rowid AS rid, bm25(chunks_fts) AS bm25_score FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid WHERE chunks_fts MATCH ? AND (c.docs_version = ? OR c.docs_version = '') AND c.docs_version <> ? ORDER BY bm25(chunks_fts) LIMIT 200"
		      End If
		      Var ftsRS As RowSet
		      If mbsOnly Then
		        ftsRS = db.SelectSQL(ftsSQL, safe, DBHelper.kMBSDocsVersion)
		      Else
		        ftsRS = db.SelectSQL(ftsSQL, safe, activeVersion, DBHelper.kMBSDocsVersion)
		      End If
		      While Not ftsRS.AfterLastRow
		        Var norm As Double = 1.0 / (1.0 + Exp(ftsRS.Column("bm25_score").DoubleValue * 0.5))
		        ftsMap.Value(ftsRS.Column("rid").IntegerValue) = norm
		        ftsRS.MoveToNextRow
		      Wend
		      ftsRS.Close
		      // NOT CDbl(Variant) — see HybridSearchChunks's history for the
		      // locale mis-parse this avoids. DoubleValue reads the Variant's
		      // binary double directly, no string round-trip.
		      For i As Integer = 0 To chunkIDs.LastIndex
		        If ftsMap.HasKey(chunkIDs(i)) Then ftsScores(i) = ftsMap.Value(chunkIDs(i)).DoubleValue
		      Next
		    Catch e As DatabaseException
		      // FTS query failed — vector-only scores.
		    End Try
		  End If

		  // Combined: 70% vector + 30% FTS, plus a flat boost when the query
		  // names this chunk's class exactly, and tracking of this pool's
		  // own Overview-chunk guarantee. See HybridSearchChunks's former
		  // (pre-Task-7) single-pool version for the full history of why
		  // both of these exist — unchanged here, just scoped per pool.
		  Var queryLower As String = query.Lowercase
		  Var combined() As Double
		  Var overviewIdx As Integer = -1
		  For i As Integer = 0 To cosScores.LastIndex
		    Var score As Double = cosScores(i) * 0.7 + ftsScores(i) * 0.3
		    Var className As String = ExtractClassName(titles(i), texts(i))
		    If className <> "" And QueryNamesClass(queryLower, className.Lowercase) Then
		      score = score + kClassNameBoost
		      If overviewIdx < 0 And titles(i) = className + " > Overview" Then overviewIdx = i
		    End If
		    combined.Add(score)
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
		      If Abs(sc - sourceLastScore.Value(src).DoubleValue) < kDedupeScoreDelta Then Continue
		    End If
		    sourceLastScore.Value(src) = sc
		    includedIDs.Value(chunkIDs(idx)) = True
		    finalIdxs.Add(idx)
		  Next

		  // Guarantee this pool's matched class's own Overview chunk
		  // survives into finalIdxs even if it lost the score race above —
		  // see the comment on overviewIdx above. Bump the weakest current
		  // slot rather than growing past maxResults, so a single pool can't
		  // blow the per-pool share of the token budget.
		  If overviewIdx >= 0 And Not includedIDs.HasKey(chunkIDs(overviewIdx)) Then
		    If finalIdxs.Count < maxResults Then
		      finalIdxs.Add(overviewIdx)
		    Else
		      Var weakestPos As Integer = 0
		      For p As Integer = 1 To finalIdxs.LastIndex
		        If combined(finalIdxs(p)) < combined(finalIdxs(weakestPos)) Then weakestPos = p
		      Next
		      finalIdxs(weakestPos) = overviewIdx
		    End If
		    includedIDs.Value(chunkIDs(overviewIdx)) = True
		  End If

		  // Task 4 "native-alternative-never-named" gap: overviewIdx above
		  // only fires when the query names a class ExtractClassName
		  // recognizes. Most of the time a user never names the class they
		  // don't know exists yet ("does Xojo have a native way to show a
		  // webpage" never says DesktopHTMLViewer) — measured live against
		  // the real DB: the correct Overview chunk then ranks ~#400 of
		  // ~15,000 chunks on cosine+BM25 alone, far outside any affordable
		  // candidateCount. But scoped to JUST this pool's own Overview
		  // chunks (~550 rows, not ~15,000 — a cheap second scan, same cost
		  // class as the main scan above but over a tiny slice), the same
		  // chunk ranks #7. Cosine alone still isn't reliable enough to
		  // gate on directly here (measured: an unrelated Overview chunk
		  // can outscore the correct one for a different query — e.g.
		  // "sort an array" scores AutoDiscovery > Overview higher than
		  // this query scores its own correct target), so these are added
		  // as ADDITIONAL rerank candidates, not a guarantee — they ride
		  // the same kMinRelevanceScore floor as everything else
		  // afterward, exactly like the platform-mismatch/MBS-noise cases
		  // already handled there.
		  //
		  // Runs UNCONDITIONALLY, not just when overviewIdx < 0 — found
		  // live during this fix's own testing: the exact repro above
		  // ALSO word-boundary-matches "WebPage" (from "webpage" in the
		  // query, the same false-positive mechanism Task 5's
		  // QueryNamesClass fix already documents), so overviewIdx was
		  // >= 0 (WebPage > Overview, the WRONG class) even though
		  // DesktopHTMLViewer — the class that actually answers the
		  // question — was never named at all. Gating on overviewIdx < 0
		  // would silently skip the fallback in exactly the cases it
		  // exists to fix. The dedup below (includedIDs) already prevents
		  // double-adding the same chunk if it happens to be both the
		  // guaranteed match AND the top fallback candidate, so running
		  // this unconditionally is safe and no more expensive per query
		  // (still one small ~550-row scan either way).
		  Var ovChunkIDs() As Integer
		  Var ovTitles() As String
		  Var ovTexts() As String
		  Var ovSources() As String
		  Var ovChunkIndexes() As Integer
		  Var ovPrevIDs() As Integer
		  Var ovNextIDs() As Integer
		  Var ovCosScores() As Double
		  Try
		    Var ovSQL As String
		    If mbsOnly Then
		      ovSQL = "SELECT c.id, c.title, c.chunk_text, c.source, c.chunk_index, c.prev_id, c.next_id, e.embedding FROM embeddings e JOIN chunks c ON e.chunk_id = c.id WHERE c.docs_version = ? AND c.title LIKE '% > Overview'"
		    Else
		      ovSQL = "SELECT c.id, c.title, c.chunk_text, c.source, c.chunk_index, c.prev_id, c.next_id, e.embedding FROM embeddings e JOIN chunks c ON e.chunk_id = c.id WHERE (c.docs_version = ? OR c.docs_version = '') AND c.docs_version <> ? AND c.title LIKE '% > Overview'"
		    End If
		    Var ovRS As RowSet
		    If mbsOnly Then
		      ovRS = db.SelectSQL(ovSQL, DBHelper.kMBSDocsVersion)
		    Else
		      ovRS = db.SelectSQL(ovSQL, activeVersion, DBHelper.kMBSDocsVersion)
		    End If
		    While Not ovRS.AfterLastRow
		      Var embBlob As MemoryBlock = ovRS.Column("embedding").BlobValue
		      If embBlob <> Nil And embBlob.Size > 0 And Not includedIDs.HasKey(ovRS.Column("id").IntegerValue) Then
		        ovChunkIDs.Add(ovRS.Column("id").IntegerValue)
		        ovTitles.Add(ovRS.Column("title").StringValue)
		        ovTexts.Add(ovRS.Column("chunk_text").StringValue)
		        ovSources.Add(ovRS.Column("source").StringValue)
		        ovChunkIndexes.Add(ovRS.Column("chunk_index").IntegerValue)
		        ovPrevIDs.Add(ovRS.Column("prev_id").IntegerValue)
		        ovNextIDs.Add(ovRS.Column("next_id").IntegerValue)
		        ovCosScores.Add(Embedder.CosineSimilarity(queryEmb, embBlob))
		      End If
		      ovRS.MoveToNextRow
		    Wend
		    ovRS.Close
		  Catch e As DatabaseException
		    App.AppendDebugLog("Retrieval.ScopedSearch (Overview fallback): " + e.Message + EndOfLine)
		  End Try

		  // Top kOverviewFallbackCount by cosine alone (no BM25/boost —
		  // these terse summary chunks rarely share vocabulary with a
		  // conversational query, which is the whole reason they lose
		  // the main race; BM25 would just add noise here, not signal).
		  Var ovUsed() As Boolean
		  For i As Integer = 0 To ovCosScores.LastIndex
		    ovUsed.Add(False)
		  Next
		  Var ovPicked As Integer = 0
		  While ovPicked < kOverviewFallbackCount And ovPicked < ovCosScores.Count
		    Var bestIdx As Integer = -1
		    Var bestScore As Double = -2.0
		    For i As Integer = 0 To ovCosScores.LastIndex
		      If Not ovUsed(i) And ovCosScores(i) > bestScore Then
		        bestScore = ovCosScores(i)
		        bestIdx = i
		      End If
		    Next
		    If bestIdx < 0 Then Exit
		    ovUsed(bestIdx) = True
		    ovPicked = ovPicked + 1

		    // Append as a plain additional candidate — not through
		    // finalIdxs' maxResults cap, since this pool's cap was
		    // already spent above. HybridSearchChunks reranks and
		    // kMinRelevanceScore-filters the whole merged set afterward,
		    // so a genuinely irrelevant fallback candidate gets dropped
		    // there rather than crowding out a real result here.
		    chunkIDs.Add(ovChunkIDs(bestIdx))
		    titles.Add(ovTitles(bestIdx))
		    texts.Add(ovTexts(bestIdx))
		    sources.Add(ovSources(bestIdx))
		    chunkIndexes.Add(ovChunkIndexes(bestIdx))
		    prevIDs.Add(ovPrevIDs(bestIdx))
		    nextIDs.Add(ovNextIDs(bestIdx))
		    cosScores.Add(ovCosScores(bestIdx))
		    combined.Add(ovCosScores(bestIdx))
		    finalIdxs.Add(chunkIDs.LastIndex)
		  Wend

		  // Track by chunk ID (not local array index) — MergeScopedResult
		  // remaps indexes when combining native+MBS into one array, so an
		  // index captured here wouldn't survive the merge. BuildContext
		  // uses this to exempt the guaranteed Overview chunk from
		  // kMinRelevanceScore filtering: it was deliberately forced into
		  // the result set specifically because the model needs it to
		  // confirm a matched class exists (see the comment on overviewIdx
		  // above and Task 4's original fix history) — a terse, generic
		  // Overview chunk reranking below the relevance floor against a
		  // specific query is exactly the failure mode this guarantee
		  // exists to prevent, so it must not be re-filtered out afterward.
		  If overviewIdx >= 0 Then result.OverviewChunkID = chunkIDs(overviewIdx)

		  result.ChunkIDs = chunkIDs
		  result.Titles = titles
		  result.Texts = texts
		  result.Sources = sources
		  result.ChunkIndexes = chunkIndexes
		  result.PrevIDs = prevIDs
		  result.NextIDs = nextIDs
		  result.CosScores = cosScores
		  result.Combined = combined
		  result.FinalIdxs = finalIdxs
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub MergeScopedResult(part As ScopedSearchResult, ByRef chunkIDs() As Integer, ByRef titles() As String, ByRef texts() As String, ByRef sources() As String, ByRef chunkIndexes() As Integer, ByRef prevIDs() As Integer, ByRef nextIDs() As Integer, ByRef combined() As Double, ByRef cosScores() As Double, ByRef finalIdxs() As Integer)
		  // Appends one ScopedSearch pool's finalIdxs onto the shared,
		  // merged arrays HybridSearchChunks reranks/expands/groups over —
		  // remapping each local index to its new position in the merged
		  // arrays. Call native's pool first, then MBS's, so finalIdxs
		  // naturally ends up native-first (see HybridSearchChunks's
		  // ordering comment).
		  Var offset As Integer = chunkIDs.Count
		  For i As Integer = 0 To part.ChunkIDs.LastIndex
		    chunkIDs.Add(part.ChunkIDs(i))
		    titles.Add(part.Titles(i))
		    texts.Add(part.Texts(i))
		    sources.Add(part.Sources(i))
		    chunkIndexes.Add(part.ChunkIndexes(i))
		    prevIDs.Add(part.PrevIDs(i))
		    nextIDs.Add(part.NextIDs(i))
		    combined.Add(part.Combined(i))
		    cosScores.Add(part.CosScores(i))
		  Next
		  For Each localIdx As Integer In part.FinalIdxs
		    finalIdxs.Add(offset + localIdx)
		  Next
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function KeywordSearchChunks(query As String, limit As Integer, db As SQLiteDatabase, activeVersion As String) As RetrievalResult()
		  // BM25-only fallback — always works, no servers needed. Scoped to the
		  // active version plus version-independent chunks (docs_version='') and
		  // MBS docset chunks (docs_version=kMBSDocsVersion).
		  Var results() As RetrievalResult
		  If db = Nil Then Return results

		  Var safe As String = BuildMatchQuery(query)
		  If safe = "" Then Return results

		  Try
		    Var sql As String = "SELECT c.id, c.title, c.chunk_text, c.prev_id, c.next_id, rank " _
		      + "FROM chunks_fts " _
		      + "JOIN chunks c ON c.id = chunks_fts.rowid " _
		      + "WHERE chunks_fts MATCH ? " _
		      + "AND (c.docs_version = ? OR c.docs_version = '' OR c.docs_version = ?) " _
		      + "ORDER BY rank LIMIT ?"
		    Var rs As RowSet = db.SelectSQL(sql, safe, activeVersion, DBHelper.kMBSDocsVersion, limit)

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
		  Var safe As String = BuildMatchQuery(query)
		  If safe <> "" Then
		    Try
		      Var ftsMap As New Dictionary
		      // ORDER BY is load-bearing here too — see HybridSearchChunks's FTS
		      // leg for the full explanation of why an unordered LIMIT silently
		      // drops the actually-relevant rows on a broad OR-matched query.
		      Var ftsRS As RowSet = db.SelectSQL("SELECT rowid, bm25(notes_fts) AS s FROM notes_fts WHERE notes_fts MATCH ? ORDER BY bm25(notes_fts) LIMIT 100", safe)
		      While Not ftsRS.AfterLastRow
		        ftsMap.Value(ftsRS.Column("rowid").IntegerValue) = 1.0 / (1.0 + Exp(ftsRS.Column("s").DoubleValue * 0.5))
		        ftsRS.MoveToNextRow
		      Wend
		      ftsRS.Close
		      // See HybridSearchChunks: NOT CDbl(Variant) — mis-parses a
		      // Double-typed Dictionary Variant under this system's locale.
		      For i As Integer = 0 To rowids.LastIndex
		        If ftsMap.HasKey(rowids(i)) Then ftsScores(i) = ftsMap.Value(rowids(i)).DoubleValue
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

		  Var safe As String = BuildMatchQuery(query)
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

		  Var emb As MemoryBlock = Embedder.FetchEmbedding(query, Embedder.kTaskPrefixQuery, 5)
		  If emb <> Nil Then
		    mCacheLock.Enter
		    mLastEmbQuery = query
		    mLastEmb = emb
		    mCacheLock.Leave
		  End If
		  Return emb
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function GetCachedRerankScore(query As String, limit As Integer) As Double
		  // Reads the best rerank score HybridSearchChunks stashed for this exact
		  // SearchChunks call (same cacheKey formula, same lock). -1 means "no
		  // signal" — either the query hasn't been searched via SearchChunks yet
		  // this call (BuildContext always searches first, so this only happens
		  // if SearchChunks returned early some other way), the reranker never
		  // ran (server down, keyword-only fallback), or a ClearCache landed
		  // between the search and this read.
		  Var cacheKey As String = DBHelper.GetActiveVersion + "|" + query + "|" + limit.ToString
		  mCacheLock.Enter
		  Var result As Double = -1.0
		  If mRerankScoreCache <> Nil And mRerankScoreCache.HasKey(cacheKey) Then
		    // NOT CDbl(Variant) — on this system CDbl mis-parses a Double-typed
		    // Variant as if it were a locale-formatted string (Danish locale:
		    // comma decimal separator), turning e.g. 0.097 into ~9.69e14.
		    // DoubleValue reads the Variant's binary double directly, with no
		    // string round-trip. Confirmed live: raw.StringValue correctly showed
		    // "9.69e-2" while CDbl(raw) returned 969339683651924.125 for the same
		    // Variant. mCache's own RetrievalResult scores never hit this because
		    // they're never boxed through a Dictionary Variant + CDbl round-trip.
		    result = mRerankScoreCache.Value(cacheKey).DoubleValue
		  End If
		  mCacheLock.Leave
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ChunkSearchLimit(query As String) As Integer
		  // A query that names a specific Xojo class (PascalCase word, e.g.
		  // "DesktopWKWebViewControlMBS") is asking about ONE class's API
		  // surface, not a broad topic — the normal kDefaultChunkLimit (4) can
		  // fill up entirely with that class's own chunks (via kClassNameBoost
		  // in HybridSearchChunks) and still miss the one member that actually
		  // answers the question. Confirmed live: asking "how do I show a
		  // webpage with DesktopWKWebViewControlMBS" filled all 4 slots with
		  // CreateWebView (a Type: event, not callable directly), the
		  // read-only URL property, setUsePrivateBrowsing, and an unrelated
		  // WebPage chunk — LoadURL, the actual method that solves this, never
		  // made the cut. The model then alternated between misusing
		  // CreateWebView and misusing URL across repeated tries, because
		  // LoadURL was never in front of it to use instead. Widening the
		  // result count specifically when a class is named gives that
		  // class's other members (methods, not just the ones that happened
		  // to score highest) more room to survive dedup and reach the
		  // reranker. MUST be called with the exact same query by both
		  // MatchStatus and BuildContext — SearchChunks's cache key includes
		  // the limit, so a mismatch here would double the actual search work
		  // and break MatchStatus's "SearchChunks caches, so the real search
		  // here is the same one BuildContext performs" assumption.
		  //
		  // Reuses the same PascalCase heuristic as SymbolCheck's
		  // ExtractPascalCaseWords (starts uppercase, all alnum, has a
		  // lowercase letter — rules out ALL-CAPS acronyms like "URL" or
		  // "HTML" which are common English/tech words, not class names) —
		  // kept as an independent, smaller check here rather than exposing
		  // SymbolCheck's private helper, since the two exist for different
		  // reasons (retrieval breadth vs. a reply-side hallucination check).
		  For Each word As String In query.Split(" ")
		    Var w As String = word
		    While w.Length > 0 And Not IsAlnumQueryChar(w.Left(1))
		      w = w.Middle(1)
		    Wend
		    While w.Length > 0 And Not IsAlnumQueryChar(w.Right(1))
		      w = w.Left(w.Length - 1)
		    Wend
		    If w.Length < kMinClassWordLength Then Continue
		    Var firstCode As Integer = w.Left(1).Asc
		    If firstCode < 65 Or firstCode > 90 Then Continue // must start uppercase
		    Var hasLower As Boolean = False
		    Var allAlnum As Boolean = True
		    For i As Integer = 1 To w.Length - 1
		      Var ch As String = w.Middle(i, 1)
		      If Not IsAlnumQueryChar(ch) Then
		        allAlnum = False
		        Exit
		      End If
		      Var code As Integer = ch.Asc
		      If code >= 97 And code <= 122 Then hasLower = True
		    Next
		    If allAlnum And hasLower Then Return kWidenedChunkLimit
		  Next
		  Return kDefaultChunkLimit
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsAlnumQueryChar(ch As String) As Boolean
		  If ch = "" Then Return False
		  Var code As Integer = ch.Asc
		  Return (code >= 48 And code <= 57) Or (code >= 65 And code <= 90) Or (code >= 97 And code <= 122)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function AllThirdPartyNote() As String
		  // A plain method, not a #tag Constant — CLAUDE.md documents that a
		  // literal comma inside a Constant's default value silently
		  // truncates the string at the project-file level in .xojo_code
		  // too, with no known escape fix (unlike .xojo_window's \x2C). An
		  // ordinary string literal built via concatenation inside a method
		  // body doesn't have this bug (see BaseInstructions/
		  // ClosingReminders, which already do this for long prompt text).
		  //
		  // Public (not Private): XDOXSession.PrepareRequest calls this
		  // directly to build its OWN copy of this text to append after
		  // ClosingReminders — see BuildContext's comment on why the copy
		  // embedded in the context string itself is stripped back out and
		  // never actually sent to the model from there.
		  Return "IMPORTANT: every result below is THIRD-PARTY (MBS plugin) documentation — " _
		    + "none of these results are part of Xojo itself. You do NOT know whether Xojo " _
		    + "has a native (built-in) way to do this — the search did not find one, but " _
		    + "that does NOT mean one doesn't exist; it may simply not have been named in " _
		    + "this conversation. This is a hard rule: do NOT say 'Xojo does not have a " _
		    + "native way' or similar, and do NOT open a reply to 'can I do this with a " _
		    + "native control' with 'No' — instead say you found third-party (MBS) " _
		    + "documentation for this, and that you cannot confirm whether a native " _
		    + "alternative exists unless the user names a specific native class to check."
		End Function
	#tag EndMethod

	#tag Constant, Name = kAllThirdPartyMarker, Type = String, Dynamic = False, Default = \"\x5B__ALL_THIRD_PARTY__\x5D", Scope = Public
	#tag EndConstant

	#tag Method, Flags = &h0
		Function BothSourcesNote() As String
		  // See kAllThirdPartyMarker/AllThirdPartyNote for why this is a
		  // plain method (comma-in-Constant truncation) and why
		  // XDOXSession.PrepareRequest appends its own copy of this text
		  // after ClosingReminders instead of trusting the marker embedded
		  // in the context string to do anything on its own.
		  //
		  // Public: XDOXSession.PrepareRequest calls this directly.
		  Return "IMPORTANT: this context contains BOTH a native Xojo (built-in) result AND a " _
		    + "third-party (MBS plugin) result that both address the user's question — see the " _
		    + "[Native Xojo Docs] and [Third-Party (MBS Plugin) Docs] sections above. This is a " _
		    + "hard rule: you do NOT get to pick a winner between them. You cannot know the " _
		    + "user's license situation, target platforms, or feature needs, so present BOTH as " _
		    + "real options — native first, then the MBS alternative — with a short, neutral " _
		    + "note on the tradeoff (e.g. native needs no extra dependency or license; the MBS " _
		    + "class may offer more features or broader platform support) and let the user choose. " _
		    + "Do NOT lead with only one of them and mention the other as an afterthought, and do " _
		    + "NOT tell the user which one to use — describe both, then stop."
		End Function
	#tag EndMethod

	#tag Constant, Name = kBothSourcesMarker, Type = String, Dynamic = False, Default = \"\x5B__BOTH_SOURCES__\x5D", Scope = Public
	#tag EndConstant

	#tag Method, Flags = &h0
		Function MatchStatus(query As String, conn As SQLiteDatabase = Nil) As String
		  // Hard gate, not advice: a system-prompt marker telling the model "no
		  // match, say so honestly" was implemented first and confirmed live to
		  // NOT reliably stop the model from writing fabricated example code
		  // right after honestly saying a feature doesn't exist — a small local
		  // model treats "admit uncertainty" and "don't then speculate" as
		  // separable instincts, and satisfying the first doesn't suppress the
		  // second. Converting the reranker's signal into CONTROL FLOW (this
		  // status gates whether XDOXSession ever opens a generation request at
		  // all) is the fix: the model cannot fabricate code in a turn it never
		  // receives. Call this before SearchChunks/BuildContext — it's cheap
		  // (SearchChunks caches, so the real search here is the same one
		  // BuildContext performs), and the caller only needs to build/send a
		  // full request on kStatusSupported.
		  //
		  // Returns kStatusSupported, kStatusNoMatch, or kStatusUnavailable
		  // (reranker down/not installed — falls back to ordinary cosine+BM25
		  // chat rather than gating, since the reranker is an improvement layered
		  // on an already-functional pipeline, not a required dependency).
		  Var pinned() As RetrievalResult = PinnedMigrationResults(query, conn)
		  If pinned.Count > 0 Then Return kStatusSupported // curated pin is trusted deterministically

		  Var chunkSearchLimit As Integer = ChunkSearchLimit(query)
		  Call SearchChunks(query, chunkSearchLimit, conn) // populates mRerankScoreCache as a side effect
		  Var rerankBestScore As Double = GetCachedRerankScore(query, chunkSearchLimit)

		  If rerankBestScore < 0.0 Then Return kStatusUnavailable
		  If rerankBestScore < Reranker.kNoMatchThreshold Then
		    App.AppendDebugLog("Retrieval.MatchStatus: NoMatch for """ + query + """ (best rerank score " + Format(rerankBestScore, "0.000") + ")" + EndOfLine)
		    Return kStatusNoMatch
		  End If
		  Return kStatusSupported
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
		  // reads never share the main-thread handle. Caller is expected to have
		  // already checked MatchStatus <> kStatusNoMatch — this function no
		  // longer gates on the reranker score itself (see MatchStatus).
		  Var pinned() As RetrievalResult = PinnedMigrationResults(query, conn)
		  Var docResults() As RetrievalResult = SearchChunks(query, ChunkSearchLimit(query), conn)

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

		  // Task 7: split into native and third-party (MBS) groups so the
		  // context can label each block explicitly instead of presenting
		  // one undifferentiated [Xojo Docs] list — HybridSearchChunks now
		  // guarantees native results come first (see its ordering
		  // comment), so this split preserves that order rather than
		  // re-sorting anything.
		  //
		  // A result is dropped here (not added to either group) if its
		  // OWN rerank score is below kMinRelevanceScore — found live:
		  // ScopedSearch always fills its half of the result budget with
		  // whatever scored best in its pool, even when the best available
		  // is still noise (e.g. a generic "Web QuickStart > Adding code"
		  // tutorial chunk for a QR-code question, because no real native
		  // QR answer exists). The reranker correctly scored that chunk
		  // near zero, but nothing previously acted on a single chunk's own
		  // low score — only on rerankBestScore (the search's best score
		  // overall, used for MatchStatus's no-match gate), which stays
		  // high because the OTHER pool (MBS) has a real answer. Without
		  // this filter, allThirdParty below could never fire once a
		  // native chunk existed at all, however weak — a regression from
		  // Task 6's original guarantee. RerankScore < 0 (reranking didn't
		  // run — pinned results, or the reranker server is down/missing)
		  // is NOT filtered; only a result that WAS scored and scored low
		  // is dropped, so this degrades to "no filtering" gracefully
		  // rather than hiding results when the signal isn't available.
		  Var nativeResults() As RetrievalResult
		  Var mbsResults() As RetrievalResult
		  // "Does this native chunk count as a real native alternative for
		  // Task 7's allThirdParty/bothFound decision" is separate from
		  // "does it belong in the results/context at all" — a chunk tagged
		  // for a DIFFERENT platform than the user is asking about (see
		  // TargetPlatformLabel) still gets shown to the model (Task 5's
		  // hard rule needs it there to correctly say "no desktop-native
		  // class, only a Web-target one"), but must NOT count as "native
		  // was found" here. Found live: a Web-target WebPage chunk scored
		  // 0.68 (genuinely relevant to "show a webpage", just wrong
		  // platform) — well above kMinRelevanceScore, so it survived the
		  // filter above and set bothFound, whose BothSourcesNote then told
		  // the model to "present both as real alternatives, native first"
		  // — directly contradicting Task 5's rule that the answer must
		  // open with "No" when the only supporting class is wrong-platform.
		  // Two hard rules actively fighting each other, same failure shape
		  // as the already-documented Task 5/Task 6 interaction bug.
		  Var wantsNonDesktop As Boolean = QueryNamesNonDesktopPlatform(query)
		  For Each r As RetrievalResult In results
		    // IsGuaranteed chunks (a matched class's own Overview page,
		    // force-included by ScopedSearch specifically so the model can
		    // confirm the class exists) are exempt from this filter — see
		    // RetrievalResult.IsGuaranteed's comment. Without this
		    // exemption, a terse Overview chunk reranking below the floor
		    // against a specific query would be silently dropped here,
		    // undoing the guarantee ScopedSearch just fought to keep.
		    If Not r.IsGuaranteed And r.RerankScore >= 0.0 And r.RerankScore < kMinRelevanceScore Then Continue
		    If r.IsThirdParty Then
		      mbsResults.Add(r)
		    Else
		      nativeResults.Add(r)
		    End If
		  Next

		  // "No native chunk found at all" is now a deterministic fact about
		  // a dedicated, separately-scoped native search (see
		  // Retrieval.ScopedSearch) — not, as before Task 7, an artifact of
		  // native chunks having lost a shared cosine/BM25 race against MBS
		  // chunks (a stray word-boundary class match from folded-in
		  // conversation history could flip that outcome unpredictably; see
		  // the retrieval-quality-backlog memory's Task 6/Task 5 interaction
		  // bug). There is no scalable way to curate "MBS class X's native
		  // equivalent is Y" — MBS's catalog is huge, much of it built
		  // precisely because Xojo has NO native equivalent, so guessing one
		  // exists would trade one hallucination for another. The honest fix
		  // is to make the gap explicit instead of guessing either way.
		  //
		  // "Found" here means "found a genuine, matching-platform native
		  // result" — a native chunk whose own platform label doesn't match
		  // what the user is asking about doesn't count, unless the user's
		  // OWN query explicitly names that other platform (in which case a
		  // Web/iOS/Console/Android result genuinely IS the right answer).
		  Var nativeFoundCount As Integer = 0
		  If wantsNonDesktop Then
		    nativeFoundCount = nativeResults.Count
		  Else
		    For Each r As RetrievalResult In nativeResults
		      If TargetPlatformLabel(r.Title) = "" Then nativeFoundCount = nativeFoundCount + 1
		    Next
		  End If
		  Var allThirdParty As Boolean = (nativeFoundCount = 0 And mbsResults.Count > 0)

		  // Both sides found something comparable — the case Task 7 exists
		  // for. The model cannot know which of native or MBS is "better"
		  // for this user's project (license cost, target platforms,
		  // feature needs are all things only the user knows), so the
		  // correct behavior is to present both as real alternatives and
		  // let the user choose, not silently pick a leader. See
		  // BothSourcesNote — same "short marker here, real instruction
		  // after ClosingReminders" pattern as kAllThirdPartyMarker below.
		  Var bothFound As Boolean = (nativeFoundCount > 0 And mbsResults.Count > 0)

		  // Short markers, not the full note text, are embedded here — the
		  // model largely ignores instructions placed BEFORE a large Context
		  // block (see XDOXSession.ClosingReminders' "burger test" comment),
		  // confirmed live: putting the full AllThirdPartyNote() text at the
		  // top of the docs context did NOT stop the model from opening a
		  // reply with "No, not with a native Xojo control." XDOXSession.
		  // PrepareRequest strips these markers back out of context and
		  // appends the actual note text to sysPrompt AFTER ClosingReminders
		  // instead, where instructions actually stick.
		  Var sb As String = ""
		  If allThirdParty Then
		    sb = sb + kAllThirdPartyMarker + EndOfLine + EndOfLine
		  ElseIf bothFound Then
		    sb = sb + kBothSourcesMarker + EndOfLine + EndOfLine
		  End If

		  If nativeResults.Count > 0 Then
		    sb = sb + "[Native Xojo Docs]" + EndOfLine
		    For di As Integer = 0 To nativeResults.Count - 1
		      If di > 0 Then sb = sb + EndOfLine + "---" + EndOfLine + EndOfLine
		      sb = sb + nativeResults(di).Text
		    Next
		  End If
		  If mbsResults.Count > 0 Then
		    If nativeResults.Count > 0 Then sb = sb + EndOfLine + EndOfLine
		    sb = sb + "[Third-Party (MBS Plugin) Docs]" + EndOfLine
		    For di As Integer = 0 To mbsResults.Count - 1
		      If di > 0 Then sb = sb + EndOfLine + "---" + EndOfLine + EndOfLine
		      sb = sb + mbsResults(di).Text
		    Next
		  End If

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
		  mRerankScoreCache = Nil
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
		  specials.Add("-")
		  specials.Add("?")
		  specials.Add("!")
		  specials.Add(".")
		  specials.Add(",")
		  specials.Add(";")
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

	#tag Method, Flags = &h0
		Function BuildMatchQuery(query As String) As String
		  // FTS5's default MATCH is an implicit AND across all tokens, so a
		  // conversational query ("does xojo have a native way to show a
		  // webpage") almost never matches terse reference text and returns
		  // zero rows. OR-joining lets any token match, so BM25 can still
		  // contribute a signal for natural-language questions.
		  Var safe As String = SanitizeQuery(query)
		  If safe = "" Then Return ""
		  Return String.FromArray(safe.Split(" "), " OR ")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ExtractClassName(title As String, chunkText As String) As String
		  // Two title conventions coexist in chunks: the MBS docset's ItemTitle
		  // text is "ClassName.member..." (dot) — near-universally a real class
		  // member, safe to trust from the title alone. Native Xojo-doc titles
		  // (RST-derived) use "ClassName > member..." (arrow) instead, e.g.
		  // "DesktopHTMLViewer > Overview" — but the SAME arrow shape is also
		  // used by IDE-guide/tutorial sections that aren't classes at all
		  // ("Toolbar > Common members" is the Xojo IDE's own toolbar, unrelated
		  // to the DesktopToolbar control; "Library > Introduction", "Inspector",
		  // "Navigator" are IDE panels). Trusting the arrow form from the title
		  // alone re-creates the exact bug this boost exists to prevent — a
		  // generic page out-ranking the real API chunk — just via IDE guides
		  // instead of tutorials. So an arrow-form candidate is only accepted
		  // when corroborated by the CHUNK TEXT: either this chunk IS the
		  // class's canonical overview page ("ClassName > Overview" titles have
		  // prose bodies, not a repeated dotted signature line, so they're
		  // checked by title suffix), or the chunk is a real member page, whose
		  // body's second line repeats "ClassName.MemberName" — e.g.
		  // "DesktopHTMLViewer > Loadurl" is followed by
		  // "DesktopHTMLViewer.LoadURL" — which guide/tutorial chunks never do.
		  Var dotPos As Integer = title.IndexOf(".")
		  Var arrowPos As Integer = title.IndexOf(" > ")
		  Var sepPos As Integer = dotPos
		  Var isArrow As Boolean = False
		  If arrowPos >= 0 And (dotPos < 0 Or arrowPos < dotPos) Then
		    sepPos = arrowPos
		    isArrow = True
		  End If
		  If sepPos < 4 Then Return ""
		  Var candidate As String = title.Left(sepPos)
		  For i As Integer = 0 To candidate.Length - 1
		    Var ch As String = candidate.Middle(i, 1)
		    Var isAlnum As Boolean = (ch >= "a" And ch <= "z") Or (ch >= "A" And ch <= "Z") Or (ch >= "0" And ch <= "9")
		    If Not isAlnum Then Return ""
		  Next

		  If isArrow Then
		    Var isOverviewTitle As Boolean = title = candidate + " > Overview"
		    Var bodyLine As String = chunkText
		    Var nl As Integer = bodyLine.IndexOf(EndOfLine)
		    If nl >= 0 Then bodyLine = bodyLine.Middle(nl + 1)
		    bodyLine = bodyLine.Trim
		    Var isMemberSignature As Boolean = bodyLine.Left(candidate.Length + 1) = candidate + "."
		    If Not isOverviewTitle And Not isMemberSignature Then Return ""
		  End If

		  Return candidate
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function QueryNamesNonDesktopPlatform(query As String) As Boolean
		  // Whole-word check (not a bare IndexOf substring) for the same
		  // reason QueryNamesClass requires word boundaries — "web" as a
		  // substring would match "webpage", "website" etc. in perfectly
		  // ordinary English, not just an explicit platform mention. Used
		  // by BuildContext to decide whether a Web/iOS/Console/Android
		  // native result should count as a genuine "native was found" for
		  // Task 7's allThirdParty/bothFound logic — it should, ONLY when
		  // the user is actually asking about that platform, not when they
		  // asked a plain "does Xojo have a native way" question and a
		  // wrong-platform chunk happened to score above the noise floor.
		  Var lower As String = " " + query.Lowercase + " "
		  Var candidates() As String = Array(" web ", " ios ", " console ", " android ")
		  For Each c As String In candidates
		    If lower.IndexOf(c) >= 0 Then Return True
		  Next
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function TargetPlatformLabel(title As String) As String
		  // Xojo's native-doc class names carry their target platform as a
		  // naming prefix (DesktopButton, WebPage, iOSCountdownPicker,
		  // ConsoleApplication) — a real, documented Xojo convention, not
		  // something inferred here. Confirmed live: asking "does Xojo have a
		  // native way of showing a webpage" retrieved WebPage (a Web-target
		  // server-side page class whose GotoURL/ExecuteJavaScript methods
		  // read as plausible cosine matches for "webpage") with nothing in
		  // the delivered chunk text distinguishing it from a desktop-app
		  // answer — the model then answered as if WebPage were a general
		  // solution, no caveat. XDOX is a general Xojo assistant, not
		  // Desktop-only (don't exclude Web/iOS/Console classes from
		  // retrieval — the user may genuinely be asking about them) — so the
		  // fix is to make the target explicit to the model rather than to
		  // hide non-Desktop results. Cheap prefix check on the class name
		  // already extracted via ExtractClassName's title parsing; only
		  // labels when a prefix is recognized, so cross-platform classes
		  // (FolderItem, String, Dictionary — the majority of chunks) are
		  // left unlabeled rather than guessed at.
		  Var sepPos As Integer = title.IndexOf(".")
		  Var arrowPos As Integer = title.IndexOf(" > ")
		  If arrowPos >= 0 And (sepPos < 0 Or arrowPos < sepPos) Then sepPos = arrowPos
		  If sepPos < 4 Then Return ""
		  Var candidate As String = title.Left(sepPos)

		  // Exact-case prefix checks — NOT the string >=/<= operators, which
		  // are case-insensitive by default in Xojo (see the "d" >= "A" And
		  // "d" <= "Z" pitfall documented for Retrieval.ExtractClassName's
		  // isAlnum check) and would otherwise make e.g. "desktopfoo" match
		  // "Desktop" too. StartsWithExact does an ordinal (Asc-based)
		  // per-character compare instead.
		  If StartsWithExact(candidate, "Desktop") Then Return "[Desktop-target class] "
		  If StartsWithExact(candidate, "iOS") Then Return "[iOS-target class] "
		  If StartsWithExact(candidate, "Console") Then Return "[Console-target class] "
		  If StartsWithExact(candidate, "Android") Then Return "[Android-target class] "
		  // "Web" alone would also match "WebService"/"WebFile" (still
		  // Web-target, fine) but must not match unrelated words that merely
		  // start with those letters — Xojo's own naming convention already
		  // guarantees a target-prefixed class name is followed by an
		  // uppercase letter (WebPage, not "Webpage"), so require that too.
		  If StartsWithExact(candidate, "Web") And candidate.Length > 3 Then
		    Var nextCode As Integer = candidate.Middle(3, 1).Asc
		    If nextCode >= 65 And nextCode <= 90 Then Return "[Web-target class — server-side web app, not desktop] "
		  End If
		  Return ""
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function StartsWithExact(s As String, prefix As String) As Boolean
		  // Case-SENSITIVE prefix check — String.Left(n) = "..." uses Xojo's
		  // default case-insensitive comparison, which would match
		  // "desktopfoo" against "Desktop" too. Xojo class names always use
		  // the documented capitalization, so an exact match is correct here.
		  If s.Length < prefix.Length Then Return False
		  Var lhs As String = s.Left(prefix.Length)
		  For i As Integer = 0 To prefix.Length - 1
		    If lhs.Middle(i, 1).Asc <> prefix.Middle(i, 1).Asc Then Return False
		  Next
		  Return True
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function QueryNamesClass(queryLower As String, classNameLower As String) As Boolean
		  // A plain IndexOf substring check matches "WebView" inside
		  // "desktopwkwebviewcontrolmbs" — confirmed live: asking about
		  // DesktopWKWebViewControlMBS pulled in WebView's chunks (a
		  // completely unrelated Xojo Web-target class) because "webview" is
		  // a literal substring of the longer class name, which then handed
		  // the model an off-topic "WebView > Overview" chunk it stitched
		  // into inventing a nonexistent "WebBrowser" control. Requiring word
		  // boundaries (neither the character before nor after the match may
		  // be alphanumeric) keeps the intended case — a class name appearing
		  // as its own word/token in a natural-language question — while
		  // rejecting one class name that merely happens to be a substring of
		  // another, longer one. Keep in sync with XMCP SemanticSearch.
		  Var pos As Integer = queryLower.IndexOf(classNameLower)
		  While pos >= 0
		    Var beforeOk As Boolean = (pos = 0) Or Not IsAlnumChar(queryLower.Middle(pos - 1, 1))
		    Var afterPos As Integer = pos + classNameLower.Length
		    Var afterOk As Boolean = (afterPos >= queryLower.Length) Or Not IsAlnumChar(queryLower.Middle(afterPos, 1))
		    If beforeOk And afterOk Then Return True
		    pos = queryLower.IndexOf(pos + 1, classNameLower)
		  Wend
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsAlnumChar(ch As String) As Boolean
		  If ch = "" Then Return False
		  Return (ch >= "a" And ch <= "z") Or (ch >= "A" And ch <= "Z") Or (ch >= "0" And ch <= "9")
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
		Private mRerankScoreCache As Dictionary
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

	// Distinct from Reranker.kNoMatchThreshold (0.9, "is the search's BEST
	// result good enough to answer at all" — gates whether a chat request
	// is sent, see MatchStatus). This is "is THIS SPECIFIC chunk relevant
	// enough to show as one of the two Task 7 sources" — a much lower bar,
	// since a chunk can legitimately be a weak-but-real supporting result.
	// 0.3 is a first cut, not independently validated: chosen to sit
	// comfortably above the noise scores measured live during Task 7
	// testing (0.001-0.117 for chunks confirmed irrelevant — an unrelated
	// IDE-tutorial page for a QR-code question) and comfortably below the
	// weakest genuine positive measured (0.523 for a correct native class
	// competing against a strong MBS alternative). Re-check against a
	// broader query set if a real answer starts being dropped as "not
	// relevant enough" or an irrelevant one keeps slipping through.
	#tag Constant, Name = kMinRelevanceScore, Type = Double, Dynamic = False, Default = \"0.3", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kClassNameBoost, Type = Double, Dynamic = False, Default = \"0.15", Scope = Private
	#tag EndConstant

	// How many of a pool's own Overview-only chunks (ScopedSearch's
	// class-not-named fallback, see the comment there) get added as extra
	// rerank candidates. Measured live: the correct chunk ranked #7 of 556
	// native Overview chunks for the Task 4 repro — an earlier value of 3
	// was measured live to be too small (it excluded rank #7 entirely, so
	// the fallback added two OTHER Overview chunks and never gave the
	// reranker a chance to see the right one). 10 gives real margin above
	// #7 without materially growing the reranker's per-turn batch size.
	#tag Constant, Name = kOverviewFallbackCount, Type = Double, Dynamic = False, Default = \"10", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kDefaultChunkLimit, Type = Double, Dynamic = False, Default = \"4", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kWidenedChunkLimit, Type = Double, Dynamic = False, Default = \"7", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kMinClassWordLength, Type = Double, Dynamic = False, Default = \"4", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kStatusSupported, Type = String, Dynamic = False, Default = \"supported", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kStatusNoMatch, Type = String, Dynamic = False, Default = \"no_match", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kStatusUnavailable, Type = String, Dynamic = False, Default = \"unavailable", Scope = Public
	#tag EndConstant


End Module
#tag EndModule
