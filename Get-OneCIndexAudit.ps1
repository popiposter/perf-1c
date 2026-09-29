#requires -Version 7.0
<#
Opt-in, read-only index/statistics audit of ONE explicit database. Requires sql/*.sql
from the same checkout; Start-OneCPerf.ps1 -IndexAudit downloads the whole snapshot.
No ALTER INDEX, UPDATE STATISTICS, jobs, user rows, histograms or automatic uploads.
PILOT: SQL/Windows execution requires supervised validation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SqlInstance,
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Database,
    [pscredential]$SqlCredential,
    [switch]$TrustServerCertificate,
    [ValidateRange(1,200)][int]$MaxIndexes=30,
    [ValidateRange(1,5000)][int]$MaxStatistics=1000,
    [ValidateRange(1,900)][int]$BudgetSeconds=60,
    [ValidateRange(0,1000000000)][int]$MinPages=1000,
    [ValidateRange(0,2147483647)][int]$ObjectId=0,
    [ValidateSet('LIMITED','SAMPLED')][string]$ScanMode='LIMITED',
    [ValidateRange(1,15)][int]$QueryTimeoutSeconds=3,
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$CaseId='case01',
    [ValidatePattern('^$|^[0-9a-fA-F]{40}$')][string]$SourceCommit='',
    [string]$OutputDirectory=(Join-Path $env:LOCALAPPDATA 'perf-1c/captures')
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
if (-not $IsWindows -or -not [Environment]::Is64BitProcess) { throw 'Windows x64 PowerShell 7 is required.' }
if ($Database -in @('master','model','msdb','tempdb') -or $Database.Length -gt 128 -or $Database -match '[\x00-\x1f]') {
    throw 'Specify one explicit user database.'
}
if ($ScanMode -eq 'SAMPLED' -and $ObjectId -eq 0) {
    throw 'SAMPLED requires an explicit -ObjectId. It may scan all pages of a small index; there is no database-wide sampled mode.'
}

function New-IndexAuditConnection {
    param([string]$Catalog)
    $b=[System.Data.SqlClient.SqlConnectionStringBuilder]::new()
    $b['Data Source']=$SqlInstance; $b['Initial Catalog']=$Catalog
    $b['Application Name']='OneCPerfIndexAudit/0.1.0-pilot'
    $b['Connect Timeout']=$QueryTimeoutSeconds; $b['Encrypt']=$true
    $b['TrustServerCertificate']=[bool]$TrustServerCertificate
    $b['Pooling']=$false; $b['Persist Security Info']=$false
    $b['Integrated Security']=($null -eq $SqlCredential)
    $c=[System.Data.SqlClient.SqlConnection]::new($b.get_ConnectionString())
    try {
        if ($null -ne $SqlCredential) {
            $p=$SqlCredential.Password.Copy(); $p.MakeReadOnly()
            $c.Credential=[System.Data.SqlClient.SqlCredential]::new($SqlCredential.UserName,$p)
        }
        return $c
    } catch { $c.Dispose(); throw }
}
function Read-IndexAuditSql {
    param([string]$Name,[string]$Catalog,[hashtable]$Parameters,[int]$Limit)
    if (-not $script:connections.ContainsKey($Catalog)) { $script:connections[$Catalog]=New-IndexAuditConnection $Catalog }
    $c=$script:connections[$Catalog]
    if ($c.State -ne [Data.ConnectionState]::Open) { $c.Open() }
    $cmd=$c.CreateCommand(); $reader=$null
    try {
        $cmd.CommandTimeout=$QueryTimeoutSeconds
        $cmd.CommandText="SET NOCOUNT ON; SET DEADLOCK_PRIORITY LOW; SET LOCK_TIMEOUT 1000;`n"+
            [IO.File]::ReadAllText((Join-Path $PSScriptRoot ('sql/'+$Name+'.sql')))
        foreach ($key in $Parameters.Keys) {
            $v=$Parameters[$key]
            if ($v -is [int]) { $p=$cmd.Parameters.Add($key,[Data.SqlDbType]::Int) }
            elseif ($v -is [DateTime]) { $p=$cmd.Parameters.Add($key,[Data.SqlDbType]::DateTime) }
            else { $p=$cmd.Parameters.Add($key,[Data.SqlDbType]::NVarChar,4000) }
            $p.Value=$v
        }
        $reader=$cmd.ExecuteReader(); $n=0
        while ($reader.Read()) {
            $row=[ordered]@{}
            for ($i=0;$i -lt $reader.FieldCount;$i++) {
                $v=$reader.GetValue($i)
                if ($v -is [DBNull]) { $v=$null }
                elseif ($v -is [DateTime]) { $v=$v.ToString('o',[Globalization.CultureInfo]::InvariantCulture) }
                $row[$reader.GetName($i)]=$v
            }
            [pscustomobject]$row; $n++
            if ($n -gt $Limit) { $cmd.Cancel(); break }
        }
    } finally { if ($null -ne $reader) { $reader.Dispose() }; $cmd.Dispose() }
}
function Write-IndexAuditRecord {
    param([hashtable]$Record)
    $Record.schema_version='0.1'; $Record.tick=0; $Record.host=$env:COMPUTERNAME
    $text=ConvertTo-Json -InputObject $Record -Depth 8 -Compress
    $nextBytes=$script:bytes+$script:utf8.GetByteCount($text)+1
    $limitBytes=if($Record.source -eq 'sql.index_audit_summary'){32MB}else{31MB}
    if ($nextBytes -gt $limitBytes) { throw 'Index audit output cap reached; raw files are preserved.' }
    $script:bytes=$nextBytes
    $script:writer.WriteLine($text)
    $script:states.Add([pscustomobject]@{source=$Record.source;status=$Record.status;duration_ms=$Record.duration_ms;row_count=$Record.row_count})
    $script:last=$Record
}
function Invoke-IndexAuditSource {
    param([string]$Name,[hashtable]$Parameters,[int]$Limit=1,[string]$Catalog=$Database,[switch]$RequireRow)
    if ($script:watch.Elapsed.TotalSeconds -ge $BudgetSeconds) {
        $script:budgetHit=$true
        Write-IndexAuditRecord @{source=('sql.'+$Name);status='skipped';rows=@();row_count=0;
            collected_utc=[DateTime]::UtcNow.ToString('o');ended_utc=[DateTime]::UtcNow.ToString('o');
            duration_ms=0;error='Audit budget reached before starting this source.'}
        return
    }
    $t=[DateTime]::UtcNow; $sw=[Diagnostics.Stopwatch]::StartNew()
    try {
        $rows=@(Read-IndexAuditSql $Name $Catalog $Parameters $Limit)
        $status='ok'
        if ($rows.Count -gt $Limit) { $status='truncated'; $rows=@($rows | Select-Object -First $Limit) }
        if ($RequireRow -and $rows.Count -eq 0) { throw 'Expected index/preflight row is missing; it may have changed or become inaccessible.' }
        Write-IndexAuditRecord @{source=('sql.'+$Name);status=$status;rows=$rows;row_count=$rows.Count;row_limit=$Limit;
            collected_utc=$t.ToString('o');ended_utc=[DateTime]::UtcNow.ToString('o');
            duration_ms=$sw.Elapsed.TotalMilliseconds;error=$null}
    } catch {
        Write-Warning ('sql.'+$Name+': '+$_.Exception.Message)
        Write-IndexAuditRecord @{source=('sql.'+$Name);status='error';rows=@();row_count=0;
            collected_utc=$t.ToString('o');ended_utc=[DateTime]::UtcNow.ToString('o');
            duration_ms=$sw.Elapsed.TotalMilliseconds;error=$_.Exception.Message}
    }
}

$started=[DateTime]::UtcNow
$hostSafe=$env:COMPUTERNAME -replace '[^A-Za-z0-9_.-]','_'
$root=[IO.Path]::GetFullPath((Join-Path $OutputDirectory ('index_{0}_{1}_{2}_{3}' -f $CaseId,$hostSafe,$started.ToString('yyyyMMddTHHmmssZ'),[guid]::NewGuid().ToString('N').Substring(0,6))))
if ($root.StartsWith('\\')) { throw 'Use a local output directory.' }
if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($root)).AvailableFreeSpace -lt 512MB) { throw 'Less than 512 MiB free on output volume.' }
[void][IO.Directory]::CreateDirectory($root)
$script:utf8=[Text.UTF8Encoding]::new($false)
$script:writer=[IO.StreamWriter]::new((Join-Path $root 'records.jsonl'),$false,$script:utf8)
$script:writer.AutoFlush=$true
$script:connections=@{}; $script:states=[Collections.Generic.List[object]]::new()
$script:last=$null; $script:bytes=0L; $script:budgetHit=$false
$script:watch=[Diagnostics.Stopwatch]::StartNew()
$manifest=[ordered]@{schema_version='0.1';profile='index-audit';collector_version='index-audit/0.1.0-pilot';
    source_commit=$SourceCommit;collector_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash;
    started_utc=$started.ToString('o');host=$env:COMPUTERNAME;case_id=$CaseId;
    sql_instance=$SqlInstance;selected_database=$Database;skip_sql=$false;
    powershell_version=$PSVersionTable.PSVersion.ToString();sql_encryption=$true;
    trust_server_certificate=[bool]$TrustServerCertificate;scan_mode=$ScanMode;object_id_filter=$ObjectId;
    index_audit_min_pages=$MinPages;max_indexes=$MaxIndexes;max_statistics=$MaxStatistics;
    budget_seconds=$BudgetSeconds;query_timeout_seconds=$QueryTimeoutSeconds;
    sql_text_collected=$false;user_data_collected=$false;
    warning='CONFIDENTIAL: database/schema/table/index names and paths. No automatic upload.';
    scope_note='One database, largest eligible rowstore partitions; bounded metadata for statistics and heaps. NOT a full database certification.';
    budget_note='Soft total budget: do not start another query after expiry; in-flight query uses its own timeout. Cancellation/cleanup can take longer.';
    test_status='PILOT: new SQL/PS paths require supervised Windows/SQL validation.'}
Write-Host ('Index audit: '+$Database+'; '+$ScanMode+'; maximum '+$MaxIndexes+' partitions; source '+$SourceCommit)
Write-Warning 'Physical index inspection takes locks and I/O. Use a quiet period; Ctrl+C stops collection. No indexes will be changed.'
$attempted=0; $measured=0; $candidateCount=$null; $physicalErrors=0
try {
    Add-Type -AssemblyName System.Data.SqlClient
    Invoke-IndexAuditSource 'index_audit_preflight' @{'@ObjectId'=$ObjectId} -RequireRow
    if ($script:last.status -ne 'ok') { throw 'Index audit preflight failed or budget expired; no physical scan was started.' }
    $manifest['requested_database']=$Database
    $manifest['selected_database']=[string]$script:last.rows[0].database_name
    $manifest['database_id']=[int]$script:last.rows[0].database_id
    # Cheap metadata and bounded stats precede physical inspection, so partial captures remain useful.
    Invoke-IndexAuditSource 'statistics_health' @{'@Limit'=($MaxStatistics+1);'@ObjectId'=$ObjectId} -Limit $MaxStatistics
    Invoke-IndexAuditSource 'heap_health' @{'@Limit'=101;'@MinPages'=$MinPages;'@ObjectId'=$ObjectId} -Limit 100
    Invoke-IndexAuditSource 'index_maintenance_history' @{'@Limit'=101;'@Database'=$Database} -Limit 100 -Catalog 'msdb'
    Invoke-IndexAuditSource 'index_inventory' @{'@Limit'=($MaxIndexes+1);'@MinPages'=$MinPages;'@ObjectId'=$ObjectId} -Limit $MaxIndexes
    if ($script:last.status -in @('ok','truncated')) {
        $inventory=@($script:last.rows)
        $candidateCount=if ($inventory.Count) { [long]$inventory[0].total_candidates } else { 0 }
        foreach ($row in $inventory) {
            if ($script:watch.Elapsed.TotalSeconds -ge $BudgetSeconds) { $script:budgetHit=$true; break }
            $attempted++
            $par=@{'@ObjectId'=[int]$row.object_id;'@IndexId'=[int]$row.index_id;
                '@PartitionNumber'=[int]$row.partition_number;'@ScanMode'=$ScanMode;
                '@ObjectName'=[string]$row.table_name;'@IndexName'=[string]$row.index_name;
                '@ObjectCreateDate'=[DateTime]::Parse($row.object_create_date_sql_local,[Globalization.CultureInfo]::InvariantCulture)}
            Invoke-IndexAuditSource 'index_health' $par -Limit 1 -RequireRow
            if ($script:last.status -eq 'ok') { $measured++; $physicalErrors=0 }
            else { $physicalErrors++ }
            if ($physicalErrors -ge 3) { Write-Warning 'Three successive physical-source errors: stopping inspection.'; break }
        }
    }
} catch { $manifest.fatal_error=$_.Exception.Message; Write-Warning $_.Exception.Message }
finally {
    $bad=@($script:states | Where-Object status -ne 'ok').Count
    $complete=($null -ne $candidateCount -and $measured -eq $candidateCount -and $bad -eq 0 -and -not $script:budgetHit -and -not $manifest.Contains('fatal_error'))
    $completion=if($complete){'complete_requested_scope'}else{'partial'}
    try {
    Write-IndexAuditRecord @{source='sql.index_audit_summary';status='ok';collected_utc=[DateTime]::UtcNow.ToString('o');
        ended_utc=[DateTime]::UtcNow.ToString('o');duration_ms=0;error=$null;row_count=1;
        rows=@([pscustomobject]@{completion=$completion;candidate_partitions=$candidateCount;attempted_partitions=$attempted;
            measured_partitions=$measured;budget_hit=$script:budgetHit;non_ok_sources=$bad})}
    } catch { $manifest['fatal_error']=$_.Exception.Message; $complete=$false; $completion='partial' }
    finally {
        foreach ($c in $script:connections.Values) { $c.Dispose() }
        $script:writer.Dispose()
    }
    $manifest.ended_utc=[DateTime]::UtcNow.ToString('o');$manifest.stop_reason=$completion
    $manifest.raw_output_bytes=$script:bytes
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),(ConvertTo-Json -InputObject $manifest -Depth 8),$script:utf8)
    [IO.File]::WriteAllText((Join-Path $root 'coverage.json'),(ConvertTo-Json -InputObject @($script:states.ToArray()) -Depth 6),$script:utf8)
    $intro='<h1>Index/statistics audit coverage</h1><p>'+ $completion +': '+$measured+' measured partitions.</p><p>Coverage only, NOT a health verdict. Run analyze.py on this ZIP for recommendations. Missing properties/untested indexes are unknown. Confidential.</p>'
    $html=$script:states | ConvertTo-Html -Title 'Index audit coverage' -PreContent $intro
    [IO.File]::WriteAllText((Join-Path $root 'coverage.html'),($html -join "`n"),$script:utf8)
    try { Compress-Archive -Path (Join-Path $root '*') -DestinationPath ($root+'.zip') -CompressionLevel Fastest; Write-Host ('Index audit archive: '+$root+'.zip') }
    catch { Write-Warning ('ZIP creation failed; raw files remain in '+$root) }
    if (-not $complete) { Write-Warning 'PARTIAL audit. Read coverage and audit summary; do not assume unmeasured indexes are healthy.' }
}
