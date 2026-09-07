#tag Module
Protected Module SymbolCheck
	#tag Method, Flags = &h0
		Function ExtractCodeBlocks(reply As String) As String()
		  // Pulls out the content of every ```xojo ... ``` (or bare ``` ...
		  // ```) fenced block. Used by Retrieval.BuildContext to extract a
		  // REAL doc code example for injection — RSTParser wraps genuine
		  // RST ".. code::" blocks in the same fence syntax at index time
		  // (see RSTParser.kCodeFenceOpen), so this parser reads that
		  // structure directly out of chunk_text.
		  //
		  // String.IndexOf in this Xojo version only takes (searchString,
		  // options, locale) — no startIndex overload — so scanning forward
		  // through the reply means re-searching Middle(reply, searchFrom)
		  // each time and adding searchFrom back to get an absolute offset,
		  // rather than passing an index into IndexOf directly.
		  Var result() As String
		  Var searchFrom As Integer = 0
		  Do
		    Var remainder As String = reply.Middle(searchFrom)
		    Var relStart As Integer = remainder.IndexOf("```")
		    If relStart < 0 Then Exit
		    Var startPos As Integer = searchFrom + relStart
		    Var afterFence As Integer = startPos + 3
		    // Skip an optional language tag on the opening fence (e.g. "xojo")
		    // up to the next newline, same convention chat-handler.js's marked
		    // rendering already assumes.
		    Var afterFenceRemainder As String = reply.Middle(afterFence)
		    Var relLineEnd As Integer = afterFenceRemainder.IndexOf(EndOfLine)
		    Var contentStart As Integer = If(relLineEnd >= 0, afterFence + relLineEnd + 1, afterFence)
		    Var contentRemainder As String = reply.Middle(contentStart)
		    Var relEnd As Integer = contentRemainder.IndexOf("```")
		    If relEnd < 0 Then Exit // unterminated fence — ignore the tail
		    Var endPos As Integer = contentStart + relEnd
		    result.Add(reply.Middle(contentStart, endPos - contentStart))
		    searchFrom = endPos + 3
		  Loop
		  Return result
		End Function
	#tag EndMethod

End Module
#tag EndModule
