#tag Class
Public Class EmbedQueueItem

	#tag Property, Flags = &h0
		Ids() As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		Texts() As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Embeddings() As MemoryBlock
	#tag EndProperty

	#tag Property, Flags = &h0
		NeedsRetry As Boolean
	#tag EndProperty

End Class
#tag EndClass
