Attribute VB_Name = "Macros"
'***************************************************************************
'PhotoDemon Macro Interface
'Copyright 2001-2018 by Tanner Helland
'Created: 10/21/01
'Last updated: 21/June/18
'Last update: better segregate functionality into discrete chunks; this lets us reuse things like the
'             XML exporter in other places (e.g. the new "Create macro from history" tool)
'
'This (relatively small) sub handles all macro-related operations.  Macros are simply a recorded list
' of program operations, which can be "played back" to automate complex lists of image processing actions.
'
'To create a macro, the user current has two options:
' 1) They can "record" themselves applying a series of actions to an image.
' 2) They can retroactively create a macro from a list of operations they've applied during this session.
'
'Either way, a list of specific actions will be exported to file, and that file can then be re-played
' against any image in the future.
'
'PhotoDemon's batch processing wizard has an integrated "play macro on image" tool, so that any combination
' of actions can be applied to any combination of images automatically.  This is a trademark feature of
' the program.
'
'As of 2014, the macro engine has been rewritten in significant ways.  Macros now rely on PhotoDemon's new
' string-based param design, and all macro settings are saved as XML files.  This makes them human-readable
' and human-editable, but it also means that old macro files are no longer supported.  Users of old macro
' files are automatically warned of this change if they try to load an outdated macro file.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit https://photodemon.org/license/
'
'***************************************************************************

Option Explicit

'Macro recording status; the default status is "MacroSTOP", which means "no macro is currently running or recording".
Public Enum PD_MacroStatus
    MacroSTOP = 0
    MacroSTART = 1
    MacroBATCH = 2
    MacroPLAYBACK = 3
    MacroCANCEL = 128
End Enum

#If False Then
    Private Const MacroSTOP = 0, MacroSTART = 1, MacroBATCH = 2, MacroPLAYBACK = 3, MacroCANCEL = 128
#End If

'Macro loading information

'The current macro version string, which must be embedded in every saved macro file.
Private Const MACRO_VERSION_2014 As String = "8.2014"

'During macro recording, all requests to the processor are forwarded to us, and we store them in a running array
Private m_ProcessCount As Long
Private m_Processes() As PD_ProcessCall

'Current macro status; the default status is "MacroSTOP", which means "no macro is currently running or recording".
Private m_MacroStatus As PD_MacroStatus

Public Function GetMacroStatus() As PD_MacroStatus
    GetMacroStatus = m_MacroStatus
End Function

Public Sub SetMacroStatus(ByVal newStatus As PD_MacroStatus)
    m_MacroStatus = newStatus
End Sub

Public Sub StartMacro()
    
    'Set the program-wide "recording" flag
    Macros.SetMacroStatus MacroSTART
    
    'Prep any internal structures related to storing macro data
    m_ProcessCount = 1
    ReDim m_Processes(0 To m_ProcessCount) As PD_ProcessCall
    
    'Update any related macro UI elements
    Macros.UpdateMacroUI True
    
End Sub

'Stop recording the current macro, and offer to save it to file.
Public Sub StopMacro()
    
    'Before stopping the macro, make sure at least one valid, recordable action has occurred.
    Dim i As Long, numOfValidProcesses As Long
    numOfValidProcesses = 0
    
    For i = 0 To m_ProcessCount
        With m_Processes(i)
            If (Len(.pcID) <> 0) And (Not .pcRaiseDialog) And .pcRecorded Then
                numOfValidProcesses = numOfValidProcesses + 1
            End If
        End With
    Next i
    
    If (numOfValidProcesses = 0) Then
    
        'Warn the user that this macro won't be saved unless they keep recording
        Dim msgReturn As VbMsgBoxResult
        msgReturn = Interface.PDMsgBox("This macro does not contain any recordable actions.  Are you sure you want to stop recording?" & vbCrLf & vbCrLf & "(Press No to continue recording.)", vbExclamation Or vbYesNo, "Warning: invalid macro")
        
        If (msgReturn = vbYes) Then
            
            'Update any related macro UI elements
            Macros.UpdateMacroUI False
            
            'Reset the macro engine and exit
            Macros.SetMacroStatus MacroSTOP
            m_ProcessCount = 0
            Message "Macro abandoned."
            Exit Sub
        
        'If the user clicks anything but "yes", exit without making changes (e.g. let them continue recording).
        Else
            Exit Sub
        End If
        
    End If
    
    Macros.SetMacroStatus MacroSTOP
    
    'Update any related macro UI elements
    Macros.UpdateMacroUI False
    
    'If the user cancels the save dialog, we'll raise a warning to tell them that the macro will be lost for good.
    ' That dialog gives them an option to return to the save dialog, which will bring us back to this line of code.
SaveMacroAgain:
     
    'If we get the data we want, save the information
    Dim sFile As String
    If DisplayMacroSaveDialog(sFile) Then
        If ExportProcCallsToMacroFile(sFile, m_Processes, 0, m_ProcessCount) Then Message "Macro saved successfully."
    Else
        
        msgReturn = PDMsgBox("If you do not save this macro, all actions recorded during this session will be permanently lost.  Are you sure you want to cancel?" & vbCrLf & vbCrLf & "(Press No to return to the Save Macro screen.  Note that you can always delete this macro later if you decide you don't want it.)", vbExclamation Or vbYesNo, "Warning: last chance to save macro")
        If (msgReturn = vbNo) Then GoTo SaveMacroAgain
        
        Message "Macro abandoned."
        
    End If
            
    m_ProcessCount = 0
    
End Sub

'Display the "export macro" dialog.  The destination filename, if any, is returned in the srcFilename parameter.
'RETURNS: TRUE if the user clicks OK, FALSE otherwise.
Public Function DisplayMacroSaveDialog(Optional ByRef srcFilename As String = vbNullString) As Boolean
    
    Dim cdFilter As String
    cdFilter = "PhotoDemon " & g_Language.TranslateMessage("Macro") & " (." & MACRO_EXT & ")|*." & MACRO_EXT
    
    Dim cdTitle As String
    cdTitle = g_Language.TranslateMessage("Save macro data")
    
    Dim saveDialog As pdOpenSaveDialog
    Set saveDialog = New pdOpenSaveDialog
    DisplayMacroSaveDialog = saveDialog.GetSaveFileName(srcFilename, , True, cdFilter, 1, UserPrefs.GetMacroPath, cdTitle, "." & MACRO_EXT, GetModalOwner().hWnd)
    
    'On a successful save, set the selected folder as the default macro path
    If DisplayMacroSaveDialog Then UserPrefs.SetMacroPath srcFilename
    
End Function

Public Function ExportProcCallsToMacroFile(ByRef dstFilename As String, ByRef srcProcCalls() As PD_ProcessCall, Optional ByVal startIndex As Long = 0, Optional ByVal endIndex As Long = -1, Optional ByVal addToRecentMacroList As Boolean = True) As Boolean
    
    'If an ending index hasn't been passed, infer it from the passed array size
    If (endIndex < 0) Then endIndex = UBound(srcProcCalls)
    
    'Create a pdXML class, which will help us assemble the macro file
    Dim xmlEngine As pdXML
    Set xmlEngine = New pdXML
    xmlEngine.PrepareNewXML "Macro"
    
    'Write out the XML version we're using for this macro
    xmlEngine.WriteTag "pdMacroVersion", MACRO_VERSION_2014
    
    'We now want to count the number of actual processes that we will be writing to file.  A valid process meets
    ' the following criteria:
    ' 1) It isn't blank/empty
    ' 2) It doesn't display a dialog
    ' 3) It was not specifically marked as "DO_NOT_RECORD"
    
    'Calculate this number now
    Dim numValidActions As Long
    numValidActions = 0
    
    Dim i As Long
    For i = startIndex To endIndex
        With srcProcCalls(i)
            If (LenB(.pcID) <> 0) And (Not .pcRaiseDialog) And .pcRecorded Then
                numValidActions = numValidActions + 1
            End If
        End With
    Next i
    
    'Due to the previous check at the top of this function, we already know how many valid functions are in the process list,
    ' and this value is guaranteed to be non-zero.
    
    'Write out the number of valid processes in the macro
    xmlEngine.WriteTag "processCount", CStr(numValidActions)
    xmlEngine.WriteBlankLine
    
    'Now, write out each macro entry in the source process list
    numValidActions = 0
    
    For i = startIndex To endIndex
        
        With srcProcCalls(i)
        
            'We only want to write out valid processes, using the same criteria as the validation loop above.
            If (LenB(.pcID) <> 0) And (Not .pcRaiseDialog) And .pcRecorded Then
        
                numValidActions = numValidActions + 1
                
                'Start each process entry with a unique identifier
                xmlEngine.WriteTagWithAttribute "processEntry", "index", numValidActions, vbNullString, True
                
                'Write out all the properties of this entry.  (Note that some properties can be inferred, so we don't
                ' need to actually store them inside the file.)
                xmlEngine.WriteTag "ID", .pcID
                xmlEngine.WriteTag "Parameters", .pcParameters
                xmlEngine.WriteTag "MakeUndo", Trim$(Str$(.pcUndoType))
                xmlEngine.WriteTag "Tool", Trim$(Str$(.pcTool))
                
                'Note that the Dialog and Recorded properties are not written to file.  There is no need to remember
                ' them, as we know their values must be FALSE and TRUE, respectively, per the check above.
                
                'Close this process entry
                xmlEngine.CloseTag "processEntry"
                xmlEngine.WriteBlankLine
                
            End If
            
        End With
        
    Next i
    
    'With all tags successfully written, we can now close the XML data and write it out to file.
    ExportProcCallsToMacroFile = xmlEngine.WriteXMLToFile(dstFilename)
    
    'Update the Recent Macros list
    If addToRecentMacroList Then g_RecentMacros.MRU_AddNewFile dstFilename
    
End Function

'All macro-related UI instructions should be placed here, as PD can terminate a macro recording session for any number of reasons,
' and it needs a uniform way to wipe macro-related UI changes).
Private Sub UpdateMacroUI(ByVal recordingIsActive As Boolean)

    If recordingIsActive Then
    
        'Notify the user that recording has begun
        Message "Macro recording started."
        toolbar_Toolbox.lblRecording.Visible = True
        
        'Disable "start recording", and enable "stop recording"
        FormMain.MnuMacroCreate(2).Enabled = False
        FormMain.MnuMacroCreate(3).Enabled = True
    
    Else
        Message "Macro recording stopped."
        toolbar_Toolbox.lblRecording.Visible = False
        FormMain.MnuMacroCreate(2).Enabled = True
        FormMain.MnuMacroCreate(3).Enabled = False
    End If

End Sub

Public Sub PlayMacro()

    'Disable user input until the dialog closes
    Interface.DisableUserInput

    'Automatically launch the load Macro data routine
    Dim openDialog As pdOpenSaveDialog
    Set openDialog = New pdOpenSaveDialog
        
    Dim cdFilter As String
    cdFilter = "PhotoDemon " & g_Language.TranslateMessage("Macro") & " (." & MACRO_EXT & ")|*." & MACRO_EXT & ";*.thm"
    cdFilter = cdFilter & "|" & g_Language.TranslateMessage("All files") & "|*.*"
    
    Dim cdTitle As String
    cdTitle = g_Language.TranslateMessage("Open Macro File")
        
    'If we get a path, load that file
    Dim sFile As String
    If openDialog.GetOpenFileName(sFile, , True, , cdFilter, 1, UserPrefs.GetMacroPath, cdTitle, "." & MACRO_EXT, GetModalOwner().hWnd) Then
        
        Message "Loading macro data..."
        
        'Save this macro's folder as the default macro path
        UserPrefs.SetMacroPath sFile
                
        Macros.PlayMacroFromFile sFile
        
    Else
        Message "Macro load canceled."
    End If
    
    'Re-enable user input
    Interface.EnableUserInput
        
End Sub

'Given a valid macro file, play back its recorded actions.
Public Function PlayMacroFromFile(ByRef srcMacroPath As String) As Boolean
    
    Dim i As Long
    
    'Create a pdXML class, which will help us load and parse the source file
    Dim xmlEngine As pdXML
    Set xmlEngine = New pdXML
    
    'Load the XML file into memory
    xmlEngine.LoadXMLFile srcMacroPath
    
    'Check for a few necessary tags, just to make sure this is actually a PhotoDemon macro file
    If xmlEngine.IsPDDataType("Macro") And xmlEngine.ValidateLoadedXMLData("pdMacroVersion") Then
    
        'Next, check the macro's version number, and make sure it's still supported
        Dim verCheck As String
        verCheck = xmlEngine.GetUniqueTag_String("pdMacroVersion")
        
        Select Case verCheck
        
            'The current macro version (e.g. the first draft of the new XML format)
            Case MACRO_VERSION_2014
            
                'Retrieve the number of processes in this macro
                m_ProcessCount = xmlEngine.GetUniqueTag_Long("processCount")
                
                If (m_ProcessCount > 0) Then
                
                    ReDim m_Processes(0 To m_ProcessCount - 1) As PD_ProcessCall
                    
                    'Start retrieving individual process data from the file
                    For i = 1 To m_ProcessCount
                    
                        'Start by finding the location of the tag we want
                        Dim tagPosition As Long
                        tagPosition = xmlEngine.GetLocationOfTagPlusAttribute("processEntry", "index", i)
                        
                        If (tagPosition > 0) Then
                        
                            'Use that tag position to retrieve the processor parameters we need.
                            With m_Processes(i - 1)
                                .pcID = xmlEngine.GetUniqueTag_String("ID", , tagPosition)
                                .pcParameters = xmlEngine.GetUniqueTag_String("Parameters", , tagPosition)
                                .pcUndoType = xmlEngine.GetUniqueTag_Long("MakeUndo", , tagPosition)
                                .pcTool = xmlEngine.GetUniqueTag_Long("Tool", , tagPosition)
                                
                                'These two attributes can be assigned automatically, as we know what their values must be.
                                .pcRaiseDialog = False
                                .pcRecorded = True
                            End With
                            
                        Else
                            Debug.Print "Expected macro entry could not be found!"
                        End If
                    
                    Next i
                    
                'This macro file contains no valid actions.  It's no longer possible to create a macro like this, so this is basically
                ' a failsafe for faulty old versions of PD.
                Else
                    
                    PDDebug.LogAction "WARNING!  m_ProcessCount is zero!  Macro file is technically valid, but there's nothing to see here..."
                    
                    Message "Macro complete!"
                    PlayMacroFromFile = True
                    Exit Function
                    
                End If
            
            Case Else
                Message "Incompatible macro version found.  Macro playback abandoned."
                PlayMacroFromFile = False
                Exit Function
        
        End Select
        
        'Mark the load as successful and continue
        PlayMacroFromFile = True
        
    Else
    
        PDMsgBox "Unfortunately, this macro file is no longer supported by the current version of PhotoDemon." & vbCrLf & vbCrLf & "In version 6.0, PhotoDemon macro files were redesigned to support new features, improve performance, and solve some long-standing reliability issues.  Unfortunately, this means that macros recorded prior to version 6.0 are no longer compatible.  You will need to re-record these macros from scratch." & vbCrLf & vbCrLf & "(Note that any old macro files will still work in old versions of PhotoDemon, if you absolutely need to access them.)", vbExclamation Or vbOKOnly, "Unsupported macro file"
        PlayMacroFromFile = False
        Exit Function
        
    End If
    
    'Now we run a loop through the macro structure, calling the software processor with all the necessary information for each action
    Message "Processing macro data..."
    
    If (Macros.GetMacroStatus <> MacroBATCH) Then Macros.SetMacroStatus MacroPLAYBACK
    
    For i = 0 To m_ProcessCount - 1
        With m_Processes(i)
            Processor.Process .pcID, .pcRaiseDialog, .pcParameters, .pcUndoType, .pcTool, .pcRecorded
        End With
    Next i
    
    If (Macros.GetMacroStatus <> MacroBATCH) Then Macros.SetMacroStatus MacroSTOP
    
    'Some processor requests may not manually update the screen; as such, perform a manual update now
    ViewportEngine.Stage2_CompositeAllLayers pdImages(g_CurrentImage), FormMain.MainCanvas(0)
    
    'Our work here is complete!
    Message "Macro complete!"
    
    'After playing, the macro should be added to the Recent Macros list
    g_RecentMacros.MRU_AddNewFile srcMacroPath
    
End Function

Public Sub NotifyProcessorEvent(ByRef srcProcData As PD_ProcessCall)

    'At present, PD only records actions when a macro is actively running.  (In the future, it may be cool
    ' to *always* record user actions, and allow the user to create macros from anything they've done in a
    ' given session.)
    If (Macros.GetMacroStatus = MacroSTART) And srcProcData.pcRecorded Then
    
        'Increase the process count
        m_ProcessCount = m_ProcessCount + 1
        
        'Copy the current process's information into the tracking array
        ReDim Preserve m_Processes(0 To m_ProcessCount) As PD_ProcessCall
        m_Processes(m_ProcessCount) = srcProcData
        
    End If
    
End Sub
