#requires -Version 7.0
<#
Targeted, read-only cache evidence. No execution/compilation of the business query,
no Query Store/XE enablement, no cache clearing. Text and cached plans are opt-in.
Windows x64, SQL Server 2016+. PILOT: requires a supervised Windows/SQL validation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SqlInstance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Database,
    [Parameter(Mandatory)][ValidatePattern('^0x[0-9a-fA-F]{16}$')][string]$QueryHash,
    [System.Management.Automation.PSCredential]$SqlCredential,
    [switch]$TrustServerCertificate,
    [switch]$IncludeSqlText,
    [switch]$IncludePlan,
    [ValidateRange(1,10)][int]$MaxPlans = 3,
    [ValidateRange(1,15)][int]$QueryTimeoutSeconds = 3,
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$CaseId = 'case01',
    [string]$OutputDirectory = (Join-Path $env:LOCALAPPDATA 'perf-1c\captures')
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw 'Windows x64 PowerShell 7 is required.' }
Add-Type -AssemblyName System.Data.SqlClient

function New-QueryConnection {
    param([string]$Instance,[string]$Catalog,[int]$Timeout,[bool]$Trust,[pscredential]$Credential)
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $builder['Data Source'] = $Instance
    $builder['Initial Catalog'] = $Catalog
    $builder['Application Name'] = 'OneCPerfQuery/0.1.0-pilot'
    $builder['Connect Timeout'] = $Timeout
    $builder['Encrypt'] = $true
    $builder['TrustServerCertificate'] = $Trust
    $builder['Pooling'] = $false
    $builder['Persist Security Info'] = $false
    $builder['Integrated Security'] = ($null -eq $Credential)
    $conn = [System.Data.SqlClient.SqlConnection]::new($builder.get_ConnectionString())
    try {
        if ($null -ne $Credential) {
            $secret = $Credential.Password.Copy()
            $secret.MakeReadOnly()
            $conn.Credential = [System.Data.SqlClient.SqlCredential]::new($Credential.UserName,$secret)
        }
        return $conn
    } catch { $conn.Dispose(); throw }
}
function Read-QueryEvidence {
    param([System.Data.SqlClient.SqlConnection]$Connection,[string]$Sql,[hashtable]$Parameters,[int]$Limit)
    $cmd = $Connection.CreateCommand()
    $cmd.CommandTimeout = $QueryTimeoutSeconds
    $cmd.CommandText = "SET NOCOUNT ON; SET DEADLOCK_PRIORITY LOW; SET LOCK_TIMEOUT 1000;`n" + $Sql
    $reader = $null
    try {
        foreach ($key in $Parameters.Keys) {
            $value = $Parameters[$key]
            if ($value -is [int]) { $p = $cmd.Parameters.Add($key,[Data.SqlDbType]::Int) }
            else { $p = $cmd.Parameters.Add($key,[Data.SqlDbType]::NVarChar,4000) }
            $p.Value = $value
        }
        $reader = $cmd.ExecuteReader()
        $count = 0
        while ($reader.Read()) {
            if ($count -ge $Limit) { throw 'Unexpected row cap exceeded.' }
            $row = [ordered]@{}
            for ($i=0; $i -lt $reader.FieldCount; $i++) {
                $v = $reader.GetValue($i)
                if ($v -is [DBNull]) { $v = $null }
                elseif ($v -is [DateTime]) { $v = $v.ToString('o',[Globalization.CultureInfo]::InvariantCulture) }
                $row[$reader.GetName($i)] = $v
            }
            [pscustomobject]$row
            $count++
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $cmd.Dispose()
    }
}
$root = [IO.Path]::GetFullPath((Join-Path $OutputDirectory ('query_{0}_{1}_{2}' -f $CaseId,[DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'),[guid]::NewGuid().ToString('N').Substring(0,6))))
if ($root.StartsWith('\\')) { throw 'Use a local output directory, not a UNC share.' }
$drive = [IO.DriveInfo]::new([IO.Path]::GetPathRoot($root))
if ($drive.AvailableFreeSpace -lt 512MB) { throw 'Less than 512 MiB free on output volume.' }
[void][IO.Directory]::CreateDirectory($root)
$utf8 = [Text.UTF8Encoding]::new($false)
$evidence = [ordered]@{
    schema_version='query-evidence/0.1'; tool_version='0.1.0-pilot'; case_id=$CaseId;
    started_utc=[DateTime]::UtcNow.ToString('o'); host=$env:COMPUTERNAME;
    sql_instance=$SqlInstance; database=$Database; query_hash=$QueryHash;
    powershell_version=$PSVersionTable.PSVersion.ToString();
    script_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash;
    include_sql_text=[bool]$IncludeSqlText; include_plan=[bool]$IncludePlan;
    trust_server_certificate=[bool]$TrustServerCertificate; encrypt=$true;
    max_plans=$MaxPlans; query_timeout_seconds=$QueryTimeoutSeconds;
    cache_status='not_collected'; candidates_truncated=$false; candidates=@(); artifacts=@();
    warning='CONFIDENTIAL. Plans also contain SQL text, literals and compiled parameters. No automatic upload.';
    scope_note='Cached completed-execution totals since compile, NOT capture-interval deltas. Cache lookup may scan DMV entries; bounded by query timeout.';
    plan_note='Cached compile-time plan, NOT actual runtime execution plan. Cache eviction/recompile can make evidence unavailable.';
    validation='PILOT. Windows/SQL runtime not validated during development.'
}
$conn = $null
try {
    if ($IncludeSqlText -or $IncludePlan) { Write-Warning $evidence.warning }
    $conn = New-QueryConnection -Instance $SqlInstance -Catalog $Database -Timeout $QueryTimeoutSeconds -Trust ([bool]$TrustServerCertificate) -Credential $SqlCredential
    $conn.Open()
    $preflight = @'
DECLARE @major int = CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));
IF @major < 13 THROW 50000, 'SQL Server 2016 or later is required.', 1;
IF ISNULL(IS_SRVROLEMEMBER('sysadmin'),0) <> 1
   AND ((@major < 16 AND ISNULL(HAS_PERMS_BY_NAME(NULL,NULL,'VIEW SERVER STATE'),0) <> 1)
     OR (@major >= 16 AND ISNULL(HAS_PERMS_BY_NAME(NULL,NULL,'VIEW SERVER PERFORMANCE STATE'),0) <> 1))
    THROW 50001, 'Server-wide performance DMV permission is required.', 1;
SELECT DB_ID() AS database_id, DB_NAME() AS database_name,
       CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion')) AS product_version;
'@
    $evidence['preflight'] = @(Read-QueryEvidence $conn $preflight @{} 1)
    $lookup = @'
SELECT TOP (@cap) TRY_CONVERT(int,pa.value) AS database_id,
       CONVERT(varchar(130),qs.sql_handle,1) AS sql_handle,
       CONVERT(varchar(130),qs.plan_handle,1) AS plan_handle,
       CONVERT(varchar(18),qs.query_hash,1) AS query_hash,
       CONVERT(varchar(18),qs.query_plan_hash,1) AS query_plan_hash,
       qs.statement_start_offset,qs.statement_end_offset,qs.plan_generation_num,
       qs.creation_time AS creation_time_sql_local,qs.last_execution_time AS last_execution_time_sql_local,
       qs.execution_count,qs.total_worker_time AS total_cpu_us,qs.last_worker_time AS last_cpu_us,
       qs.total_elapsed_time AS total_elapsed_us,qs.last_elapsed_time AS last_elapsed_us,
       qs.total_logical_reads,qs.last_logical_reads,qs.total_physical_reads,qs.last_physical_reads,
       qs.last_rows,qs.last_dop,qs.last_grant_kb,qs.last_used_grant_kb
FROM sys.dm_exec_query_stats AS qs
CROSS APPLY sys.dm_exec_plan_attributes(qs.plan_handle) AS pa
WHERE qs.query_hash=CONVERT(binary(8),@hash,1)
  AND pa.attribute='dbid' AND TRY_CONVERT(int,pa.value)=DB_ID()
ORDER BY qs.last_execution_time DESC,qs.total_worker_time DESC
OPTION (MAXDOP 1);
'@
    $candidates = @(Read-QueryEvidence $conn $lookup @{ '@hash'=$QueryHash; '@cap'=($MaxPlans+1) } ($MaxPlans+1))
    $evidence.candidates_truncated = ($candidates.Count -gt $MaxPlans)
    $evidence.candidates = @($candidates | Select-Object -First $MaxPlans)
    $evidence.cache_status = if ($candidates.Count -eq 0) { 'not_found' } else { 'found' }
    if ($candidates.Count -eq 0) { Write-Warning 'No matching cached statement found. This does not rule out the query; rerun after the operation without clearing caches.' }
    $n = 0
    foreach ($row in $evidence.candidates) {
        $n++
        $parameters = @{'@sql'=$row.sql_handle;'@plan'=$row.plan_handle;
                        '@start'=[int]$row.statement_start_offset;'@end'=[int]$row.statement_end_offset}
        foreach ($kind in @('text','plan')) {
            if (($kind -eq 'text' -and -not $IncludeSqlText) -or ($kind -eq 'plan' -and -not $IncludePlan)) { continue }
            # Plan inclusion itself authorizes SQL/compiled literals contained within Showplan.
            if ($kind -eq 'text') {
                $sql = @'
SELECT DATALENGTH(part.statement_text) AS original_bytes,
       LEFT(part.statement_text,65536) AS payload
FROM sys.dm_exec_sql_text(CONVERT(varbinary(64),@sql,1)) AS st
CROSS APPLY (SELECT SUBSTRING(st.text,(@start/2)+1,
             ((CASE WHEN @end=-1 THEN DATALENGTH(st.text) ELSE @end END-@start)/2)+1) AS statement_text) AS part;
'@
                $capBytes = 131072; $filename = 'statement_{0}.sql' -f $n
            } else {
                $sql = @'
SELECT DATALENGTH(p.query_plan) AS original_bytes,LEFT(p.query_plan,2097152) AS payload
FROM sys.dm_exec_text_query_plan(CONVERT(varbinary(64),@plan,1),@start,@end) AS p;
'@
                $capBytes = 4194304; $filename = 'plan_{0}.sqlplan' -f $n
            }
            $artifact = [ordered]@{candidate=$n;kind=$kind;status='missing';file=$null}
            try {
                $part = @(Read-QueryEvidence $conn $sql $parameters 1)
                if ($part.Count -and $null -ne $part[0].payload) {
                    $artifact['original_bytes'] = $part[0].original_bytes
                    $artifact.status = if ([long]$part[0].original_bytes -gt $capBytes) { 'truncated' } else { 'ok' }
                    if ($artifact.status -eq 'truncated') { $filename += '.truncated.txt' }
                    [IO.File]::WriteAllText((Join-Path $root $filename),[string]$part[0].payload,$utf8)
                    $artifact.file = $filename
                }
            } catch { $artifact.status='error'; $artifact['error']=$_.Exception.Message }
            $evidence.artifacts += [pscustomobject]$artifact
        }
    }
} catch {
    $evidence.cache_status = 'error'
    $evidence['error'] = $_.Exception.Message
    Write-Warning $_.Exception.Message
} finally {
    if ($null -ne $conn) { $conn.Dispose() }
    $evidence['ended_utc'] = [DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $root 'query-evidence.json'),($evidence | ConvertTo-Json -Depth 8),$utf8)
    Write-Host ('Cache status: '+$evidence.cache_status+'; candidates: '+$evidence.candidates.Count)
    foreach ($item in $evidence.artifacts) {
        if ($item.status -ne 'ok') { Write-Warning ('Artifact '+$item.kind+': '+$item.status+'; see query-evidence.json.') }
    }
    try { Compress-Archive -Path (Join-Path $root '*') -DestinationPath ($root+'.zip') -CompressionLevel Fastest; Write-Host ('Query evidence archive: '+$root+'.zip') }
    catch { Write-Warning ('ZIP creation failed; raw files remain at '+$root) }
}
