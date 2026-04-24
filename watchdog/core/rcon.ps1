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
        $clean = $line.Trim()

        if ($clean -match '(?i)^hostname\s*:\s*(.+)$') {
            $result.Hostname = $Matches[1].Trim()
        }
        elseif ($clean -match '(?i)^version\s*:\s*(.+)$') {
            $result.Version = $Matches[1].Trim()
        }
        elseif ($clean -match '(?i)^udp/ip\s*:\s*(.+)$') {
            $result.UdpIp = $Matches[1].Trim()
        }
        elseif ($clean -match '(?i)^steamid\s*:\s*(.+)$') {
            $result.SteamId = $Matches[1].Trim()
        }
        elseif ($clean -match '(?i)^map\s*:\s*(.+)$') {
            $mapRaw = $Matches[1].Trim()

			if ($mapRaw -match '^([^\s]+)') {
				$result.Map = $Matches[1]
			} else {
				$result.Map = $mapRaw
			}
        }
        elseif ($clean -match '(?i)^players\s*:\s*(.+)$') {
            $result.PlayersInfo = $Matches[1].Trim()
        }
        elseif ($clean -match '(?i)^edicts\s*:\s*(.+)$') {
            $result.Edicts = $Matches[1].Trim()
        }
    }

    return $result
}

function Get-SourceA2SInfo {
    param(
        [string]$Host,
        [int]$Port,
        [int]$TimeoutMs = 2000
    )

    $udp = New-Object System.Net.Sockets.UdpClient

    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Connect($Host, $Port)

        $request = [byte[]](0xFF,0xFF,0xFF,0xFF,0x54) + [System.Text.Encoding]::ASCII.GetBytes("Source Engine Query`0")
        [void]$udp.Send($request, $request.Length)

        $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
$response = $udp.Receive([ref]$remote)

# --- HANDLE SPLIT PACKETS FIRST (CRITICAL) ---
if (
    $response.Length -ge 4 -and
    $response[0] -eq 0xFE -and
    $response[1] -eq 0xFF -and
    $response[2] -eq 0xFF -and
    $response[3] -eq 0xFF
) {
    $packets = @()
    $packets += ,$response

    try {
        while ($true) {
            $next = $udp.Receive([ref]$remote)
            if ($next.Length -lt 4) { break }

            if (
                $next[0] -eq 0xFE -and
                $next[1] -eq 0xFF -and
                $next[2] -eq 0xFF -and
                $next[3] -eq 0xFF
            ) {
                $packets += ,$next
            } else {
                break
            }
        }
    } catch {}
# --- DETECT COMPRESSED PACKETS (GMOD EDGE CASE) ---
$packetId = [BitConverter]::ToInt32($response, 4)

if ($packetId -lt 0) {
Write-Log "A2S compressed packet detected (GMOD) — skipping parse"
return @{
    Reachable = $false
}}
    $ordered = $packets | Sort-Object { $_[8] -band 0x0F }

    $merged = @()
    foreach ($p in $ordered) {
        if ($p.Length -gt 9) {
            $merged += $p[9..($p.Length - 1)]
        }
    }

    $response = [byte[]]$merged
}

if ($response.Length -lt 6) {
    throw "A2S_INFO response too short."
}
        function Read-NullTerminatedString {
            param(
                [byte[]]$Buffer,
                [ref]$IndexRef
            )

            $start = $IndexRef.Value

            while ($IndexRef.Value -lt $Buffer.Length -and $Buffer[$IndexRef.Value] -ne 0) {
                $IndexRef.Value++
            }

            $length = $IndexRef.Value - $start
            $text = [System.Text.Encoding]::UTF8.GetString($Buffer, $start, $length)

            if ($IndexRef.Value -lt $Buffer.Length) {
                $IndexRef.Value++
            }

            return $text
        }

        $index = 0

        if (
            $response.Length -ge 4 -and
            $response[0] -eq 0xFF -and
            $response[1] -eq 0xFF -and
            $response[2] -eq 0xFF -and
            $response[3] -eq 0xFF
        ) {
            $index = 4
        }
		# --- READ PACKET TYPE FIRST ---
		$packetType = $response[$index]
		$index++

		if ($packetType -eq 0x41) {
			if (($index + 3) -ge $response.Length) {
				throw "A2S challenge packet too short."
			}

			$challenge = $response[$index..($index + 3)]

			$request = [byte[]](0xFF,0xFF,0xFF,0xFF,0x54) +
				[System.Text.Encoding]::ASCII.GetBytes("Source Engine Query`0") +
				$challenge

			[void]$udp.Send($request, $request.Length)
$response = $udp.Receive([ref]$remote)

# --- HANDLE SPLIT PACKETS AFTER CHALLENGE (CRITICAL) ---
if (
    $response.Length -ge 4 -and
    $response[0] -eq 0xFE -and
    $response[1] -eq 0xFF -and
    $response[2] -eq 0xFF -and
    $response[3] -eq 0xFF
) {
    $packets = @()
    $packets += ,$response

    try {
        while ($true) {
            $next = $udp.Receive([ref]$remote)
            if ($next.Length -lt 4) { break }

            if (
                $next[0] -eq 0xFE -and
                $next[1] -eq 0xFF -and
                $next[2] -eq 0xFF -and
                $next[3] -eq 0xFF
            ) {
                $packets += ,$next
            } else {
                break
            }
        }
    } catch {}
# --- DETECT COMPRESSED PACKETS (GMOD EDGE CASE) ---
$packetId = [BitConverter]::ToInt32($response, 4)

if ($packetId -lt 0) {
    throw "Compressed A2S packets not supported (GMOD compression detected)"
}
    $ordered = $packets | Sort-Object { $_[8] -band 0x0F }

    $merged = @()
    foreach ($p in $ordered) {
        if ($p.Length -gt 9) {
            $merged += $p[9..($p.Length - 1)]
        }
    }

    $response = [byte[]]$merged
}

if ($response.Length -lt 6) {
    throw "A2S_INFO response too short after challenge."
}

			$index = 0
			if (
				$response.Length -ge 4 -and
				$response[0] -eq 0xFF -and
				$response[1] -eq 0xFF -and
				$response[2] -eq 0xFF -and
				$response[3] -eq 0xFF
			) {
				$index = 4
			}

			$packetType = $response[$index]
			$index++
		}

		if ($packetType -ne 0x49) {
			throw ("Unexpected A2S_INFO packet type: 0x{0:X2}" -f $packetType)
		}

		if ($index -ge $response.Length) {
			throw "A2S_INFO packet ended before protocol byte."
		}

		$protocol = $response[$index]
		$index++

		if ($index -ge $response.Length) { throw "A2S parse overflow (name)" }
		$name = Read-NullTerminatedString -Buffer $response -IndexRef ([ref]$index)
		$map    = Read-NullTerminatedString -Buffer $response -IndexRef ([ref]$index)
        $folder = Read-NullTerminatedString -Buffer $response -IndexRef ([ref]$index)
        $game   = Read-NullTerminatedString -Buffer $response -IndexRef ([ref]$index)

        if (($index + 1) -ge $response.Length) {
            throw "A2S_INFO packet ended before AppID."
        }

        $appId = [BitConverter]::ToUInt16($response, $index)
        $index += 2

        if (($index + 2) -ge $response.Length) {
            throw "A2S_INFO packet ended before player counts."
        }

        $players    = [int]$response[$index]; $index++
        $maxPlayers = [int]$response[$index]; $index++
        $bots       = [int]$response[$index]; $index++
		# --- HANDLE EDF (EXTENDED DATA FLAG) ---
		if ($index -lt $response.Length) {
			$edf = $response[$index]
			$index++

			# bit flags:
			# 0x80 = port
			# 0x10 = steamid
			# 0x40 = spectator port/name
			# 0x20 = keywords
			# 0x01 = gameid

			if ($edf -band 0x80) { $index += 2 } # port
			if ($edf -band 0x10) { $index += 8 } # steamid
			if ($edf -band 0x40) {
				$index += 2
				$null = Read-NullTerminatedString -Buffer $response -IndexRef ([ref]$index)
			}
			if ($edf -band 0x20) {
				$null = Read-NullTerminatedString -Buffer $response -IndexRef ([ref]$index)
			}
			if ($edf -band 0x01) { $index += 8 } # gameid
		}
        return [PSCustomObject]@{
            Reachable  = $true
            Host       = $Host
            Port       = $Port
            Name       = $name
            Map        = $map
            Folder     = $folder
            Game       = $game
            AppId      = $appId
            Players    = $players
            MaxPlayers = $maxPlayers
            Bots       = $bots
            Protocol   = $protocol
            Error      = ""
        }
    }
    catch {
        return [PSCustomObject]@{
            Reachable  = $false
            Host       = $Host
            Port       = $Port
            Name       = ""
            Map        = ""
            Folder     = ""
            Game       = ""
            AppId      = $null
            Players    = 0
            MaxPlayers = 0
            Bots       = 0
            Protocol   = 0
            Error      = $_.Exception.Message
        }
    }
    finally {
        try { $udp.Close() } catch {}
    }
}