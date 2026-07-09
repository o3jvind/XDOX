#tag Module
Protected Module DocDetector

	#tag Method, Flags = &h0
		Function FindLatestDocsVersion() As String
		  Var versions() As String = InstalledVersions
		  If versions.Count = 0 Then Return ""
		  Return versions(0) // InstalledVersions is sorted newest-first
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function InstalledVersions() As String()
		  // Every Xojo version folder under XojoDocsBase whose name matches the
		  // version pattern (4-digit year + "r"), sorted newest-first. Basis for the
		  // version picker and for detecting versions available to index.
		  Var result() As String
		  Var base As FolderItem = Paths.XojoDocsBase
		  If base = Nil Or Not base.Exists Then Return result

		  Var count As Integer = base.Count
		  For i As Integer = 0 To count - 1
		    Var f As FolderItem = base.ChildAt(i)
		    If f = Nil Or Not f.IsFolder Then Continue
		    Var name As String = f.Name
		    // Only include folders containing a Xojo version pattern: 4 digits followed by "r"
		    // e.g. "Xojo 2026r1.2", "2025r2"
		    Var lower As String = name.Lowercase
		    Var rPos As Integer = lower.IndexOf("r")
		    If rPos >= 4 And name.Length > rPos + 1 Then
		      Var beforeR As String = name.Middle(rPos - 4, 4)
		      Var allDigits As Boolean = True
		      Var ci As Integer = 0
		      While ci < 4
		        Var ch As String = beforeR.Middle(ci, 1)
		        If ch < "0" Or ch > "9" Then allDigits = False
		        ci = ci + 1
		      Wend
		      // Only versions that actually have a docs file are indexable.
		      If allDigits And FindLlmsFullTxtFor(name) <> Nil Then result.Add(name)
		    End If
		  Next

		  If result.Count = 0 Then Return result

		  // Sort descending by version string (e.g. "2025r2" > "2025r1" > "2024r4")
		  Var n As Integer = result.LastIndex
		  For i As Integer = 0 To n - 1
		    For j As Integer = 0 To n - i - 1
		      If VersionCompare(result(j), result(j + 1)) < 0 Then
		        Var tmp As String = result(j)
		        result(j) = result(j + 1)
		        result(j + 1) = tmp
		      End If
		    Next
		  Next

		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function VersionCompare(a As String, b As String) As Integer
		  // Compares version strings like "2025r2", "Xojo 2026r1.2".
		  // Extracts the 4-digit year before "r" and the release number after "r".
		  // Returns >0 if a > b, <0 if a < b, 0 if equal.
		  Try
		    Var aRPos As Integer = a.Lowercase.IndexOf("r")
		    Var bRPos As Integer = b.Lowercase.IndexOf("r")
		    If aRPos >= 4 And bRPos >= 4 Then
		      Var aYear As Integer = Integer.FromString(a.Middle(aRPos - 4, 4))
		      Var bYear As Integer = Integer.FromString(b.Middle(bRPos - 4, 4))
		      If aYear <> bYear Then Return aYear - bYear
		      // Release: major then minor (patch), e.g. r1.2 → (1, 2).
		      Var aMajor, aMinor, bMajor, bMinor As Integer
		      ParseRelease(a, aRPos, aMajor, aMinor)
		      ParseRelease(b, bRPos, bMajor, bMinor)
		      If aMajor <> bMajor Then Return aMajor - bMajor
		      Return aMinor - bMinor
		    End If
		  Catch e As RuntimeException
		    // Fall through to lexicographic compare
		  End Try
		  If a > b Then Return 1
		  If a < b Then Return -1
		  Return 0
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Sub ParseRelease(s As String, rPos As Integer, ByRef major As Integer, ByRef minor As Integer)
		  // Parses the release number after "r" into major and minor (patch) parts,
		  // e.g. "2026r1.2" → major=1, minor=2; "2025r2" → major=2, minor=0.
		  // Without this, "r1.2" and "r1.10" would both collapse to release 1.
		  major = 0
		  minor = 0
		  Var majorStr As String = ""
		  Var minorStr As String = ""
		  Var i As Integer = rPos + 1
		  // Major: digits immediately after "r".
		  While i < s.Length
		    Var ch As String = s.Middle(i, 1)
		    If ch < "0" Or ch > "9" Then Exit
		    majorStr = majorStr + ch
		    i = i + 1
		  Wend
		  // Minor: digits after a "." separator, if present.
		  If i < s.Length And s.Middle(i, 1) = "." Then
		    i = i + 1
		    While i < s.Length
		      Var ch As String = s.Middle(i, 1)
		      If ch < "0" Or ch > "9" Then Exit
		      minorStr = minorStr + ch
		      i = i + 1
		    Wend
		  End If
		  If majorStr <> "" Then major = Integer.FromString(majorStr)
		  If minorStr <> "" Then minor = Integer.FromString(minorStr)
		End Sub
	#tag EndMethod

	#tag Method, Flags = &h0
		Function FindLlmsFullTxt() As FolderItem
		  Var version As String = FindLatestDocsVersion
		  If version = "" Then Return Nil
		  Return FindLlmsFullTxtFor(version)
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function FindLlmsFullTxtFor(version As String) As FolderItem
		  // The llms-full.txt for a specific installed version folder.
		  If version = "" Then Return Nil
		  Var base As FolderItem = Paths.XojoDocsBase
		  If base = Nil Then Return Nil
		  Var f As FolderItem = base.Child(version).Child("Documentation").Child("llms-full.txt")
		  If f <> Nil And f.Exists Then Return f
		  Return Nil
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function OrphanedIndexedVersions() As String()
		  // Versions present in the DB whose Xojo docs folder is no longer installed
		  // — candidates for housekeeping cleanup.
		  Var result() As String
		  Var installed() As String = InstalledVersions
		  For Each indexed As String In DBHelper.IndexedVersions
		    Var found As Boolean = False
		    For Each inst As String In installed
		      If inst = indexed Then
		        found = True
		        Exit
		      End If
		    Next
		    If Not found Then result.Add(indexed)
		  Next
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function UnindexedInstalledVersions() As String()
		  // Installed Xojo versions not yet present in the DB — offered for indexing
		  // (added, never replacing existing versions).
		  Var result() As String
		  Var indexed() As String = DBHelper.IndexedVersions
		  For Each inst As String In InstalledVersions
		    Var found As Boolean = False
		    For Each idx As String In indexed
		      If idx = inst Then
		        found = True
		        Exit
		      End If
		    Next
		    If Not found Then result.Add(inst)
		  Next
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function CurrentIndexedVersion() As String
		  Return DBHelper.GetMetadata("docs_version")
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function DocsInstalled() As Boolean
		  Return FindLlmsFullTxt <> Nil
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function NeedsReindex() As Boolean
		  If Not DocsInstalled Then Return True
		  If DBHelper.ChunkCount = 0 Then Return True
		  If FindLatestDocsVersion <> CurrentIndexedVersion Then Return True
		  Return False
		End Function
	#tag EndMethod

	#tag Method, Flags = &h0
		Function VersionIsNewer(candidate As String, current As String) As Boolean
		  // Returns True if candidate version > current version.
		  // Handles strings like "Xojo 2026r1.2", "2025r2".
		  Var cRPos As Integer = candidate.Lowercase.IndexOf("r")
		  Var kRPos As Integer = current.Lowercase.IndexOf("r")
		  If cRPos < 4 Or kRPos < 4 Then Return False
		  Try
		    Var cYear As Integer = Integer.FromString(candidate.Middle(cRPos - 4, 4))
		    Var kYear As Integer = Integer.FromString(current.Middle(kRPos - 4, 4))
		    If cYear <> kYear Then Return cYear > kYear
		    // Same year — compare release major then minor (patch), e.g. r1.2 vs r1.10.
		    Var cMajor, cMinor, kMajor, kMinor As Integer
		    ParseRelease(candidate, cRPos, cMajor, cMinor)
		    ParseRelease(current, kRPos, kMajor, kMinor)
		    If cMajor <> kMajor Then Return cMajor > kMajor
		    Return cMinor > kMinor
		  Catch e As RuntimeException
		    Return False
		  End Try
		End Function
	#tag EndMethod

End Module
#tag EndModule
