#tag Class
Public Class MBSParseWorker
Inherits Thread

	#tag Method, Flags = &h0
		Constructor()
		  Me.Type = Thread.Types.Preemptive
		End Constructor
	#tag EndMethod

	#tag Event
		Sub Run()
		  // Preemptive Thread: a lock held across an unhandled exception is
		  // never released (per Xojo's own CriticalSection docs), and an
		  // uncaught exception here would otherwise silently kill this
		  // worker's whole file slice with no signal reaching the owner —
		  // worse than today's single-threaded behavior, where the same
		  // exception at least reaches MBSIndexerThread.Run's own Catch.
		  // This outer Try is the backstop; the per-file Try below (mirroring
		  // MBSDocsetParser.Parse's existing one) is still the normal path.
		  Try
		    Var parser As New MBSDocsetParser
		    parser.ParseFromQueue(Queue, AnchorsByFile, EmptyAnchorSet, ResultChunks, LogLines, DoneCount)
		  Catch e As RuntimeException
		    LogLines.Add("MBSParseWorker: worker aborted after exception: " + e.Message)
		  End Try
		End Sub
	#tag EndEvent

	#tag Property, Flags = &h0
		Queue As MBSFileQueue
	#tag EndProperty

	#tag Property, Flags = &h0
		AnchorsByFile As AtomicDictionaryMBS
	#tag EndProperty

	#tag Property, Flags = &h0
		EmptyAnchorSet As AtomicDictionaryMBS
	#tag EndProperty

	#tag Property, Flags = &h0
		ResultChunks() As DocChunk
	#tag EndProperty

	#tag Property, Flags = &h0
		LogLines() As String
	#tag EndProperty

	#tag Property, Flags = &h0
		DoneCount() As Integer
	#tag EndProperty

End Class
#tag EndClass
