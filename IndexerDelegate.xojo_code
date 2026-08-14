#tag Interface
Public Interface IndexerDelegate

	#tag Method, Flags = &h0
		Sub IndexerParsing()
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerFileScanProgress(filesScanned As Integer, totalFiles As Integer)
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerProgress(chunksProcessed As Integer, totalChunks As Integer)
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerEmbedProgress(chunksEmbedded As Integer, totalChunks As Integer)
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerComplete(isReindex As Boolean)
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerError(message As String)
	#tag EndMethod

End Interface
#tag EndInterface
