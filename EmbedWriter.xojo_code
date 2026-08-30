#tag Class
Public Class EmbedWriter
Inherits Thread

	#tag Event
		Sub Run()
		  // The ONLY thread that touches the DB during the embed phase — owns
		  // the sole connection, does every claim and every write. Replaces an
		  // earlier design where 2 EmbedWorkers each had their own connection
		  // and shared a CriticalSection around claim/store: that avoided
		  // double-processing but still serialized real disk writes behind a
		  // lock, which showed up live as multi-second stalls once the lock
		  // timeout was raised (WAL mode allows only one writer at a time
		  // regardless of how politely two connections take turns). Having
		  // exactly one writer connection removes the contention structurally
		  // instead of coordinating around it.
		  Var db As SQLiteDatabase = DBHelper.OpenConnection
		  If db = Nil Then Return

		  Try
		    // Crash recovery: a prior run killed mid-batch could leave rows
		    // stuck at embedded=-2 forever — nothing else resets that sentinel.
		    // -2 should never legitimately persist across a full run, so any
		    // found at start is leftover from an aborted run.
		    If SourceFilter <> "" Then
		      db.ExecuteSQL("UPDATE chunks SET embedded=0 WHERE embedded=-2 AND source LIKE ?", SourceFilter)
		    Else
		      db.ExecuteSQL("UPDATE chunks SET embedded=0 WHERE embedded=-2")
		    End If

		    Var noMoreClaims As Boolean = False
		    Var doneCount As Integer = 0

		    While True
		      // Keep the work queue topped up so both workers always have
		      // something to chew on, without claiming unboundedly far ahead
		      // (which would just move contention into "how many rows sit
		      // claimed but unprocessed" instead of removing it).
		      If Not noMoreClaims And WorkQueue.Count < 2 Then
		        Var ids() As Integer
		        Var texts() As String
		        If Embedder.ClaimPendingBatch(db, SourceFilter, Embedder.kBatchSize, ids, texts) Then
		          Var item As New EmbedQueueItem
		          item.Ids = ids
		          item.Texts = texts
		          WorkQueue.Push(item)
		        Else
		          noMoreClaims = True
		        End If
		      End If

		      // Drain whatever results are ready and write them. Embeddings(k)
		      // = Nil marks a permanently-failed id regardless of whether it
		      // came from the normal batch path or the per-chunk retry path —
		      // EmbedWorker already resolved that distinction before pushing.
		      Var result As EmbedQueueItem = ResultQueue.Pop
		      While result <> Nil
		        db.BeginTransaction
		        For k As Integer = 0 To result.Ids.LastIndex
		          If k <= result.Embeddings.LastIndex And result.Embeddings(k) <> Nil Then
		            DBHelper.StoreChunkEmbedding(result.Ids(k), result.Embeddings(k), db)
		          Else
		            db.ExecuteSQL("UPDATE chunks SET embedded=-1 WHERE id=?", result.Ids(k))
		          End If
		        Next
		        db.CommitTransaction

		        doneCount = doneCount + result.Ids.Count
		        // Reported on OWNER (the IndexerThread/MBSIndexerThread that
		        // called Embedder.EmbedPendingChunks), not on Me — AddUser
		        // InterfaceUpdate fires ITS OWN instance's UserInterfaceUpdate
		        // event, and only Owner has a handler wired to the progress
		        // delegate. EmbedWriter has no UserInterfaceUpdate event of its
		        // own, so calling it on Me would silently go nowhere (confirmed
		        // live, 2026-08-30: progress UI stuck at "0 of 15,000" the
		        // whole run despite chunks genuinely completing).
		        Owner.AddUserInterfaceUpdate(New Pair("type", "embed-progress"), New Pair("done", doneCount), New Pair("total", Total))

		        result = ResultQueue.Pop
		      Wend

		      // Stop once nothing is left to claim, both queues are empty, and
		      // both workers report themselves idle (an explicit Busy flag,
		      // not inferred from ThreadState — a worker sleeps between poll
		      // checks too, so "Sleeping" alone can't distinguish idle from
		      // mid-batch). Checking Busy before the queues would risk exiting
		      // with a result still in flight; checking it after confirms
		      // nothing more can arrive.
		      If noMoreClaims And WorkQueue.Count = 0 And ResultQueue.Count = 0 Then
		        Var workersIdle As Boolean = True
		        For Each w As EmbedWorker In Workers
		          If w.Busy Then
		            workersIdle = False
		            Exit
		          End If
		        Next
		        If workersIdle Then Exit
		      End If

		      Me.Sleep(20)
		    Wend

		  Catch e As RuntimeException
		    App.AppendDebugLog("EmbedWriter: aborted after exception: " + e.Message + EndOfLine)
		  End Try

		  // Tell the workers to stop polling for more work, on both the
		  // normal-completion and exception paths.
		  For Each w As EmbedWorker In Workers
		    w.StopRequested = True
		  Next

		  db.Close
		End Sub
	#tag EndEvent

	#tag Property, Flags = &h0
		SourceFilter As String
	#tag EndProperty

	#tag Property, Flags = &h0
		Owner As Thread
	#tag EndProperty

	#tag Property, Flags = &h0
		Total As Integer
	#tag EndProperty

	#tag Property, Flags = &h0
		WorkQueue As EmbedQueue
	#tag EndProperty

	#tag Property, Flags = &h0
		ResultQueue As EmbedQueue
	#tag EndProperty

	#tag Property, Flags = &h0
		Workers() As EmbedWorker
	#tag EndProperty

End Class
#tag EndClass
