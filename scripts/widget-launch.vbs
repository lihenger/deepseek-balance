' DeepSeek balance whale widget - silent launcher.
'
' Purpose: start the widget without flashing a PowerShell console window.
' The autostart shortcut points here; double-click it to start manually.
' (Kept ASCII-only so any Windows Script Host locale can parse it.)
Option Explicit

Dim fso, shell, root, command
Set fso = CreateObject("Scripting.FileSystemObject")
Set shell = CreateObject("WScript.Shell")

root = fso.GetParentFolderName(WScript.ScriptFullName)
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ _
    & root & "\widget.ps1"" -Action start"

' 0 = hidden window, False = do not wait
shell.Run command, 0, False
