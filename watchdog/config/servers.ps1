# --- Server Definitions ---
# Set RconPassword for each server to enable player monitoring and custom RCON commands.
$servers = @(
    @{
        Name = "sample1"
        Path = "C:\servers\sample1\srcds.exe "
		Exe = "srcds"
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
        Args = "-console -game dab +map da_megachat -ip 06.606.66.60 -port 27099 +exec server.cfg"
        Port = 27099
		RconHost = "06.606.66.60"
        RconPort = 27099
        RconPassword = "currentpassword"
    }
)