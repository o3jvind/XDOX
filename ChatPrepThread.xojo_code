#tag Class
Public Class ChatPrepThread
Inherits Thread
	#tag Event
		Sub Run()
		  // Off-main-thread request preparation. Everything here makes synchronous
		  // HTTP calls to the local server: BuildContext embeds the query
		  // (Embedder.FetchEmbedding → SendSync) and the token guard calls
		  // /tokenize. Running them on a worker thread keeps the UI responsive
		  // while a slow local model warms up. The finished prompt is handed back
		  // to the session on the MAIN thread (UserInterfaceUpdate), which opens
		  // the streaming connection.
		  //
		  // Uses its OWN DB connection so retrieval reads never share the
		  // main-thread handle (WAL allows the concurrent reader).
		  Var conn As SQLiteDatabase = DBHelper.OpenConnection
		  Try
		    Session.PrepareRequest(mUserMessage, mHistory, conn, mSysPrompt, mRequestMessage, mHistoryDropCount)
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
		  // Back on the main thread — apply the prepared request and start the
		  // (already-async) streaming connection. BeginStreaming drops the call
		  // if mGeneration has moved on (user stopped / resent).
		  If Session <> Nil Then
		    Session.BeginStreaming(mGeneration, mUserMessage, mSysPrompt, mRequestMessage, mHistoryDropCount, mFailed)
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
		Private mSysPrompt As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRequestMessage As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHistoryDropCount As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mFailed As Boolean
	#tag EndProperty


End Class
#tag EndClass
