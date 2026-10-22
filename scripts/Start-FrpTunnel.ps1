[CmdletBinding()]
param(
    [string]$ServerAddr = "47.98.228.129",
    [int]$ServerPort = 7000,
    [int]$RemotePort = 0,
    [int[]]$PreferredRemotePorts = @(),
    [int]$LocalPort = 3389,
    [string]$FrpcPath = "$env:ProgramData\rdp-frp\frp\frpc.exe",
    [string]$WorkDir = "$env:ProgramData\rdp-frp",
    [string]$ProxyName = "",
    [string]$Token = "",
    [switch]$NoEncryption,
    [int]$MinRemotePort = 30000,
    [int]$MaxRemotePort = 49999,
    [int]$MaxAttempts = 30,
    [switch]$SkipVerify,
    [switch]$TcpOnly,
    [int]$VerifyRetries = 4,
    [string]$UserName = "",
    [string]$Password = "",
    [switch]$HidePassword,
    [string]$StatePath = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "FrpHelpers.ps1")

if (-not $StatePath) {
    $StatePath = Join-Path $WorkDir "state.json"
}
if (-not $UserName -and $env:RDP_USER) { $UserName = $env:RDP_USER }
if (-not $Password -and $env:RDP_PASSWORD) { $Password = $env:RDP_PASSWORD }
if (-not $UserName) { $UserName = "RDP" }

if (-not $ProxyName) {
    $hostPart = ($env:COMPUTERNAME -replace "[^A-Za-z0-9-]", "-").ToLowerInvariant()
    if (-not $hostPart) { $hostPart = "win" }
    $ProxyName = "rdp-$hostPart-$((Get-Random -Minimum 1000 -Maximum 9999))"
}

$configPath = Join-Path $WorkDir "frpc.toml"
$logPath = Join-Path $WorkDir "frpc.log"

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
Protect-Directory -Path $WorkDir

if (-not (Test-Path -LiteralPath $FrpcPath)) {
    throw "frpc.exe not found at $FrpcPath. Run Install-Frpc.ps1 first."
}

Stop-FrpcForConfig -ConfigPath $configPath -FrpcPath $FrpcPath

Write-Host "[*] Checking frps control endpoint $ServerAddr`:$ServerPort ..."
if (-not (Test-TcpPort -ComputerName $ServerAddr -Port $ServerPort -TimeoutMs 7000)) {
    throw "Cannot reach the frps control port $ServerAddr`:$ServerPort over TCP. Check the server address/port and its firewall."
}

Write-Step "Selecting a remote port"
$attemptPorts = New-Object System.Collections.Generic.List[int]

if ($RemotePort -gt 0) {
    $remotePortMode = "fixed"
    $repeats = [Math]::Max(1, [Math]::Min(2, $MaxAttempts))
    for ($i = 0; $i -lt $repeats; $i++) { $attemptPorts.Add($RemotePort) }
    Write-Host "[*] Using the explicitly requested remote port $RemotePort."
} else {
    $remotePortMode = "auto"
    foreach ($p in $PreferredRemotePorts) {
        if ($p -gt 0 -and $p -le 65535 -and -not $attemptPorts.Contains($p)) {
            $attemptPorts.Add($p)
        }
    }

    $targetCount = [Math]::Max(1, $MaxAttempts)
    $guard = 0
    while (($attemptPorts.Count -lt $targetCount) -and ($guard -lt ($targetCount * 50))) {
        $guard++
        $candidate = Get-RandomRemotePort -Min $MinRemotePort -Max $MaxRemotePort
        if (-not $attemptPorts.Contains($candidate)) { $attemptPorts.Add($candidate) }
    }
    Write-Host "[*] Auto-selecting from $($attemptPorts.Count) random remote ports in $MinRemotePort-$MaxRemotePort (no common-port fallback)."
}

$selectedPort = 0
$selectedProcess = $null
$lastLog = ""
$lastKind = ""
$attemptTotal = $attemptPorts.Count

for ($index = 0; $index -lt $attemptTotal; $index++) {
    $port = $attemptPorts[$index]
    Write-Step "Attempt $(($index + 1))/$attemptTotal - remote port $port"

    $config = New-FrpcConfig `
        -ServerAddr $ServerAddr `
        -ServerPort $ServerPort `
        -ProxyName $ProxyName `
        -LocalPort $LocalPort `
        -RemotePort $port `
        -Token $Token `
        -UseEncryption (-not $NoEncryption)
    Write-TextFileNoBom -Path $configPath -Content $config

    $processInfo = Start-FrpcProcess -FrpcPath $FrpcPath -ConfigPath $configPath -LogPath $logPath
    $wait = Wait-FrpProxy -LogPath $logPath -Process $processInfo.Process -TimeoutSeconds 25

    $failed = $true
    if ($wait.Success -and -not $processInfo.Process.HasExited) {
        if ($SkipVerify) {
            Write-Host "[*] frps accepted the proxy. Verification skipped (-SkipVerify)."
            $selectedPort = $port
            $selectedProcess = $processInfo.Process
            $failed = $false
        } else {
            Write-Host "[*] frps accepted the proxy; checking $ServerAddr`:$port ..."
            $tcpOk = Wait-TcpPort -ComputerName $ServerAddr -Port $port -Retries 4 -RetryDelaySeconds 2 -TimeoutMs 4000
            if (-not $tcpOk) {
                $lastKind = "port-blocked"
                Write-Warning "The proxy is up, but $ServerAddr`:$port is not reachable from this host. The frps cloud security group or firewall may block the port; trying another port."
            } elseif ($TcpOnly) {
                $selectedPort = $port
                $selectedProcess = $processInfo.Process
                $failed = $false
            } else {
                $rdpOk = Wait-RdpHandshake -ComputerName $ServerAddr -Port $port -Retries $VerifyRetries -RetryDelaySeconds 2 -TimeoutMs 5000
                if ($rdpOk) {
                    $selectedPort = $port
                    $selectedProcess = $processInfo.Process
                    $failed = $false
                } else {
                    $lastLog = Get-LogTail -Path $logPath
                    if ($processInfo.Process -and -not $processInfo.Process.HasExited) {
                        Stop-Process -Id $processInfo.Process.Id -Force -ErrorAction SilentlyContinue
                    }
                    throw "The frp tunnel is up and $ServerAddr`:$port accepts TCP, but the RDP service did not answer the RDP handshake. Check that RDP is enabled and TermService is running (or re-run with -TcpOnly / -SkipVerify)."
                }
            }
        }
    } else {
        $lastLog = Get-LogTail -Path $logPath
        if (-not $lastLog -and $wait.Log) { $lastLog = $wait.Log }
        $lastKind = Get-FrpFailureKind -LogText $lastLog
        Write-Warning "Remote port $port failed ($lastKind)."
    }

    if ($failed) {
        if ($processInfo.Process -and -not $processInfo.Process.HasExited) {
            Stop-Process -Id $processInfo.Process.Id -Force -ErrorAction SilentlyContinue
            try { $processInfo.Process.WaitForExit(3000) | Out-Null } catch { }
        }
        if ($lastKind -eq "auth") {
            throw "frps rejected the authentication token. Pass the correct -Token value.`nLast frpc log:`n$lastLog"
        }
        Start-Sleep -Seconds 1
        continue
    }

    break
}

if (-not $selectedPort) {
    $hint = ""
    switch ($lastKind) {
        "port-conflict" { $hint = "The requested remote port is already used on frps. Leave -RemotePort 0 to auto-pick." }
        "port-denied"   { $hint = "frps has allowPorts restrictions. Pass -RemotePort with a port allowed by frps." }
        "server-unreachable" { $hint = "Cannot keep a connection to frps at $ServerAddr`:$ServerPort. Check the server firewall and frps status." }
        "port-blocked"  { $hint = "frps accepted the proxy, but the public remote port is unreachable. Open it in the cloud security group/firewall, or pass -RemotePort with an open port." }
        default         { $hint = "No usable remote port was found." }
    }
    throw "Could not establish the frp tunnel. $hint`nLast frpc log:`n$lastLog"
}

$state = [ordered]@{
    serverAddr     = $ServerAddr
    serverPort     = $ServerPort
    remotePort     = $selectedPort
    remotePortMode = $remotePortMode
    minRemotePort  = $MinRemotePort
    maxRemotePort  = $MaxRemotePort
    localPort      = $LocalPort
    proxyName      = $ProxyName
    token          = $Token
    useEncryption  = (-not $NoEncryption)
    frpcPath       = $FrpcPath
    configPath     = $configPath
    logPath        = $logPath
    pid            = $selectedProcess.Id
    userName       = $UserName
    password       = $Password
    startedAt      = (Get-Date).ToString("o")
}
Save-StateFile -Path $StatePath -State $state

Set-GitHubEnvValue -Values @{
    RDP_HOST       = $ServerAddr
    RDP_PORT       = [string]$selectedPort
    RDP_ADDRESS    = "${ServerAddr}:${selectedPort}"
    RDP_USER       = $UserName
    RDP_PASSWORD   = $Password
    RDP_CREDS      = "User: $UserName | Password: $Password"
    RDP_STATE_PATH = $StatePath
}

Write-AccessBanner -ServerAddr $ServerAddr -RemotePort $selectedPort -UserName $UserName -Password $Password -HidePassword:$HidePassword
Write-Host "[+] frpc is running (PID $($selectedProcess.Id))."
Write-Host "    Config : $configPath"
Write-Host "    Log    : $logPath"
Write-Host "    State  : $StatePath"
