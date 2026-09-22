' DeepSeek balance whale widget - silent launcher.
'
' Purpose: start the widget without flashing a PowerShell console window.
' The autostart shortcut points here; double-click it to start manually.
' Prefers the renamed host copy (deepseek-balance.exe) so Task Manager shows
' "deepseek-balance" instead of "powershell"; falls back to powershell.exe.
' (Kept ASCII-only so any Windows Script Host locale can parse it.)
Option Explicit

Dim fso, shell, root, stateDir, hostExe, command, userProfile
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

root = fso.GetParentFolderName(WScript.ScriptFullName)

stateDir = shell.ExpandEnvironmentStrings("%DEEPSEEK_BALANCE_STATE_DIR%")
If stateDir = "%DEEPSEEK_BALANCE_STATE_DIR%" Or Len(stateDir) = 0 Then
    userProfile = shell.ExpandEnvironmentStrings("%USERPROFILE%")
    If Len(userProfile) = 0 Then userProfile = shell.ExpandEnvironmentStrings("%HOMEDRIVE%") & shell.ExpandEnvironmentStrings("%HOMEPATH%")
    stateDir = userProfile & "\.codex\deepseek-balance"
End If

hostExe = stateDir & "\deepseek-balance.exe"
If Not fso.FileExists(hostExe) Then hostExe = "powershell.exe"

command = """" & hostExe & """ -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
    & root & "\widget.ps1"" -Action start"

' 0 = hidden window, False = do not wait
shell.Run command, 0, False
