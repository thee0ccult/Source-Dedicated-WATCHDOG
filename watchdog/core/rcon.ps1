# ================================
# RCON + NETWORK LAYER (FINAL)
# ================================

function New-RconPacketBytes {
    param([int]$Id,[int]$Type,[string]$Body)

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

function Read-RconPacket {
    param([System.Net.Sockets.NetworkStream]$Stream)

    $header = New-Object byte[] 4
    $got = 0

    while ($got -lt 4) {
        $read = $Stream.Read($header, $got, 4 - $got)
        if ($read -le 0) { throw "RCON connection closed while reading packet header." }
        $got += $read
    }

    $size = [BitConverter]::ToInt32($header, 0)
    if ($size -lt 10 -or $size -gt 1048576) {
        throw "Invalid RCON packet size: $size"
    }

    $payload = New-Object byte[] $size
    $got = 0

    while ($got -lt $size) {
        $read = $Stream.Read($payload, $got, $size - $got)
        if ($read -le 0) { throw "RCON connection closed while reading packet body." }
        $got += $read
    }

    return [PSCustomObject]@{
        Id   = [BitConverter]::ToInt32($payload, 0)
        Type = [BitConverter]::ToInt32($payload, 4)
        Body = [System.Text.Encoding]::UTF8.GetString($payload, 8, $size - 10)
    }
}

function Read-RconResponse {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$ExpectedId,
        [int]$TimeoutMs = 4000
    )

    $Stream.ReadTimeout = $TimeoutMs
    $builder = New-Object System.Text.StringBuilder

    try {
        while ($true) {
            $packet = Read-RconPacket -Stream $Stream

            if ($packet.Id -eq $ExpectedId) { break }

            if ($packet.Id -ne -1 -and $packet.Body) {
                [void]$builder.Append($packet.Body)
            }
        }
    } catch {}

    return $builder.ToString()
}

function Invoke-SourceRcon {
    param(
        [string]$rconHost,
        [int]$Port,
        [string]$Password,
        [string]$Command
    )

    if (-not $Password) { throw "Missing RCON password." }

    $client = New-Object System.Net.Sockets.TcpClient
    $client.NoDelay = $true
    $client.ReceiveTimeout = 5000
    $client.SendTimeout = 5000

    try {
        # --- STRICT PORT LOCK ---
			try {
				$client.Connect($rconHost, $Port)
			}
			catch {
				throw "RCON failed: could not connect to $rconHost`:$Port"
			}
        $stream = $client.GetStream()

        # =========================
        # FIXED AUTH HANDSHAKE
        # =========================

        $authId = Get-Random -Minimum 100000 -Maximum 999999

        $authPacket = New-RconPacketBytes -Id $authId -Type 3 -Body $Password
		$stream.Write($authPacket, 0, $authPacket.Length)
		$stream.Flush()

		# ADD THIS NEW LINE RIGHT HERE
		Start-Sleep -Milliseconds 300

		$authed = $false
        $deadline = (Get-Date).AddSeconds(5)

		while ((Get-Date) -lt $deadline) {
			try {
				$packet = Read-RconPacket -Stream $stream
			} catch {
				Start-Sleep -Milliseconds 100
				continue
			}

			if ($packet.Id -eq -1) {
				throw "RCON auth failed"
			}

			if ($packet.Id -eq $authId) {
				$authed = $true
				break
			}
		}

		if (-not $authed) {

			# RETRY ENTIRE AUTH ON SAME CONNECTION
			Start-Sleep -Milliseconds 300

			$stream.Write($authPacket, 0, $authPacket.Length)
			$stream.Flush()

			$retryDeadline = (Get-Date).AddSeconds(5)

			while ((Get-Date) -lt $retryDeadline) {
				try {
					$packet = Read-RconPacket -Stream $stream
				} catch {
					Start-Sleep -Milliseconds 100
					continue
				}

				if ($packet.Id -eq -1) {
					throw "RCON auth failed"
				}

				if ($packet.Id -eq $authId) {
					$authed = $true
					break
				}
			}
		}

		if (-not $authed) {
			throw "RCON auth timeout"
		}

        Start-Sleep -Milliseconds 150

        # =========================
        # COMMAND
        # =========================

        $cmdId = Get-Random -Minimum 1000000 -Maximum 9999999
        $endId = $cmdId + 1

        $cmdPacket = New-RconPacketBytes -Id $cmdId -Type 2 -Body $Command
        $endPacket = New-RconPacketBytes -Id $endId -Type 2 -Body ""

        $stream.Write($cmdPacket, 0, $cmdPacket.Length)
        $stream.Write($endPacket, 0, $endPacket.Length)
        $stream.Flush()

        return (Read-RconResponse -Stream $stream -ExpectedId $endId).Trim()
    }
    finally {
        try { $client.Close() } catch {}
    }
}

function Get-ServerPlayers {
    param($server)

    if (-not $global:RconFailureState) { $global:RconFailureState = @{} }
    if (-not $global:LastGoodRconData) { $global:LastGoodRconData = @{} }

    $fallbackMessage = ""
    $rconWasTried = $false

    if (-not [string]::IsNullOrWhiteSpace($server.RconPassword)) {
        if ($global:RconFailureState.ContainsKey($server.Name) -and
            $global:RconFailureState[$server.Name] -eq "FAILED") {

            $fallbackMessage = "RCON disabled; using A2S_PLAYER fallback."
        }
        else {
            $rconWasTried = $true

            try {
                $statusText = Invoke-SourceRcon `
                    -rconHost $server.RconHost `
                    -Port $server.RconPort `
                    -Password $server.RconPassword `
                    -Command "status"

                $players = @()
                $lines = ($statusText -split "`r?`n")
Write-Log "DEBUG [$($server.Name)] RAW STATUS:`n$statusText"
				foreach ($line in $lines) {

					# --- HUMAN PLAYERS ---
					if ($line -match '^\#\s*(\d+)\s+(?:\d+\s+)?"([^"]+)"\s+([^\s]*)\s*([0-9:]+)?\s*(\d+)?\s*(\d+)?') {

					$players += [PSCustomObject]@{
						UserId    = $Matches[1]
						Name      = $Matches[2]
						SteamId   = $Matches[3]
						Connected = if ($Matches[4]) { $Matches[4] } else { "" }
						Ping      = if ($Matches[5]) { [int]$Matches[5] } else { 0 }
						Loss      = if ($Matches[6]) { [int]$Matches[6] } else { 0 }
						Score     = $null
						IsBot     = ($Matches[3] -eq "BOT")
						Source    = "RCON"
						Raw       = $line.Trim()
					}

					continue
				}

					# --- FALLBACK: CONTAGION / MODDED PLAYER BLOCK PARSER ---
					if ($line -match '^Name:\s*(.+)$') {

						$playerName = $Matches[1].Trim()

						# look ahead for SteamID in following lines
						$steamId = ""
						$connected = ""
						$ping = 0
						$loss = 0

						for ($i = 1; $i -le 10; $i++) {
							if ($lines.Count -gt ($lines.IndexOf($line) + $i)) {
								$nextLine = $lines[$lines.IndexOf($line) + $i].Trim()

								if ($nextLine -match '^SteamID:\s*(.+)$') {
									$steamId = $Matches[1].Trim()
								}

								if ($nextLine -match '^Time:\s*(.+)$') {
									$connected = $Matches[1].Trim()
								}

								if ($nextLine -match '^Latency:\s*(\d+)') {
									$ping = [int]$Matches[1]
								}

								if ($nextLine -match '^Latency Loss:\s*(\d+)') {
									$loss = [int]$Matches[1]
								}
							}
						}

						$players += [PSCustomObject]@{
							UserId    = ""
							Name      = $playerName
							SteamId   = $steamId
							Connected = $connected
							Ping      = $ping
							Loss      = $loss
							Score     = $null
							IsBot     = $false
							Source    = "RCON-CONT"
							Raw       = $line.Trim()
						}

						continue
					}
					
					# --- L4D / L4D2 PLAYER PARSER (CRITICAL FIX) ---
					if ($line -match '^\s*(\d+)\s+(.+?)\s+STEAM_') {

						$players += [PSCustomObject]@{
							UserId    = $Matches[1]
							Name      = $Matches[2].Trim()
							SteamId   = ""   # L4D often hides it
							Connected = ""
							Ping      = 0
							Loss      = 0
							Score     = $null
							IsBot     = $false
							Source    = "RCON-L4D"
							Raw       = $line.Trim()
						}

						continue
					}

					# --- BOT PLAYERS (FIX) ---
					if ($line -match '^\#\s*(\d+)\s+"([^"]+)"\s+BOT') {

						$players += [PSCustomObject]@{
							UserId    = $Matches[1]
							Name      = $Matches[2]
							SteamId   = "BOT"
							Connected = ""
							Ping      = 0
							Loss      = 0
							Score     = $null
							IsBot     = $true
							Source    = "RCON"
							Raw       = $line.Trim()
						}

						continue
					}
				}

				# If RCON returned ONLY bots or empty, try merging A2S players
				$hasRealPlayers = ($players | Where-Object { -not $_.IsBot }).Count -gt 0

				if (-not $hasRealPlayers) {

					try {
						$queryHost = Get-A2SQueryHost -server $server
						$queryPort = [int]$server.Port

						$a2s = Get-SourceA2SPlayers -QueryHost $queryHost -Port $queryPort

						if ($a2s -and $a2s.Players.Count -gt 0) {

							foreach ($p in $a2s.Players) {

								# avoid duplicates (bots already exist in RCON)
								if (-not ($players | Where-Object { $_.Name -eq $p.Name })) {

									$players += [PSCustomObject]@{
										UserId    = $p.UserId
										Name = if ([string]::IsNullOrWhiteSpace($p.Name)) { "Player_$($p.UserId)" } else { $p.Name }
										SteamId   = ""
										Connected = $p.Connected
										Ping      = $p.Ping
										Loss      = $p.Loss
										Score     = $p.Score
										IsBot     = $false
										Source    = "A2S-MERGED"
										Raw       = ""
									}
								}
							}
						}
					}
					catch {}
				}

				return [PSCustomObject]@{
					Server    = $server.Name
					Port      = $server.Port
					Enabled   = $true
					Source    = "RCON"
					Message   = ""
					Players   = $players
					RawStatus = $statusText
				}
            }
            catch {
                $fallbackMessage = "RCON failed; using A2S_PLAYER fallback. $($_.Exception.Message)"
                if (-not $global:RconFailureState.ContainsKey($server.Name) -or
                    $global:RconFailureState[$server.Name] -ne "FAILED") {
                    $global:RconFailureState[$server.Name] = "FAILED"
                }
            }
        }
    }
    else {
        $fallbackMessage = "RCON password is not configured; using A2S_PLAYER fallback."
    }

    try {
        # STEP 1 FIX:
        # Player monitoring must query the exact configured server port.
        # Do NOT use Resolve-A2SEndpoint here because it scans neighboring ports.
        # With multiple Source servers on the same IP, that can attach CNC/ZPS player
        # widgets to CSS on 27018 after long sessions or restarts.
        $queryHost = Get-A2SQueryHost -server $server
        if ([string]::IsNullOrWhiteSpace($queryHost)) {
            $queryHost = "127.0.0.1"
        }

        $queryPort = [int]$server.Port

        $playerResult = Get-SourceA2SPlayers -QueryHost $queryHost -Port $queryPort

        if ($playerResult -and $playerResult.Reachable) {
            # Hard-copy the player rows so no array/object reference can bleed into another server.
            $players = @()
            foreach ($p in @($playerResult.Players)) {
                $players += [PSCustomObject]@{
                    UserId    = $p.UserId
                    Name      = $p.Name
                    SteamId   = $p.SteamId
                    Connected = $p.Connected
                    Ping      = $p.Ping
                    Loss      = $p.Loss
                    Score     = $p.Score
                    Duration  = $p.Duration
                    Source    = $p.Source
                    Raw       = $p.Raw
                }
            }

            return [PSCustomObject]@{
                Server    = $server.Name
                Port      = $server.Port
                QueryPort = $queryPort
                QueryHost = $queryHost
                Enabled   = $true
                Source    = "A2S"
                Message   = $fallbackMessage
                Players   = $players
                RawStatus = $null
            }
        }

        return [PSCustomObject]@{
            Server    = $server.Name
            Port      = $server.Port
            QueryPort = $queryPort
            QueryHost = $queryHost
            Enabled   = $true
            Source    = if ($rconWasTried) { "RCON/A2S" } else { "A2S" }
            Message   = if ($playerResult) { "$fallbackMessage A2S_PLAYER failed on exact port $queryPort`: $($playerResult.Error)" } else { "$fallbackMessage A2S_PLAYER failed on exact port $queryPort." }
            Players   = @()
            RawStatus = $null
        }
    }
    catch {
        return [PSCustomObject]@{
            Server    = $server.Name
            Port      = $server.Port
            Enabled   = $true
            Source    = if ($rconWasTried) { "RCON/A2S" } else { "A2S" }
            Message   = "$fallbackMessage A2S_PLAYER error: $($_.Exception.Message)"
            Players   = @()
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


function Read-A2SNullString {
    param(
        [Parameter(Mandatory = $true)][byte[]]$Buffer,
        [Parameter(Mandatory = $true)][ref]$IndexRef
    )

    $start = $IndexRef.Value
    while ($IndexRef.Value -lt $Buffer.Length -and $Buffer[$IndexRef.Value] -ne 0) {
        $IndexRef.Value++
    }

    $length = $IndexRef.Value - $start
    $text = ""
    if ($length -gt 0) {
        $text = [System.Text.Encoding]::UTF8.GetString($Buffer, $start, $length)
    }

    if ($IndexRef.Value -lt $Buffer.Length) {
        $IndexRef.Value++
    }

    return $text
}

function Get-A2SQueryHost {
    param($server)

    if ($server.PSObject.Properties["A2SHost"] -and -not [string]::IsNullOrWhiteSpace($server.A2SHost)) {
        return [string]$server.A2SHost
    }

    if (-not [string]::IsNullOrWhiteSpace($server.RconHost)) {
        return [string]$server.RconHost
    }

    return "127.0.0.1"
}


function Get-A2SPortCacheKey {
    param($server)

    $cacheHost = Get-A2SQueryHost -server $server
    if ([string]::IsNullOrWhiteSpace($cacheHost)) { $cacheHost = "127.0.0.1" }

    return "$($server.Name)|$cacheHost|$([int]$server.Port)"
}

function Get-A2SPortCandidates {
    param(
        [int]$BasePort,
        [int[]]$ExtraPorts = @()
    )

    $ports = New-Object System.Collections.Generic.List[int]

    foreach ($p in @($BasePort, ($BasePort + 1), ($BasePort - 1))) {
        if ($p -gt 0) { $ports.Add([int]$p) }
    }

    for ($i = 2; $i -le 15; $i++) {
        $p = $BasePort + $i
        if ($p -gt 0) { $ports.Add([int]$p) }
    }

    foreach ($p in $ExtraPorts) {
        if ($p -gt 0) { $ports.Add([int]$p) }
    }

    return @($ports.ToArray() | Select-Object -Unique)
}

function Test-A2SInfoMatchesServer {
    param(
        $server,
        $Info
    )

    if (-not $Info -or -not $Info.Reachable) { return $false }

    if ($server.PSObject.Properties["A2SFolder"] -and -not [string]::IsNullOrWhiteSpace($server.A2SFolder)) {
        if ([string]$Info.Folder -ne [string]$server.A2SFolder) { return $false }
    }

    if ($server.PSObject.Properties["A2SGame"] -and -not [string]::IsNullOrWhiteSpace($server.A2SGame)) {
        if ([string]$Info.Game -notlike "*$($server.A2SGame)*") { return $false }
    }

    return $true
}

function Find-WorkingA2SPort {
    param(
        [Parameter(Mandatory = $true)]$server,
        [int]$TimeoutMs = 800
    )

    $queryHost = Get-A2SQueryHost -server $server
    $extra = @()

    if ($server.PSObject.Properties["A2SPort"] -and $server.A2SPort) {
        $extra += [int]$server.A2SPort
    }

    $portsToTry = Get-A2SPortCandidates -BasePort ([int]$server.Port) -ExtraPorts $extra

    foreach ($port in $portsToTry) {
        $info = Get-SourceA2SInfo -QueryHost $queryHost -Port $port -TimeoutMs $TimeoutMs

        if (Test-A2SInfoMatchesServer -server $server -Info $info) {
            if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
                Write-Log "A2S LOCKED [$($server.Name)] Host=$queryHost Port=$port | $($info.Name) | $($info.Map)"
            }

            return [PSCustomObject]@{
                Reachable = $true
                Host      = $queryHost
                Port      = [int]$port
                Info      = $info
                Error     = ""
            }
        }
    }

    return [PSCustomObject]@{
        Reachable = $false
        Host      = $queryHost
        Port      = [int]$server.Port
        Info      = $null
        Error     = "No reachable A2S port found near $($server.Port)."
    }
}

function Resolve-A2SEndpoint {
    param(
        [Parameter(Mandatory = $true)]$server,
        [switch]$ForceRefresh
    )

    if (-not $global:A2SPortCache) { $global:A2SPortCache = @{} }

    $queryHost = Get-A2SQueryHost -server $server
    $cacheKey = Get-A2SPortCacheKey -server $server

    if (-not $ForceRefresh -and $global:A2SPortCache.ContainsKey($cacheKey)) {
        $cached = $global:A2SPortCache[$cacheKey]

        $info = Get-SourceA2SInfo -QueryHost $cached.Host -Port ([int]$cached.Port) -TimeoutMs 800
        if (Test-A2SInfoMatchesServer -server $server -Info $info) {
            return [PSCustomObject]@{
                Reachable = $true
                Host      = $cached.Host
                Port      = [int]$cached.Port
                Info      = $info
                Cached    = $true
                Error     = ""
            }
        }

        $global:A2SPortCache.Remove($cacheKey)
    }

    $found = Find-WorkingA2SPort -server $server
    if ($found.Reachable) {
        $global:A2SPortCache[$cacheKey] = @{
            Host = $found.Host
            Port = [int]$found.Port
            Time = (Get-Date)
        }

        return [PSCustomObject]@{
            Reachable = $true
            Host      = $found.Host
            Port      = [int]$found.Port
            Info      = $found.Info
            Cached    = $false
            Error     = ""
        }
    }

    return [PSCustomObject]@{
        Reachable = $false
        Host      = $queryHost
        Port      = [int]$server.Port
        Info      = $null
        Cached    = $false
        Error     = $found.Error
    }
}

function Clear-A2SPortCache {
    param($server)

    if (-not $global:A2SPortCache) { return }

    $cacheKey = Get-A2SPortCacheKey -server $server
    if ($global:A2SPortCache.ContainsKey($cacheKey)) {
        $global:A2SPortCache.Remove($cacheKey)
    }
}


function Send-A2SRequest {
    param(
        [Parameter(Mandatory = $true)][System.Net.Sockets.UdpClient]$Udp,
        [Parameter(Mandatory = $true)][byte[]]$Payload
    )

    [void]$Udp.Send($Payload, $Payload.Length)
}

function Receive-A2SPayload {
    param(
        [Parameter(Mandatory = $true)][System.Net.Sockets.UdpClient]$Udp,
        [int]$TimeoutMs = 2000
    )

    $remote = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
    $response = $Udp.Receive([ref]$remote)

    if ($response.Length -lt 4) {
        throw "A2S response too short."
    }

    # Simple packet: FF FF FF FF + payload
    if ($response[0] -eq 0xFF -and $response[1] -eq 0xFF -and $response[2] -eq 0xFF -and $response[3] -eq 0xFF) {
        if ($response.Length -le 4) { return [byte[]]@() }
        return [byte[]]$response[4..($response.Length - 1)]
    }

    # Split packet: FE FF FF FF + id + count/index + chunks
    if ($response[0] -eq 0xFE -and $response[1] -eq 0xFF -and $response[2] -eq 0xFF -and $response[3] -eq 0xFF) {
        $packetId = [BitConverter]::ToInt32($response, 4)

        if ($packetId -lt 0) {
            throw "Compressed A2S split packets are not supported by this PowerShell fallback."
        }

        $chunks = @($response)
        $count = [int]$response[8]
        $deadline = (Get-Date).AddMilliseconds($TimeoutMs)

        while ($chunks.Count -lt $count -and (Get-Date) -lt $deadline) {
            try {
                $next = $Udp.Receive([ref]$remote)
                if ($next.Length -ge 9 -and
                    $next[0] -eq 0xFE -and $next[1] -eq 0xFF -and $next[2] -eq 0xFF -and $next[3] -eq 0xFF -and
                    ([BitConverter]::ToInt32($next, 4)) -eq $packetId) {
                    $chunks += ,$next
                }
            } catch {
                break
            }
        }

        $ordered = $chunks | Sort-Object { [int]$_[9] }
        $merged = New-Object System.Collections.Generic.List[byte]

        foreach ($chunk in $ordered) {
            if ($chunk.Length -gt 10) {
                for ($i = 10; $i -lt $chunk.Length; $i++) {
                    $merged.Add($chunk[$i])
                }
            }
        }

        return [byte[]]$merged.ToArray()
    }

    throw ("Unknown A2S packet header: {0:X2} {1:X2} {2:X2} {3:X2}" -f $response[0], $response[1], $response[2], $response[3])
}

function Get-SourceA2SInfo {
    param(
        [string]$QueryHost,
        [int]$Port,
        [int]$TimeoutMs = 2000
    )

    $udp = New-Object System.Net.Sockets.UdpClient

    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Client.SendTimeout = $TimeoutMs
        $udp.Connect($QueryHost, $Port)

        $request = [byte[]](0xFF,0xFF,0xFF,0xFF,0x54) + [System.Text.Encoding]::ASCII.GetBytes("Source Engine Query`0")
        Send-A2SRequest -Udp $udp -Payload $request
        $payload = Receive-A2SPayload -Udp $udp -TimeoutMs $TimeoutMs

        $index = 0
        if ($payload.Length -lt 1) { throw "Empty A2S_INFO payload." }

        if ($payload[$index] -eq 0x41) {
            if (($index + 4) -ge $payload.Length) { throw "A2S_INFO challenge packet too short." }
            $challenge = $payload[1..4]
            $request = [byte[]](0xFF,0xFF,0xFF,0xFF,0x54) + [System.Text.Encoding]::ASCII.GetBytes("Source Engine Query`0") + $challenge
            Send-A2SRequest -Udp $udp -Payload $request
            $payload = Receive-A2SPayload -Udp $udp -TimeoutMs $TimeoutMs
            $index = 0
        }

        if ($payload[$index] -ne 0x49) {
            throw ("Unexpected A2S_INFO payload type: 0x{0:X2}" -f $payload[$index])
        }
        $index++

        $protocol = [int]$payload[$index]; $index++
        $name = Read-A2SNullString -Buffer $payload -IndexRef ([ref]$index)
        $map = Read-A2SNullString -Buffer $payload -IndexRef ([ref]$index)
        $folder = Read-A2SNullString -Buffer $payload -IndexRef ([ref]$index)
        $game = Read-A2SNullString -Buffer $payload -IndexRef ([ref]$index)

        if (($index + 1) -ge $payload.Length) { throw "A2S_INFO ended before AppID." }
        $appId = [BitConverter]::ToUInt16($payload, $index); $index += 2

        if (($index + 2) -ge $payload.Length) { throw "A2S_INFO ended before player counters." }
        $players = [int]$payload[$index]; $index++
        $maxPlayers = [int]$payload[$index]; $index++
        $bots = [int]$payload[$index]; $index++

        $serverType = if ($index -lt $payload.Length) { [char]$payload[$index] } else { "" }; $index++
        $environment = if ($index -lt $payload.Length) { [char]$payload[$index] } else { "" }; $index++
        $visibility = if ($index -lt $payload.Length) { [int]$payload[$index] } else { 0 }; $index++
        $vac = if ($index -lt $payload.Length) { [int]$payload[$index] } else { 0 }; $index++

        return [PSCustomObject]@{
            Reachable   = $true
            Host        = $QueryHost
            Port        = $Port
            Name        = $name
            Map         = $map
            Folder      = $folder
            Game        = $game
            AppId       = $appId
            Players     = $players
            MaxPlayers  = $maxPlayers
            Bots        = $bots
            Protocol    = $protocol
            ServerType  = [string]$serverType
            Environment = [string]$environment
            Visibility  = $visibility
            Vac         = $vac
            Error       = ""
        }
    }
    catch {
        return [PSCustomObject]@{
            Reachable   = $false
            Host        = $QueryHost
            Port        = $Port
            Name        = ""
            Map         = ""
            Folder      = ""
            Game        = ""
            AppId       = $null
            Players     = 0
            MaxPlayers  = 0
            Bots        = 0
            Protocol    = 0
            ServerType  = ""
            Environment = ""
            Visibility  = 0
            Vac         = 0
            Error       = $_.Exception.Message
        }
    }
    finally {
        try { $udp.Close() } catch {}
    }
}

function Get-SourceA2SPlayers {
    param(
        [string]$QueryHost,
        [int]$Port,
        [int]$TimeoutMs = 2000
    )

    $udp = New-Object System.Net.Sockets.UdpClient

    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Client.SendTimeout = $TimeoutMs
        $udp.Connect($QueryHost, $Port)

        # A2S_PLAYER almost always requires a challenge. Send -1 first.
        $request = [byte[]](0xFF,0xFF,0xFF,0xFF,0x55,0xFF,0xFF,0xFF,0xFF)
        Send-A2SRequest -Udp $udp -Payload $request
        $payload = Receive-A2SPayload -Udp $udp -TimeoutMs $TimeoutMs

        if ($payload.Length -lt 1) { throw "Empty A2S_PLAYER payload." }

        if ($payload[0] -eq 0x41) {
            if ($payload.Length -lt 5) { throw "A2S_PLAYER challenge packet too short." }
            $challenge = $payload[1..4]
            $request = [byte[]](0xFF,0xFF,0xFF,0xFF,0x55) + $challenge
            Send-A2SRequest -Udp $udp -Payload $request
            $payload = Receive-A2SPayload -Udp $udp -TimeoutMs $TimeoutMs
        }

        if ($payload[0] -ne 0x44) {
            throw ("Unexpected A2S_PLAYER payload type: 0x{0:X2}" -f $payload[0])
        }

        $index = 1
        if ($index -ge $payload.Length) { throw "A2S_PLAYER ended before count." }
        $count = [int]$payload[$index]; $index++

        $players = @()

        for ($n = 0; $n -lt $count; $n++) {
            if ($index -ge $payload.Length) { break }

            $playerIndex = [int]$payload[$index]; $index++
            $name = Read-A2SNullString -Buffer $payload -IndexRef ([ref]$index)

            if (($index + 7) -ge $payload.Length) { break }

            $score = [BitConverter]::ToInt32($payload, $index); $index += 4
            $duration = [BitConverter]::ToSingle($payload, $index); $index += 4

            $players += [PSCustomObject]@{
                UserId    = $playerIndex
                Name      = $name
                SteamId   = ""
                Connected = ([TimeSpan]::FromSeconds([math]::Max(0, [double]$duration))).ToString("hh\:mm\:ss")
                Ping      = $null
                Loss      = $null
                Score     = $score
                Duration  = [math]::Round([double]$duration, 2)
                Source    = "A2S"
                Raw       = ""
            }
        }

        return [PSCustomObject]@{
            Reachable = $true
            Host      = $QueryHost
            Port      = $Port
            Count     = $count
            Players   = $players
            Error     = ""
        }
    }
    catch {
        return [PSCustomObject]@{
            Reachable = $false
            Host      = $QueryHost
            Port      = $Port
            Count     = 0
            Players   = @()
            Error     = $_.Exception.Message
        }
    }
    finally {
        try { $udp.Close() } catch {}
    }
}
