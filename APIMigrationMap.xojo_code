#tag Module
Protected Module APIMigrationMap

	#tag Method, Flags = &h0
		Function Chunks() As DocChunk()
		  // Curated legacy→modern API mapping chunks, appended to the index by
		  // IndexerThread as part of the normal indexing pass. The Xojo docs
		  // bundle (llms-full.txt) contains ONLY API 2 pages — no MsgBox,
		  // PushButton, Date, RecordSet… — so a user question phrased with an
		  // old name would otherwise have nothing to retrieve. The official
		  // "Deprecated and removed features" tables list WHAT is deprecated
		  // but not the replacement; these chunks supply the old→new link.
		  // Every modern name below is verified to have its own page in the
		  // indexed docs (2026r1.2) — keep it that way when adding entries.
		  Var chunks() As DocChunk

		  chunks.Add(MapChunk("MsgBox (API 1, deprecated) → MessageBox", _
		    "MsgBox is the deprecated API 1 name for showing a simple message dialog. Use MessageBox in modern Xojo (API 2). For dialogs with custom buttons, icons or explanations, use the MessageDialog class." + EndOfLine _
		    + "Old: MsgBox(""Hello"")" + EndOfLine _
		    + "New: MessageBox(""Hello"")"))

		  chunks.Add(MapChunk("Dim (legacy keyword) → Var", _
		    "Dim still compiles — it is a supported synonym kept for VB compatibility, not an error — but Var is the idiomatic API 2 keyword for declaring variables." + EndOfLine _
		    + "Old: Dim s As String" + EndOfLine _
		    + "New: Var s As String"))

		  chunks.Add(MapChunk("Date (deprecated class) → DateTime", _
		    "The Date class is deprecated. Use DateTime, which is immutable. DateTime.Now returns the current date/time. Date.TotalSeconds is replaced by DateTime.SecondsFrom1970." + EndOfLine _
		    + "Old: Dim d As New Date" + EndOfLine _
		    + "New: Var d As DateTime = DateTime.Now"))

		  chunks.Add(MapChunk("PushButton (deprecated control) → DesktopButton", _
		    "PushButton is deprecated. Use DesktopButton. Its click event is Pressed — API 1 called it Action." + EndOfLine _
		    + "Old: PushButton with an Action event handler" + EndOfLine _
		    + "New: DesktopButton with a Pressed event handler"))

		  chunks.Add(MapChunk("Label / StaticText (deprecated controls) → DesktopLabel", _
		    "The Label control (called StaticText in very old versions) is deprecated. Use DesktopLabel; the displayed string is its Text property."))

		  chunks.Add(MapChunk("TextField (deprecated control) → DesktopTextField", _
		    "TextField is deprecated. Use DesktopTextField. Its change event is TextChanged — API 1 called it TextChange."))

		  chunks.Add(MapChunk("TextArea (deprecated control) → DesktopTextArea", _
		    "TextArea is deprecated. Use DesktopTextArea for multi-line text editing."))

		  chunks.Add(MapChunk("ListBox (deprecated control) → DesktopListBox", _
		    "ListBox is deprecated. Use DesktopListBox. The selected row is SelectedRowIndex (API 1: ListIndex); DeleteAllRows is now RemoveAllRows; rows are added with AddRow / AddRowAt."))

		  chunks.Add(MapChunk("PopupMenu (deprecated control) → DesktopPopupMenu", _
		    "PopupMenu is deprecated. Use DesktopPopupMenu. The selected row is SelectedRowIndex (API 1: ListIndex)."))

		  chunks.Add(MapChunk("Canvas (deprecated control) → DesktopCanvas", _
		    "Canvas is deprecated. Use DesktopCanvas. All drawing happens in the Paint event via its g As Graphics parameter — the old direct Canvas.Graphics property access was deprecated in 2011 and later removed."))

		  chunks.Add(MapChunk("Window (deprecated class) → DesktopWindow", _
		    "Window is deprecated. Use DesktopWindow. Its lifecycle events are Opening and Closing — API 1 called them Open and Close."))

		  chunks.Add(MapChunk("CheckBox (deprecated control) → DesktopCheckBox", _
		    "CheckBox is deprecated. Use DesktopCheckBox; the checked state is its Value property (Boolean)."))

		  chunks.Add(MapChunk("Application (deprecated class) → DesktopApplication", _
		    "Application is deprecated for desktop projects. The App class subclasses DesktopApplication, and its startup event is Opening — API 1 called it Open."))

		  chunks.Add(MapChunk("MenuItem (deprecated class) → DesktopMenuItem", _
		    "MenuItem is deprecated for desktop projects. Use DesktopMenuItem."))

		  chunks.Add(MapChunk("Timer.Action (deprecated event) → Timer.Run", _
		    "The Timer class still exists in API 2, but its periodic event is Run — API 1 called it Action."))

		  chunks.Add(MapChunk("RecordSet (deprecated class) → RowSet", _
		    "RecordSet is deprecated. Use RowSet. MoveNext is now MoveToNextRow, EOF is AfterLastRow, and Field/IdxField are Column/ColumnAt." + EndOfLine _
		    + "Old loop: While Not rs.EOF ... rs.Field(""name"").StringValue ... rs.MoveNext ... Wend" + EndOfLine _
		    + "New loop: While Not rs.AfterLastRow ... rs.Column(""name"").StringValue ... rs.MoveToNextRow ... Wend" + EndOfLine _
		    + "A RowSet is also iterable, so the idiomatic way to loop through all rows is:" + EndOfLine _
		    + "For Each row As DatabaseRow In rs ... Next"))

		  chunks.Add(MapChunk("Database.SQLSelect (deprecated) → Database.SelectSQL", _
		    "SQLSelect is deprecated. Use SelectSQL, which supports prepared-statement parameters and raises a DatabaseException on error instead of requiring Error/ErrorCode checks." + EndOfLine _
		    + "Old: Dim rs As RecordSet = db.SQLSelect(""SELECT * FROM t"")" + EndOfLine _
		    + "New: Var rs As RowSet = db.SelectSQL(""SELECT * FROM t WHERE id = ?"", 5)"))

		  chunks.Add(MapChunk("Database.SQLExecute (deprecated) → Database.ExecuteSQL", _
		    "SQLExecute is deprecated. Use ExecuteSQL, which supports prepared-statement parameters and raises a DatabaseException on error."))

		  chunks.Add(MapChunk("DatabaseRecord (deprecated class) → DatabaseRow", _
		    "DatabaseRecord is deprecated. Use DatabaseRow with Database.AddRow."))

		  chunks.Add(MapChunk("InStr / Mid / Len (deprecated functions) → String.IndexOf / String.Middle / String.Length", _
		    "The VB-style global string functions are deprecated in favour of String methods — and the indexing changed: InStr is 1-based (0 = not found) while String.IndexOf is 0-based (-1 = not found); Mid is 1-based while String.Middle is 0-based." + EndOfLine _
		    + "Old: InStr(s, ""x"") / Mid(s, 2, 3) / Len(s)" + EndOfLine _
		    + "New: s.IndexOf(""x"") / s.Middle(1, 3) / s.Length"))

		  chunks.Add(MapChunk("Left / Right (deprecated functions) → String.Left / String.Right", _
		    "The global Left and Right functions are deprecated in favour of the String methods." + EndOfLine _
		    + "Old: Left(s, 3)" + EndOfLine _
		    + "New: s.Left(3)"))

		  chunks.Add(MapChunk("Array Append / Insert / Remove / UBound / Redim (deprecated) → Add / AddAt / RemoveAt / LastIndex / ResizeTo", _
		    "The API 1 array calls are deprecated: Append is now Add, Insert is AddAt, Remove is RemoveAt, UBound is LastIndex, and Redim is ResizeTo." + EndOfLine _
		    + "Old: names.Append(""x"") / UBound(names)" + EndOfLine _
		    + "New: names.Add(""x"") / names.LastIndex"))

		  chunks.Add(MapChunk("Str / Val (deprecated functions) → ToString / FromString", _
		    "Str and Val are deprecated. Numbers convert to text with ToString, and text to numbers with the shared FromString methods." + EndOfLine _
		    + "Old: Str(n) / Val(s)" + EndOfLine _
		    + "New: n.ToString / Integer.FromString(s) or Double.FromString(s)"))

		  chunks.Add(MapChunk("Text data type / Xojo.Core framework (deprecated) → String and classic classes", _
		    "The Text data type and the Xojo.Core namespace from the old Xojo framework are deprecated. Use String instead of Text, Dictionary instead of Xojo.Core.Dictionary, and DateTime instead of Xojo.Core.Date."))

		  chunks.Add(MapChunk("GetFolderItem (deprecated function) → New FolderItem / SpecialFolder", _
		    "GetFolderItem is deprecated. Create paths with the FolderItem constructor, and reach standard locations through the SpecialFolder module." + EndOfLine _
		    + "Old: Dim f As FolderItem = GetFolderItem(""data.txt"")" + EndOfLine _
		    + "New: Var f As FolderItem = New FolderItem(""data.txt"") — or SpecialFolder.Desktop.Child(""data.txt"")"))

		  Return chunks
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function PinTriggers() As Dictionary
		  // Lowercase whole-word triggers → the exact chunk title (must match
		  // Chunks() above). Used by Retrieval to pin a mapping chunk into the
		  // context whenever the question names a legacy identifier — FTS
		  // multi-term matching is implicit AND and cosine alone can rank the
		  // short mapping chunks below generic guide pages, so ranking is a
		  // gamble without this. Generic English words (left, mid, len, str,
		  // val, text, action…) are deliberately NOT triggers: a false pin only
		  // costs a few context lines, but they would fire on almost every
		  // question. Domain words like date/window/canvas are fine — when a
		  // question contains them, the mapping is relevant anyway.
		  Var t As New Dictionary
		  t.Value("msgbox") = "MsgBox (API 1, deprecated) → MessageBox"
		  t.Value("dim") = "Dim (legacy keyword) → Var"
		  t.Value("date") = "Date (deprecated class) → DateTime"
		  t.Value("pushbutton") = "PushButton (deprecated control) → DesktopButton"
		  t.Value("statictext") = "Label / StaticText (deprecated controls) → DesktopLabel"
		  t.Value("label") = "Label / StaticText (deprecated controls) → DesktopLabel"
		  t.Value("textfield") = "TextField (deprecated control) → DesktopTextField"
		  t.Value("textchange") = "TextField (deprecated control) → DesktopTextField"
		  t.Value("textarea") = "TextArea (deprecated control) → DesktopTextArea"
		  t.Value("listbox") = "ListBox (deprecated control) → DesktopListBox"
		  t.Value("listindex") = "ListBox (deprecated control) → DesktopListBox"
		  t.Value("deleteallrows") = "ListBox (deprecated control) → DesktopListBox"
		  t.Value("popupmenu") = "PopupMenu (deprecated control) → DesktopPopupMenu"
		  t.Value("canvas") = "Canvas (deprecated control) → DesktopCanvas"
		  t.Value("window") = "Window (deprecated class) → DesktopWindow"
		  t.Value("checkbox") = "CheckBox (deprecated control) → DesktopCheckBox"
		  t.Value("application") = "Application (deprecated class) → DesktopApplication"
		  t.Value("menuitem") = "MenuItem (deprecated class) → DesktopMenuItem"
		  t.Value("timer") = "Timer.Action (deprecated event) → Timer.Run"
		  t.Value("recordset") = "RecordSet (deprecated class) → RowSet"
		  t.Value("movenext") = "RecordSet (deprecated class) → RowSet"
		  t.Value("sqlselect") = "Database.SQLSelect (deprecated) → Database.SelectSQL"
		  t.Value("sqlexecute") = "Database.SQLExecute (deprecated) → Database.ExecuteSQL"
		  t.Value("databaserecord") = "DatabaseRecord (deprecated class) → DatabaseRow"
		  t.Value("instr") = "InStr / Mid / Len (deprecated functions) → String.IndexOf / String.Middle / String.Length"
		  t.Value("ubound") = "Array Append / Insert / Remove / UBound / Redim (deprecated) → Add / AddAt / RemoveAt / LastIndex / ResizeTo"
		  t.Value("redim") = "Array Append / Insert / Remove / UBound / Redim (deprecated) → Add / AddAt / RemoveAt / LastIndex / ResizeTo"
		  t.Value("xojo.core") = "Text data type / Xojo.Core framework (deprecated) → String and classic classes"
		  t.Value("getfolderitem") = "GetFolderItem (deprecated function) → New FolderItem / SpecialFolder"
		  Return t
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function MapChunk(title As String, body As String) As DocChunk
		  Var chunk As New DocChunk
		  chunk.Title = title
		  chunk.Source = kSource
		  chunk.ChunkText = title + EndOfLine + EndOfLine + body
		  Return chunk
		End Function
	#tag EndMethod

	#tag Constant, Name = kSource, Type = String, Dynamic = False, Default = \"curated > API 2 migration", Scope = Public
	#tag EndConstant

End Module
#tag EndModule
