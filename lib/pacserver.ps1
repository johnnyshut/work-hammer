param(
    [string]$Pac,
    [int]$Port = 8079
)

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$Port/")
$listener.Start()
try {
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        try {
            $bytes = [IO.File]::ReadAllBytes($Pac)
            $ctx.Response.StatusCode = 200
            $ctx.Response.ContentType = 'application/x-ns-proxy-autoconfig'
            $ctx.Response.Headers.Add('Cache-Control', 'no-cache')
            $ctx.Response.ContentLength64 = $bytes.Length
            $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
        } catch {
            $ctx.Response.StatusCode = 500
        } finally {
            $ctx.Response.Close()
        }
    }
} finally {
    $listener.Close()
}
