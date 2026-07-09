#tag DesktopWindow
Begin DesktopWindow NoteEditorWindow
   Backdrop        =   0
   BackgroundColor =   &cFFFFFF
   Composite       =   False
   DefaultLocation =   2
   FullScreen      =   False
   HasBackgroundColor=   False
   HasCloseButton  =   True
   HasFullScreenButton=   False
   HasMaximizeButton=   True
   HasMinimizeButton=   True
   HasTitleBar     =   True
   Height          =   600
   ImplicitInstance=   False
   MacProcID       =   0
   MaximumHeight   =   32000
   MaximumWidth    =   32000
   MenuBar         =   1984348159
   MenuBarVisible  =   False
   MinimumHeight   =   300
   MinimumWidth    =   400
   Resizeable      =   True
   Title           =   "Note"
   Type            =   0
   Visible         =   False
   Width           =   700
   Begin DesktopWKWebViewControlMBS EditorView
      AutoDeactivate  =   True
      Enabled         =   True
      Height          =   600
      Index           =   -2147483648
      InitialParent   =   ""
      Left            =   0
      LockBottom      =   True
      LockedInPosition=   False
      LockLeft        =   True
      LockRight       =   True
      LockTop         =   True
      Scope           =   0
      TabIndex        =   0
      TabPanelIndex   =   0
      TabStop         =   True
      Tooltip         =   ""
      Top             =   0
      Visible         =   True
      Width           =   700
   End
End
#tag EndDesktopWindow

#tag WindowCode
	#tag Event
		Function CancelClosing(appQuitting As Boolean) As Boolean
		  #Pragma Unused appQuitting
		  If Not mDirty Then Return False
		  Var d As New MessageDialog
		  d.Message = "You have unsaved changes."
		  d.Explanation = "Do you want to save them before closing?"
		  d.ActionButton.Caption = "Save"
		  d.CancelButton.Visible = True
		  d.AlternateActionButton.Visible = True
		  d.AlternateActionButton.Caption = "Don't Save"
		  Var result As MessageDialogButton = d.ShowModal
		  Select Case result
		  Case d.ActionButton
		    If SaveCurrent Then Return False
		    // Save failed — keep the window open so the user's text isn't lost.
		    Var err As New MessageDialog
		    err.Message = "The note could not be saved."
		    err.Explanation = "The database returned an error, so the window will stay open. See the debug log for details."
		    err.ActionButton.Caption = "OK"
		    Call err.ShowModal
		    Return True // cancel the close
		  Case d.AlternateActionButton
		    Return False
		  Else
		    Return True // cancel the close
		  End Select
		End Function
	#tag EndEvent


	#tag Method, Flags = &h0
		Shared Sub OpenNew()
		  // NOTE: the window's Opening event fires during New — before any field
		  // assignment — so all initialisation lives in Setup, not Opening.
		  Var w As New NoteEditorWindow
		  w.Setup(NoteRecord.NewManual, False)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Shared Sub OpenFromConversation(title As String, body As String)
		  Var w As New NoteEditorWindow
		  w.mSuggested = TagSuggester.SuggestTags(body)
		  w.Setup(NoteRecord.NewFromConversation(title, body), False)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Shared Sub OpenExisting(noteId As String)
		  Var n As NoteRecord = DBHelper.GetNote(noteId)
		  If n = Nil Then Return
		  Var w As New NoteEditorWindow
		  w.Setup(n, True)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub Setup(note As NoteRecord, exists As Boolean)
		  mNote = note
		  mExists = exists
		  LoadEditorUI
		  Show
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub LoadEditorUI()
		  Try
		    Var html As String = ReadAsset("web-assets/note-editor/note-editor.html")
		    If html = "" Then
		      App.AppendDebugLog("NoteEditorWindow: note-editor.html not found" + EndOfLine)
		      Return
		    End If

		    Var css As String
		    css = css + ReadAsset("web-assets/css/variables.css")
		    css = css + ReadAsset("web-assets/js/vendor/easymde.min.css")
		    css = css + ReadAsset("web-assets/note-editor/note-editor.css")
		    html = html.ReplaceAll("<!-- CSS_PLACEHOLDER -->", "<style>" + css + "</style>")

		    Var js As String
		    js = js + ReadAsset("web-assets/js/vendor/marked.min.js") + EndOfLine
		    js = js + ReadAsset("web-assets/js/sanitize.js") + EndOfLine
		    js = js + ReadAsset("web-assets/js/vendor/easymde.min.js") + EndOfLine
		    js = js + ReadAsset("web-assets/note-editor/note-editor.js") + EndOfLine
		    html = html.ReplaceAll("<!-- JS_PLACEHOLDER -->", "<script>" + js + "</script>")

		    EditorView.AddScriptMessageHandler("editorReady")
		    EditorView.AddScriptMessageHandler("saveNote")
		    EditorView.AddScriptMessageHandler("deleteNote")
		    EditorView.AddScriptMessageHandler("setDirty")
		    EditorView.AddScriptMessageHandler("markAsReviewed")
		    EditorView.AddScriptMessageHandler("dismissStaleness")
		    EditorView.AddScriptMessageHandler("closeEditor")

		    EditorView.LoadHTML(html, "https://xdox.local/note-editor/")

		    UpdateWindowTitle
		  Catch e As RuntimeException
		    App.AppendDebugLog("NoteEditorWindow.LoadEditorUI: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ReadAsset(relativePath As String) As String
		  Var f As FolderItem = App.FindFile(relativePath)
		  If f = Nil Or Not f.Exists Then
		    App.AppendDebugLog("NoteEditorWindow.ReadAsset: not found: " + relativePath + EndOfLine)
		    Return ""
		  End If
		  Var ts As TextInputStream = TextInputStream.Open(f)
		  ts.Encoding = Encodings.UTF8
		  Var result As String = ts.ReadAll
		  ts.Close
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub PushNoteToJS()
		  // The note JSON carries "exists" so JS can show/hide the Delete button.
		  Var j As New JSONItem(mNote.AsJSON)
		  j.Value("exists") = mExists
		  EditorView.EvaluateJavaScript("loadNote(" + j.ToString + ");")

		  Var tags As New JSONItem("[]")
		  For Each t As String In DBHelper.GetAllTags
		    tags.Add(t)
		  Next
		  EditorView.EvaluateJavaScript("loadTagSuggestions(" + tags.ToString + ");")

		  If mSuggested.Count > 0 Then
		    Var sug As New JSONItem
		    For Each t As String In mSuggested
		      sug.Add(t)
		    Next
		    EditorView.EvaluateJavaScript("showSuggestedTags(" + sug.ToString + ");")
		  End If

		  If mNote.VersionWarned Then
		    EditorView.EvaluateJavaScript("showStalenessBanner(" + JSONEscape(mNote.DocsVersion) + ");")
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function SaveCurrent() As Boolean
		  // Returns True only if the note actually persisted. Callers that gate
		  // window-close on the save (CancelClosing) rely on this.
		  mNote.Updated = NoteRecord.NowISO8601
		  If DBHelper.SaveNote(mNote) Then
		    mExists = True
		    mDirty = False
		    UpdateWindowTitle
		    RefreshSidebar
		    EditorView.EvaluateJavaScript("noteSaved();")
		    // Task 12: notes join semantic retrieval the moment they're saved.
		    // Embedded off-thread so the save doesn't block the UI on a slow model.
		    DBHelper.EmbedNoteAsync(mNote.Id)
		    Return True
		  End If
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub RefreshSidebar()
		  Try
		    Window1.MainView.RefreshSidebar
		  Catch e As RuntimeException
		    App.AppendDebugLog("NoteEditorWindow.RefreshSidebar: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub UpdateWindowTitle()
		  Self.Title = If(mNote.Title <> "", "Note — " + mNote.Title, "New Note")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ApplyScope(scope As String)
		  // Reconcile the note's relevance setting with its version fields.
		  // 'version' ties the note to a concrete docs version (stamping the active
		  // one if none is set yet); 'all' makes it global and clears any stale flag
		  // so a global note is never shown as outdated.
		  If scope = "version" Then
		    mNote.Scope = "version"
		    If mNote.DocsVersion = "" Then mNote.DocsVersion = DBHelper.GetActiveVersion
		  Else
		    mNote.Scope = "all"
		    mNote.VersionWarned = False
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function JSONEscape(s As String) As String
		  s = s.ReplaceAll("\", "\\")
		  s = s.ReplaceAll("""", "\""")
		  s = s.ReplaceAll(Chr(13), "\r")
		  s = s.ReplaceAll(Chr(10), "\n")
		  s = s.ReplaceAll(Chr(9), "\t")
		  Return """" + s + """"
		End Function
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mDirty As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mExists As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mNote As NoteRecord
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mSuggested() As String
	#tag EndProperty

	#tag MenuHandler
		Function EditCut() As Boolean Handles EditCut.Action
		  EditorView.EvaluateJavaScript("document.execCommand('cut')")
		  Return True
		End Function
	#tag EndMenuHandler

	#tag MenuHandler
		Function EditCopy() As Boolean Handles EditCopy.Action
		  EditorView.EvaluateJavaScript("document.execCommand('copy')")
		  Return True
		End Function
	#tag EndMenuHandler

	#tag MenuHandler
		Function EditSelectAll() As Boolean Handles EditSelectAll.Action
		  EditorView.EvaluateJavaScript("selectAllInEditor()")
		  Return True
		End Function
	#tag EndMenuHandler

#tag EndWindowCode

#tag Events EditorView
	#tag Event
		Sub Opening()
		  // Debug builds only — don't expose the inspector/DOM in release.
		  #If DebugBuild Then
		    Me.developerExtrasEnabled = True
		  #EndIf
		End Sub
	#tag EndEvent
	#tag Event
		Sub didReceiveScriptMessage(Body As Variant, name As String)
		  Select Case name
		  Case "editorReady"
		    PushNoteToJS

		  Case "saveNote"
		    Try
		      Var j As New JSONItem(Body.StringValue)
		      mNote.Title = j.Lookup("title", "").StringValue
		      mNote.Body = j.Lookup("body", "").StringValue
		      mNote.Tags = j.Lookup("tags", "").StringValue
		      ApplyScope(j.Lookup("scope", mNote.Scope).StringValue)
		      Call SaveCurrent
		    Catch e As RuntimeException
		      App.AppendDebugLog("NoteEditorWindow saveNote: " + e.Message + EndOfLine)
		    End Try

		  Case "deleteNote"
		    // Native confirmation — JS confirm() never shows in WKWebView.
		    Var d As New MessageDialog
		    d.Message = "Delete " + If(mNote.Title <> "", """" + mNote.Title + """", "this note") + "?"
		    d.Explanation = "This cannot be undone."
		    d.ActionButton.Caption = "Delete"
		    d.CancelButton.Visible = True
		    If d.ShowModal(Self) = d.ActionButton Then
		      If mExists Then Call DBHelper.DeleteNote(mNote.Id)
		      mDirty = False
		      RefreshSidebar
		      Close
		    End If

		  Case "setDirty"
		    Try
		      Var j As New JSONItem(Body.StringValue)
		      mDirty = j.Lookup("dirty", False).BooleanValue
		      // Cache the fields so save-on-close persists what the user sees.
		      mNote.Title = j.Lookup("title", mNote.Title).StringValue
		      mNote.Body = j.Lookup("body", mNote.Body).StringValue
		      mNote.Tags = j.Lookup("tags", mNote.Tags).StringValue
		      ApplyScope(j.Lookup("scope", mNote.Scope).StringValue)
		    Catch e As RuntimeException
		      App.AppendDebugLog("NoteEditorWindow setDirty: " + e.Message + EndOfLine)
		    End Try

		  Case "markAsReviewed"
		    DBHelper.MarkNoteReviewed(mNote.Id)
		    mNote.VersionWarned = False
		    mNote.DocsVersion = DBHelper.GetActiveVersion
		    RefreshSidebar

		  Case "dismissStaleness"
		    // Banner hidden JS-side only; flag stays until reviewed or re-marked.

		  Case "closeEditor"
		    Close

		  End Select
		End Sub
	#tag EndEvent
#tag EndEvents
