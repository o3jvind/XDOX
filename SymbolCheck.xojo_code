#tag Module
Protected Module SymbolCheck
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
