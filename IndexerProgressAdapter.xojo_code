#tag Class
Public Class IndexerProgressAdapter
Implements IndexerDelegate

	#tag Property, Flags = &h0
		Win As IndexProgressWindow
	#tag EndProperty

	#tag Method, Flags = &h0
		Sub IndexerParsing()
		  If Win <> Nil Then Win.IndexerParsing
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerProgress(chunksProcessed As Integer, totalChunks As Integer)
		  If Win <> Nil Then Win.IndexerProgress(chunksProcessed, totalChunks)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerEmbedProgress(chunksEmbedded As Integer, totalChunks As Integer)
		  If Win <> Nil Then Win.IndexerEmbedProgress(chunksEmbedded, totalChunks)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerComplete(isReindex As Boolean)
		  If Win <> Nil Then Win.IndexerComplete

		  Retrieval.ClearCache
		  Retrieval.NotifySemanticState

		  #If DebugBuild Then
		    Retrieval.SelfTest
		  #EndIf

		  // A finished index — additive or reindex — clears any pending banner.
		  DBHelper.SetMetadata("pending_reindex", "0")
		  DBHelper.SetMetadata("pending_version", "")

		  If isReindex Then
		    // Only a true reindex sweeps version-scoped notes for staleness.
		    Var version As String = DocDetector.FindLatestDocsVersion
		    DBHelper.MarkStaleNotes(version)
		    Var stale As Integer = DBHelper.StaleNoteCount
		    If stale > 0 Then
		      MessageBox(stale.ToString + " note(s) may be affected by the Xojo " _
		        + version + " update. Review them in the sidebar.")
		    End If
		  End If

		  // Staleness flags and the indexed-version set may have changed — repaint.
		  Try
		    Window1.MainView.RefreshSidebar
		    Window1.MainView.RefreshVersions
		  Catch e As RuntimeException
		    App.AppendDebugLog("IndexerProgressAdapter (refresh sidebar): " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerError(message As String)
		  Indexer.IsRunning = False
		  If Win <> Nil Then Win.IndexerError(message)
		End Sub
	#tag EndMethod

End Class
#tag EndClass
