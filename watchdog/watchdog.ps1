# ================================== #
# Source Dedicated Watchdog by dr.N0 #
# ================================== #
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
Write-Host "      SOURCE DEDICATED WATCHDOG          " -ForegroundColor Red
Write-Host "      Brought to you by dr.N0            " -ForegroundColor Red
Write-Host "=========================================" -ForegroundColor DarkRed

trap {
    Write-Host "FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Blue
    Write-Host "Press ENTER to exit..."
    Read-Host
    exit
}
$ErrorActionPreference = "Continue"

# --- Resolve script root FIRST ---
$scriptRoot = if ($PSScriptRoot) { 
    $PSScriptRoot 
} else { 
    Split-Path -Parent $MyInvocation.MyCommand.Path 
}

$scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

# --- Data Config File ---
. (Join-Path $scriptRoot "core\data.ps1")

# --- Auth - Dashboard Configs ---
. (Join-Path $scriptRoot "config\auth.ps1")

# --- Server Definitions ---
. (Join-Path $scriptRoot "config\servers.ps1")
# --- Server Control - VGUI - WATCH DOG ---
. (Join-Path $scriptRoot "core\servers.ps1")

# --- RCON Console Injection ---
. (Join-Path $scriptRoot "core\rcon.ps1")

# --- Dashboard Console Injection ---
. (Join-Path $scriptRoot "core\dashboard.ps1")

Write-Host "WATCHDOG STARTING..." -ForegroundColor DarkRed
Write-Log "Loading core files..." gray

# --- CLEAR STALE RESTART FLAG ---
$staleRestartFlag = Join-Path $scriptRoot "logs\restart.flag"

if (Test-Path $staleRestartFlag) {

    Remove-Item $staleRestartFlag `
        -Force `
        -ErrorAction SilentlyContinue

    Write-Log "Removed stale restart flag during startup"
}

# --- RCON failure tracking (GLOBAL, persists during runtime) ---
if (-not $global:RconFailureState) {
    $global:RconFailureState = @{}
}

# --- A2S endpoint cache (GLOBAL, persists during runtime) ---
if (-not $global:A2SPortCache) {
    $global:A2SPortCache = @{}
}

# --- JSON memory buffer fallback ---
# Keeps last-known-good JSON in memory if Windows temporarily locks a file.
if (-not $script:JsonMemoryBuffer) {
    $script:JsonMemoryBuffer = @{}
}

# --- History / status / players ---
function Get-ServerBindIpFromArgs {
    param([string]$Args)

    if ([string]::IsNullOrWhiteSpace($Args)) {
        return $null
    }

    if ($Args -match '(?i)(?:^|\s)-ip\s+([0-9\.]+)(?:\s|$)') {
        return $Matches[1]
    }

    if ($Args -match '(?i)(?:^|\s)\+ip\s+([0-9\.]+)(?:\s|$)') {
        return $Matches[1]
    }

    return $null
}

function Get-ServerLaunchPortFromArgs {
    param([string]$Args)

    if ([string]::IsNullOrWhiteSpace($Args)) {
        return $null
    }

    if ($Args -match '(?i)(?:^|\s)-port\s+(\d+)(?:\s|$)') {
        return [int]$Matches[1]
    }

    if ($Args -match '(?i)(?:^|\s)\+port\s+(\d+)(?:\s|$)') {
        return [int]$Matches[1]
    }

    return $null
}

function Get-FallbackUdpIp {
    param($server)

    $ip = $null
    $port = $null

    $argIp = Get-ServerBindIpFromArgs -Args $server.Args
    if (-not [string]::IsNullOrWhiteSpace($argIp)) {
        $ip = $argIp
    }
    elseif (-not [string]::IsNullOrWhiteSpace($server.RconHost)) {
        $ip = $server.RconHost
    }

    $argPort = Get-ServerLaunchPortFromArgs -Args $server.Args
    if ($null -ne $argPort) {
        $port = $argPort
    }
    elseif ($server.Port) {
        $port = [int]$server.Port
    }
    elseif ($server.RconPort) {
        $port = [int]$server.RconPort
    }

    if (-not [string]::IsNullOrWhiteSpace($ip) -and $port) {
        return "$ip`:$port"
    }

    if (-not [string]::IsNullOrWhiteSpace($ip)) {
        return $ip
    }

    return ""
}

function Save-JsonAtomicWithMemory {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Data,
        [Parameter(Mandatory=$true)][int]$Depth,
        [Parameter(Mandatory=$true)][string]$Label
    )

    $tempFile = "$Path.tmp"

    try {
        # Clean any leftover temp file
        Remove-Item $tempFile -ErrorAction SilentlyContinue

        # Convert safely
        $json = $Data | ConvertTo-Json -Depth $Depth

        if ([string]::IsNullOrWhiteSpace($json)) {
            throw "$Label JSON was empty"
        }

        # Write to temp first
        [System.IO.File]::WriteAllText($tempFile, $json, [System.Text.Encoding]::UTF8)

        # Atomic replace
        Move-Item -Path $tempFile -Destination $Path -Force

        # Store memory backup
        $script:JsonMemoryBuffer[$Path] = $json
    }
    catch {
        Write-Log "$Label WRITE FAILED: $($_.Exception.Message)"

        # Attempt recovery from memory
        if ($script:JsonMemoryBuffer.ContainsKey($Path)) {
            try {
                [System.IO.File]::WriteAllText($tempFile, $script:JsonMemoryBuffer[$Path], [System.Text.Encoding]::UTF8)
                Move-Item -Path $tempFile -Destination $Path -Force

                Write-Log "$Label restored from memory buffer"
            }
            catch {
                Write-Log "$Label RECOVERY FAILED"
            }
        }
    }
}

function Resolve-DisplayUdpIp {
    param(
        $server,
        $parsedUdpIp
    )

    $fallback = Get-FallbackUdpIp -server $server

    if ([string]::IsNullOrWhiteSpace($parsedUdpIp)) {
        return $fallback
    }

    # Source sometimes reports hidden/unknown bind info as ?.?.?.?:?
    # Keep dashboard widgets useful by showing the configured public IP:port instead.
    if ($parsedUdpIp -match '\?') {
        if ($parsedUdpIp -match '(?i)public\s+IP\s+from\s+Steam\s*:\s*([0-9\.]+)') {
            $publicIp = $Matches[1]
            $port = Get-ServerLaunchPortFromArgs -Args $server.Args
            if ($null -eq $port -and $server.Port) { $port = [int]$server.Port }
            if ($port) { return "$publicIp`:$port" }
            return $publicIp
        }

        return $fallback
    }

    # Normalize "x.x.x.x:y (public IP from Steam: z.z.z.z)" to the configured public endpoint
    # when the reported bind endpoint is unusable or local-only.
    if ($parsedUdpIp -match '^(0\.0\.0\.0|127\.0\.0\.1|localhost)(?::\d+)?') {
        return $fallback
    }

    return $parsedUdpIp
}

# --- CACHE LAST GOOD RCON STATUS ---
if (-not $global:LastGoodRconData) {
    $global:LastGoodRconData = @{}
}

function Update-Status {
    $status = @()
	
	$globalScriptStart = $scriptStartTime.ToString("o")
	
    foreach ($server in $servers) {
        $proc = Get-ServerProcess -port $server.Port -exe $server.Exe

        $cpu = 0
        $ram = 0

        if ($proc) {
            try { $cpu = [math]::Round([double]$proc.CPU, 2) } catch {}
            try { $ram = [math]::Round([double]$proc.WorkingSet64 / 1MB, 2) } catch {}
        }

        $parsedStatus = @{
            Hostname    = ""
            Version     = ""
            UdpIp       = ""
            SteamId     = ""
            Map         = ""
            PlayersInfo = ""
            Edicts      = ""
        }

		$rconReachable = $false
		$rconError = ""
		$serverName = $server.Name

		# --- HARD SKIP: DO NOT TOUCH RCON IF FAILED ---
		if ($global:RconFailureState.ContainsKey($serverName) -and
			$global:RconFailureState[$serverName] -eq "FAILED") {

			$rconError = "Suppressed (RCON disabled after failure)"
			$rconReachable = $false

		}
		else {

			if ($proc -and 
			-not [string]::IsNullOrWhiteSpace($server.RconPassword) -and
			-not ($global:RconFailureState.ContainsKey($serverName) -and
				  $global:RconFailureState[$serverName] -eq "FAILED")) {

				try {
					$rawStatus = Invoke-SourceRcon `
						-rconHost $server.RconHost `
						-Port $server.RconPort `
						-Password $server.RconPassword `
						-Command "status"

					$parsedStatus = Parse-ServerStatus -text $rawStatus
					$rconReachable = $true

					# STORE LAST GOOD DATA
					$global:LastGoodRconData[$serverName] = $parsedStatus

					$global:RconFailureState[$serverName] = "SUCCESS"

				} catch {
					$rconError = $_.Exception.Message

					# USE LAST GOOD DATA IF AVAILABLE
					if ($global:LastGoodRconData.ContainsKey($serverName)) {
						$parsedStatus = $global:LastGoodRconData[$serverName]
					}

					if (-not $global:RconFailureState.ContainsKey($serverName) -or
						$global:RconFailureState[$serverName] -ne "FAILED") {

						Write-Log "RCON STATUS FAILED [$serverName] Host=$($server.RconHost) Port=$($server.RconPort) :: $rconError"

						$global:RconFailureState[$serverName] = "FAILED"
					}
				}
			}

		}
            $a2s = $null
			$a2sEndpoint = $null

			try {
				# Strict per-server A2S lookup.
				# Do NOT scan neighboring/common ports here, because multiple Source servers share the same IP.
				# Scanning nearby ports can attach fof -> dods, dods -> neo, nd -> anh, etc.

				$queryHost = $server.RconHost

				if ([string]::IsNullOrWhiteSpace($queryHost)) {
					$queryHost = Get-ServerBindIpFromArgs -Args $server.Args
				}

				if ([string]::IsNullOrWhiteSpace($queryHost)) {
					$queryHost = "127.0.0.1"
				}

				$queryPort = [int]$server.Port

				$a2s = Get-SourceA2SInfo -Host $queryHost -Port $queryPort

				if ($a2s -and $a2s.Reachable) {
					$a2sEndpoint = [PSCustomObject]@{
						Host   = $queryHost
						Port   = $queryPort
						Cached = $false
					}

					Write-Log "A2S OK [$($server.Name)] Host=$queryHost Port=$queryPort | $($a2s.Name) | $($a2s.Map) | Players=$($a2s.Players)/$($a2s.MaxPlayers)"
				}
				else {
					Write-Log "A2S FAIL [$($server.Name)] Host=$queryHost Port=$queryPort"
				}
			}
			catch {
				Write-Log "A2S ERROR [$($server.Name)] $($_.Exception.Message)"
			}
		$fallbackUdpIp = Get-FallbackUdpIp -server $server

		# --- COMPUTE RCON DISPLAY STATUS (SAFE OUTSIDE OBJECT) ---
		$displayRconStatus = $null
		$displayRconTime = $null

		if ($rconStatus.ContainsKey($server.Name)) {

			$currentStatus = $rconStatus[$server.Name].Status

			if ($currentStatus -eq "RETRYING") {
				$displayRconStatus = "RETRYING"
			}
			elseif ($rconReachable) {
				$displayRconStatus = "OK"
			}
			elseif (-not [string]::IsNullOrWhiteSpace($rconError)) {
				$displayRconStatus = "FAILED"
			}
			else {
				$displayRconStatus = $currentStatus
			}

			$displayRconTime = $rconStatus[$server.Name].Time
		}
		else {
			if ($rconReachable) {
				$displayRconStatus = "OK"
			}
			elseif (-not [string]::IsNullOrWhiteSpace($rconError)) {
				$displayRconStatus = "FAILED"
			}
		}

        $status += [PSCustomObject]@{
            Name         = $server.Name
            Port         = $server.Port
            Exe          = $server.Exe
			RconHost 	 = $server.RconHost
            A2SHost      = if ($a2sEndpoint) { $a2sEndpoint.Host } else { $null }
            A2SPort      = if ($a2sEndpoint) { $a2sEndpoint.Port } else { $null }
            A2SCached    = if ($a2sEndpoint) { [bool]$a2sEndpoint.Cached } else { $false }
			UseVgui      = Get-ServerUseVgui -server $server
            LockOut      = Get-ServerLockOut -server $server
			OriginalArgs = $server.Args
			LaunchArgs   = Get-EffectiveServerArgs -server $server
			ScriptStartTime = $globalScriptStart
            Status       = if ($proc) { "ONLINE" } else { "OFFLINE" }

            # --- SIMPLE UPDATE HEURISTIC ---
            NeedsUpdate  = if ($proc) {
                try {
                    $uptime = (Get-Date) - $proc.StartTime
                    ($uptime.TotalHours -gt 24)
                } catch { $false }
            } else { $false }

            PID          = if ($proc) { $proc.Id } else { $null }

			Hostname = if (-not [string]::IsNullOrWhiteSpace($parsedStatus.Hostname)) {
				$parsedStatus.Hostname
			} elseif ($a2s -and $a2s.Reachable) {
				$a2s.Name
			} else {
				""
			}
            UdpIp        = Resolve-DisplayUdpIp -server $server -parsedUdpIp $parsedStatus.UdpIp
            SteamId      = $parsedStatus.SteamId
			Map = if (-not [string]::IsNullOrWhiteSpace($parsedStatus.Map)) {
			$parsedStatus.Map
			} elseif ($a2s -and $a2s.Reachable) {
				$a2s.Map
			} else {
				""
			}
			PlayersInfo = if (-not [string]::IsNullOrWhiteSpace($parsedStatus.PlayersInfo)) {
				$parsedStatus.PlayersInfo
			} elseif ($a2s -and $a2s.Reachable) {
				"$($a2s.Players) humans, $($a2s.Bots) bots ($($a2s.MaxPlayers) max)"
			} else {
				""
			}
            Edicts       = $parsedStatus.Edicts
            Version      = $parsedStatus.Version
			RconReachable = $rconReachable
			RconError     = $rconError
			RconStatus = $displayRconStatus
			RconTime   = $displayRconTime
			
            CPU          = $cpu
            WorkingSetMB = $ram
            LastRestart  = if ($lastRestart[$server.Name]) { $lastRestart[$server.Name].ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
            DownSince    = if ($downSince[$server.Name]) { $downSince[$server.Name].ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
            UpdatedAt    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }

Save-JsonAtomicWithMemory `
    -Path $statusFile `
    -Data $status `
    -Depth 5 `
    -Label "STATUS"
}

function Update-History {
    $existing = @()

if (Test-Path $historyFile) {
    try {
        $raw = Get-Content -Path $historyFile -Raw -ErrorAction Stop

        if (-not [string]::IsNullOrWhiteSpace($raw)) {
            try {
                $existing = $raw | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $existing = @()
            }
        }
    } catch {
        $existing = @()
    }
}

    $historyMap = @{}
 foreach ($item in @($existing)) {
    if ($null -ne $item -and $item.PSObject.Properties["Name"]) {
        $historyMap[$item.Name] = @($item.Samples)
    }
}

    foreach ($server in $servers) {
        $proc = Get-ServerProcess -port $server.Port -exe $server.Exe
        if ($historyMap.ContainsKey($server.Name)) {
    $samples = $historyMap[$server.Name]

    if ($samples -isnot [System.Collections.IEnumerable]) {
        $samples = @($samples)
    } else {
        $samples = @($samples)
    }
} else {
    $samples = @()
}

        $cpu = 0
        $ram = 0

        if ($proc) {
            try { $cpu = [math]::Round([double]$proc.CPU, 2) } catch {}
            try { $ram = [math]::Round([double]$proc.WorkingSet64 / 1MB, 2) } catch {}
        }

        $samples = @($samples) + @([PSCustomObject]@{
            Time = (Get-Date).ToString("HH:mm:ss")
            Cpu  = $cpu
            Ram  = $ram   #IMPORTANT (NOT WorkingSetMB)
        })

        if ($samples.Count -gt 120) {
            $samples = $samples[-120..-1]
        }

        $historyMap[$server.Name] = $samples
    }

    $out = @()
    foreach ($server in $servers) {
        $out += [PSCustomObject]@{
            Name    = $server.Name
            Port    = $server.Port
            Samples = $historyMap[$server.Name]
        }
    }

Save-JsonAtomicWithMemory `
    -Path $historyFile `
    -Data $out `
    -Depth 8 `
    -Label "HISTORY"
}

function Update-Players {
    $allPlayers = @()
    foreach ($server in $servers) {
        $allPlayers += Get-ServerPlayers -server $server
    }

Save-JsonAtomicWithMemory `
    -Path $playersFile `
    -Data $allPlayers `
    -Depth 8 `
    -Label "PLAYERS"
}

# --- Commands from dashboard ---
function Process-CommandQueue {
    if (-not (Test-Path $commandQueueFile)) {
        return
    }

    $lines = Get-Content -Path $commandQueueFile -ErrorAction SilentlyContinue
    if (-not $lines -or $lines.Count -eq 0) {
        return
    }

    "" | Set-Content -Path $commandQueueFile -Encoding UTF8

    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }

        try {
            $cmdObj = $line | ConvertFrom-Json

            foreach ($cmd in @($cmdObj)) {
                $server = $servers | Where-Object { $_.Name -eq $cmd.server } | Select-Object -First 1
                if (-not $server) { continue }

                switch ($cmd.action) {
                    "start" {
                        if (-not (Get-ServerProcess -port $server.Port -exe $server.Exe)) {
                            Start-ServerInstance -server $server
                            $lastRestart[$server.Name] = Get-Date
                        }
                    }
                    "stop" {
                        Stop-ServerInstance -server $server
                    }
                    "restart" {
                        Restart-ServerInstance -server $server
                    }
					"setVgui" {
						$useVgui = $false
						if ($null -ne $cmd.useVgui) {
						$useVgui = [bool]$cmd.useVgui
					}

						Set-ServerUseVgui -ServerName $server.Name -UseVgui $useVgui
						Write-Log "Set VGUI [$($server.Name)] => $useVgui"
						Update-Status
					}
                    "setLockOut" {
                        $lockOut = $false
                        if ($null -ne $cmd.lockOut) {
                            $lockOut = [bool]$cmd.lockOut
                        }

                        Set-ServerLockOut -ServerName $server.Name -LockOut $lockOut
                        Write-Log "Set LOCK OUT [$($server.Name)] => $lockOut"
                        Update-Status
                    }
					"retryRcon" {
					if ($global:RconFailureState.ContainsKey($server.Name)) {
						$global:RconFailureState.Remove($server.Name)
					}

                    Clear-A2SPortCache -server $server

                    Write-Log "RCON RETRY REQUESTED [$($server.Name)] - A2S cache cleared"

                    # Optional: reflect instantly in dashboard
                    $rconStatus[$server.Name] = @{
                        Status = "RETRYING"
                        Time   = (Get-Date).ToString("HH:mm:ss")
                    }
				}
"rcon" {
    if (-not [string]::IsNullOrWhiteSpace($cmd.command)) {
        try {
            $result = Invoke-SourceRcon `
                -rconHost $server.RconHost `
                -Port $server.RconPort `
                -Password $server.RconPassword `
                -Command $cmd.command

            Write-Log "RCON [$($server.Name)] $($cmd.command) => $result"

            # SUCCESS heuristic (Source returns text if valid)
            if (-not [string]::IsNullOrWhiteSpace($result)) {
                $rconStatus[$server.Name] = @{
                    Status = "SUCCESS"
                    Time   = (Get-Date).ToString("HH:mm:ss")
                }
            } else {
                $rconStatus[$server.Name] = @{
                    Status = "SENT"
                    Time   = (Get-Date).ToString("HH:mm:ss")
                }
            }

        } catch {
            $rconStatus[$server.Name] = @{
                Status = "FAILED"
                Time   = (Get-Date).ToString("HH:mm:ss")
            }

            Write-Log "RCON ERROR [$($server.Name)] $($_.Exception.Message)"
        }
    }
}
                }
            }

        } catch {
            Write-Log "Command queue error: $($_.Exception.Message)"
        }
    }
}

        function Test-DashboardHealth {
    param(
        [int]$TimeoutSeconds = 2
    )

    try {
        $uri = "http://127.0.0.1:$dashboardPort/api/ping?ts=$([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())"
        $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec $TimeoutSeconds -ErrorAction Stop
        return ($response.StatusCode -eq 200 -and $response.Content -match '"ok"\s*:\s*true')
    } catch {
        return $false
    }
}

function Ensure-DashboardHealthy {
    $jobName = "SourceDedicatedWatchdogDashboard"

    try {
        $dashJob = Get-Job -Name $jobName -ErrorAction SilentlyContinue
        $jobHealthy = ($dashJob -and $dashJob.State -eq "Running")
        $httpHealthy = $false

        if ($jobHealthy) {
            $httpHealthy = Test-DashboardHealth
        }

        if ($jobHealthy -and $httpHealthy) {
            return
        }

        $reason = @()
        if (-not $dashJob) {
            $reason += "job missing"
        } elseif ($dashJob.State -ne "Running") {
            $reason += "job state=$($dashJob.State)"
        }

        if (-not $httpHealthy) {
            $reason += "HTTP probe failed"
        }

        Write-Log ("Dashboard unhealthy -> " + ($reason -join ", ") + ". Restarting dashboard listener.")

        if ($dashJob) {
            try {
                $dashDetails = Receive-Job -Name $jobName -Keep -ErrorAction SilentlyContinue | Out-String
                if (-not [string]::IsNullOrWhiteSpace($dashDetails)) {
                    Write-Log "Dashboard job output: $dashDetails"
                }
            } catch {}

            try { Stop-Job -Name $jobName -ErrorAction SilentlyContinue } catch {}
            try { Remove-Job -Name $jobName -Force -ErrorAction SilentlyContinue } catch {}
        }

        Start-Sleep -Milliseconds 500
        Start-Dashboard
    } catch {
        Write-Log "Dashboard self-heal error: $($_.Exception.Message)"
    }
}

# ================================
# START
# ================================
Write-Log "WATCHDOG STARTED" Red
Write-Log "Checking data files..." gray
Ensure-DataFiles
Write-Log "Loading launch preferences..." gray
Initialize-LaunchPrefs
Write-Log "Scanning configured servers..." gray
Update-Status
Write-Log "Building history cache..." gray
Update-History
Write-Log "Scanning player lists..." gray
Update-Players
Write-Log "Creating dashboard redirect file..." gray
Ensure-DashboardRedirectFile
Write-Log "Starting dashboard web server on port $dashboardPort..." gray
Start-Dashboard
Write-Log "Validating dashboard health..." gray
Ensure-DashboardHealthy
Write-Log "Dashboard startup phase complete." Red
Write-Log "Startup validation phase..." white

foreach ($s in $servers) {

    # First check
    $proc = Get-ServerProcess -port $s.Port -exe $s.Exe

    if (-not $proc) {

        # Wait a moment (WMI delay fix)
        Start-Sleep -Seconds 3

        # Second check
        $proc = Get-ServerProcess -port $s.Port -exe $s.Exe
    }

    if (-not $proc) {
        Write-Log "Starting $($s.Name) (confirmed not running)"
        Start-ServerInstance -server $s
    } else {
        Write-Log "$($s.Name) already running (PID $($proc.Id))"
    }
}

# ================================
# LOOP
# ================================
$lastHeavyCycle = Get-Date
$lastDashboardHealthCheck = [DateTime]::MinValue

while ($true) {
	Write-Log "MAIN LOOP HEARTBEAT PID=$PID"
	$restartFlag = Join-Path $scriptRoot "logs\restart.flag"

if (Test-Path $restartFlag) {

    Write-Log "FLAG EXISTS IN MAIN LOOP"

}
	# =========================================
	# WATCHDOG SELF-RESTART
	# =========================================

	try {

$restartFlag = Join-Path $scriptRoot "logs\restart.flag"

if (Test-Path $restartFlag) {

    Write-Log "WATCHDOG RESTART FLAG DETECTED"

    Remove-Item $restartFlag -Force -ErrorAction SilentlyContinue

    $watchdogPs1 = Join-Path $scriptRoot "watchdog.ps1"
    $watchdogExe = Join-Path $scriptRoot "watchdog.exe"

    Write-Log "STARTING DETACHED WATCHDOG"

    if (Test-Path $watchdogExe) {

        Start-Process `
            -FilePath $watchdogExe `
            -WorkingDirectory $scriptRoot `
            -WindowStyle Normal

    }
    else {

        Start-Process powershell.exe `
            -ArgumentList @(
                '-ExecutionPolicy','Bypass',
                '-NoProfile',
                '-File',"`"$watchdogPs1`""
            ) `
            -WorkingDirectory $scriptRoot `
            -WindowStyle Normal
    }

    Write-Log "EXITING CURRENT WATCHDOG"

    Start-Sleep -Seconds 2

    [Environment]::Exit(0)
}

	} catch {

		Write-Log "WATCHDOG RESTART FAILURE: $($_.Exception.Message)"

	}
    try {
        # --- FAST LANE: process dashboard commands quickly ---
        Process-CommandQueue

        # --- DASHBOARD HEALTH LANE: keep listener alive ---
        if (((Get-Date) - $lastDashboardHealthCheck).TotalSeconds -ge 15) {
            Ensure-DashboardHealthy
            $lastDashboardHealthCheck = Get-Date
        }

        # --- HEAVY LANE: keep original watchdog/status cadence at 30 seconds ---
        if (((Get-Date) - $lastHeavyCycle).TotalSeconds -ge 30) {

            foreach ($s in $servers) {
                $p = Get-ServerProcess -port $s.Port -exe $s.Exe
                $lockOutEnabled = Get-ServerLockOut -server $s

                if (-not $p) {
                    if (-not $downSince[$s.Name]) {
                        $downSince[$s.Name] = Get-Date
                        Write-Log "$($s.Name) detected DOWN"
                    }

                    if ($lockOutEnabled) {
                        if (-not $rconStatus.ContainsKey("$($s.Name)_LockOutLogged")) {
                            Write-Log "$($s.Name) restart suppressed (LOCK OUT enabled)"
                            $rconStatus["$($s.Name)_LockOutLogged"] = @{
                                Status = "logged"
                                Time = (Get-Date)
                            }
                        }
                        continue
                    } else {
                        $rconStatus.Remove("$($s.Name)_LockOutLogged")
                    }

                    if (((Get-Date) - $downSince[$s.Name]).TotalSeconds -ge 60) {
                        Write-Log "Restarting $($s.Name)"
                        Start-ServerInstance -server $s
                        $lastRestart[$s.Name] = Get-Date
                        $downSince.Remove($s.Name)
                    }
                } else {
                    $downSince.Remove($s.Name)
                    $rconStatus.Remove("$($s.Name)_LockOutLogged")
                }
            }

			# ===============================
			# PERIODIC RCON REFRESH (ANTI-DEGRADATION)
			# ===============================

			if (-not $global:RconRefreshTimer) {
				$global:RconRefreshTimer = @{}
			}

			$now = Get-Date

			foreach ($s in $servers) {

				if (-not $global:RconRefreshTimer.ContainsKey($s.Name)) {
					$global:RconRefreshTimer[$s.Name] = $now
					continue
				}

				$elapsed = ($now - $global:RconRefreshTimer[$s.Name]).TotalMinutes

				if ($elapsed -gt 60) {

					Write-Log "RCON PERIODIC REFRESH [$($s.Name)]"

					if ($global:RconFailureState.ContainsKey($s.Name)) {
						$global:RconFailureState.Remove($s.Name)
					}

					$global:RconRefreshTimer[$s.Name] = $now
				}
			}

            Update-Status
            Update-History
            Update-Players

            $lastHeavyCycle = Get-Date
        }
    } catch {
        Write-Log "Main loop error: $($_.Exception.Message)"
    }

    Start-Sleep -Milliseconds 250
}