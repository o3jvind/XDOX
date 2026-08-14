#tag DesktopWindow
Begin DesktopWindow Window1
   Backdrop        =   0
   BackgroundColor =   &cFFFFFF
   Composite       =   False
   DefaultLocation =   2
   FullScreen      =   False
   HasBackgroundColor=   False
   HasCloseButton  =   True
   HasFullScreenButton=   False
   HasMaximizeButton=   True
   HasMinimizeButton=   True
   HasTitleBar     =   True
   Height          =   800
   ImplicitInstance=   True
   MacProcID       =   0
   MaximumHeight   =   32000
   MaximumWidth    =   32000
   MenuBar         =   1984348159
   MenuBarVisible  =   False
   MinimumHeight   =   64
   MinimumWidth    =   64
   Resizeable      =   True
   Title           =   "XDOX"
   Type            =   0
   Visible         =   True
   Width           =   800
   Begin DesktopRectangle BannerBackground
      AllowAutoDeactivate=   True
      BorderColor     =   &c000000
      BorderThickness =   1.0
      CornerSize      =   0.0
      Enabled         =   True
      FillColor       =   &cFFF9C2
      Height          =   44
      Index           =   -2147483648
      InitialParent   =   ""
      Left            =   0
      LockBottom      =   False
      LockedInPosition=   False
      LockLeft        =   True
      LockRight       =   True
      LockTop         =   True
      Scope           =   0
      TabIndex        =   0
      TabPanelIndex   =   0
      Tooltip         =   ""
      Top             =   0
      Transparent     =   False
      Visible         =   False
      Width           =   800
   End
   Begin DesktopLabel BannerLabel
      AllowAutoDeactivate=   True
      Bold            =   False
      Enabled         =   True
      FontName        =   "System"
      FontSize        =   12.0
      FontUnit        =   0
      Height          =   20
      Index           =   -2147483648
      InitialParent   =   ""
      Italic          =   False
      Left            =   12
      LockBottom      =   False
      LockedInPosition=   False
      LockLeft        =   True
      LockRight       =   True
      LockTop         =   True
      Multiline       =   False
      Scope           =   0
      Selectable      =   False
      TabIndex        =   1
      TabPanelIndex   =   0
      TabStop         =   False
      Text            =   ""
      TextAlignment   =   0
      TextColor       =   &c000000
      Tooltip         =   ""
      Top             =   12
      Transparent     =   False
      Underline       =   False
      Visible         =   False
      Width           =   520
   End
   Begin DesktopButton BannerIndexNowButton
      AllowAutoDeactivate=   True
      Bold            =   False
      Cancel          =   False
      Caption         =   "Index Now"
      Default         =   False
      Enabled         =   True
      FontName        =   "System"
      FontSize        =   12.0
      FontUnit        =   0
      Height          =   24
      Index           =   -2147483648
      InitialParent   =   ""
      Italic          =   False
      Left            =   544
      LockBottom      =   False
      LockedInPosition=   False
      LockLeft        =   False
      LockRight       =   True
      LockTop         =   True
      MacButtonStyle  =   0
      Scope           =   0
      TabIndex        =   2
      TabPanelIndex   =   0
      TabStop         =   True
      Tooltip         =   ""
      Top             =   10
      Transparent     =   False
      Underline       =   False
      Visible         =   False
      Width           =   110
   End
   Begin DesktopButton BannerLaterButton
      AllowAutoDeactivate=   True
      Bold            =   False
      Cancel          =   False
      Caption         =   "Later"
      Default         =   False
      Enabled         =   True
      FontName        =   "System"
      FontSize        =   12.0
      FontUnit        =   0
      Height          =   24
      Index           =   -2147483648
      InitialParent   =   ""
      Italic          =   False
      Left            =   662
      LockBottom      =   False
      LockedInPosition=   False
      LockLeft        =   False
      LockRight       =   True
      LockTop         =   True
      MacButtonStyle  =   0
      Scope           =   0
      TabIndex        =   3
      TabPanelIndex   =   0
      TabStop         =   True
      Tooltip         =   ""
      Top             =   10
      Transparent     =   False
      Underline       =   False
      Visible         =   False
      Width           =   110
   End
   Begin ChatView MainView
      AutoDeactivate  =   True
      Enabled         =   True
      Height          =   800
      Index           =   -2147483648
      InitialParent   =   ""
      Left            =   0
      LockBottom      =   True
      LockedInPosition=   False
      LockLeft        =   True
      LockRight       =   True
      LockTop         =   True
      Scope           =   0
      TabIndex        =   4
      TabPanelIndex   =   0
      TabStop         =   True
      Tooltip         =   ""
      Top             =   0
      Visible         =   True
      Width           =   800
   End
End
#tag EndDesktopWindow

#tag WindowCode
	#tag Event
		Sub Closing()
		  Quit
		End Sub
	#tag EndEvent

	#tag Event
		Sub Opening()
		  MainView.LoadUI()
		End Sub
	#tag EndEvent


	#tag MenuHandler
		Function EditCut() As Boolean Handles EditCut.Action
		  MainView.EvaluateJavaScript("document.execCommand('cut')")
		  Return True
		End Function
	#tag EndMenuHandler

	#tag MenuHandler
		Function EditCopy() As Boolean Handles EditCopy.Action
		  MainView.EvaluateJavaScript("document.execCommand('copy')")
		  Return True
		End Function
	#tag EndMenuHandler

	#tag MenuHandler
		Function EditSelectAll() As Boolean Handles EditSelectAll.Action
		  MainView.EvaluateJavaScript("document.execCommand('selectAll')")
		  Return True
		End Function
	#tag EndMenuHandler

	#tag MenuHandler
		Function ToolsIndexMBSDocs() As Boolean Handles ToolsIndexMBSDocs.Action
		  App.StartMBSIndexing
		  Return True
		End Function
	#tag EndMenuHandler

	#tag Method, Flags = &h0
		Sub HideBanner()
		  BannerBackground.Visible = False
		  BannerLabel.Visible = False
		  BannerIndexNowButton.Visible = False
		  BannerLaterButton.Visible = False
		  MainView.Top = 0
		  MainView.Height = Self.Height
		End Sub
	#tag EndMethod

	#tag Property, Flags = &h21
		Private mBannerVersion As String
	#tag EndProperty

	#tag Method, Flags = &h0
		Sub ShowVersionBanner(newVersion As String)
		  mBannerVersion = newVersion
		  BannerLabel.Text = newVersion + " documentation detected. Index it now to add it (existing versions are kept)."
		  BannerBackground.Visible = True
		  BannerLabel.Visible = True
		  BannerIndexNowButton.Visible = True
		  BannerLaterButton.Visible = True
		  MainView.Top = 44
		  MainView.Height = Self.Height - 44
		End Sub
	#tag EndMethod


#tag EndWindowCode

#tag Events BannerIndexNowButton
	#tag Event
		Sub Pressed()
		  HideBanner
		  DBHelper.SetMetadata("pending_reindex", "0")
		  // Additive: index the newly-detected version without touching existing
		  // ones. isReindex stays False so no stale-note sweep runs — the other
		  // versions' notes are unaffected.
		  App.StartIndexing(False, mBannerVersion)
		End Sub
	#tag EndEvent
#tag EndEvents
#tag Events BannerLaterButton
	#tag Event
		Sub Pressed()
		  HideBanner
		  DBHelper.SetMetadata("pending_reindex", "1")
		End Sub
	#tag EndEvent
#tag EndEvents
#tag Events MainView
	#tag Event
		Sub Opening()
		  // Debug builds only — don't expose the inspector/DOM in release.
		  #If DebugBuild Then
		    Me.developerExtrasEnabled = True
		  #EndIf
		End Sub
	#tag EndEvent
#tag EndEvents
