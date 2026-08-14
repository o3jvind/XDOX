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
		  Var anchorsByFile As New Dictionary
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
		      Var anchorSet As Dictionary
		      If anchorsByFile.HasKey(basePath) Then
		        anchorSet = anchorsByFile.Value(basePath)
		      Else
		        anchorSet = New Dictionary
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

		  Var emptyAnchorSet As New Dictionary
		  Var filesDone As Integer = 0
		  Var unindexedCount As Integer = 0
		  Var total As Integer = list.Count
		  If progressDelegate <> Nil Then progressDelegate.MBSParseProgress(0, total)
		  For i As Integer = 0 To total - 1
		    If list.Directory(i) Then Continue
		    Var name As String = list.Name(i)
		    If name.Right(5) <> ".html" Then Continue
		    Var f As FolderItem = list.Item(i)
		    If f = Nil Then Continue

		    Var anchorSet As Dictionary
		    If anchorsByFile.HasKey(name) Then
		      anchorSet = anchorsByFile.Value(name)
		    Else
		      anchorSet = emptyAnchorSet
		      unindexedCount = unindexedCount + 1
		    End If

		    Try
		      ParseFile(f, anchorSet, chunks)
		    Catch e As RuntimeException
		      // One malformed page must not sink the other ~17,000 — skip it and
		      // keep going. (An InvalidArgumentException from a numeric-entity
		      // edge case has already been hit and fixed once; this is the
		      // backstop for whatever the next one turns out to be.)
		      App.AppendDebugLog("MBSDocsetParser: skipping " + name + " after exception: " + e.Message + EndOfLine)
		    End Try
		    filesDone = filesDone + 1
		    If filesDone Mod 500 = 0 Then
		      App.AppendDebugLog("MBSDocsetParser: " + filesDone.ToString _
		        + " files parsed, " + chunks.Count.ToString + " chunks so far, last file=" + name + EndOfLine)
		    End If

		    // Progress reported against loop position (i+1), not filesDone —
		    // filesDone only counts .html files, so it would stall short of
		    // total (which includes every item FileListMBS sees) whenever a
		    // run of non-.html files lands near the end of the folder listing.
		    If (i + 1) Mod 25 = 0 Then
		      If progressDelegate <> Nil Then progressDelegate.MBSParseProgress(i + 1, total)
		    End If
		  Next
		  If progressDelegate <> Nil Then progressDelegate.MBSParseProgress(total, total)

		  App.AppendDebugLog("MBSDocsetParser: produced " + chunks.Count.ToString + " chunks from " + filesDone.ToString _
		    + " files (" + unindexedCount.ToString + " not referenced by docSet.dsidx)" + EndOfLine)

		  Return chunks
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ParseFile(f As FolderItem, anchorSet As Dictionary, chunks() As DocChunk)
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
		Private Function CleanText(s As String) As String
		  s = DecodeEntities(s)
		  // Collapse runs of blank/whitespace-only lines and trailing spaces —
		  // StripTags emits one newline per block tag, which over a dense table
		  // produces long stretches of empty lines.
		  Var lines() As String = s.Split(Chr(10))
		  Var result() As String
		  Var blankRun As Boolean = False
		  For Each line As String In lines
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
