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
    $proxy = Get-DotEnv (Join-Path $Root 'proxy\.env')
    foreach ($n in (Get-List $proxy.BYPASS_NETS)) { $nets.Add($n) }
    @($nets | Where-Object { $_ -and -not $skip.Contains($_) } | Select-Object -Unique)
}

function Clear-VlessDirectRoutes {
    $file = Join-Path $Root 'proxy\state\vless-routes.txt'
    if (-not (Test-Path $file)) { return }
    foreach ($prefix in (Get-Content $file | Where-Object { $_ -match '\S' })) {
        Remove-NetRoute -DestinationPrefix $prefix.Trim() -Confirm:$false -ErrorAction SilentlyContinue
    }
    Remove-Item $file -Force
}

function Set-VlessDirectRoutes {
    Clear-VlessDirectRoutes
    $gateway = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '0.0.0.0' -and $_.InterfaceAlias -notmatch 'redlink|WSL|vEthernet|Loopback|WireGuard' } |
        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |
        Select-Object -First 1
    if (-not $gateway) { return }
    $ifIndex = [int](Get-NetIPInterface -InterfaceAlias $gateway.InterfaceAlias -AddressFamily IPv4 -ErrorAction SilentlyContinue).InterfaceIndex
    if ($ifIndex -le 0) { return }
    $proxy = Get-DotEnv (Join-Path $Root 'proxy\.env')
    $ips = foreach ($uri in (Get-List $proxy.VLESS '\s+')) {
        if ($uri -notmatch '@([^:/?#]+)') { continue }
        $name = $Matches[1]
        if ($name -match '^\d+\.\d+\.\d+\.\d+$') { $name }
        else {
            Resolve-DnsName $name -Type A -ErrorAction SilentlyContinue |
                Where-Object Type -eq 'A' | Select-Object -ExpandProperty IPAddress
        }
    }
    $ips = @($ips | Where-Object { $_ } | Select-Object -Unique)
    if (-not $ips.Count) { return }
    $dir = Join-Path $Root 'proxy\state'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $ips | ForEach-Object { "$_/32" } | Set-Content (Join-Path $dir 'vless-routes.txt') -Encoding ascii
    $hop = [string]$gateway.NextHop
    foreach ($ip in $ips) {
        route.exe add $ip mask 255.255.255.255 $hop metric 1 if $ifIndex | Out-Null
    }
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
    Clear-VlessDirectRoutes
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
    Set-VlessDirectRoutes
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
