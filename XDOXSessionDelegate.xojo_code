#tag Interface
Public Interface XDOXSessionDelegate

	#tag Method, Flags = &h0
		Sub OnDone()
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub OnCannedResponse(pool As String, text As String)
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub OnPoolDone(pool As String)
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub OnPoolNoMatch(pool As String)
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub OnError(pool As String, message As String)
	#tag EndMethod

End Interface
#tag EndInterface
