Option Explicit
Dim sh, fs, root, command, result
Set sh = CreateObject("WScript.Shell")
Set fs = CreateObject("Scripting.FileSystemObject")
root = fs.GetParentFolderName(WScript.ScriptFullName)
command = """" & sh.ExpandEnvironmentStrings("%WINDIR%") & "\System32\WindowsPowerShell\v1.0\powershell.exe"" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File """ & root & "\run-once.ps1"""
command = command & " -Origin Scheduled"
If WScript.Arguments.Count >= 1 Then command = command & " -DataDirectory """ & WScript.Arguments(0) & """"
If WScript.Arguments.Count = 2 Then
    If WScript.Arguments(1) <> "catch-up" Then WScript.Quit 2
    command = command & " -CatchUp"
End If
If WScript.Arguments.Count > 2 Then WScript.Quit 2
result = sh.Run(command, 0, True)
WScript.Quit result
