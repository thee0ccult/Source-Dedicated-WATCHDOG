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
$script:commandQueueFile = Join-Path $dataRoot "dashboard_commands.jsonl"
$script:launchPrefsFile = Join-Path $dataRoot "launch_prefs.json"

# --- Runtime state ---
$script:launchPrefs = @{}
$script:lastRestart = @{}
$script:downSince = @{}
$script:rconStatus = @{}

$script:scriptStartTime = Get-Date

# --- Logging ---
function Write-Log {
    param(
        [string]$Message,
        [string]$Color = "Gray"
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "$timestamp - $Message"

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

    if (-not (Test-Path $commandQueueFile)) {
        "" | Set-Content -Path $commandQueueFile -Encoding UTF8
    }
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