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
		Function EmbedBatch(texts() As String, timeoutSeconds As Integer = 30) As MemoryBlock()
		  // POST /v1/embeddings on the local embedding server. Returns one
		  // float32-LE MemoryBlock per input (Nil per slot on failure) or an empty
		  // array when the whole request failed. SendSync blocks the CALLING
		  // thread only — fine on IndexerThread, keep timeouts short on Main.
		  Var result() As MemoryBlock
		  If texts.Count = 0 Then Return result

		  Var body As New JSONItem
		  body.Value("model") = kEmbedModelFile
		  Var input As New JSONItem
		  For Each t As String In texts
		    // nomic's context is hard-capped at 2048 tokens (llama-server clamps
		    // --ctx-size to the model's training limit). Truncate dense chunks:
		    // a truncated vector still retrieves; BM25 covers the full text.
		    If t.Length > kMaxEmbedChars Then t = t.Left(kMaxEmbedChars)
		    input.Add(t)
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
		Function FetchEmbedding(text As String, timeoutSeconds As Integer = 5) As MemoryBlock
		  Var texts() As String
		  texts.Add(text)
		  Var results() As MemoryBlock = EmbedBatch(texts, timeoutSeconds)
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


	#tag Constant, Name = kBatchSize, Type = Double, Dynamic = False, Default = \"8", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kEmbedModelFile, Type = String, Dynamic = False, Default = \"nomic-embed-text.gguf", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kMaxEmbedChars, Type = Double, Dynamic = False, Default = \"6000", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kEmbeddingDim, Type = Double, Dynamic = False, Default = \"768", Scope = Public
	#tag EndConstant


End Module
#tag EndModule
