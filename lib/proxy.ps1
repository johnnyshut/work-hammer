function ConvertFrom-VlessUri([string]$Uri, [string]$Tag) {
    $u = [uri]$Uri
    $q = @{}
    foreach ($pair in $u.Query.TrimStart('?').Split('&')) {
        if (-not $pair) { continue }
        $k, $v = $pair.Split('=', 2)
        $q[$k] = [uri]::UnescapeDataString([string]$v)
    }

    $out = [ordered]@{
        type            = 'vless'
        tag             = $Tag
        server          = $u.Host
        server_port     = $u.Port
        uuid            = [uri]::UnescapeDataString($u.UserInfo)
        packet_encoding = 'xudp'
    }
    if ($q.flow) { $out.flow = $q.flow }

    if ($q.security -in 'tls', 'reality') {
        $tls = [ordered]@{ enabled = $true; server_name = $(if ($q.sni) { $q.sni } else { $u.Host }) }
        if ($q.fp) { $tls.utls = [ordered]@{ enabled = $true; fingerprint = $q.fp } }
        if ($q.alpn) { $tls.alpn = @($q.alpn.Split(',')) }
        if ($q.security -eq 'reality') {
            $tls.reality = [ordered]@{ enabled = $true; public_key = $q.pbk; short_id = $q.sid }
        }
        $out.tls = $tls
    }

    switch ($q.type) {
        'ws' { $out.transport = [ordered]@{ type = 'ws'; path = $q.path; headers = @{ Host = $q.host } } }
        'grpc' { $out.transport = [ordered]@{ type = 'grpc'; service_name = $q.serviceName } }
        'httpupgrade' { $out.transport = [ordered]@{ type = 'httpupgrade'; path = $q.path; host = $q.host } }
    }
    $out
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

function Get-StateLines([string]$Path) {
    if (Test-Path $Path) { @(Get-Content $Path | Where-Object { $_ -match '\S' } | ForEach-Object { $_.Trim() }) } else { @() }
}

function New-ProxyConfig {
    $envProxy = Get-DotEnv (Join-Path $Root 'proxy\.env')

    $uris = @(Get-List $envProxy.VLESS '\s+')
    $nodes = @()
    for ($i = 0; $i -lt $uris.Count; $i++) { $nodes += ConvertFrom-VlessUri $uris[$i] "vless-$($i + 1)" }

    $outbounds = @([ordered]@{ type = 'direct'; tag = 'direct' })
    $servers = @([ordered]@{ type = 'local'; tag = 'local' })
    $rules = @([ordered]@{ action = 'sniff' })
    $cidrs = @()

    if ($nodes.Count) {
        $outbounds += [ordered]@{
            type      = 'urltest'
            tag       = 'bypass'
            outbounds = @($nodes | ForEach-Object { $_.tag })
            url       = 'https://www.gstatic.com/generate_204'
            interval  = '3m'
        }
        $outbounds += $nodes
    }

    foreach ($t in $Tunnels) {
        $e = Get-DotEnv (Join-Path $Root "$($t.Name)\.env")
        if (-not $e.Count) { continue }

        $outbounds += [ordered]@{ type = 'socks'; tag = $t.Name; server = $t.Host; server_port = $t.Port; version = '5' }

        $domains = Get-List $e.DOMAINS
        $dns = Get-StateLines (Join-Path $Root "$($t.Name)\state\dns")
        if ($domains.Count -and $dns.Count) {
            $servers += [ordered]@{ type = 'tcp'; tag = "dns-$($t.Name)"; server = $dns[0]; detour = $t.Name }
            $rules += [ordered]@{ domain_suffix = $domains; action = 'resolve'; server = "dns-$($t.Name)" }
        } elseif ($domains.Count) {
            $rules += [ordered]@{ domain_suffix = $domains; outbound = $t.Name }
        }

        foreach ($n in (Get-List $e.NETS) + (Get-StateLines (Join-Path $Root "$($t.Name)\state\nets"))) {
            $cidrs += [pscustomobject]@{ Net = $n; Len = [int]($n.Split('/')[1]); Out = $t.Name }
        }
    }

    if ($nodes.Count) {
        $bypass = Get-List $envProxy.BYPASS_DOMAINS
        if ($bypass.Count) { $rules += [ordered]@{ domain_suffix = $bypass; outbound = 'bypass' } }
        foreach ($n in Get-List $envProxy.BYPASS_NETS) {
            $cidrs += [pscustomobject]@{ Net = $n; Len = [int]($n.Split('/')[1]); Out = 'bypass' }
        }
    }

    foreach ($n in Get-LanNets) {
        $cidrs += [pscustomobject]@{ Net = $n; Len = [int]($n.Split('/')[1]); Out = 'direct' }
    }

    $groups = $cidrs | Group-Object Len, Out | Sort-Object { $_.Group[0].Len } -Descending
    foreach ($g in $groups) {
        $rules += [ordered]@{ ip_cidr = @($g.Group.Net | Select-Object -Unique); outbound = $g.Group[0].Out }
    }

    [ordered]@{
        log       = @{ level = 'warn' }
        dns       = [ordered]@{ servers = $servers; final = 'local'; strategy = 'ipv4_only' }
        inbounds  = @([ordered]@{ type = 'mixed'; tag = 'in'; listen = '0.0.0.0'; listen_port = 1080 })
        outbounds = $outbounds
        route     = [ordered]@{ rules = $rules; final = 'direct'; default_domain_resolver = 'local' }
    } | ConvertTo-Json -Depth 12
}

Add-Type -Namespace WinInet -Name Native -MemberDefinition @'
[DllImport("wininet.dll", SetLastError = true)]
public static extern bool InternetSetOption(System.IntPtr h, int option, System.IntPtr buffer, int length);
'@ -ErrorAction SilentlyContinue

$InternetSettings = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Update-WinInet {
    [WinInet.Native]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
    [WinInet.Native]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
}

function Enable-SystemProxy {
    $saved = Join-Path $Root 'proxy\state\sysproxy.json'
    if (-not (Test-Path $saved)) {
        Get-ItemProperty $InternetSettings |
            Select-Object ProxyEnable, ProxyServer, ProxyOverride |
            ConvertTo-Json | Set-Content $saved -Encoding UTF8
    }
    Set-ItemProperty $InternetSettings ProxyEnable 1
    Set-ItemProperty $InternetSettings ProxyServer '127.0.0.1:1080'
    Set-ItemProperty $InternetSettings ProxyOverride '<local>;localhost;127.*'
    Update-WinInet
}

function Disable-SystemProxy {
    $saved = Join-Path $Root 'proxy\state\sysproxy.json'
    if (Test-Path $saved) {
        $p = Get-Content $saved -Raw | ConvertFrom-Json
        Set-ItemProperty $InternetSettings ProxyEnable ([int]$p.ProxyEnable)
        foreach ($k in 'ProxyServer', 'ProxyOverride') {
            if ($null -ne $p.$k) { Set-ItemProperty $InternetSettings $k $p.$k }
            else { Remove-ItemProperty $InternetSettings $k -ErrorAction SilentlyContinue }
        }
        Remove-Item $saved
    } elseif ((Get-ItemProperty $InternetSettings).ProxyServer -eq '127.0.0.1:1080') {
        Set-ItemProperty $InternetSettings ProxyEnable 0
    }
    Update-WinInet
}

function Test-SystemProxy {
    $p = Get-ItemProperty $InternetSettings
    $p.ProxyEnable -eq 1 -and $p.ProxyServer -eq '127.0.0.1:1080'
}
