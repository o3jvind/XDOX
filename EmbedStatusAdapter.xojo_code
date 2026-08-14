#tag Class
Public Class EmbedStatusAdapter
Implements IndexerDelegate

	#tag Method, Flags = &h0
		Sub IndexerParsing()
		  // Embed-only runs never parse.
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerFileScanProgress(filesScanned As Integer, totalFiles As Integer)
		  // Embed-only runs never scan files.
		  #Pragma Unused filesScanned
		  #Pragma Unused totalFiles
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerProgress(chunksProcessed As Integer, totalChunks As Integer)
		  #Pragma Unused chunksProcessed
		  #Pragma Unused totalChunks
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerEmbedProgress(chunksEmbedded As Integer, totalChunks As Integer)
		  Try
		    Window1.MainView.UpdateIndexStatus("Embedding documentation… " _
		      + Format(chunksEmbedded, "###,###") + " of " + Format(totalChunks, "###,###"))
		  Catch e As RuntimeException
		    App.AppendDebugLog("EmbedStatusAdapter.IndexerEmbedProgress: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerComplete(isReindex As Boolean)
		  #Pragma Unused isReindex
		  Try
		    Window1.MainView.ClearIndexStatus
		    Retrieval.ClearCache
		    Retrieval.NotifySemanticState
		  Catch e As RuntimeException
		    App.AppendDebugLog("EmbedStatusAdapter.IndexerComplete: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerError(message As String)
		  App.AppendDebugLog("EmbedStatusAdapter: " + message + EndOfLine)
		  Try
		    Window1.MainView.ClearIndexStatus
		  Catch e As RuntimeException
		    App.AppendDebugLog("EmbedStatusAdapter.IndexerError (clearing status): " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

End Class
#tag EndClass
