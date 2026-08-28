#tag Class
Private Class ScopedSearchResult
	// Plain data carrier for one Retrieval.ScopedSearch call (native-only or
	// MBS-only pool) — parallel arrays, same shape HybridSearchChunks used
	// to keep as locals before Task 7 split it into two scoped searches.
	// Private (module-internal to Retrieval): nothing outside Retrieval.xojo_code
	// needs this shape.

	#tag Property, Flags = &h0
		ChunkIDs() As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		Titles() As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Texts() As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Sources() As String
	#tag EndProperty

	#tag Property, Flags = &h0
		ChunkIndexes() As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		PrevIDs() As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		NextIDs() As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		CosScores() As Double
	#tag EndProperty

	#tag Property, Flags = &h0
		Combined() As Double
	#tag EndProperty

	#tag Property, Flags = &h0
		FinalIdxs() As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		// Chunk ID (not array index — see Retrieval.ScopedSearch's comment)
		// of this pool's matched-class Overview chunk, if one was forced
		// into FinalIdxs by the Overview-guarantee. 0 if none.
		OverviewChunkID As Integer = 0
	#tag EndProperty

End Class
#tag EndClass
