#tag Module
Protected Module MBSIndexer

	#tag Property, Flags = &h0
		MBSIsRunning As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private ActiveThread As MBSIndexerThread
	#tag EndProperty

	#tag Method, Flags = &h0
		Sub StartIndex(docsetFolder As FolderItem, progressDelegate As IndexerDelegate)
		  // Also refuses to start while a Xojo-docs (re)index is running: both
		  // indexers write chunks through their own connection inside a
		  // transaction, and while distinct docs_version / source scopes keep
		  // their writes from colliding, running two long transactions against
		  // the same WAL file at once is asking for lock contention for no
		  // benefit — indexing the docs and the plugin reference are both rare,
		  // user-initiated actions, never something to parallelize.
		  If MBSIsRunning Or Indexer.IsRunning Then Return
		  MBSIsRunning = True

		  Var t As New MBSIndexerThread
		  t.DocsetFolder = docsetFolder
		  t.ProgressDelegate = progressDelegate
		  ActiveThread = t
		  t.Start
		End Sub
	#tag EndMethod

End Module
#tag EndModule
