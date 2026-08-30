#tag Class
Public Class IndexerThread
Inherits Thread

	#tag Property, Flags = &h0
		DocsFile As FolderItem
	#tag EndProperty

	#tag Property, Flags = &h0
		ProgressDelegate As IndexerDelegate
	#tag EndProperty

	#tag Property, Flags = &h0
		IsReindex As Boolean
	#tag EndProperty

	#tag Property, Flags = &h0
		TargetVersion As String
	#tag EndProperty

	#tag Property, Flags = &h0
		EmbedOnly As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mTransactionOpen As Boolean
	#tag EndProperty

	#tag Event
		Sub Run()
		  // Own connection to the same file. WAL lets this writer run alongside
		  // the main thread's readers without the two interleaving transactions
		  // on one shared handle (which would throw "transaction within a
		  // transaction" / leave writes in the wrong transaction). Declared
		  // outside the Try so the Catch below can roll back and close it —
		  // Xojo has no Finally, so this is the only place cleanup can happen
		  // for an exception raised mid-transaction.
		  Var db As SQLiteDatabase
		  mTransactionOpen = False
		  Try
		    db = DBHelper.OpenConnection
		    If db = Nil Then
		      AddUserInterfaceUpdate(New Pair("type", "error"), New Pair("msg", "Database not available"))
		      Return
		    End If

		    If EmbedOnly Then
		      Embedder.EmbedPendingChunks(db, Self)
		      db.Close
		      AddUserInterfaceUpdate(New Pair("type", "complete"), New Pair("isReindex", False))
		      Return
		    End If

		    // The version this run indexes. TargetVersion lets the caller pick a
		    // specific installed version (multi-version support); empty falls back
		    // to the latest, preserving single-version behaviour.
		    Var version As String = TargetVersion
		    If version = "" Then version = DocDetector.FindLatestDocsVersion

		    AddUserInterfaceUpdate(New Pair("type", "parsing"))
		    Var parser As New RSTParser
		    Var rawChunks() As DocChunk = parser.Parse(DocsFile)
		    // The docs bundle has no API 1 pages, so questions phrased with old
		    // names (MsgBox, PushButton…) would retrieve nothing — append the
		    // curated legacy→modern mapping chunks. Only when the parse itself
		    // produced chunks, so a failed parse still reports its error below.
		    If rawChunks.Count > 0 Then
		      For Each mapChunk As DocChunk In APIMigrationMap.Chunks
		        rawChunks.Add(mapChunk)
		      Next
		    End If
		    Var splitter As New Chunker(kMaxChars, kTargetChars)
		    Var chunks() As DocChunk = splitter.SplitIfNeeded(rawChunks)
		    Var total As Integer = chunks.Count
		    If total = 0 Then
		      db.Close
		      AddUserInterfaceUpdate(New Pair("type", "error"), New Pair("msg", "No chunks produced from documentation file."))
		      Return
		    End If

		    // Non-destructive per-version reindex: wipe only this version (and the
		    // version-independent map chunks, which are reinserted below) — other
		    // indexed versions survive. Deletion happens inside the same
		    // transaction as the inserts/links below, so a failure partway
		    // through rolls back to the previous, still-working index instead
		    // of leaving the version wiped with nothing usable in its place.
		    Var ids() As Integer
		    db.BeginTransaction
		    mTransactionOpen = True
		    DBHelper.ClearChunksForVersion(version, db)
		    For ci As Integer = 0 To total - 1
		      Var chunk As DocChunk = chunks(ci)
		      chunk.ChunkIndex = ci
		      // Curated migration chunks are version-independent (docs_version='') so
		      // they surface regardless of the active version; docs chunks carry the
		      // indexed version. See APIMigrationMap / Retrieval version filter.
		      Var chunkVersion As String = version
		      If chunk.Source = APIMigrationMap.kSource Then chunkVersion = ""
		      Var newId As Integer = DBHelper.InsertChunk(chunk.Source, chunk.Title, chunk.ChunkText, ci, chunkVersion, db)
		      ids.Add(newId)
		      Var done As Integer = ci + 1
		      If done Mod 500 = 0 Then
		        AddUserInterfaceUpdate(New Pair("type", "progress"), New Pair("done", done), New Pair("total", total))
		      End If
		    Next

		    AddUserInterfaceUpdate(New Pair("type", "progress"), New Pair("done", total), New Pair("total", total))

		    Var linkTotal As Integer = ids.Count
		    For li As Integer = 0 To linkTotal - 1
		      Var prevId As Integer = -1
		      Var nextId As Integer = -1
		      If li > 0 Then prevId = ids(li - 1)
		      If li < linkTotal - 1 Then nextId = ids(li + 1)
		      DBHelper.LinkChunks(ids(li), prevId, nextId, db)
		    Next
		    db.CommitTransaction
		    mTransactionOpen = False

		    // docs_version metadata now tracks the most-recently-indexed version
		    // (kept for backward-compat / staleness messaging). active_docs_version
		    // is what retrieval filters on; set it if this is the first indexed
		    // version so the app has something to search immediately.
		    DBHelper.SetMetadata("docs_version", version, db)
		    If DBHelper.GetMetadata("active_docs_version") = "" Then
		      DBHelper.SetActiveVersion(version, db)
		    End If

		    Var now As New Date
		    Var mo As String = now.Month.ToString
		    If now.Month < 10 Then mo = "0" + mo
		    Var dy As String = now.Day.ToString
		    If now.Day < 10 Then dy = "0" + dy
		    Var hr As String = now.Hour.ToString
		    If now.Hour < 10 Then hr = "0" + hr
		    Var mn As String = now.Minute.ToString
		    If now.Minute < 10 Then mn = "0" + mn
		    Var sc As String = now.Second.ToString
		    If now.Second < 10 Then sc = "0" + sc
		    DBHelper.SetMetadata("indexed_at", now.Year.ToString + "-" + mo + "-" + dy + "T" + hr + ":" + mn + ":" + sc + "Z", db)

		    // Embedding phase. The embed server is started by ModelManager.AutoStart
		    // (main thread); it may still be warming up, so wait with a grace
		    // period — but only if the model is on disk at all. On first run the
		    // fixed embedding model is still downloading in the background, so
		    // probing would just burn 90 s raising connection-refused exceptions.
		    // Either way the index is complete and usable BM25-only — pending
		    // rows are embedded later by the resume pass.
		    If ModelManager.EmbeddingModelInstalled And WaitForEmbedServer(90) Then
		      Embedder.EmbedPendingChunks(db, Self)
		    Else
		      App.AppendDebugLog("IndexerThread: embedding server not ready — skipping embed phase (will resume later)" + EndOfLine)
		    End If

		    db.Close
		    AddUserInterfaceUpdate(New Pair("type", "complete"), New Pair("isReindex", IsReindex))
		  Catch e As RuntimeException
		    App.AppendDebugLog("IndexerThread: " + e.Message + EndOfLine)
		    If db <> Nil Then
		      If mTransactionOpen Then
		        Try
		          db.RollbackTransaction
		        Catch e2 As DatabaseException
		        End Try
		        mTransactionOpen = False
		      End If
		      db.Close
		    End If
		    AddUserInterfaceUpdate(New Pair("type", "error"), New Pair("msg", e.Message))
		  End Try
		End Sub
	#tag EndEvent

	#tag Event
		Sub UserInterfaceUpdate(data() As Dictionary)
		  For Each d As Dictionary In data
		    Var kind As String = d.Value("type")
		    // Reset IsRunning even with no delegate attached, or a delegate-less
		    // run would leave the Indexer permanently "running".
		    If kind = "complete" Or kind = "error" Then Indexer.IsRunning = False
		    If ProgressDelegate = Nil Then Continue
		    Select Case kind
		    Case "parsing"
		      ProgressDelegate.IndexerParsing
		    Case "progress"
		      ProgressDelegate.IndexerProgress(d.Value("done"), d.Value("total"))
		    Case "embed-progress"
		      ProgressDelegate.IndexerEmbedProgress(d.Value("done"), d.Value("total"))
		    Case "complete"
		      ProgressDelegate.IndexerComplete(d.Value("isReindex"))
		    Case "error"
		      ProgressDelegate.IndexerError(d.Value("msg"))
		    End Select
		  Next
		End Sub
	#tag EndEvent

	#tag Method, Flags = &h21
		Private Function WaitForEmbedServer(graceSeconds As Integer) As Boolean
		  Var waited As Integer = 0
		  While waited < graceSeconds
		    If ModelManager.EmbedServerHealthy(2) Then Return True
		    Me.Sleep(2000)
		    waited = waited + 2
		  Wend
		  Return False
		End Function
	#tag EndMethod

	#tag Constant, Name = kMaxChars, Type = Integer, Dynamic = False, Default = \"8000", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kTargetChars, Type = Integer, Dynamic = False, Default = \"3000", Scope = Private
	#tag EndConstant

End Class
#tag EndClass
