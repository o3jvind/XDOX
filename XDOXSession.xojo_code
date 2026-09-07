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
		  // recognised as stale and dropped — see BeginStreamingForPool.
		  mGeneration = mGeneration + 1

		  // STAGE 2 of the split-bubble redesign (reactive-coalescing-thimble
		  // plan, Decision 1): up to TWO independent ChatPrepThread workers,
		  // one per pool, each posting its own completion as soon as ITS OWN
		  // search finishes — not one merged search. docs_search_scope
		  // (set by the user via the status-bar selector) is read ONCE here,
		  // synchronously, before either thread starts — mExpectedPools is
		  // therefore known up front rather than discovered from a pool's
		  // own completion, which is what lets IsResponding/the Send button
		  // know exactly when the WHOLE turn (not just the first bubble) is
		  // done (see BeginStreamingForPool).
		  Var scope As String = DBHelper.GetDocsSearchScope()
		  Var searchNative As Boolean = (scope <> "mbs")
		  Var searchMBS As Boolean = (scope <> "native")
		  mExpectedPools = 0
		  If searchNative Then mExpectedPools = mExpectedPools + 1
		  If searchMBS Then mExpectedPools = mExpectedPools + 1
		  mCompletedPools = 0

		  Var prevUserMessage As String = ""
		  Var prevNativeReply As String = ""
		  Var prevMBSReply As String = ""
		  If mHistory.LastIndex >= 0 Then
		    prevUserMessage = mHistory(mHistory.LastIndex).UserMessage
		    prevNativeReply = mHistory(mHistory.LastIndex).NativeReply
		    prevMBSReply = mHistory(mHistory.LastIndex).MBSReply
		  End If

		  mCurrentTurn = New ChatTurn
		  mCurrentTurn.UserMessage = userMessage

		  // RAG prep (query embedding + reranking) makes blocking HTTP calls to
		  // local servers, so each pool runs on its OWN worker thread; each
		  // calls back into BeginStreamingForPool on the main thread once ITS
		  // search is ready — independently of the other pool's timing. See
		  // ChatPrepThread.
		  If searchNative Then
		    mPrepNative = New ChatPrepThread
		    mPrepNative.Configure(Self, "native", userMessage, prevUserMessage, prevNativeReply, mGeneration)
		    mPrepNative.Start
		  End If
		  If searchMBS Then
		    mPrepMBS = New ChatPrepThread
		    mPrepMBS.Configure(Self, "mbs", userMessage, prevUserMessage, prevMBSReply, mGeneration)
		    mPrepMBS.Start
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub PrepareRequest(userMessage As String, pool As String, prevUserMessage As String, prevReply As String, conn As SQLiteDatabase, ByRef matchStatus As String, ByRef answerText As String)
		  // Runs on a ChatPrepThread worker (one per pool) — blocking HTTP is
		  // fine here.
		  //
		  // No chat-model generation happens anywhere in this function
		  // (see Retrieval.BuildUserFacingAnswerForPool's comment for the
		  // 2026-08-29 decision and why): a 12-query test battery found
		  // retrieval identifies the right class ~92% of the time but only
		  // ~25% of chat-model-GENERATED replies had fully correct code —
		  // and even mechanically stripping fabricated code the model wrote
		  // anyway (tried and reverted the same day) didn't fix it, because
		  // the model fabricated in PROSE too. This function only decides
		  // WHETHER retrieval found something relevant for THIS pool
		  // (MatchStatusForPool) and, if so, renders that pool's matched
		  // documentation text directly as the answer — the chat-completion
		  // model (qwen2.5-coder, port 8091) is no longer called by this
		  // session at all.
		  //
		  // Operates only on the passed-in prevUserMessage/prevReply SNAPSHOT
		  // and the worker's own DB connection (conn) — it never touches the
		  // session's live mHistory/mCurrentTurn or the shared DB handle, so
		  // nothing here races the main thread or the OTHER pool's worker.
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
		  Var retrievalQuery As String = RetrievalQuery(userMessage, prevUserMessage)
		  matchStatus = Retrieval.MatchStatusForPool(retrievalQuery, pool, conn)
		  If matchStatus = Retrieval.kStatusNoMatch Then
		    // Hard gate: nothing relevant enough was found IN THIS POOL — see
		    // Retrieval.MatchStatusForPool for the full rationale. The OTHER
		    // pool's own worker decides independently whether it has
		    // anything to show.
		    Return
		  End If

		  answerText = Retrieval.BuildUserFacingAnswerForPool(retrievalQuery, pool, conn)

		  // Folding the previous user turn into the query (above) means a
		  // follow-up whose own wording doesn't shift retrieval at all — e.g.
		  // "does Xojo have a native way of doing this?" right after an
		  // already-correct native answer — re-scores the SAME top chunk and
		  // would otherwise silently re-render it, which reads as if nothing
		  // was heard. Comparing the LEAD "#### Title" line rather than the
		  // whole answer matters: a follow-up's combined query can also pull
		  // in a second, weaker chunk that wasn't there before, so the two
		  // full answers are rarely byte-identical even when the substantive
		  // top result didn't change at all — confirmed live (2026-08-30): a
		  // whole-string comparison missed this exact case because the
		  // follow-up's answer had an extra low-relevance section appended.
		  // prevReply is THIS SAME POOL's previous reply verbatim (passed in
		  // by SendMessage from the same ChatTurn field this pool writes to),
		  // so the previous lead title is available without any chunk-ID
		  // plumbing. Say so honestly instead of repeating it; this is still
		  // not the chat model answering the "is this native" question (that
		  // would require composing prose again), just refusing to present a
		  // no-op as if it were new information.
		  If prevReply <> "" And LeadTitle(answerText) <> "" And LeadTitle(answerText) = LeadTitle(prevReply) Then
		    answerText = kRepeatedAnswerNotice + EndOfLine + EndOfLine + answerText
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function LeadTitle(answer As String) As String
		  // Retrieval.FormatResultForDisplay always opens a result with
		  // "#### Title" — pulling just that first heading out gives a cheap,
		  // robust "which chunk led this answer" identity, independent of
		  // how many further sections (MBS results, notes) follow it.
		  If Not answer.BeginsWith("#### ") Then Return ""
		  Var firstLine As String = answer
		  Var nl As Integer = answer.IndexOf(EndOfLine)
		  If nl >= 0 Then firstLine = answer.Left(nl)
		  Return firstLine
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function RetrievalQuery(userMessage As String, prevUserMessage As String) As String
		  // prevUserMessage is the previous turn's user message, or "" if
		  // there is no previous turn — passed in directly by the caller
		  // rather than derived from a flat history array's fixed offset
		  // (the old RetrievalQuery(userMessage, history() As String) read
		  // history(history.Count - 2), which assumed exactly one assistant
		  // reply per turn; that assumption broke once a turn could produce
		  // up to two independently-timed replies — see the
		  // reactive-coalescing-thimble plan's Decision 4).
		  If prevUserMessage = "" Then Return userMessage
		  Return prevUserMessage + " " + userMessage
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub BeginStreamingForPool(generation As Integer, pool As String, userMessage As String, matchStatus As String, answerText As String, failed As Boolean)
		  // Runs on the main thread (ChatPrepThread.UserInterfaceUpdate) —
		  // once per pool's own worker completion, independently of the
		  // other pool's timing. Name kept close to the old BeginStreaming
		  // (pre-split-bubble) since this is still the main-thread
		  // continuation of a worker-thread prep step, just now called once
		  // per pool instead of once per turn.
		  //
		  // Drop stale callbacks: if the user stopped/reset or sent a newer
		  // message while this prep was running, mGeneration has moved on and this
		  // request must NOT render. Guards the "stop, then quickly resend" race.
		  If generation <> mGeneration Then Return
		  If pool = "native" Then mPrepNative = Nil Else mPrepMBS = Nil
		  If Not IsResponding Then Return // stopped/reset while prep was running

		  // Push any semantic-tier change to the WebView now, on the main thread
		  // (search recorded it on the worker via RecordSemanticState).
		  Retrieval.FlushSemanticState

		  // Always fires, regardless of outcome — the one guaranteed place
		  // this pool's "Searching…" status row clears. Found live
		  // (2026-08-30): a pool that self-gates as no-match never calls
		  // OnCannedResponse at all, so without this its status row was
		  // stuck reading "Searching…" forever even though the search had
		  // genuinely finished.
		  If mDelegate <> Nil Then mDelegate.OnPoolDone(pool)

		  If failed Then
		    mCompletedPools = mCompletedPools + 1
		    If mDelegate <> Nil Then mDelegate.OnError(pool, "Could not prepare the request. Please try again.")
		    If mCompletedPools >= mExpectedPools Then FinishTurn
		    Return
		  End If

		  // No-match is a per-pool outcome now, not a whole-turn one — this
		  // pool's own search came up empty, independent of whether the
		  // OTHER pool (if any) still has a real answer coming. Surfaced
		  // IMMEDIATELY (OnPoolNoMatch), right where this pool's own
		  // "Searching…" status row was, not held back until the whole turn
		  // finishes — confirmed live (2026-08-30) that waiting was itself
		  // the problem: a fast pool's no-match was invisible for however
		  // long the OTHER (slower) pool kept searching, reading as if
		  // nothing was happening at all rather than "that source had no
		  // answer, still waiting on the other."
		  If matchStatus = Retrieval.kStatusNoMatch Or answerText = "" Then
		    If mDelegate <> Nil Then mDelegate.OnPoolNoMatch(pool)
		  Else
		    // OnCannedResponse renders as ONE atomic JS call — separate
		    // append+finalize calls with no real time between them (unlike the
		    // old token-by-token streaming, naturally paced by SSE chunk
		    // arrival) raced in the WebView's JS queue and truncated the
		    // rendered text mid-word, confirmed live back when this was only
		    // used for the no-match case; the same risk applies to any
		    // non-streamed text, so it's used unconditionally now.
		    If mCurrentTurn <> Nil Then
		      If pool = "native" Then mCurrentTurn.NativeReply = answerText Else mCurrentTurn.MBSReply = answerText
		    End If
		    If mDelegate <> Nil Then mDelegate.OnCannedResponse(pool, answerText)
		  End If

		  mCompletedPools = mCompletedPools + 1
		  If mCompletedPools >= mExpectedPools Then FinishTurn
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub FinishTurn()
		  // Only called once mCompletedPools = mExpectedPools — i.e. every
		  // pool that was actually searched for this turn has posted its own
		  // completion (with or without a bubble). This is deliberately NOT
		  // fired after the FIRST pool completes, even though that pool's
		  // bubble (or no-match note) is already fully rendered by then —
		  // see the reactive-coalescing-thimble plan's Decision 5: Send
		  // stays disabled until the whole turn resolves, because clearing
		  // it early would let an immediate follow-up start a NEW generation
		  // while the slower pool's worker is still in flight, silently
		  // dropping that pool's bubble when it later arrives (mGeneration
		  // would correctly mark it stale, but the user-visible effect is an
		  // answer vanishing with no explanation — worse than a short wait).
		  If mCurrentTurn <> Nil Then
		    mHistory.Add(mCurrentTurn)
		    mCurrentTurn = Nil
		  End If
		  IsResponding = False
		  If mDelegate <> Nil Then mDelegate.OnDone
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StopGeneration()
		  // There's no in-flight streaming connection to cancel anymore
		  // (PrepareRequest/BeginStreamingForPool render atomically, not
		  // token by token) — the only thing that can be "in progress" is
		  // the worker-thread retrieval prep itself, on up to two threads.
		  // Bumping mGeneration marks any pending ChatPrepThread callback
		  // (from either pool) stale so BeginStreamingForPool drops it when
		  // it arrives (fixes the stop-then-resend race).
		  Var wasResponding As Boolean = IsResponding
		  mGeneration = mGeneration + 1
		  IsResponding = False
		  mCurrentTurn = Nil
		  If wasResponding And mDelegate <> Nil Then mDelegate.OnDone
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h0
		IsResponding As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPrepNative As ChatPrepThread
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPrepMBS As ChatPrepThread
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mGeneration As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mDelegate As XDOXSessionDelegate
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHistory() As ChatTurn
	#tag EndProperty

	#tag Property, Flags = &h21
		// The turn currently being prepared, so each pool's own
		// BeginStreamingForPool call can fill in the SAME ChatTurn object
		// (its own NativeReply or MBSReply field) rather than each pool
		// appending a separate turn. Nil when no turn is in flight.
		Private mCurrentTurn As ChatTurn
	#tag EndProperty

	#tag Property, Flags = &h21
		// How many pools were actually searched for the in-flight turn (1 or
		// 2, computed synchronously from docs_search_scope in SendMessage
		// before either worker starts — see its comment).
		Private mExpectedPools As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		// How many of mExpectedPools have posted their own completion
		// (BeginStreamingForPool) for the in-flight turn, with or without a
		// bubble. IsResponding/OnDone only fire once this reaches
		// mExpectedPools — see FinishTurn.
		Private mCompletedPools As Integer
	#tag EndProperty

	// NB: no literal comma in this default value — confirmed live that a
	// comma inside a .xojo_code #tag Constant String default silently
	// truncates the string at compile time (the IDE parses the constant's
	// default-value list itself as comma-delimited, same underlying cause as
	// .xojo_window's documented \x2C-for-comma rule, but this is the first
	// constant in this codebase to ever contain a literal comma, so it was
	// never caught before). Use em dashes or split sentences instead.
	#tag Constant, Name = kRepeatedAnswerNotice, Type = String, Dynamic = False, Default = \"_Retrieval found the same documentation as last time — there doesn't appear to be a different or more native option than what's shown below._", Scope = Private
	#tag EndConstant

End Class
#tag EndClass
