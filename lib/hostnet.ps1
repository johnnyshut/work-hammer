param(
    [ValidateSet('up', 'down')][string]$Action,
    [string]$Root
)

if (-not $Root) { $Root = Split-Path $PSScriptRoot }

function Get-WslIpv4 {
    @((wsl.exe -e hostname -I 2>$null) -split '\s+' | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }) | Select-Object -First 1
}

function Get-WslIfIndex([string]$Gateway) {
    try { (Find-NetRoute -RemoteIPAddress $Gateway -ErrorAction Stop | Select-Object -First 1).InterfaceIndex } catch { $null }
}

function Get-HostNets {
    $skip = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($n in @('172.16.0.0/12', '192.168.0.0/16') + @(Get-LanNets)) { [void]$skip.Add($n) }
    $nets = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @('forti', 'l2tp', 'cisco')) {
        foreach ($n in (Get-StateLines (Join-Path $Root "$name\state\nets"))) { $nets.Add($n) }
        $e = Get-DotEnv (Join-Path $Root "$name\.env")
        foreach ($n in (Get-List $e.NETS)) { $nets.Add($n) }
    }
    @($nets | Where-Object { $_ -and -not $skip.Contains($_) } | Select-Object -Unique)
}

function Clear-HostNetRoutes {
    $gw = Get-WslIpv4
    if ($gw) {
        Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.NextHop -eq $gw -and $_.DestinationPrefix -ne '0.0.0.0/0' } |
            Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue
    }
    Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Comment -eq 'work-hammer' } |
        Remove-DnsClientNrptRule -Force -ErrorAction SilentlyContinue
    $saved = Join-Path $Root 'proxy\state\suffix.json'
    if (Test-Path $saved) {
        $list = @(Get-Content $saved -Raw | ConvertFrom-Json)
        if ($list.Count) { Set-DnsClientGlobalSetting -SuffixSearchList $list -ErrorAction SilentlyContinue }
        Remove-Item $saved -Force
    }
    $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
    if (Test-Path $hostsPath) {
        $raw = [IO.File]::ReadAllText($hostsPath)
        $raw = [regex]::Replace($raw, '(?s)\r?\n?# work-hammer-start.*?# work-hammer-end\r?\n?', "`r`n")
        [IO.File]::WriteAllText($hostsPath, $raw.TrimEnd() + "`r`n")
    }
}

function Set-HostNetRoutes {
    $gw = Get-WslIpv4
    if (-not $gw) { return }
    $ifIndex = Get-WslIfIndex $gw
    if (-not $ifIndex) { return }

    Clear-HostNetRoutes

    foreach ($n in (Get-HostNets)) {
        New-NetRoute -DestinationPrefix $n -NextHop $gw -InterfaceIndex $ifIndex -PolicyStore ActiveStore -ErrorAction SilentlyContinue | Out-Null
    }

    foreach ($name in @('forti', 'l2tp', 'cisco')) {
        $e = Get-DotEnv (Join-Path $Root "$name\.env")
        if (-not (Get-StateLines (Join-Path $Root "$name\state\dns")).Count) { continue }
        foreach ($d in (Get-List $e.DOMAINS)) {
            $dom = $d.Trim().TrimStart('.')
            Add-DnsClientNrptRule -Namespace ".$dom" -NameServers '127.0.0.1' -Comment 'work-hammer' -ErrorAction SilentlyContinue | Out-Null
        }
    }
    ipconfig /flushdns | Out-Null
}

function Stop-DnsProxy {
    Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*dnsproxy.py*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

if ($Action) {
    $ErrorActionPreference = 'Continue'
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
    function Get-StateLines([string]$Path) {
        if (Test-Path $Path) { @(Get-Content $Path | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }) } else { @() }
    }
    function Get-LanNets {
        Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -in 'Dhcp', 'Manual' -and $_.InterfaceAlias -notmatch 'vEthernet|WSL|Loopback' } |
            ForEach-Object {
                $len = [int]$_.PrefixLength
                $ip = ([ipaddress]$_.IPAddress).GetAddressBytes()
                $net = for ($i = 0; $i -lt 4; $i++) {
                    $bits = [math]::Max(0, [math]::Min(8, $len - 8 * $i))
                    $ip[$i] -band (0xFF -shl (8 - $bits)) -band 0xFF
                }
                "$($net -join '.')/$len"
            } | Select-Object -Unique
    }
    if ($Action -eq 'up') { Set-HostNetRoutes } else { Clear-HostNetRoutes; Stop-DnsProxy }
}
