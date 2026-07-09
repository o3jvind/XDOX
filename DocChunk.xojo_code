#tag Class
Public Class DocChunk
	#tag Property, Flags = &h0
		ChunkText As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Source As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Title As String
	#tag EndProperty

	#tag Property, Flags = &h0
		ChunkIndex As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		PrevID As Integer = -1
	#tag EndProperty

	#tag Property, Flags = &h0
		NextID As Integer = -1
	#tag EndProperty

End Class
#tag EndClass
