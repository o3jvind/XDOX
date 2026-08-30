#tag Class
Public Class EmbedQueue

	#tag Method, Flags = &h0
		Constructor()
		  mLock = New CriticalSection
		  mLock.Type = Thread.Types.Preemptive
		End Constructor
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub Push(item As EmbedQueueItem)
		  mLock.Enter
		  mItems.Add(item)
		  mLock.Leave
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function Pop() As EmbedQueueItem
		  // Returns Nil if empty — callers poll rather than block, same
		  // pattern as the parsing-phase ThreadState poll-wait (no condition
		  // variable equivalent in the Xojo Thread API).
		  mLock.Enter
		  Var result As EmbedQueueItem
		  If mItems.Count > 0 Then
		    result = mItems(0)
		    mItems.RemoveAt(0)
		  End If
		  mLock.Leave
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function Count() As Integer
		  mLock.Enter
		  Var n As Integer = mItems.Count
		  mLock.Leave
		  Return n
		End Function
	#tag EndMethod

	#tag Property, Flags = &h21
		Private mItems() As EmbedQueueItem
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLock As CriticalSection
	#tag EndProperty

End Class
#tag EndClass
