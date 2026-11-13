# Used by the installer. Creates (or removes) two scheduled tasks that start Remote Mouse with the
# highest rights, so it can also control administrator windows - without a UAC question every time.
#   "Remote Mouse Server"         starts quietly in the background (optionally when you sign in to Windows)
#   "Remote Mouse Server (open)"  opens the window of the running program (used by the shortcuts)
param([string]$Exe, [int]$AtLogon = 0, [switch]$Remove)

$ErrorActionPreference = 'Stop'
$main = 'Remote Mouse Server'
$open = 'Remote Mouse Server (open)'

if ($Remove) {
    foreach ($n in @($main, $open)) { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
    exit 0
}

$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
$action = New-ScheduledTaskAction -Execute $Exe -Argument '--minimized'
if ($AtLogon -eq 1) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    Register-ScheduledTask -TaskName $main -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
} else {
    Register-ScheduledTask -TaskName $main -Action $action -Principal $principal -Settings $settings -Force | Out-Null
}

# a second start only asks the running program to show its window, so several may run at once
$settings2 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances Parallel
$action2 = New-ScheduledTaskAction -Execute $Exe
Register-ScheduledTask -TaskName $open -Action $action2 -Principal $principal -Settings $settings2 -Force | Out-Null
