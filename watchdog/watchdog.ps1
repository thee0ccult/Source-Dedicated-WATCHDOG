# ================================== #
# Source Dedicated Watchdog by dr.N0 #
# ================================== #
trap {
    Write-Host "FATAL ERROR: $($_.Exception.Message)" -ForegroundColor Red
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

Write-Host "WATCHDOG STARTING..." -ForegroundColor Green

# --- History / status / players ---
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

        if ($proc -and -not [string]::IsNullOrWhiteSpace($server.RconPassword)) {
            try {
                $rawStatus = Invoke-SourceRcon `
                    -rconHost $server.RconHost `
                    -Port $server.RconPort `
                    -Password $server.RconPassword `
                    -Command "status"

                $parsedStatus = Parse-ServerStatus -text $rawStatus
            } catch {}
        }

        $status += [PSCustomObject]@{
            Name         = $server.Name
            Port         = $server.Port
            Exe          = $server.Exe
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

            Hostname     = $parsedStatus.Hostname
            UdpIp        = $parsedStatus.UdpIp
            SteamId      = $parsedStatus.SteamId
            Map          = $parsedStatus.Map
            PlayersInfo  = $parsedStatus.PlayersInfo
            Edicts       = $parsedStatus.Edicts
            Version      = $parsedStatus.Version
			RconStatus = if ($rconStatus.ContainsKey($server.Name)) { $rconStatus[$server.Name].Status } else { $null }
			RconTime   = if ($rconStatus.ContainsKey($server.Name)) { $rconStatus[$server.Name].Time } else { $null }

            CPU          = $cpu
            WorkingSetMB = $ram
            LastRestart  = if ($lastRestart[$server.Name]) { $lastRestart[$server.Name].ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
            DownSince    = if ($downSince[$server.Name]) { $downSince[$server.Name].ToString("yyyy-MM-dd HH:mm:ss") } else { $null }
            UpdatedAt    = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }

    $status | ConvertTo-Json -Depth 5 | Set-Content -Path $statusFile -Encoding UTF8
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

    $out | ConvertTo-Json -Depth 8 | Set-Content -Path $historyFile -Encoding UTF8
}

function Update-Players {
    $allPlayers = @()
    foreach ($server in $servers) {
        $allPlayers += Get-ServerPlayers -server $server
    }

    $allPlayers | ConvertTo-Json -Depth 8 | Set-Content -Path $playersFile -Encoding UTF8
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
Write-Log "WATCHDOG STARTED"
Ensure-DataFiles
Initialize-LaunchPrefs
Update-Status
Update-History
Update-Players
Ensure-DashboardRedirectFile
Start-Dashboard
Ensure-DashboardHealthy

Write-Log "Startup validation phase..."

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