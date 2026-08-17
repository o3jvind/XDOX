#tag Module
Protected Module Reranker
	#tag Method, Flags = &h0
		Function RerankBatch(query As String, candidates() As String, timeoutSeconds As Integer = 10) As Double()
		  // POST /v1/rerank on the local reranker server. Returns one relevance
		  // score per candidate (0.0 per slot on failure) or an empty array when
		  // the whole request failed / the server isn't up — callers MUST treat an
		  // empty result as "reranking unavailable, keep the existing cosine+BM25
		  // order" rather than a hard failure, same graceful-degradation contract
		  // as Embedder.FetchEmbedding returning Nil. SendSync blocks the CALLING
		  // thread only — Retrieval only calls this from ChatPrepThread's worker.
		  Var result() As Double
		  If candidates.Count = 0 Then Return result

		  Var body As New JSONItem
		  body.Value("model") = kRerankModelFile
		  body.Value("query") = query
		  Var docs As New JSONItem
		  For Each c As String In candidates
		    // Same truncation reasoning as Embedder.kMaxEmbedChars: a truncated
		    // candidate can still be scored; it just loses signal from its tail.
		    If c.Length > kMaxRerankChars Then c = c.Left(kMaxRerankChars)
		    docs.Add(c)
		  Next
		  body.Value("documents") = docs

		  Var raw As String
		  Var conn As New URLConnection
		  Try
		    conn.SetRequestContent(body.ToString, "application/json")
		    raw = conn.SendSync("POST", ModelManager.RerankBaseURL() + "/v1/rerank", timeoutSeconds)
		  Catch e As RuntimeException
		    App.AppendDebugLog("Reranker.RerankBatch: " + e.Message + EndOfLine)
		    Return result
		  End Try
		  If conn.HTTPStatusCode <> 200 Then
		    App.AppendDebugLog("Reranker.RerankBatch: HTTP " + conn.HTTPStatusCode.ToString + " — " + raw.Left(200) + EndOfLine)
		    Return result
		  End If

		  Return ParseRerankResponse(raw, candidates.Count)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ParseRerankResponse(json As String, expectedCount As Integer) As Double()
		  // Response: {"results":[{"index":0,"relevance_score":0.97},...]} — index-
		  // keyed and defensively parsed the same way Embedder.ParseBatchResponse
		  // is, so one malformed entry doesn't fail the whole batch.
		  Var result() As Double
		  Try
		    Var root As New JSONItem(json)
		    If Not root.HasKey("results") Then Return result
		    Var resultsArray As JSONItem = root.Child("results")
		    If resultsArray = Nil Or resultsArray.Count = 0 Then Return result

		    result.ResizeTo(expectedCount - 1)
		    For i As Integer = 0 To expectedCount - 1
		      result(i) = 0.0
		    Next

		    For d As Integer = 0 To resultsArray.Count - 1
		      Var item As JSONItem = resultsArray.ChildAt(d)
		      If Not item.HasKey("relevance_score") Then Continue

		      Var idx As Integer = d
		      If item.HasKey("index") Then idx = item.Value("index").IntegerValue
		      If idx < 0 Or idx > result.LastIndex Then Continue

		      result(idx) = item.Value("relevance_score").DoubleValue
		    Next
		  Catch e As RuntimeException
		    App.AppendDebugLog("Reranker.ParseRerankResponse: " + e.Message + EndOfLine)
		  End Try
		  Return result
		End Function
	#tag EndMethod


	#tag Constant, Name = kRerankModelFile, Type = String, Dynamic = False, Default = \"qwen3-reranker-0.6b.gguf", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kMaxRerankChars, Type = Double, Dynamic = False, Default = \"6000", Scope = Public
	#tag EndConstant

	// 0.9 is the value validated in the original 16-query test set (0/8 false
	// positives, 1/8 false negative). A SYNTHETIC (not live) test with
	// hand-typed candidate text found a believable near-miss risk: a query
	// containing "type detection" scored 0.857 against a chunk about Xojo's
	// static type system (surface "type" vocabulary overlap, wrong sense) —
	// that number was never reproduced against the real production
	// chunk_text, and a threshold of 0.85 would NOT have caught it anyway
	// (0.857 > 0.85). Left at the original validated 0.9 rather than acting
	// on that unreproduced synthetic number. Live production runs of the
	// real CSV repro scored 0.005–0.097, comfortably under 0.9. Re-check
	// against a broader query set if false-positive "no match" reports show
	// up on genuinely answerable questions.
	#tag Constant, Name = kNoMatchThreshold, Type = Double, Dynamic = False, Default = \"0.9", Scope = Public
	#tag EndConstant


End Module
#tag EndModule
