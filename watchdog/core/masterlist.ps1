function Update-MasterHeartbeat {
    param(
        [Parameter(Mandatory=$true)]
        $StatusData
    )

    if (-not $masterServerEnabled) {
        return
    }

# --- Ensure heartbeat folder exists ---
$heartbeatFolder = Split-Path $masterHeartbeatFile -Parent

if (-not (Test-Path $heartbeatFolder)) {

    New-Item `
        -ItemType Directory `
        -Path $heartbeatFolder `
        -Force | Out-Null
}

    $heartbeat = @()

    foreach ($server in $StatusData) {

        $ip = ""
        $port = ""

        if ($server.UdpIp -match "^([0-9\.]+):(\d+)$") {
            $ip = $Matches[1]
            $port = [int]$Matches[2]
        }
        else {
            $ip = $server.RconHost
            $port = $server.Port
        }

        if ([string]::IsNullOrWhiteSpace($ip)) {
            continue
        }

		$heartbeat += [PSCustomObject]@{
			serverId   = "$ip`:$port"

			node       = $watchdogNodeName

			name       = $server.Name
			region     = $server.Region
			modName    = if ($server.ModName) { $server.ModName } else { "Source Engine" }
			hostname   = $server.Hostname
			map        = $server.Map
			players    = $server.PlayersInfo

			status     = $server.Status

			ip         = $ip
			port       = $port

			claimServerKey = $ClaimServerKey

			updated    = $server.UpdatedAt
			updatedUtc = (Get-Date).ToUniversalTime().ToString("o")
		}
    }

    Save-JsonAtomicWithMemory `
        -Path $masterHeartbeatFile `
        -Data $heartbeat `
        -Depth 5 `
        -Label "MASTER HEARTBEAT"
}
function Send-MasterHeartbeat {

    if (-not $masterServerEnabled) {
        return
    }

    if (-not (Test-Path $masterHeartbeatFile)) {
        return
    }

    try {

        $json = Get-Content `
            -Path $masterHeartbeatFile `
            -Raw `
            -ErrorAction Stop

        if ([string]::IsNullOrWhiteSpace($json)) {
            return
        }

        Invoke-RestMethod `
            -Uri $masterServerUrl `
            -Method POST `
            -Headers @{
                "X-WATCHDOG-KEY" = $masterApiKey
            } `
            -ContentType "application/json" `
            -Body $json `
            -TimeoutSec 5 `
            -ErrorAction Stop | Out-Null

        Write-Log "MASTER HEARTBEAT SENT"

    }
    catch {

        Write-Log "MASTER HEARTBEAT FAILED: $($_.Exception.Message)"
    }
}