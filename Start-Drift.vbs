' Starts Drift with no console window. Double-click this file, or let the
' Startup shortcut (created from Settings or install.cmd) run it at sign-in.
' Pass "demo" as an argument for short intervals:  wscript Start-Drift.vbs demo
Set fso = CreateObject("Scripting.FileSystemObject")
here = fso.GetParentFolderName(WScript.ScriptFullName)
extra = ""
If WScript.Arguments.Count > 0 Then
  If LCase(WScript.Arguments(0)) = "demo" Then extra = " -Demo"
End If
cmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File """ & here & "\drift.ps1""" & extra
CreateObject("WScript.Shell").Run cmd, 0, False
