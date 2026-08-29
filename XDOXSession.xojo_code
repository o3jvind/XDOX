#tag Class
Public Class XDOXSession

	#tag Method, Flags = &h0
		Sub Constructor(theDelegate As XDOXSessionDelegate)
		  mDelegate = theDelegate
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub Reset()
		  // clearChat: forget the conversation. Safe mid-response — the in-flight
		  // exchange just won't be committed to the (now empty) history.
		  // Bump the generation so an in-flight prep callback is dropped rather
		  // than rendering into a just-cleared session.
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

		  // RAG prep (query embedding + reranking) makes blocking HTTP calls to
		  // local servers, so run it on a worker thread; it calls back into
		  // BeginStreaming on the main thread once the answer is ready. See
		  // ChatPrepThread.
		  mPrep = New ChatPrepThread
		  mPrep.Configure(Self, userMessage, historySnapshot, mGeneration)
		  mPrep.Start
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub PrepareRequest(userMessage As String, history() As String, conn As SQLiteDatabase, ByRef matchStatus As String, ByRef answerText As String)
		  // Runs on the ChatPrepThread worker — blocking HTTP is fine here.
		  //
		  // No chat-model generation happens anywhere in this function
		  // (see Retrieval.BuildUserFacingAnswer's comment for the
		  // 2026-08-29 decision and why): a 12-query test battery found
		  // retrieval identifies the right class ~92% of the time but only
		  // ~25% of chat-model-GENERATED replies had fully correct code —
		  // and even mechanically stripping fabricated code the model wrote
		  // anyway (tried and reverted the same day) didn't fix it, because
		  // the model fabricated in PROSE too. This function only decides
		  // WHETHER retrieval found something relevant (MatchStatus) and,
		  // if so, renders the matched documentation text directly as the
		  // answer — the chat-completion model (qwen2.5-coder, port 8091)
		  // is no longer called by this session at all.
		  //
		  // Operates only on the passed-in history SNAPSHOT and the worker's own
		  // DB connection (conn) — it never touches the session's live mHistory
		  // or the shared DB handle, so nothing here races the main thread.
		  //
		  // RETRIEVAL uses userMessage plus the immediately preceding user turn
		  // (RetrievalQuery), not userMessage alone — a follow-up like "Does
		  // Xojo have a native way of doing this" carries almost no keyword
		  // content of its own; "this" only resolves against the prior turn.
		  // Only the previous user turn is folded in, not the assistant's
		  // reply — the assistant's past turn is now always genuine
		  // documentation text (never model-composed prose), so this is
		  // mainly about keeping the folded-in vocabulary short and on-topic
		  // rather than guarding against invented terms as it originally did.
		  Var retrievalQuery As String = RetrievalQuery(userMessage, history)
		  matchStatus = Retrieval.MatchStatus(retrievalQuery, conn)
		  If matchStatus = Retrieval.kStatusNoMatch Then
		    // Hard gate: nothing relevant enough was found — see
		    // Retrieval.MatchStatus for the full rationale.
		    Return
		  End If

		  answerText = Retrieval.BuildUserFacingAnswer(retrievalQuery, conn)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function RetrievalQuery(userMessage As String, history() As String) As String
		  // history is the flat oldest-first [user, assistant, user, assistant, ...]
		  // snapshot SendMessage builds from mHistory (role labels are dropped —
		  // see its comment). The previous USER turn is always two slots back
		  // from the end (the last slot is the previous assistant reply), so it
		  // only exists once at least one full exchange has happened.
		  If history.Count < 2 Then Return userMessage
		  Var prevUserTurn As String = history(history.Count - 2)
		  If prevUserTurn = "" Then Return userMessage
		  Return prevUserTurn + " " + userMessage
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub BeginStreaming(generation As Integer, userMessage As String, matchStatus As String, answerText As String, failed As Boolean)
		  // Runs on the main thread (ChatPrepThread.UserInterfaceUpdate).
		  //
		  // No chat-model connection is opened here — see PrepareRequest's
		  // comment. The no-match case and the found-an-answer case both
		  // render via OnCannedResponse (one atomic, non-streamed JS call),
		  // since there's no token-by-token generation to stream anymore;
		  // the answer text was already fully computed on the worker thread.
		  // Name kept as BeginStreaming rather than renamed, since ChatPrepThread
		  // and this method's role (main-thread continuation of a worker-thread
		  // prep step) are otherwise unchanged.
		  //
		  // Drop stale callbacks: if the user stopped/reset or sent a newer
		  // message while this prep was running, mGeneration has moved on and this
		  // request must NOT render. Guards the "stop, then quickly resend" race.
		  If generation <> mGeneration Then Return
		  mPrep = Nil
		  If Not IsResponding Then Return // stopped/reset while prep was running

		  // Push any semantic-tier change to the WebView now, on the main thread
		  // (search recorded it on the worker via RecordSemanticState).
		  Retrieval.FlushSemanticState

		  If failed Then
		    IsResponding = False
		    If mDelegate <> Nil Then mDelegate.OnError("Could not prepare the request. Please try again.")
		    Return
		  End If

		  Var replyText As String = kNoMatchResponse
		  If matchStatus <> Retrieval.kStatusNoMatch And answerText <> "" Then replyText = answerText

		  // OnCannedResponse renders as ONE atomic JS call — separate
		  // append+finalize calls with no real time between them (unlike the
		  // old token-by-token streaming, naturally paced by SSE chunk
		  // arrival) raced in the WebView's JS queue and truncated the
		  // rendered text mid-word, confirmed live back when this was only
		  // used for the no-match case; the same risk applies to any
		  // non-streamed text, so it's used unconditionally now.
		  mHistory.Add(New Pair("user", userMessage))
		  mHistory.Add(New Pair("assistant", replyText))
		  IsResponding = False
		  If mDelegate <> Nil Then mDelegate.OnCannedResponse(replyText)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StopGeneration()
		  // There's no in-flight streaming connection to cancel anymore
		  // (PrepareRequest/BeginStreaming render atomically, not token by
		  // token) — the only thing that can be "in progress" is the
		  // worker-thread retrieval prep itself. Bumping mGeneration marks
		  // any pending ChatPrepThread callback stale so BeginStreaming
		  // drops it when it arrives (fixes the stop-then-resend race).
		  Var wasResponding As Boolean = IsResponding
		  mGeneration = mGeneration + 1
		  IsResponding = False
		  If wasResponding And mDelegate <> Nil Then mDelegate.OnDone
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h0
		IsResponding As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPrep As ChatPrepThread
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mGeneration As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mDelegate As XDOXSessionDelegate
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHistory() As Pair
	#tag EndProperty

	// NB: no literal comma in this default value — confirmed live that a
	// comma inside a .xojo_code #tag Constant String default silently
	// truncates the string at compile time (the IDE parses the constant's
	// default-value list itself as comma-delimited, same underlying cause as
	// .xojo_window's documented \x2C-for-comma rule, but this is the first
	// constant in this codebase to ever contain a literal comma, so it was
	// never caught before). Use em dashes or split sentences instead.
	#tag Constant, Name = kNoMatchResponse, Type = String, Dynamic = False, Default = \"I couldn't find closely matching Xojo documentation for that — so I can't verify that it exists or provide reliable Xojo code for it. Try rephrasing the question — or asking about a documented Xojo feature.", Scope = Private
	#tag EndConstant

End Class
#tag EndClass
