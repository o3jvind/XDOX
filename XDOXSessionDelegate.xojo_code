#tag Interface
Public Interface XDOXSessionDelegate

	#tag Method, Flags = &h0
		Sub OnToken(text As String)
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub OnDone()
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub OnError(message As String)
	#tag EndMethod

End Interface
#tag EndInterface
