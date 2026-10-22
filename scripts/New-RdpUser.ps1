[CmdletBinding()]
param(
    [string]$UserName = "RDP",
    [string]$Password = "",
    [string]$CredentialFile = "",
    [switch]$HidePassword
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "FrpHelpers.ps1")

if (-not (Test-IsAdministrator)) {
    throw "New-RdpUser.ps1 must run as Administrator."
}

if (-not $Password -and $env:RDP_PASSWORD) {
    $Password = $env:RDP_PASSWORD
    Write-Host "[*] Using the fixed password from RDP_PASSWORD."
}
if (-not $Password) {
    $Password = New-StrongPassword -Length 16
    Write-Host "[*] No password supplied; generated a random password."
}

$securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
$existing = Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue

if ($existing) {
    Write-Host "[*] Local user '$UserName' already exists; resetting its password."
    Set-LocalUser -Name $UserName -Password $securePassword -PasswordNeverExpires $true
    if (-not $existing.Enabled) { Enable-LocalUser -Name $UserName }
} else {
    New-LocalUser -Name $UserName `
        -Password $securePassword `
        -AccountNeverExpires `
        -PasswordNeverExpires `
        -Description "RDP access user (managed by rdp-frp)" | Out-Null
    Write-Host "[*] Created local user '$UserName'."
}

$user = Get-LocalUser -Name $UserName -ErrorAction Stop
if (-not $user) {
    throw "User creation failed: '$UserName' not found."
}

function Add-UserToLocalGroupBySid {
    param(
        [Parameter(Mandatory)][string]$GroupSid,
        [Parameter(Mandatory)][string]$MemberName,
        [Parameter(Mandatory)][string]$MemberSid
    )
    $group = Get-LocalGroup -SID $GroupSid -ErrorAction SilentlyContinue
    if (-not $group) {
        Write-Warning "Local group with SID $GroupSid was not found."
        return
    }

    $members = @()
    try {
        $members = @(Get-LocalGroupMember -SID $GroupSid -ErrorAction Stop)
    } catch { }

    foreach ($member in $members) {
        if ($member.SID -and $member.SID.Value -eq $MemberSid) {
            Write-Host "[*] '$MemberName' is already a member of '$($group.Name)'."
            return
        }
    }

    try {
        Add-LocalGroupMember -Group $group -Member $MemberName -ErrorAction Stop
        Write-Host "[*] Added '$MemberName' to '$($group.Name)'."
    } catch {
        Write-Warning "Could not add '$MemberName' to '$($group.Name)': $($_.Exception.Message)"
    }
}

# S-1-5-32-544 = Administrators, S-1-5-32-555 = Remote Desktop Users.
Add-UserToLocalGroupBySid -GroupSid "S-1-5-32-544" -MemberName $UserName -MemberSid $user.SID.Value
Add-UserToLocalGroupBySid -GroupSid "S-1-5-32-555" -MemberName $UserName -MemberSid $user.SID.Value

$credential = [ordered]@{
    userName  = $UserName
    password  = $Password
    createdAt = (Get-Date).ToString("o")
}

if ($CredentialFile) {
    Write-TextFileNoBom -Path $CredentialFile -Content ($credential | ConvertTo-Json)
}

Set-GitHubEnvValue -Values @{
    RDP_USER     = $UserName
    RDP_PASSWORD = $Password
    RDP_CREDS    = "User: $UserName | Password: $Password"
}

Write-Host ""
Write-Host "[+] RDP user ready."
Write-Host "    Username : $UserName"
if ($HidePassword) {
    Write-Host "    Password : ******** (repository secret RDP_PASSWORD)"
} else {
    Write-Host "    Password : $Password"
}
Write-Host ""
