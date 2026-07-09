#tag Module
Public Module DBHelper

	#tag ComputedProperty, Flags = &h0
		#tag Getter
			Get
			  Return App.GetDB
			End Get
		#tag EndGetter
		#tag Setter
			Set
			  App.SetDB(value)
			End Set
		#tag EndSetter
		DB As SQLiteDatabase
	#tag EndComputedProperty

	#tag Method, Flags = &h21
		Private Function Resolve(conn As SQLiteDatabase) As SQLiteDatabase
		  // Write methods take an optional connection so a background thread
		  // (IndexerThread, NoteEmbedThread) can pass its OWN connection instead
		  // of the shared main-thread one — the two must never interleave
		  // transactions on the same handle. Nil means "use the shared connection".
		  If conn <> Nil Then Return conn
		  Return DB
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function OpenConnection() As SQLiteDatabase
		  // A fresh connection to the same DB file, for a worker thread to own.
		  // WAL (set once in InitDB) lets it run alongside the main-thread reader.
		  Var f As FolderItem = Paths.DatabaseFile
		  If f = Nil Or Not f.Exists Then Return Nil
		  Try
		    Var db As New SQLiteDatabase
		    db.DatabaseFile = f
		    db.Connect
		    db.ExecuteSQL("PRAGMA journal_mode=WAL")
		    Return db
		  Catch e As RuntimeException
		    App.AppendDebugLog("DBHelper.OpenConnection: " + e.Message + EndOfLine)
		    Return Nil
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub InitDB()
		  Var f As FolderItem = Paths.DatabaseFile
		  If f = Nil Then
		    App.AppendDebugLog("DBHelper.InitDB: could not resolve database path" + EndOfLine)
		    Return
		  End If

		  // Pre-1.0 schema policy: no migrations. An outdated DB is deleted and
		  // recreated from the template; the empty chunks table triggers a full
		  // reindex (~5 min) on this launch. Notes are discarded — accepted.
		  If f.Exists And SchemaVersionOf(f) < kSchemaVersion Then
		    App.AppendDebugLog("DBHelper.InitDB: schema outdated — recreating DB from template (full reindex will follow)" + EndOfLine)
		    DeleteDatabaseFiles(f)
		  End If

		  If Not f.Exists Then
		    Var template As FolderItem = FindTemplateDB
		    If template <> Nil And template.Exists Then
		      template.CopyTo(f)
		    Else
		      App.AppendDebugLog("DBHelper.InitDB: xdox_template.sqlite not found — DB will be empty" + EndOfLine)
		    End If
		  End If

		  Try
		    Var db As New SQLiteDatabase
		    db.DatabaseFile = f
		    db.CreateDatabase
		    // WAL so external readers (XMCP) can query while XDOX writes.
		    db.ExecuteSQL("PRAGMA journal_mode=WAL")
		    App.SetDB(db)
		  Catch e As IOException
		    App.AppendDebugLog("DBHelper.InitDB: IOException " + e.Message + EndOfLine)
		  Catch e As RuntimeException
		    App.AppendDebugLog("DBHelper.InitDB: RuntimeException " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function SchemaVersionOf(f As FolderItem) As Integer
		  // Read metadata.schema_version through a throwaway connection.
		  // Anything unreadable counts as version 0 (v1 DBs had no such key).
		  Try
		    Var db As New SQLiteDatabase
		    db.DatabaseFile = f
		    db.Connect
		    Var rs As RowSet = db.SelectSQL("SELECT value FROM metadata WHERE key='schema_version'")
		    Var v As Integer = 0
		    If Not rs.AfterLastRow Then v = Integer.FromString(rs.Column("value").StringValue)
		    rs.Close
		    db.Close
		    Return v
		  Catch e As RuntimeException
		    Return 0
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub DeleteDatabaseFiles(f As FolderItem)
		  Try
		    Var wal As FolderItem = f.Parent.Child(f.Name + "-wal")
		    Var shm As FolderItem = f.Parent.Child(f.Name + "-shm")
		    If wal <> Nil And wal.Exists Then wal.Delete
		    If shm <> Nil And shm.Exists Then shm.Delete
		    f.Delete
		  Catch e As RuntimeException
		    App.AppendDebugLog("DBHelper.DeleteDatabaseFiles: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function FindTemplateDB() As FolderItem
		  Var roots(3) As FolderItem
		  roots(0) = App.ExecutableFile.Parent
		  roots(1) = App.ExecutableFile.Parent.Parent.Child("Resources")
		  roots(2) = App.ExecutableFile.Parent.Parent.Parent.Parent.Child("template-db")
		  roots(3) = App.ExecutableFile.Parent.Parent.Parent.Parent.Parent.Child("template-db")
		  For Each root As FolderItem In roots
		    If root = Nil Then Continue
		    Var f As FolderItem = root.Child("xdox_template.sqlite")
		    If f <> Nil And f.Exists Then Return f
		  Next
		  Return Nil
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function GetMetadata(key As String) As String
		  If DB = Nil Then Return ""
		  Try
		    Var rs As RowSet = DB.SelectSQL("SELECT value FROM metadata WHERE key=?", key)
		    If rs.AfterLastRow Then
		      rs.Close
		      Return ""
		    End If
		    Var v As String = rs.Column("value").StringValue
		    rs.Close
		    Return v
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.GetMetadata: " + e.Message + EndOfLine)
		    Return ""
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub SetMetadata(key As String, value As String, conn As SQLiteDatabase = Nil)
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Then Return
		  Try
		    d.ExecuteSQL("INSERT INTO metadata (key, value) VALUES (?, ?) " _
		      + "ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, value)
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.SetMetadata: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function ChunkCount() As Integer
		  If DB = Nil Then Return 0
		  Try
		    Var rs As RowSet = DB.SelectSQL("SELECT COUNT(*) AS n FROM chunks")
		    If rs.AfterLastRow Then
		      rs.Close
		      Return 0
		    End If
		    Var n As Integer = rs.Column("n").IntegerValue
		    rs.Close
		    Return n
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.ChunkCount: " + e.Message + EndOfLine)
		    Return 0
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StartTransaction()
		  If DB = Nil Then Return
		  DB.BeginTransaction
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub EndTransaction()
		  If DB = Nil Then Return
		  DB.CommitTransaction
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub CancelTransaction()
		  If DB = Nil Then Return
		  DB.RollbackTransaction
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub ClearChunks(conn As SQLiteDatabase = Nil)
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Then Return
		  Try
		    d.ExecuteSQL("DELETE FROM chunks") // chunks_ad trigger also clears embeddings
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.ClearChunks: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub ClearChunksForVersion(docsVersion As String, conn As SQLiteDatabase = Nil)
		  // Non-destructive reindex: wipe only one version's chunks so other
		  // indexed versions survive. The chunks_ad trigger cascades to embeddings
		  // and chunks_fts. Version-independent map chunks (docs_version='') are
		  // reinserted on every reindex, so clear them here too rather than leave
		  // duplicates accumulating.
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Then Return
		  Try
		    d.ExecuteSQL("DELETE FROM chunks WHERE docs_version=? OR docs_version=''", docsVersion)
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.ClearChunksForVersion: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub DeleteVersion(docsVersion As String, conn As SQLiteDatabase = Nil)
		  // Housekeeping: remove one indexed Xojo version entirely. Triggers cascade
		  // to embeddings + FTS. Version-independent chunks (docs_version='') are
		  // left untouched — they belong to whatever version(s) remain.
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Or docsVersion = "" Then Return
		  Try
		    d.ExecuteSQL("DELETE FROM chunks WHERE docs_version=?", docsVersion)
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.DeleteVersion: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function IndexedVersions() As String()
		  // Distinct non-empty docs_version values present in chunks, newest first.
		  // '' (version-independent map chunks) is excluded — it is not a version.
		  Var result() As String
		  If DB = Nil Then Return result
		  Try
		    Var rs As RowSet = DB.SelectSQL("SELECT DISTINCT docs_version FROM chunks WHERE docs_version <> '' ORDER BY docs_version DESC")
		    While Not rs.AfterLastRow
		      result.Add(rs.Column("docs_version").StringValue)
		      rs.MoveToNextRow
		    Wend
		    rs.Close
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.IndexedVersions: " + e.Message + EndOfLine)
		  End Try
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function ChunkCountForVersion(docsVersion As String) As Integer
		  If DB = Nil Then Return 0
		  Try
		    Var rs As RowSet = DB.SelectSQL("SELECT COUNT(*) AS n FROM chunks WHERE docs_version=?", docsVersion)
		    Var n As Integer = rs.Column("n").IntegerValue
		    rs.Close
		    Return n
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.ChunkCountForVersion: " + e.Message + EndOfLine)
		    Return 0
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function GetActiveVersion() As String
		  // The Xojo version chat/retrieval currently filters on. Falls back to the
		  // newest indexed version if the metadata key was never set (e.g. first run
		  // after upgrade) so retrieval never silently returns nothing.
		  Var v As String = GetMetadata("active_docs_version")
		  If v <> "" Then Return v
		  Var indexed() As String = IndexedVersions
		  If indexed.Count > 0 Then Return indexed(0)
		  Return ""
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub SetActiveVersion(docsVersion As String, conn As SQLiteDatabase = Nil)
		  SetMetadata("active_docs_version", docsVersion, conn)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function InsertChunk(source As String, title As String, chunkText As String, chunkIndex As Integer, docsVersion As String = "", conn As SQLiteDatabase = Nil) As Integer
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Then Return -1
		  Try
		    d.ExecuteSQL("INSERT INTO chunks (source, title, chunk_text, chunk_index, docs_version) VALUES (?, ?, ?, ?, ?)", source, title, chunkText, chunkIndex, docsVersion)
		    Var rs As RowSet = d.SelectSQL("SELECT last_insert_rowid() AS id")
		    If rs.AfterLastRow Then
		      rs.Close
		      Return -1
		    End If
		    Var newId As Integer = rs.Column("id").IntegerValue
		    rs.Close
		    Return newId
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.InsertChunk: " + e.Message + EndOfLine)
		    Return -1
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StoreChunkEmbedding(chunkId As Integer, emb As MemoryBlock, conn As SQLiteDatabase = Nil)
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Or emb = Nil Then Return
		  Try
		    d.ExecuteSQL("INSERT OR REPLACE INTO embeddings (chunk_id, embedding) VALUES (?, ?)", chunkId, emb)
		    d.ExecuteSQL("UPDATE chunks SET embedded=1 WHERE id=?", chunkId)
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.StoreChunkEmbedding: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function PendingEmbedCount(conn As SQLiteDatabase = Nil) As Integer
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Then Return 0
		  Try
		    Var rs As RowSet = d.SelectSQL("SELECT COUNT(*) AS n FROM chunks WHERE embedded=0")
		    Var n As Integer = rs.Column("n").IntegerValue
		    rs.Close
		    Return n
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.PendingEmbedCount: " + e.Message + EndOfLine)
		    Return 0
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub LinkChunks(id As Integer, prevId As Integer, nextId As Integer, conn As SQLiteDatabase = Nil)
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Then Return
		  Try
		    d.ExecuteSQL("UPDATE chunks SET prev_id=?, next_id=? WHERE id=?", prevId, nextId, id)
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.LinkChunks: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function GetChunkById(id As Integer, conn As SQLiteDatabase = Nil) As String
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Then Return ""
		  Try
		    Var rs As RowSet = d.SelectSQL("SELECT chunk_text FROM chunks WHERE id=?", id)
		    If rs.AfterLastRow Then
		      rs.Close
		      Return ""
		    End If
		    Var t As String = rs.Column("chunk_text").StringValue
		    rs.Close
		    Return t
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.GetChunkById: " + e.Message + EndOfLine)
		    Return ""
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function SaveNote(note As NoteRecord) As Boolean
		  If DB = Nil Or note = Nil Then Return False
		  Try
		    // embedded resets to 0 on update — an edited note needs a fresh vector.
		    DB.ExecuteSQL("INSERT INTO notes (id, title, body, tags, source, scope, docs_version, version_warned, created, updated) " _
		      + "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) " _
		      + "ON CONFLICT(id) DO UPDATE SET title=excluded.title, body=excluded.body, tags=excluded.tags, " _
		      + "scope=excluded.scope, docs_version=excluded.docs_version, version_warned=excluded.version_warned, updated=excluded.updated, embedded=0", _
		      note.Id, note.Title, note.Body, note.Tags, note.Source, note.Scope, note.DocsVersion, _
		      If(note.VersionWarned, 1, 0), note.Created, note.Updated)
		    Return True
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.SaveNote: " + e.Message + EndOfLine)
		    Return False
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function GetNote(id As String) As NoteRecord
		  If DB = Nil Then Return Nil
		  Try
		    Var rs As RowSet = DB.SelectSQL("SELECT * FROM notes WHERE id=?", id)
		    If rs.AfterLastRow Then
		      rs.Close
		      Return Nil
		    End If
		    Var n As NoteRecord = NoteFromRow(rs)
		    rs.Close
		    Return n
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.GetNote: " + e.Message + EndOfLine)
		    Return Nil
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function DeleteNote(id As String) As Boolean
		  If DB = Nil Then Return False
		  Try
		    DB.ExecuteSQL("DELETE FROM notes WHERE id=?", id) // notes_ad trigger clears note_embeddings
		    Return True
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.DeleteNote: " + e.Message + EndOfLine)
		    Return False
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function GetAllNotes() As NoteRecord()
		  Var result() As NoteRecord
		  If DB = Nil Then Return result
		  Try
		    Var rs As RowSet = DB.SelectSQL("SELECT * FROM notes ORDER BY updated DESC")
		    While Not rs.AfterLastRow
		      result.Add(NoteFromRow(rs))
		      rs.MoveToNextRow
		    Wend
		    rs.Close
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.GetAllNotes: " + e.Message + EndOfLine)
		  End Try
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function GetAllTags() As String()
		  // All tags across all notes, deduplicated, most-used first.
		  Var counts As New Dictionary
		  Var empty() As String
		  If DB = Nil Then Return empty
		  Try
		    Var rs As RowSet = DB.SelectSQL("SELECT tags FROM notes WHERE tags <> ''")
		    While Not rs.AfterLastRow
		      For Each t As String In rs.Column("tags").StringValue.Split(",")
		        t = t.Trim
		        If t <> "" Then counts.Value(t) = counts.Lookup(t, 0).IntegerValue + 1
		      Next
		      rs.MoveToNextRow
		    Wend
		    rs.Close
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.GetAllTags: " + e.Message + EndOfLine)
		  End Try

		  Var tags() As String
		  Var freqs() As Integer
		  For Each key As Variant In counts.Keys
		    tags.Add(key.StringValue)
		    freqs.Add(counts.Value(key).IntegerValue)
		  Next
		  freqs.SortWith(tags)
		  Var result() As String
		  For i As Integer = tags.LastIndex DownTo 0 // descending frequency
		    result.Add(tags(i))
		  Next
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub MarkNoteReviewed(id As String)
		  If DB = Nil Then Return
		  Try
		    DB.ExecuteSQL("UPDATE notes SET version_warned=0, docs_version=? WHERE id=?", _
		      GetActiveVersion, id)
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.MarkNoteReviewed: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StoreNoteEmbedding(noteId As String, emb As MemoryBlock, embeddedText As String, conn As SQLiteDatabase = Nil)
		  // embeddedText is the exact title+body that was embedded. If the note has
		  // been saved again since (a fast edit+save), the note's current text no
		  // longer matches, so this vector is stale and must NOT be written back —
		  // otherwise note_embeddings would describe old text. Comparing the text
		  // itself (not the 'updated' timestamp) is exact even for two saves within
		  // the same second. Done in one transaction so check and writes can't
		  // interleave with a concurrent writer.
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Or emb = Nil Then Return
		  Try
		    d.BeginTransaction
		    Var rs As RowSet = d.SelectSQL("SELECT title, body FROM notes WHERE id=?", noteId)
		    Var currentText As String = ""
		    Var found As Boolean = Not rs.AfterLastRow
		    If found Then currentText = rs.Column("title").StringValue + Chr(10) + rs.Column("body").StringValue
		    rs.Close
		    If Not found Or currentText <> embeddedText Then
		      // Note deleted or superseded by a newer save — discard this vector.
		      // A newer save started its own embed thread for the fresh text.
		      d.RollbackTransaction
		      Return
		    End If
		    d.ExecuteSQL("INSERT OR REPLACE INTO note_embeddings (note_id, embedding) VALUES (?, ?)", noteId, emb)
		    d.ExecuteSQL("UPDATE notes SET embedded=1 WHERE id=?", noteId)
		    d.CommitTransaction
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.StoreNoteEmbedding: " + e.Message + EndOfLine)
		    Try
		      d.RollbackTransaction
		    Catch e2 As DatabaseException
		    End Try
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub EmbedNote(note As NoteRecord, conn As SQLiteDatabase = Nil)
		  // One vector per note over title + body. Failure is silent by design —
		  // the note is saved regardless; backfill picks it up later. Embedding
		  // blocks on a synchronous HTTP call, so callers on the main thread
		  // should use EmbedNoteAsync rather than call this directly.
		  // StoreNoteEmbedding compares the embedded text against the note's current
		  // text and discards the result if a newer save has since landed.
		  If note = Nil Then Return
		  If Not ModelManager.EmbedServerReady Then Return
		  Var embeddedText As String = note.Title + Chr(10) + note.Body
		  Var emb As MemoryBlock = Embedder.FetchEmbedding(embeddedText, 5)
		  If emb <> Nil Then StoreNoteEmbedding(note.Id, emb, embeddedText, conn)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub EmbedNoteById(noteId As String, conn As SQLiteDatabase = Nil)
		  // Re-reads the note through the given connection and embeds it. Used by
		  // NoteEmbedThread so read+embed+write all happen on that thread's own
		  // connection.
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Then Return
		  Try
		    Var rs As RowSet = d.SelectSQL("SELECT * FROM notes WHERE id=?", noteId)
		    If rs.AfterLastRow Then
		      rs.Close
		      Return
		    End If
		    Var n As NoteRecord = NoteFromRow(rs)
		    rs.Close
		    EmbedNote(n, conn)
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.EmbedNoteById: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub EmbedNoteAsync(noteId As String)
		  // Fire-and-forget note embedding on a worker thread — keeps note-save
		  // from freezing the UI while a slow model produces the vector.
		  If noteId = "" Or Not ModelManager.EmbedServerReady Then Return
		  Var t As New NoteEmbedThread
		  t.EmbedOne(noteId)
		  t.Start
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub BackfillNoteEmbeddings(conn As SQLiteDatabase = Nil)
		  // Embed notes saved while the embedding server was down. Runs on a
		  // worker thread (NoteEmbedThread) so the up-to-200-note loop of blocking
		  // embed calls doesn't freeze the UI.
		  Var d As SQLiteDatabase = Resolve(conn)
		  If d = Nil Or Not ModelManager.EmbedServerReady Then Return
		  Try
		    Var pending() As NoteRecord
		    Var rs As RowSet = d.SelectSQL("SELECT * FROM notes WHERE embedded=0 LIMIT 200")
		    While Not rs.AfterLastRow
		      pending.Add(NoteFromRow(rs))
		      rs.MoveToNextRow
		    Wend
		    rs.Close
		    For Each n As NoteRecord In pending
		      EmbedNote(n, conn)
		    Next
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.BackfillNoteEmbeddings: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub BackfillNoteEmbeddingsAsync()
		  // Fire-and-forget backfill on a worker thread.
		  If Not ModelManager.EmbedServerReady Then Return
		  Var t As New NoteEmbedThread
		  t.Start
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function NoteFromRow(rs As RowSet) As NoteRecord
		  Var n As New NoteRecord
		  n.Id = rs.Column("id").StringValue
		  n.Title = rs.Column("title").StringValue
		  n.Body = rs.Column("body").StringValue
		  n.Tags = rs.Column("tags").StringValue
		  n.Source = rs.Column("source").StringValue
		  n.Scope = rs.Column("scope").StringValue
		  n.DocsVersion = rs.Column("docs_version").StringValue
		  n.VersionWarned = (rs.Column("version_warned").IntegerValue = 1)
		  n.Created = rs.Column("created").StringValue
		  n.Updated = rs.Column("updated").StringValue
		  Return n
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub MarkStaleNotes(currentVersion As String)
		  // Only version-scoped notes can go stale. Global notes (scope='all') hold
		  // version-independent knowledge and must never be flagged on a Xojo update.
		  If DB = Nil Then Return
		  Try
		    DB.ExecuteSQL("UPDATE notes SET version_warned=1 " _
		      + "WHERE scope='version' " _
		      + "AND docs_version IS NOT NULL " _
		      + "AND docs_version <> ? " _
		      + "AND version_warned=0", currentVersion)
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.MarkStaleNotes: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function StaleNoteCount() As Integer
		  If DB = Nil Then Return 0
		  Try
		    Var rs As RowSet = DB.SelectSQL("SELECT COUNT(*) AS n FROM notes WHERE version_warned=1")
		    If rs.AfterLastRow Then
		      rs.Close
		      Return 0
		    End If
		    Var n As Integer = rs.Column("n").IntegerValue
		    rs.Close
		    Return n
		  Catch e As DatabaseException
		    App.AppendDebugLog("DBHelper.StaleNoteCount: " + e.Message + EndOfLine)
		    Return 0
		  End Try
		End Function
	#tag EndMethod

	#tag Constant, Name = kSchemaVersion, Type = Double, Dynamic = False, Default = \"3", Scope = Public
	#tag EndConstant

	#tag Method, Flags = &h0
		Function JSONEscape(s As String) As String
		  s = s.ReplaceAll("\", "\\")
		  s = s.ReplaceAll("""", "\""")
		  s = s.ReplaceAll(Chr(13), "\r")
		  s = s.ReplaceAll(Chr(10), "\n")
		  s = s.ReplaceAll(Chr(9), "\t")
		  Return """" + s + """"
		End Function
	#tag EndMethod

End Module
#tag EndModule
