#tag Class
Public Class ChatTurn

	#tag Property, Flags = &h0
		UserMessage As String
	#tag EndProperty

	#tag Property, Flags = &h0
		// "" = no bubble from this pool for this turn — either it wasn't
		// searched (docs_search_scope excluded it) or it found nothing
		// admissible (MatchStatusForPool self-gated as no-match). Same
		// empty-string-as-sentinel convention as RetrievalResult.RerankScore
		// using -1.0 for "not scored."
		NativeReply As String
	#tag EndProperty

	#tag Property, Flags = &h0
		MBSReply As String
	#tag EndProperty

End Class
#tag EndClass
