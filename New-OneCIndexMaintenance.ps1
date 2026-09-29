#requires -Version 7.0
<#
Generate local reviewable SQL Agent INDEX jobs for explicit user databases.
-Apply only installs DISABLED jobs after confirmation. Never enables or starts a job.
Default policy: >=1000 pages, 5<=fragmentation<30 REORGANIZE; >=30 is deferred
unless -AllowOfflineRebuild explicitly authorizes blocking REBUILD inside the job.
PILOT: Windows/SQL integration must be tested on a disposable SQL instance first.
#>
[CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
param(
    [Parameter(Mandatory)][ValidateCount(1,20)][string[]]$Database,
    [string]$SqlInstance='.',
    [pscredential]$SqlCredential,
    [switch]$TrustServerCertificate,
    [ValidateRange(1,200)][int]$MaxIndexes=50,
    [ValidateRange(0,1000000000)][int]$MinPages=1000,
    [ValidateRange(0,99)][int]$ReorganizePercent=5,
    [ValidateRange(1,100)][int]$RebuildPercent=30,
    [ValidateRange(1,240)][int]$BudgetMinutes=30,
    [ValidateRange(1,60)][int]$LockTimeoutSeconds=5,
    [ValidateRange(1,8)][int]$MaxDop=2,
    [switch]$AllowOfflineRebuild,
    [switch]$SortInTempdb,
    [ValidatePattern('^([01][0-9]|2[0-3]):[0-5][0-9]$')][string]$MaintenanceTime='05:00',
    [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')][string]$MaintenanceDay='Sunday',
    [string]$OperatorName='',
    [string]$OutputDirectory=(Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'perf-1c/maintenance'),
    [switch]$Apply
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
function Get-IndexTextHash([string]$Text) {
    $h=[Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-','').ToLowerInvariant() }
    finally { $h.Dispose() }
}
function Quote-IndexSqlLiteral([string]$Text) { return "N'"+$Text.Replace("'","''")+"'" }
function Quote-IndexSqlName([string]$Text) { return '['+$Text.Replace(']',']]')+']' }
function Assert-IndexDatabaseName([string]$Name) {
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 128 -or $Name -match '[\x00-\x1f]') { throw 'Invalid database name.' }
    if ($Name -in @('master','model','msdb','tempdb')) { throw 'Explicit USER databases only.' }
}
foreach ($db in $Database) { Assert-IndexDatabaseName $db }
if (@($Database | Sort-Object -Unique).Count -ne $Database.Count) { throw 'Duplicate database names.' }
if ($ReorganizePercent -ge $RebuildPercent) { throw 'ReorganizePercent must be smaller than RebuildPercent.' }
if ($SortInTempdb -and -not $AllowOfflineRebuild) { throw 'SortInTempdb requires explicit AllowOfflineRebuild.' }
if ($OperatorName.Length -gt 128 -or $OperatorName -match '[\x00-\x1f]') { throw 'Invalid operator name.' }
$dayBits=@{Sunday=1;Monday=2;Tuesday=4;Wednesday=8;Thursday=16;Friday=32;Saturday=64}
$time=[int]($MaintenanceTime.Replace(':','')+'00');$day=$dayBits[$MaintenanceDay]
$logTable='dbo.perf1c_IndexMaintenanceLog_v1'

# The job body executes in the target database, but the shared heavy-maintenance
# applock is acquired and released in MASTER, like New-OneCMaintenance STATS/CHECKDB.
$bodyTemplate=@'
SET NOCOUNT ON; SET DEADLOCK_PRIORITY LOW; SET LOCK_TIMEOUT {{LOCK_MS}};
IF DB_ID()<=4 OR NOT EXISTS (SELECT 1 FROM sys.databases WHERE database_id=DB_ID() AND state=0 AND is_read_only=0 AND replica_id IS NULL)
 THROW 51200,'Index maintenance requires an ONLINE/read-write standalone user database.',1;
IF EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_primary_databases WHERE primary_database=DB_NAME())
 OR EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_secondary_databases WHERE secondary_database=DB_NAME())
 THROW 51201,'Log shipping requires a separate maintenance design.',1;
DECLARE @run uniqueidentifier=NEWID(),@runlog bigint,@entry bigint,@start datetime2(3)=SYSUTCDATETIME(),
 @deadline datetime2(3)=DATEADD(minute,{{BUDGET_MINUTES}},SYSUTCDATETIME()),@total bigint=0,
 @checked int=0,@changed int=0,@errors int=0,@deferred int=0,@budget bit=0;
INSERT msdb.dbo.perf1c_IndexMaintenanceLog_v1(run_id,database_name,action,outcome,started_utc)
 VALUES(@run,DB_NAME(),N'RUN',N'started',@start);
SET @runlog=SCOPE_IDENTITY();
BEGIN TRY
 CREATE TABLE #work(n int IDENTITY(1,1) PRIMARY KEY,object_id int,index_id int,partition_number int,
  partition_count int,schema_name sysname,table_name sysname,index_name sysname,created datetime,known_pages bigint,total bigint);
 INSERT #work(object_id,index_id,partition_number,partition_count,schema_name,table_name,index_name,created,known_pages,total)
 SELECT TOP ({{MAX_INDEXES}}) t.object_id,i.index_id,p.partition_number,
  (SELECT COUNT(*) FROM sys.partitions pp WHERE pp.object_id=i.object_id AND pp.index_id=i.index_id),
  s.name,t.name,i.name,t.create_date,p.in_row_data_page_count,COUNT_BIG(*) OVER()
 FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id
 JOIN sys.indexes i ON i.object_id=t.object_id
 JOIN sys.dm_db_partition_stats p ON p.object_id=i.object_id AND p.index_id=i.index_id
 OUTER APPLY (SELECT MAX(l.started_utc) AS last_checked FROM msdb.dbo.perf1c_IndexMaintenanceLog_v1 l
   WHERE l.database_name=DB_NAME() AND l.object_id=t.object_id AND l.index_id=i.index_id AND l.partition_number=p.partition_number
   AND l.table_name=t.name AND l.index_name=i.name AND l.schema_name=s.name) hist
 WHERE t.is_ms_shipped=0 AND t.is_memory_optimized=0 AND i.type IN (1,2)
  AND i.is_disabled=0 AND i.is_hypothetical=0 AND p.in_row_data_page_count>={{MIN_PAGES}}
 ORDER BY hist.last_checked ASC,p.in_row_data_page_count DESC,t.object_id,i.index_id,p.partition_number
 OPTION (MAXDOP 1);
 SELECT @total=ISNULL(MAX(total),0) FROM #work;
 DECLARE @n int=1,@oid int,@iid int,@part int,@parts int,@schema sysname,@table sysname,@index sysname,
  @created datetime,@pages bigint,@frag float,@pageLocks bit,@sql nvarchar(max),@action nvarchar(24),@message nvarchar(2048);
 WHILE EXISTS (SELECT 1 FROM #work WHERE n=@n)
 BEGIN
  IF SYSUTCDATETIME()>=@deadline BEGIN SET @budget=1; BREAK; END;
  SELECT @oid=object_id,@iid=index_id,@part=partition_number,@parts=partition_count,
   @schema=schema_name,@table=table_name,@index=index_name,@created=created FROM #work WHERE n=@n;
  SET @pages=NULL; SET @frag=NULL; SET @pageLocks=NULL; SET @sql=NULL; SET @action=N'CHECK';
  INSERT msdb.dbo.perf1c_IndexMaintenanceLog_v1(run_id,database_name,object_id,index_id,partition_number,
   schema_name,table_name,index_name,action,outcome,started_utc)
  VALUES(@run,DB_NAME(),@oid,@iid,@part,@schema,@table,@index,N'CHECK',N'started',SYSUTCDATETIME());
  SET @entry=SCOPE_IDENTITY();
  BEGIN TRY
   -- No NULL/0 wildcard arguments, no silent fallback if an object changed after inventory.
   IF @oid IS NULL OR @oid<=0 OR @iid IS NULL OR @iid<=0 OR @part IS NULL OR @part<=0
    THROW 51202,'Invalid explicit index identity.',1;
   IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id
    JOIN sys.indexes i ON i.object_id=t.object_id JOIN sys.partitions p ON p.object_id=i.object_id AND p.index_id=i.index_id
    WHERE t.object_id=@oid AND i.index_id=@iid AND p.partition_number=@part
     AND s.name=@schema AND t.name=@table AND i.name=@index AND t.create_date=@created
     AND t.is_memory_optimized=0 AND i.type IN (1,2) AND i.is_disabled=0 AND i.is_hypothetical=0)
    THROW 51203,'Object changed or is unsupported; skipped without replacement.',1;
   SELECT @pageLocks=allow_page_locks FROM sys.indexes WHERE object_id=@oid AND index_id=@iid;
   SELECT @pages=page_count,@frag=avg_fragmentation_in_percent
   FROM sys.dm_db_index_physical_stats(DB_ID(),@oid,@iid,@part,N'LIMITED')
   WHERE index_level=0 AND alloc_unit_type_desc=N'IN_ROW_DATA';
   IF @pages IS NULL OR @frag IS NULL THROW 51204,'Physical statistics missing; not a healthy result.',1;
   UPDATE msdb.dbo.perf1c_IndexMaintenanceLog_v1 SET page_count=@pages,fragmentation_percent=@frag WHERE log_id=@entry;
   SET @checked+=1;
   -- The budget prevents a NEW operation, not a hard deadline for an in-flight ALTER INDEX.
   IF SYSUTCDATETIME()>=@deadline
   BEGIN
    SET @budget=1;
    UPDATE msdb.dbo.perf1c_IndexMaintenanceLog_v1 SET outcome=N'budget_stop',ended_utc=SYSUTCDATETIME() WHERE log_id=@entry;
    BREAK;
   END;
   IF @pages<{{MIN_PAGES}} OR @frag<{{REORGANIZE_PERCENT}}
    UPDATE msdb.dbo.perf1c_IndexMaintenanceLog_v1 SET outcome=N'no_action_by_policy',ended_utc=SYSUTCDATETIME() WHERE log_id=@entry;
   ELSE IF @frag>={{REBUILD_PERCENT}} AND {{ALLOW_OFFLINE}}=0
   BEGIN
    SET @deferred+=1;
    UPDATE msdb.dbo.perf1c_IndexMaintenanceLog_v1 SET outcome=N'offline_not_approved',ended_utc=SYSUTCDATETIME(),
     message=N'REBUILD candidate deferred: blocking offline rebuild was not explicitly approved.' WHERE log_id=@entry;
   END
   ELSE IF @frag<{{REBUILD_PERCENT}} AND ISNULL(@pageLocks,0)=0
   BEGIN
    SET @deferred+=1;
    UPDATE msdb.dbo.perf1c_IndexMaintenanceLog_v1 SET outcome=N'page_locks_disabled',ended_utc=SYSUTCDATETIME(),
     message=N'REORGANIZE is unavailable with ALLOW_PAGE_LOCKS=OFF; setting is not changed.' WHERE log_id=@entry;
   END
   ELSE
   BEGIN
    SET @action=CASE WHEN @frag>={{REBUILD_PERCENT}} THEN N'REBUILD' ELSE N'REORGANIZE' END;
    SET @sql=N'ALTER INDEX '+QUOTENAME(@index)+N' ON '+QUOTENAME(@schema)+N'.'+QUOTENAME(@table)+N' '+@action
      +CASE WHEN @parts>1 THEN N' PARTITION = '+CONVERT(nvarchar(12),@part) ELSE N'' END
      +CASE WHEN @action=N'REBUILD' THEN N' WITH (ONLINE = OFF, MAXDOP = {{MAX_DOP}}, SORT_IN_TEMPDB = {{SORT_TEMPDB}})' ELSE N' WITH (LOB_COMPACTION = OFF)' END+N';';
    UPDATE msdb.dbo.perf1c_IndexMaintenanceLog_v1 SET action=@action WHERE log_id=@entry;
    EXEC sys.sp_executesql @sql;
    SET @changed+=1;
    UPDATE msdb.dbo.perf1c_IndexMaintenanceLog_v1 SET outcome=N'succeeded',ended_utc=SYSUTCDATETIME() WHERE log_id=@entry;
    -- No FULLSCAN ALL after rebuild. Separate STATS policy handles column statistics.
   END;
  END TRY
  BEGIN CATCH
   SET @errors+=1;
   UPDATE msdb.dbo.perf1c_IndexMaintenanceLog_v1 SET outcome=N'error',ended_utc=SYSUTCDATETIME(),
    error_number=ERROR_NUMBER(),message=LEFT(ERROR_MESSAGE(),2048) WHERE log_id=@entry;
  END CATCH;
  SET @n+=1;
  IF @errors>=3 BREAK;
 END;
 SET @message=CONCAT(N'Eligible partitions=',@total,N'; checked=',@checked,N'; changed=',@changed,
   N'; errors=',@errors,N'; deferred=',@deferred,N'; budget_stop=',@budget,
   N'. A successful bounded subset is NOT full database maintenance.');
 UPDATE msdb.dbo.perf1c_IndexMaintenanceLog_v1 SET ended_utc=SYSUTCDATETIME(),message=@message,
  outcome=CASE WHEN @errors>0 THEN N'error' WHEN @budget=1 THEN N'budget_stop' WHEN @deferred>0 THEN N'needs_review'
   WHEN @checked<@total THEN N'completed_subset' ELSE N'completed_scope' END WHERE log_id=@runlog;
 RAISERROR(N'%s',10,1,@message) WITH NOWAIT;
 IF @errors>0 OR @budget=1 OR @deferred>0 THROW 51205,'Index maintenance incomplete or requires review; inspect perf-1c log. No automatic offline fallback.',1;
END TRY
BEGIN CATCH
 UPDATE msdb.dbo.perf1c_IndexMaintenanceLog_v1 SET ended_utc=SYSUTCDATETIME(),
  outcome=CASE WHEN outcome=N'started' THEN N'error' ELSE outcome END,
  error_number=ERROR_NUMBER(),message=COALESCE(message,LEFT(ERROR_MESSAGE(),2048)) WHERE log_id=@runlog;
 THROW;
END CATCH;
'@
$values=@{
    LOCK_MS=[string]($LockTimeoutSeconds*1000);BUDGET_MINUTES=[string]$BudgetMinutes;
    MAX_INDEXES=[string]$MaxIndexes;MIN_PAGES=[string]$MinPages;
    REORGANIZE_PERCENT=[string]$ReorganizePercent;REBUILD_PERCENT=[string]$RebuildPercent;
    ALLOW_OFFLINE=[string][int][bool]$AllowOfflineRebuild;MAX_DOP=[string]$MaxDop;
    SORT_TEMPDB=$(if($SortInTempdb){'ON'}else{'OFF'})
}
$body=$bodyTemplate
foreach ($key in $values.Keys) { $body=$body.Replace(('{{'+$key+'}}'),$values[$key]) }
$specs=@()
foreach ($db in $Database) {
    $q=Quote-IndexSqlLiteral $db;$ident=Quote-IndexSqlName $db
    $inner=Quote-IndexSqlLiteral ("USE $ident;`n"+$body)
    $command=@"
USE master;
SET NOCOUNT ON;
IF DB_ID($q) IS NULL THROW 51206,'Configured user database no longer exists.',1;
DECLARE @lock int;
EXEC @lock=sys.sp_getapplock @Resource=N'perf-1c:heavy-maintenance',@LockMode=N'Exclusive',@LockOwner=N'Session',@LockTimeout=0;
IF @lock<0 THROW 51207,'Another perf-1c STATS/CHECKDB/INDEX job is running; reschedule.',1;
BEGIN TRY
 EXEC sys.sp_executesql $inner;
 EXEC sys.sp_releaseapplock @Resource=N'perf-1c:heavy-maintenance',@LockOwner=N'Session';
END TRY
BEGIN CATCH
 EXEC sys.sp_releaseapplock @Resource=N'perf-1c:heavy-maintenance',@LockOwner=N'Session';
 THROW;
END CATCH;
"@
    $name='perf-1c-'+(Get-IndexTextHash $db).Substring(0,16)+'-INDEX'
    $description='perf-1c/index-maintenance-v1:'+(Get-IndexTextHash ($command+"|$day|$time|$OperatorName"))
    $specs += [pscustomobject]@{name=$name;database=$db;description=$description;command=$command}
}
$preflight=@'
USE msdb;
SET NOCOUNT ON; SET XACT_ABORT ON;
IF CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<13 OR CONVERT(int,SERVERPROPERTY('EngineEdition')) NOT IN (2,3)
 THROW 51210,'SQL Server 2016+ Standard/Enterprise/Developer with SQL Agent required.',1;
IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0)<>1 THROW 51211,'An authorized SQL sysadmin must install this package.',1;
'@
$targets=''
foreach ($db in $Database) {
    $q=Quote-IndexSqlLiteral $db
    $targets+="`nIF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name=$q AND database_id>4 AND state=0 AND is_read_only=0 AND replica_id IS NULL) THROW 51212,'Target database unavailable/read-only/in AG.',1;"
    $targets+="`nIF EXISTS (SELECT 1 FROM dbo.log_shipping_primary_databases WHERE primary_database=$q) OR EXISTS (SELECT 1 FROM dbo.log_shipping_secondary_databases WHERE secondary_database=$q) THROW 51213,'Log shipping is outside this package scope.',1;"
}
$op=Quote-IndexSqlLiteral $OperatorName
if ($OperatorName) { $targets+="`nIF NOT EXISTS (SELECT 1 FROM dbo.sysoperators WHERE name=$op AND enabled=1 AND NULLIF(email_address,N'') IS NOT NULL) THROW 51214,'Existing enabled email operator required. Configure and test Agent mail separately.',1;" }
$tx=@'

DECLARE @id uniqueidentifier,@rc int,@lock int;
BEGIN TRY
 BEGIN TRANSACTION;
 EXEC @lock=sys.sp_getapplock @Resource=N'perf-1c:install-index-maintenance',@LockMode=N'Exclusive',@LockOwner=N'Transaction',@LockTimeout=10000;
 IF @lock<0 THROW 51215,'Cannot acquire installer lock.',1;
'@
$end=@'

 COMMIT;
END TRY
BEGIN CATCH
 IF @@TRANCOUNT>0 ROLLBACK;
 THROW;
END CATCH;
'@
$logDdl=@'

 IF OBJECT_ID(N'dbo.perf1c_IndexMaintenanceLog_v1') IS NULL
 BEGIN
  CREATE TABLE dbo.perf1c_IndexMaintenanceLog_v1(
   log_id bigint IDENTITY(1,1) NOT NULL PRIMARY KEY,run_id uniqueidentifier NOT NULL,database_name sysname NOT NULL,
   object_id int NULL,index_id int NULL,partition_number int NULL,schema_name sysname NULL,table_name sysname NULL,index_name sysname NULL,
   action nvarchar(24) NOT NULL,outcome nvarchar(32) NOT NULL,started_utc datetime2(3) NOT NULL,ended_utc datetime2(3) NULL,
   page_count bigint NULL,fragmentation_percent float NULL,error_number int NULL,message nvarchar(2048) NULL);
  CREATE INDEX IX_perf1c_IndexMaintenanceLog_v1_object ON dbo.perf1c_IndexMaintenanceLog_v1
   (database_name,object_id,index_id,partition_number,started_utc) INCLUDE (schema_name,table_name,index_name);
  EXEC sys.sp_addextendedproperty @name=N'perf-1c:owner',@value=N'index-maintenance/1',
   @level0type=N'SCHEMA',@level0name=N'dbo',@level1type=N'TABLE',@level1name=N'perf1c_IndexMaintenanceLog_v1';
 END;
 IF OBJECT_ID(N'dbo.perf1c_IndexMaintenanceLog_v1',N'U') IS NULL
 OR NOT EXISTS (SELECT 1 FROM sys.extended_properties WHERE major_id=OBJECT_ID(N'dbo.perf1c_IndexMaintenanceLog_v1')
  AND minor_id=0 AND class=1 AND name=N'perf-1c:owner' AND CONVERT(nvarchar(128),value)=N'index-maintenance/1')
 OR ISNULL(COL_LENGTH(N'dbo.perf1c_IndexMaintenanceLog_v1',N'run_id'),-1)<>16
 OR ISNULL(COL_LENGTH(N'dbo.perf1c_IndexMaintenanceLog_v1',N'message'),-1)<>4096
 OR ISNULL(COL_LENGTH(N'dbo.perf1c_IndexMaintenanceLog_v1',N'log_id'),-1)<>8
  THROW 51216,'Log table ownership/schema differs. Do not overwrite it.',1;
'@
$install=$preflight+$targets+$tx+$logDdl
$approval=@'

-- Review backups, restore test, storage/log headroom, competing maintenance, alerts and real durations.
-- Offline rebuilds can block users for the ENTIRE operation. Soft budget is NOT a cancellation timeout.
DECLARE @Approved bit=0;
IF @Approved<>1 THROW 51220,'Review the package and set @Approved=1 explicitly before enabling.',1;
'@
$enable=$preflight+$targets+$approval+$tx
$disable=$preflight+$tx;$remove=$preflight+$tx
foreach ($job in $specs) {
    $n=Quote-IndexSqlLiteral $job.name; $d=Quote-IndexSqlLiteral $job.description
    $c=Quote-IndexSqlLiteral $job.command; $schedule=Quote-IndexSqlLiteral ($job.name+'-schedule')
    $notify=if($OperatorName){",@notify_level_email=2,@notify_email_operator_name=$op"}else{''}
    $match=@"
 (SELECT COUNT(*) FROM dbo.sysjobsteps WHERE job_id=@id)=1
 AND EXISTS (SELECT 1 FROM dbo.sysjobs WHERE job_id=@id AND description=$d)
 AND EXISTS (SELECT 1 FROM dbo.sysjobsteps WHERE job_id=@id AND step_id=1 AND subsystem=N'TSQL'
  AND database_name=N'master' AND command COLLATE Latin1_General_100_BIN2=$c COLLATE Latin1_General_100_BIN2
  AND on_success_action=1 AND on_fail_action=2 AND retry_attempts=0)
 AND (SELECT COUNT(*) FROM dbo.sysjobschedules WHERE job_id=@id)=1
 AND EXISTS (SELECT 1 FROM dbo.sysjobschedules js JOIN dbo.sysschedules s ON s.schedule_id=js.schedule_id
  WHERE js.job_id=@id AND s.name=$schedule AND s.freq_type=8 AND s.freq_interval=$day
   AND s.active_start_time=$time AND s.freq_subday_type=1 AND s.freq_recurrence_factor=1 AND s.enabled=1)
"@
    $install+=@"

 SET @id=NULL; SELECT @id=job_id FROM dbo.sysjobs WHERE name=$n;
 IF @id IS NOT NULL
 BEGIN
  IF NOT ($match) THROW 51221,'Existing INDEX job differs; no overwrite.',1;
 END
 ELSE
 BEGIN
  IF EXISTS (SELECT 1 FROM dbo.sysschedules WHERE name=$schedule) THROW 51222,'Schedule name already in use; no reuse of unrelated schedules.',1;
  EXEC @rc=dbo.sp_add_job @job_name=$n,@enabled=0,@description=$d,@job_id=@id OUTPUT$notify;
  IF @rc<>0 THROW 51223,'sp_add_job failed.',1;
  EXEC @rc=dbo.sp_add_jobstep @job_id=@id,@step_name=N'Conditional index maintenance',@subsystem=N'TSQL',
   @database_name=N'master',@command=$c,@on_success_action=1,@on_fail_action=2,@retry_attempts=0;
  IF @rc<>0 THROW 51224,'sp_add_jobstep failed.',1;
  EXEC @rc=dbo.sp_add_jobschedule @job_id=@id,@name=$schedule,@enabled=1,@freq_type=8,@freq_interval=$day,
   @freq_recurrence_factor=1,@freq_subday_type=1,@active_start_time=$time;
  IF @rc<>0 THROW 51225,'sp_add_jobschedule failed.',1;
  EXEC @rc=dbo.sp_add_jobserver @job_id=@id;
  IF @rc<>0 THROW 51226,'sp_add_jobserver failed.',1;
 END;
"@
    $guard=@"

 SET @id=NULL; SELECT @id=job_id FROM dbo.sysjobs WHERE name=$n;
 IF @id IS NOT NULL AND NOT ($match) THROW 51227,'Owned INDEX job was modified; inspect manually.',1;
"@
    $enable+=$guard+"`n IF @id IS NULL THROW 51228,'INDEX job missing; install first.',1;`n EXEC @rc=dbo.sp_update_job @job_id=@id,@enabled=1;`n IF @rc<>0 THROW 51229,'Cannot enable INDEX job.',1;"
    $disable+=$guard+"`n IF @id IS NOT NULL BEGIN EXEC @rc=dbo.sp_update_job @job_id=@id,@enabled=0; IF @rc<>0 THROW 51230,'Cannot disable INDEX job.',1; END;"
    $remove+=$guard+@'

 IF @id IS NOT NULL
 BEGIN
  IF EXISTS (SELECT 1 FROM dbo.sysjobactivity WHERE job_id=@id AND session_id=(SELECT MAX(session_id) FROM dbo.syssessions)
   AND start_execution_date IS NOT NULL AND stop_execution_date IS NULL) THROW 51231,'INDEX job is running; do not remove it.',1;
  EXEC @rc=dbo.sp_delete_job @job_id=@id,@delete_unused_schedule=1;
  IF @rc<>0 THROW 51232,'Cannot remove INDEX job.',1;
 END;
'@
}
$install+=$end+"`n-- New jobs DISABLED. No index maintenance has been executed.`n"
$enable+=$end;$disable+=$end;$remove+=$end+"`n-- Shared msdb log table is deliberately preserved.`n"
$root=[IO.Path]::GetFullPath((Join-Path $OutputDirectory ('index_package_'+[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')+'_'+[guid]::NewGuid().ToString('N').Substring(0,6))))
if ($root.StartsWith('\\')) { throw 'Use a local package output directory.' }
[void][IO.Directory]::CreateDirectory($root)
$utf8=[Text.UTF8Encoding]::new($false)
foreach ($item in (@{install=$install;enable=$enable;disable=$disable;remove=$remove}).GetEnumerator()) {
    [IO.File]::WriteAllText((Join-Path $root ($item.Key+'.sql')),$item.Value,$utf8)
}
$package=[ordered]@{schema_version='index-maintenance/1';generator_version='0.1.0-pilot';databases=$Database;
    generated_utc=[DateTime]::UtcNow.ToString('o');jobs=$specs;install_sha256=(Get-FileHash -LiteralPath (Join-Path $root 'install.sql') -Algorithm SHA256).Hash;
    max_indexes=$MaxIndexes;min_pages=$MinPages;reorganize_percent=$ReorganizePercent;rebuild_percent=$RebuildPercent;
    allow_offline_rebuild=[bool]$AllowOfflineRebuild;sort_in_tempdb=[bool]$SortInTempdb;budget_minutes=$BudgetMinutes;
    maxdop=$MaxDop;lock_timeout_seconds=$LockTimeoutSeconds;maintenance_time=$MaintenanceTime;maintenance_day=$MaintenanceDay;
    operator_name=$OperatorName;apply_status='not_requested';log_table='msdb.dbo.perf1c_IndexMaintenanceLog_v1';
    warning='Confidential database names/commands. No upload. Jobs disabled; enabling is a separate reviewed operation.';
    limitations=@('No hard timeout for in-flight DDL; soft budget checked before each operation.',
        'No online/resumable rebuild; offline rebuild requires explicit approval and can block users.',
        'No fillfactor/schema/recovery changes, no automatic FULLSCAN, no blanket rebuild.',
        'Shared heavy-maintenance lock only coordinates perf-1c jobs; external jobs and backups may overlap.',
        'msdb log is kept, never automatically cleaned; plan retention and storage monitoring.',
        'A completed_subset run is not full database maintenance; bounded work rotates by oldest check.',
        'No simple rollback of physical layout or updated statistics. Disable/remove only controls future jobs.',
        'PILOT: Windows/SQL runtime not tested in this development environment.')}
if (-not $OperatorName) { Write-Warning 'No email operator set. Configure and test external monitoring before enabling.' }
if ($AllowOfflineRebuild) { Write-Warning 'This package permits blocking OFFLINE REBUILD after enabling the jobs. Verify maintenance window and storage/log headroom.' }
try {
    if ($Apply -and $PSCmdlet.ShouldProcess($SqlInstance,'Install DISABLED INDEX jobs and the owned msdb history table; do NOT run maintenance')) {
        if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw 'Apply requires Windows x64 PS7.' }
        Add-Type -AssemblyName System.Data.SqlClient
        $b=[System.Data.SqlClient.SqlConnectionStringBuilder]::new()
        $b['Data Source']=$SqlInstance;$b['Initial Catalog']='msdb';$b['Application Name']='OneCPerfIndexInstaller/0.1'
        $b['Connect Timeout']=15;$b['Encrypt']=$true;$b['TrustServerCertificate']=[bool]$TrustServerCertificate
        $b['Integrated Security']=($null -eq $SqlCredential);$b['Pooling']=$false;$b['Persist Security Info']=$false
        $conn=[System.Data.SqlClient.SqlConnection]::new($b.get_ConnectionString())
        try {
            if ($null -ne $SqlCredential) {
                $secret=$SqlCredential.Password.Copy();$secret.MakeReadOnly()
                $conn.Credential=[System.Data.SqlClient.SqlCredential]::new($SqlCredential.UserName,$secret)
            }
            $conn.Open();$cmd=$conn.CreateCommand()
            try { $cmd.CommandTimeout=30;$cmd.CommandText=$install;[void]$cmd.ExecuteNonQuery() }
            finally { $cmd.Dispose() }
            $package.apply_status='installed_new_jobs_disabled_existing_jobs_preserved'
        } finally { $conn.Dispose() }
    } elseif ($Apply) { $package.apply_status='not_applied_whatif_or_declined' }
} catch { $package.apply_status='error';$package.error=$_.Exception.Message;throw }
finally {
    [IO.File]::WriteAllText((Join-Path $root 'package.json'),(ConvertTo-Json -InputObject $package -Depth 8),$utf8)
    Write-Host ('Index maintenance package: '+$root)
    Write-Host ('Apply status: '+$package.apply_status+'. Review install.sql; enable.sql requires separate explicit approval.')
}
