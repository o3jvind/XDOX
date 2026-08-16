#tag Class
Public Class XDOXSession

	#tag Method, Flags = &h0
		Sub Constructor(theDelegate As XDOXSessionDelegate)
		  mDelegate = theDelegate
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function BaseInstructions() As String
		  Return "You are XDOX, an expert assistant for the Xojo programming language. " _
		    + "You help developers understand Xojo APIs, solve coding problems, and write idiomatic Xojo code." _
		    + EndOfLine + EndOfLine _
		    + "CRITICAL: Always write code examples in modern Xojo (API 2) syntax only. " _
		    + "Xojo uses 'Var x As Type', arrays are declared as 'Var items() As FolderItem', " _
		    + "and items are added with 'items.Add(item)'. " _
		    + "Never use TypeScript, JavaScript, Swift, or any other language." _
		    + EndOfLine + EndOfLine _
		    + "The documentation context contains only modern API 2 pages, plus deprecation lists and " _
		    + "migration notes that map old API 1 names to their replacements (e.g. MsgBox → MessageBox, " _
		    + "PushButton → DesktopButton, Date → DateTime, 'Dim' → 'Var'). The old names still compile — " _
		    + "they are deprecated, not invalid — so never claim a legacy name is an error; when one comes " _
		    + "up, name the modern replacement and answer in terms of it. Write your own code examples " _
		    + "exclusively in modern API 2 form unless the user explicitly asks about legacy code." _
		    + EndOfLine + EndOfLine _
		    + "Answer concisely and accurately. Use Markdown formatting for code examples. " _
		    + "Start every reply with the substance — never with flattery or filler like 'Great question' " _
		    + "or 'You're absolutely right'. When the user asks whether something exists or is true, open " _
		    + "with the fact itself ('Xojo has a JSONItem class...'), not with praise or validation. " _
		    + "Ground every factual claim about Xojo — APIs, syntax, class members, version history, " _
		    + "recommendations — in the Context section below, and copy method signatures and calling " _
		    + "styles exactly as the context shows them (for example, a setter documented with Assigns is " _
		    + "written 'item.Value(""key"") = x', not 'item.Value(""key"", x)'). Example code must be " _
		    + "valid Xojo that compiles: create objects with New before using them, and JSON itself only " _
		    + "allows double-quoted strings — never write a JSON literal with single quotes. If the " _
		    + "context does not cover something and you are not certain of it, say plainly that you don't " _
		    + "know — do not invent APIs, behaviours, or history." _
		    + EndOfLine + EndOfLine _
		    + "NEVER fabricate sources or evidence. Do not invent quotes, forum posts, URLs, blog " _
		    + "articles, conference talks, named people, statistics, or version numbers. Only quote text " _
		    + "or cite a URL if it appears in the context. If asked where your information comes from, " _
		    + "answer honestly: the documentation context you were given, or your general training — " _
		    + "never claim to have searched the web or read a forum." _
		    + EndOfLine + EndOfLine _
		    + "When your own training knowledge and the documentation context disagree, or when the " _
		    + "context doesn't mention something you recall from training, always defer to the context " _
		    + "and say what it — or its absence — actually shows. Training-knowledge recall is not a " _
		    + "substitute for checking the context: a class, method, or property you 'remember' but that " _
		    + "isn't in the context is not confirmed to exist, and a plausible-sounding API name from " _
		    + "training is exactly how a wrong answer happens. If the context doesn't contain something, " _
		    + "say so plainly instead of filling the gap from memory." _
		    + EndOfLine + EndOfLine _
		    + "When the user pushes back on something you said, do not reflexively agree. Re-check the " _
		    + "context: if it supports your answer, stand by it and point to the documentation; if you " _
		    + "were wrong, admit it in one sentence and give the correction. Never invent supporting " _
		    + "evidence to defend an earlier claim." _
		    + EndOfLine + EndOfLine _
		    + "When the user's message includes their own notes, treat them as authoritative: " _
		    + "incorporate what they say into your answer and mention that it comes from the user's notes."
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ClosingReminders() As String
		  // Appended AFTER the RAG context. Same lesson as the notes preamble
		  // (the burger test): this model ignores instructions buried before a
		  // large Context block — style rules only stick when they come last.
		  Return "Final reminders (these override any habits from your training): " _
		    + "Never answer from training-knowledge memory alone — verify every class, method, and " _
		    + "property name against the Context above, even when you feel certain. If it isn't in the " _
		    + "Context, say you don't know rather than naming something you merely recall. " _
		    + "Start your reply directly with the substance — never 'You're absolutely right', " _
		    + "'Great question' or other praise or validation. " _
		    + "JSON strings use double quotes only — never single quotes. " _
		    + "In Xojo code an embedded double quote is written by doubling it ("""") — " _
		    + "never with a backslash escape like \"". " _
		    + "Objects must be created with New before use. " _
		    + "Only state what the documentation context supports."
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function BuildRequestJSON(sysPrompt As String, userMessage As String) As String
		  Var body As New JSONItem
		  Var messages As New JSONItem

		  Var sys As New JSONItem
		  sys.Value("role") = "system"
		  sys.Value("content") = sysPrompt
		  messages.Add(sys)

		  For Each p As Pair In mHistory
		    Var m As New JSONItem
		    m.Value("role") = p.Left.StringValue
		    m.Value("content") = p.Right.StringValue
		    messages.Add(m)
		  Next

		  Var usr As New JSONItem
		  usr.Value("role") = "user"
		  usr.Value("content") = userMessage
		  messages.Add(usr)

		  body.Value("messages") = messages
		  body.Value("stream") = True
		  body.Value("cache_prompt") = True
		  // Factual-assistant sampling. llama-server's defaults (temperature 0.8)
		  // are tuned for creative chat and let small models free-associate fake
		  // facts and citations. Not 0.0 either — pure greedy decoding can trap
		  // Qwen-family models in repetition loops.
		  body.Value("temperature") = 0.3
		  body.Value("top_p") = 0.9
		  Return body.ToString
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub CleanupConnection()
		  If mConn <> Nil Then
		    RemoveHandler mConn.ReceivingProgressed, AddressOf OnReceivingProgressed
		    RemoveHandler mConn.ContentReceived, AddressOf OnContentReceived
		    RemoveHandler mConn.Error, AddressOf OnConnectionError
		    mConn = Nil
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub FinishResponse()
		  // Commit the exchange to history (partial replies included — a stopped
		  // generation still happened from the model's point of view).
		  If mCurrentUserMessage <> "" Then
		    mHistory.Add(New Pair("user", mCurrentUserMessage))
		    mHistory.Add(New Pair("assistant", mCurrentReply))
		  End If
		  mCurrentUserMessage = ""
		  mCurrentReply = ""
		  mSSEBuffer = ""
		  IsResponding = False
		  CleanupConnection
		  If mDelegate <> Nil Then mDelegate.OnDone
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub FailResponse(message As String)
		  mCurrentUserMessage = ""
		  mCurrentReply = ""
		  mSSEBuffer = ""
		  IsResponding = False
		  CleanupConnection
		  If mDelegate <> Nil Then mDelegate.OnError(message)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnConnectionError(sender As URLConnection, err As RuntimeException)
		  #Pragma Unused sender
		  If Not IsResponding Then Return // already finished or stopped
		  App.AppendDebugLog("XDOXSession connection error: " + err.Message + EndOfLine)
		  If ModelManager.ServerReady Then
		    FailResponse("Could not reach the model. Please try again.")
		  Else
		    FailResponse("Model is still loading — try again in a moment.")
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnContentReceived(sender As URLConnection, url As String, httpStatus As Integer, content As String)
		  #Pragma Unused sender
		  #Pragma Unused url
		  If Not IsResponding Then Return // stopped by the user mid-flight

		  If httpStatus <> 200 Then
		    App.AppendDebugLog("XDOXSession HTTP " + httpStatus.ToString + ": " + content.Left(500) + EndOfLine)
		    If httpStatus = 503 Then
		      FailResponse("Model is still loading — try again in a moment.")
		    Else
		      FailResponse("Model request failed (HTTP " + httpStatus.ToString + ").")
		    End If
		    Return
		  End If

		  // Tokens already arrived via ReceivingProgressed; flush any tail still
		  // in the SSE buffer — isFinal=True because there is no more data
		  // coming, so an unterminated last line is still complete, not a
		  // partial split — then finalize.
		  ProcessSSEChunk("", True)
		  FinishResponse
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnReceivingProgressed(sender As URLConnection, bytesReceived As Int64, totalBytes As Int64, newData As String)
		  #Pragma Unused sender
		  #Pragma Unused bytesReceived
		  #Pragma Unused totalBytes
		  If Not IsResponding Then Return
		  If newData = "" Then Return
		  ProcessSSEChunk(newData, False)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ProcessSSEChunk(newData As String, isFinal As Boolean = False)
		  // Accumulate raw bytes, emit only complete lines; an SSE event or even a
		  // multi-byte UTF-8 character can be split across network chunks, so the
		  // trailing partial line normally stays in the buffer until its newline
		  // arrives. On the final call (isFinal, from OnContentReceived) no more
		  // bytes are coming, so any remaining buffered text IS a complete line
		  // even without a trailing newline — e.g. a server that closes the
		  // connection right after its last "data: ..." line — and must be
		  // parsed here or it's silently dropped.
		  mSSEBuffer = mSSEBuffer + newData
		  If mSSEBuffer = "" Then Return // stream ended cleanly on a newline; nothing to flush
		  Var lines() As String = mSSEBuffer.Split(Chr(10))
		  If lines.LastIndex < 0 Then // Split("") returns an EMPTY array, not [""]
		    mSSEBuffer = ""
		    Return
		  End If
		  Var completeCount As Integer = lines.LastIndex - 1
		  If isFinal Then
		    mSSEBuffer = ""
		    completeCount = lines.LastIndex
		  Else
		    mSSEBuffer = lines(lines.LastIndex) // possibly-incomplete tail
		  End If
		  For i As Integer = 0 To completeCount
		    Var line As String = DefineEncoding(lines(i), Encodings.UTF8).Trim
		    If Not line.BeginsWith("data:") Then Continue
		    Var payload As String = line.Middle(5).Trim
		    If payload = "[DONE]" Or payload = "" Then Continue
		    Try
		      Var j As New JSONItem(payload)
		      If Not j.HasKey("choices") Then Continue
		      Var choices As JSONItem = j.Child("choices")
		      If choices.Count = 0 Then Continue
		      Var delta As JSONItem = JSONItem(choices.ValueAt(0)).Lookup("delta", Nil)
		      If delta = Nil Then Continue
		      Var chunk As String = delta.Lookup("content", "").StringValue
		      If chunk = "" Then Continue
		      mCurrentReply = mCurrentReply + chunk
		      If mDelegate <> Nil Then mDelegate.OnToken(chunk)
		    Catch e As RuntimeException
		      App.AppendDebugLog("XDOXSession SSE parse: " + e.Message + " line: " + line.Left(200) + EndOfLine)
		    End Try
		  Next
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub Reset()
		  // clearChat: forget the conversation. Safe mid-response — the in-flight
		  // exchange just won't be committed to the (now empty) history.
		  // Bump the generation so an in-flight prep callback is dropped rather
		  // than streaming into a just-cleared session.
		  mGeneration = mGeneration + 1
		  mHistory.RemoveAll
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub SendMessage(userMessage As String)
		  If IsResponding Then Return
		  IsResponding = True

		  // Stamp this request. Stop/Reset/new-send bump mGeneration so a prep
		  // callback that finishes late (user stopped, then sent again) is
		  // recognised as stale and dropped — see BeginStreaming.
		  mGeneration = mGeneration + 1

		  // Snapshot the history text on the main thread. The worker only reads
		  // this copy, so a concurrent Reset() clearing mHistory can't race it.
		  Var historySnapshot() As String
		  For Each p As Pair In mHistory
		    historySnapshot.Add(p.Right.StringValue)
		  Next

		  // RAG prep (query embedding + token-guard /tokenize) makes blocking HTTP
		  // calls, so run it on a worker thread; it calls back into BeginStreaming
		  // on the main thread once the prompt is ready. See ChatPrepThread.
		  mPrep = New ChatPrepThread
		  mPrep.Configure(Self, userMessage, historySnapshot, mGeneration)
		  mPrep.Start
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub PrepareRequest(userMessage As String, history() As String, conn As SQLiteDatabase, ByRef sysPrompt As String, ByRef requestMessage As String, ByRef historyDropCount As Integer)
		  // Runs on the ChatPrepThread worker — blocking HTTP is fine here.
		  // Fresh RAG context per query — the system prompt is rebuilt every
		  // message, which is why history lives here and not on the server.
		  // Docs go in the system prompt; relevant notes are prepended to the
		  // user message itself (recency — see Retrieval.BuildNotesPreamble).
		  //
		  // Operates only on the passed-in history SNAPSHOT and the worker's own
		  // DB connection (conn) — it never touches the session's live mHistory
		  // or the shared DB handle, so nothing here races the main thread. The
		  // computed historyDropCount is applied to mHistory later on the main
		  // thread in BeginStreaming.
		  Var context As String = Retrieval.BuildContext(userMessage, conn)
		  requestMessage = Retrieval.BuildNotesPreamble(userMessage, conn) + userMessage
		  sysPrompt = BaseInstructions()
		  If context <> "" Then
		    sysPrompt = sysPrompt + EndOfLine + EndOfLine + "Context:" + EndOfLine + context
		  End If
		  sysPrompt = sysPrompt + EndOfLine + EndOfLine + ClosingReminders()

		  // Token guard: drop RAG context first, then trim oldest history pairs.
		  historyDropCount = 0
		  Var limit As Integer = ModelManager.kContextSize * 0.9
		  Var estimate As Integer = TokenCount(TranscriptText(sysPrompt, requestMessage, history, historyDropCount))
		  If estimate > limit And context <> "" Then
		    sysPrompt = BaseInstructions() + EndOfLine + EndOfLine + ClosingReminders()
		    estimate = TokenCount(TranscriptText(sysPrompt, requestMessage, history, historyDropCount))
		  End If
		  While estimate > limit And history.Count - historyDropCount >= 2
		    historyDropCount = historyDropCount + 2
		    estimate = TokenCount(TranscriptText(sysPrompt, requestMessage, history, historyDropCount))
		  Wend
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub BeginStreaming(generation As Integer, userMessage As String, sysPrompt As String, requestMessage As String, historyDropCount As Integer, failed As Boolean)
		  // Runs on the main thread (ChatPrepThread.UserInterfaceUpdate). Applies
		  // the history trim the worker computed, then opens the async stream.
		  //
		  // Drop stale callbacks: if the user stopped/reset or sent a newer
		  // message while this prep was running, mGeneration has moved on and this
		  // request must NOT stream. Guards the "stop, then quickly resend" race.
		  If generation <> mGeneration Then Return
		  mPrep = Nil
		  If Not IsResponding Then Return // stopped/reset while prep was running

		  // Push any semantic-tier change to the WebView now, on the main thread
		  // (search recorded it on the worker via RecordSemanticState).
		  Retrieval.FlushSemanticState

		  If failed Then
		    FailResponse("Could not prepare the request. Please try again.")
		    Return
		  End If

		  // Apply the token-guard trim now, on the owning thread.
		  Var drop As Integer = historyDropCount
		  If drop > mHistory.Count Then drop = mHistory.Count
		  For i As Integer = 1 To drop
		    mHistory.RemoveAt(0)
		  Next

		  mCurrentUserMessage = userMessage
		  mCurrentReply = ""
		  mSSEBuffer = ""

		  mConn = New URLConnection
		  AddHandler mConn.ReceivingProgressed, AddressOf OnReceivingProgressed
		  AddHandler mConn.ContentReceived, AddressOf OnContentReceived
		  AddHandler mConn.Error, AddressOf OnConnectionError
		  mConn.RequestHeader("Accept") = "text/event-stream"
		  // History keeps the clean user message (mCurrentUserMessage) — the
		  // notes preamble is re-derived fresh for each new message instead of
		  // being baked into past turns.
		  mConn.SetRequestContent(BuildRequestJSON(sysPrompt, requestMessage), "application/json")
		  mConn.Send("POST", ModelManager.BaseURL() + "/v1/chat/completions")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StopGeneration()
		  If Not IsResponding Or mConn = Nil Then
		    // Still in the prep phase (no connection yet) — bump the generation so
		    // the pending ChatPrepThread callback is recognised as stale and
		    // never opens a stream (fixes the stop-then-resend race).
		    Var wasResponding As Boolean = IsResponding
		    mGeneration = mGeneration + 1
		    IsResponding = False
		    // Nothing streamed yet, so there's no partial reply to keep — but the
		    // JS UI is stuck in "generating" until finalizeMessage() fires. Notify
		    // the delegate so send/stop unlocks. Only if we were actually mid-prep.
		    If wasResponding And mDelegate <> Nil Then mDelegate.OnDone
		    Return
		  End If
		  // llama-server has no cancel API, but dropping the connection stops
		  // generation server-side. Keep the partial reply in history and fire
		  // OnDone so the JS side resets the send/stop buttons.
		  Var conn As URLConnection = mConn
		  FinishResponse
		  conn.Disconnect
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function TokenCount(text As String) As Integer
		  // POST /tokenize on the local server. Returns -1 when unavailable —
		  // callers treat that as "guard can't run", not as an error.
		  Try
		    Var body As New JSONItem
		    body.Value("content") = text
		    Var conn As New URLConnection
		    conn.SetRequestContent(body.ToString, "application/json")
		    Var raw As String = conn.SendSync("POST", ModelManager.BaseURL() + "/tokenize", 10)
		    Var j As New JSONItem(raw)
		    If j.HasKey("tokens") Then Return j.Child("tokens").Count
		  Catch e As RuntimeException
		    App.AppendDebugLog("XDOXSession.TokenCount: " + e.Message + EndOfLine)
		  End Try
		  Return -1
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function TranscriptText(sysPrompt As String, userMessage As String, history() As String, historyDropCount As Integer) As String
		  // Flat text approximation of the full request for the token guard.
		  // Operates on the history SNAPSHOT (worker thread) — historyDropCount
		  // oldest entries are treated as already-trimmed.
		  Var s As String = sysPrompt + EndOfLine
		  Var start As Integer = historyDropCount
		  If start < 0 Then start = 0
		  For i As Integer = start To history.LastIndex
		    s = s + history(i) + EndOfLine
		  Next
		  Return s + userMessage
		End Function
	#tag EndMethod


	#tag Property, Flags = &h0
		IsResponding As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mConn As URLConnection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPrep As ChatPrepThread
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mGeneration As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mCurrentReply As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mCurrentUserMessage As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mDelegate As XDOXSessionDelegate
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHistory() As Pair
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSSEBuffer As String
	#tag EndProperty

End Class
#tag EndClass
