Option Explicit
Dim shell, files, script
Set shell = CreateObject("WScript.Shell")
Set files = CreateObject("Scripting.FileSystemObject")
script = files.BuildPath(files.GetParentFolderName(WScript.ScriptFullName), "linux\desktop.ps1")
shell.Run "powershell.exe -WindowStyle Hidden -NoProfile -STA -ExecutionPolicy Bypass -File """ & script & """", 1, False
