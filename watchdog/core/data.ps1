# ================================
# DATA + LOGGING LAYER
# ================================

# --- Determine writable data directory ---
# --- Prefer local logs folder ---
$dataRoot = Join-Path $scriptRoot "logs"

# Ensure logs folder exists (create early)
try {
    if (-not (Test-Path $dataRoot)) {
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    }
} catch {
    # fallback if creation fails
    $dataRoot = "C:\ProgramData\Watchdog"
	if (-not (Test-Path $dataRoot)) {
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
	}
}

$testFile = Join-Path $dataRoot "__test.tmp"

try {
    "test" | Set-Content -Path $testFile -ErrorAction Stop
    Remove-Item $testFile -Force -ErrorAction SilentlyContinue
}
catch {
    $dataRoot = "C:\ProgramData\Watchdog"
}

# --- Ensure directory exists ---
if (-not (Test-Path $dataRoot)) {
    try {
        New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    } catch {
        Write-Host "FATAL: Cannot create data directory: $dataRoot" -ForegroundColor Red
        exit
    }
}

# --- Data files ---
$script:logFile = Join-Path $dataRoot "watchdog_log.txt"
$script:statusFile = Join-Path $dataRoot "status.json"
$script:historyFile = Join-Path $dataRoot "history.json"
$script:playersFile = Join-Path $dataRoot "players.json"
$script:usersListFile = Join-Path $dataRoot "userslist.txt"
$script:usersDatabaseFile = Join-Path $dataRoot "usersdatabase.json"
$script:commandQueueFile = Join-Path $dataRoot "dashboard_commands.jsonl"
$script:launchPrefsFile = Join-Path $dataRoot "launch_prefs.json"

# --- Runtime state ---
$script:launchPrefs = @{}
$script:lastRestart = @{}
$script:downSince = @{}
$script:rconStatus = @{}
# --- ACTIVE PLAYER SESSION TRACKING ---
# Runtime-only tracking for true joins/leaves.
# Prevents TotalJoins inflation during watchdog refresh loops.
$script:activePlayerSessions = @{}

$script:scriptStartTime = Get-Date

# --- Logging ---
function Write-Log {
	param(
		[string]$Message,
		[string]$Color = "Gray",
		[switch]$NoConsole
	)

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp - $Message"
	# --- GLOBAL CONSOLE SUPPRESSION ---
	if ($NoConsole) {
		Add-Content -Path $logFile -Value $line
		return
	}
    # ALWAYS write to file (no change)
    Add-Content -Path $logFile -Value $line

	# ===============================
	# LOG FILE SIZE LIMITER
	# ===============================

	if (-not $global:LastLogTrim -or ((Get-Date) - $global:LastLogTrim).TotalSeconds -gt 43200) {

    $global:LastLogTrim = Get-Date

    $maxLines = 5000

    try {
        $lines = Get-Content -Path $logFile -ErrorAction Stop
        if ($lines.Count -gt $maxLines) {
            $lines = $lines[-$maxLines..-1]
            Set-Content -Path $logFile -Value $lines -Encoding UTF8
        }
    } catch {}
}
	
    # ===============================
    # SMART CONSOLE FILTERING
    # ===============================

    if (-not $global:ConsoleState) {
        $global:ConsoleState = @{}
    }

    $isFailure = $Message -match "FAILED|ERROR|DOWN"
    $isStartup = $Message -match "WATCHDOG STARTED|Loading core files|STARTING|startup"
    $isDiscovery = $Message -match "DISCOVERED|LOCKED"
    $isCacheSpam = $Message -match "A2S CACHE"

    # ALWAYS show failures
    if ($isFailure) {
        Write-Host $line -ForegroundColor Red
        return
    }

    # ALWAYS show startup phase
    if ($isStartup) {
        Write-Host $line -ForegroundColor $Color
        return
    }

    # Show discovery ONCE per server
    if ($isDiscovery) {
        if (-not $global:ConsoleState.ContainsKey($Message)) {
            $global:ConsoleState[$Message] = $true
            Write-Host $line -ForegroundColor White
        }
        return
    }

    # SUPPRESS repetitive cache spam
    if ($isCacheSpam) {
        return
    }

    # OPTIONAL: suppress everything else unless first time
    if (-not $global:ConsoleState.ContainsKey($Message)) {
        $global:ConsoleState[$Message] = $true
        Write-Host $line -ForegroundColor $Color
    }
}

# --- File initialization ---
function Ensure-DataFiles {
    foreach ($file in @($statusFile, $historyFile, $playersFile, $launchPrefsFile)) {
        if (-not (Test-Path $file)) {
            "[]" | Set-Content -Path $file -Encoding UTF8
        }
    }

    if (-not (Test-Path $usersListFile)) {
        "" | Set-Content -Path $usersListFile -Encoding UTF8
    }

	if (-not (Test-Path $usersDatabaseFile)) {
		"[]" | Set-Content -Path $usersDatabaseFile -Encoding UTF8
	}

    if (-not (Test-Path $commandQueueFile)) {
        "" | Set-Content -Path $commandQueueFile -Encoding UTF8
    }
}

function Get-SafeUsersListValue {
    param($Value)

    if ($null -eq $Value) {
        return ""
    }

    return ([string]$Value).Trim()
}

function Get-UsersListPlayerName {
    param($Player)

    foreach ($prop in @("Name", "name", "Username", "username", "PlayerName", "playername", "UserName", "userName")) {
        if ($null -ne $Player.PSObject.Properties[$prop]) {
            $value = Get-SafeUsersListValue $Player.$prop
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return ""
}

function Get-UsersListSteamId {
    param($Player)

    foreach ($prop in @("SteamID", "SteamId", "steamid", "uniqueid", "UniqueId", "UniqueID", "SteamID64", "SteamId64", "CommunityID", "CommunityId")) {
        if ($null -ne $Player.PSObject.Properties[$prop]) {
            $value = Get-SafeUsersListValue $Player.$prop
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return ""
}

function Expand-UsersListPlayers {
    param(
        [array]$Items
    )

    $flatPlayers = @()

    foreach ($item in $Items) {

        if ($null -eq $item) {
            continue
        }

        if ($item.PSObject.Properties["Players"] -and $item.Players) {
            foreach ($nestedPlayer in $item.Players) {
                $flatPlayers += $nestedPlayer
            }
        }
        else {
            $flatPlayers += $item
        }
    }

    return $flatPlayers
}

function Get-UsersListIpAddress {
    param($Player)

    foreach ($prop in @("Address", "Adr", "adr", "IP", "Ip", "ip")) {

        if ($null -ne $Player.PSObject.Properties[$prop]) {

            $value = Get-SafeUsersListValue $Player.$prop

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return ""
}

function Get-UsersListServerName {
    param($Player)

    foreach ($prop in @("Server", "server")) {

        if ($null -ne $Player.PSObject.Properties[$prop]) {

            $value = Get-SafeUsersListValue $Player.$prop

            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $value
            }
        }
    }

    return ""
}

function Format-SessionDuration {
    param(
        [datetime]$StartTime
    )

    if ($null -eq $StartTime) {
        return ""
    }

    $duration = (Get-Date) - $StartTime

    $days = [int]$duration.TotalDays
    $hours = $duration.Hours
    $minutes = $duration.Minutes
    $seconds = $duration.Seconds

    if ($days -gt 0) {
        return "{0}d {1}h {2}m {3}s" -f $days, $hours, $minutes, $seconds
    }

    if ($hours -gt 0) {
        return "{0}h {1}m {2}s" -f $hours, $minutes, $seconds
    }

    if ($minutes -gt 0) {
        return "{0}m {1}s" -f $minutes, $seconds
    }

    return "{0}s" -f $seconds
}

function Format-PlaytimeDuration {
    param(
        [int64]$TotalSeconds
    )

    if ($TotalSeconds -le 0) {
        return "0s"
    }

    $ts = [TimeSpan]::FromSeconds($TotalSeconds)

    if ($ts.TotalDays -ge 1) {
        return "{0}d {1}h {2}m {3}s" -f `
            [int]$ts.TotalDays,
            $ts.Hours,
            $ts.Minutes,
            $ts.Seconds
    }

    if ($ts.TotalHours -ge 1) {
        return "{0}h {1}m {2}s" -f `
            $ts.Hours,
            $ts.Minutes,
            $ts.Seconds
    }

    if ($ts.TotalMinutes -ge 1) {
        return "{0}m {1}s" -f `
            $ts.Minutes,
            $ts.Seconds
    }

    return "{0}s" -f $ts.Seconds
}

function Update-UsersList {
    param(
        [array]$Players
    )

    if ($null -eq $Players) {
        return
    }

	# --- BUILD CURRENT SESSION SNAPSHOT ---
	$currentSessions = @{}

	foreach ($wrapper in @($Players)) {

		$serverLabel = ""

		if ($wrapper.PSObject.Properties["Server"]) {
			$serverLabel = [string]$wrapper.Server
		}

		foreach ($player in (Expand-UsersListPlayers -Items @($wrapper))) {

			$playerName = Get-UsersListPlayerName -Player $player
			$steamId = Get-UsersListSteamId -Player $player

			$sessionKey = ""

			if (-not [string]::IsNullOrWhiteSpace($steamId)) {
				$sessionKey = "$serverLabel|$steamId"
			}
			elseif (-not [string]::IsNullOrWhiteSpace($playerName)) {
				$sessionKey = "$serverLabel|NAME:$playerName"
			}

			if (-not [string]::IsNullOrWhiteSpace($sessionKey)) {
				$currentSessions[$sessionKey] = $true
			}
		}
	}

	# --- CLEANUP DISCONNECTED SESSIONS ---
	foreach ($existingKey in @($script:activePlayerSessions.Keys)) {

		if (-not $currentSessions.ContainsKey($existingKey)) {

			$session = $script:activePlayerSessions[$existingKey]

			if (
				$session.ContainsKey("FirstSeen") -and
				$session.ContainsKey("SteamID")
			) {

				$sessionSeconds = [int64](
					((Get-Date) - $session.FirstSeen).TotalSeconds
				)

				$steamId = [string]$session.SteamID

				if (-not [string]::IsNullOrWhiteSpace($steamId)) {

					try {

						$rawDb = Get-Content `
							-Path $usersDatabaseFile `
							-Raw `
							-ErrorAction SilentlyContinue

						if (-not [string]::IsNullOrWhiteSpace($rawDb)) {

							$parsedRaw = $rawDb | ConvertFrom-Json

						$dbParsed = New-Object System.Collections.ArrayList

						foreach ($entry in @($parsedRaw)) {
							[void]$dbParsed.Add($entry)
						}

						foreach ($dbRecord in $dbParsed) {

							if ($dbRecord.SteamID -eq $steamId) {

								# --- SAFE FIELD INITIALIZATION ---

								if (-not ($dbRecord.PSObject.Properties.Name -contains "TotalPlaytimeSeconds")) {

									$dbRecord | Add-Member `
										-NotePropertyName "TotalPlaytimeSeconds" `
										-NotePropertyValue ([int64]0)
								}

								if (-not ($dbRecord.PSObject.Properties.Name -contains "LongestSessionSeconds")) {

									$dbRecord | Add-Member `
										-NotePropertyName "LongestSessionSeconds" `
										-NotePropertyValue ([int64]0)
								}

								# --- FORCE SAFE INTEGER TYPES ---

								$currentPlaytime = 0

								try {
									$currentPlaytime = [int64]($dbRecord.TotalPlaytimeSeconds | Select-Object -First 1)
								} catch {}

								$currentLongest = 0

								try {
									$currentLongest = [int64]($dbRecord.LongestSessionSeconds | Select-Object -First 1)
								} catch {}

								# --- UPDATE TOTAL PLAYTIME ---

								$dbRecord.TotalPlaytimeSeconds =
									[int64]($currentPlaytime + $sessionSeconds)

								# --- UPDATE LONGEST SESSION ---

								if ($sessionSeconds -gt $currentLongest) {

									$dbRecord.LongestSessionSeconds =
										[int64]$sessionSeconds
								}

								break
							}
						}

							Save-JsonAtomicWithMemory `
								-Path $usersDatabaseFile `
								-Data $dbParsed `
								-Depth 10 `
								-Label "USERS DATABASE"
						}

					} catch {

						Write-Log "SESSION PLAYTIME SAVE FAILED: $($_.Exception.Message)"
					}
				}
			}

			$script:activePlayerSessions.Remove($existingKey)
		}
	}

    $database = @()

    if (Test-Path $usersDatabaseFile) {

        try {

            $raw = Get-Content `
                -Path $usersDatabaseFile `
                -Raw `
                -ErrorAction SilentlyContinue

            if (-not [string]::IsNullOrWhiteSpace($raw)) {

                $database = New-Object System.Collections.ArrayList

				$parsed = $raw | ConvertFrom-Json

				foreach ($entry in @($parsed)) {
					[void]$database.Add($entry)
				}

            }

        } catch {

            Write-Log "USER DATABASE READ FAILED: $($_.Exception.Message)"

            $database = @()
        }
    }

    foreach ($wrapper in @($Players)) {

    $serverLabel = ""

    if ($wrapper.PSObject.Properties["Server"]) {
        $serverLabel = [string]$wrapper.Server
    }

    foreach ($player in (Expand-UsersListPlayers -Items @($wrapper))) {

        $playerName = Get-UsersListPlayerName -Player $player
        $steamId = Get-UsersListSteamId -Player $player
        $ipAddress = Get-UsersListIpAddress -Player $player
        $serverName = $serverLabel

		# --- STABLE SESSION KEY ---
		# Prefer SteamID.
		# Fallback to username only if SteamID unavailable.
		$sessionKey = ""

		if (-not [string]::IsNullOrWhiteSpace($steamId)) {
			$sessionKey = "$serverName|$steamId"
		}
		elseif (-not [string]::IsNullOrWhiteSpace($playerName)) {
			$sessionKey = "$serverName|NAME:$playerName"
		}

        if ([string]::IsNullOrWhiteSpace($playerName) -and
            [string]::IsNullOrWhiteSpace($steamId)) {
            continue
        }

		if (
			$steamId -eq "BOT" -or
			$playerName -match '^BOT\s' -or
			$playerName -match '^Player_\d+$'
		) {
			continue
		}

        $record = $null

        if (-not [string]::IsNullOrWhiteSpace($steamId)) {

            $record = $database | Where-Object {
                $_.SteamID -eq $steamId
            } | Select-Object -First 1
        }

        if ($null -eq $record -and
            -not [string]::IsNullOrWhiteSpace($playerName)) {

            $record = $database | Where-Object {
                $_.Usernames -contains $playerName
            } | Select-Object -First 1
        }

        $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

        if ($null -eq $record) {

            $record = [PSCustomObject]@{
                SteamID         = $steamId
                Usernames       = @()
                FirstSeen       = $now
                LastSeen        = $now
                LastServer      = $serverName
                TotalJoins      = 0
                IpHistory       = @()
            }

            [void]$database.Add($record)
        }

        if ([string]::IsNullOrWhiteSpace($record.SteamID) -and
            -not [string]::IsNullOrWhiteSpace($steamId)) {

            $record.SteamID = $steamId
        }

		if (-not ($record.PSObject.Properties.Name -contains "Usernames")) {
			$record | Add-Member -NotePropertyName "Usernames" -NotePropertyValue @()
		}

		if (-not ($record.PSObject.Properties.Name -contains "FirstSeen")) {
			$record | Add-Member -NotePropertyName "FirstSeen" -NotePropertyValue $now
		}

		if (-not ($record.PSObject.Properties.Name -contains "LastSeen")) {
			$record | Add-Member -NotePropertyName "LastSeen" -NotePropertyValue $now
		}

		if (-not ($record.PSObject.Properties.Name -contains "LastServer")) {
			$record | Add-Member -NotePropertyName "LastServer" -NotePropertyValue ""
		}

		if (-not ($record.PSObject.Properties.Name -contains "TotalJoins")) {
			$record | Add-Member -NotePropertyName "TotalJoins" -NotePropertyValue 0
		}

		if (-not ($record.PSObject.Properties.Name -contains "IpHistory")) {
			$record | Add-Member -NotePropertyName "IpHistory" -NotePropertyValue @()
		}
		
		if (-not ($record.PSObject.Properties.Name -contains "TotalPlaytimeSeconds")) {
			$record | Add-Member -NotePropertyName "TotalPlaytimeSeconds" -NotePropertyValue 0
		}

		if (-not ($record.PSObject.Properties.Name -contains "LongestSessionSeconds")) {
			$record | Add-Member -NotePropertyName "LongestSessionSeconds" -NotePropertyValue 0
		}
		
        if (-not [string]::IsNullOrWhiteSpace($playerName) -and
            $record.Usernames -notcontains $playerName) {

            $record.Usernames = @($record.Usernames + $playerName)
        }

		if (-not [string]::IsNullOrWhiteSpace($ipAddress) -and
			$record.IpHistory -notcontains $ipAddress) {

			$record.IpHistory = @($record.IpHistory + $ipAddress)

			# --- KEEP ONLY LAST 10 IPS ---
			if ($record.IpHistory.Count -gt 10) {

				$record.IpHistory =
					@(
						$record.IpHistory |
						Select-Object -Last 10
					)
			}
		}

		$record.LastSeen = $now
		$record.LastServer = $serverName

		# --- TRUE SESSION JOIN TRACKING ---
		if (
			-not [string]::IsNullOrWhiteSpace($sessionKey) -and
			-not $script:activePlayerSessions.ContainsKey($sessionKey)
		) {
			$script:activePlayerSessions[$sessionKey] = @{
				FirstSeen = Get-Date
				SteamID   = $steamId
			}

			$record.TotalJoins = [int]$record.TotalJoins + 1
		}
    }
}

    Save-JsonAtomicWithMemory `
        -Path $usersDatabaseFile `
        -Data $database `
        -Depth 10 `
        -Label "USERS DATABASE"

    $output = @()

    $row = 1

    foreach ($record in $database) {

        $usernames = @($record.Usernames) -join ", "
        $ips = @($record.IpHistory) -join ", "

		$totalPlaytime = Format-PlaytimeDuration `
			-TotalSeconds ([int64]$record.TotalPlaytimeSeconds)

		$longestSession = Format-PlaytimeDuration `
			-TotalSeconds ([int64]$record.LongestSessionSeconds)

		$currentSessionDuration = ""

		foreach ($sessionKey in $script:activePlayerSessions.Keys) {

			if ($sessionKey -match [regex]::Escape($record.SteamID)) {

				$session = $script:activePlayerSessions[$sessionKey]

				if ($session.ContainsKey("FirstSeen")) {

					$currentSessionDuration = Format-SessionDuration `
						-StartTime $session.FirstSeen

					break
				}
			}
		}

        $output += (
            "$row | " +
            "SteamID: $($record.SteamID) | " +
            "Usernames: $usernames | " +
            "First Seen: $($record.FirstSeen) | " +
            "Last Seen: $($record.LastSeen) | " +
            "Last Server: $($record.LastServer) | " +
			"Current Session: $currentSessionDuration | " +
			"Longest Session: $longestSession | " +
			"Total Playtime: $totalPlaytime | " +
            "Total Joins: $($record.TotalJoins) | " +
            "IPs: $ips"
        )

        $row++
    }

    $output | Set-Content `
        -Path $usersListFile `
        -Encoding UTF8
}

# --- Launch prefs ---
function Initialize-LaunchPrefs {
    if (-not (Test-Path $launchPrefsFile)) {
        $defaults = @()
        foreach ($server in $servers) {
            $defaults += [PSCustomObject]@{
                Name    = $server.Name
                UseVgui = $false
                LockOut = $false
            }
        }

        $defaults | ConvertTo-Json -Depth 5 | Set-Content -Path $launchPrefsFile -Encoding UTF8
    }

    Load-LaunchPrefs
}

function Load-LaunchPrefs {
    $script:launchPrefs = @{}

    if (-not (Test-Path $launchPrefsFile)) { return }

    try {
        $raw = Get-Content -Path $launchPrefsFile -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return }

        $items = $raw | ConvertFrom-Json -ErrorAction Stop
        foreach ($item in @($items)) {
            if ($null -ne $item -and $item.PSObject.Properties["Name"]) {
                $script:launchPrefs[$item.Name] = @{
                    UseVgui = [bool]$item.UseVgui
                    LockOut = if ($item.PSObject.Properties["LockOut"]) { [bool]$item.LockOut } else { $false }
                }
            }
        }
    } catch {
        Write-Log "Launch prefs load error: $($_.Exception.Message)"
    }
}

function Save-LaunchPrefs {
    try {
        $out = @()
        foreach ($server in $servers) {
            $useVgui = $false
            if ($launchPrefs.ContainsKey($server.Name)) {
                $useVgui = [bool]$launchPrefs[$server.Name].UseVgui
            }

            $lockOut = $false
            if ($launchPrefs.ContainsKey($server.Name) -and $launchPrefs[$server.Name].ContainsKey("LockOut")) {
                $lockOut = [bool]$launchPrefs[$server.Name].LockOut
            }

            $out += [PSCustomObject]@{
                Name    = $server.Name
                UseVgui = $useVgui
                LockOut = $lockOut
            }
        }

        $out | ConvertTo-Json -Depth 5 | Set-Content -Path $launchPrefsFile -Encoding UTF8
    } catch {
        Write-Log "Launch prefs save error: $($_.Exception.Message)"
    }
}