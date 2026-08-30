#tag Class
Public Class RSTParser

	#tag Method, Flags = &h0
		Function Parse(llmsFullPath As FolderItem) As DocChunk()
		  Var chunks() As DocChunk

		  If llmsFullPath = Nil Or Not llmsFullPath.Exists Then
		    Return chunks
		  End If

		  Var stream As TextInputStream
		  Try
		    stream = TextInputStream.Open(llmsFullPath)
		  Catch e As IOException
		    App.AppendDebugLog("RSTParser: Cannot open " + llmsFullPath.NativePath + ": " + e.Message + EndOfLine)
		    Return chunks
		  End Try

		  Var lines() As String
		  Do Until stream.EndOfFile
		    lines.Add(stream.ReadLine)
		  Loop
		  stream.Close

		  App.AppendDebugLog("RSTParser: Read " + lines.Count.ToString + " lines." + EndOfLine)

		  // Title disambiguation: llms.txt (Xojo's own sitemap manifest, same
		  // folder as llms-full.txt) lists every page's title once per URL, so
		  // counting title occurrences there reveals which RST h1 titles are
		  // ambiguous (e.g. "Introduction" appears on 6+ unrelated pages) —
		  // without hardcoding a list of known-ambiguous titles, so future doc
		  // versions with new collisions are caught automatically. Missing file
		  // degrades gracefully to no disambiguation.
		  Var titleCounts As Dictionary = LoadTitleCounts(llmsFullPath)

		  Var pageStarts() As Integer
		  Var pageTitles() As String

		  Var lastCount As Integer = lines.LastIndex
		  For i As Integer = 0 To lastCount
		    Var line As String = lines(i).TrimRight
		    If line = "" Then Continue
		    If i + 1 <= lastCount Then
		      Var nextLine As String = lines(i + 1).TrimRight
		      If IsUnderline(nextLine, "=") And nextLine.Length >= line.Length Then
		        If Not IsUnderline(line, "=") Then
		          pageStarts.Add(i)
		          pageTitles.Add(line.Trim)
		        End If
		      End If
		    End If
		  Next i

		  App.AppendDebugLog("RSTParser: Found " + pageStarts.Count.ToString + " pages (h1 sections)." + EndOfLine)

		  Var pageCount As Integer = pageStarts.LastIndex
		  If pageCount < 0 Then Return chunks

		  // Split the pi=0..pageCount range into System.CoreCount contiguous
		  // slices — not round-robin — so each worker's ResultChunks() is
		  // already in original page order and the merge below is a plain
		  // index-ordered concatenation with no re-sorting needed.
		  Var pageTotal As Integer = pageCount + 1
		  Var workerCount As Integer = System.CoreCount
		  If workerCount > pageTotal Then workerCount = pageTotal
		  If workerCount < 1 Then workerCount = 1

		  Var workers() As RSTPageWorker
		  Var baseSize As Integer = pageTotal \ workerCount
		  Var remainder As Integer = pageTotal Mod workerCount
		  Var startPi As Integer = 0
		  For w As Integer = 0 To workerCount - 1
		    Var sliceSize As Integer = baseSize
		    If w < remainder Then sliceSize = sliceSize + 1
		    If sliceSize = 0 Then Continue
		    Var worker As New RSTPageWorker
		    worker.Lines = lines
		    worker.PageStarts = pageStarts
		    worker.PageTitles = pageTitles
		    worker.TitleCounts = titleCounts
		    worker.LastLineIndex = lastCount
		    worker.PageIndexFrom = startPi
		    worker.PageIndexTo = startPi + sliceSize - 1
		    workers.Add(worker)
		    startPi = startPi + sliceSize
		    worker.Start
		  Next

		  // No blocking Join exists for preemptive Threads — poll ThreadState
		  // instead. Safe to sleep this call's own thread (IndexerThread)
		  // while waiting, since it isn't the main/UI thread.
		  Var allDone As Boolean = False
		  While Not allDone
		    allDone = True
		    For Each worker As RSTPageWorker In workers
		      If worker.ThreadState <> Thread.ThreadStates.NotRunning Then
		        allDone = False
		        Exit
		      End If
		    Next
		    If Not allDone Then Thread.SleepCurrent(20)
		  Wend

		  For Each worker As RSTPageWorker In workers
		    For Each c As DocChunk In worker.ResultChunks
		      chunks.Add(c)
		    Next
		    For Each line As String In worker.LogLines
		      App.AppendDebugLog(line + EndOfLine)
		    Next
		  Next

		  Return chunks
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub ParsePageGroup(lines() As String, pageStarts() As Integer, pageTitles() As String, fromPi As Integer, toPi As Integer, lastLineIndex As Integer, titleCounts As Dictionary, chunks() As DocChunk)
		  // Entry point for a single RSTPageWorker's page-index slice — the
		  // same per-pi loop body Parse used to run inline, extracted so it
		  // can run on a worker Thread instead. ParseAPIClassPage/
		  // ParseGuidePage/IsAPIClassPage stay Private; this is the only new
		  // public surface needed to reuse them.
		  Var pageCount As Integer = pageStarts.LastIndex
		  For pi As Integer = fromPi To toPi
		    Var pageLineStart As Integer = pageStarts(pi)
		    Var pageLineEnd As Integer
		    If pi < pageCount Then
		      pageLineEnd = pageStarts(pi + 1) - 1
		      // Same overline back-up fix as the old inline loop — see
		      // Parse's history for the "=======================" leak this
		      // guards against.
		      If pageLineEnd >= 0 And pageLineEnd <= lastLineIndex And IsUnderline(lines(pageLineEnd).TrimRight, "=") Then
		        pageLineEnd = pageLineEnd - 1
		      End If
		    Else
		      pageLineEnd = lastLineIndex
		    End If

		    Var pageTitle As String = pageTitles(pi)

		    If IsAPIClassPage(lines, pageLineStart, pageLineEnd) Then
		      ParseAPIClassPage(lines, pageLineStart, pageLineEnd, pageTitle, titleCounts, chunks)
		    Else
		      ParseGuidePage(lines, pageLineStart, pageLineEnd, pageTitle, titleCounts, chunks)
		    End If
		  Next pi
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ParseAPIClassPage(lines() As String, startLine As Integer, endLine As Integer, className As String, titleCounts As Dictionary, chunks() As DocChunk)
		  Var displayClassName As String = DisambiguatedTitle(lines, startLine, endLine, className, titleCounts)

		  Var firstMemberLine As Integer = endLine + 1
		  For i As Integer = startLine To endLine
		    If IsMemberAnchor(lines(i)) Then
		      firstMemberLine = i
		      Exit
		    End If
		  Next i

		  If firstMemberLine > startLine + 2 Then
		    Var overviewText As String = ExtractAPIOverview(lines, startLine + 2, firstMemberLine - 1)
		    If overviewText <> "" Then
		      Var chunk As New DocChunk
		      chunk.Title = displayClassName + " > Overview"
		      chunk.Source = "llms-full.txt > " + displayClassName
		      chunk.ChunkText = chunk.Title + EndOfLine + EndOfLine + overviewText
		      chunks.Add(chunk)
		    End If
		  End If

		  Var i As Integer = firstMemberLine
		  While i <= endLine
		    If IsMemberAnchor(lines(i)) Then
		      Var memberAnchorLine As Integer = i
		      Var memberEnd As Integer = endLine
		      Var j As Integer = i + 1
		      While j <= endLine
		        If IsMemberAnchor(lines(j)) Then
		          memberEnd = j - 1
		          Exit
		        End If
		        j = j + 1
		      Wend

		      Var anchor As String = lines(memberAnchorLine).Trim
		      Var memberName As String = ""
		      Var anchorInner As String = anchor.Middle(4)
		      If anchorInner.EndsWith(":") Then
		        anchorInner = anchorInner.Left(anchorInner.Length - 1)
		      End If
		      Var anchorDotPos As Integer = anchorInner.IndexOf(".")
		      If anchorDotPos >= 0 Then
		        memberName = anchorInner.Middle(anchorDotPos + 1)
		        If memberName.Length > 0 Then
		          memberName = memberName.Left(1).Uppercase + memberName.Middle(1)
		        End If
		      End If

		      If memberName <> "" Then
		        Var memberText As String = ExtractBody(lines, memberAnchorLine + 1, memberEnd)
		        If memberText <> "" Then
		          Var chunk As New DocChunk
		          chunk.Title = displayClassName + " > " + memberName
		          chunk.Source = "llms-full.txt > " + displayClassName
		          chunk.ChunkText = chunk.Title + EndOfLine + EndOfLine + memberText
		          chunks.Add(chunk)
		        End If
		      End If

		      i = memberEnd + 1
		    Else
		      i = i + 1
		    End If
		  Wend
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ParseGuidePage(lines() As String, startLine As Integer, endLine As Integer, pageTitle As String, titleCounts As Dictionary, chunks() As DocChunk)
		  Var firstAnchor As String = FindFirstPathAnchor(lines, startLine, endLine)

		  If ShouldSkipGuidePage(firstAnchor) Then Return

		  Var displayTitle As String = pageTitle
		  If titleCounts.Lookup(pageTitle, 0) > 1 Then
		    Var category As String = CategoryFromAnchor(firstAnchor)
		    If category <> "" Then displayTitle = pageTitle + " (" + category + ")"
		  End If
		  pageTitle = displayTitle

		  Var currentH2 As String = ""
		  Var chunkLines() As String
		  Var inChunk As Boolean = False
		  Var inDirective As Boolean = False
		  // Same real ".. code:: xojo" block tracking as ExtractBody (see its
		  // codeBlockIndent comment for the full rationale) — ParseGuidePage
		  // is a completely separate code path with its own line-by-line
		  // scan, so it needs its own copy of this state rather than sharing
		  // ExtractBody's. Confirmed live, 2026-08-29: without this, guide
		  // pages (narrative "how to" articles like "HTTP (Web)
		  // communication") kept showing the raw ".. code:: xojo" directive
		  // text verbatim in the answer instead of a proper fenced block —
		  // ExtractBody's fix only ever covered ParseAPIClassPage's chunks.
		  Var inCodeBlock As Boolean = False
		  Var codeBlockIndent As Integer = -1

		  Var i As Integer = startLine + 2
		  While i <= endLine
		    Var line As String = lines(i).TrimRight

		    // A directive's own parameters/body are indented lines following it
		    // (e.g. toctree's :maxdepth:/:name: and its bare link list) — skip
		    // the whole indented block, not just the directive's own line, or
		    // the link list leaks through as bogus chunk text (a toctree-only
		    // page like "Web" or "iOS" would otherwise become a chunk that's
		    // just a list of child-page links with no real content).
		    If inDirective Then
		      If line.Trim = "" Then
		        i = i + 1
		        Continue
		      ElseIf line.Left(1) = " " Or line.Left(1) = Chr(9) Then
		        i = i + 1
		        Continue
		      Else
		        inDirective = False
		      End If
		    End If

		    Var trimmedEarly As String = line.Trim
		    If trimmedEarly.BeginsWith(".. code") Then
		      If inCodeBlock And inChunk Then chunkLines.Add(kCodeFenceClose)
		      inCodeBlock = True
		      codeBlockIndent = -1
		      If inChunk Then chunkLines.Add(kCodeFenceOpen)
		      i = i + 1
		      Continue
		    End If

		    If inCodeBlock Then
		      If line = "" Then
		        If inChunk Then chunkLines.Add("")
		        i = i + 1
		        Continue
		      Else
		        Var indent As Integer = LeadingWhitespaceCount(line)
		        If codeBlockIndent < 0 Then codeBlockIndent = indent
		        If indent >= codeBlockIndent Then
		          If inChunk Then chunkLines.Add(line.Trim)
		          i = i + 1
		          Continue
		        Else
		          inCodeBlock = False
		          codeBlockIndent = -1
		          If inChunk Then chunkLines.Add(kCodeFenceClose)
		          // Fall through — this line is real content (prose, a new
		          // heading, etc.), handled by the normal logic below.
		        End If
		      End If
		    End If

		    If line <> "" And i + 1 <= endLine Then
		      Var nextLine As String = lines(i + 1).TrimRight
		      If IsUnderline(nextLine, "-") And nextLine.Length >= line.Trim.Length And Not IsUnderline(line, "-") Then
		        If inChunk And chunkLines.Count > 0 Then
		          EmitGuideChunk(pageTitle, currentH2, chunkLines, chunks)
		          chunkLines.ResizeTo(-1)
		        End If
		        currentH2 = line.Trim
		        inChunk = True
		        i = i + 2
		        Continue
		      End If
		    End If

		    If line <> "" And i + 1 <= endLine Then
		      Var nextLine As String = lines(i + 1).TrimRight
		      If (IsUnderline(nextLine, "*") Or IsUnderline(nextLine, "^") Or IsUnderline(nextLine, "~")) _
		         And nextLine.Length >= line.Trim.Length And Not IsUnderline(line, "*") _
		         And Not IsUnderline(line, "^") And Not IsUnderline(line, "~") Then
		        If inChunk Then
		          chunkLines.Add(line.Trim)
		        End If
		        i = i + 2
		        Continue
		      End If
		    End If

		    Var trimmed As String = line.Trim
		    If trimmed.BeginsWith(".. _") Or trimmed.BeginsWith(".. toctree") Or _
		       trimmed.BeginsWith(".. image") Or trimmed.BeginsWith(".. figure") Or _
		       trimmed.BeginsWith(".. rst-class") Or trimmed.BeginsWith(".. csv-table") Or _
		       trimmed.BeginsWith(".. seealso::") Or trimmed.BeginsWith(".. note::") Or _
		       trimmed.BeginsWith(".. warning::") Or trimmed.BeginsWith(".. deprecated::") Or _
		       trimmed.BeginsWith(":header:") Or trimmed.BeginsWith(":widths:") Then
		      inDirective = True
		      i = i + 1
		      Continue
		    End If

		    If inChunk Or currentH2 = "" Then
		      If Not inChunk Then inChunk = True
		      Var cleaned As String = StripRSTMarkup(trimmed)
		      If cleaned <> "" Then
		        chunkLines.Add(cleaned)
		      ElseIf trimmed = "" And chunkLines.Count > 0 Then
		        If chunkLines(chunkLines.LastIndex) <> "" Then
		          chunkLines.Add("")
		        End If
		      End If
		    End If

		    i = i + 1
		  Wend

		  // A code block that never got a chance to close inline (page ends
		  // mid-example) still needs its closing fence — see ExtractBody's
		  // identical end-of-loop guard for why.
		  If inCodeBlock And inChunk Then chunkLines.Add(kCodeFenceClose)

		  If inChunk And chunkLines.Count > 0 Then
		    EmitGuideChunk(pageTitle, currentH2, chunkLines, chunks)
		  End If
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub EmitGuideChunk(pageTitle As String, h2Title As String, chunkLines() As String, chunks() As DocChunk)
		  While chunkLines.Count > 0 And chunkLines(chunkLines.LastIndex) = ""
		    chunkLines.RemoveAt(chunkLines.LastIndex)
		  Wend
		  If chunkLines.Count = 0 Then Return

		  // Some RST oddities (a bare category label like "Class" or "Method",
		  // sitting between two real pages with a blank line before its own
		  // underline so it's never recognised as its own h1) produce a chunk
		  // with only a word or two of body text — noise, not documentation.
		  If Join(chunkLines, "").Length < kMinChunkBodyLength Then Return

		  Var chunk As New DocChunk
		  If h2Title = "" Then
		    chunk.Title = pageTitle
		  Else
		    chunk.Title = pageTitle + " > " + h2Title
		  End If
		  chunk.Source = "llms-full.txt > " + pageTitle
		  chunk.ChunkText = chunk.Title + EndOfLine + EndOfLine + Join(chunkLines, EndOfLine)
		  chunks.Add(chunk)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ExtractAPIOverview(lines() As String, startIdx As Integer, endIdx As Integer) As String
		  Var parts() As String
		  Var inDirective As Boolean = False
		  Var pastFirstRef As Boolean = False
		  Var sectionNames() As String
		  Var sectionMembers() As String
		  Var currentSectionIdx As Integer = -1

		  For i As Integer = startIdx To endIdx
		    If i > lines.LastIndex Then Exit
		    Var line As String = lines(i).TrimRight
		    Var trimmed As String = line.Trim

		    If trimmed <> "" And i + 1 <= endIdx Then
		      Var nextLine As String = lines(i + 1).TrimRight
		      If IsUnderline(nextLine, "-") And nextLine.Length >= trimmed.Length Then
		        sectionNames.Add(trimmed)
		        sectionMembers.Add("")
		        currentSectionIdx = sectionNames.LastIndex
		        inDirective = False
		        i = i + 1
		        Continue
		      End If
		    End If

		    If trimmed.BeginsWith(":ref:`") Then
		      pastFirstRef = True
		      If currentSectionIdx >= 0 Then
		        Var tickStart As Integer = trimmed.IndexOf("`")
		        If tickStart >= 0 Then
		          Var anglePos As Integer = trimmed.IndexOf(tickStart + 1, "<")
		          Var nameEnd As Integer = If(anglePos > 0, anglePos, trimmed.IndexOf(tickStart + 1, "`"))
		          If nameEnd > tickStart Then
		            Var mName As String = trimmed.Middle(tickStart + 1, nameEnd - tickStart - 1).Trim
		            If mName <> "" Then
		              If sectionMembers(currentSectionIdx) = "" Then
		                sectionMembers(currentSectionIdx) = mName
		              Else
		                sectionMembers(currentSectionIdx) = sectionMembers(currentSectionIdx) + ", " + mName
		              End If
		            End If
		          End If
		        End If
		      End If
		      Continue
		    End If

		    If pastFirstRef Then Continue

		    If trimmed.BeginsWith(".. rst-class::") Or trimmed.BeginsWith(".. _") Or _
		       trimmed.BeginsWith(":header:") Or trimmed.BeginsWith(":widths:") Or _
		       trimmed.BeginsWith(".. csv-table::") Or trimmed.BeginsWith(":scale:") Then
		      Continue
		    End If

		    If trimmed.BeginsWith(".. toctree::") Or trimmed.BeginsWith(".. image::") Or _
		       trimmed.BeginsWith(".. figure::") Or trimmed.BeginsWith(".. code") Or _
		       trimmed.BeginsWith(".. warning::") Or trimmed.BeginsWith(".. note::") Then
		      inDirective = True
		      Continue
		    End If

		    If inDirective Then
		      If trimmed = "" Then
		        Continue
		      ElseIf line.Left(1) <> " " And line.Left(1) <> Chr(9) Then
		        inDirective = False
		      Else
		        Continue
		      End If
		    End If

		    If trimmed = "" Then
		      If parts.Count > 0 And parts(parts.LastIndex) <> "" Then parts.Add("")
		      Continue
		    End If

		    If Not trimmed.BeginsWith(".. ") And trimmed <> "----" Then
		      Var cleaned As String = StripRSTMarkup(trimmed)
		      If cleaned <> "" Then parts.Add(cleaned)
		    End If
		  Next i

		  For si As Integer = 0 To sectionNames.LastIndex
		    If sectionMembers(si) <> "" Then
		      If parts.Count > 0 Then parts.Add("")
		      parts.Add(sectionNames(si) + ": " + sectionMembers(si) + ".")
		    End If
		  Next si

		  While parts.Count > 0 And parts(0) = ""
		    parts.RemoveAt(0)
		  Wend
		  While parts.Count > 0 And parts(parts.LastIndex) = ""
		    parts.RemoveAt(parts.LastIndex)
		  Wend

		  Return Join(parts, EndOfLine)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsAPIClassPage(lines() As String, startLine As Integer, endLine As Integer) As Boolean
		  Var limit As Integer = Min(endLine, startLine + 500)
		  For i As Integer = startLine To limit
		    If IsMemberAnchor(lines(i)) Then Return True
		  Next i
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsMemberAnchor(line As String) As Boolean
		  Var trimmed As String = line.Trim
		  If Not trimmed.BeginsWith(".. _") Then Return False
		  If trimmed.BeginsWith(".. _/") Then Return False
		  If Not trimmed.EndsWith(":") Then Return False
		  Var inner As String = trimmed.Middle(4, trimmed.Length - 5)
		  Var dotPos As Integer = inner.IndexOf(".")
		  If dotPos <= 0 Then Return False
		  If inner.IndexOf("/") >= 0 Then Return False
		  Return True
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function LoadTitleCounts(llmsFullPath As FolderItem) As Dictionary
		  // Counts how many URLs share each title in llms.txt (Xojo's sitemap
		  // manifest, sibling of llms-full.txt) — a title appearing more than
		  // once is ambiguous. Missing/unreadable file → empty Dictionary, so
		  // Lookup(title, 0) > 1 is never true and titles are left untouched.
		  Var counts As New Dictionary
		  If llmsFullPath = Nil Then Return counts
		  Var parent As FolderItem = llmsFullPath.Parent
		  If parent = Nil Then Return counts
		  Var llmsTxtFile As FolderItem = parent.Child("llms.txt")
		  If llmsTxtFile = Nil Or Not llmsTxtFile.Exists Then
		    App.AppendDebugLog("RSTParser: llms.txt not found next to " + llmsFullPath.NativePath + " — title disambiguation disabled." + EndOfLine)
		    Return counts
		  End If

		  Var stream As TextInputStream
		  Try
		    stream = TextInputStream.Open(llmsTxtFile)
		  Catch e As IOException
		    App.AppendDebugLog("RSTParser: Cannot open llms.txt: " + e.Message + EndOfLine)
		    Return counts
		  End Try

		  Do Until stream.EndOfFile
		    Var line As String = stream.ReadLine.Trim
		    // Format: - [Title](URL)
		    If line.BeginsWith("- [") Then
		      Var closeBracket As Integer = line.IndexOf("](")
		      If closeBracket > 3 Then
		        Var title As String = line.Middle(3, closeBracket - 3)
		        If title <> "" Then
		          counts.Value(title) = counts.Lookup(title, 0) + 1
		        End If
		      End If
		    End If
		  Loop
		  stream.Close

		  App.AppendDebugLog("RSTParser: llms.txt loaded, " + counts.Count.ToString + " distinct titles." + EndOfLine)
		  Return counts
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function FindFirstPathAnchor(lines() As String, startLine As Integer, endLine As Integer) As String
		  // A page's own h1 is rarely anchored directly — RST only anchors its
		  // h2 subsections (e.g. h1 "Introduction" has no anchor of its own,
		  // but its first h2 subsection is anchored as
		  // .. _/getting_started/using_the_ide/introduction/getting_started:).
		  // That anchor's parent path segment (found by CategoryFromAnchor,
		  // which drops TWO trailing segments — the h2's own slug plus the
		  // h1's slug) is what identifies this page's category. Search the
		  // whole page rather than a fixed short window, since the anchor can
		  // be many lines after the h1 if the intro text is long.
		  For i As Integer = startLine To Min(startLine + 200, endLine)
		    Var line As String = lines(i).Trim
		    If line.BeginsWith(".. _/") Then Return line
		  Next i
		  Return ""
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function CategoryFromAnchor(anchor As String) As String
		  // anchor looks like:
		  //   .. _/getting_started/using_the_ide/introduction/getting_started:
		  // found on a CHILD h2 subsection, not the h1 page itself — so both
		  // the child's own slug (last segment) AND the page's own slug
		  // (second-to-last) must be dropped to reach the actual category
		  // ("using_the_ide"). A page with only one path segment before its
		  // own slug (e.g. a top-level /introduction) has no deeper category
		  // to show.
		  If anchor = "" Then Return ""
		  Var slashPos As Integer = anchor.IndexOf("_/")
		  If slashPos < 0 Then Return ""
		  Var inner As String = anchor.Middle(slashPos + 2)
		  If inner.EndsWith(":") Then inner = inner.Left(inner.Length - 1)
		  Var segments() As String = inner.Split("/")
		  If segments.LastIndex < 2 Then Return ""
		  Return HumanizeSegment(segments(segments.LastIndex - 2))
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function HumanizeSegment(segment As String) As String
		  // Generic path-segment-to-readable-text rule (no hardcoded word list,
		  // so it keeps working on doc categories we haven't seen yet) — known
		  // tradeoff: acronyms like "ide" become "Ide", not "IDE".
		  Var words() As String = segment.ReplaceAll("-", "_").Split("_")
		  Var result As String = ""
		  For Each w As String In words
		    If w = "" Then Continue
		    Var word As String = w.Left(1).Uppercase + w.Middle(1).Lowercase
		    If result <> "" Then result = result + " "
		    result = result + word
		  Next
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function DisambiguatedTitle(lines() As String, startLine As Integer, endLine As Integer, title As String, titleCounts As Dictionary) As String
		  If titleCounts.Lookup(title, 0) <= 1 Then Return title
		  Var anchor As String = FindFirstPathAnchor(lines, startLine, endLine)
		  Var category As String = CategoryFromAnchor(anchor)
		  If category = "" Then Return title
		  Return title + " (" + category + ")"
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ShouldSkipGuidePage(firstAnchor As String) As Boolean
		  Var skipPrefixes() As String
		  skipPrefixes.Add(".. _/resources/release_notes/")
		  skipPrefixes.Add(".. _/resources/system_requirements_for")
		  skipPrefixes.Add(".. _/español/")
		  skipPrefixes.Add(".. _/resources/videos/")
		  skipPrefixes.Add(".. _/resources/roadmap/")
		  skipPrefixes.Add(".. _/resources/xojotalk_podcast/")
		  skipPrefixes.Add(".. _/whitesands/")
		  skipPrefixes.Add(".. _/fine_print/")
		  skipPrefixes.Add(".. _/copy_files")
		  For Each prefix As String In skipPrefixes
		    If firstAnchor.BeginsWith(prefix) Then Return True
		  Next prefix
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ExtractBody(lines() As String, startIdx As Integer, endIdx As Integer) As String
		  Var parts() As String
		  Var inDirective As Boolean = False
		  Var inCodeBlock As Boolean = False
		  Var blankCount As Integer = 0
		  // Indent width (raw leading-whitespace char count, BEFORE
		  // TrimRight/Trim) of the code block's own first non-blank line, set
		  // once a code block starts. A later line only ends the block if its
		  // OWN indent is LESS than this — not "any unindented line", which
		  // is wrong for the API-reference doc format where an entire method
		  // body (both code AND the prose between multiple .. code:: blocks
		  // for the same method) is indented at one shared fixed level, e.g.
		  // 4 spaces; only the next .. code::/.. note:: directive itself
		  // marks a real prose/code boundary there, not the indent amount.
		  // Confirmed via a live DB check after this bug shipped once already:
		  // a "Sends a GET request..." prose sentence sitting between two
		  // .. code:: blocks (both indented 4 spaces under the method
		  // signature) got swallowed into the first code fence because it
		  // was still indented relative to column 0, even though it isn't
		  // actually more code.
		  Var codeBlockIndent As Integer = -1

		  For i As Integer = startIdx To endIdx
		    If i > lines.LastIndex Then Exit

		    Var line As String = lines(i).TrimRight
		    Var trimmed As String = line.Trim

		    If trimmed.BeginsWith(".. toctree::") Or trimmed.BeginsWith(".. image::") Or _
		       trimmed.BeginsWith(".. figure::") Or trimmed.BeginsWith(".. rst-class::") Or _
		       trimmed.BeginsWith(".. csv-table::") Or trimmed.BeginsWith(".. _") Or _
		       trimmed.BeginsWith(":header:") Or trimmed.BeginsWith(":widths:") Or _
		       trimmed.BeginsWith(":scale:") Or trimmed.BeginsWith(":name:") Then
		      inDirective = True
		      Continue
		    End If

		    If trimmed.BeginsWith(".. code") Or trimmed.BeginsWith(".. warning::") Or _
		       trimmed.BeginsWith(".. note::") Or trimmed.BeginsWith(".. deprecated::") Then
		      If inCodeBlock Then parts.Add(kCodeFenceClose)
		      inCodeBlock = False
		      codeBlockIndent = -1
		      inDirective = False
		      If trimmed.BeginsWith(".. code") Then
		        inCodeBlock = True
		        parts.Add(kCodeFenceOpen)
		      End If
		      Continue
		    End If

		    If inDirective Then
		      If line = "" Then
		        Continue
		      ElseIf line.Left(1) <> " " And line.Left(1) <> Chr(9) Then
		        inDirective = False
		      Else
		        Continue
		      End If
		    End If

		    If inCodeBlock Then
		      If line = "" Then
		        parts.Add("")
		        Continue
		      Else
		        Var indent As Integer = LeadingWhitespaceCount(line)
		        // First non-blank line of this code block sets the reference
		        // indent — every later line at or above that indent is still
		        // part of the SAME block; only dropping below it (or hitting
		        // the next directive, handled above) ends it. This is what
		        // makes the API-reference format (whole method body, prose
		        // and code alike, at one shared indent) work: a prose
		        // sentence between two .. code:: blocks sits at that SAME
		        // indent, not less, so it must NOT be swallowed as code — but
		        // it also isn't reached here at all, because the next ..
		        // code:: directive already closed the previous block above.
		        // What this guards against is different: a code line itself
		        // using LESS leading whitespace than the block's own first
		        // line (rare, but seen with a not-fully-indented continuation
		        // line) no longer incorrectly ends the block.
		        If codeBlockIndent < 0 Then codeBlockIndent = indent
		        If indent >= codeBlockIndent Then
		          parts.Add(line.Trim)
		          Continue
		        Else
		          inCodeBlock = False
		          codeBlockIndent = -1
		          parts.Add(kCodeFenceClose)
		        End If
		      End If
		    End If

		    If trimmed.BeginsWith(".. ") Or trimmed = "----" Then Continue

		    If trimmed = "" Then
		      blankCount = blankCount + 1
		      If blankCount <= 1 And parts.Count > 0 Then
		        parts.Add("")
		      End If
		      Continue
		    End If
		    blankCount = 0

		    Var cleaned As String = StripRSTMarkup(trimmed)
		    If cleaned <> "" Then
		      parts.Add(cleaned)
		    End If
		  Next i

		  // A code block that never got a chance to close inline (loop ran out
		  // of lines while still inCodeBlock — e.g. the body ends mid-example)
		  // still needs its closing fence, or every subsequent chunk_text
		  // built from a later page would end up wrapped as "code" too, since
		  // there'd be an unbalanced opening fence with no matching close.
		  If inCodeBlock Then parts.Add(kCodeFenceClose)

		  While parts.Count > 0 And parts(0) = ""
		    parts.RemoveAt(0)
		  Wend
		  While parts.Count > 0 And parts(parts.LastIndex) = ""
		    parts.RemoveAt(parts.LastIndex)
		  Wend

		  Return Join(parts, EndOfLine)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function LeadingWhitespaceCount(line As String) As Integer
		  // Counts leading space/tab characters — used to compare a code-block
		  // line's own indent against the block's established reference
		  // indent (see ExtractBody's codeBlockIndent comment), not to strip
		  // or otherwise interpret the whitespace itself.
		  Var count As Integer = 0
		  While count < line.Length And (line.Middle(count, 1) = " " Or line.Middle(count, 1) = Chr(9))
		    count = count + 1
		  Wend
		  Return count
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsUnderline(line As String, ch As String) As Boolean
		  Var trimmed As String = line.Trim
		  If trimmed.Length < 3 Then Return False
		  For i As Integer = 0 To trimmed.Length - 1
		    If trimmed.Middle(i, 1) <> ch Then Return False
		  Next i
		  Return True
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function Min(a As Integer, b As Integer) As Integer
		  If a < b Then Return a
		  Return b
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function StripRSTMarkup(line As String) As String
		  Var result As String = line
		  Var i As Integer = 0
		  Var advanced As Boolean
		  Var roleEnd As Integer
		  Var tickEnd As Integer
		  Var inner As String
		  Var ltPos As Integer
		  Var r As String = ""
		  Var ch As String

		  While i < result.Length
		    advanced = False
		    If result.Middle(i, 1) = ":" Then
		      roleEnd = result.IndexOf(i + 1, ":`")
		      If roleEnd > i And roleEnd - i < 20 Then
		        tickEnd = result.IndexOf(roleEnd + 2, "`")
		        If tickEnd > roleEnd Then
		          inner = result.Middle(roleEnd + 2, tickEnd - roleEnd - 2)
		          ltPos = inner.IndexOf("<")
		          If ltPos >= 0 Then inner = inner.Left(ltPos)
		          result = result.Left(i) + inner.Trim + result.Middle(tickEnd + 1)
		          advanced = True
		        End If
		      End If
		    End If
		    If Not advanced Then i = i + 1
		  Wend

		  result = result.ReplaceAll("``", "")
		  result = result.ReplaceAll("**", "")
		  result = result.ReplaceAll("*", "")
		  result = result.ReplaceAll("\(", "(")
		  result = result.ReplaceAll("\)", ")")

		  i = 0
		  While i < result.Length
		    ch = result.Middle(i, 1)
		    If ch = "`" Then
		      Var closing As Integer = result.IndexOf(i + 1, "`")
		      If closing > i Then
		        r = r + result.Middle(i + 1, closing - i - 1)
		        If closing + 1 < result.Length And result.Middle(closing + 1, 1) = "_" Then
		          i = closing + 2
		        Else
		          i = closing + 1
		        End If
		      Else
		        r = r + ch
		        i = i + 1
		      End If
		    Else
		      r = r + ch
		      i = i + 1
		    End If
		  Wend

		  Return r.Trim
		End Function
	#tag EndMethod

	#tag Constant, Name = kMinChunkBodyLength, Type = Integer, Dynamic = False, Default = \"15", Scope = Private
	#tag EndConstant

	// Mark a real RST ".. code::" block's boundaries in chunk_text so a
	// downstream consumer (SymbolCheck.ExtractCodeBlocks, and eventually the
	// UI) can tell actual Xojo code apart from prose without guessing —
	// previously this distinction, known at parse time, was discarded when
	// ExtractBody joined code and prose lines into one flat string. Two
	// separate constants (not one reused both ways) because a fence with a
	// language tag only makes sense as an opener — a closing fence with
	// "xojo" trailing it would render wrong if this text is ever shown as
	// literal Markdown, even though ExtractCodeBlocks itself only looks for
	// the next bare "```" and would work either way.
	#tag Constant, Name = kCodeFenceOpen, Type = String, Dynamic = False, Default = \"```xojo", Scope = Public
	#tag EndConstant

	#tag Constant, Name = kCodeFenceClose, Type = String, Dynamic = False, Default = \"```", Scope = Public
	#tag EndConstant

End Class
#tag EndClass
