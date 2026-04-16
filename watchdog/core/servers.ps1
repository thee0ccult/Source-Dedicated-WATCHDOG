# ================================
# SERVER PROCESS + CONTROL LAYER
# ================================

function Get-ServerUseVgui {
    param($server)

    if ($launchPrefs.ContainsKey($server.Name)) {
        return [bool]$launchPrefs[$server.Name].UseVgui
    }

    return $false
}

function Set-ServerUseVgui {
    param(
        [string]$ServerName,
        [bool]$UseVgui
    )

    if (-not $launchPrefs.ContainsKey($ServerName)) {
        $launchPrefs[$ServerName] = @{ UseVgui = $false }
    }

    $launchPrefs[$ServerName].UseVgui = $UseVgui
    Save-LaunchPrefs
}

function Get-EffectiveServerArgs {
    param($server)

    $args = [string]$server.Args
    $useVgui = Get-ServerUseVgui -server $server

    if (-not $useVgui) {
        return $args
    }

    $effectiveArgs = [regex]::Replace($args, '(?i)(?<!\S)-console(?!\S)', '')
    $effectiveArgs = [regex]::Replace($effectiveArgs, '\s{2,}', ' ').Trim()

    return $effectiveArgs
}

# --- Process Detection ---
function Get-ServerProcess {
    param (
        [int]$port,
        [string]$exe
    )

    $procs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.ProcessName -like "$exe*"
    }

    foreach ($p in $procs) {
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CommandLine
            if ($cmd -match "-port\s+$port\b") {
                return $p
            }
        } catch {}
    }

    return $null
}

# --- Server control ---
function Start-ServerInstance {
    param($server)

    $effectiveArgs = Get-EffectiveServerArgs -server $server
    $useVgui = Get-ServerUseVgui -server $server

    Write-Log "Starting $($server.Name) | UseVgui=$useVgui | Args=$effectiveArgs"

    Start-Process -FilePath $server.Path `
        -ArgumentList $effectiveArgs `
        -WorkingDirectory (Split-Path $server.Path)
}

function Stop-ServerInstance {
    param($server)

    $proc = Get-ServerProcess -port $server.Port -exe $server.Exe
    if ($proc) {
        Write-Log "Stopping $($server.Name)"
        Stop-Process -Id $proc.Id -Force
        Start-Sleep -Seconds 2
    }
}

function Restart-ServerInstance {
    param($server)

    Write-Log "Restarting $($server.Name)"
    Stop-ServerInstance -server $server
    Start-ServerInstance -server $server
    $lastRestart[$server.Name] = Get-Date
    $downSince.Remove($server.Name)
}