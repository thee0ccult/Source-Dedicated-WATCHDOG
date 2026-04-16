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
    param ([string]$msg)
    "$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) - $msg" | Out-File -Append -FilePath $logFile -Encoding UTF8
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

            $out += [PSCustomObject]@{
                Name    = $server.Name
                UseVgui = $useVgui
            }
        }

        $out | ConvertTo-Json -Depth 5 | Set-Content -Path $launchPrefsFile -Encoding UTF8
    } catch {
        Write-Log "Launch prefs save error: $($_.Exception.Message)"
    }
}