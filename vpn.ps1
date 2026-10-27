#Requires -Version 5.1
param(
    [Parameter(Position = 0)][ValidateSet('up', 'down', 'status')][string]$Action = 'status',
    [Parameter(Position = 1)][ValidateSet('all', 'forti', 'cisco', 'l2tp', 'proxy', 'dashboard')][string]$Target = 'all',
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$Tunnels = @(
    @{ Name = 'forti'; Host = 'host.docker.internal'; Port = 11080; Wsl = $true }
    @{ Name = 'cisco'; Host = 'cisco'; Port = 1080; Wsl = $false }
    @{ Name = 'l2tp'; Host = 'host.docker.internal'; Port = 14080; Wsl = $true }
)

function Get-DotEnv([string]$Path) {
    $map = @{}
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^\s*([A-Z0-9_]+)\s*=(.*)$') { $map[$Matches[1]] = $Matches[2].Trim() }
        }
    }
    $map
}

function Get-List([string]$Value, [string]$Separator = '[,\s]+') {
    @($Value -split $Separator | Where-Object { $_ })
}

. (Join-Path $Root 'lib\proxy.ps1')

function Invoke-Compose { & docker compose --project-directory $Root @args *> $null }

function ConvertTo-WslPath([string]$Path) {
    '/mnt/' + $Path.Substring(0, 1).ToLowerInvariant() + ($Path.Substring(2) -replace '\\', '/')
}

function Test-Port([int]$Port) {
    $c = New-Object Net.Sockets.TcpClient
    try { $c.ConnectAsync('127.0.0.1', $Port).Wait(1000) -and $c.Connected } catch { $false } finally { $c.Dispose() }
}

function Start-Docker {
    docker info *> $null
    if ($LASTEXITCODE -eq 0) { return }
    Write-Host ('{0,-10}' -f 'docker') -NoNewline
    Start-Process "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
    for ($i = 0; $i -lt 60; $i++) {
        Start-Sleep -Seconds 3
        docker info *> $null
        if ($LASTEXITCODE -eq 0) { break }
    }
    Write-State 'docker' $(if ($LASTEXITCODE -eq 0) { 'up' } else { 'failed' })
}

function Test-Container([string]$Name) {
    (docker inspect -f '{{.State.Running}}' $Name 2>$null) -eq 'true'
}

function Get-Tunnel([string]$Name) { $Tunnels | Where-Object { $_.Name -eq $Name } }

function Get-StatusFile([string]$Name) { Join-Path $Root "$Name\state\status" }

function Read-StatusFile([string]$Name) {
    $f = Get-StatusFile $Name
    if (Test-Path $f) { (Get-Content $f -Raw).Trim() } else { 'stopped' }
}

function Write-StatusFile([string]$Name, [string]$Value) {
    $f = Get-StatusFile $Name
    New-Item -ItemType Directory -Force -Path (Split-Path $f) | Out-Null
    [IO.File]::WriteAllText($f, $Value)
}

function Get-State([string]$Name) {
    switch ($Name) {
        'proxy' { if ((Test-Container 'work-hammer-proxy') -and (Test-Port 1080)) { 'up' } else { 'stopped' } }
        'dashboard' { if (Test-Port 3456) { 'up' } else { 'stopped' } }
        'cisco' {
            $s = Read-StatusFile 'cisco'
            if (-not (Test-Container 'work-hammer-cisco') -and $s -in 'up', 'connecting') { 'stopped' } else { $s }
        }
        default {
            $s = Read-StatusFile $Name
            if ($s -eq 'up' -and -not (Test-Port (Get-Tunnel $Name).Port)) { 'failed' } else { $s }
        }
    }
}

function Wait-State([string]$Name, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $s = Get-State $Name
        if ($s -ne 'connecting') { return $s }
    }
    'timeout'
}

function Show-Log([string]$Name) {
    $lines = switch ($Name) {
        'cisco' { docker logs --tail 5 work-hammer-cisco 2>&1 }
        'proxy' { docker logs --tail 5 work-hammer-proxy 2>&1 }
        default { Get-Content (Join-Path $Root "$Name\state\run.log") -Tail 5 -ErrorAction SilentlyContinue }
    }
    foreach ($l in $lines) { Write-Host "    $l" -ForegroundColor DarkGray }
}

function Stop-Tunnel([string]$Name) {
    if ((Get-Tunnel $Name).Wsl) {
        wsl.exe -e bash (ConvertTo-WslPath "$Root\$Name\run.sh") stop *> $null
        Start-Sleep -Seconds 1
    } else {
        Invoke-Compose rm -sf $Name
    }
    Write-StatusFile $Name 'stopped'
}

function Start-Tunnel([string]$Name) {
    Stop-Tunnel $Name
    Write-StatusFile $Name 'connecting'
    if ((Get-Tunnel $Name).Wsl) {
        $script = ConvertTo-WslPath "$Root\$Name\run.sh"
        Start-Process cmd.exe -ArgumentList '/c', "wsl.exe -e bash `"$script`"" -WindowStyle Hidden
    } else {
        Invoke-Compose up -d $Name
    }
    $s = Wait-State $Name 200
    if ($s -eq 'timeout') { Stop-Tunnel $Name }
    $s
}

function Stop-Proxy {
    Disable-SystemProxy
    Invoke-Compose rm -sf proxy
}

function Start-Proxy {
    $dir = Join-Path $Root 'proxy\state'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    [IO.File]::WriteAllText((Join-Path $dir 'config.json'), (New-ProxyConfig))
    Invoke-Compose up -d --force-recreate proxy

    for ($i = 0; $i -lt 15; $i++) {
        Start-Sleep -Seconds 1
        $code = curl.exe -s -o NUL -m 5 -w '%{http_code}' -x http://127.0.0.1:1080 https://www.gstatic.com/generate_204
        if ($code -eq '204') { break }
    }
    if ($code -ne '204') {
        Disable-SystemProxy
        return 'failed'
    }
    Enable-SystemProxy
    'up'
}

function Stop-Dashboard {
    $dir = Join-Path $Root 'dashboard'
    Get-CimInstance Win32_Process -Filter "Name='oscript.exe'" |
        Where-Object { $_.CommandLine -like "*$dir*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Start-Dashboard {
    Stop-Dashboard
    $dir = Join-Path $Root 'dashboard'
    New-Item -ItemType Directory -Force -Path "$dir\state" | Out-Null
    $env:Logging__LogLevel__Default = 'Warning'
    $secret = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($secret)
    $env:DASHBOARD_SECRET = [Convert]::ToBase64String($secret)
    Start-Process oscript.exe -ArgumentList "`"$dir\app.os`"" -WorkingDirectory $dir -WindowStyle Hidden `
        -RedirectStandardOutput "$dir\state\out.log" -RedirectStandardError "$dir\state\err.log"
    for ($i = 0; $i -lt 20 -and -not (Test-Port 3456); $i++) { Start-Sleep -Seconds 1 }
    Get-State 'dashboard'
}

function Write-State([string]$Name, [string]$State) {
    $color = switch ($State) { 'up' { 'Green' } 'stopped' { 'DarkGray' } default { 'Red' } }
    Write-Host $State -ForegroundColor $color
    if ($State -in 'failed', 'timeout') { Show-Log $Name }
}

function Write-Line([string]$Name, [string]$State) {
    Write-Host ('{0,-10}' -f $Name) -NoNewline
    Write-State $Name $State
}

function Invoke-Up([string]$Name) {
    Write-Host ('{0,-10}' -f $Name) -NoNewline
    $s = switch ($Name) {
        'proxy' { Start-Proxy }
        'dashboard' { Start-Dashboard }
        default { Start-Tunnel $Name }
    }
    Write-State $Name $s
    $s
}

function Invoke-Down([string]$Name) {
    switch ($Name) {
        'proxy' { Stop-Proxy }
        'dashboard' { Stop-Dashboard }
        default { Stop-Tunnel $Name }
    }
}

$names = if ($Target -eq 'all') { @($Tunnels.Name) + 'proxy' } else { @($Target) }

$lock = New-Object Threading.Mutex($false, 'Local\work-hammer')
try { $owned = $lock.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
if ($Action -eq 'status') {
    $busy = -not $owned
    if ($owned) { $lock.ReleaseMutex() }
} elseif (-not $owned -and $Target -ne 'dashboard') {
    Write-Host 'busy' -ForegroundColor Yellow
    exit 1
}

switch ($Action) {
    'status' {
        $rows = foreach ($n in @($Tunnels.Name) + 'proxy' + 'dashboard') {
            [pscustomobject]@{ id = $n; state = Get-State $n }
        }
        if ($Json) {
            [pscustomobject]@{ items = @($rows); system_proxy = (Test-SystemProxy); busy = $busy } | ConvertTo-Json -Depth 4 -Compress
        } else {
            foreach ($r in $rows) { Write-Line $r.id $r.state }
            Write-Line 'sysproxy' $(if (Test-SystemProxy) { 'up' } else { 'stopped' })
        }
    }
    'down' {
        if ($Target -eq 'all') { $names = @('proxy') + @($Tunnels.Name) }
        foreach ($n in $names) { Invoke-Down $n }
    }
    'up' {
        if ($names -contains 'cisco' -or $names -contains 'proxy') { Start-Docker }
        if ($Target -eq 'all') { foreach ($n in @('proxy') + @($Tunnels.Name)) { Invoke-Down $n } }
        $failed = 0
        foreach ($n in $names) {
            if ((Invoke-Up $n) -ne 'up') { $failed++ }
        }
        if ($Target -in 'forti', 'cisco', 'l2tp' -and (Get-State 'proxy') -eq 'up') { Invoke-Up 'proxy' | Out-Null }
        exit $failed
    }
}
