#tag Class
Class ChatView
Inherits DesktopWKWebViewControlMBS
Implements XDOXSessionDelegate
	#tag Method, Flags = &h0
		Sub LoadUI()
		  // App.FindFile resolves relative to project in debug, Resources/ in release.
		  Try
		    Var html As String = ReadAsset("web-assets/index.html")
		    If html = "" Then
		      App.AppendDebugLog("ChatView.LoadUI: index.html not found" + EndOfLine)
		      Return
		    End If

		    Var css As String
		    css = css + ReadAsset("web-assets/css/variables.css")
		    css = css + ReadAsset("web-assets/css/chat.css")
		    css = css + ReadAsset("web-assets/css/layout.css")
		    css = css + ReadAsset("web-assets/css/sidebar.css")
		    html = html.ReplaceAll("<!-- CSS_PLACEHOLDER -->", "<style>" + css + "</style>")

		    Var js As String
		    js = js + ReadAsset("web-assets/js/vendor/marked.min.js") + EndOfLine
		    js = js + ReadAsset("web-assets/js/sanitize.js") + EndOfLine
		    js = js + ReadAsset("web-assets/js/chat-handler.js") + EndOfLine
		    js = js + ReadAsset("web-assets/js/notes-manager.js") + EndOfLine
		    js = js + ReadAsset("web-assets/js/main.js") + EndOfLine
		    html = html.ReplaceAll("<!-- JS_PLACEHOLDER -->", "<script>" + js + "</script>")

		    Me.AddScriptMessageHandler("sendMessage")
		    Me.AddScriptMessageHandler("stopGeneration")
		    Me.AddScriptMessageHandler("clearChat")
		    Me.AddScriptMessageHandler("saveAsNote")
		    Me.AddScriptMessageHandler("setTheme")
		    Me.AddScriptMessageHandler("pageReady")
		    Me.AddScriptMessageHandler("openURL")
		    Me.AddScriptMessageHandler("getModels")
		    Me.AddScriptMessageHandler("downloadModel")
		    Me.AddScriptMessageHandler("cancelDownload")
		    Me.AddScriptMessageHandler("selectModel")
		    Me.AddScriptMessageHandler("newNote")
		    Me.AddScriptMessageHandler("openNote")
		    Me.AddScriptMessageHandler("deleteNote")
		    Me.AddScriptMessageHandler("selectDocsVersion")
		    Me.AddScriptMessageHandler("setNotesSearchScope")

		    Me.LoadHTML(html, "https://xdox.local/")
		  Catch e As RuntimeException
		    App.AppendDebugLog("ChatView.LoadUI error: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Event
		Sub didReceiveScriptMessage(Body As Variant, name As String)
		  Select Case name
		  Case "sendMessage"
		    Var text As String = Body.StringValue
		    If text = "" Then Return
		    If mSession = Nil Then
		      mSession = New XDOXSession(Self)
		    End If
		    mSession.SendMessage(text)

		  Case "stopGeneration"
		    If mSession <> Nil Then mSession.StopGeneration

		  Case "clearChat"
		    If mSession <> Nil Then mSession.Reset

		  Case "saveAsNote"
		    // body is JSON: { "title": "...", "body": "..." }
		    Try
		      Var j As New JSONItem(Body.StringValue)
		      NoteEditorWindow.OpenFromConversation(j.Lookup("title", "").StringValue, j.Lookup("body", "").StringValue)
		    Catch e As RuntimeException
		      App.AppendDebugLog("ChatView saveAsNote: " + e.Message + EndOfLine)
		    End Try

		  Case "newNote"
		    NoteEditorWindow.OpenNew

		  Case "openNote"
		    NoteEditorWindow.OpenExisting(Body.StringValue)

		  Case "deleteNote"
		    // Native confirmation — JS confirm() never shows in WKWebView.
		    Var noteId As String = Body.StringValue
		    Var title As String = "this note"
		    Var rec As NoteRecord = DBHelper.GetNote(noteId)
		    If rec <> Nil And rec.Title <> "" Then title = """" + rec.Title + """"
		    Var d As New MessageDialog
		    d.Message = "Delete " + title + "?"
		    d.Explanation = "This cannot be undone."
		    d.ActionButton.Caption = "Delete"
		    d.CancelButton.Visible = True
		    If d.ShowModal = d.ActionButton Then
		      Call DBHelper.DeleteNote(noteId)
		      RefreshSidebar
		    End If

		  Case "openURL"
		    // ShowURL hands the URL to the OS handler directly — no shell, so
		    // metacharacters (&, ?, spaces) in legit URLs can't break or inject.
		    // The scheme whitelist stays as a defence-in-depth guard.
		    Var url As String = Body.StringValue
		    If url.Left(8) = "https://" Or url.Left(7) = "http://" Then
		      Try
		        ShowURL(url)
		      Catch e As RuntimeException
		        App.AppendDebugLog("ChatView.openURL: " + e.Message + EndOfLine)
		      End Try
		    End If

		  Case "setTheme"
		    // No-op from Xojo side — theme is stored only in the WebView.

		  Case "pageReady"
		    // Page is live — safe to start the backend and talk to JS.
		    ModelManager.AutoStart
		    RefreshSidebar
		    RefreshVersions

		  Case "getModels"
		    // 4th arg: does the picker need the one-time embedding-download notice?
		    EvaluateJavaScript("receiveCatalog(" + ModelManager.CatalogJSON + "," + ModelManager.InstalledModelsJSON + "," + JSONEscape(ModelManager.SelectedModelId) + "," + If(ModelManager.EmbeddingModelInstalled, "false", "true") + ");")

		  Case "downloadModel"
		    ModelManager.DownloadModel(Body.StringValue)

		  Case "cancelDownload"
		    ModelManager.CancelDownload(Body.StringValue)

		  Case "selectModel"
		    ModelManager.SwitchModel(Body.StringValue)

		  Case "selectDocsVersion"
		    Var v As String = Body.StringValue
		    If v <> "" Then
		      DBHelper.SetActiveVersion(v)
		      Retrieval.ClearCache
		      RefreshVersions
		    End If

		  Case "setNotesSearchScope"
		    Var scope As String = Body.StringValue
		    If scope <> "all" And scope <> "version" Then scope = "all"
		    DBHelper.SetMetadata("notes_search_scope", scope)

		  End Select
		End Sub
	#tag EndEvent

	#tag Method, Flags = &h21
		Private Function ReadAsset(relativePath As String) As String
		  Var f As FolderItem = App.FindFile(relativePath)
		  If f = Nil Or Not f.Exists Then
		    App.AppendDebugLog("ChatView.ReadAsset: not found: " + relativePath + EndOfLine)
		    Return ""
		  End If
		  Var ts As TextInputStream = TextInputStream.Open(f)
		  ts.Encoding = Encodings.UTF8
		  Var result As String = ts.ReadAll
		  ts.Close
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub OnDone()
		  EvaluateJavaScript("finalizeMessage()")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub OnError(message As String)
		  EvaluateJavaScript("showError(" + JSONEscape(message) + ")")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub OnToken(TheString As String)
		  EvaluateJavaScript("appendToken(" + JSONEscape(TheString) + ")")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub RefreshSidebar()
		  // Push all notes to the sidebar list. Body is trimmed to a 120-char
		  // preview — the editor loads the full note via GetNote when opened.
		  Try
		    // "[]" forces array serialisation — a bare JSONItem with no children
		    // serialises as {} and breaks Array.prototype calls on the JS side.
		    Var arr As New JSONItem("[]")
		    For Each n As NoteRecord In DBHelper.GetAllNotes
		      Var j As New JSONItem
		      j.Value("id") = n.Id
		      j.Value("title") = n.Title
		      Var preview As String = n.Body.ReplaceAll(Chr(10), " ").Trim
		      If preview.Length > 120 Then preview = preview.Left(120) + "…"
		      j.Value("preview") = preview
		      Var tags As New JSONItem("[]")
		      For Each t As String In n.TagList
		        tags.Add(t)
		      Next
		      j.Value("tags") = tags
		      j.Value("version_warned") = n.VersionWarned
		      j.Value("docs_version") = n.DocsVersion
		      j.Value("updated") = n.Updated
		      arr.Add(j)
		    Next
		    EvaluateJavaScript("loadNotes(" + arr.ToString + ");")
		  Catch e As RuntimeException
		    App.AppendDebugLog("ChatView.RefreshSidebar: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub UpdateIndexStatus(TheMessage As String)
		  EvaluateJavaScript("updateIndexStatus(" + JSONEscape(TheMessage) + ")")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub RefreshVersions()
		  // Push the indexed-version list + active version to the JS dropdown. Also
		  // syncs the notes-search-scope toggle. Call at startup and after any
		  // (re)index or version cleanup.
		  Try
		    Var arr As New JSONItem("[]")
		    For Each v As String In DBHelper.IndexedVersions
		      arr.Add(v)
		    Next
		    EvaluateJavaScript("receiveVersions(" + arr.ToString + "," + JSONEscape(DBHelper.GetActiveVersion) + ");")

		    Var scope As String = DBHelper.GetMetadata("notes_search_scope")
		    If scope = "" Then scope = "all"
		    EvaluateJavaScript("receiveNotesSearchScope(" + JSONEscape(scope) + ");")
		  Catch e As RuntimeException
		    App.AppendDebugLog("ChatView.RefreshVersions: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub ClearIndexStatus()
		  EvaluateJavaScript("clearIndexStatus()")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function JSONEscape(s As String) As String
		  // Wrap s as a JSON string literal safe for EvaluateJavaScript.
		  s = s.ReplaceAll("\", "\\")
		  s = s.ReplaceAll("""", "\""")
		  s = s.ReplaceAll("/", "\/")
		  s = s.ReplaceAll(Chr(8), "\b")
		  s = s.ReplaceAll(Chr(9), "\t")
		  s = s.ReplaceAll(Chr(10), "\n")
		  s = s.ReplaceAll(Chr(12), "\f")
		  s = s.ReplaceAll(Chr(13), "\r")
		  Return """" + s + """"
		End Function
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mSession As XDOXSession
	#tag EndProperty


	#tag ViewBehavior
		#tag ViewProperty
			Name="Name"
			Visible=true
			Group="ID"
			InitialValue=""
			Type="String"
			EditorType="String"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Index"
			Visible=true
			Group="ID"
			InitialValue=""
			Type="Integer"
			EditorType="Integer"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Super"
			Visible=true
			Group="ID"
			InitialValue=""
			Type="String"
			EditorType="String"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Left"
			Visible=true
			Group="Position"
			InitialValue=""
			Type="Integer"
			EditorType="Integer"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Top"
			Visible=true
			Group="Position"
			InitialValue=""
			Type="Integer"
			EditorType="Integer"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Width"
			Visible=true
			Group="Position"
			InitialValue="300"
			Type="Integer"
			EditorType="Integer"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Height"
			Visible=true
			Group="Position"
			InitialValue="300"
			Type="Integer"
			EditorType="Integer"
		#tag EndViewProperty
		#tag ViewProperty
			Name="LockLeft"
			Visible=true
			Group="Position"
			InitialValue=""
			Type="Boolean"
			EditorType="Boolean"
		#tag EndViewProperty
		#tag ViewProperty
			Name="LockTop"
			Visible=true
			Group="Position"
			InitialValue=""
			Type="Boolean"
			EditorType="Boolean"
		#tag EndViewProperty
		#tag ViewProperty
			Name="LockRight"
			Visible=true
			Group="Position"
			InitialValue=""
			Type="Boolean"
			EditorType="Boolean"
		#tag EndViewProperty
		#tag ViewProperty
			Name="LockBottom"
			Visible=true
			Group="Position"
			InitialValue=""
			Type="Boolean"
			EditorType="Boolean"
		#tag EndViewProperty
		#tag ViewProperty
			Name="TabPanelIndex"
			Visible=false
			Group="Position"
			InitialValue="0"
			Type="Integer"
			EditorType="Integer"
		#tag EndViewProperty
		#tag ViewProperty
			Name="TabIndex"
			Visible=true
			Group="Position"
			InitialValue="0"
			Type="Integer"
			EditorType="Integer"
		#tag EndViewProperty
		#tag ViewProperty
			Name="TabStop"
			Visible=true
			Group="Position"
			InitialValue="True"
			Type="Boolean"
			EditorType="Boolean"
		#tag EndViewProperty
		#tag ViewProperty
			Name="InitialParent"
			Visible=false
			Group="Position"
			InitialValue=""
			Type="String"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="Visible"
			Visible=true
			Group="Appearance"
			InitialValue="True"
			Type="Boolean"
			EditorType="Boolean"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Tooltip"
			Visible=true
			Group="Appearance"
			InitialValue=""
			Type="String"
			EditorType="MultiLineEditor"
		#tag EndViewProperty
		#tag ViewProperty
			Name="AutoDeactivate"
			Visible=true
			Group="Appearance"
			InitialValue="True"
			Type="Boolean"
			EditorType="Boolean"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Enabled"
			Visible=true
			Group="Appearance"
			InitialValue="True"
			Type="Boolean"
			EditorType="Boolean"
		#tag EndViewProperty
	#tag EndViewBehavior
End Class
#tag EndClass
