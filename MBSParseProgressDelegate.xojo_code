#tag Interface
Public Interface MBSParseProgressDelegate

	#tag Method, Flags = &h0
		Sub MBSParseProgress(filesDone As Integer, totalFiles As Integer)
	#tag EndMethod

End Interface
#tag EndInterface
