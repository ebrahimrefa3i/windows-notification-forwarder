' NotificationForwarder - Hidden Forwarder Launcher
' Uses Windows Script Host (wscript.exe GUI subsystem) to launch PowerShell
' without creating or flashing a console window (SW_HIDE = 0).
' Waits for PowerShell process so Task Scheduler monitors execution state.

Option Explicit

Dim oShell, oFSO, sScriptDir, sPowerShell, sForwarderScript, sLogPath, sCommand
Dim i, sArgs, iExitCode

Set oShell = CreateObject("WScript.Shell")
Set oFSO = CreateObject("Scripting.FileSystemObject")

' Resolve project directory dynamically from launcher location
sScriptDir = oFSO.GetParentFolderName(WScript.ScriptFullName)
sForwarderScript = sScriptDir & "\NotificationForwarder.ps1"
sLogPath = sScriptDir & "\forwarder.log"

sPowerShell = oShell.ExpandEnvironmentStrings("%SystemRoot%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"
If Not oFSO.FileExists(sPowerShell) Then
    sPowerShell = "powershell.exe"
End If

sArgs = ""
If WScript.Arguments.Count > 0 Then
    For i = 0 To WScript.Arguments.Count - 1
        Dim arg
        arg = WScript.Arguments(i)
        If InStr(arg, " ") > 0 And Left(arg, 1) <> """" Then
            arg = """" & arg & """"
        End If
        sArgs = sArgs & " " & arg
    Next
Else
    sArgs = " -LogPath """ & sLogPath & """"
End If

' Fully quote executable and arguments
sCommand = """" & sPowerShell & """ -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & sForwarderScript & """" & sArgs

' Run hidden (0 = SW_HIDE) and wait for completion (True)
iExitCode = oShell.Run(sCommand, 0, True)
WScript.Quit iExitCode
