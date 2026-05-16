# --- Dashboard HTML and server ---
function Get-DashboardHtml {

	$dashboardPath = Join-Path $scriptRoot "web\dashboard.html"
	$loginPath = Join-Path $scriptRoot "web\login.html"

	$html = Get-Content -Path $dashboardPath -Raw -Encoding UTF8
	$loginPage = Get-Content -Path $loginPath -Raw -Encoding UTF8

    $html = $html.Replace('__AUTH_USER__', $authUser)
	$html = $html.Replace('__AUTH_PASS__', $authPass)

	return @{
        Html  = $html.Replace('__DASHBOARD_TITLE__', $dashboardTitle)
        Login = $loginPage
    }
}

function Ensure-DashboardRedirectFile {
    $target = if ($dashboardHost -eq "*") { "http://localhost:$dashboardPort/" } else { "http://$dashboardHost`:$dashboardPort/" }
@"
<!doctype html>
<html>
<head>
<meta http-equiv="refresh" content="0; url=$target">
<title>$dashboardTitle</title>
</head>
<body>
Opening <a href="$target">$target</a>
</body>
</html>
"@ | Set-Content -Path $dashboardHtmlPath -Encoding UTF8
}

$scriptRoot = if ($PSScriptRoot) {
    Split-Path $PSScriptRoot -Parent
}
else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Start-Dashboard {
    $jobName = "SourceDedicatedWatchdogDashboard"

    $existing = Get-Job -Name $jobName -ErrorAction SilentlyContinue
    if ($existing) {
        try {
            if ($existing.State -eq "Running") {
                Write-Log "Dashboard job already running"
                return
            } else {
                Remove-Job -Name $jobName -Force -ErrorAction SilentlyContinue
            }
        } catch {
        }
    }

    $dashboardData = Get-DashboardHtml
	$dashboardHtml = $dashboardData.Html
	$loginPage = $dashboardData.Login

    Start-Job -Name $jobName `
        -ArgumentList $scriptRoot, $dashboardPort, $statusFile, $historyFile, $playersFile, $usersDatabaseFile, $logoPath, $onIconPath, $offIconPath, $dashboardTitle, $commandQueueFile, $dashboardHtml, $loginPage, $allowRemote, $servers `
        -ScriptBlock {
            param($scriptRoot, $port, $statusPath, $historyPath, $playersPath, $usersDatabasePath, $logoPath, $onIconPath, $offIconPath, $title, $queuePath, $dashboardHtml, $loginPage, $initialAllowRemote, $servers)

            $allowRemote = [bool]$initialAllowRemote
			$authToken = [guid]::NewGuid().ToString()

			# --- SHARED MASTER STATE FILE ---
			$masterStateFile = Join-Path $scriptRoot "data\master_enabled.json"

            $listener = New-Object System.Net.HttpListener
            $listener.IgnoreWriteExceptions = $true
            $listener.Prefixes.Add("http://+:$port/")
			Add-Type -AssemblyName Microsoft.VisualBasic
			
			function Get-MasterListEnabled {

    if (-not (Test-Path $masterStateFile)) {

        @{
            enabled = $true
        } |
        ConvertTo-Json |
        Set-Content `
            -Path $masterStateFile `
            -Encoding UTF8

        return $true
    }

    try {

        $json = Get-Content `
            -Path $masterStateFile `
            -Raw `
            -ErrorAction Stop |
            ConvertFrom-Json

        return [bool]$json.enabled

    } catch {

        return $true
    }
}

function Set-MasterListEnabled {
    param(
        [bool]$Enabled
    )

    try {

        @{
            enabled = $Enabled
            updated = (Get-Date).ToString("o")
        } |
        ConvertTo-Json |
        Set-Content `
            -Path $masterStateFile `
            -Encoding UTF8

    } catch {

        Write-Output "MASTER STATE WRITE FAILED: $($_.Exception.Message)"
    }
}
			
            function Write-WidgetResponse {
                param(
                    [Parameter(Mandatory = $true)] $Response,
                    [Parameter(Mandatory = $true)][int] $StatusCode,
                    [Parameter(Mandatory = $true)][string] $ContentType,
                    [Parameter(Mandatory = $true)][string] $Body
                )

                $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
                $Response.StatusCode = $StatusCode
                $Response.ContentType = $ContentType
                try { $Response.Headers.Add("X-Content-Type-Options", "nosniff") } catch {}
                $Response.OutputStream.Write($bytes, 0, $bytes.Length)
                $Response.OutputStream.Close()
            }


            function ConvertTo-JsonStringLiteral {
                param([AllowNull()][string]$Value)

                if ($null -eq $Value) {
                    return 'null'
                }

                return ($Value | ConvertTo-Json -Compress)
            }

            function Get-ServerMapListJson {
                param(
                    [Parameter(Mandatory = $true)][string]$ServerName,
                    [Parameter(Mandatory = $true)]$Servers
                )

                $server = $Servers | Where-Object { $_.Name -eq $ServerName } | Select-Object -First 1

                if ($null -eq $server) {
                    return '{"ok":false,"error":"Unknown server name."}'
                }

                $gameFolder = $null
                try {
                    $gameMatch = [regex]::Match([string]$server.Args, '(?i)(?:^|\s)-game\s+("?)([^"\s]+)\1')
                    if ($gameMatch.Success) {
                        $gameFolder = $gameMatch.Groups[2].Value
                    }
                } catch {}

                if ([string]::IsNullOrWhiteSpace($gameFolder)) {
                    return '{"ok":false,"error":"Unable to determine game folder from server Args."}'
                }

                $serverRoot = Split-Path -Path ([string]$server.Path) -Parent
                $mapFolder = Join-Path (Join-Path $serverRoot $gameFolder) "maps"

                if (-not (Test-Path -LiteralPath $mapFolder -PathType Container)) {
                    $mapFolderJson = ConvertTo-JsonStringLiteral $mapFolder
                    return "{""ok"":false,""error"":""Maps folder was not found."",""mapFolder"":$mapFolderJson}"
                }

                try {
                    $maps = @(Get-ChildItem -LiteralPath $mapFolder -Filter "*.bsp" -File -ErrorAction Stop |
                        Sort-Object Name |
                        ForEach-Object { $_.Name })

                    $payload = [PSCustomObject]@{
                        ok        = $true
                        server    = $ServerName
                        mapFolder = $mapFolder
                        count     = $maps.Count
                        maps      = $maps
                    }

                    return ($payload | ConvertTo-Json -Depth 5 -Compress)
                } catch {
                    $errorJson = ConvertTo-JsonStringLiteral $_.Exception.Message
                    $mapFolderJson = ConvertTo-JsonStringLiteral $mapFolder
                    return "{""ok"":false,""error"":$errorJson,""mapFolder"":$mapFolderJson}"
                }
            }

            try {
                $listener.Start()
                Write-Output "Dashboard listener started OK"
            } catch {
                Write-Output "Dashboard failed: $($_.Exception.Message)"
                return
            }

            try {
                while ($listener.IsListening) {

                    try {
                        $ctx = $listener.GetContext()
                    } catch {
                        Write-Output "Dashboard GetContext error: $($_.Exception.Message)"
                        Start-Sleep -Milliseconds 250
                        continue
                    }

                    if ($null -eq $ctx) {
                        Start-Sleep -Milliseconds 100
                        continue
                    }

                    $req = $ctx.Request
                    $res = $ctx.Response

                    try {
                        $remoteIP = $req.RemoteEndPoint.Address.ToString()
                    } catch {
                        $remoteIP = ""
                    }

                    try {
                        $path = $req.Url.AbsolutePath.ToLowerInvariant()
                    } catch {
                        $path = "/"
                    }
                    # --- PUBLIC WIDGET ROUTES (READ-ONLY) ---
                    if ($path -match "^/widget/api/([a-zA-Z0-9_-]{1,64})$") {
                        if ($req.HttpMethod -ne "GET") {
                            Write-WidgetResponse -Response $res -StatusCode 405 -ContentType "text/plain; charset=utf-8" -Body "Method Not Allowed"
                            continue
                        }

                        $serverName = $Matches[1].ToLowerInvariant()
                        $allowedServers = @($servers | ForEach-Object { $_.Name.ToLowerInvariant() })

                        if ($allowedServers -notcontains $serverName) {
                            Write-WidgetResponse -Response $res -StatusCode 404 -ContentType "text/plain; charset=utf-8" -Body "Not Found"
                            continue
                        }

                        $statusData = @()
                        if (Test-Path $statusPath) {
                            try {
                                $rawStatus = Get-Content -Path $statusPath -Raw
                                if (-not [string]::IsNullOrWhiteSpace($rawStatus)) {
                                    $statusData = $rawStatus | ConvertFrom-Json
                                }
                            } catch {
                                $statusData = @()
                            }
                        }

                        $playersData = @()
                        if (Test-Path $playersPath) {
                            try {
                                $rawPlayers = Get-Content -Path $playersPath -Raw
                                if (-not [string]::IsNullOrWhiteSpace($rawPlayers)) {
                                    $playersData = $rawPlayers | ConvertFrom-Json
                                }
                            } catch {
                                $playersData = @()
                            }
                        }

                        $server = $statusData | Where-Object { $_.Name -and $_.Name.ToLowerInvariant() -eq $serverName } | Select-Object -First 1
                        if (-not $server) {
                            Write-WidgetResponse -Response $res -StatusCode 404 -ContentType "text/plain; charset=utf-8" -Body "Not Found"
                            continue
                        }

                        $playerEntry = $playersData | Where-Object { $_.Server -and $_.Server.ToLowerInvariant() -eq $serverName } | Select-Object -First 1
                        $onlinePlayers = @()
                        if ($playerEntry -and $playerEntry.Enabled -and $playerEntry.Players) {
							$onlinePlayers = @($playerEntry.Players | ForEach-Object {
								@{
                                    name      = $_.Name
                                    steamId   = $_.SteamId
                                    connected = $_.Connected
                                    ping      = $_.Ping
                                    loss      = $_.Loss
                                }
                            })
                        }

$ip = ""
$port = ""

$ip = ""
$port = ""

if ($server.UdpIp -match "^([0-9\.]+):(\d+)$") {
    $ip = $matches[1]
    $port = $matches[2]
}

# --- HARD FALLBACK (THIS FIXES EVERYTHING) ---
if ([string]::IsNullOrWhiteSpace($ip)) {
    $ip = $server.RconHost
}

if ([string]::IsNullOrWhiteSpace($port)) {
    $port = $server.Port
}

$safe = @{
    name          = $server.Name
	region        = $server.Region
    hostname      = $server.Hostname
    status        = $server.Status
    map           = $server.Map
    players       = $server.PlayersInfo
    updated       = $server.UpdatedAt
    ip            = $ip
    port          = $port
    onlinePlayers = $onlinePlayers
}

                        Write-WidgetResponse -Response $res -StatusCode 200 -ContentType "application/json; charset=utf-8" -Body (($safe | ConvertTo-Json -Depth 6))
                        continue
                    }

                    if ($path -match "^/widget/builder/([a-zA-Z0-9_-]{1,64})$") {
                        if ($req.HttpMethod -ne "GET") {
                            Write-WidgetResponse -Response $res -StatusCode 405 -ContentType "text/plain; charset=utf-8" -Body "Method Not Allowed"
                            continue
                        }

                        $serverName = $Matches[1].ToLowerInvariant()
                        $allowedServers = @($servers | ForEach-Object { $_.Name.ToLowerInvariant() })

                        if ($allowedServers -notcontains $serverName) {
                            Write-WidgetResponse -Response $res -StatusCode 404 -ContentType "text/plain; charset=utf-8" -Body "Not Found"
                            continue
                        }

                        $builderHtml = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Widget Builder - $serverName</title>
<style>
body{margin:0;background:#101215;color:#d7dbe0;font-family:Arial,Helvetica,sans-serif}
.page{display:grid;grid-template-columns:360px 1fr;gap:16px;min-height:100vh;padding:16px;box-sizing:border-box}
.panel,.preview{background:#171b20;border:1px solid #2a313a;border-radius:10px;padding:14px;box-sizing:border-box}
h1,h2{margin:0 0 12px 0;font-size:18px}
.group{margin-bottom:12px}
label{display:block;font-size:12px;color:#aeb6bf;margin-bottom:4px}
input[type="text"],input[type="number"],select,textarea{width:100%;box-sizing:border-box;background:#0f1317;color:#eef2f6;border:1px solid #2d3640;border-radius:6px;padding:8px}
input[type="color"]{width:100%;box-sizing:border-box;background:#0f1317;border:1px solid #2d3640;border-radius:6px;padding:4px;height:40px;cursor:pointer}
.row{display:grid;grid-template-columns:1fr 1fr;gap:10px}
.check{display:flex;align-items:center;gap:8px;padding-top:8px}
button{background:#2e7dff;color:#fff;border:0;border-radius:6px;padding:10px 12px;cursor:pointer}
button.secondary{background:#2b3138}
.actions{display:flex;gap:8px;flex-wrap:wrap}
iframe{border:0;background:#000;border-radius:8px;display:block}
.small{font-size:12px;color:#aeb6bf}
#embedCode{height:120px}
</style>
</head>
<body>
<div class="page">
    <div class="panel">
        <h1>Widget Builder</h1>
        <div class="small" style="margin-bottom:12px;">Server: $serverName</div>

        <div class="group">
            <label for="theme">Theme</label>
            <select id="theme">
                <option value="dark">Dark</option>
                <option value="light">Light</option>
                <option value="orange">Orange</option>
                <option value="green">Green</option>
                <option value="custom">Custom</option>
            </select>
        </div>

        <div class="row">
            <div class="group">
                <label for="bgColor">Background Color</label>
                <input id="bgColor" type="text" value="111111" maxlength="6">
            </div>
            <div class="group">
                <label for="fontColor">Font Color</label>
                <input id="fontColor" type="text" value="dddddd" maxlength="6">
            </div>
        </div>

<div class="row">
    <div class="group">
        <label for="labelColor">Label Color</label>
        <input id="labelColor" type="text" value="dddddd" maxlength="6">
    </div>
    <div class="group">
        <label for="valueColor">Value Color</label>
        <input id="valueColor" type="text" value="dddddd" maxlength="6">
    </div>
</div>

<div class="row">
    <div class="group">
        <label for="playerLabelColor">Player Label Color</label>
        <input id="playerLabelColor" type="text" value="dddddd" maxlength="6">
    </div>
    <div class="group">
        <label for="playerValueColor">Player Value Color</label>
        <input id="playerValueColor" type="text" value="dddddd" maxlength="6">
    </div>
</div>

<div class="group">
    <label for="infoColor">Info Color</label>
    <input id="infoColor" type="text" value="dddddd" maxlength="6">
</div>

        <div class="row">
            <div class="group">
                <label for="titleBgColor">Title Background</label>
                <input id="titleBgColor" type="text" value="111111" maxlength="6">
            </div>
            <div class="group">
                <label for="titleColor">Title Color</label>
                <input id="titleColor" type="text" value="ffffff" maxlength="6">
            </div>
        </div>

        <div class="row">
            <div class="group">
                <label for="borderColor">Border Color</label>
                <input id="borderColor" type="text" value="333333" maxlength="6">
            </div>
            <div class="group">
                <label for="linkColor">Link/Accent Color</label>
                <input id="linkColor" type="text" value="57d957" maxlength="6">
            </div>
        </div>

        <div class="row">
            <div class="group">
                <label for="borderStyle">Border Style</label>
                <select id="borderStyle">
                    <option value="solid">Solid</option>
                    <option value="double">Double</option>
                    <option value="minimal">Minimal</option>
                </select>
            </div>
            <div class="group">
                <label for="fontSize">Font Size</label>
                <input id="fontSize" type="number" value="12" min="10" max="18">
            </div>
        </div>

<div class="row">
    <div class="group">
        <label for="width">Width (min 144)</label>
        <input id="width" type="number" value="260" min="144">
    </div>
    <div class="group">
        <label for="frameHeight">Frame Height</label>
        <input id="frameHeight" type="number" value="420" min="200">
    </div>
</div>

<div class="row">
    <div class="group">
        <label for="playerHeight">Player List Height (min 100)</label>
        <input id="playerHeight" type="number" value="180" min="100">
    </div>
    <div class="group"></div>
</div>

<div class="row">
    <div class="group">
        <label for="globalColorPicker">Color Picker</label>
        <input id="globalColorPicker" type="color" value="#57d957">
    </div>
    <div class="group">
        <label for="globalColorHex">Hex Value</label>
        <input id="globalColorHex" type="text" value="57d957" maxlength="6" readonly>
    </div>
</div>

<div class="row">
    <div class="check">
        <input id="showPlayers" type="checkbox" checked>
        <label for="showPlayers" style="margin:0;">Show online players</label>
    </div>

    <div class="check">
        <input id="showJoin" type="checkbox" checked>
        <label for="showJoin" style="margin:0;">Show join button</label>
    </div>
</div>

<div class="row">
    <div class="check">
        <input id="showTitle" type="checkbox" checked>
        <label for="showTitle" style="margin:0;">Show title</label>
    </div>

    <div class="check">
        <input id="showFooter" type="checkbox" checked>
        <label for="showFooter" style="margin:0;">Show footer</label>
    </div>
</div>
        <div class="actions" style="margin-top:14px;">
            <button id="refreshBtn" type="button">Refresh Preview</button>
            <button id="copyBtn" class="secondary" type="button">Copy Embed Code</button>
        </div>

        <div class="group" style="margin-top:14px;">
            <label for="embedCode">Embed Code</label>
            <textarea id="embedCode" readonly></textarea>
        </div>
    </div>

    <div class="preview">
        <h2>Preview</h2>
        <div class="small" id="heightInfo" style="margin-bottom:12px;"></div>
        <iframe id="previewFrame" src="/widget/$serverName" width="260" height="420" scrolling="no"></iframe>
    </div>
</div>

<script>
(function(){
const presets = {
    dark:   { bgColor:'111111', fontColor:'dddddd', infoColor:'dddddd', playerLabelColor:'dddddd', playerValueColor:'dddddd', titleBgColor:'111111', titleColor:'ffffff', borderColor:'333333', linkColor:'57d957', borderStyle:'solid', labelColor:'dddddd', valueColor:'dddddd', fontSize:'12' },
    light:  { bgColor:'f3f5f7', fontColor:'1e2328', infoColor:'1e2328', playerLabelColor:'dddddd', playerValueColor:'dddddd', titleBgColor:'e7ebef', titleColor:'111111', borderColor:'c7d0d9', linkColor:'2e7dff', borderStyle:'solid', labelColor:'dddddd', valueColor:'dddddd', fontSize:'12' },
    orange: { bgColor:'1a1310', fontColor:'f4d8c8', infoColor:'f4d8c8', playerLabelColor:'dddddd', playerValueColor:'dddddd', titleBgColor:'241712', titleColor:'ffb26b', borderColor:'5d3a2a', linkColor:'ff8c42', borderStyle:'double', labelColor:'dddddd', valueColor:'dddddd', fontSize:'12' },
    green:  { bgColor:'0f1712', fontColor:'d8f0df', infoColor:'d8f0df', playerLabelColor:'dddddd', playerValueColor:'dddddd', titleBgColor:'132118', titleColor:'8ef0a4', borderColor:'29543a', linkColor:'5de07f', borderStyle:'solid', labelColor:'dddddd', valueColor:'dddddd', fontSize:'12' }
};

	const ids = ['theme','bgColor','fontColor','labelColor','valueColor','playerLabelColor','playerValueColor','infoColor','titleBgColor','titleColor','borderColor','linkColor','borderStyle','fontSize','width','frameHeight','playerHeight','showPlayers','showJoin','showTitle','showFooter'];

	const el = {};
	ids.forEach(id => el[id] = document.getElementById(id));
    const previewFrame = document.getElementById('previewFrame');
    const embedCode = document.getElementById('embedCode');
    const heightInfo = document.getElementById('heightInfo');
    const globalColorPicker = document.getElementById('globalColorPicker');
    const globalColorHex = document.getElementById('globalColorHex');

    function hex(v, fallback){
        return /^[0-9a-fA-F]{6}$/.test(v || '') ? v.toLowerCase() : fallback;
    }
    function intVal(v, fallback, min, max){
        const n = parseInt(v,10);
        if (isNaN(n)) return fallback;
        return Math.max(min, Math.min(max, n));
    }
    function applyTheme(){
        const theme = el.theme.value;
        if (theme !== 'custom' && presets[theme]){
            const p = presets[theme];
el.bgColor.value = p.bgColor;
el.fontColor.value = p.fontColor;
el.playerLabelColor.value = p.playerLabelColor || p.fontColor;
el.playerValueColor.value = p.playerValueColor || p.fontColor;
el.infoColor.value = p.infoColor;
el.titleBgColor.value = p.titleBgColor;
el.titleColor.value = p.titleColor;
el.borderColor.value = p.borderColor;
el.linkColor.value = p.linkColor;
el.borderStyle.value = p.borderStyle;
el.fontSize.value = p.fontSize;
        }
        render();
    }
    function buildQuery(){
        const width = intVal(el.width.value, 260, 144, 1200);
        const playerHeight = intVal(el.playerHeight.value, 180, 100, 800);
        const showPlayers = el.showPlayers.checked ? '1' : '0';

        const params = new URLSearchParams();
		params.set('theme', el.theme.value);
		params.set('bgColor', hex(el.bgColor.value, '111111'));
		params.set('fontColor', hex(el.fontColor.value, 'dddddd'));
		params.set('labelColor', hex(el.labelColor.value, hex(el.fontColor.value, 'dddddd')));
		params.set('valueColor', hex(el.valueColor.value, hex(el.fontColor.value, 'dddddd')));
		params.set('titleBgColor', hex(el.titleBgColor.value, '111111'));
		params.set('playerLabelColor', hex(el.playerLabelColor.value, hex(el.fontColor.value, 'dddddd')));
		params.set('playerValueColor', hex(el.playerValueColor.value, hex(el.fontColor.value, 'dddddd')));
		params.set('infoColor', hex(el.infoColor.value, hex(el.fontColor.value, 'dddddd')));
		params.set('titleColor', hex(el.titleColor.value, 'ffffff'));
		params.set('borderColor', hex(el.borderColor.value, '333333'));
		params.set('linkColor', hex(el.linkColor.value, '57d957'));
        params.set('borderStyle', ['solid','double','minimal'].includes(el.borderStyle.value) ? el.borderStyle.value : 'solid');
        params.set('fontSize', intVal(el.fontSize.value, 12, 10, 18));
        params.set('width', width);
		params.set('playerHeight', playerHeight);
		params.set('frameHeight', intVal(el.frameHeight.value, 420, 200, 2000));
        params.set('showPlayers', showPlayers);
		params.set('showJoin', el.showJoin.checked ? '1' : '0');
		params.set('showTitle', el.showTitle.checked ? '1' : '0');
		params.set('showFooter', el.showFooter.checked ? '1' : '0');
        return params.toString();
    }
function calculateHeight(){
    return intVal(el.frameHeight.value, 420, 200, 2000);
}
    function render(){
        const width = intVal(el.width.value, 260, 144, 1200);
        const qs = buildQuery();
        const serverName = "$serverName";
        const src = '/widget/' + serverName + '?' + qs;
		const height = intVal(el.frameHeight.value, 420, 200, 2000);

        previewFrame.width = width;
        previewFrame.height = height;
        previewFrame.src = src;
        heightInfo.textContent = 'Suggested iframe height: ' + height + 'px';
        embedCode.value = '<iframe src="' + window.location.origin + src + '" frameborder="0" scrolling="no" width="' + width + '" height="' + height + '"></iframe>';
    }

    function syncGlobalColorHex(){
        const value = globalColorPicker.value.replace('#','').toLowerCase();
        globalColorHex.value = value;
    }

    document.getElementById('refreshBtn').addEventListener('click', render);
    document.getElementById('copyBtn').addEventListener('click', async function(){
        try { await navigator.clipboard.writeText(embedCode.value); } catch(e) {}
    });
    el.theme.addEventListener('change', applyTheme);
    ids.filter(id => id !== 'theme').forEach(id => el[id].addEventListener('input', render));
    ids.filter(id => id !== 'theme').forEach(id => el[id].addEventListener('change', render));
    globalColorPicker.addEventListener('input', syncGlobalColorHex);
    globalColorPicker.addEventListener('change', syncGlobalColorHex);

    syncGlobalColorHex();
    applyTheme();
})();
</script>
</body>
</html>
"@

                        Write-WidgetResponse -Response $res -StatusCode 200 -ContentType "text/html; charset=utf-8" -Body $builderHtml
                        continue
                    }
if ($path -eq "/logo_bit.png") {

    $logoBitPath = Join-Path $scriptRoot "img\logo_bit.png"

    if (Test-Path $logoBitPath) {

        try {

            $bytes = [System.IO.File]::ReadAllBytes($logoBitPath)

            $res.StatusCode = 200
            $res.ContentType = "image/png"
            $res.ContentLength64 = $bytes.Length

            $res.OutputStream.Write($bytes, 0, $bytes.Length)

        }
        catch {

            $res.StatusCode = 500

        }

    }
    else {

        $res.StatusCode = 404

    }

    $res.OutputStream.Close()
    continue
}

if ($path -match "^/flags/([a-zA-Z0-9_-]+)\.gif$") {

    $flagName = $Matches[1].ToLowerInvariant()

    $flagPath = Join-Path $scriptRoot "flags\$flagName.gif"

    if (Test-Path $flagPath) {

        try {

            $bytes = [System.IO.File]::ReadAllBytes($flagPath)

            $res.StatusCode = 200
            $res.ContentType = "image/gif"
            $res.ContentLength64 = $bytes.Length

            $res.OutputStream.Write($bytes, 0, $bytes.Length)

        }
        catch {

            $res.StatusCode = 500

        }

    }
    else {

        $fallback = Join-Path $scriptRoot "flags\dontknow.gif"

        if (Test-Path $fallback) {

            $bytes = [System.IO.File]::ReadAllBytes($fallback)

            $res.StatusCode = 200
            $res.ContentType = "image/gif"
            $res.ContentLength64 = $bytes.Length

            $res.OutputStream.Write($bytes, 0, $bytes.Length)

        }
        else {

            $res.StatusCode = 404

        }

    }

    $res.OutputStream.Close()
    continue
}

# ==========================================
# RCON TOGGLE API
# ==========================================

if ($path -eq "/api/rcon-toggle") {

    try {

        $reader =
            New-Object IO.StreamReader($req.InputStream)

        $body = $reader.ReadToEnd()

        $json = $body | ConvertFrom-Json

        $serverName = [string]$json.server
        $disabled = [bool]$json.disabled

        if ($disabled) {

            $global:RconDisabledServers[$serverName] = $true

            Write-Log `
                "RCON MANUALLY DISABLED [$serverName]"

        } else {

            $global:RconDisabledServers.Remove($serverName)

            Write-Log `
                "RCON MANUAL DISABLE REMOVED [$serverName]"
        }

        $res.StatusCode = 200

    } catch {

        $res.StatusCode = 500

        Write-Log `
            "RCON TOGGLE API FAILED: $($_.Exception.Message)"
    }

    $res.Close()
    continue
}

if ($path -eq "/api/users-list") {

    try {

        if (-not (Test-Path $usersDatabasePath)) {

            Write-WidgetResponse `
                -Response $res `
                -StatusCode 200 `
                -ContentType "application/json; charset=utf-8" `
                -Body "[]"

            continue
        }

        $rawUsers = Get-Content `
            -Path $usersDatabasePath `
            -Raw `
            -ErrorAction SilentlyContinue

        if ([string]::IsNullOrWhiteSpace($rawUsers)) {
            $rawUsers = "[]"
        }

        Write-WidgetResponse `
            -Response $res `
            -StatusCode 200 `
            -ContentType "application/json; charset=utf-8" `
            -Body $rawUsers

    }
    catch {

        Write-WidgetResponse `
            -Response $res `
            -StatusCode 500 `
            -ContentType "application/json; charset=utf-8" `
            -Body '{"error":"Failed to load users database"}'
    }

    continue
}

                    if ($path -match "^/widget/([a-zA-Z0-9_-]{1,64})$") {
                        if ($req.HttpMethod -ne "GET") {
                            Write-WidgetResponse -Response $res -StatusCode 405 -ContentType "text/plain; charset=utf-8" -Body "Method Not Allowed"
                            continue
                        }

                        $serverName = $Matches[1].ToLowerInvariant()
                        $allowedServers = @($servers | ForEach-Object { $_.Name.ToLowerInvariant() })

                        if ($allowedServers -notcontains $serverName) {
                            Write-WidgetResponse -Response $res -StatusCode 404 -ContentType "text/plain; charset=utf-8" -Body "Not Found"
                            continue
                        }

                        function Get-SafeInt {
                            param($Value, [int]$Default, [int]$Min, [int]$Max)
                            try {
                                $n = [int]$Value
                            } catch {
                                return $Default
                            }
                            if ($n -lt $Min) { return $Min }
                            if ($n -gt $Max) { return $Max }
                            return $n
                        }

                        function Get-SafeBool {
                            param($Value, [bool]$Default)
                            if ($null -eq $Value -or $Value -eq "") { return $Default }
                            return ($Value -eq "1" -or $Value.ToString().ToLowerInvariant() -eq "true")
                        }

                        function Get-SafeHex {
                            param($Value, [string]$Default)
                            if ($null -ne $Value -and $Value.ToString() -match '^[0-9a-fA-F]{6}$') {
                                return $Value.ToLowerInvariant()
                            }
                            return $Default
                        }

                        function Get-SafeEnum {
                            param($Value, [string[]]$Allowed, [string]$Default)
                            if ($null -eq $Value) { return $Default }
                            $v = $Value.ToString().ToLowerInvariant()
                            if ($Allowed -contains $v) { return $v }
                            return $Default
                        }

                        $qs = $req.QueryString

                        $theme = Get-SafeEnum -Value $qs["theme"] -Allowed @("dark","light","orange","green","custom") -Default "dark"

                        switch ($theme) {
                            "light" {
                                $defaultBgColor = "f3f5f7"
                                $defaultFontColor = "1e2328"
                                $defaultTitleBgColor = "e7ebef"
                                $defaultTitleColor = "111111"
                                $defaultBorderColor = "c7d0d9"
                                $defaultLinkColor = "2e7dff"
                                $defaultBorderStyle = "solid"
                            }
                            "orange" {
                                $defaultBgColor = "1a1310"
                                $defaultFontColor = "f4d8c8"
                                $defaultTitleBgColor = "241712"
                                $defaultTitleColor = "ffb26b"
                                $defaultBorderColor = "5d3a2a"
                                $defaultLinkColor = "ff8c42"
                                $defaultBorderStyle = "double"
                            }
                            "green" {
                                $defaultBgColor = "0f1712"
                                $defaultFontColor = "d8f0df"
                                $defaultTitleBgColor = "132118"
                                $defaultTitleColor = "8ef0a4"
                                $defaultBorderColor = "29543a"
                                $defaultLinkColor = "5de07f"
                                $defaultBorderStyle = "solid"
                            }
                            default {
                                $defaultBgColor = "111111"
                                $defaultFontColor = "dddddd"
                                $defaultTitleBgColor = "111111"
                                $defaultTitleColor = "ffffff"
                                $defaultBorderColor = "333333"
                                $defaultLinkColor = "57d957"
                                $defaultBorderStyle = "solid"
                            }
                        }

						$bgColor = Get-SafeHex -Value $qs["bgColor"] -Default $defaultBgColor
						$fontColor = Get-SafeHex -Value $qs["fontColor"] -Default $defaultFontColor
						$infoColor = Get-SafeHex -Value $qs["infoColor"] -Default $fontColor
						$labelColor = Get-SafeHex -Value $qs["labelColor"] -Default $infoColor
						$valueColor = Get-SafeHex -Value $qs["valueColor"] -Default $infoColor
						$playerLabelColor = Get-SafeHex `
							-Value $qs["playerLabelColor"] `
							-Default $fontColor

						$playerValueColor = Get-SafeHex `
							-Value $qs["playerValueColor"] `
							-Default $fontColor
						$titleBgColor = Get-SafeHex -Value $qs["titleBgColor"] -Default $defaultTitleBgColor
						$titleColor = Get-SafeHex -Value $qs["titleColor"] -Default $defaultTitleColor
						$borderColor = Get-SafeHex -Value $qs["borderColor"] -Default $defaultBorderColor
						$linkColor = Get-SafeHex -Value $qs["linkColor"] -Default $defaultLinkColor
						$borderStyle = Get-SafeEnum -Value $qs["borderStyle"] -Allowed @("solid","double","minimal") -Default $defaultBorderStyle
                        $width = Get-SafeInt -Value $qs["width"] -Default 260 -Min 144 -Max 1200
                        $fontSize = Get-SafeInt -Value $qs["fontSize"] -Default 12 -Min 10 -Max 18
                        $playerHeight = Get-SafeInt -Value $qs["playerHeight"] -Default 180 -Min 100 -Max 800
						$frameHeight = Get-SafeInt -Value $qs["frameHeight"] -Default 420 -Min 200 -Max 2000
						$showPlayers = Get-SafeBool -Value $qs["showPlayers"] -Default $true
						$showJoin = Get-SafeBool -Value $qs["showJoin"] -Default $true
						$showTitle = Get-SafeBool -Value $qs["showTitle"] -Default $true
						$showFooter = Get-SafeBool -Value $qs["showFooter"] -Default $true

						$showPlayersJs = if ($showPlayers) { "true" } else { "false" }
						$showJoinJs = if ($showJoin) { "true" } else { "false" }
						$showTitleJs = if ($showTitle) { "true" } else { "false" }
						$showFooterJs = if ($showFooter) { "true" } else { "false" }
						
                        $widgetHtml = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=$width, initial-scale=1">
<title>Server Widget - $serverName</title>
<style>
html,body{margin:0;padding:0;background:#$bgColor;color:#$fontColor;font-family:Arial,Helvetica,sans-serif;font-size:${fontSize}px}
body{
    overflow:hidden;
    height:${frameHeight}px;
}
.wrap{
    width:${width}px;
    height:${frameHeight}px;
    padding:10px;
    border:1px $(if ($borderStyle -eq "minimal") { "solid" } else { $borderStyle }) #$borderColor;
    background:#$bgColor;
    box-sizing:border-box;

    display:flex;
    flex-direction:column;
}
.title{font-size:$([int]($fontSize + 2))px;font-weight:700;color:#$titleColor;background:#$titleBgColor;margin:-10px -10px 8px -10px;padding:0px;border-bottom:1px solid #$borderColor}
.status{
    margin-bottom:6px;
    display:flex;
    align-items:center;
    justify-content:space-between;
    gap:8px;
}
.online{color:#$linkColor;font-weight:700}
.offline{color:#ff6666;font-weight:700}
.meta{line-height:1.45;word-wrap:break-word}
.meta .label{color:#$labelColor;font-weight:600}
.meta .value{color:#$valueColor}
.players{
    margin-top:8px;
    height:${playerHeight}px;
    overflow-y:auto;
    border-top:1px solid #$borderColor;
    padding-top:8px;
    flex-shrink:0;
}
.player{padding:4px 0;border-bottom:1px solid #$borderColor}
.small{font-size:$([Math]::Max($fontSize-1,10))px;color:#$fontColor;opacity:0.85}
.join-btn{
    padding:1px 6px;
    font-size:0.9em;
    line-height:1.2;
    font-weight:600;
    border-radius:4px;
    border:1px solid #$borderColor;
    background:#$linkColor;
    color:#000;
    text-decoration:none;
    white-space:nowrap;
}
.join-btn:hover{
    filter:brightness(1.1);
}
.error{color:#ff6666}
a{color:#$linkColor}
.watchdogFooter{
    margin-top:10px;
    padding-top:8px;
    border-top:1px solid #$borderColor;

    display:flex;
    align-items:center;
    justify-content:center;
    gap:8px;

    opacity:0.75;

    color:#$infoColor;
}

.watchdogFooter img{
    width:16px;
    height:16px;
    object-fit:contain;
}
.onlineRow{
    display:flex;
    align-items:center;
    justify-content:center;
    gap:6px;
}

.flag{
    width:16px;
    height:11px;
    object-fit:cover;
    image-rendering:auto;
    border-radius:1px;
    box-shadow:0 0 2px rgba(0,0,0,0.5);
}
</style>
</head>
<body>
<div class="wrap">
    $(if ($showTitle) { "<div class='title'>$serverName</div>" })
    <div id="content">Loading...</div>
</div>
<script>
async function load(){
    try{
        const serverName = "$serverName";
        const showPlayers = $showPlayersJs;
		const showJoin = $showJoinJs;
		const showTitle = $showTitleJs;
		const showFooter = $showFooterJs;
        const res = await fetch('/widget/api/' + serverName + '?ts=' + Date.now(), { cache: 'no-store' });

        const root = document.getElementById('content');
        if(!root){ return; }

        if(res.status !== 200){
            root.innerHTML = '<div class="error">API Error</div>';
            return;
        }

        const data = await res.json();
        const isOnline = String(data.status || '').toUpperCase() === 'ONLINE';
        const players = Array.isArray(data.onlinePlayers) ? data.onlinePlayers : [];

        let html = '';
        let statusHtml = '<div class="status ' + (isOnline ? 'online' : 'offline') + '">';

statusHtml += '<div style="display:flex;align-items:center;gap:6px;">' +

    '<span>' + (data.status || 'UNKNOWN') + '</span>' +

    '<img ' +
        'src="/flags/' + ((data.region || 'dontknow').toLowerCase()) + '.gif" ' +
        'title="Region: ' + (data.region || 'Unknown') + '" ' +
        'alt="' + (data.region || 'Unknown') + '" ' +
        'style="' +
            'width:16px;' +
            'height:11px;' +
            'object-fit:cover;' +
            'border-radius:1px;' +
            'box-shadow:0 0 2px rgba(0,0,0,0.5);' +
        '"' +
    '>' +

'</div>';

const connect = (data.ip && data.port)
    ? 'steam://connect/' + data.ip + ':' + data.port
    : '';

if(connect && showJoin){
    statusHtml += '<a class="join-btn" href="' + connect + '">JOIN</a>';
}

statusHtml += '</div>';

html += statusHtml;
html += '<div class="meta">';

html += '<span class="label">Hostname:</span> <span class="value">' + (data.hostname || '') + '</span><br>';
html += '<span class="label">Address:</span> <span class="value">' + ((data.ip || '') + ':' + (data.port || '')) + '</span><br>';
html += '<span class="label">Map:</span> <span class="value">' + (data.map || '') + '</span><br>';
html += '<span class="label">Players:</span> <span class="value">' + (data.players || '') + '</span><br>';
html += '<span class="label">Updated:</span> <span class="value">' + (data.updated || '') + '</span>';

html += '</div>';

        if(showPlayers){
            if(players.length > 0){
                html += '<div class="players">';
                for(let i=0;i<players.length;i++){
                    const p = players[i] || {};
                    html += '<div class="player">';
					
					// Convert Steam2 -> SteamID64
function steamTo64(id){
    try{
        if(!id) return '';

        // Steam2 format
        if(id.startsWith('STEAM_')){
            const parts = id.split(':');
            const Y = parseInt(parts[1]);
            const Z = parseInt(parts[2]);
            return (BigInt(Z) * 2n + BigInt(Y) + 76561197960265728n).toString();
        }

        // Steam3 format [U:1:XXXX]
        const match = id.match(/\[U:1:(\d+)\]/);
        if(match){
            return (BigInt(match[1]) + 76561197960265728n).toString();
        }

        return '';
    }catch{
        return '';
    }
}

const steamId = (p.steamId || '');
const steam64 = steamTo64(steamId);
const profileUrl = steam64 ? ('https://steamcommunity.com/profiles/' + steam64) : '';

html += '<div style="display:flex; align-items:center; gap:6px;">';
html += '<span>' + (p.name || '') + '</span>';

if(profileUrl){
    html += '<a href="' + profileUrl + '" target="_blank" ' +
            'style="text-decoration:none; padding:1px 6px; border:1px solid #$borderColor; ' +
            'background:#$linkColor; color:#000; border-radius:4px; font-size:0.9em; font-weight:600;">' +
            'PROFILE</a>';
}

html += '</div>';

html += '<div class="small" style="opacity:0.7;">' +

    '<span style="color:#$playerLabelColor;font-weight:600;">SteamID:</span> ' +

    '<span style="color:#$playerValueColor;">' +
        steamId +
    '</span>' +

'</div>';

html += '<div class="small">' +

    '<span style="color:#$playerLabelColor;font-weight:600;">Ping:</span> ' +

    '<span style="color:#$playerValueColor;">' +
        (p.ping || '') +
    '</span>' +

    '<span style="color:#$playerLabelColor;font-weight:600;"> | Connected:</span> ' +

    '<span style="color:#$playerValueColor;">' +
        (p.connected || '') +
    '</span>' +

'</div>';

html += '</div>';
                }
                html += '</div>';
            } else {
                html += '<div class="small" style="margin-top:8px;">No players connected</div>';
            }
        }
if(showFooter){

    html += '<div class="watchdogFooter">' +
            '<img src="' + window.location.origin + '/logo_bit.png">' +
            '<span>Guarded by WATCHDOG</span>' +
            '</div>';
}

root.innerHTML = html;
    }catch(e){
        const root = document.getElementById('content');
        if(root){ root.innerHTML = '<div class="error">JS Error</div>'; }
    }
}
window.addEventListener('DOMContentLoaded', function(){
    load();
    setInterval(load, 10000);
});
</script>
</body>
</html>
"@

                        Write-WidgetResponse -Response $res -StatusCode 200 -ContentType "text/html; charset=utf-8" -Body $widgetHtml
                        continue
                    }


# --- AUTH / REMOTE CONTROL ---
$cookie = $req.Headers["Cookie"]

$isLocal = ($remoteIP -eq "127.0.0.1" -or $remoteIP -eq "::1")
$isAuthed = ($cookie -match "auth=$authToken")

# BLOCK REMOTE COMPLETELY IF DISABLED
if (-not $allowRemote -and -not $isLocal) {
    $res.StatusCode = 403
    $res.OutputStream.Close()
    continue
}

# FORCE LOGIN FOR ANY REMOTE REQUEST
if (-not $isLocal) {

    # Allow login + widget endpoints without auth
    if (
        $path -ne "/api/login" -and
        $path -notlike "/widget*"
    ) {

        if (-not $isAuthed) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($loginPage)
            $res.ContentType = "text/html"
            $res.OutputStream.Write($bytes,0,$bytes.Length)
            $res.OutputStream.Close()
            continue
        }
    }
}

if ($path -eq "/api/restart-watchdog") {

    try {
        $dataDir = Split-Path -Parent $statusPath
        $restartFlag = Join-Path $dataDir "restart.flag"

        if (-not (Test-Path $dataDir)) {
            New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
        }

        "restart requested $(Get-Date -Format o)" | Set-Content `
            -Path $restartFlag `
            -Encoding UTF8 `
            -Force

        Write-Output "WATCHDOG RESTART FLAG CREATED: $restartFlag"

        $json = @{
            ok = $true
            restartFlag = $restartFlag
        } | ConvertTo-Json -Compress

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $res.StatusCode = 200
        $res.ContentType = "application/json; charset=utf-8"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
    }
    catch {
        Write-Output "RESTART FLAG FAILURE: $($_.Exception.Message)"

        $json = @{
            ok = $false
            error = $_.Exception.Message
        } | ConvertTo-Json -Compress

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $res.StatusCode = 500
        $res.ContentType = "application/json; charset=utf-8"
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
        $res.OutputStream.Close()
    }

    continue
}

# block if remote disabled
if ($path -ne "/api/toggle-remote" -and $path -ne "/api/remote-status") {
    if (-not $allowRemote -and -not $isLocal) {
        $res.StatusCode = 403
        $res.OutputStream.Close()
        continue
    }
}

                    try {
                        switch ($path) {
                            "/" {
                                $bytes = [System.Text.Encoding]::UTF8.GetBytes($dashboardHtml)
                                $res.ContentType = "text/html; charset=utf-8"
                                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                            }
                            "/api/status" {
                                $json = if (Test-Path $statusPath) {
                                    $raw = Get-Content -Path $statusPath -Raw
                                    if ([string]::IsNullOrWhiteSpace($raw)) { "[]" } else { $raw }
                                } else { "[]" }

                                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                                $res.ContentType = "application/json; charset=utf-8"
                                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                            }
							"/api/set-vgui" {
							if ($req.HttpMethod -ne "POST") {
								$res.StatusCode = 405
							} else {
								$reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
								$body = $reader.ReadToEnd()
								$reader.Close()

							Add-Content -Path $queuePath -Value $body

								$bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
								$res.ContentType = "application/json; charset=utf-8"
								$res.OutputStream.Write($bytes, 0, $bytes.Length)
								}
							}

                            "/api/set-lockout" {
                                if ($req.HttpMethod -ne "POST") {
                                    $res.StatusCode = 405
                                } else {
                                    $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                                    $body = $reader.ReadToEnd()
                                    $reader.Close()

                                    Add-Content -Path $queuePath -Value $body

                                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                                    $res.ContentType = "application/json; charset=utf-8"
                                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                                }
                            }
							"/api/set-rcon-disabled" {
								if ($req.HttpMethod -ne "POST") {

									$res.StatusCode = 405

								} else {

									$reader =
										New-Object System.IO.StreamReader(
											$req.InputStream,
											$req.ContentEncoding
										)

									$body = $reader.ReadToEnd()
									$reader.Close()

									Add-Content `
										-Path $queuePath `
										-Value $body

									Write-Output "RCON DISABLE QUEUED: $body"

									$bytes =
										[System.Text.Encoding]::UTF8.GetBytes(
											'{"ok":true}'
										)

									$res.ContentType =
										"application/json; charset=utf-8"

									$res.OutputStream.Write(
										$bytes,
										0,
										$bytes.Length
									)
								}
							}
                            "/api/maps" {
                                $serverName = [string]$req.QueryString["server"]
                                $json = Get-ServerMapListJson -ServerName $serverName -Servers $servers

                                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                                $res.ContentType = "application/json; charset=utf-8"
                                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                            }

							"/api/clear-logs" {

								if ($req.HttpMethod -ne "POST") {

									$res.StatusCode = 405

								} else {

									try {

										$reader = New-Object System.IO.StreamReader($req.InputStream)
										$body = $reader.ReadToEnd()
										$reader.Close()

										$obj = $body | ConvertFrom-Json

										$serverName = [string]$obj.server

										$server = $servers | Where-Object {
											$_.Name -eq $serverName
										} | Select-Object -First 1

										if (-not $server) {
											throw "Server not found"
										}

										$serverRoot = Split-Path -Path ([string]$server.Path) -Parent

										$logFolders = Get-ChildItem `
											-Path $serverRoot `
											-Directory `
											-Recurse `
											-ErrorAction SilentlyContinue |
											Where-Object {
												$_.Name -ieq "logs"
											}

										if (-not $logFolders -or $logFolders.Count -eq 0) {
											throw "No logs folders found"
										}

										$deleted = 0

										foreach ($logsPath in $logFolders) {

											$files = Get-ChildItem `
												-Path $logsPath.FullName `
												-File `
												-ErrorAction SilentlyContinue |
												Sort-Object CreationTime -Descending

											if ($files.Count -le 1) {
												continue
											}

											$deleteTargets = $files | Select-Object -Skip 1

											$useRecycleBin = ($deleteTargets.Count -le 250)

											foreach ($file in $deleteTargets) {

												try {

													if ($useRecycleBin) {

														[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
															$file.FullName,
															[Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
															[Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
														)

													} else {

														Remove-Item `
															-LiteralPath $file.FullName `
															-Force `
															-ErrorAction Stop
													}

													$deleted++

												} catch {

													# silently ignore locked files

												}
											}
										}

										$json = @{
											ok = $true
											deleted = $deleted
										} | ConvertTo-Json -Compress

										$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

										$res.ContentType = "application/json; charset=utf-8"

										$res.Headers.Add("Connection", "close")

										$res.OutputStream.Write($bytes, 0, $bytes.Length)
									} catch {

										$json = @{
											ok = $false
											error = $_.Exception.Message
										} | ConvertTo-Json -Compress

										$bytes = [System.Text.Encoding]::UTF8.GetBytes($json)

										$res.StatusCode = 500
										$res.ContentType = "application/json; charset=utf-8"

										$res.Headers.Add("Connection", "close")

										$res.OutputStream.Write($bytes, 0, $bytes.Length)									}
								}
							}

                            "/api/history" {
                                $json = if (Test-Path $historyPath) {
                                    $raw = Get-Content -Path $historyPath -Raw
                                    if ([string]::IsNullOrWhiteSpace($raw)) { "[]" } else { $raw }
                                } else { "[]" }

                                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                                $res.ContentType = "application/json; charset=utf-8"
                                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                            }
                            "/api/players" {
                                $json = if (Test-Path $playersPath) {
                                    $raw = Get-Content -Path $playersPath -Raw
                                    if ([string]::IsNullOrWhiteSpace($raw)) { "[]" } else { $raw }
                                } else { "[]" }

                                $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
                                $res.ContentType = "application/json; charset=utf-8"
                                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                            }
                            "/api/action" {
                                if ($req.HttpMethod -ne "POST") {
                                    $res.StatusCode = 405
                                } else {
                                    $reader = New-Object System.IO.StreamReader($req.InputStream, $req.ContentEncoding)
                                    $body = $reader.ReadToEnd()
                                    $reader.Close()

                                    Add-Content -Path $queuePath -Value $body
                                    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                                    $res.ContentType = "application/json; charset=utf-8"
                                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                                }
                            }
							"/api/login" {
    if ($req.HttpMethod -ne "POST") {
        $res.StatusCode = 405
    } else {
        $reader = New-Object System.IO.StreamReader($req.InputStream)
        $body = $reader.ReadToEnd()
        $reader.Close()

        try {
            $obj = $body | ConvertFrom-Json

            function Get-Hash {
                param([string]$text)
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
                $hash = $sha.ComputeHash($bytes)
                return ([BitConverter]::ToString($hash) -replace "-","").ToLower()
            }

            $uHash = Get-Hash $obj.user
            $pHash = Get-Hash $obj.pass

            # LOAD CURRENT AUTH FROM FILE (LIVE)
try {
    $authData = Get-Content -Path $using:authFile -Raw | ConvertFrom-Json
    $currentUser = $authData.user
    $currentPass = $authData.pass
} catch {
    $currentUser = "watchd0g"
    $currentPass = "admin123"
}

$currentUserHash = Get-Hash $currentUser
$currentPassHash = Get-Hash $currentPass

if ($uHash -eq $currentUserHash -and $pHash -eq $currentPassHash) {

                $res.Headers.Add("Set-Cookie","auth=$authToken; Path=/; HttpOnly; SameSite=Strict")
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $res.OutputStream.Write($bytes,0,$bytes.Length)

            } else {
                $res.StatusCode = 403
            }

        } catch {
            $res.StatusCode = 500
        }
    }
}
"/api/logout" {
    # rotate token -> invalidates ALL sessions
    $authToken = [guid]::NewGuid().ToString()

    # clear cookie
    $res.Headers.Add("Set-Cookie","auth=; Path=/; Expires=Thu, 01 Jan 1970 00:00:00 GMT")

    $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
    $res.OutputStream.Write($bytes,0,$bytes.Length)
}
"/api/set-auth" {
    if ($req.HttpMethod -ne "POST") {
        $res.StatusCode = 405
    } else {
        $reader = New-Object System.IO.StreamReader($req.InputStream)
        $body = $reader.ReadToEnd()
        $reader.Close()

        try {
            $obj = $body | ConvertFrom-Json

            if ($obj.user.Length -le 8 -and $obj.pass.Length -le 8) {

                $newAuth = @{
                    user = $obj.user
                    pass = $obj.pass
                }

                # SAVE NEW CREDS
                $newAuth | ConvertTo-Json | Set-Content -Path $using:authFile -Encoding UTF8

                # CRITICAL: ROTATE TOKEN HERE
                $authToken = [guid]::NewGuid().ToString()
				# AFTER saving file
				Start-Sleep -Milliseconds 100
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":true}')
                $res.OutputStream.Write($bytes,0,$bytes.Length)

            } else {
                $res.StatusCode = 400
            }

        } catch {
            $res.StatusCode = 500
        }
    }
}
"/api/toggle-remote" {
    $allowRemote = -not $allowRemote

    # rotate token when disabling remote
    if (-not $allowRemote) {
        $authToken = [guid]::NewGuid().ToString()
    }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes("{""remote"":$allowRemote}")
    $res.ContentType = "application/json"
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}
"/api/toggle-master" {

    $current = Get-MasterListEnabled

    $newState = -not $current

    Set-MasterListEnabled -Enabled $newState

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(
        "{""master"":$($newState.ToString().ToLower())}"
    )

    $res.ContentType = "application/json"

    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}
                            "/api/ping" {
                                $res.ContentType = "application/json; charset=utf-8"
                                $bytes = [System.Text.Encoding]::UTF8.GetBytes("{""ok"":true,""ts"":""$((Get-Date).ToString("o"))""}")
                                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                            }
                            "/api/remote-status" {
                                $bytes = [System.Text.Encoding]::UTF8.GetBytes("{""remote"":$($allowRemote.ToString().ToLower())}")
                                $res.ContentType = "application/json; charset=utf-8"
                                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                            }
							"/api/master-status" {

								$enabled = Get-MasterListEnabled

								$bytes = [System.Text.Encoding]::UTF8.GetBytes(
									"{""master"":$($enabled.ToString().ToLower())}"
								)

								$res.ContentType = "application/json; charset=utf-8"

								$res.OutputStream.Write($bytes, 0, $bytes.Length)
							}
                            "/logo.png" {
                                if (Test-Path $logoPath) {
                                    $bytes = [System.IO.File]::ReadAllBytes($logoPath)
                                    $res.ContentType = "image/png"
                                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                                } else {
                                    $res.StatusCode = 404
                                }
                            }
							"/logo_bit.png" {
								$logoBitPath = Join-Path $scriptRoot "img\logo_bit.png"
	
								if (Test-Path $logoBitPath) {
									$bytes = [System.IO.File]::ReadAllBytes($logoBitPath)
									$res.ContentType = "image/png"
									$res.OutputStream.Write($bytes, 0, $bytes.Length)
								} else {
									$res.StatusCode = 404
								}
							}
                            "/on.png" {
                                if (Test-Path $onIconPath) {
                                    $bytes = [System.IO.File]::ReadAllBytes($onIconPath)
                                    $res.ContentType = "image/png"
                                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                                } else {
                                    $res.StatusCode = 404
                                }
                            }
                            "/off.png" {
                                if (Test-Path $offIconPath) {
                                    $bytes = [System.IO.File]::ReadAllBytes($offIconPath)
                                    $res.ContentType = "image/png"
                                    $res.OutputStream.Write($bytes, 0, $bytes.Length)
                                } else {
                                    $res.StatusCode = 404
                                }
                            }
                            default {
                                $res.StatusCode = 404
                            }
                        }
                    } catch {
                        $res.StatusCode = 500
                    } finally {
                        try { $res.OutputStream.Close() } catch {}
                    }
                }
            } finally {
                try { $listener.Stop() } catch {}
                try { $listener.Close() } catch {}
            }
        } | Out-Null

    Start-Sleep -Seconds 1

    $job = Get-Job -Name $jobName -ErrorAction SilentlyContinue
    if ($job -and $job.State -eq "Failed") {
        try {
            $details = Receive-Job -Name $jobName -Keep -ErrorAction SilentlyContinue | Out-String
            Write-Log "Dashboard job failed: $details"
        } catch {
            Write-Log "Dashboard job failed."
        }
    } else {
        Write-Log "Dashboard started on port $dashboardPort"
    }
}