' voice-typer silent launcher -- runs in background with no console window
' Double-click this file. After that use the tray icon / floating button / hotkey.
'
' Note: if voice-typer is already running, a dialog will tell you so instead of
'       starting a duplicate (duplicates would fight over the global hotkey).
Option Explicit

Dim fso, sh, here, ps1, cmd, pwsh

Set fso = CreateObject("Scripting.FileSystemObject")
Set sh  = CreateObject("WScript.Shell")

here = fso.GetParentFolderName(WScript.ScriptFullName)
ps1  = here & "\voice-typer.ps1"

If Not fso.FileExists(ps1) Then
  MsgBox "Cannot find voice-typer.ps1" & vbCrLf & ps1, 16, "voice-typer"
  WScript.Quit 1
End If

' Prefer the full path to pwsh; fall back to the bare command name.
pwsh = sh.ExpandEnvironmentStrings("%ProgramFiles%") & "\PowerShell\7\pwsh.exe"
If Not fso.FileExists(pwsh) Then pwsh = "pwsh"

' -Notify makes it show one balloon on startup so you can tell it actually launched.
cmd = """" & pwsh & """ -NoLogo -NoProfile -ExecutionPolicy Bypass -File """ & ps1 & """ -Notify"

' 0 = hidden window, False = do not wait for it to finish
sh.Run cmd, 0, False
