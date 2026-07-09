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
   Height          =   180
   ImplicitInstance=   False
   MacProcID       =   0
   MaximumHeight   =   180
   MaximumWidth    =   440
   MenuBar         =   1984348159
   MenuBarVisible  =   False
   MinimumHeight   =   180
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
End
#tag EndDesktopWindow

#tag WindowCode
	#tag Method, Flags = &h0
		Sub IndexerParsing()
		  ProgressBar.Indeterminate = True
		  ChunkLabel.Text = "Parsing documentation…"
		  HintLabel.Text = "Building the keyword index — takes a minute or two."
		End Sub

		Sub IndexerProgress(chunksProcessed As Integer, totalChunks As Integer)
		  ProgressBar.Indeterminate = False
		  Var pct As Integer = If(totalChunks > 0, (chunksProcessed * 100) \ totalChunks, 0)
		  ProgressBar.Value = pct
		  ChunkLabel.Text = "Processing chunk " + Format(chunksProcessed, "###,###") _
		    + " of " + Format(totalChunks, "###,###")
		  HintLabel.Text = "Building the keyword index — takes a minute or two."
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Sub IndexerEmbedProgress(chunksEmbedded As Integer, totalChunks As Integer)
		  ProgressBar.Indeterminate = False
		  Var pct As Integer = If(totalChunks > 0, (chunksEmbedded * 100) \ totalChunks, 0)
		  ProgressBar.Value = pct
		  ChunkLabel.Text = "Embedding chunk " + Format(chunksEmbedded, "###,###") _
		    + " of " + Format(totalChunks, "###,###")
		  HintLabel.Text = "Embedding for semantic search — about 5 minutes."
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

