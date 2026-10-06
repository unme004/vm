$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$KeyUrl = 'https://raw.githubusercontent.com/unme004/vm/main/ssh-key.pub'
$RestrictToLocalSubnet = $true
$UsePowerShellAsDefaultShell = $true
$DisablePasswordAuth = $false
$LogFile = Join-Path $env:ProgramData 'ssh-setup.log'

function Write-Step($msg) { Write-Host "[*] $msg" }

function Merge-KeyFile([string]$Path, [string[]]$NewKeys) {
    $dir = Split-Path $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $existing = @()
    if (Test-Path $Path) { $existing = Get-Content $Path | Where-Object { $_.Trim() -ne '' } }
    $all = @($existing + $NewKeys) | Select-Object -Unique
    [IO.File]::WriteAllLines($Path, [string[]]$all, (New-Object Text.UTF8Encoding $false))
}

function Set-SshdOption([string[]]$Lines, [string]$Name, [string]$Value) {
    $pattern = '^\s*#?\s*' + [regex]::Escape($Name) + '\s+'
    $found = $false
    $out = foreach ($l in $Lines) {
        if (-not $found -and $l -match $pattern) { $found = $true; "$Name $Value" }
        else { $l }
    }
    if (-not $found) { $out = @("$Name $Value") + $out }
    return $out
}

Start-Transcript -Path $LogFile -Append | Out-Null

try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
               ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "ERROR: not running as Administrator."
        return
    }

    Write-Step "Downloading public key from $KeyUrl"
    $raw = Invoke-RestMethod -Uri $KeyUrl -UseBasicParsing
    $keys = @(($raw -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^(ssh-|ecdsa-|sk-)' })
    if ($keys.Count -eq 0) {
        Write-Host "ERROR: no valid public key found at $KeyUrl"
        return
    }

    Write-Step "Checking OpenSSH Server"
    $cap = Get-WindowsCapability -Online -Name 'OpenSSH.Server*' | Select-Object -First 1
    if ($cap.State -ne 'Installed') {
        Write-Step "Installing OpenSSH Server"
        Add-WindowsCapability -Online -Name $cap.Name | Out-Null
    }

    Write-Step "Enabling and starting sshd"
    Set-Service -Name sshd -StartupType Automatic
    Start-Service sshd

    Write-Step "Configuring firewall"
    $ruleName = 'OpenSSH-Server-In-TCP'
    if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -Name $ruleName -DisplayName 'OpenSSH Server (sshd)' `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22 | Out-Null
    }
    Set-NetFirewallRule -Name $ruleName -Enabled True -Profile Any
    if ($RestrictToLocalSubnet) {
        Set-NetFirewallRule -Name $ruleName -RemoteAddress LocalSubnet
    }

    Write-Step "Installing key for administrator accounts"
    $adminKeyFile = Join-Path $env:ProgramData 'ssh\administrators_authorized_keys'
    Merge-KeyFile -Path $adminKeyFile -NewKeys $keys
    icacls.exe $adminKeyFile /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" | Out-Null

    Write-Step "Installing key for user $env:USERNAME"
    $userKeyFile = Join-Path $env:USERPROFILE '.ssh\authorized_keys'
    Merge-KeyFile -Path $userKeyFile -NewKeys $keys
    icacls.exe $userKeyFile /inheritance:r /grant "${env:USERNAME}:F" /grant "*S-1-5-18:F" /grant "*S-1-5-32-544:F" | Out-Null

    if ($UsePowerShellAsDefaultShell) {
        Write-Step "Setting PowerShell as default SSH shell"
        $regPath = 'HKLM:\SOFTWARE\OpenSSH'
        if (-not (Test-Path $regPath)) { New-Item -Path $regPath -Force | Out-Null }
        New-ItemProperty -Path $regPath -Name DefaultShell `
            -Value 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe' `
            -PropertyType String -Force | Out-Null
    }

    $cfg = Join-Path $env:ProgramData 'ssh\sshd_config'
    if (Test-Path $cfg) {
        Write-Step "Updating sshd_config"
        $lines = Get-Content $cfg
        $lines = Set-SshdOption $lines 'PubkeyAuthentication' 'yes'
        if ($DisablePasswordAuth) {
            $lines = Set-SshdOption $lines 'PasswordAuthentication' 'no'
        }
        Set-Content -Path $cfg -Value $lines -Encoding ascii
    }

    Write-Step "Restarting sshd"
    Restart-Service sshd

    $ips = Get-NetIPAddress -AddressFamily IPv4 |
           Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.)' } |
           Select-Object -ExpandProperty IPAddress
    Write-Host "DONE: OpenSSH Server is running on $env:COMPUTERNAME"
    foreach ($ip in $ips) { Write-Host "    ssh $env:USERNAME@$ip" }
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)"
}
finally {
    Stop-Transcript | Out-Null
}
