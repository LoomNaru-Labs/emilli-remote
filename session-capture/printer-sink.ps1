# The working printer of the connected-session screenshots: a raw print port on 127.0.0.1:9100
# that takes every job and throws the data away, so a job sent to it really completes. Started
# hidden by run-take.ps1 on a GitHub runner only. Plain ASCII (Windows PowerShell 5.1).
param([int] $Port = 9100)
$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
$buffer = New-Object byte[] 65536
while ($true) {
    $client = $listener.AcceptTcpClient()
    try {
        $stream = $client.GetStream()
        while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) { }
    } catch { } finally { $client.Close() }
}
