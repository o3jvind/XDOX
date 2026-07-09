#tag Class
Protected Class App
Inherits DesktopApplication
	#tag Event
		Sub Closing()
		  ModelManager.CancelAllDownloads
		  ModelManager.StopAllServers
		End Sub
	#tag EndEvent

	#tag Event
		Sub Opening()
		  Var mbsReg() As String = Secrets.GetMBSRegistration()
		  If mbsReg(3) <> "" Then
		    If Not RegisterMBSPlugin(mbsReg(0).Trim, mbsReg(1).Trim, Integer.FromString(mbsReg(2).Trim), mbsReg(3).Trim) Then
		      System.DebugLog("MBS registration failed — check Owner/Product/Year/Key in keychain")
		    End If
		  Else
		    System.DebugLog("MBS serial not found — add to keychain: security add-generic-password -s MBS -a Key -w YOUR_KEY")
		  End If
		  
		  DBHelper.InitDB
		  
		  CheckDocs
		End Sub
	#tag EndEvent

	#tag Event
		Function UnhandledException(error As RuntimeException) As Boolean
		  Var msg As String = "Error: " + error.Message + EndOfLine
		  msg = msg + "Error Number: " + Str(error.ErrorNumber) + EndOfLine
		  If error.Stack <> Nil Then
		    msg = msg + "Stack:" + EndOfLine
		    For Each frame As String In error.Stack
		      msg = msg + "  " + frame + EndOfLine
		    Next
		  End If
		  AppendDebugLog(msg)
		End Function
	#tag EndEvent


	#tag Method, Flags = &h0
		Shared Sub AppendDebugLog(message As String)
		  Try
		    Var f As FolderItem = Paths.DebugLog
		    If f = Nil Then Return
		    Var stream As TextOutputStream
		    If f.Exists Then
		      stream = TextOutputStream.Append(f)
		    Else
		      stream = TextOutputStream.Create(f)
		    End If
		    If stream <> Nil Then
		      Var now As New Date
		      stream.Write("[" + now.SQLDateTime + "] " + message)
		      stream.Close
		    End If
		  Catch e As RuntimeException
		    // Intentionally silent: this IS the debug logger, so logging a failure
		    // here would recurse. A lost log line is preferable to a stack overflow.
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub CheckDocs()
		  If Not DocDetector.DocsInstalled Then
		    Var win As New DocsNotInstalledWindow
		    win.ShowModal
		    Return
		  End If

		  // First run / empty DB: index the latest installed version.
		  If DBHelper.IndexedVersions.Count = 0 Or DBHelper.ChunkCount = 0 Then
		    StartIndexing(False)
		    Return
		  End If

		  // Housekeeping: offer to remove versions no longer installed (dismissable,
		  // can be turned off). Done before the add-version banner so the two
		  // prompts don't stack.
		  OfferOrphanCleanup

		  // Additive multi-version: if a newer installed version isn't indexed yet,
		  // offer to add it (existing versions are kept). The banner button calls
		  // StartIndexing with that version.
		  Var unindexed() As String = DocDetector.UnindexedInstalledVersions
		  If unindexed.Count > 0 Then
		    // unindexed is newest-first (from InstalledVersions ordering).
		    DBHelper.SetMetadata("pending_reindex", "1")
		    DBHelper.SetMetadata("pending_version", unindexed(0))
		    Window1.ShowVersionBanner(unindexed(0))
		  ElseIf DBHelper.GetMetadata("pending_reindex") = "1" Then
		    Var pending As String = DBHelper.GetMetadata("pending_version")
		    If pending = "" Then pending = DocDetector.FindLatestDocsVersion
		    Window1.ShowVersionBanner(pending)
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OfferOrphanCleanup()
		  // Prompt to delete indexed versions whose Xojo docs folder is gone.
		  // Skipped entirely if the user chose "don't ask again".
		  If DBHelper.GetMetadata("skip_orphan_cleanup") = "1" Then Return
		  Var orphans() As String = DocDetector.OrphanedIndexedVersions
		  If orphans.Count = 0 Then Return

		  Var list As String = String.FromArray(orphans, ", ")
		  Var d As New MessageDialog
		  d.Message = "Remove documentation for uninstalled Xojo version(s)?"
		  d.Explanation = list + " no longer installed. Their indexed docs can be removed to free space. Notes are not affected."
		  d.ActionButton.Caption = "Remove"
		  d.CancelButton.Visible = True
		  d.CancelButton.Caption = "Keep"
		  d.AlternateActionButton.Visible = True
		  d.AlternateActionButton.Caption = "Don't ask again"
		  Var choice As MessageDialogButton = d.ShowModal
		  If choice = d.ActionButton Then
		    For Each v As String In orphans
		      DBHelper.DeleteVersion(v)
		    Next
		    // If the active version was just removed, fall back to newest remaining.
		    Var active As String = DBHelper.GetActiveVersion
		    Var stillPresent As Boolean = False
		    For Each iv As String In DBHelper.IndexedVersions
		      If iv = active Then stillPresent = True
		    Next
		    If Not stillPresent Then
		      Var remaining() As String = DBHelper.IndexedVersions
		      If remaining.Count > 0 Then DBHelper.SetActiveVersion(remaining(0)) Else DBHelper.SetActiveVersion("")
		    End If
		    Retrieval.ClearCache
		  ElseIf choice = d.AlternateActionButton Then
		    DBHelper.SetMetadata("skip_orphan_cleanup", "1")
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function FindFile(name As String) As FolderItem
		  Var parts() As String = name.Split("/")
		  Dim roots(3) As FolderItem
		  roots(0) = App.ExecutableFile.Parent
		  roots(1) = App.ExecutableFile.Parent.Parent.Child("Resources")
		  roots(2) = App.ExecutableFile.Parent.Parent.Parent.Parent.Child("src")
		  roots(3) = App.ExecutableFile.Parent.Parent.Parent.Parent.Parent.Child("src")
		  For i As Integer = 0 To 3
		    Var f As FolderItem = roots(i)
		    If f = Nil Then Continue
		    For Each part As String In parts
		      f = f.Child(part)
		      If f = Nil Then Exit
		    Next
		    If f <> Nil And f.Exists Then Return f
		  Next
		  App.AppendDebugLog("FindFile: not found: " + name + EndOfLine)
		  Return Nil
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Shared Function GetDB() As SQLiteDatabase
		  Return mDB
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Shared Sub SetDB(db As SQLiteDatabase)
		  mDB = db
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StartIndexing(isReindex As Boolean, targetVersion As String = "")
		  // targetVersion selects which installed Xojo version to index; empty means
		  // the latest (single-version / first-run behaviour).
		  Var docsFile As FolderItem
		  If targetVersion <> "" Then
		    docsFile = DocDetector.FindLlmsFullTxtFor(targetVersion)
		  Else
		    docsFile = DocDetector.FindLlmsFullTxt
		  End If
		  If docsFile = Nil Then Return
		  Var win As New IndexProgressWindow
		  win.Show
		  Var adapter As New IndexerProgressAdapter
		  adapter.Win = win
		  Indexer.StartIndex(docsFile, adapter, isReindex, targetVersion)
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h21
		Private Shared mDB As SQLiteDatabase
	#tag EndProperty


	#tag Constant, Name = kEditClear, Type = String, Dynamic = False, Default = \"Delete", Scope = Public
		#Tag Instance, Platform = Windows, Language = Default, Definition  = \"Delete"
		#Tag Instance, Platform = Linux, Language = Default, Definition  = \"Delete"
	#tag EndConstant

	#tag Constant, Name = kFileQuit, Type = String, Dynamic = False, Default = \"Quit", Scope = Public
		#Tag Instance, Platform = Windows, Language = Default, Definition  = \"&xit"
	#tag EndConstant

	#tag Constant, Name = kFileQuitShortcut, Type = String, Dynamic = False, Default = \"", Scope = Public
		#Tag Instance, Platform = Mac OS, Language = Default, Definition  = \"md+Q"
		#Tag Instance, Platform = Linux, Language = Default, Definition  = \"trl+Q"
	#tag EndConstant


	#tag ViewBehavior
		#tag ViewProperty
			Name="Name"
			Visible=false
			Group="ID"
			InitialValue=""
			Type="String"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="Index"
			Visible=false
			Group="ID"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="Super"
			Visible=false
			Group="ID"
			InitialValue=""
			Type="String"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="Left"
			Visible=false
			Group="Position"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="Top"
			Visible=false
			Group="Position"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="AllowAutoQuit"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="Boolean"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="AllowHiDPI"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="Boolean"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="BugVersion"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="Copyright"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="String"
			EditorType="MultiLineEditor"
		#tag EndViewProperty
		#tag ViewProperty
			Name="Description"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="String"
			EditorType="MultiLineEditor"
		#tag EndViewProperty
		#tag ViewProperty
			Name="LastWindowIndex"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="MajorVersion"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="MinorVersion"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="NonReleaseVersion"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="RegionCode"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="StageCode"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="Version"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="string"
			EditorType="MultiLineEditor"
		#tag EndViewProperty
		#tag ViewProperty
			Name="_CurrentEventTime"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
		#tag ViewProperty
			Name="ProcessID"
			Visible=false
			Group="Behavior"
			InitialValue=""
			Type="Integer"
			EditorType=""
		#tag EndViewProperty
	#tag EndViewBehavior
End Class
#tag EndClass
