# -----------------------------------------------------------------------
# --- Source Dedicated WATCHDOG by dr.N0 --------------------------------
# --- http://drn0.site.nfoservers.com/hub/drn0/to0lb0x/watchdog/index.php
# --- Visit the WATCHDOG MASTER LIST at the official WATCHDOG website.
# -----------------------------------------------------------------------

# --- Server Definitions File ---
# Set RconPassword for each server to enable player monitoring and RCON commands.
#
# Set Region by this strict list of names
# ---
# afghanistan-armenia-australia-bangladesh-barbados-belgium-bhutan-brazil-cambodia
# canada-cuba-czech_republic-denmark-dontknow-egypt-england-estonia-ethiopia
# fiji-finland-france-greece-hongkong-iceland-india-ireland-israel-italy-jamaica
# japan-kyrgyzstan-malaysia-mexico-nepal-netherlands-nicaragua-norway-pakistan
# poland-portugal-puertorico-romania-russia-seychelles-singapore-southafrica
# spain-sweden-switzerland-taiwan-tibet-trinidadandtobago-uk-ukraine-usa-ussr
# wales-yugoslavia-zimbabwe - these names correspond to the flags images.
# --- Server Definitions --

# --- Master Server Config ---
$masterServerEnabled = $true
# --- Name your watchdog Node --- 
$watchdogNodeName = "My WATCHDOG Node"

# --- do not touch root directories ---
$masterHeartbeatFile = Join-Path $scriptRoot "data\master_heartbeat.json"
# --- do not touch master server url ---
$masterServerUrl = "http://drn0.site.nfoservers.com/hub/drn0/to0lb0x/watchdog/masterlist.php"
# --- do not touch master api key ---
$masterApiKey = "SDW_26_V2_NML_H01OBWOME301DW5D10D99ANH60660"

# --- Start server definition between @{ and }, | only ending code blocks
# --- end in a single closing bracket }
# --- path exe and exe must match! port and rcon port must match!
# --- must contain actual servers rcon password set in server.cfg!
# --- Args should include -console -game +map -ip -port +exec server.cfg
$servers = @(
    @{
        Name = "sample1"
        Path = "C:\servers\sample1\srcds.exe "
		Exe = "srcds"
		Region = "dontknow"
        Args = "-console -game cstrike +map cs_assault -ip 06.606.66.60 -port 27066 +exec server.cfg"
        Port = 27066
		RconHost = "06.606.66.60"
        RconPort = 27066
        RconPassword = "currentpassword"
    },
    @{
        Name = "sample2"
        Path = "C:\servers\sample2\srcds.exe "
		Exe = "srcds"
		Region = "dontknow"
        Args = "-console -game cure +map cbe_bunker -ip 06.606.66.60 -port 27033 +exec server.cfg"
        Port = 27033
		RconHost = "06.606.66.60"
        RconPort = 27033
        RconPassword = "currentpassword"
		
    },
    @{
        Name = "sample3"
        Path = "C:\servers\sample3\othersrcds.exe"
		Exe = "othersrcds"
		Region = "dontknow"
        Args = "-console -game dab +map da_megachat -ip 06.606.66.60 -port 27099 +exec server.cfg"
        Port = 27099
		RconHost = "06.606.66.60"
        RconPort = 27099
        RconPassword = "currentpassword"
    }
)