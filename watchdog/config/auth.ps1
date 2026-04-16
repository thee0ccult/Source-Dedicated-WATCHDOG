# ================================
# AUTH + DASHBOARD CONFIG
# ================================

# --- Dashboard config ---
$script:dashboardPort = 8080
$script:dashboardHost = "*"
$script:allowRemote = $true
$script:dashboardTitle = "Source Dedicated Watchdog"

$script:imgPath = Join-Path $scriptRoot "img"

$script:logoPath = Join-Path $script:imgPath "logo.png"
$script:onIconPath = Join-Path $script:imgPath "on.png"
$script:offIconPath = Join-Path $script:imgPath "off.png"
$script:dashboardHtmlPath = Join-Path $scriptRoot "dashboard.html"

# --- AUTH CONFIG ---
$script:authFile = Join-Path $scriptRoot "auth.json"
$script:authToken = [guid]::NewGuid().ToString()

function Get-Hash {
    param([string]$text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
    $hash = $sha.ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace "-","").ToLower()
}

if (Test-Path $authFile) {
    try {
        $authData = Get-Content $authFile -Raw | ConvertFrom-Json
        $script:authUser = $authData.user
        $script:authPass = $authData.pass
    } catch {
        $script:authUser = "watchd0g"
        $script:authPass = "admin123"
    }
} else {
    $script:authUser = "watchd0g"
    $script:authPass = "admin123"
}

$script:authUserHash = Get-Hash $authUser
$script:authPassHash = Get-Hash $authPass