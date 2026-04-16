=====================================================
==    dr.N0s SOURCE DEDICATED SERVER WATCHDOG      ==
==		  DEVELOPERS BETA: version. 1.5            ==
==				  april 7th 2026                   ==
=====================================================
*For USE with Windows Server 2019*

This is a Source Engine Dedicated server application 
macros program that enables extended control over
any active listed srcds application. If the servers listed
are not active the macros will systematically restart the 
applications via -console back into an online state.

------------------------------------------------------
quick install
step 1 -----------------------------------------------
in PowerShell Run as Administrator
netsh http add urlacl url=http://+:8080/ user=Everyone
and
New-NetFirewallRule -DisplayName "Watchdog Dashboard" -Direction Inbound -LocalPort 8080 -Protocol TCP -Action Allow

step 2 -----------------------------------------------
edit server definition code blocks
    @{
        Name = "sample1"
        Path = "C:\servers\sample1\srcds.exe "
		Exe = "srcds"
        Args = "-console -game cstrike +map cs_assault -ip 06.606.66.60 -port 27066 +exec server.cfg"
        Port = 27066
		RconHost = "06.606.66.60"
        RconPort = 27066
        RconPassword = "currentpassword"
    }

step 3 -------------------------------------------------
Run watchdog.ps1 as Administrator [Please wait -+5 minutes]
console shows starting watchdog.

step 4 -------------------------------------------------
open internet browser
dashboard connection display-----------
http://localhost:8080/ for web view from server itself
or
ServerIP:8080 e.g 11.234.56.78:8080 for web view from internet anywhere

step 5 --------------------------------------------------
Refresh dashboard until loading completed and fully displayed
on full load program refreshes the dashboard automatically every
5 seconds.
----------------------------------------------------------

To keep window open after crash use this example
open powershell and run
powershell -NoExit -ExecutionPolicy Bypass -File "C:\Users\Administrator\Desktop\watchdog.ps1"

powered by Power Shell on Windows Server 2019