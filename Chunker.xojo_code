#tag Class
Public Class Chunker

	#tag Method, Flags = &h0
		Constructor(maxChars As Integer, targetChars As Integer)
		  mMaxChars = maxChars
		  mTargetChars = targetChars
		End Constructor
	#tag EndMethod

	#tag Method, Flags = &h0
		Function SplitIfNeeded(chunks() As DocChunk) As DocChunk()
		  Var result() As DocChunk
		  For Each chunk As DocChunk In chunks
		    If chunk.ChunkText.Length <= mMaxChars Then
		      result.Add(chunk)
		    Else
		      Var subChunks() As DocChunk = SplitChunk(chunk)
		      For si As Integer = 0 To subChunks.LastIndex
		        result.Add(subChunks(si))
		      Next si
		    End If
		  Next chunk
		  Return result
		End Function
	#tag EndMethod

	#tag Method, Flags = &h21
		Private Function SplitChunk(chunk As DocChunk) As DocChunk()
		  Var result() As DocChunk
		  Var paragraphs() As String
		  Var rawLines() As String
		  Var current As String = ""
		  Var accumChars As Integer = 0
		  Var accumParts() As String
		  Var partNum As Integer = 1
		  Var newChunk As DocChunk
		  Var para As String

		  rawLines = chunk.ChunkText.Split(Chr(10))
		  For ri As Integer = 0 To rawLines.LastIndex
		    Var rawLine As String = rawLines(ri)
		    If rawLine.Trim = "" Then
		      If current <> "" Then
		        paragraphs.Add(current.Trim)
		        current = ""
		      End If
		    Else
		      If current <> "" Then current = current + Chr(10)
		      current = current + rawLine
		    End If
		  Next
		  If current <> "" Then paragraphs.Add(current.Trim)

		  For pi As Integer = 0 To paragraphs.LastIndex
		    para = paragraphs(pi)

		    If para.Length > mTargetChars Then
		      If accumParts.Count > 0 Then
		        newChunk = New DocChunk
		        newChunk.Title = chunk.Title + " (part " + partNum.ToString + ")"
		        newChunk.Source = chunk.Source
		        newChunk.ChunkText = Join(accumParts, Chr(10) + Chr(10))
		        result.Add(newChunk)
		        partNum = partNum + 1
		        accumParts.ResizeTo(-1)
		        accumChars = 0
		      End If
		      Var pos As Integer = 0
		      Var prevSliceText As String = ""
		      While pos < para.Length
		        Var overlapPrefix As String = ""
		        If prevSliceText.Length > 0 Then
		          Var overlapStart As Integer = prevSliceText.Length - kOverlapChars
		          If overlapStart < 0 Then overlapStart = 0
		          While overlapStart < prevSliceText.Length And prevSliceText.Middle(overlapStart, 1) <> " "
		            overlapStart = overlapStart + 1
		          Wend
		          If overlapStart < prevSliceText.Length Then
		            overlapPrefix = prevSliceText.Middle(overlapStart + 1)
		          End If
		        End If

		        Var slice As String = para.Middle(pos, mTargetChars)
		        If pos + mTargetChars < para.Length Then
		          Var searchPos As Integer = slice.Length - 1
		          Var lastSpace As Integer = -1
		          While searchPos > mTargetChars \ 2
		            If slice.Middle(searchPos, 1) = " " Then
		              lastSpace = searchPos
		              Exit
		            End If
		            searchPos = searchPos - 1
		          Wend
		          If lastSpace > 0 Then
		            slice = para.Middle(pos, lastSpace)
		          End If
		        End If
		        prevSliceText = slice

		        newChunk = New DocChunk
		        newChunk.Title = chunk.Title + " (part " + partNum.ToString + ")"
		        newChunk.Source = chunk.Source
		        If overlapPrefix <> "" Then
		          newChunk.ChunkText = overlapPrefix.Trim + Chr(10) + Chr(10) + slice.Trim
		        Else
		          newChunk.ChunkText = slice.Trim
		        End If
		        result.Add(newChunk)
		        partNum = partNum + 1
		        pos = pos + slice.Length
		      Wend
		      Continue
		    End If

		    If accumChars > 0 And accumChars + para.Length > mTargetChars Then
		      Var emittedText As String = Join(accumParts, Chr(10) + Chr(10))
		      newChunk = New DocChunk
		      newChunk.Title = chunk.Title + " (part " + partNum.ToString + ")"
		      newChunk.Source = chunk.Source
		      newChunk.ChunkText = emittedText
		      result.Add(newChunk)
		      partNum = partNum + 1

		      Var overlapStart As Integer = emittedText.Length - kOverlapChars
		      If overlapStart < 0 Then overlapStart = 0
		      While overlapStart < emittedText.Length And emittedText.Middle(overlapStart, 1) <> " "
		        overlapStart = overlapStart + 1
		      Wend
		      Var overlapText As String = ""
		      If overlapStart < emittedText.Length Then
		        overlapText = emittedText.Middle(overlapStart + 1).Trim
		      End If

		      accumParts.ResizeTo(-1)
		      accumChars = 0
		      If overlapText <> "" Then
		        accumParts.Add(overlapText)
		        accumChars = overlapText.Length
		      End If
		    End If
		    accumParts.Add(para)
		    accumChars = accumChars + para.Length
		  Next

		  If accumParts.Count > 0 Then
		    newChunk = New DocChunk
		    If partNum > 1 Then
		      newChunk.Title = chunk.Title + " (part " + partNum.ToString + ")"
		    Else
		      newChunk.Title = chunk.Title
		    End If
		    newChunk.Source = chunk.Source
		    newChunk.ChunkText = Join(accumParts, Chr(10) + Chr(10))
		    result.Add(newChunk)
		  End If

		  If result.Count = 0 Then result.Add(chunk)
		  Return result
		End Function
	#tag EndMethod

	#tag Property, Flags = &h21
		Private mMaxChars As Integer
	#tag EndProperty

	#tag Property, Flags = &h21
		Private mTargetChars As Integer
	#tag EndProperty

	#tag Constant, Name = kOverlapChars, Type = Integer, Dynamic = False, Default = \"200", Scope = Private
	#tag EndConstant

End Class
#tag EndClass
