#tag DesktopWindow
Begin DesktopWindow IndexProgressWindow
   Backdrop        =   0
   BackgroundColor =   &cFFFFFF
   Composite       =   False
   DefaultLocation =   2
   FullScreen      =   False
   HasBackgroundColor=   False
   HasCloseButton  =   False
   HasFullScreenButton=   False
   HasMaximizeButton=   False
   HasMinimizeButton=   False
   HasTitleBar     =   True
   Height          =   232
   ImplicitInstance=   False
   MacProcID       =   0
   MaximumHeight   =   232
   MaximumWidth    =   440
   MenuBar         =   1984348159
   MenuBarVisible  =   False
   MinimumHeight   =   232
   MinimumWidth    =   440
   Resizeable      =   False
   Title           =   "Indexing Xojo Documentation"
   Type            =   3
   Visible         =   False
   Width           =   440
   Begin DesktopLabel TitleLabel
      AutoDeactivate  =   True
      Bold            =   True
      Enabled         =   True
      FontSize        =   13.0
      FontUnit        =   0
      Height          =   20
      Index           =   -2147483648
      InitialParent   =   ""
      Italic          =   False
      Left            =   20
      LockBottom      =   False
      LockedInPosition=   False
      LockLeft        =   True
      LockRight       =   True
      LockTop         =   True
      Multiline       =   False
      Scope           =   0
      TabIndex        =   0
      TabPanelIndex   =   0
      TabStop         =   True
      Text            =   "Indexing Xojo Documentation"
      Tooltip         =   ""
      Top             =   20
      Underline       =   False
      Visible         =   True
      Width           =   400
   End
   Begin DesktopProgressBar ProgressBar
      AutoDeactivate  =   True
      Enabled         =   True
      Height          =   20
      Index           =   -2147483648
      InitialParent   =   ""
      Left            =   20
      LockBottom      =   False
      LockedInPosition=   False
      LockLeft        =   True
      LockRight       =   True
      LockTop         =   True
      Maximum         =   100
      Minimum         =   0
      Scope           =   0
      TabIndex        =   1
      TabPanelIndex   =   0
      TabStop         =   True
      Tooltip         =   ""
      Top             =   56
      Value           =   0
      Visible         =   True
      Width           =   400
   End
   Begin DesktopLabel ChunkLabel
      AutoDeactivate  =   True
      Bold            =   False
      Enabled         =   True
      FontSize        =   12.0
      FontUnit        =   0
      Height          =   20
      Index           =   -2147483648
      InitialParent   =   ""
      Italic          =   False
      Left            =   20
      LockBottom      =   False
      LockedInPosition=   False
      LockLeft        =   True
      LockRight       =   True
      LockTop         =   True
      Multiline       =   False
      Scope           =   0
      TabIndex        =   2
      TabPanelIndex   =   0
      TabStop         =   True
      Text            =   ""
      Tooltip         =   ""
      Top             =   84
      Underline       =   False
      Visible         =   True
      Width           =   400
   End
   Begin DesktopLabel HintLabel
      AutoDeactivate  =   True
      Bold            =   False
      Enabled         =   True
      FontSize        =   12.0
      FontUnit        =   0
      Height          =   36
      Index           =   -2147483648
      InitialParent   =   ""
      Italic          =   False
      Left            =   20
      LockBottom      =   False
      LockedInPosition=   False
      LockLeft        =   True
      LockRight       =   True
      LockTop         =   True
      Multiline       =   True
      Scope           =   0
      TabIndex        =   3
      TabPanelIndex   =   0
      TabStop         =   True
      Text            =   ""
      Tooltip         =   ""
      Top             =   108
      Underline       =   False
      Visible         =   True
      Width           =   400
   End
   Begin DesktopButton PauseButton
      AllowAutoDeactivate=   True
      Bold            =   False
      Cancel          =   False
      Caption         =   "Pause"
      Default         =   False
      Enabled         =   False
      FontName        =   "System"
      FontSize        =   12.0
      FontUnit        =   0
      Height          =   24
      Index           =   -2147483648
      InitialParent   =   ""
      Italic          =   False
      Left            =   320
      LockBottom      =   True
      LockedInPosition=   False
      LockLeft        =   False
      LockRight       =   True
      LockTop         =   False
      MacButtonStyle  =   0
      Scope           =   0
      TabIndex        =   4
      TabPanelIndex   =   0
      TabStop         =   True
      Tooltip         =   ""
      Top             =   152
      Underline       =   False
      Visible         =   True
      Width           =   100
   End
End
#tag EndDesktopWindow

#tag WindowCode
	#tag Method, Flags = &h0
		Sub IndexerParsing()
		  ProgressBar.Indeterminate = True
		  ChunkLabel.Text = "Parsing documentation…"
		  HintLabel.Text = "Building the keyword index."
		  // Pausing is only offered during the embed phase (see
		  // IndexerEmbedProgress) — parsing itself has no partial-progress
		  // concept to save, so stopping mid-parse would just mean starting
		  // parse over from scratch next time anyway.
		  PauseButton.Enabled = False
		End Sub

		Sub IndexerFileScanProgress(filesScanned As Integer, totalFiles As Integer)
		  ProgressBar.Indeterminate = False
		  Var pct As Integer = If(totalFiles > 0, (filesScanned * 100) \ totalFiles, 0)
		  ProgressBar.Value = pct
		  ChunkLabel.Text = "Scanning file " + Format(filesScanned, "###,###") _
		    + " of " + Format(totalFiles, "###,###")
		  // File sizes vary a lot (some example pages run past 1 MB) — the
		  // percentage can sit still for a while on those without anything
		  // actually being stuck, so say so rather than let it look hung.
		  HintLabel.Text = "Reading documentation files — some are much larger than others, so progress may pause briefly."
		End Sub

		Sub IndexerProgress(chunksProcessed As Integer, totalChunks As Integer)
		  ProgressBar.Indeterminate = False
		  Var pct As Integer = If(totalChunks > 0, (chunksProcessed * 100) \ totalChunks, 0)
		  ProgressBar.Value = pct
		  ChunkLabel.Text = "Processing chunk " + Format(chunksProcessed, "###,###") _
		    + " of " + Format(totalChunks, "###,###")
		  HintLabel.Text = "Building the keyword index."
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerEmbedProgress(chunksEmbedded As Integer, totalChunks As Integer)
		  ProgressBar.Indeterminate = False
		  Var pct As Integer = If(totalChunks > 0, (chunksEmbedded * 100) \ totalChunks, 0)
		  ProgressBar.Value = pct
		  ChunkLabel.Text = "Embedding chunk " + Format(chunksEmbedded, "###,###") _
		    + " of " + Format(totalChunks, "###,###")
		  // No fixed time estimate here — actual duration depends on how many
		  // chunks are new/changed (content-hash caching skips the rest) and on
		  // machine/model speed, so a fixed guess would just be wrong most of
		  // the time. The percentage above is the honest signal.
		  HintLabel.Text = "Embedding for semantic search."
		  // Only re-enable if the user hasn't already clicked Pause this run
		  // — PauseButton.Caption still reads "Pause" (not "Stopping…") in
		  // that case, since it's flipped to disabled+"Stopping…" the moment
		  // Pressed fires and this event keeps firing with fresh progress
		  // afterward too (already-claimed batches still complete and write).
		  If PauseButton.Caption = "Pause" Then PauseButton.Enabled = True
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerComplete()
		  Close
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerError(message As String)
		  Close
		  MessageBox("Indexing failed: " + message)
		End Sub
	#tag EndMethod
#tag EndWindowCode

#tag Events PauseButton
	#tag Event
		Sub Pressed()
		  // Only meaningful during the embed phase (see Indexer/MBSIndexer.
		  // RequestStopEmbedding and Embedder.EmbedPendingChunks' polling
		  // loop) — harmless to call during parse too, since nothing polls
		  // the flag yet at that point. Calling both is safe: only one of
		  // Indexer/MBSIndexer ever has an ActiveThread at a time, since
		  // App.xojo_code's own IsRunning/MBSIsRunning checks already
		  // refuse to run both indexers concurrently.
		  Indexer.RequestStopEmbedding
		  MBSIndexer.RequestStopEmbedding
		  Me.Enabled = False
		  Me.Caption = "Stopping…"
		  HintLabel.Text = "Finishing in-flight batches, then stopping — already-embedded chunks are saved. Resuming later picks up where this left off."
		End Sub
	#tag EndEvent
#tag EndEvents

