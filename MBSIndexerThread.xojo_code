#tag Class
Public Class MBSIndexerThread
Inherits Thread
Implements MBSParseProgressDelegate

	#tag Property, Flags = &h0
		DocsetFolder As FolderItem
	#tag EndProperty

	#tag Property, Flags = &h0
		ProgressDelegate As IndexerDelegate
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mTransactionOpen As Boolean
	#tag EndProperty

	#tag Event
		Sub Run()
		  // Own connection, same reasoning as IndexerThread: WAL lets this writer
		  // run alongside the main thread's readers without two connections
		  // interleaving transactions on one shared handle.
		  Var db As SQLiteDatabase
		  mTransactionOpen = False
		  Try
		    db = DBHelper.OpenConnection
		    If db = Nil Then
		      AddUserInterfaceUpdate(New Pair("type", "error"), New Pair("msg", "Database not available"))
		      Return
		    End If

		    AddUserInterfaceUpdate(New Pair("type", "parsing"))
		    Var parser As New MBSDocsetParser
		    Var rawChunks() As DocChunk = parser.Parse(DocsetFolder, Self)
		    If rawChunks.Count = 0 Then
		      db.Close
		      AddUserInterfaceUpdate(New Pair("type", "error"), New Pair("msg", "No chunks produced from MBS docset — check it points at a MBS.docset bundle."))
		      Return
		    End If

		    Var splitter As New Chunker(kMaxChars, kTargetChars)
		    Var chunks() As DocChunk = splitter.SplitIfNeeded(rawChunks)
		    // Chunker assigns every split part the SAME Source as the original
		    // (only Title gets a "(part N)" suffix) — fine for Xojo-doc chunks,
		    // which are addressed by id, but MBS upserts key on Source. Disambiguate
		    // here so two parts of one oversized page don't collide into one row.
		    DisambiguateSplitSources(chunks)

		    Var total As Integer = chunks.Count
		    Var existingHashes As Dictionary = DBHelper.MBSChunkHashes(db)
		    Var keepSources As New Dictionary
		    Var unchanged As Integer = 0

		    db.BeginTransaction
		    mTransactionOpen = True
		    For ci As Integer = 0 To chunks.LastIndex
		      Var chunk As DocChunk = chunks(ci)
		      keepSources.Value(chunk.Source) = True
		      Var hash As String = ContentHash(chunk.ChunkText)
		      If existingHashes.HasKey(chunk.Source) And existingHashes.Value(chunk.Source) = hash Then
		        unchanged = unchanged + 1
		      Else
		        DBHelper.UpsertMBSChunk(chunk.Source, chunk.Title, chunk.ChunkText, hash, db)
		      End If
		      Var done As Integer = ci + 1
		      If done Mod 1000 = 0 Then
		        AddUserInterfaceUpdate(New Pair("type", "progress"), New Pair("done", done), New Pair("total", total))
		      End If
		    Next
		    AddUserInterfaceUpdate(New Pair("type", "progress"), New Pair("done", total), New Pair("total", total))

		    DBHelper.DeleteMBSChunksExcept(keepSources, db)
		    db.CommitTransaction
		    mTransactionOpen = False

		    Var changedCount As Integer = total - unchanged
		    App.AppendDebugLog("MBSIndexerThread: " + total.ToString + " chunks, " + unchanged.ToString _
		      + " unchanged (skipped re-embed), " + changedCount.ToString + " new/updated" + EndOfLine)

		    If ModelManager.EmbeddingModelInstalled And WaitForEmbedServer(90) Then
		      EmbedPendingChunks(db)
		    Else
		      App.AppendDebugLog("MBSIndexerThread: embedding server not ready — skipping embed phase (will resume later)" + EndOfLine)
		    End If

		    db.Close
		    AddUserInterfaceUpdate(New Pair("type", "complete"), New Pair("isReindex", False))
		  Catch e As RuntimeException
		    App.AppendDebugLog("MBSIndexerThread: " + e.Message + EndOfLine)
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

	#tag Method, Flags = &h0
		Sub MBSParseProgress(filesDone As Integer, totalFiles As Integer)
		  // Called by MBSDocsetParser.Parse from this same thread (Parse runs
		  // synchronously inside Run) — safe to call AddUserInterfaceUpdate
		  // directly, same as every other progress point in this class.
		  AddUserInterfaceUpdate(New Pair("type", "file-scan-progress"), New Pair("done", filesDone), New Pair("total", totalFiles))
		End Sub
	#tag EndMethod

	#tag Event
		Sub UserInterfaceUpdate(data() As Dictionary)
		  For Each d As Dictionary In data
		    Var kind As String = d.Value("type")
		    If kind = "complete" Or kind = "error" Then MBSIndexer.MBSIsRunning = False
		    If ProgressDelegate = Nil Then Continue
		    Select Case kind
		    Case "parsing"
		      ProgressDelegate.IndexerParsing
		    Case "file-scan-progress"
		      ProgressDelegate.IndexerFileScanProgress(d.Value("done"), d.Value("total"))
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
		Private Sub DisambiguateSplitSources(chunks() As DocChunk)
		  Var counts As New Dictionary
		  For Each c As DocChunk In chunks
		    counts.Value(c.Source) = counts.Lookup(c.Source, 0).IntegerValue + 1
		  Next
		  Var seen As New Dictionary
		  For Each c As DocChunk In chunks
		    If counts.Value(c.Source).IntegerValue > 1 Then
		      Var n As Integer = seen.Lookup(c.Source, 0).IntegerValue + 1
		      seen.Value(c.Source) = n
		      c.Source = c.Source + " (part " + n.ToString + ")"
		    End If
		  Next
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ContentHash(text As String) As String
		  // String -> MemoryBlock is an implicit raw-bytes conversion in Xojo;
		  // DefineEncoding first guarantees those bytes are UTF-8 regardless of
		  // whatever encoding chunk text happened to carry after HTML parsing.
		  Var mb As MemoryBlock = DefineEncoding(text, Encodings.UTF8)
		  Return EncodeHex(Crypto.SHA2_256(mb)).Lowercase
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub EmbedPendingChunks(db As SQLiteDatabase)
		  // Identical batching/retry/failure-cap strategy as
		  // IndexerThread.EmbedPendingChunks, scoped to MBS chunks only so a
		  // concurrent Xojo-doc reindex (guarded out by IsRunning anyway) can
		  // never interleave with this transaction.
		  If db = Nil Then Return
		  Var total As Integer = PendingMBSEmbedCount(db)
		  If total = 0 Then Return
		  AddUserInterfaceUpdate(New Pair("type", "embed-progress"), New Pair("done", 0), New Pair("total", total))

		  Var done As Integer = 0
		  Var consecutiveFailures As Integer = 0
		  While True
		    Var ids() As Integer
		    Var texts() As String
		    Var rs As RowSet = db.SelectSQL("SELECT id, chunk_text FROM chunks WHERE embedded=0 AND source LIKE ? LIMIT " _
		      + Embedder.kBatchSize.ToString, DBHelper.kMBSSourcePrefix + "%")
		    While Not rs.AfterLastRow
		      ids.Add(rs.Column("id").IntegerValue)
		      texts.Add(rs.Column("chunk_text").StringValue)
		      rs.MoveToNextRow
		    Wend
		    rs.Close
		    If ids.Count = 0 Then Exit

		    Var embs() As MemoryBlock = Embedder.EmbedBatch(texts, Embedder.kTaskPrefixDocument)
		    If embs.Count = 0 Then
		      consecutiveFailures = consecutiveFailures + 1
		      If consecutiveFailures >= 5 Then
		        App.AppendDebugLog("MBSIndexerThread: 5 consecutive embed batch failures — aborting embed phase (" _
		          + PendingMBSEmbedCount(db).ToString + " chunks left pending)" + EndOfLine)
		        Exit
		      End If
		      db.BeginTransaction
		      mTransactionOpen = True
		      For k As Integer = 0 To ids.LastIndex
		        Var single As MemoryBlock = Embedder.FetchEmbedding(texts(k), Embedder.kTaskPrefixDocument, 30)
		        If single <> Nil Then
		          DBHelper.StoreChunkEmbedding(ids(k), single, db)
		        Else
		          db.ExecuteSQL("UPDATE chunks SET embedded=-1 WHERE id=?", ids(k))
		        End If
		      Next
		      db.CommitTransaction
		      mTransactionOpen = False
		      done = done + ids.Count
		      Continue
		    End If
		    consecutiveFailures = 0

		    db.BeginTransaction
		    mTransactionOpen = True
		    For k As Integer = 0 To ids.LastIndex
		      If k <= embs.LastIndex And embs(k) <> Nil Then
		        DBHelper.StoreChunkEmbedding(ids(k), embs(k), db)
		      Else
		        db.ExecuteSQL("UPDATE chunks SET embedded=-1 WHERE id=?", ids(k))
		      End If
		    Next
		    db.CommitTransaction
		    mTransactionOpen = False

		    done = done + ids.Count
		    If done Mod 500 < ids.Count Then
		      AddUserInterfaceUpdate(New Pair("type", "embed-progress"), New Pair("done", done), New Pair("total", total))
		    End If
		  Wend
		  AddUserInterfaceUpdate(New Pair("type", "embed-progress"), New Pair("done", total), New Pair("total", total))
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function PendingMBSEmbedCount(db As SQLiteDatabase) As Integer
		  Try
		    Var rs As RowSet = db.SelectSQL("SELECT COUNT(*) AS n FROM chunks WHERE embedded=0 AND source LIKE ?", DBHelper.kMBSSourcePrefix + "%")
		    Var n As Integer = rs.Column("n").IntegerValue
		    rs.Close
		    Return n
		  Catch e As DatabaseException
		    Return 0
		  End Try
		End Function
	#tag EndMethod

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
