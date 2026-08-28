#tag Class
Public Class RetrievalResult

	#tag Property, Flags = &h0
		Text As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Title As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Source As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Score As Double
	#tag EndProperty

	#tag Property, Flags = &h0
		IsThirdParty As Boolean
	#tag EndProperty

	#tag Property, Flags = &h0
		// Cross-encoder relevance score for this specific chunk (0.0-1.0),
		// -1.0 if reranking didn't run (server down, or fallback to
		// cosine+BM25 order) — distinct from Score, which is the raw
		// cosine+BM25(+boost) combined score. BuildContext uses this to drop
		// a chunk that only "won" its scoped pool's internal race but isn't
		// actually relevant (see Retrieval.kMinRelevanceScore) — Score alone
		// can't tell a genuinely weak pool (nothing relevant exists) from a
		// strong one, since ScopedSearch always fills its share of slots
		// with whatever scored best, even when "best" is still noise.
		RerankScore As Double = -1.0
	#tag EndProperty

	#tag Property, Flags = &h0
		// True for a chunk ScopedSearch force-included via its Overview-
		// chunk guarantee (confirms a matched class exists — see Task 4's
		// original fix history). BuildContext exempts these from
		// Retrieval.kMinRelevanceScore filtering: they were deliberately
		// pinned in past the score race specifically because the model
		// needs to see them, so a low RerankScore must not un-pin them.
		IsGuaranteed As Boolean
	#tag EndProperty

End Class
#tag EndClass
