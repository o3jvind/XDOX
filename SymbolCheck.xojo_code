#tag Module
Protected Module SymbolCheck
	#tag Method, Flags = &h0
		Function FindUnverifiedSymbolsInCode(reply As String, context As String) As String()
		  // Same detector as FindUnverifiedSymbols, scoped to fenced code
		  // blocks only — see ExtractCodeBlocks for why. Used to decide
		  // whether to show the user a "this code could not be verified"
		  // warning (XDOXSession.FinishResponse), unlike
		  // FindUnverifiedSymbols's prose-wide scan, which stays a
		  // debug-log-only diagnostic because prose false-positives
		  // ("Here", "However", "Choose"...) are too frequent to act on
		  // directly — code-block symbols are a much cleaner signal
		  // (a PascalCase word inside ```xojo``` is a class/method/property
		  // reference far more reliably than one in a sentence).
		  Var blocks() As String = ExtractCodeBlocks(reply)
		  Var seen As New Dictionary
		  Var unverified() As String
		  For Each block As String In blocks
		    For Each sym As String In ExtractPascalCaseWords(block)
		      If context.IndexOf(sym) < 0 And Not seen.HasKey(sym) Then
		        seen.Value(sym) = True
		        unverified.Add(sym)
		      End If
		    Next
		  Next
		  Return unverified
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ExtractCodeBlocks(reply As String) As String()
		  // Pulls out the content of every ```xojo ... ``` (or bare ``` ...
		  // ```) fenced block — the model always wraps code this way (see
		  // BaseInstructions: "Use Markdown formatting for code examples").
		  // Scoping symbol-verification to just these blocks, rather than the
		  // whole reply, is what makes acting on the signal viable: prose
		  // sentences constantly contain capitalized words that are real
		  // English, not Xojo API names (see FindUnverifiedSymbols's
		  // long-documented false-positive list), but a PascalCase token
		  // actually used as an identifier inside a code block is a much
		  // stronger signal that it's meant to be a real API call.
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

	#tag Method, Flags = &h0
		Function FindUnverifiedSymbols(reply As String, context As String) As String()
		  // Debug-log-only diagnostic (no user-visible effect yet — see the
		  // ZXingWriterMBS case this exists to catch): extracts PascalCase,
		  // class-name-shaped tokens from the model's reply and reports any
		  // that never appear anywhere in the retrieved context. This is a
		  // DIFFERENT failure mode than Retrieval.MatchStatus's hard gate —
		  // that gate only fires when retrieval confidence is LOW; this checks
		  // whether the model invented a specific symbol even when retrieval
		  // found genuinely relevant (but incomplete) context. Confirmed live:
		  // asked about QR code generation, retrieval correctly found real
		  // ZXing/barcode documentation (ZXingReaderMBS is real), but the
		  // model invented "ZXingWriterMBS" — a plausible reader→writer
		  // sibling that doesn't exist in the docs at all.
		  //
		  // Deliberately narrow heuristic (PascalCase words only, no dotted
		  // Class.Member matching) to keep the false-positive rate low while
		  // this is being validated — see the extraction/rationale note in
		  // ExtractPascalCaseWords.
		  Var replySymbols() As String = ExtractPascalCaseWords(reply)
		  Var unverified() As String
		  For Each sym As String In replySymbols
		    If context.IndexOf(sym) < 0 Then unverified.Add(sym)
		  Next
		  Return unverified
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsUpperAZ(ch As String) As Boolean
		  // NOT ch >= "A" And ch <= "Z" — Xojo string comparison operators are
		  // CASE-INSENSITIVE by default (confirmed via docs: "'Steve' and
		  // 'steve' are equal"), so that range check spuriously matched EVERY
		  // lowercase letter too (e.g. "d" >= "A" And "d" <= "Z" evaluated
		  // True), silently turning this into "is any letter" instead of
		  // "starts with uppercase" — confirmed live via a character-by-
		  // character trace: "does" was accumulating from its very first
		  // (lowercase) character. Asc() gives the ordinal code point, which
		  // compares correctly regardless of Xojo's string-comparison default.
		  Var code As Integer = ch.Asc
		  Return code >= 65 And code <= 90 // 'A'..'Z'
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsLowerAZ(ch As String) As Boolean
		  Var code As Integer = ch.Asc
		  Return code >= 97 And code <= 122 // 'a'..'z'
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function IsDigit(ch As String) As Boolean
		  Var code As Integer = ch.Asc
		  Return code >= 48 And code <= 57 // '0'..'9'
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function ExtractPascalCaseWords(text As String) As String()
		  // Manual scan, not RegEx — matches the existing codebase convention
		  // (Retrieval.SanitizeQuery/ExtractClassName both hand-scan rather
		  // than pull in a regex dependency). A candidate word: starts with an
		  // uppercase letter, is all letters/digits (no spaces/punctuation),
		  // at least kMinSymbolLength chars, and contains at least one lowercase
		  // letter after the first char (rules out ALL-CAPS acronyms like
		  // "JSON" or "HTML" on their own — those are real English/tech terms
		  // constantly used correctly in prose, not Xojo class names, and
		  // would otherwise dominate the unverified-symbol list with noise).
		  Var result() As String
		  Var seen As New Dictionary
		  Var current As String = ""
		  Var hasLower As Boolean = False

		  For i As Integer = 0 To text.Length
		    Var ch As String = If(i < text.Length, text.Middle(i, 1), " ")
		    Var isAlnum As Boolean = IsLowerAZ(ch) Or IsUpperAZ(ch) Or IsDigit(ch)
		    If isAlnum Then
		      If current = "" And Not IsUpperAZ(ch) Then Continue // must start uppercase
		      current = current + ch
		      If IsLowerAZ(ch) Then hasLower = True
		    Else
		      If current.Length >= kMinSymbolLength And hasLower And Not seen.HasKey(current) Then
		        seen.Value(current) = True
		        result.Add(current)
		      End If
		      current = ""
		      hasLower = False
		    End If
		  Next

		  Return result
		End Function
	#tag EndMethod


	#tag Constant, Name = kMinSymbolLength, Type = Double, Dynamic = False, Default = \"4", Scope = Private
	#tag EndConstant


End Module
#tag EndModule
