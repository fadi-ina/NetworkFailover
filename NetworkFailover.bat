@echo off
setlocal
REM Network Failover v1.1.0 - one-file EXE builder
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f='%~f0';$s=Get-Content -LiteralPath $f -Raw;$p=('#'+'POWERSHELL_APP');$app=($s -split [regex]::Escape($p),2)[1];$b=(($s -split [regex]::Escape('#'+'BUILDER'),2)[1] -split [regex]::Escape($p),2)[0];& ([scriptblock]::Create($b)) $app $f"
if errorlevel 1 (echo Build failed. See the message above.& pause& exit /b 1)
echo EXE created beside this file.
pause
exit /b 0
#BUILDER
param($appSource,$builderPath)
$ErrorActionPreference='Stop'
try {
 $tokens=$null;$parseErrors=$null
 [void][System.Management.Automation.Language.Parser]::ParseInput($appSource,[ref]$tokens,[ref]$parseErrors)
 if($parseErrors.Count){throw (($parseErrors|ForEach-Object {$_.Message}) -join [Environment]::NewLine)}
 $out=Join-Path (Split-Path -Parent $builderPath) 'NetworkFailover.exe'
 $scriptB64=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($appSource))
 $cs=@'
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Security.Principal;
using System.Threading;
using System.Windows.Forms;
internal static class Program {
 private const string Script="__SCRIPT__";
 [STAThread] static int Main(){
  try {
   if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator)){
    ProcessStartInfo elevate=new ProcessStartInfo(Assembly.GetExecutingAssembly().Location);
    elevate.UseShellExecute=true; elevate.Verb="runas"; elevate.WindowStyle=ProcessWindowStyle.Hidden;
    using(Process elevated=Process.Start(elevate)){return elevated==null?1:0;}
   }
   bool firstInstance;
   using(Mutex mutex=new Mutex(true,"NetworkFailoverMonitorMutex",out firstInstance)){
    if(!firstInstance){MessageBox.Show("Network Failover is already running. Click its notification-area icon, then choose Open monitor.","Network Failover",MessageBoxButtons.OK,MessageBoxIcon.Information);return 0;}
    string data=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),"NetworkFailover");
    Directory.CreateDirectory(data);
    string ps=Path.Combine(data,"NetworkFailover.ps1");
    File.WriteAllBytes(ps,Convert.FromBase64String(Script));
    string exe=Assembly.GetExecutingAssembly().Location;
    string q=((char)34).ToString();
    string args="-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "+q+ps+q+" -ExePath "+q+exe+q;
    ProcessStartInfo start=new ProcessStartInfo("powershell.exe",args);
    start.UseShellExecute=false; start.CreateNoWindow=true; start.WindowStyle=ProcessWindowStyle.Hidden;
    using(Process child=Process.Start(start)){if(child==null)return 1;child.WaitForExit();return child.ExitCode;}
   }
  } catch(Exception error){MessageBox.Show(error.Message,"Network Failover",MessageBoxButtons.OK,MessageBoxIcon.Error);return 1;}
 }
}
'@
 $cs=$cs.Replace('__SCRIPT__',$scriptB64)
 if(Test-Path $out){Remove-Item $out -Force}
 Add-Type -TypeDefinition $cs -Language CSharp -ReferencedAssemblies @('System.dll','System.Core.dll','System.Windows.Forms.dll') -OutputAssembly $out -OutputType WindowsApplication -ErrorAction Stop
 Write-Host "Created $out" -ForegroundColor Green
} catch {Write-Host $_.Exception.Message -ForegroundColor Red;exit 1}
#POWERSHELL_APP
# Network Failover v1.1.0
param([string]$ExePath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$Version='1.1.0'
$Root=Join-Path $env:ProgramData 'NetworkFailover'
$SettingsPath=Join-Path $Root 'settings.json'
$WorkerPath=Join-Path $Root 'worker.ps1'
$StatusPath=Join-Path $Root 'status.json'
$LogPath=Join-Path $Root 'activity.log'
$Task='NetworkFailover'
$MonitorTask='NetworkFailoverMonitor'
New-Item -ItemType Directory -Path $Root -Force|Out-Null
$Worker=@'
$ErrorActionPreference='Stop'
$root=Join-Path $env:ProgramData 'NetworkFailover'
$cfg=Get-Content (Join-Path $root 'settings.json') -Raw|ConvertFrom-Json
$ping=New-Object System.Net.NetworkInformation.Ping
$fails=0;$goods=0;$last='';$gwSeen=$null;$log=Join-Path $root 'activity.log';$statusPath=Join-Path $root 'status.json'
function Write-Diagnostic([string]$Level,[string]$Message){
 try{$line="$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff') [$Level] $Message";Add-Content -LiteralPath $script:log -Value $line -Encoding UTF8;if((Get-Item $script:log).Length -gt 1048576){Set-Content -LiteralPath $script:log -Value (Get-Content $script:log -Tail 300) -Encoding UTF8}}catch{}
}
function State($message,$ok=$false){
 if($message -ne $script:last){Write-Diagnostic 'INFO' $message;$script:last=$message}
 [pscustomobject]@{Version='1.1.0';Updated=(Get-Date).ToString('o');Message=$message;PingOK=$ok;Fails=$script:fails;Goods=$script:goods;Primary=$script:cfg.Primary;Backup=$script:cfg.Backup}|ConvertTo-Json|Set-Content -LiteralPath $script:statusPath -Encoding UTF8
}
while($true){try{
 if(Test-Path (Join-Path $root 'pause.flag')){State 'Paused by user; adapter metrics unchanged';Start-Sleep 1;continue}
 $a=Get-NetAdapter -Name $cfg.Primary -ErrorAction Stop;$b=Get-NetAdapter -Name $cfg.Backup -ErrorAction Stop
 if($b.Status -ne 'Up'){Write-Diagnostic 'WARN' "Backup adapter '$($cfg.Backup)' is $($b.Status); backup may be unavailable"}
 if($a.Status -ne 'Up'){$fails=0;$goods=0;Set-NetIPInterface -InterfaceAlias $cfg.Primary -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 100 -ErrorAction SilentlyContinue;State $(if($b.Status -eq 'Up'){'Primary disconnected; backup link is up'}else{'Primary and backup links are disconnected'})}
 else{
  $g=(Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue|Where-Object NextHop -ne '0.0.0.0'|Select-Object -First 1).NextHop
  if(!$g){$goods=0;$fails=0;Set-NetIPInterface -InterfaceAlias $cfg.Primary -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 100 -ErrorAction SilentlyContinue;State 'Primary has no gateway; backup preferred'}
  else{
   if($g -ne $gwSeen){route delete $cfg.Target 2>$null|Out-Null;route add $cfg.Target mask 255.255.255.255 $g metric 1 if $a.ifIndex|Out-Null;$gwSeen=$g;Write-Diagnostic 'INFO' "Primary gateway is $g; test route refreshed"}
   try{$ok=$ping.Send($cfg.Target,600).Status -eq 'Success'}catch{$ok=$false;Write-Diagnostic 'WARN' "Ping exception: $($_.Exception.Message)"}
   $m=(Get-NetIPInterface -InterfaceAlias $cfg.Primary -AddressFamily IPv4).InterfaceMetric
   if($ok){$fails=0;$goods++;if($m -ne 10 -and $goods -ge 20){Set-NetIPInterface -InterfaceAlias $cfg.Primary -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 10;$m=10;Write-Diagnostic 'INFO' 'Primary metric restored after 20 successful checks'};State $(if($m -eq 10){'Primary healthy; primary preferred'}else{'Primary responding; waiting for recovery'}) $true}
   else{$goods=0;$fails++;if($fails -ge 3 -and $m -ne 100){Set-NetIPInterface -InterfaceAlias $cfg.Primary -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 100;Write-Diagnostic 'WARN' 'Primary metric set to 100 after failed tests'};State $(if($fails -ge 3){'Primary failed; backup preferred'}else{"Primary checks failing $fails/3"})}
  }
 }
}catch{Write-Diagnostic 'ERROR' $_.Exception.ToString();State "Worker error: $($_.Exception.Message)"};Start-Sleep 1}
'@
function Msg($text,$title='Network Failover'){[void][Windows.Forms.MessageBox]::Show($text,$title,'OK','Information')}
function Show-Monitor {$Form.Show();$Form.ShowInTaskbar=$true;$Form.WindowState='Normal';$Form.BringToFront();$Form.Activate()}
function Hide-Monitor {$Form.Hide();$Form.ShowInTaskbar=$false}
function RefreshAdapters {
 $names=@(Get-NetAdapter -ErrorAction SilentlyContinue|Sort-Object Name|Select-Object -ExpandProperty Name)
 $Primary.Items.Clear();$Backup.Items.Clear();foreach($n in $names){[void]$Primary.Items.Add($n);[void]$Backup.Items.Add($n)}
 $i=$Primary.Items.IndexOf('Ethernet');if($i -ge 0){$Primary.SelectedIndex=$i}elseif($names.Count){$Primary.SelectedIndex=0}
 $j=$Backup.Items.IndexOf('Ethernet 2');if($j -ge 0){$Backup.SelectedIndex=$j}elseif($names.Count -gt 1){$Backup.SelectedIndex=1}elseif($names.Count){$Backup.SelectedIndex=0}
}
function UpdateView {
 try{$t=Get-ScheduledTask -TaskName $Task -ErrorAction Stop;$TaskState.Text=[string]$t.State}catch{$TaskState.Text='Not installed'}
 if(-not (Test-Path -LiteralPath $SettingsPath)){$Alive.Text='Not installed';$Alive.ForeColor=[Drawing.Color]::DimGray;$BackupHealth.Text='Not configured - install first';$BackupHealth.ForeColor=[Drawing.Color]::DimGray;$Metric.Text='--';$Last.Text='--';$Activity.Text='Click Install / Save and Start to configure and run failover.';$Log.Text='No installation activity yet.';$tray.Text="Network Failover v$Version - not installed";$Pause.Enabled=$false;$Recover.Enabled=$false;return}
 $Pause.Enabled=$true;$Recover.Enabled=$true;$isPaused=Test-Path (Join-Path $Root 'pause.flag');$Pause.Text=if($isPaused){'Resume checks'}else{'Pause checks'}
 try{$s=Get-Content $StatusPath -Raw|ConvertFrom-Json;$age=((Get-Date)-[datetime]$s.Updated).TotalSeconds;$workerAlive=$TaskState.Text -eq 'Running' -and $age -ge 0 -and $age -lt 15;$Alive.Text=if($isPaused){'Paused by user'}elseif($workerAlive){'Yes - heartbeat current'}else{'No - worker needs attention'};$Activity.Text=[string]$s.Message;$Last.Text=([datetime]$s.Updated).ToString('HH:mm:ss');$tray.Text=if($isPaused){'Network Failover - paused'}elseif($workerAlive){'Network Failover v1.1.0 - running'}else{'Network Failover - check worker'};if($workerAlive -and -not $isPaused){$Alive.ForeColor=[Drawing.Color]::ForestGreen}else{$Alive.ForeColor=[Drawing.Color]::DarkOrange}}catch{$Alive.Text='No heartbeat';$Activity.Text='Waiting for worker';$Last.Text='--';$tray.Text='Network Failover - no heartbeat'}
 try{$s=Get-Content $SettingsPath -Raw|ConvertFrom-Json;$Metric.Text=[string](Get-NetIPInterface -InterfaceAlias ([string]$s.Primary) -AddressFamily IPv4 -ErrorAction Stop).InterfaceMetric}catch{$Metric.Text='Unavailable'}
 try{$s=Get-Content $SettingsPath -Raw|ConvertFrom-Json;$ba=Get-NetAdapter -Name $s.Backup -ErrorAction Stop;$BackupHealth.Text="$($s.Backup) - $($ba.Status)";$BackupHealth.ForeColor=if($ba.Status -eq 'Up'){[Drawing.Color]::ForestGreen}else{[Drawing.Color]::Firebrick}}catch{$BackupHealth.Text="Backup check failed: $($_.Exception.Message)";$BackupHealth.ForeColor=[Drawing.Color]::Firebrick}
 try{$Log.Text=(Get-Content $LogPath -Tail 20) -join [Environment]::NewLine}catch{$Log.Text='No activity yet'}
}
function SetMonitorStartup($enable){
 if(!$enable){Unregister-ScheduledTask -TaskName $MonitorTask -Confirm:$false -ErrorAction SilentlyContinue;return}
 if(!$ExePath -or -not (Test-Path -LiteralPath $ExePath)){throw 'Keep NetworkFailover.exe in a permanent folder and reopen it.'}
 $act=New-ScheduledTaskAction -Execute $ExePath;$tr=New-ScheduledTaskTrigger -AtLogOn -User ([Security.Principal.WindowsIdentity]::GetCurrent().Name)
 $settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
 $pr=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
 Register-ScheduledTask -TaskName $MonitorTask -Action $act -Trigger $tr -Principal $pr -Settings $settings -Force|Out-Null
}
function InstallFailover {
 $primaryName=if($Primary.SelectedItem){[string]$Primary.SelectedItem}else{''};$backupName=if($Backup.SelectedItem){[string]$Backup.SelectedItem}else{''}
 if(!$primaryName -or !$backupName -or $primaryName -eq $backupName){Msg 'Choose two different network adapters.';return}
 $ip=$null;if(-not [Net.IPAddress]::TryParse($Target.Text,[ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){Msg 'Enter a valid IPv4 test address.';return}
 try{
  foreach($n in @($primaryName,$backupName)){$adapter=Get-NetAdapter -Name $n -ErrorAction SilentlyContinue;if(-not $adapter){throw "Adapter not found: $n"};if($adapter.Status -ne 'Up'){throw "Adapter '$n' is $($adapter.Status). Connect it before installing failover."}}
  if([Windows.Forms.MessageBox]::Show("Install using primary '$primaryName' and backup '$backupName'? This changes IPv4 interface metrics.",'Confirm network changes','YesNo','Warning') -ne 'Yes'){return}
  [pscustomobject]@{Primary=$primaryName;Backup=$backupName;Target=$Target.Text}|ConvertTo-Json|Set-Content $SettingsPath -Encoding UTF8
  Set-NetIPInterface -InterfaceAlias $primaryName -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 10;Set-NetIPInterface -InterfaceAlias $backupName -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 50
  Set-Content -LiteralPath $WorkerPath -Value $Worker -Encoding UTF8;Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue
  $action=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$WorkerPath`"";$trigger=New-ScheduledTaskTrigger -AtStartup
  $set=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
  Register-ScheduledTask -TaskName $Task -Action $action -Trigger $trigger -Settings $set -User SYSTEM -RunLevel Highest|Out-Null;Start-ScheduledTask -TaskName $Task
  if($Startup.Checked){SetMonitorStartup $true};UpdateView;Msg 'Failover installed. The worker starts automatically with Windows.'
 }catch{[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Install failed','OK','Error')}
}
function Toggle-Pause {$flag=Join-Path $Root 'pause.flag';if(Test-Path $flag){Remove-Item $flag -Force;Add-Content $LogPath "$(Get-Date -Format s) [INFO] Monitoring resumed"}else{Set-Content $flag 'paused';Add-Content $LogPath "$(Get-Date -Format s) [WARN] Monitoring paused by user"};UpdateView}
function Recover-Primary {try{if(-not(Test-Path $SettingsPath)){throw 'Install failover before forcing recovery.'};$s=Get-Content $SettingsPath -Raw|ConvertFrom-Json;$p=Get-NetAdapter -Name $s.Primary -ErrorAction Stop;if($p.Status -ne 'Up'){throw "Primary adapter is $($p.Status); connect it before recovery."};if([Windows.Forms.MessageBox]::Show("Force primary '$($s.Primary)' to preferred metric 10?",'Confirm recovery','YesNo','Warning') -ne 'Yes'){return};Set-NetIPInterface -InterfaceAlias $s.Primary -AddressFamily IPv4 -AutomaticMetric Disabled -InterfaceMetric 10 -ErrorAction Stop;Remove-Item (Join-Path $Root 'pause.flag') -Force -ErrorAction SilentlyContinue;Add-Content $LogPath "$(Get-Date -Format s) [INFO] User forced primary metric to 10";UpdateView}catch{[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Recovery unavailable','OK','Warning')}}
function Export-Diagnostics {try{$stamp=Get-Date -Format 'yyyyMMdd-HHmmss';$desktop=[Environment]::GetFolderPath('Desktop');if(-not $desktop -or -not(Test-Path $desktop)){$desktop=$Root};$dest=Join-Path $desktop "NetworkFailover-Diagnostics-$stamp.txt";$info=@("Network Failover v1.1.0","Collected: $(Get-Date -Format o)","Windows: $([Environment]::OSVersion.VersionString)",'','--- Adapters ---',(Get-NetAdapter|Format-Table Name,Status,LinkSpeed,ifIndex -AutoSize|Out-String),'--- IPv4 metrics ---',(Get-NetIPInterface -AddressFamily IPv4|Format-Table InterfaceAlias,ConnectionState,AutomaticMetric,InterfaceMetric -AutoSize|Out-String));if(Test-Path $StatusPath){$info+=(Get-Content $StatusPath -Raw)};if(Test-Path $LogPath){$info+=((Get-Content $LogPath -Tail 300)-join [Environment]::NewLine)};$info|Set-Content -LiteralPath $dest -Encoding UTF8;[Windows.Forms.Clipboard]::SetText(($info -join [Environment]::NewLine));Msg "Diagnostics saved to:`r`n$dest`r`n`r`nA copy was placed on the clipboard. Review it before sharing." 'Diagnostics ready'}catch{[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Diagnostics failed','OK','Error')}}
$Form=New-Object Windows.Forms.Form;$Form.Text="Network Failover v$Version";$Form.ClientSize=New-Object Drawing.Size(600,625);$Form.MinimumSize=New-Object Drawing.Size(616,664);$Form.StartPosition='CenterScreen';$Form.Font=New-Object Drawing.Font('Segoe UI',9)
$heading=New-Object Windows.Forms.Label;$heading.Text="Network Failover v$Version";$heading.Font=New-Object Drawing.Font('Segoe UI',17,[Drawing.FontStyle]::Bold);$heading.Location='20,15';$heading.Size='480,36';$Form.Controls.Add($heading)
function AddLabel($text,$x,$y,$w=120){$l=New-Object Windows.Forms.Label;$l.Text=$text;$l.Location=New-Object Drawing.Point($x,$y);$l.Size=New-Object Drawing.Size($w,22);$Form.Controls.Add($l)}
AddLabel 'Primary adapter' 20 65;AddLabel 'Backup adapter' 290 65
$Primary=New-Object Windows.Forms.ComboBox;$Primary.Location='20,88';$Primary.Size='240,25';$Primary.DropDownStyle='DropDownList';$Form.Controls.Add($Primary)
$Backup=New-Object Windows.Forms.ComboBox;$Backup.Location='290,88';$Backup.Size='240,25';$Backup.DropDownStyle='DropDownList';$Form.Controls.Add($Backup)
AddLabel 'Test IPv4 address' 20 124;$Target=New-Object Windows.Forms.TextBox;$Target.Text='1.1.1.1';$Target.Location='20,147';$Target.Size='240,25';$Form.Controls.Add($Target)
$Refresh=New-Object Windows.Forms.Button;$Refresh.Text='Refresh adapters';$Refresh.Location='290,144';$Refresh.Size='130,30';$Form.Controls.Add($Refresh)
$Startup=New-Object Windows.Forms.CheckBox;$Startup.Text='Start monitor with Windows';$Startup.Location='20,184';$Startup.Size='260,25';$Form.Controls.Add($Startup)
$Install=New-Object Windows.Forms.Button;$Install.Text='Install / Save and Start';$Install.Location='20,220';$Install.Size='210,34';$Form.Controls.Add($Install)
$Stop=New-Object Windows.Forms.Button;$Stop.Text='Stop worker';$Stop.Location='245,220';$Stop.Size='120,34';$Form.Controls.Add($Stop)
$Remove=New-Object Windows.Forms.Button;$Remove.Text='Uninstall';$Remove.Location='380,220';$Remove.Size='150,34';$Form.Controls.Add($Remove)
$Pause=New-Object Windows.Forms.Button;$Pause.Text='Pause checks';$Pause.Location='20,264';$Pause.Size='130,32';$Form.Controls.Add($Pause)
$Recover=New-Object Windows.Forms.Button;$Recover.Text='Recover primary';$Recover.Location='160,264';$Recover.Size='145,32';$Form.Controls.Add($Recover)
$Diag=New-Object Windows.Forms.Button;$Diag.Text='Copy diagnostics';$Diag.Location='315,264';$Diag.Size='150,32';$Form.Controls.Add($Diag)
AddLabel 'Worker task' 20 307;$TaskState=New-Object Windows.Forms.Label;$TaskState.Location='150,307';$TaskState.Size='400,22';$Form.Controls.Add($TaskState)
AddLabel 'Worker alive' 20 331;$Alive=New-Object Windows.Forms.Label;$Alive.Location='150,331';$Alive.Size='400,22';$Form.Controls.Add($Alive)
AddLabel 'Backup link' 20 355;$BackupHealth=New-Object Windows.Forms.Label;$BackupHealth.Location='150,355';$BackupHealth.Size='400,22';$Form.Controls.Add($BackupHealth)
AddLabel 'Primary metric' 20 379;$Metric=New-Object Windows.Forms.Label;$Metric.Location='150,379';$Metric.Size='360,22';$Form.Controls.Add($Metric)
AddLabel 'Last update' 20 403;$Last=New-Object Windows.Forms.Label;$Last.Location='150,403';$Last.Size='360,22';$Form.Controls.Add($Last)
AddLabel 'Current activity' 20 427;$Activity=New-Object Windows.Forms.Label;$Activity.Location='150,427';$Activity.Size='400,22';$Form.Controls.Add($Activity)
$Log=New-Object Windows.Forms.TextBox;$Log.Location='20,455';$Log.Size='550,145';$Log.Multiline=$true;$Log.ReadOnly=$true;$Log.ScrollBars='Vertical';$Form.Controls.Add($Log)
$menu=New-Object Windows.Forms.ContextMenuStrip;[void]$menu.Items.Add('Open monitor',$null,{Show-Monitor});[void]$menu.Items.Add('Exit monitor (worker continues)',$null,{$script:Exit=$true;$timer.Stop();$tray.Visible=$false;$Form.Close()})
$tray=New-Object Windows.Forms.NotifyIcon;$tray.Icon=[Drawing.SystemIcons]::Application;if($ExePath -and(Test-Path -LiteralPath $ExePath)){try{$tray.Icon=[Drawing.Icon]::ExtractAssociatedIcon($ExePath)}catch{}};$tray.Text="Network Failover v$Version";$tray.ContextMenuStrip=$menu;$tray.Visible=$true;$tray.Add_Click({param($sender,$e)if($e.Button -eq 'Left'){Show-Monitor}});$tray.Add_DoubleClick({Show-Monitor})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=2000;$timer.Add_Tick({try{UpdateView}catch{}})
$Refresh.Add_Click({RefreshAdapters});$Install.Add_Click({InstallFailover});$Pause.Add_Click({Toggle-Pause});$Recover.Add_Click({Recover-Primary});$Diag.Add_Click({Export-Diagnostics})
$Stop.Add_Click({if([Windows.Forms.MessageBox]::Show('Stop the failover worker?','Confirm stop','YesNo','Warning') -eq 'Yes'){Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue;Add-Content $LogPath "$(Get-Date -Format s) [WARN] Worker stopped by user";UpdateView}})
$script:SuppressStartupEvent=$false;$Startup.Add_CheckedChanged({if($script:SuppressStartupEvent){return};try{SetMonitorStartup $Startup.Checked}catch{[void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Startup option failed','OK','Error');$script:SuppressStartupEvent=$true;$Startup.Checked=$false;$script:SuppressStartupEvent=$false}})
$Remove.Add_Click({if([Windows.Forms.MessageBox]::Show('Remove tasks, restore automatic metrics, and remove the test route?','Confirm uninstall','YesNo','Warning') -eq 'Yes'){try{$s=Get-Content $SettingsPath -Raw|ConvertFrom-Json;Stop-ScheduledTask -TaskName $Task -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $Task -Confirm:$false -ErrorAction SilentlyContinue;Unregister-ScheduledTask -TaskName $MonitorTask -Confirm:$false -ErrorAction SilentlyContinue;foreach($n in @($s.Primary,$s.Backup)){Set-NetIPInterface -InterfaceAlias $n -AddressFamily IPv4 -AutomaticMetric Enabled -ErrorAction SilentlyContinue};route delete $s.Target 2>$null|Out-Null;$script:SuppressStartupEvent=$true;$Startup.Checked=$false;$script:SuppressStartupEvent=$false;UpdateView;Msg 'Tasks removed and automatic metrics restored.'}catch{Msg $_.Exception.Message 'Uninstall failed'}}})
$script:Exit=$false
$Form.Add_Shown({try{RefreshAdapters;try{$s=Get-Content $SettingsPath -Raw|ConvertFrom-Json;$i=$Primary.Items.IndexOf([string]$s.Primary);if($i -ge 0){$Primary.SelectedIndex=$i};$j=$Backup.Items.IndexOf([string]$s.Backup);if($j -ge 0){$Backup.SelectedIndex=$j};$Target.Text=[string]$s.Target}catch{};if(-not(Get-ScheduledTask -TaskName $MonitorTask -ErrorAction SilentlyContinue)){SetMonitorStartup $true};$script:SuppressStartupEvent=$true;$Startup.Checked=[bool](Get-ScheduledTask -TaskName $MonitorTask -ErrorAction SilentlyContinue);$script:SuppressStartupEvent=$false;UpdateView;$timer.Start()}catch{$script:SuppressStartupEvent=$false;Add-Content -LiteralPath (Join-Path $Root 'ui-error.log') -Value ("$(Get-Date -Format o)`r`n$($_.ScriptStackTrace)`r`n$($_.Exception.ToString())") -ErrorAction SilentlyContinue;[void][Windows.Forms.MessageBox]::Show("Startup error: $($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)",'Network Failover startup error','OK','Error')}})
$Form.Add_FormClosing({param($sender,$e)if(-not $script:Exit){$e.Cancel=$true;Hide-Monitor;$tray.ShowBalloonTip(3000,'Network Failover','The monitor is still running. Click its notification-area icon to reopen it.',[Windows.Forms.ToolTipIcon]::Info)}})
[void]$Form.ShowDialog();$timer.Dispose();$tray.Visible=$false;$tray.Dispose();$menu.Dispose();$Form.Dispose()

