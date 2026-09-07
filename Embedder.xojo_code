#tag Module
Protected Module Embedder
	#tag Method, Flags = &h0
		Function CosineSimilarity(a As MemoryBlock, b As MemoryBlock) As Double
		  If a = Nil Or b = Nil Then Return 0
		  Var count As Integer = a.Size \ 4
		  If b.Size \ 4 < count Then count = b.Size \ 4

		  Var dot As Double = 0
		  Var na As Double = 0
		  Var nb As Double = 0
		  For i As Integer = 0 To count - 1
		    Var ai As Double = a.SingleValue(i * 4)
		    Var bi As Double = b.SingleValue(i * 4)
		    dot = dot + ai * bi
		    na = na + ai * ai
		    nb = nb + bi * bi
		  Next
		  If na = 0 Or nb = 0 Then Return 0
		  Return dot / (Sqrt(na) * Sqrt(nb))
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function EmbedBatch(texts() As String, taskPrefix As String, timeoutSeconds As Integer = 30) As MemoryBlock()
		  // POST /v1/embeddings on the local embedding server. Returns one
		  // float32-LE MemoryBlock per input (Nil per slot on failure) or an empty
		  // array when the whole request failed. SendSync blocks the CALLING
		  // thread only — fine on IndexerThread, keep timeouts short on Main.
		  //
		  // taskPrefix: nomic-embed-text-v1.5 is trained on Nomic's asymmetric
		  // task-instruction convention and requires it for good retrieval —
		  // pass kTaskPrefixDocument for indexed chunk/note text, kTaskPrefixQuery
		  // for a user's search query. Always pass one; there is no "no prefix"
		  // mode because the model was never trained on unprefixed text.
		  Var result() As MemoryBlock
		  If texts.Count = 0 Then Return result

		  Var body As New JSONItem
		  body.Value("model") = kEmbedModelFile
		  Var input As New JSONItem
		  For Each t As String In texts
		    // nomic's context is hard-capped at 2048 tokens (llama-server clamps
		    // --ctx-size to the model's training limit). Truncate dense chunks:
		    // a truncated vector still retrieves; BM25 covers the full text.
		    // Truncate BEFORE prefixing so the prefix never eats into the budget.
		    If t.Length > kMaxEmbedChars Then t = t.Left(kMaxEmbedChars)
		    input.Add(taskPrefix + t)
		  Next
		  body.Value("input") = input

		  Var raw As String
		  Var conn As New URLConnection
		  Try
		    conn.SetRequestContent(body.ToString, "application/json")
		    raw = conn.SendSync("POST", ModelManager.EmbedBaseURL() + "/v1/embeddings", timeoutSeconds)
		  Catch e As RuntimeException
		    App.AppendDebugLog("Embedder.EmbedBatch: " + e.Message + EndOfLine)
		    Return result
		  End Try
		  If conn.HTTPStatusCode <> 200 Then
		    App.AppendDebugLog("Embedder.EmbedBatch: HTTP " + conn.HTTPStatusCode.ToString + " — " + raw.Left(200) + EndOfLine)
		    Return result
		  End If

		  Return ParseBatchResponse(raw, texts.Count)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function FetchEmbedding(text As String, taskPrefix As String, timeoutSeconds As Integer = 5) As MemoryBlock
		  Var texts() As String
		  texts.Add(text)
		  Var results() As MemoryBlock = EmbedBatch(texts, taskPrefix, timeoutSeconds)
		  If results.Count = 0 Then Return Nil
		  Return results(0)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ParseBatchResponse(json As String, expectedCount As Integer) As MemoryBlock()
		  // Response: {"data":[{"index":0,"embedding":[f1,...]},...]}
		  Var result() As MemoryBlock
		  Try
		    Var root As New JSONItem(json)
		    If Not root.HasKey("data") Then Return result
		    Var dataArray As JSONItem = root.Child("data")
		    If dataArray = Nil Or dataArray.Count = 0 Then Return result

		    result.ResizeTo(expectedCount - 1)
		    For d As Integer = 0 To dataArray.Count - 1
		      Var item As JSONItem = dataArray.ChildAt(d)
		      If Not item.HasKey("embedding") Then Continue
		      Var embArray As JSONItem = item.Child("embedding")
		      If embArray = Nil Then Continue

		      Var idx As Integer = d
		      If item.HasKey("index") Then idx = item.Value("index").IntegerValue
		      If idx < 0 Or idx > result.LastIndex Then Continue

		      Var floatCount As Integer = embArray.Count
		      If floatCount <> kEmbeddingDim Then
		        App.AppendDebugLog("Embedder: unexpected dim " + floatCount.ToString + " (expected " + kEmbeddingDim.ToString + ")" + EndOfLine)
		        Continue
		      End If

		      Var mb As New MemoryBlock(floatCount * 4)
		      mb.LittleEndian = True
		      For i As Integer = 0 To floatCount - 1
		        mb.SingleValue(i * 4) = CDbl(embArray.ValueAt(i))
		      Next
		      result(idx) = mb
		    Next
		  Catch e As RuntimeException
		    App.AppendDebugLog("Embedder.ParseBatchResponse: " + e.Message + EndOfLine)
		  End Try
		  Return result
		End Function
	#tag EndMethod


	#tag Method, Flags = &h0
		Function ClaimPendingBatch(db As SQLiteDatabase, sourceFilter As String, batchSize As Integer, ids() As Integer, texts() As String) As Boolean
		  // Atomically reserves up to batchSize pending rows for the CALLING
		  // connection's exclusive use, then reads them back. Needed because
		  // EmbedPendingChunks now runs up to 2 EmbedWorkers concurrently, each
		  // on its own SQLiteDatabase connection — a bare "SELECT ... WHERE
		  // embedded=0 LIMIT n" would let two workers select the same rows.
		  // embedded=-2 is a new "claimed, in flight" sentinel (0=pending,
		  // 1=done, -1=permanently failed were the only values used before
		  // this).
		  //
		  // The candidate id list is read FIRST (still WHERE embedded=0), then
		  // claimed by THOSE EXACT ids, then re-read by THOSE EXACT ids — not
		  // by re-querying "whatever is embedded=-2 right now". A first version
		  // did claim-then-reselect-by-status (UPDATE ... embedded=-2, then
		  // SELECT WHERE embedded=-2), which is a real race with 2 concurrent
		  // workers: if worker B's claim UPDATE runs between worker A's claim
		  // UPDATE and worker A's own SELECT, A's unscoped "WHERE embedded=-2"
		  // sees BOTH workers' claimed rows and double-processes some of them —
		  // confirmed live, 2026-08-30: a native reindex's embed progress
		  // reported "16,104 of 15,000" and stopped at exactly 30,000, 2x the
		  // real ~15,000 total, i.e. every row processed roughly twice. No
		  // RETURNING clause is used anywhere else in this codebase, so this
		  // still claims via UPDATE...WHERE id IN (...) rather than assuming
		  // RETURNING is supported here — the fix is scoping every step to a
		  // fixed id list computed once per call, not the mutable -2 status.
		  ids.ResizeTo(-1)
		  texts.ResizeTo(-1)
		  Try
		    Var candidateIds() As Integer
		    Var whereClause As String = "embedded=0"
		    If sourceFilter <> "" Then whereClause = whereClause + " AND source LIKE ?"
		    Var candRs As RowSet
		    If sourceFilter <> "" Then
		      candRs = db.SelectSQL("SELECT id FROM chunks WHERE " + whereClause + " LIMIT " + batchSize.ToString, sourceFilter)
		    Else
		      candRs = db.SelectSQL("SELECT id FROM chunks WHERE " + whereClause + " LIMIT " + batchSize.ToString)
		    End If
		    While Not candRs.AfterLastRow
		      candidateIds.Add(candRs.Column("id").IntegerValue)
		      candRs.MoveToNextRow
		    Wend
		    candRs.Close
		    If candidateIds.Count = 0 Then Return False

		    Var idList() As String
		    For Each cid As Integer In candidateIds
		      idList.Add(cid.ToString)
		    Next
		    Var idsSQL As String = Join(idList, ",")

		    db.ExecuteSQL("UPDATE chunks SET embedded=-2 WHERE id IN (" + idsSQL + ") AND embedded=0")

		    Var rs As RowSet = db.SelectSQL("SELECT id, chunk_text FROM chunks WHERE id IN (" + idsSQL + ") AND embedded=-2")
		    While Not rs.AfterLastRow
		      ids.Add(rs.Column("id").IntegerValue)
		      texts.Add(rs.Column("chunk_text").StringValue)
		      rs.MoveToNextRow
		    Wend
		    rs.Close
		  Catch e As DatabaseException
		    App.AppendDebugLog("Embedder.ClaimPendingBatch: " + e.Message + EndOfLine)
		    Return False
		  End Try
		  Return ids.Count > 0
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub EmbedPendingChunks(db As SQLiteDatabase, owner As Thread, sourceFilter As String = "", stopSignal As StopSignal = Nil)
		  // Shared by IndexerThread and MBSIndexerThread (pass kMBSSourcePrefix
		  // + "%" as sourceFilter for the MBS case). Single-writer queue
		  // pipeline: one EmbedWriter owns the only DB connection used during
		  // this phase (claims batches, writes results); N EmbedWorkers do
		  // ONLY the slow HTTP EmbedBatch call, with no DB access at all,
		  // matched to the embed server's --parallel slot count (both sized
		  // by ModelManager.ChooseEmbedParallelCount from physical RAM — see
		  // its own comment). An earlier design gave each EmbedWorker its own
		  // connection, serialized via a shared CriticalSection — that avoided
		  // double-processing but still hit real WAL write-lock contention
		  // live (confirmed via "database is locked" DatabaseExceptions and
		  // visible multi-second stalls). A single writer removes that
		  // contention structurally rather than coordinating around it.
		  If db = Nil Then Return

		  Var total As Integer
		  If sourceFilter <> "" Then
		    Var rs As RowSet = db.SelectSQL("SELECT COUNT(*) AS n FROM chunks WHERE (embedded=0 OR embedded=-2) AND source LIKE ?", sourceFilter)
		    total = rs.Column("n").IntegerValue
		    rs.Close
		  Else
		    Var rs As RowSet = db.SelectSQL("SELECT COUNT(*) AS n FROM chunks WHERE embedded=0 OR embedded=-2")
		    total = rs.Column("n").IntegerValue
		    rs.Close
		  End If
		  // Includes leftover embedded=-2 rows from a prior aborted run in the
		  // total up front, since EmbedWriter's own crash-recovery reset (its
		  // first step) folds them back into embedded=0 before claiming.
		  If total = 0 Then Return
		  owner.AddUserInterfaceUpdate(New Pair("type", "embed-progress"), New Pair("done", 0), New Pair("total", total))

		  Var workQueue As New EmbedQueue
		  Var resultQueue As New EmbedQueue

		  Var workerCount As Integer = ModelManager.ChooseEmbedParallelCount()
		  Var workers() As EmbedWorker
		  For w As Integer = 1 To workerCount
		    Var worker As New EmbedWorker
		    worker.WorkQueue = workQueue
		    worker.ResultQueue = resultQueue
		    workers.Add(worker)
		    worker.Start
		  Next

		  Var writer As New EmbedWriter
		  writer.SourceFilter = sourceFilter
		  writer.Total = total
		  writer.Owner = owner
		  writer.WorkQueue = workQueue
		  writer.ResultQueue = resultQueue
		  writer.Workers = workers
		  writer.Start

		  // Cooperative Threads: SleepCurrent yields this call's own thread
		  // (IndexerThread/MBSIndexerThread) so writer/workers actually get
		  // scheduled while we wait. Waiting on the writer alone is sufficient
		  // — its own Run only exits after confirming both workers are idle
		  // and both queues are empty (see EmbedWriter.Run's termination
		  // comment), and it sets StopRequested on both workers before
		  // returning, so they exit their own poll loops right after.
		  //
		  // Polls stopSignal (IndexProgressWindow's Pause button, relayed via
		  // IndexerThread/MBSIndexerThread's own StopEmbeddingRequested
		  // property — a plain StopSignal object, not an interface method;
		  // an earlier version of this tried a second Implements interface
		  // on IndexerThread/MBSIndexerThread for this, which broke passing
		  // Self as MBSDocsetParser.Parse's MBSParseProgressDelegate
		  // parameter at runtime — see CLAUDE.md's Xojo file conventions
		  // section) and relays True into writer.StopRequested the same way
		  // progress itself is relayed.
		  While writer.ThreadState <> Thread.ThreadStates.NotRunning
		    If stopSignal <> Nil And stopSignal.Requested Then writer.StopRequested = True
		    Thread.SleepCurrent(50)
		  Wend
		End Sub
	#tag EndMethod

	#tag Constant, Name = kBatchSize, Type = Double, Dynamic = False, Default = \"8", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kEmbedModelFile, Type = String, Dynamic = False, Default = \"nomic-embed-text.gguf", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kMaxEmbedChars, Type = Double, Dynamic = False, Default = \"6000", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kEmbeddingDim, Type = Double, Dynamic = False, Default = \"768", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kTaskPrefixDocument, Type = String, Dynamic = False, Default = \"search_document: ", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kTaskPrefixQuery, Type = String, Dynamic = False, Default = \"search_query: ", Scope = Public
	#tag EndConstant


End Module
#tag EndModule
