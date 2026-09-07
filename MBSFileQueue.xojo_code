#tag Class
Public Class MBSFileQueue
	#tag Method, Flags = &h0
		Sub Constructor(files() As FolderItem, names() As String)
		  // Files/Names are set once here, before any worker Thread is
		  // started, and never mutated afterward — safe to read from any
		  // number of threads without a lock. Only mNextIndex(0), the pull
		  // cursor, is shared mutable state.
		  mFiles = files
		  mNames = names
		  mNextIndex.Add(0)
		  mLock = New CriticalSection
		  mLock.Type = Thread.Types.Preemptive
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function TryTakeNext(ByRef fileOut As FolderItem, ByRef nameOut As String) As Boolean
		  // Pull-based work assignment: replaces static contiguous file
		  // slicing (the design MBSDocsetParser.Parse used before) so a
		  // worker stuck with several large/slow files, or one running on a
		  // slower efficiency core, simply pulls fewer files overall instead
		  // of leaving the other workers idle at the end of the run. See
		  // project-mbs-parsing-perf memory: the straggler was observed as
		  // CPU dropping from ~865% to ~100% near the end of a parse run.
		  //
		  // The critical section here only ever guards one Integer compare
		  // + increment — kept deliberately short. The prior
		  // ParseProgressCounter crashed under a burst of ~10 preemptive
		  // threads all calling Enter for the FIRST time within the same
		  // few milliseconds of each other (a Xojo CriticalSection runtime
		  // race, confirmed not a misuse of the API — see that memory).
		  // This queue is exposed identically to all workers at Start time,
		  // so it risks the same first-contention burst; verified live at
		  // full System.CoreCount fan-out before trusting this design.
		  // 2026-09-07: mFiles(idx)/mNames(idx) moved INSIDE the lock —
		  // confirmed live that reading them after Leave (the original
		  // design, reasoned to be safe since the arrays are never mutated
		  // post-construction) still left a real, reproducible non-
		  // determinism: repeat reindexes of an unchanged docset kept
		  // producing a small nonzero "new/updated" count at full
		  // System.CoreCount fan-out, while forcing workerCount=1
		  // eliminated it completely (3 consecutive 0-count runs). Testing
		  // whether concurrent unlocked reads of these arrays — not just
		  // the AtomicDictionaryMBS-converted anchorsByFile/anchorSet,
		  // which did NOT fix it either — are the real cause.
		  mLock.Enter
		  Var idx As Integer = mNextIndex(0)
		  If idx >= mFiles.Count Then
		    mLock.Leave
		    Return False
		  End If
		  mNextIndex(0) = idx + 1
		  fileOut = mFiles(idx)
		  nameOut = mNames(idx)
		  mLock.Leave
		  Return True
		End Function
	#tag EndMethod

	#tag Property, Flags = &h21
		Private mFiles() As FolderItem
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mNames() As String
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mNextIndex() As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mLock As CriticalSection
	#tag EndProperty

End Class
#tag EndClass
