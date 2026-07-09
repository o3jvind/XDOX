#tag Module
Protected Module ModelManager
	#tag Method, Flags = &h0
		Sub AutoStart()
		  // Called from ChatView's pageReady handler — the WebView must be live
		  // before any receiveBackendState() call can land.
		  CleanupPartFiles
		  Var id As String = SelectedModelId()
		  If id = "" Then
		    // First run: hold the embedding download until the user has picked a
		    // chat model in the picker — the picker discloses the extra one-time
		    // download, so acting on it counts as informed consent.
		    SendBackendState("no-model", "")
		  Else
		    EnsureEmbeddingModel
		    StartServer(id)
		  End If

		  StartEmbedServer
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function BaseURL() As String
		  // Single source of truth for the llama-server endpoint — used by the
		  // launch args, the adoption probe, health polling and XDOXSession.
		  Return "http://127.0.0.1:" + kServerPort
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function EmbedBaseURL() As String
		  // Port 8089 on purpose: XMCP hardcodes this address for its semantic
		  // search, so XDOX's embedding server serves both apps.
		  Return "http://127.0.0.1:" + kEmbedPort
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
		Sub EnsureEmbeddingModel()
		  // The embedding model is a fixed dependency (768-dim nomic), not a
		  // catalog choice — the DB schema and XMCP both assume it.
		  Var f As FolderItem = ModelsFolder().Child(Embedder.kEmbedModelFile)
		  If f <> Nil And f.Exists And f.Length > 0 Then Return

		  If mDownloads = Nil Then mDownloads = New Dictionary
		  For Each key As Variant In mDownloads.Keys
		    Var info As Dictionary = Dictionary(mDownloads.Value(URLConnection(key)))
		    If info.Lookup("modelId", "") = "embedding" Then Return // already downloading
		  Next

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
		  info.Value("lastProgressTick") = System.Ticks
		  mDownloads.Value(conn) = info

		  conn.Send("GET", url, dest)
		  StartStallWatchdog
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub CancelDownload(modelId As String)
		  If mDownloads = Nil Then Return
		  For Each key As Variant In mDownloads.Keys
		    Var conn As URLConnection = URLConnection(key)
		    Var info As Dictionary = Dictionary(mDownloads.Value(conn))
		    If info.Lookup("modelId", "") = modelId Then
		      conn.Disconnect()
		      Var filename As String = info.Lookup("filename", "")
		      Var part As FolderItem = ModelsFolder().Child(filename + ".part")
		      If part <> Nil And part.Exists Then part.Delete
		      mDownloads.Remove(conn)
		      SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false,""cancelled"");")
		      Return
		    End If
		  Next
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub CancelAllDownloads()
		  // Called from App.Closing so a quit during a download doesn't leave a
		  // half-written .part file (or an orphaned URLConnection) behind.
		  If mDownloads = Nil Then Return
		  For Each key As Variant In mDownloads.Keys
		    Var conn As URLConnection = URLConnection(key)
		    Var info As Dictionary = Dictionary(mDownloads.Value(conn))
		    conn.Disconnect()
		    Var filename As String = info.Lookup("filename", "")
		    Var part As FolderItem = ModelsFolder().Child(filename + ".part")
		    If part <> Nil And part.Exists Then part.Delete
		  Next
		  mDownloads = New Dictionary
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

	#tag Method, Flags = &h21
		Private Function CatalogEntry(id As String, name As String, description As String, ram As String, repo As String, filename As String, bytes As Int64, recommended As Boolean) As JSONItem
		  Var entry As New JSONItem
		  entry.Value("id") = id
		  entry.Value("name") = name
		  entry.Value("description") = description
		  entry.Value("ram") = ram
		  entry.Value("repo") = repo
		  entry.Value("filename") = filename
		  entry.Value("bytes") = bytes
		  entry.Value("recommended") = recommended
		  Return entry
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function CatalogJSON() As String
		  // Static text-only model catalog (no mmproj — XDOX is text-only).
		  // bytes = exact HF download size, used to verify completed downloads.
		  Var catalog As New JSONItem
		  // Coder 7B is the recommended default: in testing (July 2026) it was the
		  // smallest model that reproduced doc syntax faithfully — the 4B models
		  // recite syntax rules correctly but violate them in their own code.
		  catalog.Add(CatalogEntry("qwen25-coder-7b-q6", "Qwen2.5 Coder 7B (Q6)", "Alibaba. Most accurate Xojo code answers, for 16 GB+ Macs.", "~9 GB", "Qwen/Qwen2.5-Coder-7B-Instruct-GGUF", "qwen2.5-coder-7b-instruct-q6_k.gguf", 6254198784, True))
		  catalog.Add(CatalogEntry("qwen3-4b-q4", "Qwen3 4B Instruct (Q4)", "Alibaba. Fast and light, fits 8 GB Macs.", "~5 GB", "unsloth/Qwen3-4B-Instruct-2507-GGUF", "Qwen3-4B-Instruct-2507-Q4_K_M.gguf", 2497281120, False))
		  catalog.Add(CatalogEntry("gemma3-4b-q4", "Gemma 3 4B (Q4)", "Google. Strong all-rounder, fits 8 GB Macs.", "~5 GB", "ggml-org/gemma-3-4b-it-GGUF", "gemma-3-4b-it-Q4_K_M.gguf", 2489757856, False))
		  catalog.Add(CatalogEntry("phi4-mini-q4", "Phi-4 Mini 3.8B (Q4)", "Microsoft, MIT licence. Good reasoning, fits 8 GB Macs.", "~5 GB", "unsloth/Phi-4-mini-instruct-GGUF", "Phi-4-mini-instruct-Q4_K_M.gguf", 2491874272, False))
		  catalog.Add(CatalogEntry("gpt-oss-20b", "GPT-OSS 20B (MXFP4)", "OpenAI. Strongest option, for 16 GB+ Macs.", "~16 GB", "ggml-org/gpt-oss-20b-GGUF", "gpt-oss-20b-mxfp4.gguf", 12109566560, False))
		  catalog.Add(CatalogEntry("mistral-small-24b-q4", "Mistral Small 3.2 24B (Q4)", "Mistral (EU). Big and capable, for 24 GB+ Macs.", "~17 GB", "bartowski/mistralai_Mistral-Small-3.2-24B-Instruct-2506-GGUF", "mistralai_Mistral-Small-3.2-24B-Instruct-2506-Q4_K_M.gguf", 14333915264, False))
		  Return catalog.ToString
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub DownloadModel(modelId As String)
		  Var entry As JSONItem = FindCatalogEntry(modelId)
		  If entry = Nil Then Return
		  Var repo As String = entry.Lookup("repo", "")
		  Var filename As String = entry.Lookup("filename", "")
		  Var bytes As Int64 = entry.Lookup("bytes", 0).Int64Value

		  If mDownloads = Nil Then mDownloads = New Dictionary
		  Var url As String = kHFBase + "/" + repo + "/resolve/main/" + filename
		  // Download directly to a .part file; OnFileReceived renames it
		  Var dest As FolderItem = ModelsFolder().Child(filename + ".part")

		  Var conn As New URLConnection
		  AddHandler conn.FileReceived, AddressOf OnFileReceived
		  AddHandler conn.ReceivingProgressed, AddressOf OnReceivingProgressed
		  AddHandler conn.Error, AddressOf OnDownloadError

		  Var info As New Dictionary
		  info.Value("modelId") = modelId
		  info.Value("filename") = filename
		  info.Value("bytes") = bytes
		  info.Value("lastProgressTick") = System.Ticks
		  mDownloads.Value(conn) = info

		  conn.Send("GET", url, dest)
		  StartStallWatchdog

		  // The user's first chat-model download doubles as consent for the fixed
		  // embedding model (disclosed in the picker) — fetch both in parallel.
		  EnsureEmbeddingModel
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function EmbeddingModelInstalled() As Boolean
		  Var f As FolderItem = ModelsFolder().Child(Embedder.kEmbedModelFile)
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
		Private Function FindCatalogEntry(modelId As String) As JSONItem
		  Var catalog As New JSONItem(CatalogJSON())
		  For i As Integer = 0 To catalog.Count - 1
		    Var entry As JSONItem = JSONItem(catalog.ValueAt(i))
		    If entry.Lookup("id", "") = modelId Then Return entry
		  Next
		  Return Nil
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function InstalledModelsJSON() As String
		  // { "<id>": true/false, ... } — file present (any size > 0) counts as
		  // installed. Exact-size verification happens only at download time:
		  // locally adopted files may differ a few bytes from the current HF blob.
		  Var folder As FolderItem = ModelsFolder()
		  Var result As New JSONItem
		  Var catalog As New JSONItem(CatalogJSON())
		  For i As Integer = 0 To catalog.Count - 1
		    Var entry As JSONItem = JSONItem(catalog.ValueAt(i))
		    Var fi As FolderItem = folder.Child(entry.Lookup("filename", ""))
		    result.Value(entry.Lookup("id", "").StringValue) = (fi <> Nil And fi.Exists And fi.Length > 0)
		  Next
		  Return result.ToString
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

	#tag Method, Flags = &h21
		Private Sub LaunchServer(modelPath As String)
		  Var probe As String = ProbeExistingServer(modelPath)
		  If probe = "adopt" Then
		    mServerAdopted = True
		    mServerReady = True
		    SendBackendState("ready", "")
		    Return
		  ElseIf probe <> "none" Then
		    SendBackendState("port-conflict", probe)
		    Return
		  End If

		  Var serverBin As FolderItem = ServerBinary()
		  If serverBin = Nil Or Not serverBin.Exists Then
		    SendBackendState("error", "llama-server binary not found")
		    Return
		  End If

		  Var args() As String
		  args.Add("--model")
		  args.Add(modelPath)
		  args.Add("--port")
		  args.Add(kServerPort)
		  args.Add("--host")
		  args.Add("127.0.0.1")
		  args.Add("--ctx-size")
		  args.Add(kContextSize.ToString)
		  // One conversation at a time: a single slot gets the full context and
		  // avoids the 4× KV-cache allocation of the server's default 4 slots.
		  args.Add("--parallel")
		  args.Add("1")
		  args.Add("-ngl")
		  args.Add("99")

		  mServerReady = False
		  mServerTask = New NSTaskMBS
		  mServerTask.launchPath = serverBin.NativePath
		  mServerTask.setArguments(args)

		  Var stdoutPipe As New NSPipeMBS
		  mServerTask.setStandardOutput(stdoutPipe)
		  mServerTask.setStandardError(stdoutPipe)
		  mServerTask.launch()

		  mServerStdoutHandle = stdoutPipe.fileHandleForReading
		  mServerStdoutObserver = New NSNotificationObserverMBS
		  AddHandler mServerStdoutObserver.GotNotification, AddressOf OnServerOutput
		  NSNotificationCenterMBS.defaultCenter.addObserver(mServerStdoutObserver, NSFileHandleMBS.NSFileHandleDataAvailableNotification, mServerStdoutHandle)
		  mServerStdoutHandle.waitForDataInBackgroundAndNotify

		  SendBackendState("loading", "")
		  StartHealthPolling
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function ModelsFolder() As FolderItem
		  Var models As FolderItem = Paths.AppSupport.Child("models")
		  If Not models.Exists Then models.CreateFolder
		  Return models
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnCrashCheckTimer(sender As Timer)
		  #Pragma Unused sender
		  If mServerReady Then Return
		  If mServerTask <> Nil And Not mServerTask.isRunning Then
		    App.AppendDebugLog("ModelManager: llama-server exited before becoming ready" + EndOfLine)
		    StopHealthPolling
		    SendBackendState("crashed", "")
		  End If
		End Sub
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

		  Catch e As RuntimeException
		    App.AppendDebugLog("ModelManager.OnFileReceived: move exception: " + e.Message + EndOfLine)
		    If Not final.Exists And backup.Exists Then
		      Try
		        backup.MoveFileTo(final)
		      Catch e2 As RuntimeException
		        App.AppendDebugLog("ModelManager.OnFileReceived: restore failed, previous model at " + backup.NativePath + EndOfLine)
		      End Try
		    End If
		    SendToJS("receiveDownloadDone(" + JSEscape(modelId) + ",false," + JSEscape(e.Message) + ");")
		  End Try
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnHealthError(sender As URLConnection, err As RuntimeException)
		  #Pragma Unused sender
		  #Pragma Unused err
		  // Connection refused — server socket not up yet. Keep polling; the
		  // 60 s grace cutoff lives in OnHealthTimer.
		  mHealthConn = Nil
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnHealthReceived(sender As URLConnection, url As String, httpStatus As Integer, content As String)
		  #Pragma Unused sender
		  #Pragma Unused url
		  #Pragma Unused content
		  mHealthConn = Nil
		  If httpStatus = 200 Then
		    mServerReady = True
		    StopHealthPolling
		    SendBackendState("ready", "")
		  End If
		  // 503 = model still loading — keep polling.
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnHealthTimer(sender As Timer)
		  If mServerReady Then
		    StopHealthPolling
		    Return
		  End If
		  mHealthElapsed = mHealthElapsed + (sender.Period / 1000)
		  If mHealthElapsed > kHealthGraceSeconds Then
		    StopHealthPolling
		    App.AppendDebugLog("ModelManager: server did not become healthy within " + kHealthGraceSeconds.ToString + "s" + EndOfLine)
		    SendBackendState("error", "Model failed to load — see debug log")
		    Return
		  End If
		  If mHealthConn <> Nil Then Return // previous probe still in flight
		  mHealthConn = New URLConnection
		  AddHandler mHealthConn.ContentReceived, AddressOf OnHealthReceived
		  AddHandler mHealthConn.Error, AddressOf OnHealthError
		  mHealthConn.Send("GET", BaseURL() + "/health")
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
		Private Sub OnServerOutput(observer As NSNotificationObserverMBS, notification As NSNotificationMBS)
		  #Pragma Unused observer
		  #Pragma Unused notification
		  If mServerStdoutHandle = Nil Then Return
		  Var data As MemoryBlock = mServerStdoutHandle.availableData
		  If data <> Nil And data.Size > 0 Then
		    Var line As String = DefineEncoding(data.StringValue(0, data.Size), Encodings.UTF8)
		    If Not mServerReady And (line.IndexOf("HTTP server listening") >= 0 Or line.IndexOf("server listening") >= 0) Then
		      // Socket is up; /health flips us to "ready" once the model is loaded.
		    End If
		    mServerStdoutHandle.waitForDataInBackgroundAndNotify
		  Else
		    // 0 bytes means EOF on the pipe — the write end closed, so the process
		    // has exited (or is about to). Do NOT re-arm
		    // waitForDataInBackgroundAndNotify here: EOF is permanent, so that
		    // would spin synchronously on the main thread. Instead give the process
		    // a brief grace period via a one-shot timer before reporting a crash.
		    If Not mServerReady Then
		      mCrashCheckTimer = New Timer
		      mCrashCheckTimer.Period = 500
		      mCrashCheckTimer.RunMode = Timer.RunModes.Single
		      AddHandler mCrashCheckTimer.Action, AddressOf OnCrashCheckTimer
		    End If
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ProbeExistingServer(expectedModelPath As String) As String
		  // A stale llama-server from a previous debug session can be left running
		  // on the server port. Starting a second instance against the same port
		  // always fails ("couldn't bind HTTP server socket"), which looks like a
		  // crash even though the original server is healthy. Probe /props first:
		  // nothing listening -> "none" (launch normally); a llama-server with the
		  // expected model -> "adopt" (reuse it); anything else -> a conflict
		  // message (don't launch a doomed instance, surface the conflict instead).
		  Var raw As String
		  Try
		    Var conn As New URLConnection
		    raw = conn.SendSync("GET", BaseURL() + "/props", 2)
		  Catch e As NetworkException
		    Return "none"
		  End Try

		  Try
		    Var props As New JSONItem(raw)
		    Var runningModel As String = props.Lookup("model_path", "").StringValue
		    If runningModel = "" Then
		      // Answers JSON on /props but doesn't name a model (llama-server
		      // versions differ in shape) — close enough to adopt
		      Return "adopt"
		    End If
		    If FileNameFromPath(runningModel) = FileNameFromPath(expectedModelPath) Then
		      Return "adopt"
		    End If
		    Return "Port " + kServerPort + " is used by another llama-server (model: " + FileNameFromPath(runningModel) + ")"
		  Catch e As RuntimeException
		    Return "Port " + kServerPort + " is used by another application"
		  End Try
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub SendBackendState(state As String, detail As String)
		  SendToJS("receiveBackendState(" + JSEscape(state) + "," + JSEscape(detail) + ");")
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
		Sub SaveSelectedModel(modelId As String)
		  DBHelper.SetMetadata("selected_model", modelId)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function SelectedModelId() As String
		  Return DBHelper.GetMetadata("selected_model")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function ServerReady() As Boolean
		  Return mServerReady
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StartServer(modelId As String)
		  If mServerTask <> Nil And mServerTask.isRunning Then Return

		  Var entry As JSONItem = FindCatalogEntry(modelId)
		  If entry = Nil Then
		    SendBackendState("no-model", "")
		    Return
		  End If
		  Var modelFi As FolderItem = ModelsFolder().Child(entry.Lookup("filename", ""))
		  If modelFi = Nil Or Not modelFi.Exists Then
		    SendBackendState("not-downloaded", modelId)
		    Return
		  End If
		  LaunchServer(modelFi.NativePath)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub StartHealthPolling()
		  mHealthElapsed = 0
		  If mHealthTimer = Nil Then
		    mHealthTimer = New Timer
		    mHealthTimer.Period = 3000
		    AddHandler mHealthTimer.Action, AddressOf OnHealthTimer
		  End If
		  mHealthTimer.RunMode = Timer.RunModes.Multiple
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub StopHealthPolling()
		  If mHealthTimer <> Nil Then
		    mHealthTimer.RunMode = Timer.RunModes.Off
		  End If
		  mHealthConn = Nil
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub StopServer()
		  StopHealthPolling
		  If mServerTask <> Nil And mServerTask.isRunning Then
		    mServerTask.terminate()
		  ElseIf mServerAdopted Then
		    // Adopted servers have no NSTaskMBS handle — kill by command line.
		    KillAdoptedServer(kServerPort)
		  End If
		  mServerAdopted = False
		  mServerTask = Nil
		  If mServerStdoutObserver <> Nil Then
		    NSNotificationCenterMBS.defaultCenter.removeObserver(mServerStdoutObserver)
		    mServerStdoutObserver = Nil
		  End If
		  mServerStdoutHandle = Nil
		  mServerReady = False
		End Sub
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
		  // Adoption additionally requires the rope-scaled 8192 context regime:
		  // vectors from a 2048-capped server live in a different embedding space,
		  // so a stale old-regime instance is killed and relaunched instead ("our
		  // model on our port" implies it is an orphan XDOX once started).
		  Var probe As String = ProbeExistingServerOn(EmbedBaseURL(), modelFi.NativePath)
		  If probe = "adopt" Then
		    If ProbeSlotCtx(EmbedBaseURL()) = 8192 Then
		      mEmbedAdopted = True
		      App.AppendDebugLog("ModelManager: adopted existing embedding server on port " + kEmbedPort + EndOfLine)
		      OnEmbedServerBecameReady
		      Return
		    End If
		    App.AppendDebugLog("ModelManager: stale embedding server runs the old 2048-token regime — replacing it" + EndOfLine)
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
		  // and a single input must fit the slot — one slot, full context (the
		  // server otherwise defaults to 4 slots sharing the budget).
		  // NB: these flags define the embedding space — changing them makes all
		  // stored vectors incompatible (full re-embed required).
		  args.Add("--ctx-size")
		  args.Add("8192")
		  args.Add("--batch-size")
		  args.Add("8192")
		  args.Add("--ubatch-size")
		  args.Add("8192")
		  args.Add("--parallel")
		  args.Add("1")
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
		    mEmbedCrashCheckTimer = New Timer
		    mEmbedCrashCheckTimer.Period = 500
		    mEmbedCrashCheckTimer.RunMode = Timer.RunModes.Single
		    AddHandler mEmbedCrashCheckTimer.Action, AddressOf OnEmbedCrashCheckTimer
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub OnEmbedCrashCheckTimer(sender As Timer)
		  #Pragma Unused sender
		  If mEmbedTask <> Nil And Not mEmbedTask.isRunning Then
		    App.AppendDebugLog("ModelManager: embedding server exited — semantic search degrades to keyword-only" + EndOfLine)
		  End If
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
		  mEmbedHealthConn = Nil
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
		Sub StopAllServers()
		  StopServer
		  StopEmbedServer
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

	#tag Method, Flags = &h0
		Sub SwitchModel(modelId As String)
		  // User picked a different model: persist, restart the server on it.
		  SaveSelectedModel(modelId)
		  StopServer
		  StartServer(modelId)
		  // Covers the first-run path where a chat model was already on disk and
		  // the user selected it without downloading anything.
		  EnsureEmbeddingModel
		End Sub
	#tag EndMethod


	#tag Property, Flags = &h21
		Private mCrashCheckTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mDownloads As Dictionary
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedAdopted As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mServerAdopted As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedHealthConn As URLConnection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedHealthElapsed As Double
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedHealthTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedReady As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedCrashCheckTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedStdoutHandle As NSFileHandleMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedStdoutObserver As NSNotificationObserverMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mEmbedTask As NSTaskMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHealthConn As URLConnection
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHealthElapsed As Double
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mHealthTimer As Timer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLastProgressTick As Double
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mServerReady As Boolean
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mServerStdoutHandle As NSFileHandleMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mServerStdoutObserver As NSNotificationObserverMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mServerTask As NSTaskMBS
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mStallTimer As Timer
	#tag EndProperty


	#tag Constant, Name = kContextSize, Type = Double, Dynamic = False, Default = \"8192", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kDownloadStallSeconds, Type = Double, Dynamic = False, Default = \"90", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kEmbedPort, Type = String, Dynamic = False, Default = \"8089", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kHFBase, Type = String, Dynamic = False, Default = \"https://huggingface.co", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kHealthGraceSeconds, Type = Double, Dynamic = False, Default = \"60", Scope = Private
	#tag EndConstant

	#tag Constant, Name = kServerPort, Type = String, Dynamic = False, Default = \"8091", Scope = Public
	#tag EndConstant


End Module
#tag EndModule
