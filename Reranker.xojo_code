#tag Module
Protected Module Reranker
	#tag Method, Flags = &h0
		Function RerankBatch(query As String, candidates() As String, timeoutSeconds As Integer = 25) As Double()
		  // POST /v1/rerank on the local reranker server. Returns one relevance
		  // score per candidate (0.0 per slot on failure) or an empty array when
		  // the whole request failed / the server isn't up — callers MUST treat an
		  // empty result as "reranking unavailable, keep the existing cosine+BM25
		  // order" rather than a hard failure, same graceful-degradation contract
		  // as Embedder.FetchEmbedding returning Nil. SendSync blocks the CALLING
		  // thread only — Retrieval only calls this from ChatPrepThread's worker.
		  //
		  // Default raised from 10s (Task 7, 2026-08-28): the 10s default was
		  // set for the 0.6B model. After upgrading to Qwen3-Reranker-4B (~7x
		  // the parameters), a live batch of 7 candidates timed out at 10s —
		  // confirmed via "Reranker.RerankBatch: Anmodningen udløb." in the
		  // debug log — silently falling back to unranked cosine+BM25 order
		  // for that turn, which let an MBS-only chunk (no TargetPlatformLabel
		  // signal ever gets applied without a successful rerank pass) get
		  // presented as if it were native. 25s is a first-cut increase, not
		  // independently measured against the 4B model's real latency
		  // distribution — revisit if timeouts keep happening even at this
		  // value, or lower it if 4B turns out to reliably finish well under
		  // it in practice.
		  Var result() As Double
		  If candidates.Count = 0 Then Return result

		  Var body As New JSONItem
		  body.Value("model") = kRerankModelFile
		  // Qwen3-Reranker is trained on an "Instruct: {task}\nQuery: {query}"
		  // input, not a bare query string — the model card documents this
		  // (default instruction: "Given a web search query, retrieve
		  // relevant passages that answer the query") and community reports
		  // measure 1-5% accuracy gains from using a task-specific
		  // instruction over the default. Confirmed live during Task 7
		  // testing: without this prefix, the 0.6B model scored a completely
		  // unrelated IDE-tutorial chunk (generic "Navigator/Editor/Library"
		  // prose that happens to repeat "web page") at 0.99 relevance
		  // against "Does Xojo have a native way to show a webpage in a
		  // desktop app?" — well above kNoMatchThreshold, so MatchStatus's
		  // no-match gate never caught it and the model hallucinated a
		  // nonexistent "WebBrowser" class instead. With this instruction
		  // prefix (still on the 0.6B model), the true-positive/false-positive
		  // gap widened enough to be usable; combined with the kRerankModelFile
		  // upgrade below (4B), the gap became reliably decisive.
		  body.Value("query") = "Instruct: " + kRerankInstruction() + EndOfLine + "Query: " + query
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


	#tag Constant, Name = kRerankModelFile, Type = String, Dynamic = False, Default = \"qwen3-reranker-4b-q8_0.gguf", Scope = Public
	#tag EndConstant

	#tag Method, Flags = &h0
		Function kRerankInstruction() As String
		  // A plain method, not a #tag Constant — see AllThirdPartyNote in
		  // Retrieval.xojo_code for why a literal comma in a Constant's
		  // default value silently truncates it at the project-file level.
		  // This string has no comma today, but keeping the same
		  // method-not-constant convention for any prompt text avoids ever
		  // having to remember the rule mid-edit.
		  Return "Given a question about Xojo (desktop/web/iOS/console/Android app development), retrieve documentation passages that directly and specifically answer it."
		End Function
	#tag EndMethod

	#tag Constant, Name = kMaxRerankChars, Type = Double, Dynamic = False, Default = \"6000", Scope = Public
	#tag EndConstant

	// 0.9 was validated in the original 16-query test set (0/8 false
	// positives, 1/8 false negative) — but that validation ran against the
	// 0.6B model WITHOUT the Instruct/Query prompt format (see
	// kRerankInstruction/RerankBatch). Both changed together (Task 7,
	// 2026-08-28) after a live false positive: the 0.6B model, called with
	// a bare query string, scored an unrelated IDE-tutorial chunk at 0.99
	// relevance against a genuinely answerable question, so MatchStatus's
	// no-match gate never caught it. Switching to the 4B model AND adding
	// the instruction prefix widened the true/false-positive gap enough to
	// fix that specific repro (0.92 true positive vs 0.52 false positive,
	// measured directly against the rerank server, bypassing XDOX). This
	// value has NOT been re-validated against a broad query set under the
	// new model+prompt combination — only against the two known false
	// positives found in Task 7 testing. Re-check against a broader query
	// set (ideally the original 16, plus these two) before trusting this
	// threshold the way the old value was trusted.
	#tag Constant, Name = kNoMatchThreshold, Type = Double, Dynamic = False, Default = \"0.9", Scope = Public
	#tag EndConstant


End Module
#tag EndModule
