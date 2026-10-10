# Attach this machine's Neovim to a workspace's headless Neovim server
# (coder_script.nvim_server in the templates, port 6666 in the workspace).
#
#   .\nvim-coder.ps1 copper-raven-22          # from a terminal
#   nvim-coder://open/<owner>/<workspace>     # the "Neovim" button in Coder (see install.ps1)
#
# Opens a `coder port-forward` tunnel on a free local port, runs `nvim --remote-ui` against it,
# and closes the tunnel when nvim exits.
param(
  [Parameter(Mandatory, Position = 0)][string]$Target
)

$ErrorActionPreference = 'Stop'

function Fail($message) {
  Write-Host $message -ForegroundColor Red
  Read-Host 'Press Enter to close' | Out-Null
  exit 1
}

# Links come from the browser, so accept plain workspace names only
$name = '[A-Za-z0-9_.-]+'
if ($Target -match "^nvim-coder://open/($name)/($name)/?$") {
  $workspace = "$($Matches[1])/$($Matches[2])"
} elseif ($Target -match "^($name/)?$name$") {
  $workspace = $Target
} else {
  Fail "Not a workspace name or nvim-coder link: $Target"
}

# The protocol handler starts us hidden; reopen visibly, in Windows Terminal when available
if ($Target.StartsWith('nvim-coder://')) {
  # Start-Process joins these with spaces without quoting, so quote anything that has spaces
  $self = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", $workspace)
  if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
    Start-Process wt.exe -ArgumentList (@('-w', 'new', '--title', "`"nvim $workspace`"", 'powershell.exe') + $self)
  } else {
    Start-Process powershell.exe -ArgumentList $self
  }
  exit 0
}

$Host.UI.RawUI.WindowTitle = "nvim $workspace"

# A free local port, so several workspaces can be open at once
$probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
$probe.Start()
$port = $probe.LocalEndpoint.Port
$probe.Stop()

Write-Host "Connecting to $workspace ..."
$forward = Start-Process coder -ArgumentList 'port-forward', $workspace, '--tcp', "${port}:6666" `
  -WindowStyle Hidden -PassThru
try {
  # Wait for the tunnel to listen locally
  $deadline = (Get-Date).AddSeconds(30)
  while ($true) {
    if ($forward.HasExited) { Fail "coder port-forward exited (is $workspace running?)" }
    try {
      [System.Net.Sockets.TcpClient]::new('127.0.0.1', $port).Dispose()
      break
    } catch {
      if ((Get-Date) -gt $deadline) { Fail "Timed out waiting for the tunnel to $workspace" }
      Start-Sleep -Milliseconds 300
    }
  }

  nvim --server "127.0.0.1:$port" --remote-ui
} finally {
  if (-not $forward.HasExited) { Stop-Process -Id $forward.Id -Force }
}
