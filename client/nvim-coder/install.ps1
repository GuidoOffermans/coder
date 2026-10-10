# Registers nvim-coder:// links for the current user (no admin needed), so the "Neovim" button
# in Coder workspaces opens nvim-coder.ps1. Re-run after moving this folder.
# Uninstall: Remove-Item -Recurse HKCU:\Software\Classes\nvim-coder

$script = Join-Path $PSScriptRoot 'nvim-coder.ps1'
$key = 'HKCU:\Software\Classes\nvim-coder'

New-Item -Path "$key\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path $key -Name '(default)' -Value 'URL:Neovim on Coder'
Set-ItemProperty -Path $key -Name 'URL Protocol' -Value ''
# Starts hidden; the script validates the link and reopens itself in a terminal
Set-ItemProperty -Path "$key\shell\open\command" -Name '(default)' `
  -Value "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" `"%1`""

Write-Host "Registered nvim-coder:// -> $script"
