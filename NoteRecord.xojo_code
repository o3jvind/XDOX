#tag Class
Public Class NoteRecord

	#tag Method, Flags = &h0
		Shared Function NewManual() As NoteRecord
		  // Manual notes default to global scope — most hand-written notes capture
		  // version-independent knowledge and should never be flagged stale. The
		  // editor lets the user switch a note to a specific version.
		  Var n As New NoteRecord
		  n.Id = GenerateUUID
		  n.Source = "manual"
		  n.Scope = "all"
		  n.DocsVersion = DBHelper.GetActiveVersion
		  n.Created = NowISO8601
		  n.Updated = n.Created
		  Return n
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Shared Function NewFromConversation(title As String, body As String) As NoteRecord
		  // Notes saved from a chat answer are tied to the active docs version by
		  // default — the answer was grounded in that version's docs, so it may go
		  // stale on an update. The user can switch it to global in the editor.
		  Var n As NoteRecord = NewManual
		  n.Source = "conversation"
		  n.Scope = "version"
		  n.Title = title
		  n.Body = body
		  Return n
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function AsJSON() As String
		  Var j As New JSONItem
		  j.Value("id") = Id
		  j.Value("title") = Title
		  j.Value("body") = Body
		  // "[]" forces array serialisation even when there are no tags.
		  Var tagArr As New JSONItem("[]")
		  For Each t As String In TagList
		    tagArr.Add(t)
		  Next
		  j.Value("tags") = tagArr
		  j.Value("source") = Source
		  j.Value("scope") = Scope
		  j.Value("docs_version") = DocsVersion
		  j.Value("version_warned") = VersionWarned
		  j.Value("created") = Created
		  j.Value("updated") = Updated
		  Return j.ToString
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function TagList() As String()
		  // Tags are stored as a comma-separated string in the DB.
		  Var result() As String
		  For Each t As String In Tags.Split(",")
		    t = t.Trim
		    If t <> "" Then result.Add(t)
		  Next
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Shared Function GenerateUUID() As String
		  // Version-4 UUID from Crypto random bytes.
		  Var b As MemoryBlock = Crypto.GenerateRandomBytes(16)
		  b.UInt8Value(6) = (b.UInt8Value(6) And &h0F) Or &h40
		  b.UInt8Value(8) = (b.UInt8Value(8) And &h3F) Or &h80
		  Var hex As String = EncodeHex(b).Lowercase
		  Return hex.Left(8) + "-" + hex.Middle(8, 4) + "-" + hex.Middle(12, 4) _
		    + "-" + hex.Middle(16, 4) + "-" + hex.Middle(20, 12)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Shared Function NowISO8601() As String
		  Var s As String = DateTime.Now.SQLDateTime // "YYYY-MM-DD HH:MM:SS"
		  Return s.Left(10) + "T" + s.Middle(11)
		End Function
	#tag EndMethod


	#tag Property, Flags = &h0
		Id As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Title As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Body As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Tags As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Source As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Scope As String
	#tag EndProperty

	#tag Property, Flags = &h0
		DocsVersion As String
	#tag EndProperty

	#tag Property, Flags = &h0
		VersionWarned As Boolean
	#tag EndProperty

	#tag Property, Flags = &h0
		Created As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Updated As String
	#tag EndProperty

End Class
#tag EndClass
