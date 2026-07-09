#tag Class
Public Class NoteEmbedThread
Inherits Thread
	#tag Event
		Sub Run()
		  // Embeds notes off the main thread — Embedder.FetchEmbedding blocks on a
		  // synchronous HTTP call, and note-save / server-ready both used to run it
		  // inline (freezing the UI on a slow model). Uses its own DB connection so
		  // its writes never share a handle with the main thread (see fix #1).
		  If Not ModelManager.EmbedServerReady Then Return
		  Var db As SQLiteDatabase = DBHelper.OpenConnection
		  If db = Nil Then Return
		  Try
		    If mNoteId <> "" Then
		      DBHelper.EmbedNoteById(mNoteId, db)
		    Else
		      DBHelper.BackfillNoteEmbeddings(db)
		    End If
		  Catch e As RuntimeException
		    App.AppendDebugLog("NoteEmbedThread: " + e.Message + EndOfLine)
		  End Try
		  db.Close
		End Sub
	#tag EndEvent


	#tag Method, Flags = &h0
		Sub EmbedOne(noteId As String)
		  mNoteId = noteId
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mNoteId As String
	#tag EndProperty


End Class
#tag EndClass
