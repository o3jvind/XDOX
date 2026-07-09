#tag Module
Protected Module Paths

	#tag Method, Flags = &h0
		Function AppSupport() As FolderItem
		  Var id As String = AppBundleId
		  If id = "" Then id = "xdox"
		  Var f As FolderItem = SpecialFolder.ApplicationData.Child(id)
		  If f <> Nil And Not f.Exists Then f.CreateFolder
		  Return f
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function DatabaseFile() As FolderItem
		  Return AppSupport.Child("xdox.db")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function DebugLog() As FolderItem
		  Return AppSupport.Child("XDOX_debug.log")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function XojoDocsBase() As FolderItem
		  Return SpecialFolder.ApplicationData.Child("Xojo").Child("Xojo")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function AppBundleId() As String
		  #If TargetMacOS Then
		    Declare Function NSClassFromString Lib "AppKit" (className As CFStringRef) As Ptr
		    Declare Function mainBundle Lib "AppKit" Selector "mainBundle" (NSBundleClass As Ptr) As Ptr
		    Declare Function bundleIdentifier Lib "AppKit" Selector "bundleIdentifier" (NSBundleRef As Ptr) As CFStringRef
		    Return bundleIdentifier(mainBundle(NSClassFromString("NSBundle")))
		  #Else
		    Return ""
		  #EndIf
		End Function
	#tag EndMethod

End Module
#tag EndModule
