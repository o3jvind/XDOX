#tag Class
Public Class ChatPrepThread
Inherits Thread
	#tag Event
		Sub Run()
		  // Off-main-thread request preparation for ONE pool ("native" or
		  // "mbs") — split-bubble redesign (reactive-coalescing-thimble
		  // plan, Decision 1, 2026-08-30): XDOXSession.SendMessage now
		  // starts up to TWO of these, one per pool, so each pool's search
		  // (embedding via Embedder.FetchEmbedding → SendSync, plus its own
		  // reranker call) runs and completes independently — whichever
		  // finishes first posts back to the main thread first, without
		  // waiting on the other. There's no chat-model generation to
		  // stream anymore either way (see XDOXSession.PrepareRequest's
		  // comment: no chat-model has been called in this flow since
		  // 2026-08-29).
		  //
		  // Uses its OWN DB connection so retrieval reads never share the
		  // main-thread handle, OR the other pool's worker's connection
		  // (WAL allows concurrent readers).
		  Var conn As SQLiteDatabase = DBHelper.OpenConnection
		  Try
		    Session.PrepareRequest(mUserMessage, mPool, mPrevUserMessage, mPrevReply, conn, mMatchStatus, mAnswerText)
		  Catch e As RuntimeException
		    App.AppendDebugLog("ChatPrepThread (" + mPool + "): " + e.Message + EndOfLine)
		    mFailed = True
		  End Try
		  If conn <> Nil Then conn.Close
		  AddUserInterfaceUpdate(New Dictionary("done" : True))
		End Sub
	#tag EndEvent

	#tag Event
		Sub UserInterfaceUpdate(data() As Dictionary)
		  #Pragma Unused data
		  // Back on the main thread — render this pool's prepared answer.
		  // BeginStreamingForPool drops the call if mGeneration has moved on
		  // (user stopped / resent).
		  If Session <> Nil Then
		    Session.BeginStreamingForPool(mGeneration, mPool, mUserMessage, mMatchStatus, mAnswerText, mFailed)
		  End If
		End Sub
	#tag EndEvent


	#tag Method, Flags = &h0
		Sub Configure(session As XDOXSession, pool As String, userMessage As String, prevUserMessage As String, prevReply As String, generation As Integer)
		  Self.Session = session
		  mPool = pool
		  mUserMessage = userMessage
		  mPrevUserMessage = prevUserMessage
		  mPrevReply = prevReply
		  mGeneration = generation
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h0
		Session As XDOXSession
	#tag EndProperty

	#tag Property, Flags = &h21
		// "native" or "mbs" — which pool this worker searches.
		Private mPool As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mUserMessage As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPrevUserMessage As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mPrevReply As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mGeneration As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mMatchStatus As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mAnswerText As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mFailed As Boolean
	#tag EndProperty


End Class
#tag EndClass
