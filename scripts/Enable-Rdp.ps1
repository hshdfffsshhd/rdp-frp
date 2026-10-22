[CmdletBinding()]
param(
    [string]$FirewallRuleName = "RDP-frp",
    [switch]$KeepNla
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "FrpHelpers.ps1")

if (-not (Test-IsAdministrator)) {
    throw "Enable-Rdp.ps1 must run as Administrator."
}

$tsKey = "HKLM:\System\CurrentControlSet\Control\Terminal Server"
$rdpTcpKey = "HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp"

$edition = ""
try {
    $edition = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion" -Name EditionID -ErrorAction Stop).EditionID
} catch { }
if ($edition -match "Home") {
    Write-Warning "Windows edition '$edition' does not include an RDP server. Remote Desktop may not work."
}

Write-Host "[*] Enabling Remote Desktop..."
Set-ItemProperty -Path $tsKey -Name "fDenyTSConnections" -Value 0 -Force
if (-not $KeepNla) {
    # Same behaviour as the reference workflow: allow clients without NLA/TLS.
    Set-ItemProperty -Path $rdpTcpKey -Name "UserAuthentication" -Value 0 -Force
    Set-ItemProperty -Path $rdpTcpKey -Name "SecurityLayer" -Value 0 -Force
}

try {
    Set-Service -Name TermService -StartupType Automatic -ErrorAction Stop
} catch {
    Write-Warning "Could not set TermService startup type: $($_.Exception.Message)"
}

Write-Host "[*] Configuring firewall rule '$FirewallRuleName' for TCP 3389..."
netsh advfirewall firewall delete rule name="$FirewallRuleName" | Out-Null
netsh advfirewall firewall add rule name="$FirewallRuleName" dir=in action=allow protocol=TCP localport=3389 | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Failed to add firewall rule '$FirewallRuleName'."
}

Write-Host "[*] Restarting TermService..."
Restart-Service -Name TermService -Force

$deadline = (Get-Date).AddSeconds(60)
$listener = $null
do {
    $listener = Get-NetTCPConnection -LocalPort 3389 -State Listen -ErrorAction SilentlyContinue
    if (-not $listener) { Start-Sleep -Seconds 2 }
} while (-not $listener -and (Get-Date) -lt $deadline)

if (-not $listener) {
    throw "RDP listener on TCP 3389 did not start. Windows Home editions cannot host RDP."
}

Write-Host "[+] RDP is enabled and listening on TCP 3389."
