#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <steamworks>

public Plugin myinfo =
{
    name = "Watchdog Federation",
    author = "dr.N0",
    description = "Watchdog Federation Heartbeat",
    version = "2.0.0",
    url = "http://drn0.site.nfoservers.com/hub/drn0/to0lb0x/watchdog/index.php"
};

ConVar g_Enabled;
ConVar g_MasterUrl;
ConVar g_ApiKey;
ConVar g_Node;
ConVar g_ServerName;
ConVar g_Region;
ConVar g_Interval;

Handle g_Timer = null;

public void OnPluginStart()
{
    g_Enabled = CreateConVar(
        "sm_watchdog_enabled",
        "1"
    );

    g_MasterUrl = CreateConVar(
        "sm_watchdog_master_url",
        "http://drn0.site.nfoservers.com/hub/drn0/to0lb0x/watchdog/masterlist.php"
    );

	g_ApiKey = CreateConVar(
		"sm_watchdog_api_key",
		"SDW_26_V2_NML_H01OBWOME301DW5D10D99ANH60660"
	);

    g_Node = CreateConVar(
        "sm_watchdog_node",
        "dr.N0s WATCHDOG"
    );

	g_ServerName = CreateConVar(
		"sm_watchdog_name",
		""
	);

    g_Region = CreateConVar(
        "sm_watchdog_region",
        "usa"
    );

    g_Interval = CreateConVar(
        "sm_watchdog_interval",
        "30.0"
    );

    AutoExecConfig(
        true,
        "watchdog_heartbeat"
    );

	HookConVarChange(
		g_Enabled,
		OnWatchdogToggle
	);

    RegAdminCmd(
        "sm_watchdog_test",
        Command_Test,
        ADMFLAG_ROOT
    );

    LogMessage("[WATCHDOG] Plugin loaded");
}

public void OnMapStart()
{
    LogMessage(
        "[WATCHDOG] Map started, rebuilding heartbeat timer"
    );

    CreateTimer(
        5.0,
        Timer_DelayedStart
    );
}

public void OnWatchdogToggle(
    ConVar convar,
    const char[] oldValue,
    const char[] newValue
)
{
    if (!g_Enabled.BoolValue)
    {
        if (g_Timer != null)
        {
            KillTimer(g_Timer);
            g_Timer = null;
        }

        LogMessage(
            "[WATCHDOG] Heartbeat disabled"
        );

        return;
    }

    LogMessage(
        "[WATCHDOG] Heartbeat enabled"
    );

    StartHeartbeatTimer();
}

public Action Timer_DelayedStart(
    Handle timer
)
{
    if (!g_Enabled.BoolValue)
    {
        LogMessage(
            "[WATCHDOG] Heartbeat disabled, timer not started"
        );

        return Plugin_Stop;
    }

    StartHeartbeatTimer();

    LogMessage(
        "[WATCHDOG] Heartbeat timer started"
    );

    return Plugin_Stop;
}

void StartHeartbeatTimer()
{
    if (g_Timer != null)
    {
        KillTimer(g_Timer);
    }

    float interval = g_Interval.FloatValue;

    if (interval < 10.0)
    {
        interval = 10.0;
    }

	g_Timer = CreateTimer(
		interval,
		Timer_Heartbeat,
		_,
		TIMER_REPEAT
	);
}

public Action Timer_Heartbeat(
    Handle timer
)
{
    if (!g_Enabled.BoolValue)
    {
        LogMessage(
            "[WATCHDOG] Heartbeat timer stopped"
        );

        g_Timer = null;

        return Plugin_Stop;
    }

    SendHeartbeat();

    return Plugin_Continue;
}

public Action Command_Test(
    int client,
    int args
)
{
    SendHeartbeat();

    if (client > 0)
    {
        ReplyToCommand(
            client,
            "[WATCHDOG] Heartbeat sent."
        );
    }
    else
    {
        PrintToServer(
            "[WATCHDOG] Heartbeat sent."
        );
    }

    return Plugin_Handled;
}

void SendHeartbeat()
{

	char serverName[64];

	g_ServerName.GetString(
		serverName,
		sizeof(serverName)
	);

	TrimString(serverName);

	if (serverName[0] == '\0')
	{
		LogError(
			"[WATCHDOG] sm_watchdog_name is empty"
		);

		return;
	}

    char json[8192];

    BuildHeartbeatJson(
        json,
        sizeof(json)
    );

    char url[512];
    char apiKey[256];

    g_MasterUrl.GetString(
        url,
        sizeof(url)
    );

	g_ApiKey.GetString(
		apiKey,
		sizeof(apiKey)
	);

    Handle request = SteamWorks_CreateHTTPRequest(
        k_EHTTPMethodPOST,
        url
    );

    if (request == INVALID_HANDLE)
    {
        LogError("[WATCHDOG] Failed creating HTTP request");
        return;
    }

    SteamWorks_SetHTTPRequestHeaderValue(
        request,
        "Content-Type",
        "application/json"
    );

    SteamWorks_SetHTTPRequestHeaderValue(
        request,
        "X-WATCHDOG-KEY",
        apiKey
    );

    SteamWorks_SetHTTPRequestRawPostBody(
        request,
        "application/json",
        json,
        strlen(json)
    );

    SteamWorks_SetHTTPCallbacks(
        request,
        OnHTTPComplete
    );

	if (!SteamWorks_SendHTTPRequest(request))
	{
		LogError("[WATCHDOG] Failed sending HTTP request");
	}
}

public int OnHTTPComplete(
    Handle request,
    bool failure,
    bool requestSuccessful,
    EHTTPStatusCode statusCode,
    any data
)
{
    if (failure || !requestSuccessful)
    {
        LogError(
            "[WATCHDOG] HTTP request failed"
        );
    }
    else
    {
        LogMessage(
            "[WATCHDOG] Heartbeat sent (%d)",
            statusCode
        );
    }

    return 0;
}

void BuildHeartbeatJson(
    char[] output,
    int maxlen
)
{
	char hostname[256];
	char map[128];
	char ip[64];
	char portStr[16];
	char node[128];
	char serverName[64];
	char region[64];
	

    GetConVarString(
        FindConVar("hostname"),
        hostname,
        sizeof(hostname)
    );

    GetCurrentMap(
        map,
        sizeof(map)
    );

    GetServerIP(
        ip,
        sizeof(ip)
    );

    GetServerPort(
        portStr,
        sizeof(portStr)
    );

    g_Node.GetString(
        node,
        sizeof(node)
    );

    g_ServerName.GetString(
        serverName,
        sizeof(serverName)
    );

    g_Region.GetString(
        region,
        sizeof(region)
    );
	
    int humans = 0;
    int bots = 0;

    char players[4096];
    players[0] = '\0';

    bool first = true;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))
        {
            continue;
        }

        bool isBot = IsFakeClient(i);

        if (isBot)
        {
            bots++;
        }
        else
        {
            humans++;
        }

        char name[128];
        char escapedName[256];

        GetClientName(
            i,
            name,
            sizeof(name)
        );

        JsonEscape(
            name,
            escapedName,
            sizeof(escapedName)
        );

        char steamId[64];

        if (isBot)
        {
            strcopy(
                steamId,
                sizeof(steamId),
                "BOT"
            );
        }
        else
        {
            if (!GetClientAuthId(
                i,
                AuthId_Steam3,
                steamId,
                sizeof(steamId),
                true
            ))
            {
                strcopy(
                    steamId,
                    sizeof(steamId),
                    "UNKNOWN"
                );
            }
        }

        int ping = 0;

        if (!isBot)
        {
            ping = RoundToNearest(
                GetClientAvgLatency(
                    i,
                    NetFlow_Both
                ) * 1000.0
            );
        }

        char connected[32];

        FormatConnectionTime(
            GetClientTime(i),
            connected,
            sizeof(connected)
        );

        char row[512];

        Format(
            row,
            sizeof(row),
            "%s{\"name\":\"%s\",\"steamId\":\"%s\",\"ping\":%d,\"connected\":\"%s\",\"bot\":%s}",
            first ? "" : ",",
            escapedName,
            steamId,
            ping,
            connected,
            isBot ? "true" : "false"
        );

        StrCat(
            players,
            sizeof(players),
            row
        );

        first = false;
    }

    int maxPlayers = MaxClients;

    char escapedHost[512];

    JsonEscape(
        hostname,
        escapedHost,
        sizeof(escapedHost)
    );

    int unixTime = GetTime();

	Format(
		output,
		maxlen,
		"[{\"serverId\":\"%s:%s\",\"node\":\"%s\",\"name\":\"%s\",\"region\":\"%s\",\"hostname\":\"%s\",\"map\":\"%s\",\"players\":\"%d humans, %d bots (%d max)\",\"onlinePlayers\":[%s],\"status\":\"ONLINE\",\"ip\":\"%s\",\"port\":%s,\"updated\":%d,\"watchdogPlugin\":true}]",
		ip,
		portStr,
		node,
		serverName,
		region,
		escapedHost,
		map,
		humans,
		bots,
		maxPlayers,
		players,
		ip,
		portStr,
		unixTime
	);
}

void GetServerIP(
    char[] buffer,
    int maxlen
)
{
    int hostip = GetConVarInt(
        FindConVar("hostip")
    );

    Format(
        buffer,
        maxlen,
        "%d.%d.%d.%d",
        (hostip >> 24) & 255,
        (hostip >> 16) & 255,
        (hostip >> 8) & 255,
        hostip & 255
    );
}

void GetServerPort(
    char[] buffer,
    int maxlen
)
{
    ConVar port = FindConVar(
        "hostport"
    );

    if (port == null)
    {
        port = FindConVar("port");
    }

    IntToString(
        port.IntValue,
        buffer,
        maxlen
    );
}

void FormatConnectionTime(
    float seconds,
    char[] buffer,
    int maxlen
)
{
    int total = RoundToFloor(seconds);

    int hours = total / 3600;
    int mins = (total % 3600) / 60;

    Format(
        buffer,
        maxlen,
        "%02d:%02d",
        hours,
        mins
    );
}

void JsonEscape(
    const char[] input,
    char[] output,
    int maxlen
)
{
    output[0] = '\0';

    char temp[2];

    for (int i = 0; input[i] != '\0'; i++)
    {
        if (input[i] == '"' || input[i] == '\\')
        {
            StrCat(
                output,
                maxlen,
                "\\"
            );
        }

        temp[0] = input[i];
        temp[1] = '\0';

        StrCat(
            output,
            maxlen,
            temp
        );
    }
}