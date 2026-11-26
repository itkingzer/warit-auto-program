Option Explicit

Dim shell, files, root, command, argument, result
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
root = files.GetParentFolderName(WScript.ScriptFullName)

command = Quote(shell.ExpandEnvironmentStrings("%SystemRoot%") & _
    "\System32\WindowsPowerShell\v1.0\powershell.exe") & _
    " -NoProfile -STA -ExecutionPolicy Bypass -File " & _
    Quote(files.BuildPath(root, "AutoSetup-GUI.ps1"))

For Each argument In WScript.Arguments
    Select Case LCase(argument)
        Case "-startuplaunch", "-autoinstall", "-resumeonly"
            command = command & " " & argument
        Case Else
            MsgBox "Unknown startup option: " & argument, vbExclamation, "Warit Auto Setup"
            WScript.Quit 1
    End Select
Next

result = shell.Run(command, 0, True)
If result <> 0 Then
    MsgBox "Auto Setup could not start (exit code " & result & "). " & _
        "Run Start-AutoSetup.bat to see the PowerShell error.", vbExclamation, "Warit Auto Setup"
End If
WScript.Quit result

Function Quote(value)
    Quote = Chr(34) & value & Chr(34)
End Function
