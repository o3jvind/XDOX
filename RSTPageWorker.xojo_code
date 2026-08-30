#tag Class
Public Class RSTPageWorker
Inherits Thread

	#tag Method, Flags = &h0
		Constructor()
		  Me.Type = Thread.Types.Preemptive
		End Constructor
	#tag EndMethod

	#tag Event
		Sub Run()
		  // Same outer-Try backstop as MBSParseWorker.Run — see its comment.
		  // App.AppendDebugLog is not documented thread-safe, so the message
		  // is buffered here and flushed by the owner after all workers
		  // finish, same as MBSParseWorker's LogLines.
		  Try
		    Var parser As New RSTParser
		    parser.ParsePageGroup(Lines, PageStarts, PageTitles, PageIndexFrom, PageIndexTo, LastLineIndex, TitleCounts, ResultChunks)
		  Catch e As RuntimeException
		    LogLines.Add("RSTPageWorker: worker aborted after exception: " + e.Message)
		  End Try
		End Sub
	#tag EndEvent

	#tag Property, Flags = &h0
		Lines() As String
	#tag EndProperty

	#tag Property, Flags = &h0
		PageStarts() As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		PageTitles() As String
	#tag EndProperty

	#tag Property, Flags = &h0
		PageIndexFrom As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		PageIndexTo As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		LastLineIndex As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		TitleCounts As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h0
		ResultChunks() As DocChunk
	#tag EndProperty

	#tag Property, Flags = &h0
		LogLines() As String
	#tag EndProperty

End Class
#tag EndClass
