# ================================== #
# Source Dedicated Watchdog by dr.N0 #
# ================================== #

$ErrorActionPreference = "Stop"

$LogDir = Join-Path $PSScriptRoot "logs"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir | Out-Null
}

try {

    Write-Host "[LOGS] Cleaning old transcripts..." `
        -ForegroundColor DarkGray

    Get-ChildItem `
        -Path $LogDir `
        -Filter "*.log" |
    Where-Object {
        $_.LastWriteTime -lt (Get-Date).AddDays(-2)
    } |
    Remove-Item -Force

}
catch {

    Write-Host (
        "[WARNING] Log cleanup failed: " +
        $_.Exception.Message
    ) -ForegroundColor Yellow
}

$LogFile = Join-Path $LogDir ("watchdog_relay_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")

Start-Transcript -Path $LogFile -Append

# --- Console Appearance ---
$Host.UI.RawUI.BackgroundColor = "Black"
$Host.UI.RawUI.ForegroundColor = "DarkRed"

Clear-Host

Write-Host "            +######################+     " -ForegroundColor DarkRed
Write-Host "        ########################++####   " -ForegroundColor DarkRed
Write-Host "     +######++-----++#########-+++-+##   " -ForegroundColor DarkRed
Write-Host "   +#####---+-----------#####--###++##   " -ForegroundColor DarkRed
Write-Host "  ####+----+##------------##+------###   " -ForegroundColor DarkRed
Write-Host " +###------####------+#+---+#########+   " -ForegroundColor DarkRed
Write-Host "####+-----+#####++-+###-----+#######+    " -ForegroundColor DarkRed
Write-Host "###+------+######+++###------######+     " -ForegroundColor DarkRed
Write-Host "###+------######+++++#+------######      " -ForegroundColor DarkRed
Write-Host "###+-------+#+++###++#+------+####       " -ForegroundColor DarkRed
Write-Host "###+-------++++++#+++#+------#####       " -ForegroundColor DarkRed
Write-Host "####------+#++++++++####+---+###+        " -ForegroundColor DarkRed
Write-Host " ####----+##+++++++######--+####         " -ForegroundColor DarkRed
Write-Host "  ####+--++#+++++++###+---+####          " -ForegroundColor DarkRed
Write-Host "   #####----------------+####+           " -ForegroundColor DarkRed
Write-Host "     ######+---------######+             " -ForegroundColor DarkRed
Write-Host "       +#################+               " -ForegroundColor DarkRed
Write-Host "           ##########+                   " -ForegroundColor DarkRed

Write-Host "=========================================" -ForegroundColor DarkRed
Write-Host "       SOURCE DEDICATED RELAY            " -ForegroundColor Red
Write-Host "      Brought to you by dr.N0            " -ForegroundColor Red
Write-Host "=========================================" -ForegroundColor DarkRed

$RelayConfig = @{
    RelayName = "watchdog-vps-01"
    ApiKey    = "wdr01vps91daw"

    BaseUrl   = "http://drn0.site.nfoservers.com/hub/drn0/to0lb0x/watchdog/relay_api"
}

function Invoke-RelayCleanup {

    Write-Host "[CLEANUP] Running memory cleanup..." `
        -ForegroundColor DarkGray

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    [System.GC]::Collect()
}

function Register-Node {

    Write-Host ""
    Write-Host "[REGISTER] Registering relay node..." -ForegroundColor Red
    Write-Host ""

    $body = @{
        relay_name         = $RelayConfig.RelayName
        api_key            = $RelayConfig.ApiKey
        version            = "1.0.0"
        hostname           = $env:COMPUTERNAME
        operating_system   = (Get-CimInstance Win32_OperatingSystem).Caption
        powershell_version = $PSVersionTable.PSVersion.ToString()
        private_ip         = "127.0.0.1"
    } | ConvertTo-Json

try {

    $result = Invoke-RestMethod `
        -Uri "$($RelayConfig.BaseUrl)/register_node.php" `
        -Method POST `
        -ContentType "application/json" `
        -TimeoutSec 30 `
        -Body $body

    Write-Host "[SUCCESS] Registration successful." `
        -ForegroundColor DarkYellow
}
catch {

    Write-Host (
        "[WARNING] Registration failed: " +
        $_.Exception.Message
    ) -ForegroundColor Yellow

    Write-Host "[INFO] Continuing anyway..." `
        -ForegroundColor DarkYellow
}
}

function Invoke-RelayApi {

    param(
        [string]$Endpoint,
        [hashtable]$Body = @{}
    )

    try {

        $json = $Body | ConvertTo-Json -Depth 10

        return Invoke-RestMethod `
            -Uri "$($RelayConfig.BaseUrl)/$Endpoint" `
            -Method POST `
            -ContentType "application/json" `
            -TimeoutSec 30 `
            -Headers @{
                "X-Relay-Name" = $RelayConfig.RelayName
                "X-Relay-Key"  = $RelayConfig.ApiKey
            } `
            -Body $json
    }
    catch {

        Write-Host (
            "[API ERROR] $Endpoint : " +
            $_.Exception.Message
        ) -ForegroundColor Yellow

        return @{
            success = $false
            data = @{}
        }
    }
}

function Get-PendingSubmissions {

    Write-Host ""
    Write-Host "[QUEUE] Checking pending submissions..." -ForegroundColor Red
    Write-Host ""

    $result = Invoke-RelayApi `
        -Endpoint "get_pending_submissions.php" `
        -Body @{
            limit = 10
        }

    if (-not $result.success) {

        Write-Host "[ERROR] API returned failure." -ForegroundColor Red
        return @()
    }

    Write-Host "[INFO] Pending submissions: $($result.data.count)" -ForegroundColor DarkYellow
    Write-Host ""

    foreach ($server in $result.data.submissions) {

        Write-Host "=================================" -ForegroundColor DarkRed
        Write-Host "Submission ID : $($server.id)" -ForegroundColor White
        Write-Host "IP            : $($server.ip_address)" -ForegroundColor White
        Write-Host "Query Port    : $($server.query_port)" -ForegroundColor White
        Write-Host "Join Port     : $($server.join_port)" -ForegroundColor White
        Write-Host "Game Type     : $($server.game_type)" -ForegroundColor White
        Write-Host "=================================" -ForegroundColor DarkRed
        Write-Host ""
    }

    return $result.data.submissions
}

function Query-A2SInfo {

    param(
        [string]$ServerAddress,
        [int]$Port
    )

    Write-Host ""
    Write-Host "[A2S] Querying $ServerAddress`:$Port" -ForegroundColor Yellow
    Write-Host ""

    $endpoint = New-Object System.Net.IPEndPoint(
        [System.Net.IPAddress]::Any,
        0
    )

    $client = New-Object System.Net.Sockets.UdpClient
    $client.Client.ReceiveTimeout = 5000

    try {

        #
        # FIRST REQUEST
        #
        $packet = New-Object byte[] 25

        $packet[0] = 0xFF
        $packet[1] = 0xFF
        $packet[2] = 0xFF
        $packet[3] = 0xFF
        $packet[4] = 0x54

        $query = [System.Text.Encoding]::ASCII.GetBytes(
            "Source Engine Query"
        )

        [Array]::Copy($query, 0, $packet, 5, $query.Length)

        $packet[24] = 0x00

        $client.Send(
            $packet,
            $packet.Length,
            $ServerAddress,
            $Port
        ) | Out-Null

        $response = $client.Receive([ref]$endpoint)

        #
        # Challenge packet?
        #
        if ($response.Length -ge 9 -and $response[4] -eq 0x41) {

            Write-Host "[INFO] Server requested challenge." `
                -ForegroundColor Red

            $challenge = $response[5..8]

            Write-Host (
                "[INFO] Challenge bytes: " +
                ($challenge | ForEach-Object { $_.ToString("X2") }) -join " "
            ) -ForegroundColor Gray

            #
            # Build second request
            #
            $packet2 = New-Object byte[] 29

            $packet2[0] = 0xFF
            $packet2[1] = 0xFF
            $packet2[2] = 0xFF
            $packet2[3] = 0xFF
            $packet2[4] = 0x54

            [Array]::Copy($query, 0, $packet2, 5, $query.Length)

            $packet2[24] = 0x00

            [Array]::Copy(
                $challenge,
                0,
                $packet2,
                25,
                4
            )

            $client.Send(
                $packet2,
                $packet2.Length,
                $ServerAddress,
                $Port
            ) | Out-Null

            $response = $client.Receive([ref]$endpoint)
        }

        Write-Host ""
        Write-Host "[SUCCESS] Final packet received." `
            -ForegroundColor DarkYellow

        Write-Host "Packet Length: $($response.Length) bytes"
        Write-Host "Packet Type:   0x$('{0:X2}' -f $response[4])"

        return $response
    }
    catch {

        Write-Host ""
        Write-Host "[FAILED] A2S query failed." `
            -ForegroundColor Red

        Write-Host $_.Exception.Message `
            -ForegroundColor DarkRed

        return $null
    }
    finally {

        $client.Close()

    }
}

function Read-NullTerminatedString {

    param(
        [byte[]]$Bytes,
        [ref]$Index
    )

    $start = $Index.Value

    while (
        $Index.Value -lt $Bytes.Length `
        -and $Bytes[$Index.Value] -ne 0
    ) {
        $Index.Value++
    }

    $length = $Index.Value - $start

    $text = [System.Text.Encoding]::UTF8.GetString(
        $Bytes,
        $start,
        $length
    )

    $Index.Value++

    return $text
}

function Parse-A2SInfo {

    param(
        [byte[]]$Bytes
    )

    if ($Bytes.Length -lt 6) {

        Write-Host "[ERROR] Packet too short." `
            -ForegroundColor Red

        return
    }

    if ($Bytes[4] -ne 0x49) {

        Write-Host "[ERROR] Not an A2S_INFO packet." `
            -ForegroundColor Red

        return
    }

    $i = 6

    $hostname = Read-NullTerminatedString `
        -Bytes $Bytes `
        -Index ([ref]$i)

    $map = Read-NullTerminatedString `
        -Bytes $Bytes `
        -Index ([ref]$i)

    $folder = Read-NullTerminatedString `
        -Bytes $Bytes `
        -Index ([ref]$i)

    $game = Read-NullTerminatedString `
        -Bytes $Bytes `
        -Index ([ref]$i)

    $appId = [BitConverter]::ToUInt16($Bytes, $i)
    $i += 2

    $players = $Bytes[$i++]
    $maxPlayers = $Bytes[$i++]
    $bots = $Bytes[$i++]

    $serverType = [char]$Bytes[$i++]
    $serverOS = [char]$Bytes[$i++]

    $password = $Bytes[$i++]
    $vac = $Bytes[$i++]

    $version = Read-NullTerminatedString `
        -Bytes $Bytes `
        -Index ([ref]$i)

    Write-Host ""
    Write-Host "=========================================" `
        -ForegroundColor DarkRed

    Write-Host "HOSTNAME : $hostname" `
        -ForegroundColor White

    Write-Host "MAP      : $map" `
        -ForegroundColor White

    Write-Host "FOLDER   : $folder" `
        -ForegroundColor White

    Write-Host "GAME     : $game" `
        -ForegroundColor White

    Write-Host "APP ID   : $appId" `
        -ForegroundColor White

    Write-Host "PLAYERS  : $players / $maxPlayers" `
        -ForegroundColor White

    Write-Host "BOTS     : $bots" `
        -ForegroundColor White

    Write-Host "VAC      : $vac" `
        -ForegroundColor White

    Write-Host "VERSION  : $version" `
        -ForegroundColor White

    Write-Host "=========================================" `
        -ForegroundColor DarkRed

    return @{
        Hostname   = $hostname
        Map        = $map
        Folder     = $folder
        Game       = $game
        AppId      = $appId
        Players    = $players
        MaxPlayers = $maxPlayers
        Bots       = $bots
        VAC        = $vac
        Version    = $version
    }
}

function Query-A2SPlayers {

    param(
        [string]$ServerAddress,
        [int]$Port
    )

    Write-Host ""
    Write-Host "[A2S_PLAYER] Querying player list..." `
        -ForegroundColor Red

    $endpoint = New-Object System.Net.IPEndPoint(
        [System.Net.IPAddress]::Any,
        0
    )

    $client = New-Object System.Net.Sockets.UdpClient
    $client.Client.ReceiveTimeout = 5000

    try {

        #
        # Initial player request
        #
        $packet = [byte[]](
            0xFF,0xFF,0xFF,0xFF,
            0x55,
            0xFF,0xFF,0xFF,0xFF
        )

        $client.Send(
            $packet,
            $packet.Length,
            $ServerAddress,
            $Port
        ) | Out-Null

        $response = $client.Receive([ref]$endpoint)

        #
        # Must receive challenge
        #
        if ($response.Length -lt 9 -or $response[4] -ne 0x41) {

            Write-Host "[WARNING] No player challenge received." `
                -ForegroundColor Yellow

            return @()
        }

        $challenge = $response[5..8]

        Write-Host (
            "[INFO] Player challenge: " +
            (($challenge |
                ForEach-Object {
                    $_.ToString("X2")
                }) -join " ")
        ) -ForegroundColor Gray

        #
        # Actual player request
        #
        $packet2 = New-Object byte[] 9

        $packet2[0] = 0xFF
        $packet2[1] = 0xFF
        $packet2[2] = 0xFF
        $packet2[3] = 0xFF
        $packet2[4] = 0x55

        [Array]::Copy(
            $challenge,
            0,
            $packet2,
            5,
            4
        )

        $client.Send(
            $packet2,
            $packet2.Length,
            $ServerAddress,
            $Port
        ) | Out-Null

        return $client.Receive([ref]$endpoint)
    }
    catch {

        Write-Host "[WARNING] Player query failed." `
            -ForegroundColor Yellow

        return @()
    }
    finally {

        $client.Close()

    }
}

function Parse-A2SPlayers {

    param(
        [byte[]]$Bytes
    )

    $players = @()

    if ($Bytes.Length -lt 6) {
        return $players
    }

    if ($Bytes[4] -ne 0x44) {
        return $players
    }

    $count = $Bytes[5]

    Write-Host ""
    Write-Host "[PLAYERS] Found $count players." `
        -ForegroundColor Red

    $i = 6

    while ($i -lt $Bytes.Length) {

        try {

            $index = $Bytes[$i]
            $i++

            $name = Read-NullTerminatedString `
                -Bytes $Bytes `
                -Index ([ref]$i)

            if (($i + 8) -gt $Bytes.Length) {
                break
            }

            $score = [BitConverter]::ToInt32(
                $Bytes,
                $i
            )

            $i += 4

            $duration = [BitConverter]::ToSingle(
                $Bytes,
                $i
            )

            $i += 4

            Write-Host (
                "  $name | Score: $score | " +
                "$([int]$duration)s"
            ) -ForegroundColor White

            $players += @{
                index = $index
                name = $name
                score = $score
                duration_seconds = [int]$duration
            }
        }
        catch {
            break
        }
    }

    return $players
}

function Submit-RelayPlayers {

    param(
        [int]$ServerId,
        [array]$Players
    )

    Write-Host ""
    Write-Host "[UPLOAD] Sending player list..." `
        -ForegroundColor Red

    $result = Invoke-RelayApi `
        -Endpoint "submit_players.php" `
        -Body @{
            server_id = $ServerId
            players   = $Players
        }

    if ($result.success) {

        Write-Host (
            "[SUCCESS] Stored " +
            "$($Players.Count) players."
        ) -ForegroundColor DarkYellow
    }
}

function Submit-RelayRules {

    param(
        [long]$ServerId,
        [array]$Rules
    )

    Write-Host ""
    Write-Host "[UPLOAD] Sending rules..." `
        -ForegroundColor Red

    $result = Invoke-RelayApi `
        -Endpoint "submit_rules.php" `
        -Body @{
            server_id = $ServerId
            rules     = $Rules
        }

    if ($result.success) {

        Write-Host (
            "[SUCCESS] Stored " +
            $result.data.stored_rules +
            " rules."
        ) -ForegroundColor DarkYellow
    }
}

function Get-A2SRules {

    param(
        [string]$ServerAddress,
        [int]$Port
    )

    Write-Host ""
    Write-Host "[A2S_RULES] Querying server rules..." -ForegroundColor Red

    $endpoint = New-Object System.Net.IPEndPoint(
        [System.Net.IPAddress]::Any,
        0
    )

    $client = New-Object System.Net.Sockets.UdpClient
    $client.Client.ReceiveTimeout = 5000

    try {

        $packet = [byte[]](
            0xFF,0xFF,0xFF,0xFF,
            0x56,
            0xFF,0xFF,0xFF,0xFF
        )

        $client.Send(
            $packet,
            $packet.Length,
            $ServerAddress,
            $Port
        ) | Out-Null

        $response = $client.Receive([ref]$endpoint)

        if ($response.Length -lt 9 -or $response[4] -ne 0x41) {

            Write-Host "[WARNING] No A2S_RULES challenge." -ForegroundColor Yellow
            return @()
        }

        $challenge = $response[5..8]

        Write-Host (
            "[INFO] Rules challenge: " +
            (($challenge | ForEach-Object { $_.ToString("X2") }) -join " ")
        ) -ForegroundColor Gray

        $packet2 = New-Object byte[] 9

        $packet2[0] = 0xFF
        $packet2[1] = 0xFF
        $packet2[2] = 0xFF
        $packet2[3] = 0xFF
        $packet2[4] = 0x56

        [Array]::Copy(
            $challenge,
            0,
            $packet2,
            5,
            4
        )

        $client.Send(
            $packet2,
            $packet2.Length,
            $ServerAddress,
            $Port
        ) | Out-Null

        $response = $client.Receive([ref]$endpoint)

        #
        # Handle split packet: FE FF FF FF
        #
        if (
            $response.Length -gt 12 `
            -and $response[0] -eq 0xFE `
            -and $response[1] -eq 0xFF `
            -and $response[2] -eq 0xFF `
            -and $response[3] -eq 0xFF
        ) {

            Write-Host "[INFO] Split rules packet detected." -ForegroundColor Red

$packetId = [BitConverter]::ToInt32($response, 4)
$totalPackets = [int]$response[8]
$packetNumber = [int]$response[9]
$payloadStart = 12

$parts = @{}

$parts[$packetNumber] = @(
    for ($x = $payloadStart; $x -lt $response.Length; $x++) {
        [byte]$response[$x]
    }
)

while ($parts.Count -lt $totalPackets) {

    $next = $client.Receive([ref]$endpoint)

    if (
        $next.Length -gt 12 `
        -and $next[0] -eq 0xFE `
        -and $next[1] -eq 0xFF `
        -and $next[2] -eq 0xFF `
        -and $next[3] -eq 0xFF
    ) {

        $nextId = [BitConverter]::ToInt32($next, 4)

        if ($nextId -ne $packetId) {
            continue
        }

        $nextNumber = [int]$next[9]

        $parts[$nextNumber] = @(
            for ($x = $payloadStart; $x -lt $next.Length; $x++) {
                [byte]$next[$x]
            }
        )
    }
}

$assembled = New-Object System.Collections.Generic.List[byte]

for ($i = 0; $i -lt $totalPackets; $i++) {

    if ($parts.ContainsKey($i)) {

        foreach ($b in $parts[$i]) {
            $assembled.Add([byte]$b)
        }
    }
}

$response = $assembled.ToArray()
Write-Host (
    "[INFO] Reassembled rules packet: " +
    "$($response.Length) bytes."
) -ForegroundColor DarkGray

}
        #
        # Normal packet must now be:
        # FF FF FF FF 45 ...
        #
        if (
            $response.Length -lt 7 `
            -or $response[0] -ne 0xFF `
            -or $response[1] -ne 0xFF `
            -or $response[2] -ne 0xFF `
            -or $response[3] -ne 0xFF `
            -or $response[4] -ne 0x45
        ) {

            Write-Host "[WARNING] Invalid A2S_RULES packet after assembly." -ForegroundColor Yellow
            return @()
        }

        $index = 5

        $ruleCount = [BitConverter]::ToUInt16(
            $response,
            $index
        )

        $index += 2

        $rules = @()

        for ($i = 0; $i -lt $ruleCount; $i++) {

            if ($index -ge $response.Length) {
                break
            }

            $name = Read-NullTerminatedString `
                -Bytes $response `
                -Index ([ref]$index)

            if ($index -ge $response.Length) {
                break
            }

            $value = Read-NullTerminatedString `
                -Bytes $response `
                -Index ([ref]$index)

            if ($name -ne "") {

                $rules += @{
                    name  = $name
                    value = $value
                }
            }
        }

        Write-Host "[RULES] Found $($rules.Count) rules." -ForegroundColor Gray

        return $rules
    }
    catch {

        Write-Host "[WARNING] A2S_RULES failed." -ForegroundColor Yellow
        Write-Host $_.Exception.Message -ForegroundColor DarkYellow

        return @()
    }
    finally {

        $client.Close()
    }
}

function Submit-RelayUpdate {

    param(
        [object]$Server,
        [hashtable]$Info
    )

    Write-Host ""
    Write-Host "[UPLOAD] Sending live data..." `
        -ForegroundColor Red

$body = @{

    hostname = $Info.Hostname
    map_name = $Info.Map
    folder = $Info.Folder
    game_name = $Info.Game

    app_id = $Info.AppId

    players = $Info.Players
    max_players = $Info.MaxPlayers
    bots = $Info.Bots

    vac_secured = $Info.VAC
    version = $Info.Version
}

#
# New submission?
#
if ($Server.PSObject.Properties["submitted_at"]) {

    $body.submission_id = $Server.id
}
else {

    $body.server_id = $Server.id
}

try {

    $json = $body | ConvertTo-Json -Depth 10 -Compress

    $json = [System.Text.Encoding]::UTF8.GetString(
        [System.Text.Encoding]::UTF8.GetBytes($json)
    )

    $result = Invoke-RestMethod `
        -Uri "$($RelayConfig.BaseUrl)/submit_update.php" `
        -Method POST `
        -ContentType "application/json; charset=utf-8" `
        -TimeoutSec 30 `
        -Headers @{
            "X-Relay-Name" = $RelayConfig.RelayName
            "X-Relay-Key"  = $RelayConfig.ApiKey
        } `
        -Body $json

    if ($result.success) {

        Write-Host "[SUCCESS] Data stored." `
            -ForegroundColor DarkYellow

        Write-Host "Server ID: $($result.data.server_id)"

        return $result.data.server_id
    }

    Write-Host "[FAILED] Upload failed." `
        -ForegroundColor Red

    return $null
}
catch {

    Write-Host (
        "[ERROR] submit_update.php failed: " +
        $_.Exception.Message
    ) -ForegroundColor Yellow

    return $null
}

}
function Send-Heartbeat {

    try {

        $null = Invoke-RelayApi `
            -Endpoint "heartbeat.php"

        Write-Host "[HEARTBEAT] Relay online." `
            -ForegroundColor DarkGray
    }
    catch {

        Write-Host (
            "[WARNING] Heartbeat failed: " +
            $_.Exception.Message
        ) -ForegroundColor Yellow
    }
}

function Report-SubmissionFailure {

    param(
        [object]$Server,
        [string]$Reason
    )

    Write-Host "[FAILED] Marking submission as failed..." `
        -ForegroundColor Red

    Invoke-RelayApi `
        -Endpoint "report_submission_failure.php" `
        -Body @{
            submission_id = $Server.id
            message       = $Reason
        }
}

function Get-ActiveServers {

    $result = Invoke-RelayApi `
        -Endpoint "get_active_servers.php"

    if (-not $result.success) {

        return @()
    }

    return $result.data.servers
}


function Export-FederationMaster {

    Write-Host ""
    Write-Host "========================================="
    Write-Host "       FEDERATION MASTER EXPORT"
    Write-Host "========================================="
    Write-Host ""

    try {

        $result = Invoke-RestMethod `
            -Uri "$($RelayConfig.BaseUrl)/federation_export.php" `
            -Method GET `
            -TimeoutSec 30

        if ($result.success) {

            Write-Host (
                "[SUCCESS] Exported " +
                "$($result.data.servers_exported) servers."
            ) -ForegroundColor DarkYellow
        }
        else {

            Write-Host "[WARNING] Export failed." `
                -ForegroundColor Yellow
        }
    }
    catch {

        Write-Host (
            "[WARNING] Federation export failed: " +
            $_.Exception.Message
        ) -ForegroundColor Yellow
    }
}


Register-Node

$ScriptStartTime = Get-Date
$MaxRuntimeHours = 24

while ($true) {

    try {

    Write-Host ""
    Write-Host "========================================="
    Write-Host "         RELAY LOOP START"
    Write-Host "========================================="
    Write-Host ""

    Send-Heartbeat

    #
    # Process NEW submissions
    #
    $pendingServers = Get-PendingSubmissions

foreach ($server in $pendingServers) {

    try {

        $response = Query-A2SInfo `
            -ServerAddress $server.ip_address `
            -Port $server.query_port

        if ($null -eq $response) {

            Report-SubmissionFailure `
                -Server $server `
                -Reason "No A2S response received."

            continue
        }

        $serverInfo = Parse-A2SInfo `
            -Bytes $response

        if ($null -eq $serverInfo) {

            Report-SubmissionFailure `
                -Server $server `
                -Reason "Invalid A2S packet."

            continue
        }

$serverId = Submit-RelayUpdate `
    -Server $server `
    -Info $serverInfo

$playerPacket = Query-A2SPlayers `
    -ServerAddress $server.ip_address `
    -Port $server.query_port

if ($playerPacket.Length -gt 0) {

    $players = Parse-A2SPlayers `
        -Bytes $playerPacket

    if ($serverId) {

        Submit-RelayPlayers `
            -ServerId $serverId `
            -Players $players

        $rules = Get-A2SRules `
            -ServerAddress $server.ip_address `
            -Port $server.query_port

        Submit-RelayRules `
            -ServerId $serverId `
            -Rules $rules
    }
}

}
catch {

    Write-Host (
        "[ERROR] Pending submission failed: " +
        "$($server.ip_address):$($server.query_port)"
    ) -ForegroundColor Red

    Write-Host $_.Exception.Message `
        -ForegroundColor DarkRed
}
}

    #
    # Refresh VERIFIED servers
    #
    Write-Host ""
    Write-Host "[MONITOR] Updating verified servers..." `
        -ForegroundColor DarkRed

    $activeServers = Get-ActiveServers

    Write-Host "[INFO] Active servers: $($activeServers.Count)" `
        -ForegroundColor Gray

    foreach ($server in $activeServers) {

    try {

        Write-Host ""
        Write-Host "[LIVE] Refreshing $($server.ip_address):$($server.query_port)" `
            -ForegroundColor Gray

        $response = Query-A2SInfo `
            -ServerAddress $server.ip_address `
            -Port $server.query_port

        if ($null -eq $response) {

            Write-Host "[WARNING] Server offline." `
                -ForegroundColor Yellow

            continue
        }

        $serverInfo = Parse-A2SInfo `
            -Bytes $response

        if ($null -eq $serverInfo) {
            continue
        }

        $serverId = Submit-RelayUpdate `
            -Server $server `
            -Info $serverInfo

        $playerPacket = Query-A2SPlayers `
            -ServerAddress $server.ip_address `
            -Port $server.query_port

        if ($playerPacket.Length -gt 0) {

            $players = Parse-A2SPlayers `
                -Bytes $playerPacket

            if ($serverId) {

                Submit-RelayPlayers `
                    -ServerId $serverId `
                    -Players $players

                $rules = Get-A2SRules `
                    -ServerAddress $server.ip_address `
                    -Port $server.query_port

                Submit-RelayRules `
                    -ServerId $serverId `
                    -Rules $rules
            }
        }
    }
    catch {

        Write-Host (
            "[ERROR] Live server failed: " +
            "$($server.ip_address):$($server.query_port)"
        ) -ForegroundColor Red

        Write-Host $_.Exception.Message `
            -ForegroundColor DarkRed
    }
}

try {

    Export-FederationMaster
}
catch {

    Write-Host (
        "[WARNING] Export-FederationMaster failed: " +
        $_.Exception.Message
    ) -ForegroundColor Yellow
}

try {

    Invoke-RelayCleanup
}
catch {

    Write-Host (
        "[WARNING] Cleanup failed: " +
        $_.Exception.Message
    ) -ForegroundColor Yellow
}

$runtime =
    (Get-Date) - $ScriptStartTime

if ($runtime.TotalHours -ge $MaxRuntimeHours) {

    Write-Host ""
    Write-Host "========================================="
    Write-Host "         SCHEDULED SELF RESTART"
    Write-Host "========================================="
    Write-Host ""

    Write-Host (
        "[INFO] Runtime reached " +
        "$([math]::Round($runtime.TotalHours,2)) hours."
    ) -ForegroundColor Yellow

    try {

    Stop-Transcript

}
catch {

    Write-Host (
        "[WARNING] Transcript already stopped."
    ) -ForegroundColor DarkYellow
}

    Start-Process powershell `
        -ArgumentList @(
            '-ExecutionPolicy',
            'Bypass',
            '-File',
            "`"$PSCommandPath`""
        )

    exit
}

Write-Host ""
Write-Host "[SLEEP] Waiting 60 seconds..." `
    -ForegroundColor Yellow

Start-Sleep -Seconds 60

    }
    catch {

        Write-Host ""
        Write-Host "========================================="
        Write-Host "            RELAY LOOP ERROR"
        Write-Host "========================================="
        Write-Host ""

        Write-Host $_.Exception.Message `
            -ForegroundColor Red

        $_ | Format-List -Force

        Write-Host ""
        Write-Host "[RECOVERY] Restarting in 15 seconds..." `
            -ForegroundColor Yellow

        Start-Sleep -Seconds 15
    }
}

Write-Host ""