' NotificationForwarder - Hidden Watchdog Launcher
' Uses Windows Script Host (wscript.exe GUI subsystem) to launch PowerShell
' without creating or flashing a console window (SW_HIDE = 0).

Option Explicit

Dim oShell, oFSO, sScriptDir, sPowerShell, sWatchdogScript, sLogPath, sCommand
Dim i, sArgs

Set oShell = CreateObject("WScript.Shell")
Set oFSO = CreateObject("Scripting.FileSystemObject")

' Resolve project directory dynamically from launcher location
sScriptDir = oFSO.GetParentFolderName(WScript.ScriptFullName)
sWatchdogScript = sScriptDir & "\Watchdog.ps1"
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
sCommand = """" & sPowerShell & """ -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File """ & sWatchdogScript & """" & sArgs

' Run hidden (0 = SW_HIDE) without waiting for completion (False)
oShell.Run sCommand, 0, False