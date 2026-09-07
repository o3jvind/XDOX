#tag Class
Public Class MBSDocsetParser

	#tag Method, Flags = &h0
		Function Parse(docsetFolder As FolderItem, progressDelegate As MBSParseProgressDelegate = Nil) As DocChunk()
		  // docsetFolder is the top-level "MBS.docset" bundle. docSet.dsidx (a
		  // small SQLite index Dash ships inside every docset) tells us every
		  // addressable member (name, type, path#anchor) — used here as a hint
		  // for which anchors are "real" members on files it references. It is
		  // NOT used to decide which files to parse: about a third of this
		  // docset's HTML files (e.g. DesktopWKWebViewControlMBS's own method
		  // pages) are never mentioned in the index at all despite containing
		  // real, well-structured content, so Parse enumerates every .html file
		  // in Documents/ directly. Unindexed files simply get an empty
		  // anchorSet, which ParseFile already treats as "trust every ItemTitle
		  // block found" (the same fallback the FAQ/Instruction bare-path case
		  // uses) rather than as "nothing here."
		  Var chunks() As DocChunk

		  Var docsFolder As FolderItem = docsetFolder.Child("Contents").Child("Resources").Child("Documents")
		  Var idxFile As FolderItem = docsetFolder.Child("Contents").Child("Resources").Child("docSet.dsidx")
		  If docsFolder = Nil Or Not docsFolder.Exists Or idxFile = Nil Or Not idxFile.Exists Then
		    App.AppendDebugLog("MBSDocsetParser: docSet.dsidx or Documents folder not found under " + docsetFolder.NativePath + EndOfLine)
		    Return chunks
		  End If

		  // Group anchors by their base HTML file so ParseFile can tell a real
		  // indexed member apart from a stray "ItemTitle"-shaped block elsewhere
		  // on a page that IS covered by the index.
		  //
		  // AtomicDictionaryMBS, not a plain Dictionary (2026-09-07): built
		  // once here, single-threaded, before any MBSParseWorker starts —
		  // but every ANCHOR SET inside it (and this outer map itself) is
		  // then READ concurrently by all System.CoreCount worker threads
		  // during ParseFile. Confirmed live that this was a genuine data
		  // race, not just theoretically risky: three consecutive single-
		  // worker (workerCount=1) reindexes of an unchanged docset all
		  // produced exactly 0 "new/updated" chunks, while 10-worker runs
		  // on the SAME unchanged docset consistently produced a nonzero,
		  // varying count (9 up to 259 across many runs) — i.e. some
		  // chunks' extracted text genuinely differed between runs whenever
		  // multiple preemptive threads read this structure at once. MBS's
		  // own Dictionary docs never claimed concurrent-read safety; this
		  // was an unverified assumption from earlier in this same session
		  // that turned out to be wrong. AtomicDictionaryMBS (MBS Util
		  // Plugin 26.3+) is purpose-built for exactly this "many threads
		  // read, one thread wrote it once up front" pattern.
		  Var anchorsByFile As New AtomicDictionaryMBS
		  Try
		    Var idx As New SQLiteDatabase
		    idx.DatabaseFile = idxFile
		    idx.Connect
		    Var rs As RowSet = idx.SelectSQL("SELECT path FROM searchIndex")
		    While Not rs.AfterLastRow
		      Var raw As String = rs.Column("path").StringValue
		      Var hashPos As Integer = raw.IndexOf("#")
		      Var basePath As String
		      Var anchor As String
		      If hashPos >= 0 Then
		        basePath = raw.Left(hashPos)
		        anchor = raw.Middle(hashPos + 1)
		      Else
		        basePath = raw
		        anchor = ""
		      End If
		      Var anchorSet As AtomicDictionaryMBS
		      If anchorsByFile.HasKey(basePath) Then
		        anchorSet = anchorsByFile.Value(basePath)
		      Else
		        anchorSet = New AtomicDictionaryMBS
		        anchorsByFile.Value(basePath) = anchorSet
		      End If
		      If anchor <> "" Then anchorSet.Value(anchor) = True
		      rs.MoveToNextRow
		    Wend
		    rs.Close
		    idx.Close
		  Catch e As DatabaseException
		    App.AppendDebugLog("MBSDocsetParser: could not read docSet.dsidx: " + e.Message + EndOfLine)
		    Return chunks
		  End Try

		  App.AppendDebugLog("MBSDocsetParser: " + anchorsByFile.KeyCount.ToString + " distinct HTML files referenced by index" + EndOfLine)

		  // FileListMBS instead of FolderItem.Children: MBS's own docs describe
		  // it as built specifically to list a folder's contents faster than
		  // FolderItem, which matters at this scale (~17,000 files) — FolderItem
		  // enumeration goes through a full per-item OS abstraction layer
		  // (alias resolution, permissions, etc.) that FileListMBS skips.
		  Var list As New FileListMBS(docsFolder)
		  If Not list.OK Then
		    App.AppendDebugLog("MBSDocsetParser: FileListMBS could not list " + docsFolder.NativePath + EndOfLine)
		    Return chunks
		  End If

		  Var emptyAnchorSet As New AtomicDictionaryMBS
		  Var htmlFiles() As FolderItem
		  Var htmlNames() As String
		  For i As Integer = 0 To list.Count - 1
		    If list.Directory(i) Then Continue
		    Var name As String = list.Name(i)
		    If name.Right(5) <> ".html" Then Continue
		    Var f As FolderItem = list.Item(i)
		    If f = Nil Then Continue
		    htmlFiles.Add(f)
		    htmlNames.Add(name)
		  Next

		  Var total As Integer = htmlFiles.Count
		  If progressDelegate <> Nil Then progressDelegate.MBSParseProgress(0, total)
		  If total = 0 Then
		    App.AppendDebugLog("MBSDocsetParser: produced 0 chunks from 0 files" + EndOfLine)
		    Return chunks
		  End If

		  // Pull-based queue instead of static contiguous slices: a fixed
		  // upfront split assumes every file costs the same to parse and
		  // every worker runs at the same speed. Neither holds in practice —
		  // this docset has "Sample" pages past 1MB alongside tiny ones, and
		  // Apple Silicon Macs mix faster performance cores with slower
		  // efficiency cores — so a static split reliably produced
		  // stragglers (observed: CPU falling from ~865% to ~100% near the
		  // end of a run while most workers sat idle). Pulling one file at a
		  // time means a worker that lands on big files, or one running on a
		  // slower core, simply pulls fewer files overall instead of
		  // blocking the others from finishing. See project-mbs-parsing-perf
		  // memory for the full history.
		  // 2026-09-07: confirmed live (three consecutive single-worker
		  // runs against a 2,143-file sample all produced 0 new/updated on
		  // repeat reindexes, vs. 111-154 at full 10-worker scale) that the
		  // residual content-hash instability documented in
		  // project-retrieval-quality-backlog IS caused by concurrent
		  // preemptive-thread parsing — a genuine race, not the
		  // DisambiguateSplitSources ordering issue (already fixed
		  // separately). Root cause not yet isolated further (leading
		  // suspicion: the anchorsByFile Dictionary shared read-only across
		  // all workers) — reverted back to System.CoreCount here since
		  // that diagnostic conclusion is what mattered, not keeping
		  // parsing single-threaded permanently (workerCount=1 undoes this
		  // session's ~7.7x parse-phase speedup). See that memory for the
		  // open investigation.
		  Var workerCount As Integer = System.CoreCount
		  If workerCount > total Then workerCount = total
		  If workerCount < 1 Then workerCount = 1

		  Var queue As New MBSFileQueue(htmlFiles, htmlNames)
		  Var workers() As MBSParseWorker
		  For w As Integer = 0 To workerCount - 1
		    Var worker As New MBSParseWorker
		    worker.Queue = queue
		    worker.AnchorsByFile = anchorsByFile
		    worker.EmptyAnchorSet = emptyAnchorSet
		    Var doneCount() As Integer
		    doneCount.Add(0)
		    worker.DoneCount = doneCount
		    workers.Add(worker)
		    worker.Start
		  Next

		  // No blocking Join exists for preemptive Threads — poll ThreadState
		  // instead. Safe to sleep this call's own thread (MBSIndexerThread)
		  // while waiting, since it isn't the main/UI thread. Progress is
		  // summed from each worker's own lock-free DoneCount(0) here, on
		  // this single polling thread, rather than workers each calling
		  // AddUserInterfaceUpdate themselves — see ParseFromQueue's comment
		  // for why the earlier CriticalSection-based shared counter was
		  // dropped.
		  Var allDone As Boolean = False
		  Var lastReported As Integer = -1
		  While Not allDone
		    allDone = True
		    Var sum As Integer = 0
		    For Each worker As MBSParseWorker In workers
		      sum = sum + worker.DoneCount(0)
		      If worker.ThreadState <> Thread.ThreadStates.NotRunning Then allDone = False
		    Next
		    If progressDelegate <> Nil And sum <> lastReported Then
		      progressDelegate.MBSParseProgress(sum, total)
		      lastReported = sum
		    End If
		    If Not allDone Then Thread.SleepCurrent(50)
		  Wend

		  Var unindexedCount As Integer = 0
		  For Each name As String In htmlNames
		    If Not anchorsByFile.HasKey(name) Then unindexedCount = unindexedCount + 1
		  Next

		  For Each worker As MBSParseWorker In workers
		    For Each c As DocChunk In worker.ResultChunks
		      chunks.Add(c)
		    Next
		    For Each line As String In worker.LogLines
		      App.AppendDebugLog(line + EndOfLine)
		    Next
		  Next

		  If progressDelegate <> Nil Then progressDelegate.MBSParseProgress(total, total)

		  App.AppendDebugLog("MBSDocsetParser: produced " + chunks.Count.ToString + " chunks from " + total.ToString _
		    + " files (" + unindexedCount.ToString + " not referenced by docSet.dsidx)" + EndOfLine)

		  Return chunks
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub ParseFromQueue(queue As MBSFileQueue, anchorsByFile As AtomicDictionaryMBS, emptyAnchorSet As AtomicDictionaryMBS, chunks() As DocChunk, logLines() As String, doneCount() As Integer)
		  // Entry point for a single MBSParseWorker — pulls one file at a
		  // time from the shared queue instead of iterating a pre-assigned
		  // slice, so a worker that lands on several large/slow files (or
		  // runs on a slower efficiency core) simply pulls fewer files
		  // overall rather than leaving other workers idle at the end. See
		  // MBSFileQueue and the Parse call site for the full rationale.
		  // ParseFile itself stays Private; this is the only new public
		  // surface needed to reuse it.
		  //
		  // doneCount is a 1-element array used as a mutable box — Xojo
		  // arrays are passed by reference, so the owner (Parse) can poll
		  // doneCount(0) from its own wait loop without any shared lock. This
		  // replaces an earlier ParseProgressCounter (CriticalSection-backed)
		  // design that crashed live, 2026-08-30: with System.CoreCount (10 on
		  // the test machine) preemptive MBSParseWorkers all calling
		  // CriticalSection.Enter within the same few milliseconds of Start,
		  // Xojo's own runtime threw "Cannot enter a cooperative CriticalSection
		  // in a preemptive thread" on a SUBSET of workers even though a
		  // temporary diagnostic confirmed the lock's own .Type read back as
		  // Preemptive on every call right up until the failures — a real race
		  // in Xojo's CriticalSection internals under a burst of near-
		  // simultaneous first-time preemptive Enter calls, not a bug in this
		  // code. Since per-file progress isn't correctness-critical (unlike
		  // ResultChunks, which stays worker-local and lock-free by design
		  // already), removing the shared lock entirely sidesteps the race
		  // rather than trying to work around unclear runtime behavior. The
		  // queue's own CriticalSection (a NEW shared lock, unlike this one)
		  // is a deliberate, narrower re-introduction — see MBSFileQueue.
		  Var f As FolderItem
		  Var name As String
		  While queue.TryTakeNext(f, name)
		    Var anchorSet As AtomicDictionaryMBS
		    If anchorsByFile.HasKey(name) Then
		      anchorSet = anchorsByFile.Value(name)
		    Else
		      anchorSet = emptyAnchorSet
		    End If

		    Try
		      ParseFile(f, anchorSet, chunks)
		    Catch e As RuntimeException
		      // One malformed page must not sink the other ~17,000 — skip it and
		      // keep going. (An InvalidArgumentException from a numeric-entity
		      // edge case has already been hit and fixed once; this is the
		      // backstop for whatever the next one turns out to be.)
		      logLines.Add("MBSDocsetParser: skipping " + name + " after exception: " + e.Message)
		    End Try

		    doneCount(0) = doneCount(0) + 1
		  Wend
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ParseFile(f As FolderItem, anchorSet As AtomicDictionaryMBS, chunks() As DocChunk)
		  // Each documented member on a page lives in "<p class=ItemTitle>...
		  // </p>" followed by a description and a platform-availability table,
		  // up to the next ItemTitle (or end of the tagged block). Pages with no
		  // ItemTitle at all (FAQ answers, whole-class overviews, examples) are
		  // emitted as one chunk for the whole content div instead.
		  Var html As String
		  Try
		    Var stream As TextInputStream = TextInputStream.Open(f)
		    stream.Encoding = Encodings.UTF8
		    html = stream.ReadAll
		    stream.Close
		  Catch e As IOException
		    App.AppendDebugLog("MBSDocsetParser: cannot read " + f.NativePath + ": " + e.Message + EndOfLine)
		    Return
		  End Try

		  Var contentStart As Integer = ContentStartPosition(html)

		  Var titlePositions() As Integer
		  Var searchFrom As Integer = contentStart
		  Do
		    Var pos As Integer = html.IndexOf(searchFrom, "<p class=ItemTitle>")
		    If pos < 0 Then Exit
		    titlePositions.Add(pos)
		    searchFrom = pos + 19 // past the needle — avoids rematching the same spot
		  Loop

		  If titlePositions.Count = 0 Then
		    EmitWholePageChunk(f, html, chunks)
		    Return
		  End If

		  Var bodyEnd As Integer = BodyEndPosition(html)
		  For ti As Integer = 0 To titlePositions.LastIndex
		    Var segStart As Integer = titlePositions(ti)
		    Var segEnd As Integer
		    If ti < titlePositions.LastIndex Then
		      segEnd = titlePositions(ti + 1)
		    Else
		      segEnd = bodyEnd
		    End If
		    If segEnd <= segStart Then Continue
		    Var segment As String = html.Middle(segStart, segEnd - segStart)

		    // Only emit segments whose anchor is one the index actually lists for
		    // this file — guards against stray "ItemTitle" blocks (e.g. inside an
		    // unrelated inline example) that don't correspond to an indexed
		    // member. Pages whose dsidx entry is a bare path with no #anchor at
		    // all (FAQ/Instruction pages: the index lists the page once, but the
		    // page itself still tags its single answer with a named anchor) have
		    // an empty anchorSet — there's nothing to filter against, so every
		    // ItemTitle block found is trusted rather than rejected outright.
		    If anchorSet.KeyCount > 0 Then
		      Var anchorName As String = FirstAnchorName(segment)
		      If anchorName = "" Or Not anchorSet.HasKey(anchorName) Then Continue
		    End If

		    Var titleEnd As Integer = segment.IndexOf("</p>")
		    If titleEnd < 0 Then Continue
		    Var titleHTML As String = segment.Left(titleEnd)
		    Var title As String = CleanText(StripTags(titleHTML))
		    If title = "" Then Continue

		    Var chunk As New DocChunk
		    chunk.Title = title
		    chunk.Source = DBHelper.kMBSSourcePrefix + title
		    chunk.ChunkText = CleanText(StripTags(RewriteFunctionHeaderTables(segment)))
		    If chunk.ChunkText = "" Then Continue
		    chunks.Add(chunk)
		  Next
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub EmitWholePageChunk(f As FolderItem, html As String, chunks() As DocChunk)
		  // Pages with no per-member ItemTitle blocks (FAQ answers, class
		  // overviews, "New in version N" release notes, example project dumps).
		  // Titled from <H2>/<TITLE> since there's no ItemTitle to draw one from.
		  Var title As String = ExtractPageTitle(html)
		  If title = "" Then title = f.Name

		  Var bodyStart As Integer = ContentStartPosition(html)
		  Var bodyEnd As Integer = BodyEndPosition(html)
		  Var body As String = html.Middle(bodyStart, bodyEnd - bodyStart)

		  Var text As String = CleanText(StripTags(RewriteFunctionHeaderTables(body)))
		  If text = "" Then Return

		  Var chunk As New DocChunk
		  chunk.Title = title
		  chunk.Source = DBHelper.kMBSSourcePrefix + title
		  chunk.ChunkText = text
		  chunks.Add(chunk)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ExtractPageTitle(html As String) As String
		  Var h2Start As Integer = html.IndexOf("<H2")
		  If h2Start >= 0 Then
		    Var tagEnd As Integer = html.IndexOf(h2Start, ">")
		    Var closeStart As Integer = html.IndexOf(h2Start, "</h2>")
		    If closeStart < 0 Then closeStart = html.IndexOf(h2Start, "</H2>")
		    If tagEnd >= 0 And closeStart > tagEnd Then
		      Return CleanText(StripTags(html.Middle(tagEnd + 1, closeStart - tagEnd - 1)))
		    End If
		  End If

		  Var titleStart As Integer = html.IndexOf("<TITLE>")
		  If titleStart >= 0 Then
		    Var titleClose As Integer = html.IndexOf(titleStart, "</TITLE>")
		    If titleClose > titleStart Then
		      Var raw As String = html.Middle(titleStart + 7, titleClose - titleStart - 7)
		      raw = CleanText(StripTags(raw))
		      // Strip the "Monkeybread Xojo plugin - " prefix every page's <TITLE> carries.
		      Var dashPos As Integer = raw.IndexOf(" - ")
		      If dashPos >= 0 Then Return raw.Middle(dashPos + 3)
		      Return raw
		    End If
		  End If
		  Return ""
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function RewriteFunctionHeaderTables(html As String) As String
		  // Every member's doc block carries a "FunctionHeaderTable": a header
		  // row (Type, Topic, Plugin, Version, macOS, Windows, Linux, iOS,
		  // Targets) and one value row (e.g. event, WebKit2, MBS Mac64bit
		  // Plugin, 21.5, Yes, No, No, No, Desktop only). StripTags has no
		  // notion of table structure, so left alone this linearizes into two
		  // side-by-side runs of words with no header-to-value pairing —
		  // "Type" ends up nowhere near "event" in the stripped text, so a
		  // reader (human or LLM) can no longer tell whether a given member is
		  // a method, property, or event. Rewriting it here into "Type: event"
		  // / "Plugin: MBS Mac64bit Plugin" style lines, BEFORE the general
		  // StripTags pass, keeps that pairing intact.
		  Var htmlLower As String = html.Lowercase
		  Var parts() As String
		  Var searchFrom As Integer = 0
		  Do
		    Var tablePos As Integer = htmlLower.IndexOf(searchFrom, "<table")
		    If tablePos < 0 Then Exit
		    Var tableOpenEnd As Integer = html.IndexOf(tablePos, ">")
		    If tableOpenEnd < 0 Then Exit
		    Var tableTag As String = htmlLower.Middle(tablePos, tableOpenEnd - tablePos)
		    Var tableCloseTagPos As Integer = htmlLower.IndexOf(tableOpenEnd, "</table>")
		    If tableCloseTagPos < 0 Then Exit
		    Var tableCloseEnd As Integer = tableCloseTagPos + 8 // len("</table>")

		    If tableTag.IndexOf("functionheadertable") < 0 Then
		      searchFrom = tableCloseEnd
		      Continue
		    End If

		    If tablePos > searchFrom Then parts.Add(html.Middle(searchFrom, tablePos - searchFrom))
		    Var tableInner As String = html.Middle(tableOpenEnd + 1, tableCloseTagPos - tableOpenEnd - 1)
		    parts.Add(FormatFunctionHeaderTable(tableInner))
		    searchFrom = tableCloseEnd
		  Loop
		  If searchFrom < html.Length Then parts.Add(html.Middle(searchFrom, html.Length - searchFrom))
		  Return Join(parts, "")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function FormatFunctionHeaderTable(tableInner As String) As String
		  // tableInner holds exactly two <tr> rows: header cell names, then
		  // this member's values, in the same column order. Cells can contain
		  // nested tags (e.g. <a href=...>WebKit2</a>) and entities, so each
		  // cell is run through the same StripTags/DecodeEntities used for
		  // everything else rather than assuming plain text.
		  Var rows() As String
		  Var lowerInner As String = tableInner.Lowercase
		  Var searchFrom As Integer = 0
		  Do
		    Var trStart As Integer = lowerInner.IndexOf(searchFrom, "<tr")
		    If trStart < 0 Then Exit
		    Var trOpenEnd As Integer = tableInner.IndexOf(trStart, ">")
		    If trOpenEnd < 0 Then Exit
		    Var trCloseStart As Integer = lowerInner.IndexOf(trOpenEnd, "</tr>")
		    If trCloseStart < 0 Then Exit
		    rows.Add(tableInner.Middle(trOpenEnd + 1, trCloseStart - trOpenEnd - 1))
		    searchFrom = trCloseStart + 5 // len("</tr>")
		  Loop
		  If rows.Count < 2 Then Return ""

		  Var headers() As String = ExtractCells(rows(0))
		  Var values() As String = ExtractCells(rows(1))

		  Var lines() As String
		  Var n As Integer = headers.Count
		  If values.Count < n Then n = values.Count
		  For i As Integer = 0 To n - 1
		    If values(i) = "" Then Continue
		    lines.Add(headers(i) + ": " + values(i))
		  Next
		  If lines.Count = 0 Then Return ""
		  Return Chr(10) + Join(lines, Chr(10)) + Chr(10)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ExtractCells(rowHTML As String) As String()
		  Var cells() As String
		  Var lowerRow As String = rowHTML.Lowercase
		  Var searchFrom As Integer = 0
		  Do
		    Var tdStart As Integer = lowerRow.IndexOf(searchFrom, "<td")
		    If tdStart < 0 Then Exit
		    Var tdOpenEnd As Integer = rowHTML.IndexOf(tdStart, ">")
		    If tdOpenEnd < 0 Then Exit
		    Var tdCloseStart As Integer = lowerRow.IndexOf(tdOpenEnd, "</td>")
		    If tdCloseStart < 0 Then Exit
		    Var cellHTML As String = rowHTML.Middle(tdOpenEnd + 1, tdCloseStart - tdOpenEnd - 1)
		    cells.Add(CleanText(StripTags(cellHTML)).ReplaceAllBytes(Chr(10), " "))
		    searchFrom = tdCloseStart + 5 // len("</td>")
		  Loop
		  Return cells
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ContentStartPosition(html As String) As Integer
		  // Every page in the docset repeats the same nav/header boilerplate
		  // (Online Documentation links, version-history links, platform
		  // chooser) before the real content begins. PlatformChooserMBS's
		  // closing </p> is the one marker common to all page types, so
		  // skipping to just after it keeps chunks free of that repeated noise.
		  Var p As Integer = html.IndexOf("PlatformChooserMBS")
		  If p < 0 Then Return 0
		  Var closeP As Integer = html.IndexOf(p, "</p>")
		  If closeP < 0 Then Return 0
		  Return closeP + 4
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function BodyEndPosition(html As String) As Integer
		  Var p As Integer = html.IndexOf("</BODY>")
		  If p < 0 Then p = html.IndexOf("</body>")
		  If p < 0 Then p = html.Length
		  Return p
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function FirstAnchorName(segment As String) As String
		  // Looks for name="f1" (or name='f1' — quote style varies across pages).
		  Var doubleQuote As String = Chr(34)
		  Var p As Integer = segment.IndexOf("name=" + doubleQuote)
		  Var quote As String = doubleQuote
		  If p < 0 Then
		    p = segment.IndexOf("name='")
		    quote = "'"
		  End If
		  If p < 0 Then Return ""
		  Var startPos As Integer = p + 6
		  Var endPos As Integer = segment.IndexOf(startPos, quote)
		  If endPos < 0 Then Return ""
		  Return segment.Middle(startPos, endPos - startPos)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function StripTags(html As String) As String
		  // Hand-rolled, single-pass tag stripper — no external HTML parser is
		  // available in pure Xojo, and this content is small/regular enough
		  // (Dash-generated, no scripts inside content divs) not to need one.
		  // <script>/<style> bodies are dropped entirely, not just their tags,
		  // since platforms.js snippets would otherwise leak into chunk text.
		  //
		  // Collects whole plain-text runs (via Middle slices) between tags
		  // instead of "result = result + ch" per character — repeated
		  // concatenation onto one growing string is O(n^2) and made the
		  // largest docset pages (Sample pages run past 1 MB) effectively hang.
		  // Tag starts are found with IndexOf rather than a per-character
		  // Middle(i,1) scan for the same reason — Middle on a multi-megabyte
		  // string is not free, and calling it once per character is its own
		  // O(n^2). A single lowercased copy of html is computed once up front
		  // so a <script>/<style> tag doesn't re-lowercase the whole string.
		  //
		  // <a href>, <pre>, and <div class="RB_Code"> get special handling
		  // (2026-09-06) instead of being flattened to plain text — see each
		  // block below for why. Everything else in this loop is unchanged.
		  Var htmlLower As String = html.Lowercase
		  Var parts() As String
		  Var n As Integer = html.Length
		  Var plainStart As Integer = 0
		  Var i As Integer = html.IndexOf(0, "<")
		  While i >= 0 And i < n
		    If i > plainStart Then parts.Add(html.Middle(plainStart, i - plainStart))

		    Var tagEnd As Integer = html.IndexOf(i, ">")
		    If tagEnd < 0 Then Exit
		    Var tag As String = htmlLower.Middle(i + 1, tagEnd - i - 1)
		    If tag.BeginsWith("script") Or tag.BeginsWith("style") Then
		      Var closePos As Integer = htmlLower.IndexOf(tagEnd, "</script>")
		      Var closePos2 As Integer = htmlLower.IndexOf(tagEnd, "</style>")
		      If closePos >= 0 And (closePos2 < 0 Or closePos < closePos2) Then
		        plainStart = closePos + 9
		      ElseIf closePos2 >= 0 Then
		        plainStart = closePos2 + 8
		      Else
		        plainStart = tagEnd + 1
		      End If
		      i = html.IndexOf(plainStart, "<")
		      Continue
		    End If

		    // <a href="..."> ... </a> → markdown [text](url) instead of the
		    // href being silently discarded. A relative in-docset link (e.g.
		    // "class-foo.html" or "datatypes-foo-method.html#c2") is NOT
		    // dropped — confirmed live (2026-09-06) that MBS's real online
		    // docs mirror the Dash docset's own file names 1:1: fetching
		    // "https://www.monkeybreadsoftware.net/" + the exact relative
		    // href resolves to the equivalent live page for every pattern
		    // tried (class-*.html, datatypes-*-method.html, faq-*.html).
		    // RewriteRelativeHref does that rewrite (dropping any #anchor —
		    // MBS's own site isn't guaranteed to use the same anchor names
		    // as this Dash docset, and landing on the right PAGE without
		    // the exact anchor is still far better than no link at all).
		    // http(s) hrefs are used as-is. Either way the result still
		    // passes through the same http(s)-only allowlist independently
		    // enforced on both the JS side (sanitize.js's isSafeHref) and
		    // the Xojo side (ChatView.openURL) — those gates are unaffected
		    // by this change, they just now actually see a URL for what
		    // used to be a silently-dropped relative href.
		    If tag.BeginsWith("a ") Or tag = "a" Then
		      Var hrefURL As String = RewriteRelativeHref(ExtractAttr(html, i, tagEnd, "href"))
		      Var aCloseStart As Integer = htmlLower.IndexOf(tagEnd, "</a>")
		      If aCloseStart < 0 Then
		        plainStart = tagEnd + 1
		        i = html.IndexOf(plainStart, "<")
		        Continue
		      End If
		      Var linkText As String = ExtractInlineText(html.Middle(tagEnd + 1, aCloseStart - tagEnd - 1))
		      If (hrefURL.Lowercase.BeginsWith("http://") Or hrefURL.Lowercase.BeginsWith("https://")) And linkText <> "" Then
		        parts.Add("[" + linkText + "](" + hrefURL + ")")
		      Else
		        parts.Add(linkText)
		      End If
		      plainStart = aCloseStart + 4 // len("</a>")
		      i = html.IndexOf(plainStart, "<")
		      Continue
		    End If

		    // <pre>...</pre> → a markdown fenced code block. MBS's <pre>
		    // blocks use <br /> for line breaks (not real newlines) and wrap
		    // syntax-highlighting <span> runs around individual tokens —
		    // ExtractInlineText's OWN inner loop (not this outer one) turns
		    // <br> into Chr(10) and drops the <span> tags while keeping
		    // their text, so nested tags never reach this outer loop at all.
		    If tag = "pre" Then
		      Var preCloseStart As Integer = htmlLower.IndexOf(tagEnd, "</pre>")
		      If preCloseStart < 0 Then
		        plainStart = tagEnd + 1
		        i = html.IndexOf(plainStart, "<")
		        Continue
		      End If
		      Var codeText As String = ExtractInlineText(html.Middle(tagEnd + 1, preCloseStart - tagEnd - 1))
		      If codeText.Trim <> "" Then
		        parts.Add(Chr(10) + "```" + Chr(10) + codeText + Chr(10) + "```" + Chr(10))
		      End If
		      plainStart = preCloseStart + 6 // len("</pre>")
		      i = html.IndexOf(plainStart, "<")
		      Continue
		    End If

		    // <div class="RB_Code">...</div> is MBS's OTHER code-example
		    // format (whole embedded Sample projects, one div per source
		    // line — no <pre> involved at all). RB_MainItem sibling divs are
		    // pure indentation wrappers with no text of their own; each
		    // RB_Code div's own leading tabs already carry the indentation,
		    // so RB_MainItem needs no special handling beyond the existing
		    // "/div → newline" rule below. A whole RUN of consecutive
		    // RB_Code/RB_MainItem divs is collected into ONE fenced block
		    // (not one block per line) — ConsumeCodeDivRun scans forward
		    // from here and returns how far it got.
		    If tag = "div class=" + Chr(34) + "rb_code" + Chr(34) Or tag = "div class=" + Chr(34) + "rb_mainitem" + Chr(34) Then
		      Var consumed As Pair = ConsumeCodeDivRun(html, htmlLower, i)
		      Var blockText As String = consumed.Left
		      Var afterPos As Integer = consumed.Right
		      If blockText.Trim <> "" Then
		        parts.Add(Chr(10) + "```" + Chr(10) + blockText + Chr(10) + "```" + Chr(10))
		      End If
		      plainStart = afterPos
		      i = html.IndexOf(plainStart, "<")
		      Continue
		    End If

		    // Block-level tags become a newline so stripped text keeps some
		    // structure (paragraph/row breaks) instead of one run-on line.
		    If tag.BeginsWith("br") Or tag.BeginsWith("/p") Or tag.BeginsWith("/tr") _
		      Or tag.BeginsWith("/div") Or tag.BeginsWith("/h") Or tag.BeginsWith("/li") Then
		      parts.Add(Chr(10))
		    End If
		    plainStart = tagEnd + 1
		    i = html.IndexOf(plainStart, "<")
		  Wend
		  If n > plainStart Then parts.Add(html.Middle(plainStart, n - plainStart))
		  Return Join(parts, "")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ExtractAttr(html As String, tagStart As Integer, tagEnd As Integer, attrName As String) As String
		  // Reads attrName="value" from within html.Middle(tagStart, tagEnd-tagStart)
		  // — the opening-tag text only, never searched past tagEnd, so a
		  // same-named attribute inside the tag's own CONTENT (e.g. an <a>
		  // whose text happens to contain the word href="...") can't be
		  // mismatched. MBS's docset consistently double-quotes attributes;
		  // no single-quote fallback is needed here (unlike FirstAnchorName,
		  // which reads Dash's own generated anchor markup and does see both
		  // styles).
		  Var needle As String = attrName + "=" + Chr(34)
		  Var searchIn As String = html.Middle(tagStart, tagEnd - tagStart).Lowercase
		  Var p As Integer = searchIn.IndexOf(needle)
		  If p < 0 Then Return ""
		  Var valueStart As Integer = tagStart + p + needle.Length
		  Var valueEnd As Integer = html.IndexOf(valueStart, Chr(34))
		  If valueEnd < 0 Then Return ""
		  Return html.Middle(valueStart, valueEnd - valueStart)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function RewriteRelativeHref(hrefValue As String) As String
		  // A bare "xxx.html" or "xxx.html#anchor" relative href — the shape
		  // every in-docset content link in this docset actually takes (only
		  // ../*.css stylesheet references use a "../" path, and those never
		  // appear inside an <a> tag to begin with, only <link>, which
		  // StripTags never visits as visible content) — maps 1:1 onto a
		  // real page at MBS's own online docs site, confirmed live
		  // (2026-09-06) by fetching the equivalent URL for several
		  // different filename patterns (class-*.html, datatypes-*-method.
		  // html, faq-*.html) and getting the matching page back each time.
		  // The #anchor (if any) is dropped rather than carried over — MBS's
		  // live site isn't guaranteed to use the same per-member anchor
		  // names as this Dash docset's own generated markup, and landing
		  // on the right PAGE without the exact anchor beats no link.
		  //
		  // Anything else (already http(s), empty, or NOT of this exact
		  // "plain filename, no further path" shape — e.g. an unexpected
		  // "../" prefix or a query string, neither seen in this docset but
		  // not proven impossible) is returned unchanged and left to the
		  // caller's existing http(s)-only check, same as before this
		  // rewrite existed — this function only ever WIDENS what resolves
		  // to a URL, it never narrows the prior behavior.
		  If hrefValue = "" Then Return hrefValue
		  Var lower As String = hrefValue.Lowercase
		  If lower.BeginsWith("http://") Or lower.BeginsWith("https://") Then Return hrefValue
		  If hrefValue.IndexOf("/") >= 0 Then Return hrefValue // "../foo.css" etc. — not a bare filename
		  Var hashPos As Integer = hrefValue.IndexOf("#")
		  Var fileName As String = hrefValue
		  If hashPos >= 0 Then fileName = hrefValue.Left(hashPos)
		  If Not fileName.Lowercase.EndsWith(".html") Then Return hrefValue
		  Return "https://www.monkeybreadsoftware.net/" + fileName
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ExtractInlineText(html As String) As String
		  // Strips tags from a SMALL fragment already isolated by the caller
		  // (an <a> or <pre> body) — same run-slicing approach as StripTags
		  // itself, just without needing script/style/link/code awareness
		  // since a fragment this size never contains another one of those.
		  // <br> becomes a real newline (not a Chr(10)-then-collapsed-by-
		  // CleanText round trip) so <pre>'s line breaks survive intact
		  // through to the fenced code block built by the caller.
		  Var htmlLower As String = html.Lowercase
		  Var parts() As String
		  Var n As Integer = html.Length
		  Var plainStart As Integer = 0
		  Var i As Integer = html.IndexOf(0, "<")
		  While i >= 0 And i < n
		    If i > plainStart Then parts.Add(html.Middle(plainStart, i - plainStart))
		    Var tagEnd As Integer = html.IndexOf(i, ">")
		    If tagEnd < 0 Then Exit
		    Var tag As String = htmlLower.Middle(i + 1, tagEnd - i - 1)
		    If tag.BeginsWith("br") Then parts.Add(Chr(10))
		    plainStart = tagEnd + 1
		    i = html.IndexOf(plainStart, "<")
		  Wend
		  If n > plainStart Then parts.Add(html.Middle(plainStart, n - plainStart))
		  Return DecodeEntities(Join(parts, ""))
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ConsumeCodeDivRun(html As String, htmlLower As String, startPos As Integer) As Pair
		  // Called at the START of a run of consecutive <div class="RB_Code">
		  // / <div class="RB_MainItem"> divs (MBS's whole-Sample-project code
		  // format — one div per source line, RB_MainItem divs are pure
		  // indentation wrappers with no text of their own). Collects every
		  // RB_Code div's own text (its leading tabs already carry the
		  // indentation) as one line each, skips over RB_MainItem's open/
		  // close tags without emitting anything for them, and stops at the
		  // first tag that is NEITHER of those two — so the whole nested run
		  // becomes ONE fenced code block instead of one block per line, and
		  // control correctly returns to StripTags' own loop right after the
		  // run ends (never past it — the closing "outer" </div> that ends
		  // the run is left for StripTags' normal /div handling to consume).
		  //
		  // Returns a Pair: Left = the collected code text, Right = the html
		  // index to resume StripTags' own scan from.
		  Var lines() As String
		  Var pos As Integer = startPos
		  Do
		    Var tagEnd As Integer = html.IndexOf(pos, ">")
		    If tagEnd < 0 Then Exit
		    Var tag As String = htmlLower.Middle(pos + 1, tagEnd - pos - 1)

		    If tag = "div class=" + Chr(34) + "rb_mainitem" + Chr(34) Then
		      pos = tagEnd + 1
		      Var nextLt As Integer = html.IndexOf(pos, "<")
		      If nextLt < 0 Then Exit
		      pos = nextLt
		      Continue
		    End If

		    If tag = "/div" Then
		      // Closes either an RB_MainItem wrapper (skip, keep scanning —
		      // there may be more RB_Code siblings after it) or, if nothing
		      // RB_Code-shaped follows, the outer container that ends this
		      // whole run (stop, leave this </div> for StripTags to handle).
		      pos = tagEnd + 1
		      Var nextLt As Integer = html.IndexOf(pos, "<")
		      If nextLt < 0 Then Return New Pair(Join(lines, Chr(10)), pos)
		      Var peekEnd As Integer = html.IndexOf(nextLt, ">")
		      If peekEnd < 0 Then Return New Pair(Join(lines, Chr(10)), pos)
		      Var peekTag As String = htmlLower.Middle(nextLt + 1, peekEnd - nextLt - 1)
		      If peekTag = "div class=" + Chr(34) + "rb_code" + Chr(34) Or peekTag = "div class=" + Chr(34) + "rb_mainitem" + Chr(34) Then
		        pos = nextLt
		        Continue
		      End If
		      Return New Pair(Join(lines, Chr(10)), pos)
		    End If

		    If tag = "div class=" + Chr(34) + "rb_code" + Chr(34) Then
		      Var lineCloseStart As Integer = htmlLower.IndexOf(tagEnd, "</div>")
		      If lineCloseStart < 0 Then Return New Pair(Join(lines, Chr(10)), tagEnd + 1)
		      lines.Add(ExtractInlineText(html.Middle(tagEnd + 1, lineCloseStart - tagEnd - 1)))
		      pos = lineCloseStart + 6 // len("</div>")
		      Var nextLt As Integer = html.IndexOf(pos, "<")
		      If nextLt < 0 Then Return New Pair(Join(lines, Chr(10)), pos)
		      pos = nextLt
		      Continue
		    End If

		    // Anything else ends the run — leave it for StripTags' own loop.
		    Return New Pair(Join(lines, Chr(10)), pos)
		  Loop
		  Return New Pair(Join(lines, Chr(10)), pos)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function CleanText(s As String) As String
		  s = DecodeEntities(s)
		  // Collapse runs of blank/whitespace-only lines and trailing spaces —
		  // StripTags emits one newline per block tag, which over a dense table
		  // produces long stretches of empty lines.
		  //
		  // Lines inside a ``` fenced block (StripTags' <pre>/RB_Code handling,
		  // 2026-09-06) are passed through UNTRIMMED — collapsing each line's
		  // leading whitespace here would strip the indentation those blocks
		  // exist specifically to preserve, and a code block's blank lines are
		  // meaningful (paragraph breaks inside a listing) rather than
		  // structural noise the way a dense HTML table's are. The blank-run
		  // collapse rule above is still exactly right for everything OUTSIDE
		  // a fence, so it only gets skipped while inFence is True.
		  Var lines() As String = s.Split(Chr(10))
		  Var result() As String
		  Var blankRun As Boolean = False
		  Var inFence As Boolean = False
		  For Each line As String In lines
		    If line.Trim = "```" Then
		      result.Add(line.Trim)
		      inFence = Not inFence
		      blankRun = False
		      Continue
		    End If
		    If inFence Then
		      result.Add(line)
		      Continue
		    End If
		    Var trimmed As String = line.Trim
		    If trimmed = "" Then
		      If Not blankRun And result.Count > 0 Then result.Add("")
		      blankRun = True
		    Else
		      result.Add(trimmed)
		      blankRun = False
		    End If
		  Next
		  While result.Count > 0 And result(result.LastIndex) = ""
		    result.RemoveAt(result.LastIndex)
		  Wend
		  Return Join(result, Chr(10)).Trim
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function DecodeEntities(s As String) As String
		  // ReplaceAllBytes instead of ReplaceAll: both sides of every one of
		  // these replacements are fixed ASCII (entity names never appear in
		  // any other case in this docset), so byte-level replacement is safe
		  // and — per Xojo forum reports — measurably faster than ReplaceAll's
		  // Unicode-aware scan, especially across this many calls per chunk.
		  s = s.ReplaceAllBytes("&nbsp;", " ")
		  s = s.ReplaceAllBytes("&amp;", "&")
		  s = s.ReplaceAllBytes("&lt;", "<")
		  s = s.ReplaceAllBytes("&gt;", ">")
		  s = s.ReplaceAllBytes("&quot;", """")
		  s = s.ReplaceAllBytes("&#39;", "'")
		  s = s.ReplaceAllBytes("&rsquo;", "'")
		  s = s.ReplaceAllBytes("&lsquo;", "'")
		  s = s.ReplaceAllBytes("&rdquo;", """")
		  s = s.ReplaceAllBytes("&ldquo;", """")
		  s = s.ReplaceAllBytes("&mdash;", "-")
		  s = s.ReplaceAllBytes("&ndash;", "-")

		  // Numeric entities: &#NNNN; (decimal). The docset uses these for
		  // check/cross marks (&#9989; &#10060;) and any other odd symbol.
		  // Same run-slicing + IndexOf approach as StripTags — no per-character
		  // Middle/"+=" scan, which is its own O(n^2) on large chunks.
		  Var parts() As String
		  Var n As Integer = s.Length
		  Var plainStart As Integer = 0
		  Var i As Integer = s.IndexOf(0, "&#")
		  While i >= 0 And i < n
		    Var semiPos As Integer = s.IndexOf(i, ";")
		    If semiPos > i And semiPos - i <= 10 Then
		      Var numStr As String = s.Middle(i + 2, semiPos - i - 2)
		      // IsDigitsOnly guards Integer.FromString, which throws (rather than
		      // returning 0) on non-numeric input — and "&#" followed by
		      // something that isn't actually a numeric entity (hex &#xNN;, or
		      // just a stray "&#" in unrelated text within 10 chars of a ";")
		      // does turn up in these docset pages.
		      Var code As Integer = 0
		      If IsDigitsOnly(numStr) Then code = Integer.FromString(numStr)
		      If code > 0 Then
		        If i > plainStart Then parts.Add(s.Middle(plainStart, i - plainStart))
		        parts.Add(Encodings.UTF8.Chr(code))
		        plainStart = semiPos + 1
		        i = s.IndexOf(plainStart, "&#")
		        Continue
		      End If
		    End If
		    i = s.IndexOf(i + 1, "&#")
		  Wend
		  If n > plainStart Then parts.Add(s.Middle(plainStart, n - plainStart))
		  Return Join(parts, "")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsDigitsOnly(s As String) As Boolean
		  If s = "" Then Return False
		  For i As Integer = 0 To s.Length - 1
		    Var ch As String = s.Middle(i, 1)
		    If ch < "0" Or ch > "9" Then Return False
		  Next
		  Return True
		End Function
	#tag EndMethod

End Class
#tag EndClass
