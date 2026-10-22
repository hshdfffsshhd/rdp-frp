[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$InstallDir = "$env:ProgramData\rdp-frp\frp",
    [string]$DownloadUrl = "",
    [string]$LocalZip = "",
    [string]$Architecture = "",
    [switch]$UseMirror,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "FrpHelpers.ps1")

$target = Join-Path $InstallDir "frpc.exe"
$marker = Join-Path $InstallDir "version.txt"

if (-not $Architecture) { $Architecture = Get-WindowsArchitecture }

if (-not $Force -and (Test-Path -LiteralPath $target)) {
    $installedVersion = "unknown"
    if (Test-Path -LiteralPath $marker) {
        $markerValue = (Get-Content -LiteralPath $marker -Raw).Trim()
        if ($markerValue) { $installedVersion = $markerValue }
    }

    if (-not $Version -and -not $DownloadUrl -and -not $LocalZip) {
        Write-Host "[*] frpc is already installed at $target (version: $installedVersion). Use -Force to reinstall."
        return $target
    }
    if ($Version -and -not $DownloadUrl -and -not $LocalZip -and $installedVersion -eq $Version) {
        Write-Host "[*] frpc $Version is already installed."
        return $target
    }
}

if (-not $Version -and -not $DownloadUrl -and -not $LocalZip) {
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/fatedier/frp/releases/latest" `
            -Headers @{ "User-Agent" = "rdp-frp-setup" } -TimeoutSec 20
        $Version = ([string]$release.tag_name).TrimStart("v")
        if (-not $Version) { throw "Empty tag name." }
        Write-Host "[*] Latest frp release: $Version"
    } catch {
        $Version = $DefaultFrpVersion
        Write-Host "[*] Could not query the GitHub API; falling back to frp $Version."
    }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("rdp-frp-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

try {
    $zipPath = Join-Path $tempRoot "frp.zip"

    if ($LocalZip) {
        if (-not (Test-Path -LiteralPath $LocalZip)) {
            throw "Local archive not found: $LocalZip"
        }
        Copy-Item -LiteralPath $LocalZip -Destination $zipPath -Force
        Write-Host "[*] Using local archive: $LocalZip"
    } else {
        $isDefaultUrl = $false
        if (-not $DownloadUrl) {
            $asset = "frp_${Version}_windows_$Architecture.zip"
            $DownloadUrl = "https://github.com/fatedier/frp/releases/download/v$Version/$asset"
            $isDefaultUrl = $true
        }

        $downloadUrls = New-Object System.Collections.Generic.List[string]
        if ($UseMirror -and $isDefaultUrl) {
            # Mirrors are used only when explicitly requested; they proxy the official release asset.
            $downloadUrls.Add("https://gh-proxy.com/$DownloadUrl")
            $downloadUrls.Add("https://ghproxy.net/$DownloadUrl")
            $downloadUrls.Add("https://ghfast.top/$DownloadUrl")
        }
        $downloadUrls.Add($DownloadUrl)

        $downloaded = $false
        foreach ($url in $downloadUrls) {
            if ($downloaded) { break }
            Write-Host "[*] Downloading $url"
            if (Test-Path -LiteralPath $zipPath) {
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
            }
            try {
                if (Get-Command curl.exe -ErrorAction SilentlyContinue) {
                    & curl.exe -fsSL --retry 1 --connect-timeout 20 --speed-limit 10240 --speed-time 30 --max-time 480 -o $zipPath $url
                    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $zipPath) -and (Get-Item -LiteralPath $zipPath).Length -gt 1MB) {
                        $downloaded = $true
                    }
                } else {
                    $ProgressPreference = "SilentlyContinue"
                    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing -TimeoutSec 480
                    if ((Test-Path -LiteralPath $zipPath) -and (Get-Item -LiteralPath $zipPath).Length -gt 1MB) {
                        $downloaded = $true
                    }
                }
            } catch {
                Write-Warning "Download failed from ${url}: $($_.Exception.Message)"
            }
        }

        if (-not $downloaded) {
            throw "Failed to download frp. Use -LocalZip <path>, -DownloadUrl <mirror URL>, or -UseMirror."
        }
    }

    $extractDir = Join-Path $tempRoot "extract"
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force

    $frpc = Get-ChildItem -Path $extractDir -Filter "frpc.exe" -Recurse -File | Select-Object -First 1
    if (-not $frpc) {
        throw "The archive does not contain frpc.exe."
    }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -LiteralPath $frpc.FullName -Destination $target -Force
    try { Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue } catch { }

    $recordedVersion = $Version
    if (-not $recordedVersion) { $recordedVersion = "custom" }
    Write-TextFileNoBom -Path $marker -Content $recordedVersion

    Write-Host "[+] Installed frpc ($recordedVersion) at $target"
    return $target
} finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
