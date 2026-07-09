#tag DesktopWindow
Begin DesktopWindow DocsNotInstalledWindow
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
   Height          =   200
   ImplicitInstance=   False
   MacProcID       =   0
   MaximumHeight   =   200
   MaximumWidth    =   480
   MenuBar         =   1984348159
   MenuBarVisible  =   False
   MinimumHeight   =   200
   MinimumWidth    =   480
   Resizeable      =   False
   Title           =   "Documentation Not Installed"
   Type            =   0
   Visible         =   False
   Width           =   480
   Begin DesktopLabel MessageLabel
      AutoDeactivate  =   True
      Bold            =   False
      Enabled         =   True
      FontSize        =   13.0
      FontUnit        =   0
      Height          =   100
      Index           =   -2147483648
      InitialParent   =   ""
      Italic          =   False
      Left            =   24
      LockBottom      =   False
      LockedInPosition=   False
      LockLeft        =   True
      LockRight       =   True
      LockTop         =   True
      Multiline       =   True
      Scope           =   0
      TabIndex        =   0
      TabPanelIndex   =   0
      TabStop         =   True
      Text            =   "Xojo documentation is not installed. Open the Xojo IDE → Settings → General → Install Local Documentation, then relaunch XDOX."
      Tooltip         =   ""
      Top             =   24
      Underline       =   False
      Visible         =   True
      Width           =   432
   End
   Begin DesktopButton QuitButton
      AutoDeactivate  =   True
      Bold            =   False
      Cancel          =   False
      Caption         =   "Quit"
      Default         =   True
      Enabled         =   True
      FontSize        =   13.0
      FontUnit        =   0
      Height          =   32
      Index           =   -2147483648
      InitialParent   =   ""
      Italic          =   False
      Left            =   376
      LockBottom      =   True
      LockedInPosition=   False
      LockLeft        =   False
      LockRight       =   True
      LockTop         =   False
      Scope           =   0
      TabIndex        =   1
      TabPanelIndex   =   0
      TabStop         =   True
      Tooltip         =   ""
      Top             =   148
      Underline       =   False
      Visible         =   True
      Width           =   80
   End
End
#tag EndDesktopWindow

#tag WindowCode
#tag EndWindowCode

#tag Events QuitButton
	#tag Event
		Sub Pressed()
		  Quit
		End Sub
	#tag EndEvent
#tag EndEvents
