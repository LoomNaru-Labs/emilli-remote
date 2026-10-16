-- Emilli: every path is quoted, because the app name ("RustDesk" here) may contain a space.
set daemon_plist to quoted form of "/Library/LaunchDaemons/com.carriez.RustDesk_service.plist"
set agent_plist to quoted form of "/Library/LaunchAgents/com.carriez.RustDesk_server.plist"

set sh1 to "launchctl unload -w " & daemon_plist & ";"
set sh2 to "/bin/rm " & daemon_plist & ";"
set sh3 to "/bin/rm " & agent_plist & ";"

set sh to sh1 & sh2 & sh3
do shell script sh with prompt "RustDesk wants to unload daemon" with administrator privileges