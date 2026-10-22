[CmdletBinding()]
param(
    [string]$ServerAddr = "47.98.228.129",
    [int]$ServerPort = 7000,
    [int]$RemotePort = 0,
    [int[]]$PreferredRemotePorts = @(),
    [string]$UserName = "RDP",
    [string]$Password = "",
    [string]$Token = "",
    [switch]$NoEncryption,
    [string]$WorkDir = "$env:ProgramData\rdp-frp",
    [string]$FrpcPath = "",
    [string]$FrpVersion = "",
    [string]$FrpZip = "",
    [string]$DownloadUrl = "",
    [switch]$UseMirror,
    [int]$MinRemotePort = 30000,
    [int]$MaxRemotePort = 49999,
    [int]$MaxAttempts = 30,
    [switch]$SkipRdpSetup,
    [switch]$SkipVerify,
    [switch]$TcpOnly,
    [switch]$KeepNla,
    [switch]$HidePassword,
    [switch]$Supervise
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "FrpHelpers.ps1")

if (-not (Test-IsAdministrator)) {
    throw "Run this script from an elevated PowerShell (Run as Administrator)."
}

if (-not $Password -and $env:RDP_PASSWORD) {
    $Password = $env:RDP_PASSWORD
}

$credFile = Join-Path $WorkDir "credentials.json"
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
Protect-Directory -Path $WorkDir

if (-not $SkipRdpSetup) {
    Write-Step "Step 1/4 - Enabling Remote Desktop"
    & (Join-Path $PSScriptRoot "Enable-Rdp.ps1") -KeepNla:$KeepNla

    Write-Step "Step 2/4 - Creating the RDP user"
    & (Join-Path $PSScriptRoot "New-RdpUser.ps1") -UserName $UserName -Password $Password -CredentialFile $credFile -HidePassword:$HidePassword
} else {
    Write-Step "Step 1/4 - Reusing the existing RDP configuration"
    if (-not (Test-Path -LiteralPath $credFile)) {
        Write-TextFileNoBom -Path $credFile -Content (([ordered]@{
            userName  = $UserName
            password  = $Password
            createdAt = (Get-Date).ToString("o")
        }) | ConvertTo-Json)
    }
}

$credentials = Get-Content -LiteralPath $credFile -Raw | ConvertFrom-Json
$rdpUser = $credentials.userName
$rdpPassword = $credentials.password

Write-Step "Step 3/4 - Installing frpc"
if (-not $FrpcPath) {
    $installOutput = & (Join-Path $PSScriptRoot "Install-Frpc.ps1") `
        -Version $FrpVersion `
        -LocalZip $FrpZip `
        -DownloadUrl $DownloadUrl `
        -UseMirror:$UseMirror
    $FrpcPath = @($installOutput)[-1]
}
if (-not $FrpcPath -or -not (Test-Path -LiteralPath $FrpcPath)) {
    throw "frpc.exe was not found after installation."
}

Write-Step "Step 4/4 - Establishing the frp tunnel"
& (Join-Path $PSScriptRoot "Start-FrpTunnel.ps1") `
    -ServerAddr $ServerAddr `
    -ServerPort $ServerPort `
    -RemotePort $RemotePort `
    -PreferredRemotePorts $PreferredRemotePorts `
    -FrpcPath $FrpcPath `
    -WorkDir $WorkDir `
    -Token $Token `
    -NoEncryption:$NoEncryption `
    -MinRemotePort $MinRemotePort `
    -MaxRemotePort $MaxRemotePort `
    -MaxAttempts $MaxAttempts `
    -SkipVerify:$SkipVerify `
    -TcpOnly:$TcpOnly `
    -UserName $rdpUser `
    -Password $rdpPassword `
    -HidePassword:$HidePassword

if (-not $SkipVerify) {
    Write-Step "Verifying RDP accessibility"
    & (Join-Path $PSScriptRoot "Test-FrpTunnel.ps1") -TcpOnly:$TcpOnly -HidePassword:$HidePassword
}

if ($Supervise) {
    Write-Step "Supervising the tunnel (Ctrl+C stops the supervisor, frpc keeps running)"
    & (Join-Path $PSScriptRoot "Watch-FrpTunnel.ps1") -HidePassword:$HidePassword
} else {
    Write-Host ""
    Write-Host "[+] Setup complete. frpc keeps running in the background."
    Write-Host "    To supervise it: .\scripts\Watch-FrpTunnel.ps1"
    Write-Host "    To stop it:      Get-Process frpc | Stop-Process -Force"
    Write-Host ""
}
