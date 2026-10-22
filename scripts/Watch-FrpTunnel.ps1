[CmdletBinding()]
param(
    [string]$StatePath = "",
    [int]$CheckIntervalSeconds = 15,
    [int]$ReportIntervalSeconds = 300,
    [int]$MaxRestartFailures = 3,
    [switch]$HidePassword
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "FrpHelpers.ps1")

if (-not $StatePath) {
    if ($env:RDP_STATE_PATH) {
        $StatePath = $env:RDP_STATE_PATH
    } else {
        $StatePath = "$env:ProgramData\rdp-frp\state.json"
    }
}

$state = Read-StateFile -Path $StatePath

$userName = $state.userName
$password = $state.password
if (-not $userName -and $env:RDP_USER) { $userName = $env:RDP_USER }
if (-not $password -and $env:RDP_PASSWORD) { $password = $env:RDP_PASSWORD }
if (-not $userName) { $userName = "RDP" }

function Get-TrackedFrpcProcess {
    param($State)
    if (-not $State.pid) { return $null }
    $process = Get-Process -Id ([int]$State.pid) -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    try {
        if ($process.ProcessName -ne "frpc") { return $null }
        if ($process.Path -ne $State.frpcPath) { return $null }
    } catch { }
    return $process
}

function Restart-TrackedTunnel {
    param(
        $State,
        [ref]$Failures
    )
    Stop-FrpcForConfig -ConfigPath $State.configPath -FrpcPath $State.frpcPath

    if ($State.remotePortMode -eq "auto" -and $Failures.Value -ge 3) {
        $newPort = Get-RandomRemotePort -Min ([int]$State.minRemotePort) -Max ([int]$State.maxRemotePort)
        Write-Host "[*] Repeated restart failures; switching remote port $($State.remotePort) -> $newPort."
        $config = New-FrpcConfig `
            -ServerAddr $State.serverAddr `
            -ServerPort ([int]$State.serverPort) `
            -ProxyName $State.proxyName `
            -LocalPort ([int]$State.localPort) `
            -RemotePort $newPort `
            -Token $State.token `
            -UseEncryption ([bool]$State.useEncryption)
        Write-TextFileNoBom -Path $State.configPath -Content $config
        $State.remotePort = $newPort
    }

    $info = Start-FrpcProcess -FrpcPath $State.frpcPath -ConfigPath $State.configPath -LogPath $State.logPath
    $wait = Wait-FrpProxy -LogPath $State.logPath -Process $info.Process -TimeoutSeconds 25

    if ($wait.Success -and -not $info.Process.HasExited) {
        $State.pid = $info.Process.Id
        Save-StateFile -Path $StatePath -State $State
        $Failures.Value = 0
        Write-Host "[+] frpc restarted (PID $($State.pid), remote port $($State.remotePort))."
        return $info.Process
    }

    $Failures.Value++
    $tail = Get-LogTail -Path $State.logPath -Lines 8
    Write-Warning "frpc restart failed (attempt $($Failures.Value)). $tail"
    if ($info.Process -and -not $info.Process.HasExited) {
        Stop-Process -Id $info.Process.Id -Force -ErrorAction SilentlyContinue
    }
    return $null
}

Write-Host "[*] Watching the frp tunnel. Press Ctrl+C to stop watching (frpc keeps running)."
$lastReport = [datetime]::MinValue
$failures = 0
$process = Get-TrackedFrpcProcess -State $state

while ($true) {
    $process = Get-TrackedFrpcProcess -State $state

    if (-not $process) {
        Write-Host "[!] frpc is not running; restarting ..."
        $failuresRef = [ref]$failures
        $process = Restart-TrackedTunnel -State $state -Failures $failuresRef
        $failures = $failuresRef.Value
    }

    if (((Get-Date) - $lastReport).TotalSeconds -ge $ReportIntervalSeconds) {
        $status = if ($process) { "frpc PID $($state.pid)" } else { "frpc DOWN" }
        Write-Host ""
        Write-Host "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] RDP over frp active - $($state.serverAddr):$($state.remotePort) ($status)"
        Write-AccessBanner `
            -ServerAddr $state.serverAddr `
            -RemotePort ([int]$state.remotePort) `
            -UserName $userName `
            -Password $password `
            -AddSummary $false `
            -HidePassword:$HidePassword
        $lastReport = Get-Date
    }

    Start-Sleep -Seconds $CheckIntervalSeconds
}
