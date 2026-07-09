#tag Module
Protected Module TagSuggester

	#tag Method, Flags = &h0
		Function SuggestTags(body As String) As String()
		  // Suggest up to 3 normalised tags by matching the note body against the
		  // docs index: FTS on key terms from the body, then map the matching
		  // chunks' titles/sources through the keyword->tag dictionary.
		  Var result() As String
		  If DBHelper.DB = Nil Then Return result

		  Var terms() As String = KeyTerms(body)
		  If terms.Count = 0 Then Return result

		  Var mapping As Dictionary = KeywordTagMap
		  Var seen As New Dictionary

		  Try
		    Var query As String = String.FromArray(terms, " OR ")
		    Var rs As RowSet = DBHelper.DB.SelectSQL( _
		      "SELECT c.title, c.source FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid " _
		      + "WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT 15", query)
		    While Not rs.AfterLastRow
		      Var haystack As String = rs.Column("title").StringValue + " " + rs.Column("source").StringValue
		      For Each key As Variant In mapping.Keys
		        If haystack.IndexOf(key.StringValue) >= 0 Then
		          Var tag As String = mapping.Value(key)
		          If Not seen.HasKey(tag) Then
		            seen.Value(tag) = True
		            result.Add(tag)
		            If result.Count >= 3 Then
		              rs.Close
		              Return result
		            End If
		          End If
		        End If
		      Next
		      rs.MoveToNextRow
		    Wend
		    rs.Close
		  Catch e As DatabaseException
		    App.AppendDebugLog("TagSuggester.SuggestTags: " + e.Message + EndOfLine)
		  End Try
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function KeyTerms(body As String) As String()
		  // First 500 chars, words longer than 5 chars, top 10, FTS-safe.
		  Var result() As String
		  Var head As String = body.Left(500)
		  Var cleaned As String = Retrieval.SanitizeQuery(head)
		  For Each w As String In cleaned.Split(" ")
		    If w.Length > 5 Then
		      result.Add(w)
		      If result.Count >= 10 Then Exit
		    End If
		  Next
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function KeywordTagMap() As Dictionary
		  Var d As New Dictionary
		  d.Value("FolderItem") = "filesystem"
		  d.Value("URLConnection") = "networking"
		  d.Value("Database") = "sqlite"
		  d.Value("SQLite") = "sqlite"
		  d.Value("Thread") = "threading"
		  d.Value("Timer") = "threading"
		  d.Value("Desktop") = "ui"
		  d.Value("WebView") = "ui"
		  d.Value("Exception") = "error-handling"
		  d.Value("Try") = "error-handling"
		  d.Value("JSON") = "json"
		  d.Value("XMLDocument") = "xml"
		  d.Value("Picture") = "graphics"
		  d.Value("Graphics") = "graphics"
		  d.Value("Shell") = "shell"
		  d.Value("NSTask") = "shell"
		  d.Value("Socket") = "networking"
		  d.Value("Crypto") = "security"
		  d.Value("Declare") = "declares"
		  Return d
		End Function
	#tag EndMethod

End Module
#tag EndModule
