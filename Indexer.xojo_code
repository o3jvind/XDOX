#tag Module
Protected Module Indexer

	#tag Property, Flags = &h0
		IsRunning As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private ActiveThread As IndexerThread
	#tag EndProperty

	#tag Method, Flags = &h0
		Sub StartIndex(docsFile As FolderItem, progressDelegate As IndexerDelegate, isReindex As Boolean, targetVersion As String = "")
		  // See MBSIndexer.StartIndex for why the two indexers refuse to run
		  // concurrently.
		  If IsRunning Or MBSIndexer.MBSIsRunning Then Return
		  IsRunning = True

		  Var t As New IndexerThread
		  t.DocsFile = docsFile
		  t.ProgressDelegate = progressDelegate
		  t.IsReindex = isReindex
		  t.TargetVersion = targetVersion
		  ActiveThread = t
		  t.Start
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StartEmbedOnly(progressDelegate As IndexerDelegate)
		  // Backfill embeddings for chunks left pending by an earlier run (embed
		  // server was down or the model wasn't downloaded yet). No parse phase,
		  // no progress window — status arrives via the delegate.
		  If IsRunning Then Return
		  If DBHelper.PendingEmbedCount = 0 Then Return
		  IsRunning = True

		  Var t As New IndexerThread
		  t.EmbedOnly = True
		  t.ProgressDelegate = progressDelegate
		  ActiveThread = t
		  t.Start
		End Sub
	#tag EndMethod

End Module
#tag EndModule
