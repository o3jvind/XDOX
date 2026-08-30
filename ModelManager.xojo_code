#tag Module
Protected Module ModelManager
	#tag Method, Flags = &h0
		Sub AutoStart()
		  // Called from ChatView's pageReady handler — the WebView must be live
		  // before any receiveModelStatus()/receiveDownloadProgress() call can
		  // land.
		  //
		  // XDOX used to generate chat replies with a local LLM (qwen2.5-coder
		  // et al, port 8091) selected via a model picker. Removed 2026-08-30:
		  // XDOXSession stopped calling that model at all on 2026-08-29 (see
		  // its PrepareRequest comment) — replies render matched documentation
		  // text directly instead of generating one. Two narrower follow-up
		  // uses were deliberately explored and rejected before removal, not
		  // just assumed unnecessary: (1) query-rewriting for retrieval (e.g.
		  // folding a follow-up like "how about android?" into a standalone
		  // search query) — measured directly against the DB across 3 repros,
		  // mixed/no real improvement over plain history-concatenation, same
		  // conclusion as an earlier 2026-08-16 attempt; (2) asking ONE narrow
		  // clarifying question back to the user when retrieval is ambiguous
		  // or empty, explicitly told not to state any Xojo fact — worked
		  // cleanly for pure platform-choice questions, but a harder repro (a
		  // query touching a deprecated API) leaked an unrequested factual
		  // claim in 3 of 5 runs despite the explicit instruction not to. Even
		  // this narrow a generative task didn't reach reliable
		  // zero-fabrication at this model size, so the catalog, download
		  // pipeline, server lifecycle and picker UI were removed rather than
		  // left dormant.
		  CleanupPartFiles
		  EnsureEmbeddingModel
		  EnsureRerankModel
		  SendToJS("receiveModelStatus(" + If(EmbeddingModelInstalled, "false", "true") + "," + If(RerankModelInstalled, "false", "true") + ");")

		  StartEmbedServer
		  StartRerankServer
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function EmbedBaseURL() As String
		  // Port 8089 on purpose: XMCP hardcodes this address for its semantic
		  // search, so XDOX's embedding server serves both apps.
		  Return "http://127.0.0.1:" + kEmbedPort
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function RerankBaseURL() As String
		  // Port 8093 on purpose: XMCP hardcodes this address too, same reasoning
		  // as EmbedBaseURL — one reranker server serves both apps.
		  Return "http://127.0.0.1:" + kRerankPort
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function EmbedServerHealthy(timeoutSeconds As Integer = 2) As Boolean
		  // One synchronous /health probe. Callers own any retry/wait loop
		  // (IndexerThread loops with Me.Sleep between probes).
		  Try
		    Var conn As New URLConnection
		    // Connection refused is the expected outcome while the server warms
		    // up — don't drop into the debugger on every probe.
		    #Pragma BreakOnExceptions False
		    Call conn.SendSync("GET", EmbedBaseURL() + "/health", timeoutSeconds)
		    #Pragma BreakOnExceptions Default
		    Return conn.HTTPStatusCode = 200
		  Catch e As RuntimeException
		    Return False
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function RerankServerHealthy(timeoutSeconds As Integer = 2) As Boolean
		  // Mirrors EmbedServerHealthy — one synchronous /health probe.
		  Try
		    Var conn As New URLConnection
		    #Pragma BreakOnExceptions False
		    Call conn.SendSync("GET", RerankBaseURL() + "/health", timeoutSeconds)
		    #Pragma BreakOnExceptions Default
		    Return conn.HTTPStatusCode = 200
		  Catch e As RuntimeException
		    Return False
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsModelBusy(modelId As String) As Boolean
		  // True while modelId is downloading OR its .part is being hashed —
		  // covers both dictionaries so a second download can't start while
		  // VerifyThenInstall still has the file from the first one open.
		  If mDownloads <> Nil Then
		    For Each key As Variant In mDownloads.Keys
		      Var info As Dictionary = Dictionary(mDownloads.Value(URLConnection(key)))
		      If info.Lookup("modelId", "") = modelId Then Return True
		    Next
		  End If
		  If mVerifying <> Nil Then
		    For Each key As Variant In mVerifying.Keys
		      Var info As Dictionary = Dictionary(mVerifying.Value(Shell(key)))
		      If info.Lookup("modelId", "") = modelId Then Return True
		    Next
		  End If
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub EnsureEmbeddingModel()
		  // The embedding model is a fixed dependency (768-dim nomic), not a
		  // catalog choice — the DB schema and XMCP both assume it.
		  Var f As FolderItem = ModelsFolder().Child(Embedder.kEmbedModelFile)
		  If f <> Nil And f.Exists And f.Length > 0 Then Return

		  If mDownloads = Nil Then mDownloads = New Dictionary
		  If IsModelBusy("embedding") Then Return // already downloading or verifying

		  App.AppendDebugLog("ModelManager: downloading embedding model from HF" + EndOfLine)
		  Var url As String = kHFBase + "/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf"
		  Var dest As FolderItem = ModelsFolder().Child(Embedder.kEmbedModelFile + ".part")

		  Var conn As New URLConnection
		  AddHandler conn.FileReceived, AddressOf OnFileReceived
		  AddHandler conn.ReceivingProgressed, AddressOf OnReceivingProgressed
		  AddHandler conn.Error, AddressOf OnDownloadError

		  Var info As New Dictionary
		  info.Value("modelId") = "embedding"
		  info.Value("filename") = Embedder.kEmbedModelFile
		  info.Value("bytes") = CType(146146432, Int64)
		  info.Value("sha256") = "3e24342164b3d94991ba9692fdc0dd08e3fd7362e0aacc396a9a5c54a544c3b7"
		  info.Value("lastProgressTick") = System.Ticks
		  mDownloads.Value(conn) = info

		  conn.Send("GET", url, dest)
		  StartStallWatchdog
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub EnsureRerankModel()
		  // The reranker model is a fixed dependency (Qwen3-Reranker-4B), not a
		  // catalog choice — same "disclosed in the picker = informed consent"
		  // pattern as EnsureEmbeddingModel. Use Voodisss's conversion, NOT
		  // ggml-org's — the latter is a known-broken GGUF missing the
		  // cls.output.weight classifier tensor and returns near-zero, low-signal
		  // scores regardless of actual relevance.
		  //
		  // Upgraded from the 0.6B variant (Task 7, 2026-08-28): live testing
		  // found the 0.6B model, even with Reranker.kRerankInstruction's
		  // Instruct/Query prompt format, unreliably separated a real answer
		  // from an unrelated IDE-tutorial chunk with superficial keyword
		  // overlap (both scored >0.9). The 4B model with the same prompt
		  // format showed a much clearer separation (0.92 true positive vs
		  // 0.52 false positive on the same repro) — see Reranker.xojo_code's
		  // kNoMatchThreshold comment for the measurement and its caveats.
		  // 4B is ~4.3GB (Q8_0) vs 0.6B's ~640MB — a real download-size and
		  // disk-space cost, but the reranker is a small, optional
		  // improvement layer (see MatchStatus), not required for basic chat.
		  Var f As FolderItem = ModelsFolder().Child(Reranker.kRerankModelFile)
		  If f <> Nil And f.Exists And f.Length > 0 Then Return

		  If mDownloads = Nil Then mDownloads = New Dictionary
		  If IsModelBusy("reranker") Then Return // already downloading or verifying

		  App.AppendDebugLog("ModelManager: downloading reranker model from HF" + EndOfLine)
		  Var url As String = kHFBase + "/Voodisss/Qwen3-Reranker-4B-GGUF-llama_cpp/resolve/main/Qwen3-Reranker-4B.Q8_0.gguf"
		  Var dest As FolderItem = ModelsFolder().Child(Reranker.kRerankModelFile + ".part")

		  Var conn As New URLConnection
		  AddHandler conn.FileReceived, AddressOf OnFileReceived
		  AddHandler conn.ReceivingProgressed, AddressOf OnReceivingProgressed
		  AddHandler conn.Error, AddressOf OnDownloadError

		  Var info As New Dictionary
		  info.Value("modelId") = "reranker"
		  info.Value("filename") = Reranker.kRerankModelFile
		  info.Value("bytes") = CType(4279678912, Int64)
		  info.Value("sha256") = "102ac400d68f02877c2fdfecf0732872652298448352b6faf28ec7f8dca8c913"
		  info.Value("lastProgressTick") = System.Ticks
		  mDownloads.Value(conn) = info

		  conn.Send("GET", url, dest)
		  StartStallWatchdog
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub CancelDownload(modelId As String)
		  If mDownloads <> Nil Then
		    For Each key As Variant In mDownloads.Keys
		      Var conn As URLConnection = URLConnection(key)
		      Var info As Dictionary = Dictionary(mDownloads.Value(conn))
		      If info.Lookup("modelId", "") = modelId Then
		        // Remove before Disconnect: Disconnect can trigger Error
		        // (possibly synchronously), and OnDownloadError no-ops once the
		        // key is gone rather than reporting a spurious failure and
		        // double-sending receiveDownloadDone.
		        mDownloads.Remove(conn)
		        conn.Disconnect()
		        Var filename As String = info.Lookup("filename", "")
		        Var part As FolderItem = ModelsFolder().Child(filename + ".part")
		        If part <> Nil And part.Exists Then part.Delete
		        SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false,""cancelled"");")
		        Return
		      End If
		    Next
		  End If

		  // The download itself may already be complete and the file handed off
		  // to the shasum verification pass (mVerifying) — the Cancel button in
		  // the UI has no way to know which phase it's in, so check both.
		  If mVerifying <> Nil Then
		    For Each key As Variant In mVerifying.Keys
		      Var sh As Shell = Shell(key)
		      Var info As Dictionary = Dictionary(mVerifying.Value(sh))
		      If info.Lookup("modelId", "") = modelId Then
		        // Remove before Close: Close triggers Completed (possibly
		        // synchronously), and OnHashCompleted no-ops once the key is
		        // gone rather than reporting a spurious "verify failed".
		        mVerifying.Remove(sh)
		        If sh.IsRunning Then sh.Close
		        Var file As FolderItem = FolderItem(info.Lookup("file", Nil))
		        If file <> Nil And file.Exists Then file.Delete
		        SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false,""cancelled"");")
		        Return
		      End If
		    Next
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub CancelAllDownloads()
		  // Called from App.Closing so a quit during a download doesn't leave a
		  // half-written .part file (or an orphaned URLConnection) behind.
		  // Swap in a fresh dictionary before disconnecting any connection:
		  // Disconnect can trigger Error (possibly synchronously), and
		  // OnDownloadError's own Remove(sender) must land on the old,
		  // already-abandoned dictionary, not the one this loop is iterating.
		  If mDownloads <> Nil Then
		    Var pendingDownloads As Dictionary = mDownloads
		    mDownloads = New Dictionary
		    For Each key As Variant In pendingDownloads.Keys
		      Var conn As URLConnection = URLConnection(key)
		      Var info As Dictionary = Dictionary(pendingDownloads.Value(conn))
		      conn.Disconnect()
		      Var filename As String = info.Lookup("filename", "")
		      Var part As FolderItem = ModelsFolder().Child(filename + ".part")
		      If part <> Nil And part.Exists Then part.Delete
		    Next
		  End If

		  // A shasum verification (post-download, pre-install) may still be
		  // running too — the file at this point is still named ".part". Swap
		  // in a fresh dictionary before closing any Shell: Close triggers
		  // Completed (possibly synchronously), and OnHashCompleted's own
		  // Remove(sender) must land on the old, already-abandoned dictionary,
		  // not the one this loop is still iterating.
		  If mVerifying <> Nil Then
		    Var pending As Dictionary = mVerifying
		    mVerifying = New Dictionary
		    For Each key As Variant In pending.Keys
		      Var sh As Shell = Shell(key)
		      Var info As Dictionary = Dictionary(pending.Value(sh))
		      If sh.IsRunning Then sh.Close
		      Var file As FolderItem = FolderItem(info.Lookup("file", Nil))
		      If file <> Nil And file.Exists Then file.Delete
		    Next
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub CleanupPartFiles()
		  // A .part file only survives to the next launch if the app quit or
		  // crashed mid-download (a crash bypasses CancelAllDownloads too — see
		  // App.Closing). Stale partial downloads have no resume support, so
		  // clear them out rather than let them sit on disk forever.
		  Var folder As FolderItem = ModelsFolder()
		  For i As Integer = folder.Count DownTo 1
		    Var f As FolderItem = folder.Item(i)
		    If f <> Nil And Not f.IsFolder And f.Name.EndsWith(".part") Then
		      App.AppendDebugLog("ModelManager: removing stale partial download " + f.Name + EndOfLine)
		      f.Delete
		    End If
		  Next
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function EmbeddingModelInstalled() As Boolean
		  Var f As FolderItem = ModelsFolder().Child(Embedder.kEmbedModelFile)
		  Return f <> Nil And f.Exists And f.Length > 0
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function RerankModelInstalled() As Boolean
		  Var f As FolderItem = ModelsFolder().Child(Reranker.kRerankModelFile)
		  Return f <> Nil And f.Exists And f.Length > 0
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function FileNameFromPath(p As String) As String
		  Var parts() As String = p.Split("/")
		  If parts.LastIndex < 0 Then Return p
		  Return parts(parts.LastIndex)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function JSEscape(s As String) As String
		  s = s.ReplaceAll("\", "\\")
		  s = s.ReplaceAll("""", "\""")
		  s = s.ReplaceAll("/", "\/")
		  s = s.ReplaceAll(Chr(10), "\n")
		  s = s.ReplaceAll(Chr(13), "\r")
		  s = s.ReplaceAll(Chr(9), "\t")
		  Return """" + s + """"
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function ModelsFolder() As FolderItem
		  Var models As FolderItem = Paths.AppSupport.Child("models")
		  If Not models.Exists Then models.CreateFolder
		  Return models
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnDownloadError(sender As URLConnection, err As RuntimeException)
		  If mDownloads = Nil Or Not mDownloads.HasKey(sender) Then Return
		  Var info As Dictionary = Dictionary(mDownloads.Value(sender))
		  mDownloads.Remove(sender)
		  Var modelId As String = info.Lookup("modelId", "")
		  App.AppendDebugLog("ModelManager download error: " + err.Message + EndOfLine)
		  SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false," + JSEscape(err.Message) + ");")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnFileReceived(sender As URLConnection, url As String, httpStatus As Integer, file As FolderItem)
		  #Pragma Unused url
		  If mDownloads = Nil Or Not mDownloads.HasKey(sender) Then Return
		  Var info As Dictionary = Dictionary(mDownloads.Value(sender))
		  mDownloads.Remove(sender)
		  Var modelId As String = info.Lookup("modelId", "")
		  Var filename As String = info.Lookup("filename", "")
		  Var expectedBytes As Int64 = info.Lookup("bytes", 0).Int64Value
		  Var expectedSHA As String = info.Lookup("sha256", "").StringValue.Lowercase

		  If httpStatus <> 200 Then
		    If file <> Nil And file.Exists Then file.Delete
		    SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false,""HTTP " + httpStatus.ToString + """);")
		    Return
		  End If

		  // A partial download must never count as an installed model.
		  If expectedBytes > 0 And file <> Nil And file.Length <> expectedBytes Then
		    Var got As Int64 = file.Length
		    If file.Exists Then file.Delete
		    SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false,""incomplete download (" + got.ToString + " of " + expectedBytes.ToString + " bytes)"");")
		    Return
		  End If

		  If expectedSHA = "" Then
		    // No pinned hash for this entry — install as before.
		    InstallVerifiedFile(modelId, filename, file)
		    Return
		  End If

		  VerifyThenInstall(modelId, filename, file, expectedSHA)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub VerifyThenInstall(modelId As String, filename As String, file As FolderItem, expectedSHA As String)
		  // GGUF files run up to ~17 GB — too large to hash via Xojo's
		  // Crypto.SHA2_256 (whole-file-in-one-MemoryBlock). Shell out to the
		  // OS shasum binary instead, same pattern as launching llama-server:
		  // an external process, watched asynchronously, never blocking the
		  // UI thread while it streams the file.
		  Var sh As New Shell
		  sh.ExecuteMode = Shell.ExecuteModes.Asynchronous
		  AddHandler sh.Completed, AddressOf OnHashCompleted

		  Var info As New Dictionary
		  info.Value("modelId") = modelId
		  info.Value("filename") = filename
		  info.Value("file") = file
		  info.Value("expectedSHA") = expectedSHA
		  If mVerifying = Nil Then mVerifying = New Dictionary
		  mVerifying.Value(sh) = info

		  App.AppendDebugLog("ModelManager: verifying SHA-256 of " + filename + EndOfLine)
		  sh.Execute("/usr/bin/shasum", "-a 256 " + EscapeShellArg(file.NativePath))
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function EscapeShellArg(s As String) As String
		  Return "'" + s.ReplaceAll("'", "'\''") + "'"
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnHashCompleted(sender As Shell)
		  If mVerifying = Nil Or Not mVerifying.HasKey(sender) Then Return
		  Var info As Dictionary = Dictionary(mVerifying.Value(sender))
		  mVerifying.Remove(sender)

		  Var modelId As String = info.Lookup("modelId", "")
		  Var filename As String = info.Lookup("filename", "")
		  Var file As FolderItem = FolderItem(info.Lookup("file", Nil))
		  Var expectedSHA As String = info.Lookup("expectedSHA", "")

		  // shasum prints "<64 hex chars>  <path>" on success.
		  Var output As String = sender.Result.Trim
		  Var actualSHA As String = ""
		  If output.Length >= 64 Then actualSHA = output.Left(64).Lowercase

		  If sender.ExitCode <> 0 Or actualSHA.Length <> 64 Then
		    App.AppendDebugLog("ModelManager: shasum failed for " + filename + " (exit " + sender.ExitCode.ToString + "): " + output.Left(200) + EndOfLine)
		    If file <> Nil And file.Exists Then file.Delete
		    SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false,""could not verify download integrity"");")
		    Return
		  End If

		  If actualSHA <> expectedSHA Then
		    App.AppendDebugLog("ModelManager: SHA-256 mismatch for " + filename + " — expected " + expectedSHA + ", got " + actualSHA + EndOfLine)
		    If file <> Nil And file.Exists Then file.Delete
		    SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false,""downloaded file failed integrity check — please retry"");")
		    Return
		  End If

		  InstallVerifiedFile(modelId, filename, file)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub InstallVerifiedFile(modelId As String, filename As String, file As FolderItem)
		  // Rename .part -> final filename, via backup so a failed move never
		  // leaves an already-installed model deleted or half-replaced.
		  Var final As FolderItem = ModelsFolder().Child(filename)
		  Var backup As FolderItem = ModelsFolder().Child(filename + ".xdox_bak")
		  If backup.Exists Then backup.Delete

		  Try
		    If final.Exists Then
		      final.MoveFileTo(backup)
		      If Not backup.Exists Or final.Exists Then
		        SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false,""could not stage existing model for replacement"");")
		        Return
		      End If
		    End If

		    file.MoveFileTo(final)
		    If Not final.Exists Or file.Exists Then
		      If backup.Exists Then backup.MoveFileTo(final)
		      SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false,""could not install downloaded model"");")
		      Return
		    End If

		    If backup.Exists Then backup.Delete
		    SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",true,"""");")
		    If modelId = "embedding" Then StartEmbedServer
		    If modelId = "reranker" Then StartRerankServer

		  Catch e As RuntimeException
		    App.AppendDebugLog("ModelManager.InstallVerifiedFile: move exception: " + e.Message + EndOfLine)
		    If Not final.Exists And backup.Exists Then
		      Try
		        backup.MoveFileTo(final)
		      Catch e2 As RuntimeException
		        App.AppendDebugLog("ModelManager.InstallVerifiedFile: restore failed, previous model at " + backup.NativePath + EndOfLine)
		      End Try
		    End If
		    SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false," + JSEscape(e.Message) + ");")
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnReceivingProgressed(sender As URLConnection, bytesReceived As Int64, totalBytes As Int64, newData As String)
		  #Pragma Unused newData
		  If mDownloads = Nil Or Not mDownloads.HasKey(sender) Then Return
		  Var info As Dictionary = Dictionary(mDownloads.Value(sender))
		  info.Value("lastProgressTick") = System.Ticks
		  Var now As Double = System.Ticks
		  If (now - mLastProgressTick) < 60 Then Return
		  mLastProgressTick = now
		  Var modelId As String = info.Lookup("modelId", "")
		  Var expected As Int64 = info.Lookup("bytes", 0).Int64Value
		  Var total As Int64 = If(totalBytes > 0, totalBytes, expected)
		  Var pct As Double = If(total > 0, bytesReceived / total * 100.0, 0)
		  SendToJS("receiveDownloadProgress(" + JSEscape(modelId) + "," + Format(pct, "0.0") + ");")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub StartStallWatchdog()
		  If mStallTimer = Nil Then
		    mStallTimer = New Timer
		    mStallTimer.Period = 10000
		    AddHandler mStallTimer.Action, AddressOf OnStallTimer
		  End If
		  mStallTimer.RunMode = Timer.RunModes.Multiple
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnStallTimer(sender As Timer)
		  If mDownloads = Nil Or mDownloads.Count = 0 Then
		    sender.RunMode = Timer.RunModes.Off
		    Return
		  End If

		  Var now As Double = System.Ticks
		  Var stalled() As URLConnection
		  For Each key As Variant In mDownloads.Keys
		    Var conn As URLConnection = URLConnection(key)
		    Var info As Dictionary = Dictionary(mDownloads.Value(conn))
		    Var lastTick As Double = info.Lookup("lastProgressTick", 0.0)
		    If (now - lastTick) / 60 > kDownloadStallSeconds Then
		      stalled.Add(conn)
		    End If
		  Next

		  For Each conn As URLConnection In stalled
		    Var info As Dictionary = Dictionary(mDownloads.Value(conn))
		    Var modelId As String = info.Lookup("modelId", "")
		    Var filename As String = info.Lookup("filename", "")
		    App.AppendDebugLog("ModelManager: download of " + modelId + " stalled — no data for " + kDownloadStallSeconds.ToString + "s, cancelling" + EndOfLine)
		    conn.Disconnect()
		    Var part As FolderItem = ModelsFolder().Child(filename + ".part")
		    If part <> Nil And part.Exists Then part.Delete
		    mDownloads.Remove(conn)
		    SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false,""download stalled — no data received"");")
		  Next
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub SendToJS(js As String)
		  Try
		    Window1.MainView.EvaluateJavaScript(js)
		  Catch e As RuntimeException
		    App.AppendDebugLog("ModelManager.SendToJS: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ServerBinary() As FolderItem
		  // Release: llama-server is copied into Resources by Build Automation.
		  // Debug: fall back to Binaries/llama-server in the repo checkout.
		  Var f As FolderItem = SpecialFolder.Resources.Child("llama-server")
		  If f <> Nil And f.Exists Then Return f
		  Return App.FindFile("Binaries/llama-server")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StartEmbedServer()
		  If mEmbedTask <> Nil And mEmbedTask.isRunning Then Return
		  If mEmbedAdopted And EmbedServerHealthy(1) Then Return

		  Var modelFi As FolderItem = ModelsFolder().Child(Embedder.kEmbedModelFile)
		  If modelFi = Nil Or Not modelFi.Exists Then
		    App.AppendDebugLog("ModelManager: embedding model not installed yet — semantic search stays off" + EndOfLine)
		    Return
		  End If

		  // A stale embedding server (old start-server.sh workflow, previous debug
		  // run) may already own port 8089 — adopt it rather than double-bind.
		  // Adoption additionally requires the rope-scaled 8192-per-slot context
		  // regime: vectors from a 2048-capped server live in a different
		  // embedding space, so a stale old-regime instance is killed and
		  // relaunched instead ("our model on our port" implies it is an orphan
		  // XDOX once started).
		  //
		  // ALSO checks total slots (ProbeSlotCount) — added alongside the
		  // --parallel 1→2 bump (embed-phase parallelization, 2026-08-30),
		  // same reasoning as StartRerankServer's identical check: n_ctx alone
		  // can't distinguish an old single-slot server from the new 2-slot
		  // one, since ctx-size was scaled proportionally and both report
		  // n_ctx=8192 per slot — a stale --parallel 1 server would otherwise
		  // pass this check and get silently adopted, capping embedding at one
		  // request in flight with no error logged. Slot count 0 (older
		  // llama-server build, field absent) is treated as "unknown" and does
		  // NOT force a replace — only a CONFIRMED single-slot server does.
		  Var probe As String = ProbeExistingServerOn(EmbedBaseURL(), modelFi.NativePath)
		  If probe = "adopt" Then
		    Var slots As Integer = ProbeSlotCount(EmbedBaseURL())
		    If ProbeSlotCtx(EmbedBaseURL()) = 8192 And slots <> 1 Then
		      mEmbedAdopted = True
		      App.AppendDebugLog("ModelManager: adopted existing embedding server on port " + kEmbedPort + EndOfLine)
		      OnEmbedServerBecameReady
		      StartAdoptedEmbedWatchdog
		      Return
		    End If
		    App.AppendDebugLog("ModelManager: stale embedding server runs the old 2048-token or single-slot regime — replacing it" + EndOfLine)
		    KillAdoptedServer(kEmbedPort)
		    For i As Integer = 1 To 10
		      If ProbeExistingServerOn(EmbedBaseURL(), modelFi.NativePath) = "none" Then Exit
		      Thread.SleepCurrent(200)
		    Next
		  ElseIf probe <> "none" Then
		    App.AppendDebugLog("ModelManager: embedding port conflict: " + probe + EndOfLine)
		    Return
		  End If

		  Var serverBin As FolderItem = ServerBinary()
		  If serverBin = Nil Or Not serverBin.Exists Then Return

		  Var args() As String
		  args.Add("--model")
		  args.Add(modelFi.NativePath)
		  args.Add("--embedding")
		  args.Add("--port")
		  args.Add(kEmbedPort)
		  args.Add("--host")
		  args.Add("127.0.0.1")
		  // nomic v1.5 trains at 2048 tokens but officially supports 8192 through
		  // YaRN rope scaling (HF model card: --rope-scaling yarn --rope-freq-scale
		  // .75). Newer llama-server hard-caps the slot context to the GGUF's
		  // training-context metadata regardless of rope flags, so that key must
		  // be overridden too. XDOX chunks run up to 8000 chars (~2000+ tokens)
		  // and a single input must fit the slot — llama-server splits ctx-size
		  // evenly across parallel slots, so ctx-size must scale with --parallel
		  // to keep each slot's own budget at the required 8192.
		  // NB: these flags define the embedding space — changing them makes all
		  // stored vectors incompatible (full re-embed required).
		  //
		  // 2 slots, not 1 (embed-phase parallelization, 2026-08-30): the
		  // client-side embed loop (Embedder.EmbedPendingChunks) now runs up to
		  // 2 EmbedWorker threads concurrently — with --parallel 1 the second
		  // request queues behind the first INSIDE this server regardless of
		  // Xojo-side threading, capping the actual throughput win. ctx-size
		  // doubled to 16384 (2 x 8192) so each of the 2 slots keeps its
		  // existing 8192-token budget rather than being halved. NOT verified
		  // safe to raise further than 2 on this hardware (M1 Max, 32GB): each
		  // parallel slot allocates its own full ctx-size KV-cache under -ngl 99
		  // full GPU offload, and StartRerankServer's identical --parallel bump
		  // has an existing comment noting a prior attempt to give one slot the
		  // model's full native context crashed the server silently on launch —
		  // the same failure mode a bigger multiply here could hit again. Only
		  // 2 concurrent embed workers are ever spawned — no need to go higher.
		  args.Add("--ctx-size")
		  args.Add("16384")
		  args.Add("--batch-size")
		  args.Add("16384")
		  args.Add("--ubatch-size")
		  args.Add("16384")
		  args.Add("--parallel")
		  args.Add("2")
		  args.Add("--rope-scaling")
		  args.Add("yarn")
		  args.Add("--rope-freq-scale")
		  args.Add("0.75")
		  args.Add("--override-kv")
		  args.Add("nomic-bert.context_length=int:8192")
		  args.Add("-ngl")
		  args.Add("99")

		  mEmbedTask = New NSTaskMBS
		  mEmbedTask.launchPath = serverBin.NativePath
		  mEmbedTask.setArguments(args)

		  Var stdoutPipe As New NSPipeMBS
		  mEmbedTask.setStandardOutput(stdoutPipe)
		  mEmbedTask.setStandardError(stdoutPipe)
		  mEmbedTask.launch()

		  mEmbedStdoutHandle = stdoutPipe.fileHandleForReading
		  mEmbedStdoutObserver = New NSNotificationObserverMBS
		  AddHandler mEmbedStdoutObserver.GotNotification, AddressOf OnEmbedServerOutput
		  NSNotificationCenterMBS.defaultCenter.addObserver(mEmbedStdoutObserver, NSFileHandleMBS.NSFileHandleDataAvailableNotification, mEmbedStdoutHandle)
		  mEmbedStdoutHandle.waitForDataInBackgroundAndNotify

		  StartEmbedHealthPolling
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub StartEmbedHealthPolling()
		  mEmbedHealthElapsed = 0
		  If mEmbedHealthTimer = Nil Then
		    mEmbedHealthTimer = New Timer
		    mEmbedHealthTimer.Period = 3000
		    AddHandler mEmbedHealthTimer.Action, AddressOf OnEmbedHealthTimer
		  End If
		  mEmbedHealthTimer.RunMode = Timer.RunModes.Multiple
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnEmbedHealthTimer(sender As Timer)
		  If mEmbedReady Then
		    sender.RunMode = Timer.RunModes.Off
		    Return
		  End If
		  mEmbedHealthElapsed = mEmbedHealthElapsed + (sender.Period / 1000)
		  If mEmbedHealthElapsed > kHealthGraceSeconds Then
		    sender.RunMode = Timer.RunModes.Off
		    App.AppendDebugLog("ModelManager: embedding server never became healthy — keyword-only search" + EndOfLine)
		    Return
		  End If
		  If mEmbedHealthConn <> Nil Then Return
		  mEmbedHealthConn = New URLConnection
		  AddHandler mEmbedHealthConn.ContentReceived, AddressOf OnEmbedHealthReceived
		  AddHandler mEmbedHealthConn.Error, AddressOf OnEmbedHealthError
		  mEmbedHealthConn.Send("GET", EmbedBaseURL() + "/health")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnEmbedHealthReceived(sender As URLConnection, url As String, httpStatus As Integer, content As String)
		  #Pragma Unused sender
		  #Pragma Unused url
		  #Pragma Unused content
		  mEmbedHealthConn = Nil
		  If httpStatus = 200 Then
		    If mEmbedHealthTimer <> Nil Then mEmbedHealthTimer.RunMode = Timer.RunModes.Off
		    OnEmbedServerBecameReady
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnEmbedHealthError(sender As URLConnection, err As RuntimeException)
		  #Pragma Unused sender
		  #Pragma Unused err
		  mEmbedHealthConn = Nil // socket not up yet — keep polling
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnEmbedServerBecameReady()
		  mEmbedReady = True
		  Retrieval.NotifySemanticState
		  // Notes saved while the server was down get their vectors now — on a
		  // worker thread, since this runs in a URLConnection callback on main.
		  DBHelper.BackfillNoteEmbeddingsAsync
		  // Backfill any chunks the last index run left unembedded (server was
		  // down or the model was mid-download). Skipped while a full index runs —
		  // its own embed phase covers them.
		  If DBHelper.PendingEmbedCount > 0 And Not Indexer.IsRunning Then
		    App.AppendDebugLog("ModelManager: resuming embedding of " + DBHelper.PendingEmbedCount.ToString + " pending chunks" + EndOfLine)
		    Indexer.StartEmbedOnly(New EmbedStatusAdapter)
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function EmbedServerReady() As Boolean
		  Return mEmbedReady
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnEmbedServerOutput(observer As NSNotificationObserverMBS, notification As NSNotificationMBS)
		  #Pragma Unused observer
		  #Pragma Unused notification
		  If mEmbedStdoutHandle = Nil Then Return
		  Var data As MemoryBlock = mEmbedStdoutHandle.availableData
		  If data <> Nil And data.Size > 0 Then
		    // Same EOF rule as the chat server: only re-arm while data flows.
		    mEmbedStdoutHandle.waitForDataInBackgroundAndNotify
		  Else
		    // Arm regardless of mEmbedReady — a crash after becoming ready needs
		    // recovery/notification just as much as one that never came up.
		    mEmbedCrashCheckTimer = New Timer
		    mEmbedCrashCheckTimer.Period = 500
		    AddHandler mEmbedCrashCheckTimer.Action, AddressOf OnEmbedCrashCheckTimer
		    mEmbedCrashCheckTimer.RunMode = Timer.RunModes.Single
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnEmbedCrashCheckTimer(sender As Timer)
		  #Pragma Unused sender
		  If mEmbedTask <> Nil And Not mEmbedTask.isRunning Then
		    App.AppendDebugLog("ModelManager: embedding server exited — semantic search degrades to keyword-only" + EndOfLine)
		    StopEmbedServer
		    Retrieval.NotifySemanticState
		    SendToJS("receiveEmbedCrashed();")
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub StartAdoptedEmbedWatchdog()
		  // Adopted embedding servers have no NSTaskMBS handle either — poll
		  // /health so a later crash is still detected.
		  If mAdoptedEmbedWatchdogTimer = Nil Then
		    mAdoptedEmbedWatchdogTimer = New Timer
		    mAdoptedEmbedWatchdogTimer.Period = kAdoptedWatchdogMS
		    AddHandler mAdoptedEmbedWatchdogTimer.Action, AddressOf OnAdoptedEmbedWatchdogTimer
		  End If
		  mAdoptedEmbedWatchdogTimer.RunMode = Timer.RunModes.Multiple
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnAdoptedEmbedWatchdogTimer(sender As Timer)
		  If Not mEmbedAdopted Then
		    sender.RunMode = Timer.RunModes.Off
		    Return
		  End If
		  If mAdoptedEmbedWatchdogConn <> Nil Then Return // previous probe still in flight
		  mAdoptedEmbedWatchdogConn = New URLConnection
		  AddHandler mAdoptedEmbedWatchdogConn.ContentReceived, AddressOf OnAdoptedEmbedWatchdogReceived
		  AddHandler mAdoptedEmbedWatchdogConn.Error, AddressOf OnAdoptedEmbedWatchdogError
		  mAdoptedEmbedWatchdogConn.Send("GET", EmbedBaseURL() + "/health")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnAdoptedEmbedWatchdogReceived(sender As URLConnection, url As String, httpStatus As Integer, content As String)
		  #Pragma Unused url
		  #Pragma Unused content
		  // Ignore a stale connection from a server StopEmbedServer already tore
		  // down — see OnAdoptedWatchdogReceived for the same race on the chat side.
		  If sender <> mAdoptedEmbedWatchdogConn Then Return
		  mAdoptedEmbedWatchdogConn = Nil
		  If httpStatus <> 200 Then HandleAdoptedEmbedWatchdogFailure
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnAdoptedEmbedWatchdogError(sender As URLConnection, err As RuntimeException)
		  #Pragma Unused err
		  If sender <> mAdoptedEmbedWatchdogConn Then Return
		  mAdoptedEmbedWatchdogConn = Nil
		  HandleAdoptedEmbedWatchdogFailure
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub HandleAdoptedEmbedWatchdogFailure()
		  If Not mEmbedAdopted Then Return // already stopped by another path
		  App.AppendDebugLog("ModelManager: adopted embedding server failed health check — treating as crashed" + EndOfLine)
		  If mAdoptedEmbedWatchdogTimer <> Nil Then mAdoptedEmbedWatchdogTimer.RunMode = Timer.RunModes.Off
		  StopEmbedServer
		  Retrieval.NotifySemanticState
		  SendToJS("receiveEmbedCrashed();")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ProbeExistingServerOn(baseURL As String, expectedModelPath As String) As String
		  // Generalised /props probe: "none" (port free), "adopt" (compatible
		  // server already running) or a human-readable conflict message.
		  Var raw As String
		  Try
		    Var conn As New URLConnection
		    raw = conn.SendSync("GET", baseURL + "/props", 2)
		  Catch e As NetworkException
		    Return "none"
		  End Try

		  Try
		    Var props As New JSONItem(raw)
		    Var runningModel As String = props.Lookup("model_path", "").StringValue
		    If runningModel = "" Then Return "adopt"
		    If FileNameFromPath(runningModel) = FileNameFromPath(expectedModelPath) Then Return "adopt"
		    Return baseURL + " is used by another llama-server (model: " + FileNameFromPath(runningModel) + ")"
		  Catch e As RuntimeException
		    Return baseURL + " is used by another application"
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StopEmbedServer()
		  If mEmbedHealthTimer <> Nil Then mEmbedHealthTimer.RunMode = Timer.RunModes.Off
		  If mAdoptedEmbedWatchdogTimer <> Nil Then mAdoptedEmbedWatchdogTimer.RunMode = Timer.RunModes.Off
		  mEmbedHealthConn = Nil
		  If mAdoptedEmbedWatchdogConn <> Nil Then mAdoptedEmbedWatchdogConn.Disconnect
		  mAdoptedEmbedWatchdogConn = Nil
		  If mEmbedTask <> Nil And mEmbedTask.isRunning Then
		    mEmbedTask.terminate()
		  ElseIf mEmbedAdopted Then
		    KillAdoptedServer(kEmbedPort)
		  End If
		  mEmbedTask = Nil
		  If mEmbedStdoutObserver <> Nil Then
		    NSNotificationCenterMBS.defaultCenter.removeObserver(mEmbedStdoutObserver)
		    mEmbedStdoutObserver = Nil
		  End If
		  mEmbedStdoutHandle = Nil
		  mEmbedAdopted = False
		  mEmbedReady = False
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StartRerankServer()
		  If mRerankTask <> Nil And mRerankTask.isRunning Then Return
		  If mRerankAdopted And RerankServerHealthy(1) Then Return

		  Var modelFi As FolderItem = ModelsFolder().Child(Reranker.kRerankModelFile)
		  If modelFi = Nil Or Not modelFi.Exists Then
		    App.AppendDebugLog("ModelManager: reranker model not installed yet — no-match detection stays off" + EndOfLine)
		    Return
		  End If

		  // A stale reranker server from a previous debug session may already own
		  // port 8093 — adopt it rather than double-bind, same as the chat/embed
		  // servers. Same stale-regime check as the embedding server's ProbeSlotCtx
		  // use: a server started with llama-server's tiny default --batch-size
		  // (512) would otherwise be silently adopted forever, returning HTTP 500
		  // "input too large" on every real rerank call (hit live). Checks for
		  // the CURRENT --ctx-size (4096) specifically, not just "> 512" — an
		  // old build that tried 40960 and crashed on launch never got this far,
		  // but a hypothetical future value change should still force a replace.
		  //
		  // ALSO checks total slots (ProbeSlotCount) — added alongside the
		  // --parallel 1→2 bump (split-bubble redesign, 2026-08-30):
		  // n_ctx alone can't distinguish an old single-slot server from the
		  // new 2-slot one, both report n_ctx=4096, so a stale --parallel 1
		  // server would otherwise pass this check and get silently adopted,
		  // capping the concurrency this change exists to enable. Slot count
		  // 0 (older llama-server build, field absent) is treated as
		  // "unknown" and does NOT force a replace — only a CONFIRMED
		  // single-slot server (slots = 1) does, same "only replace on
		  // positive evidence of staleness" discipline as the n_ctx check.
		  Var probe As String = ProbeExistingServerOn(RerankBaseURL(), modelFi.NativePath)
		  If probe = "adopt" Then
		    Var slots As Integer = ProbeSlotCount(RerankBaseURL())
		    If ProbeSlotCtx(RerankBaseURL()) = 4096 And slots <> 1 Then
		      mRerankAdopted = True
		      App.AppendDebugLog("ModelManager: adopted existing reranker server on port " + kRerankPort + EndOfLine)
		      OnRerankServerBecameReady
		      StartAdoptedRerankWatchdog
		      Return
		    End If
		    App.AppendDebugLog("ModelManager: stale reranker server runs the old small-batch or single-slot regime — replacing it" + EndOfLine)
		    KillAdoptedServer(kRerankPort)
		    For i As Integer = 1 To 10
		      If ProbeExistingServerOn(RerankBaseURL(), modelFi.NativePath) = "none" Then Exit
		      Thread.SleepCurrent(200)
		    Next
		  ElseIf probe <> "none" Then
		    App.AppendDebugLog("ModelManager: reranker port conflict: " + probe + EndOfLine)
		    Return
		  End If

		  Var serverBin As FolderItem = ServerBinary()
		  If serverBin = Nil Or Not serverBin.Exists Then Return

		  Var args() As String
		  args.Add("--model")
		  args.Add(modelFi.NativePath)
		  // All three flags are required together — llama-server reports "This
		  // server does not support reranking" if any one is missing.
		  args.Add("--reranking")
		  args.Add("--embedding")
		  args.Add("--pooling")
		  args.Add("rank")
		  args.Add("--port")
		  args.Add(kRerankPort)
		  args.Add("--host")
		  args.Add("127.0.0.1")
		  // llama-server's default --batch-size/--ubatch-size (512) caps the
		  // tokens processed per SINGLE query+candidate pair (the reranking
		  // endpoint scores candidates one at a time, not as one combined
		  // batch — confirmed live: a batch of 8 large candidates succeeded at
		  // 4096 with 6088 total prompt_tokens reported, so the ceiling is
		  // per-pair, not per-request). Reranker.kMaxRerankChars caps each
		  // candidate at 6000 chars (~1500 tokens); 4096 leaves comfortable
		  // headroom for the query + chat-template overhead on top of that.
		  // Matching the model's full 40960-token native context here was
		  // tried first and crashed the server silently on launch (large
		  // KV-cache allocation with -ngl 99 forcing full GPU offload) — do
		  // NOT raise this without confirming the server actually stays up.
		  args.Add("--ctx-size")
		  args.Add("4096")
		  args.Add("--batch-size")
		  args.Add("4096")
		  args.Add("--ubatch-size")
		  args.Add("4096")
		  // 2 slots, not 1: the split-bubble redesign (reactive-coalescing-
		  // thimble plan, Decision 1, 2026-08-30) runs native and MBS
		  // reranking as two independent ChatPrepThread workers that can
		  // call Reranker.RerankBatch concurrently — with --parallel 1 the
		  // second call queues behind the first INSIDE this server
		  // regardless of Xojo-side threading, capping the actual
		  // responsiveness win. NOT verified safe to raise further than 2:
		  // each parallel slot gets its own full --ctx-size KV-cache
		  // allocation, and the comment above (Matching the model's full
		  // context crashed the server silently on launch with -ngl 99
		  // forcing full GPU offload) is exactly the failure mode a bigger
		  // multiply here could hit again. Only ever 2 concurrent callers
		  // exist (native pool, MBS pool) — no need to go higher.
		  args.Add("--parallel")
		  args.Add("2")
		  args.Add("-ngl")
		  args.Add("99")

		  mRerankTask = New NSTaskMBS
		  mRerankTask.launchPath = serverBin.NativePath
		  mRerankTask.setArguments(args)

		  Var stdoutPipe As New NSPipeMBS
		  mRerankTask.setStandardOutput(stdoutPipe)
		  mRerankTask.setStandardError(stdoutPipe)
		  mRerankTask.launch()

		  mRerankStdoutHandle = stdoutPipe.fileHandleForReading
		  mRerankStdoutObserver = New NSNotificationObserverMBS
		  AddHandler mRerankStdoutObserver.GotNotification, AddressOf OnRerankServerOutput
		  NSNotificationCenterMBS.defaultCenter.addObserver(mRerankStdoutObserver, NSFileHandleMBS.NSFileHandleDataAvailableNotification, mRerankStdoutHandle)
		  mRerankStdoutHandle.waitForDataInBackgroundAndNotify

		  StartRerankHealthPolling
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub StartRerankHealthPolling()
		  mRerankHealthElapsed = 0
		  If mRerankHealthTimer = Nil Then
		    mRerankHealthTimer = New Timer
		    mRerankHealthTimer.Period = 3000
		    AddHandler mRerankHealthTimer.Action, AddressOf OnRerankHealthTimer
		  End If
		  mRerankHealthTimer.RunMode = Timer.RunModes.Multiple
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnRerankHealthTimer(sender As Timer)
		  If mRerankReady Then
		    sender.RunMode = Timer.RunModes.Off
		    Return
		  End If
		  mRerankHealthElapsed = mRerankHealthElapsed + (sender.Period / 1000)
		  If mRerankHealthElapsed > kHealthGraceSeconds Then
		    sender.RunMode = Timer.RunModes.Off
		    App.AppendDebugLog("ModelManager: reranker server never became healthy — no-match detection stays off" + EndOfLine)
		    Return
		  End If
		  If mRerankHealthConn <> Nil Then Return
		  mRerankHealthConn = New URLConnection
		  AddHandler mRerankHealthConn.ContentReceived, AddressOf OnRerankHealthReceived
		  AddHandler mRerankHealthConn.Error, AddressOf OnRerankHealthError
		  mRerankHealthConn.Send("GET", RerankBaseURL() + "/health")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnRerankHealthReceived(sender As URLConnection, url As String, httpStatus As Integer, content As String)
		  #Pragma Unused sender
		  #Pragma Unused url
		  #Pragma Unused content
		  mRerankHealthConn = Nil
		  If httpStatus = 200 Then
		    If mRerankHealthTimer <> Nil Then mRerankHealthTimer.RunMode = Timer.RunModes.Off
		    OnRerankServerBecameReady
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnRerankHealthError(sender As URLConnection, err As RuntimeException)
		  #Pragma Unused sender
		  #Pragma Unused err
		  mRerankHealthConn = Nil // socket not up yet — keep polling
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnRerankServerBecameReady()
		  mRerankReady = True
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function RerankServerReady() As Boolean
		  Return mRerankReady
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnRerankServerOutput(observer As NSNotificationObserverMBS, notification As NSNotificationMBS)
		  #Pragma Unused observer
		  #Pragma Unused notification
		  If mRerankStdoutHandle = Nil Then Return
		  Var data As MemoryBlock = mRerankStdoutHandle.availableData
		  If data <> Nil And data.Size > 0 Then
		    mRerankStdoutHandle.waitForDataInBackgroundAndNotify
		  Else
		    // Arm regardless of mRerankReady — a crash after becoming ready needs
		    // recovery/notification just as much as one that never came up.
		    mRerankCrashCheckTimer = New Timer
		    mRerankCrashCheckTimer.Period = 500
		    AddHandler mRerankCrashCheckTimer.Action, AddressOf OnRerankCrashCheckTimer
		    mRerankCrashCheckTimer.RunMode = Timer.RunModes.Single
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnRerankCrashCheckTimer(sender As Timer)
		  #Pragma Unused sender
		  If mRerankTask <> Nil And Not mRerankTask.isRunning Then
		    App.AppendDebugLog("ModelManager: reranker server exited — no-match detection degrades off, ranking falls back to cosine+BM25" + EndOfLine)
		    StopRerankServer
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub StartAdoptedRerankWatchdog()
		  // Adopted reranker servers have no NSTaskMBS handle either — poll
		  // /health so a later crash is still detected.
		  If mAdoptedRerankWatchdogTimer = Nil Then
		    mAdoptedRerankWatchdogTimer = New Timer
		    mAdoptedRerankWatchdogTimer.Period = kAdoptedWatchdogMS
		    AddHandler mAdoptedRerankWatchdogTimer.Action, AddressOf OnAdoptedRerankWatchdogTimer
		  End If
		  mAdoptedRerankWatchdogTimer.RunMode = Timer.RunModes.Multiple
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnAdoptedRerankWatchdogTimer(sender As Timer)
		  If Not mRerankAdopted Then
		    sender.RunMode = Timer.RunModes.Off
		    Return
		  End If
		  If mAdoptedRerankWatchdogConn <> Nil Then Return // previous probe still in flight
		  mAdoptedRerankWatchdogConn = New URLConnection
		  AddHandler mAdoptedRerankWatchdogConn.ContentReceived, AddressOf OnAdoptedRerankWatchdogReceived
		  AddHandler mAdoptedRerankWatchdogConn.Error, AddressOf OnAdoptedRerankWatchdogError
		  mAdoptedRerankWatchdogConn.Send("GET", RerankBaseURL() + "/health")
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnAdoptedRerankWatchdogReceived(sender As URLConnection, url As String, httpStatus As Integer, content As String)
		  #Pragma Unused url
		  #Pragma Unused content
		  If sender <> mAdoptedRerankWatchdogConn Then Return
		  mAdoptedRerankWatchdogConn = Nil
		  If httpStatus <> 200 Then HandleAdoptedRerankWatchdogFailure
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnAdoptedRerankWatchdogError(sender As URLConnection, err As RuntimeException)
		  #Pragma Unused err
		  If sender <> mAdoptedRerankWatchdogConn Then Return
		  mAdoptedRerankWatchdogConn = Nil
		  HandleAdoptedRerankWatchdogFailure
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub HandleAdoptedRerankWatchdogFailure()
		  If Not mRerankAdopted Then Return // already stopped by another path
		  App.AppendDebugLog("ModelManager: adopted reranker server failed health check — treating as crashed" + EndOfLine)
		  If mAdoptedRerankWatchdogTimer <> Nil Then mAdoptedRerankWatchdogTimer.RunMode = Timer.RunModes.Off
		  StopRerankServer
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StopRerankServer()
		  If mRerankHealthTimer <> Nil Then mRerankHealthTimer.RunMode = Timer.RunModes.Off
		  If mAdoptedRerankWatchdogTimer <> Nil Then mAdoptedRerankWatchdogTimer.RunMode = Timer.RunModes.Off
		  mRerankHealthConn = Nil
		  If mAdoptedRerankWatchdogConn <> Nil Then mAdoptedRerankWatchdogConn.Disconnect
		  mAdoptedRerankWatchdogConn = Nil
		  If mRerankTask <> Nil And mRerankTask.isRunning Then
		    mRerankTask.terminate()
		  ElseIf mRerankAdopted Then
		    KillAdoptedServer(kRerankPort)
		  End If
		  mRerankTask = Nil
		  If mRerankStdoutObserver <> Nil Then
		    NSNotificationCenterMBS.defaultCenter.removeObserver(mRerankStdoutObserver)
		    mRerankStdoutObserver = Nil
		  End If
		  mRerankStdoutHandle = Nil
		  mRerankAdopted = False
		  mRerankReady = False
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StopAllServers()
		  StopEmbedServer
		  StopRerankServer
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ProbeSlotCtx(baseURL As String) As Integer
		  // Effective per-slot context of a running server, read from /props
		  // (default_generation_settings.n_ctx). 0 if unreachable or unparsable.
		  Try
		    Var conn As New URLConnection
		    #Pragma BreakOnExceptions False
		    Var raw As String = conn.SendSync("GET", baseURL + "/props", 2)
		    #Pragma BreakOnExceptions Default
		    Var props As New JSONItem(raw)
		    If Not props.HasKey("default_generation_settings") Then Return 0
		    Var dgs As JSONItem = props.Child("default_generation_settings")
		    Return dgs.Lookup("n_ctx", 0)
		  Catch e As RuntimeException
		    Return 0
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ProbeSlotCount(baseURL As String) As Integer
		  // Total parallel slots a running server was launched with, read
		  // from /props (total_slots, a field newer llama-server builds
		  // report). 0 if unreachable, unparsable, or the field is absent
		  // (older server build — treated as "unknown," not "1," by the
		  // caller, so an unparsable response doesn't itself force a
		  // needless restart).
		  //
		  // Added alongside StartRerankServer's --parallel 1→2 bump (split-
		  // bubble redesign, Decision 1, 2026-08-30): ProbeSlotCtx alone
		  // (n_ctx) can't tell a stale, already-running --parallel 1
		  // reranker apart from the new --parallel 2 regime — both report
		  // n_ctx=4096 — so a server adopted from before this change would
		  // otherwise silently keep running single-slot, capping the
		  // concurrency this change exists to enable, with no error and no
		  // log line to explain why the second rerank call still queues.
		  Try
		    Var conn As New URLConnection
		    #Pragma BreakOnExceptions False
		    Var raw As String = conn.SendSync("GET", baseURL + "/props", 2)
		    #Pragma BreakOnExceptions Default
		    Var props As New JSONItem(raw)
		    Return props.Lookup("total_slots", 0)
		  Catch e As RuntimeException
		    Return 0
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub KillAdoptedServer(port As String)
		  // Only called when the adoption flag is set, i.e. /props confirmed the
		  // process is a llama-server running OUR model — a foreign process on
		  // the port (port-conflict state) is never adopted and never killed.
		  // The pkill pattern is narrow: binary name + exact port.
		  Try
		    Var sh As New Shell
		    sh.Execute("/usr/bin/pkill -f ""llama-server.*--port " + port + """")
		  Catch e As RuntimeException
		    App.AppendDebugLog("ModelManager.KillAdoptedServer: " + e.Message + EndOfLine)
		  End Try
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mAdoptedEmbedWatchdogTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mAdoptedRerankWatchdogTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mAdoptedEmbedWatchdogConn As URLConnection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mAdoptedRerankWatchdogConn As URLConnection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mDownloads As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mVerifying As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedAdopted As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRerankAdopted As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedHealthConn As URLConnection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRerankHealthConn As URLConnection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedHealthElapsed As Double
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRerankHealthElapsed As Double
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedHealthTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRerankHealthTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedReady As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRerankReady As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedCrashCheckTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRerankCrashCheckTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedStdoutHandle As NSFileHandleMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRerankStdoutHandle As NSFileHandleMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedStdoutObserver As NSNotificationObserverMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRerankStdoutObserver As NSNotificationObserverMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedTask As NSTaskMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mRerankTask As NSTaskMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLastProgressTick As Double
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mStallTimer As Timer
	#tag EndProperty


	#tag Constant, Name = kDownloadStallSeconds, Type = Double, Dynamic = False, Default = \"90", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kAdoptedWatchdogMS, Type = Double, Dynamic = False, Default = \"5000", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kEmbedPort, Type = String, Dynamic = False, Default = \"8089", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kRerankPort, Type = String, Dynamic = False, Default = \"8093", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kHFBase, Type = String, Dynamic = False, Default = \"https://huggingface.co", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kHealthGraceSeconds, Type = Double, Dynamic = False, Default = \"60", Scope = Private
	#tag EndConstant


End Module
#tag EndModule
