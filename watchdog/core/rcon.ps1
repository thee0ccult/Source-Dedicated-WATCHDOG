# ================================
# RCON + NETWORK LAYER
# ================================

function New-RconPacketBytes {
    param(
        [int]$Id,
        [int]$Type,
        [string]$Body
    )

    $bodyBytes = [System.Text.Encoding]::ASCII.GetBytes($Body)
    $size = 4 + 4 + $bodyBytes.Length + 2

    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $bw.Write([int]$size)
    $bw.Write([int]$Id)
    $bw.Write([int]$Type)
    $bw.Write($bodyBytes)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Flush()

    return $ms.ToArray()
}

function Read-RconResponse {
    param(
        [System.Net.Sockets.NetworkStream]$Stream
    )

    $allText = New-Object System.Text.StringBuilder
    $buffer = New-Object byte[] 4096
    $deadline = (Get-Date).AddMilliseconds(1500)

    while ((Get-Date) -lt $deadline) {
        if ($Stream.DataAvailable) {
            $read = $Stream.Read($buffer, 0, $buffer.Length)
            if ($read -le 0) { break }

            $offset = 0
            while ($offset -lt $read) {
                if (($offset + 4) -gt $read) { break }
                $packetSize = [BitConverter]::ToInt32($buffer, $offset)
                if ($packetSize -le 0) { break }

                $packetTotal = $packetSize + 4
                if (($offset + $packetTotal) -gt $read) { break }

                $bodyLength = $packetSize - 10
                if ($bodyLength -gt 0) {
                    $bodyOffset = $offset + 12
                    $text = [System.Text.Encoding]::ASCII.GetString($buffer, $bodyOffset, $bodyLength)
                    [void]$allText.Append($text)
                }

                $offset += $packetTotal
            }

            $deadline = (Get-Date).AddMilliseconds(500)
        } else {
            Start-Sleep -Milliseconds 50
        }
    }

    return $allText.ToString()
}

function Invoke-SourceRcon {
    param(
        [string]$rconHost,
        [int]$Port,
        [string]$Password,
        [string]$Command
    )

    if ([string]::IsNullOrWhiteSpace($Password)) {
        throw "RCON password is not configured."
    }

    $client = New-Object System.Net.Sockets.TcpClient
    $client.ReceiveTimeout = 2000
    $client.SendTimeout = 2000
    $client.NoDelay = $true

    try {
        $client.Connect($rconHost, $Port)
        $stream = $client.GetStream()

        $authPacket = New-RconPacketBytes -Id 1 -Type 3 -Body $Password
        $stream.Write($authPacket, 0, $authPacket.Length)
        $stream.Flush()
        [void](Read-RconResponse -Stream $stream)

        $cmdPacket = New-RconPacketBytes -Id 2 -Type 2 -Body $Command
        $stream.Write($cmdPacket, 0, $cmdPacket.Length)
        $stream.Flush()

        $response = Read-RconResponse -Stream $stream
        return $response.Trim()
    }
    finally {
        try { $client.Close() } catch {}
    }
}

function Get-ServerPlayers {
    param($server)

    if ([string]::IsNullOrWhiteSpace($server.RconPassword)) {
        return [PSCustomObject]@{
            Server = $server.Name
            Port = $server.Port
            Enabled = $false
            Message = "Set RconPassword to enable player monitoring."
            Players = @()
            RawStatus = $null
        }
    }

    try {
        $statusText = Invoke-SourceRcon `
            -rconHost $server.RconHost `
            -Port $server.RconPort `
            -Password $server.RconPassword `
            -Command "status"

        $players = @()
        $lines = ($statusText -split "`r?`n")

        foreach ($line in $lines) {
            if ($line -match '^\#\s*(\d+)\s+"([^"]+)"\s+([^\s]+)\s+([0-9:]+)\s+(\d+)\s+(\d+)') {
                $players += [PSCustomObject]@{
                    UserId    = $Matches[1]
                    Name      = $Matches[2]
                    SteamId   = $Matches[3]
                    Connected = $Matches[4]
                    Ping      = $Matches[5]
                    Loss      = $Matches[6]
                    Raw       = $line.Trim()
                }
            }
        }

        return [PSCustomObject]@{
            Server = $server.Name
            Port = $server.Port
            Enabled = $true
            Message = ""
            Players = $players
            RawStatus = $statusText
        }
    }
    catch {
        return [PSCustomObject]@{
            Server = $server.Name
            Port = $server.Port
            Enabled = $true
            Message = $_.Exception.Message
            Players = @()
            RawStatus = $null
        }
    }
}

function Parse-ServerStatus {
    param([string]$text)

    $result = @{
        Hostname    = ""
        Version     = ""
        UdpIp       = ""
        SteamId     = ""
        Map         = ""
        PlayersInfo = ""
        Edicts      = ""
    }

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $result
    }

    $lines = $text -split "`r?`n"

    foreach ($line in $lines) {
        if ($line -match '^\s*hostname\s*:\s*(.+)$') {
            $result.Hostname = $Matches[1].Trim()
        }
        elseif ($line -match '^\s*version\s*:\s*(.+)$') {
            $result.Version = $Matches[1].Trim()
        }
        elseif ($line -match '^\s*udp/ip\s*:\s*(.+)$') {
            $result.UdpIp = $Matches[1].Trim()
        }
        elseif ($line -match '^\s*steamid\s*:\s*(.+)$') {
            $result.SteamId = $Matches[1].Trim()
        }
        elseif ($line -match '^\s*map\s*:\s*(.+)$') {
            $result.Map = $Matches[1].Trim()
        }
        elseif ($line -match '^\s*players\s*:\s*(.+)$') {
            $result.PlayersInfo = $Matches[1].Trim()
        }
        elseif ($line -match '^\s*edicts\s*:\s*(.+)$') {
            $result.Edicts = $Matches[1].Trim()
        }
    }

    return $result
}