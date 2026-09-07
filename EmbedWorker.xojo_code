#tag Class
Public Class EmbedWorker
Inherits Thread

	#tag Event
		Sub Run()
		  // No DB access at all — EmbedWriter is the sole DB connection for
		  // the whole embed phase. This worker only does the slow HTTP
		  // Embedder.EmbedBatch call, which is where the real parallelism win
		  // lives: 2 workers' HTTP calls run fully concurrently against the
		  // embed server's 2 slots, with zero DB lock contention because
		  // neither worker ever opens a connection.
		  Try
		    While Not StopRequested
		      Var item As EmbedQueueItem = WorkQueue.Pop
		      If item = Nil Then
		        Busy = False
		        Me.Sleep(20)
		        Continue
		      End If
		      Busy = True

		      Var embs() As MemoryBlock = Embedder.EmbedBatch(item.Texts, Embedder.kTaskPrefixDocument)
		      Var result As New EmbedQueueItem
		      result.Ids = item.Ids

		      If embs.Count = 0 Then
		        // Whole batch failed — likely one oversized/poisonous input.
		        // Retry each chunk individually so one bad chunk doesn't sink
		        // seven good ones; only the actual offender gets marked
		        // failed. Nil in result.Embeddings(k) tells EmbedWriter to
		        // mark that id embedded=-1 instead of storing a vector.
		        For k As Integer = 0 To item.Ids.LastIndex
		          Var single As MemoryBlock = Embedder.FetchEmbedding(item.Texts(k), Embedder.kTaskPrefixDocument, 30)
		          result.Embeddings.Add(single)
		        Next
		      Else
		        result.Embeddings = embs
		      End If

		      ResultQueue.Push(result)
		      Busy = False
		    Wend
		  Catch e As RuntimeException
		    App.AppendDebugLog("EmbedWorker: aborted after exception: " + e.Message + EndOfLine)
		    Busy = False
		  End Try
		End Sub
	#tag EndEvent

	#tag Property, Flags = &h0
		WorkQueue As EmbedQueue
	#tag EndProperty

	#tag Property, Flags = &h0
		ResultQueue As EmbedQueue
	#tag EndProperty

	#tag Property, Flags = &h0
		StopRequested As Boolean
	#tag EndProperty

	#tag Property, Flags = &h0
		Busy As Boolean
	#tag EndProperty

End Class
#tag EndClass
