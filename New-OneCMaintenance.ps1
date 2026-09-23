#requires -Version 7.0
<#
Generate a REVIEWABLE SQL Agent maintenance package. Default: local files only.
-Apply installs DISABLED jobs after confirmation; it never enables or starts jobs.
PILOT: Windows/SQL integration not yet validated. Native T-SQL, not SSIS plans.
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][ValidateCount(1,20)][string[]]$Database,
    [string]$BackupDirectory,
    [string]$SqlInstance = '.',
    [System.Management.Automation.PSCredential]$SqlCredential,
    [switch]$TrustServerCertificate,
    [ValidateRange(0,60)][int]$LogBackupMinutes = 0,
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')][string]$FullBackupTime = '01:00',
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')][string]$StatisticsTime = '03:00',
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')][string]$CheckDbTime = '04:00',
    [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')][string]$CheckDbDay = 'Sunday',
    [string]$OperatorName = '',
    [string]$OutputDirectory = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'perf-1c/maintenance'),
    [switch]$NonInteractive,
    [switch]$Apply
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
function Get-TextHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant() }
    finally { $sha.Dispose() }
}
function Quote-SqlLiteral([string]$Text) { return "N'"+$Text.Replace("'","''")+"'" }
function Quote-SqlName([string]$Text) { return '['+$Text.Replace(']',']]')+']' }
function Assert-DatabaseName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 128 -or $Name -match '[\x00-\x1F]') { throw 'Invalid database name.' }
    if ($Name -in @('master','model','msdb','tempdb')) { throw 'This package accepts explicit USER databases only. Back up system databases separately.' }
}
if ($LogBackupMinutes -gt 0 -and $LogBackupMinutes -lt 5) { throw 'Use LOG backup frequency 5-60 minutes, or 0 (no managed LOG job).' }
foreach ($db in $Database) { Assert-DatabaseName $db }
if (@($Database | Sort-Object -Unique).Count -ne $Database.Count) { throw 'Duplicate database names are not allowed.' }
if (-not $BackupDirectory) {
    if ($NonInteractive) { throw 'Specify -BackupDirectory: existing path visible to the SQL Server service.' }
    $BackupDirectory = Read-Host 'Existing backup directory visible to SQL Server (prefer separate backup storage)'
}
# Do not use Test-Path: a remote SQL host/service has different paths and permissions.
if ($BackupDirectory.Length -gt 170 -or $BackupDirectory -match '[\x00-\x1F*?]' -or
    $BackupDirectory -notmatch '^(?:[A-Za-z]:\\|\\\\[^\\]+\\[^\\]+)') {
    throw 'Use an absolute Windows drive or UNC backup directory (maximum 170 characters, no controls/wildcards).'
}
$BackupDirectory = $BackupDirectory.TrimEnd('\')+'\'
if ($OperatorName.Length -gt 128 -or $OperatorName -match '[\x00-\x1F]') { throw 'Invalid operator name.' }
$dayBits = @{Sunday=1;Monday=2;Tuesday=4;Wednesday=8;Thursday=16;Friday=32;Saturday=64}
$specs = @()
foreach ($db in $Database) {
    $dbValue=Quote-SqlLiteral $db; $dbName=Quote-SqlName $db
    $tag=(Get-TextHash $db).Substring(0,16)
    $guard = @"
SET NOCOUNT ON; SET DEADLOCK_PRIORITY LOW; SET LOCK_TIMEOUT 10000;
IF DB_ID($dbValue) IS NULL OR EXISTS (SELECT 1 FROM sys.databases WHERE name=$dbValue AND (state<>0 OR is_read_only=1 OR replica_id IS NOT NULL))
    THROW 51000, 'Database must exist, be ONLINE/read-write, and not be an AG database.', 1;
"@
    $kinds=@('FULL','STATS','CHECKDB')
    if ($LogBackupMinutes -gt 0) { $kinds+= 'LOG' }
    foreach ($kind in $kinds) {
        if ($kind -in @('FULL','LOG')) {
            $ext=if($kind -eq 'LOG'){'trn'}else{'bak'}
            $prefix=Quote-SqlLiteral ($BackupDirectory+'perf1c_'+$tag+'_'+$kind+'_')
            $command=$guard+"`nDECLARE @path nvarchar(260)=$prefix+CONVERT(char(8),GETUTCDATE(),112)+N'_'+REPLACE(CONVERT(char(8),GETUTCDATE(),108),N':',N'')+N'_'+CONVERT(nvarchar(36),NEWID())+N'.$ext';`n"
            if ($kind -eq 'LOG') {
                $command+="IF EXISTS (SELECT 1 FROM sys.databases WHERE name=$dbValue AND recovery_model=3) THROW 51001, 'LOG backup requires FULL or BULK_LOGGED. Recovery model is not changed automatically.', 1;`n"
            }
            $verb=if($kind -eq 'LOG'){'LOG'}else{'DATABASE'}
            $command+="BACKUP $verb $dbName TO DISK=@path WITH CHECKSUM, COMPRESSION, NOINIT;`nRESTORE VERIFYONLY FROM DISK=@path WITH CHECKSUM;"
            $time=if($kind -eq 'LOG'){0}else{[int]($FullBackupTime.Replace(':','')+'00')}
            $freq=4; $freqInterval=1; $subtype=if($kind -eq 'LOG'){4}else{1}; $subinterval=if($kind -eq 'LOG'){$LogBackupMinutes}else{0}
        } else {
            $body=if($kind -eq 'STATS') {
                "DECLARE @stats_result int; EXEC @stats_result=$dbName.sys.sp_updatestats @resample='NO'; IF @stats_result<>0 THROW 51002, 'Statistics update failed.', 1;"
            } else { "DBCC CHECKDB ($dbValue) WITH NO_INFOMSGS, ALL_ERRORMSGS, MAXDOP=2;" }
            # All jobs use master, so this lock serializes heavy work across databases.
            # No global lock for LOG backups: do not block them behind CHECKDB/statistics.
            $command=$guard+@"

DECLARE @lock int;
EXEC @lock=sys.sp_getapplock @Resource=N'perf-1c:heavy-maintenance',@LockMode=N'Exclusive',@LockOwner=N'Session',@LockTimeout=0;
IF @lock<0 THROW 51003, 'Another perf-1c heavy maintenance job is running; retry or reschedule.', 1;
BEGIN TRY
    $body
    EXEC sys.sp_releaseapplock @Resource=N'perf-1c:heavy-maintenance',@LockOwner=N'Session';
END TRY
BEGIN CATCH
    EXEC sys.sp_releaseapplock @Resource=N'perf-1c:heavy-maintenance',@LockOwner=N'Session';
    THROW;
END CATCH;
"@
            $clock=if ($kind -eq 'STATS') { $StatisticsTime } else { $CheckDbTime }
            $time=[int]($clock.Replace(':','')+'00')
            $freq=if($kind -eq 'STATS'){4}else{8}; $freqInterval=if($kind -eq 'STATS'){1}else{$dayBits[$CheckDbDay]}; $subtype=1; $subinterval=0
        }
        $name='perf-1c-'+$tag+'-'+$kind
        $fingerprint=Get-TextHash ($command+"|$freq|$freqInterval|$time|$subtype|$subinterval|$OperatorName")
        $specs+= [pscustomobject]@{name=$name;database=$db;kind=$kind;command=$command;
            description=('perf-1c/maintenance-v1:'+$fingerprint);time=$time;freq=$freq;freq_interval=$freqInterval;subtype=$subtype;subinterval=$subinterval}
    }
}
$preflight=@'
USE msdb;
SET NOCOUNT ON; SET XACT_ABORT ON;
IF CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<13 OR CONVERT(int,SERVERPROPERTY('EngineEdition')) NOT IN (2,3)
 THROW 51010, 'SQL Server 2016+ Standard/Enterprise/Developer with SQL Agent required.', 1;
IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51011, 'Installation requires an authorized SQL sysadmin; no permissions are granted by this script.', 1;
'@
# Rollback controls must remain usable when a target database is offline or gone.
$adminPreflight=$preflight
foreach ($db in $Database) {
    $q=Quote-SqlLiteral $db
    $preflight+="`nIF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name=$q AND database_id>4 AND state=0 AND is_read_only=0 AND replica_id IS NULL) THROW 51012, 'An explicit database is unavailable, read-only, or in an AG.', 1;"
    if ($LogBackupMinutes -gt 0) { $preflight+="`nIF EXISTS (SELECT 1 FROM sys.databases WHERE name=$q AND recovery_model=3) THROW 51013, 'LOG jobs were requested for a SIMPLE database. Use separate packages.', 1;" }
}
foreach ($db in $Database) {
    $q=Quote-SqlLiteral $db
    $preflight+="`nIF EXISTS (SELECT 1 FROM dbo.log_shipping_primary_databases WHERE primary_database=$q) OR EXISTS (SELECT 1 FROM dbo.log_shipping_secondary_databases WHERE secondary_database=$q) THROW 51017, 'Log shipping requires a separate maintenance design.', 1;"
}
$op=Quote-SqlLiteral $OperatorName
if ($OperatorName) { $preflight+="`nIF NOT EXISTS (SELECT 1 FROM dbo.sysoperators WHERE name=$op AND enabled=1 AND NULLIF(email_address,N'') IS NOT NULL) THROW 51014, 'Existing enabled email operator required. Configure Database Mail/Agent separately.', 1;" }
$install=$preflight+@'

DECLARE @id uniqueidentifier,@name sysname,@description nvarchar(512),@command nvarchar(max),@lock int;
BEGIN TRY
 BEGIN TRANSACTION;
 EXEC @lock=sys.sp_getapplock @Resource=N'perf-1c:install-maintenance',@LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=10000;
 IF @lock<0 THROW 51015, 'Cannot acquire installer lock.', 1;
'@
$enable=$preflight+@'

-- EDIT ONLY AFTER REVIEW: no conflicting backup chains/schedules; storage, RPO and alerts verified.
DECLARE @Approved bit=0;
IF @Approved<>1 THROW 51020, 'Review this package and existing maintenance, then set @Approved=1.', 1;
'@
if ($LogBackupMinutes -eq 0) {
    $enable+="`nDECLARE @ExternalLogBackupsConfirmed bit=0;"
    foreach ($db in $Database) {
        $q=Quote-SqlLiteral $db
        $enable+="`nIF @ExternalLogBackupsConfirmed<>1 AND EXISTS (SELECT 1 FROM sys.databases WHERE name=$q AND recovery_model IN (1,2)) THROW 51021, 'FULL/BULK_LOGGED database: create LOG jobs or confirm external LOG backups first.', 1;"
    }
}
$enable+="`nBEGIN TRY`n BEGIN TRANSACTION;"
$disable=$adminPreflight+"`nBEGIN TRY`n BEGIN TRANSACTION;"; $remove=$adminPreflight+"`nBEGIN TRY`n BEGIN TRANSACTION;"
foreach ($job in $specs) {
    $n=Quote-SqlLiteral $job.name; $d=Quote-SqlLiteral $job.description; $c=Quote-SqlLiteral $job.command
    $schedule=Quote-SqlLiteral ($job.name+'-schedule')
    $notify=if($OperatorName){",@notify_level_email=2,@notify_email_operator_name=$op"}else{''}
    $f=$job.freq; $fi=$job.freq_interval; $tm=$job.time; $st=$job.subtype; $si=$job.subinterval
    # Keep existing jobs only if the fingerprint AND actual step/schedule still match.
    $install+=@"

 SET @id=NULL; SET @name=$n; SET @description=$d; SET @command=$c;
 SELECT @id=job_id FROM dbo.sysjobs WHERE name=@name;
 IF @id IS NOT NULL
 BEGIN
  IF NOT EXISTS (SELECT 1 FROM dbo.sysjobs WHERE job_id=@id AND description=@description)
    OR (SELECT COUNT(*) FROM dbo.sysjobsteps WHERE job_id=@id)<>1
    OR NOT EXISTS (SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@id AND step_id=1 AND subsystem=N'TSQL' AND database_name=N'master' AND command=@command)
    OR (SELECT COUNT(*) FROM dbo.sysjobschedules WHERE job_id=@id)<>1
    OR NOT EXISTS (SELECT 1 FROM dbo.sysjobschedules js JOIN dbo.sysschedules s ON s.schedule_id=js.schedule_id
       WHERE js.job_id=@id AND s.name=$schedule AND s.freq_type=$f AND s.freq_interval=$fi AND s.active_start_time=$tm AND s.freq_subday_type=$st AND s.freq_subday_interval=$si)
      THROW 51016, 'Existing job differs. No overwrite: inspect it and regenerate or remove the owned package explicitly.', 1;
 END
 ELSE
 BEGIN
  EXEC dbo.sp_add_job @job_name=@name,@enabled=0,@description=@description,@job_id=@id OUTPUT$notify;
  EXEC dbo.sp_add_jobstep @job_id=@id,@step_name=N'Maintenance',@subsystem=N'TSQL',@database_name=N'master',
       @command=@command,@on_success_action=1,@on_fail_action=2,@retry_attempts=2,@retry_interval=5;
  EXEC dbo.sp_add_jobschedule @job_id=@id,@name=$schedule,@enabled=1,@freq_type=$f,@freq_interval=$fi,
       @freq_recurrence_factor=1,@freq_subday_type=$st,@freq_subday_interval=$si,@active_start_time=$tm;
  EXEC dbo.sp_add_jobserver @job_id=@id;
 END;
"@
    $guard="`nIF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name=$n AND description<>$d) THROW 51022, 'Job ownership signature changed; inspect manually.', 1;"
    $enable+=$guard+"`nIF NOT EXISTS (SELECT 1 FROM dbo.sysjobs j JOIN dbo.sysjobsteps st ON st.job_id=j.job_id WHERE j.name=$n AND j.description=$d AND st.step_id=1 AND st.command=$c) THROW 51023, 'Owned job missing or modified; do not enable.', 1;`nEXEC dbo.sp_update_job @job_name=$n,@enabled=1;"
    $disable+=$guard+"`nIF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name=$n AND description=$d) EXEC dbo.sp_update_job @job_name=$n,@enabled=0;"
    $remove+=$guard+"`nIF EXISTS (SELECT 1 FROM dbo.sysjobs j JOIN dbo.sysjobactivity a ON a.job_id=j.job_id WHERE j.name=$n AND a.session_id=(SELECT MAX(session_id) FROM dbo.syssessions) AND a.start_execution_date IS NOT NULL AND a.stop_execution_date IS NULL) THROW 51024, 'Owned job is running; wait for completion before removing.', 1;`nIF EXISTS (SELECT 1 FROM dbo.sysjobs WHERE name=$n AND description=$d) EXEC dbo.sp_delete_job @job_name=$n,@delete_unused_schedule=1;"
}
$install+=@'

 COMMIT;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK;
 THROW;
END CATCH;
-- Newly created jobs are DISABLED. No backup, CHECKDB or statistics update was run.
'@
$endTransaction="`n COMMIT;`nEND TRY`nBEGIN CATCH`n IF @@TRANCOUNT>0 ROLLBACK;`n THROW;`nEND CATCH;"
$enable+=$endTransaction; $disable+=$endTransaction; $remove+=$endTransaction
$root=Join-Path $OutputDirectory ('package_'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'_'+[guid]::NewGuid().ToString('N').Substring(0,6))
[void][IO.Directory]::CreateDirectory($root)
$utf8=[Text.UTF8Encoding]::new($false)
foreach ($item in @(@('install.sql',$install),@('enable.sql',$enable),@('disable.sql',$disable),@('remove.sql',$remove))) {
    [IO.File]::WriteAllText((Join-Path $root $item[0]),$item[1],$utf8)
}
$overview=[ordered]@{tool_version='0.1.0-pilot';sql_instance=$SqlInstance;databases=$Database;
    backup_directory=$BackupDirectory;log_backup_minutes=$LogBackupMinutes;operator=$OperatorName;
    schedule_time_basis='SQL Server Agent local time';job_count=$specs.Count;
    jobs=@($specs | Select-Object name,database,kind,time,freq,freq_interval,description);
    applied=$false;created_jobs_enabled=$false;
    warnings=@('PILOT: SQL/PowerShell integration not validated.','No retention deletion, external copy, restore-test, system DB backup or alert setup is implemented.',
    'Full backups are regular (not COPY_ONLY) and can change the differential base. Review existing backup chains before enabling.',
    'VERIFYONLY is not a restore test. Existing backup directory and SQL service write access must be verified.',
    'Jobs have no hard time limit. Review windows and stagger database schedules. Heavy jobs serialize; backup I/O can still overlap.',
    'NO automatic REBUILD, SHRINK, recovery-model change, SQL configuration change or cache clearing. Disabling jobs does not stop an already running job.')}
Write-Warning 'Preview files generated. No jobs enabled or run. Review backup storage, existing schedules/chains, RPO and notifications.'
Write-Host ('Maintenance package: '+[IO.Path]::GetFullPath($root))
try {
    if ($Apply -and $PSCmdlet.ShouldProcess($SqlInstance,'Install DISABLED SQL Agent jobs from reviewed maintenance package')) {
        if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw '-Apply requires Windows x64 PowerShell 7.' }
        Add-Type -AssemblyName System.Data.SqlClient
        $b=[System.Data.SqlClient.SqlConnectionStringBuilder]::new()
        $b['Data Source']=$SqlInstance; $b['Initial Catalog']='msdb'; $b['Encrypt']=$true
        $b['TrustServerCertificate']=[bool]$TrustServerCertificate; $b['Integrated Security']=($null -eq $SqlCredential)
        $b['Connect Timeout']=10; $b['Persist Security Info']=$false; $b['Pooling']=$false
        $b['Application Name']='OneCPerfMaintenance/0.1.0-pilot'
        $connection=[System.Data.SqlClient.SqlConnection]::new($b.get_ConnectionString())
        try {
            if ($null -ne $SqlCredential) { $secret=$SqlCredential.Password.Copy(); $secret.MakeReadOnly(); $connection.Credential=[System.Data.SqlClient.SqlCredential]::new($SqlCredential.UserName,$secret) }
            $connection.Open(); $cmd=$connection.CreateCommand()
            try { $cmd.CommandTimeout=60; $cmd.CommandText=$install; [void]$cmd.ExecuteNonQuery(); $overview.applied=$true }
            finally { $cmd.Dispose() }
        } finally { $connection.Dispose() }
        Write-Host 'Installed. NEW jobs remain DISABLED; previously existing matching jobs were left unchanged. Review enable.sql separately.'
    }
} catch { $overview['apply_error']=$_.Exception.Message; throw }
finally { [IO.File]::WriteAllText((Join-Path $root 'package.json'),($overview|ConvertTo-Json -Depth 8),$utf8) }
