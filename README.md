Network Failover
Network Failover is a lightweight Windows utility that monitors a primary network adapter and automatically prefers a backup adapter when primary connectivity fails. It combines a background PowerShell worker with a simple desktop monitor, system-tray access, diagnostics, and automatic startup.

Built with Windows PowerShell and Windows Forms, it requires no third-party runtime or installer. The included one-file builder compiles a standalone NetworkFailover.exe launcher using the .NET Framework already available in Windows.

Features
Automatic failover between two network adapters using IPv4 interface metrics
Continuous primary-link monitoring through a configurable IPv4 test address
Primary-link recovery after 20 consecutive successful checks
Failover after 3 consecutive failed checks
Backup adapter connection-status monitoring
Background worker heartbeat and current-activity display
Pause and resume connectivity checks without uninstalling
Manually restore the primary adapter's preferred metric
System-tray monitor with left-click and double-click reopening
Closing the window keeps the monitor running in the background
Optional automatic monitor startup at Windows logon
Worker starts automatically at Windows startup after installation
Export detailed diagnostics to a text file and the clipboard
Uninstall option that removes scheduled tasks and restores automatic adapter metrics
Single BAT file containing both the application and its EXE builder
Requirements
Windows 10 or Windows 11
Windows PowerShell 5.1
.NET Framework 4.x with the Windows PowerShell and .NET compiler components included in Windows
Administrator privileges
Two distinct IPv4 network adapters that can be connected simultaneously
A reachable IPv4 address for connectivity testing
The program is designed for Windows PowerShell 5.1 (powershell.exe), not PowerShell 7 (pwsh.exe).

Download and Build
Download NetworkFailover-OneFile.bat from the Releases page or clone this repository.
Place the BAT file in a permanent, writable folder.
Run the BAT file and allow the requested administrator permission.
The builder validates the embedded PowerShell source and creates NetworkFailover.exe beside the BAT file.
Run NetworkFailover.exe as administrator.
The EXE is a small native launcher. It writes the embedded application to %ProgramData%\NetworkFailover\NetworkFailover.ps1 and starts it with Windows PowerShell in hidden-window mode. PowerShell remains a required Windows component; the EXE does not embed the PowerShell runtime.

Configure and Install
Select the Primary adapter.
Select a different Backup adapter.
Enter an IPv4 Test address. The default is 1.1.1.1.
Make sure both adapters are connected and have valid network configurations.
Click Install / Save and Start.
Confirm the network changes.
Installation writes the worker and settings, assigns the preferred IPv4 metrics, and registers a scheduled task that runs the worker as SYSTEM at Windows startup.

The monitor is also registered to start automatically when the current Windows user logs on. Clear Start monitor with Windows if you do not want this behavior.

How Failover Works
The worker checks adapter status, the primary default gateway, and connectivity to the configured test address approximately once per second.

Preferred metrics
State	Primary IPv4 metric	Backup IPv4 metric
Normal operation	10	50
Primary failure	100	50
Windows normally prefers the route with the lower effective interface metric. Changing the metric encourages Windows to use the backup adapter without disabling the primary adapter.

Failure detection
Failover can be triggered when the primary adapter is disconnected, has no usable default gateway, or fails three consecutive connectivity tests. The primary metric is then changed to 100, making the backup metric of 50 preferable.

Automatic recovery
When the primary adapter is connected and its gateway and test address are reachable, the worker waits for 20 consecutive successful checks before restoring the primary metric to 10. This delay helps prevent rapid switching on an unstable connection.

To test the primary connection rather than the current default route, the worker creates a host route for the configured test IPv4 address through the primary adapter's gateway.

Warning: Changing interface metrics affects how Windows routes traffic. Test the utility on a non-critical system first. Incorrect adapter selection, gateway configuration, or overlapping networks can disrupt connectivity, VPN connections, or remote access.

Monitor Controls
Control	Purpose
Refresh adapters	Reload the available Windows network adapters
Install / Save and Start	Save configuration, set metrics, and register/start the worker
Stop worker	Stop the scheduled failover task until it is started again
Uninstall	Remove the scheduled tasks, delete the test route, and restore automatic metrics
Pause checks	Suspend worker checks while leaving adapter metrics unchanged
Resume checks	Resume normal monitoring
Recover primary	Manually restore the primary metric to 10 after confirming its link is up
Copy diagnostics	Save a diagnostic report and copy its contents to the clipboard
Background and Tray Operation
Closing the monitor window does not stop failover monitoring. The window is hidden and the application remains available through its notification-area icon.

Click or double-click the tray icon to reopen the monitor.
Use Open monitor in the tray menu.
Use Exit monitor (worker continues) to close the desktop monitor and remove its tray icon while leaving the worker running.
If Windows hides the icon, click the ^ overflow arrow beside the system clock.
Keep NetworkFailover.exe in a permanent folder. Moving, renaming, or deleting it after setup can break the monitor's automatic-logon task. Reopen the EXE from its new location to register the updated path.

Data and Logs
Runtime files are stored in:

sh

Copy
C:\ProgramData\NetworkFailover\
Important files include:

File	Contents
settings.json	Selected adapters and test IPv4 address
worker.ps1	Installed background worker
status.json	Latest heartbeat and worker activity
activity.log	Worker and monitor events
NetworkFailover.ps1	Embedded desktop application written by the EXE
ui-error.log	Desktop startup diagnostics, if an error occurs
Scheduled tasks:

NetworkFailover — runs the worker at Windows startup
NetworkFailoverMonitor — starts the desktop monitor at user logon
Diagnostics and Privacy
Diagnostics can include adapter names, link status, link speed, interface indexes, IPv4 metrics, task state, worker status, and activity logs. The report is saved to the desktop when available, or to the program-data directory otherwise, and is also copied to the clipboard.

Review the report before sharing it publicly. Do not upload logs or diagnostic reports containing private network information.

This project contains no telemetry or analytics and does not upload diagnostics. Network connectivity tests are sent only to the IPv4 address configured by the user; Windows scheduled tasks and normal operating-system networking also apply.

Uninstall
Click Uninstall in the monitor and confirm the operation. This removes the scheduled tasks, restores automatic IPv4 metrics on the configured adapters, and deletes the worker's test route.

The application intentionally leaves its configuration and logs in %ProgramData%\NetworkFailover for inspection. After exiting the monitor, you may delete that directory manually if you no longer need them. Delete the BAT and EXE files separately.

Troubleshooting
Adapters are missing: Click Refresh adapters and confirm both adapters appear in Windows Network Connections.
Worker is not alive: Confirm the NetworkFailover scheduled task is running and review activity.log.
Failover does not occur: Verify both links work independently and that the test address is reachable through the primary adapter.
Monitor disappeared: Look for its icon in the notification area or the ^ overflow menu. The worker may still be running.
Automatic monitor startup fails: Reopen the EXE as administrator and verify that its path has not changed.
Remote connection lost: Use another network path or local access to restore automatic interface metrics, then review the selected adapters and routes.
Security Notes
The application requires administrator privileges because it changes IPv4 interface metrics, adds a host route, and registers elevated scheduled tasks. The failover worker runs as SYSTEM.

Download releases only from a trusted source and review the PowerShell source before building. The connectivity test uses ICMP ping; a firewall or test service that blocks ICMP can cause the primary link to appear unavailable.

Project Scope
This utility provides metric-based route preference and connectivity monitoring. It is not a firewall, VPN, bonding solution, load balancer, or guarantee of uninterrupted connectivity. Existing sessions may still need to reconnect when Windows changes routes.

Version
Current version: 1.1.0

