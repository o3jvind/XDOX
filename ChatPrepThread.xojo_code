#tag Class
Public Class ChatPrepThread
Inherits Thread
	#tag Event
		Sub Run()
		  // Off-main-thread request preparation. Retrieval (embedding via
		  // Embedder.FetchEmbedding → SendSync, plus the reranker call) makes
		  // synchronous HTTP calls to local servers, so this runs on a worker
		  // thread to keep the UI responsive. The finished answer text is
		  // handed back to the session on the MAIN thread (UserInterfaceUpdate)
		  // for rendering — there's no streaming connection to open anymore
		  // (see XDOXSession.PrepareRequest's comment: no chat-model
		  // generation happens in this flow at all as of 2026-08-29).
		  //
		  // Uses its OWN DB connection so retrieval reads never share the
		  // main-thread handle (WAL allows the concurrent reader).
		  Var conn As SQLiteDatabase = DBHelper.OpenConnection
		  Try
		    Session.PrepareRequest(mUserMessage, mHistory, conn, mMatchStatus, mAnswerText)
		  Catch e As RuntimeException
		    App.AppendDebugLog("ChatPrepThread: " + e.Message + EndOfLine)
		    mFailed = True
		  End Try
		  If conn <> Nil Then conn.Close
		  AddUserInterfaceUpdate(New Dictionary("done" : True))
		End Sub
	#tag EndEvent

	#tag Event
		Sub UserInterfaceUpdate(data() As Dictionary)
		  #Pragma Unused data
		  // Back on the main thread — render the prepared answer.
		  // BeginStreaming (name kept for now) drops the call if mGeneration
		  // has moved on (user stopped / resent).
		  If Session <> Nil Then
		    Session.BeginStreaming(mGeneration, mUserMessage, mMatchStatus, mAnswerText, mFailed)
		  End If
		End Sub
	#tag EndEvent


	#tag Method, Flags = &h0
		Sub Configure(session As XDOXSession, userMessage As String, history() As String, generation As Integer)
		  Self.Session = session
		  mUserMessage = userMessage
		  mHistory = history
		  mGeneration = generation
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h0
		Session As XDOXSession
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mUserMessage As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHistory() As String
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
