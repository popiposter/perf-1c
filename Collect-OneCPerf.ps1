#requires -Version 5.1
<#
Portable, bounded diagnostic collection for Windows x64: PowerShell 7 or Windows PowerShell 5.1.
No installed services, no system/configuration changes, no user-table queries.
SQL credentials and SQL text/plans are not written to the output.
This is a pilot, not yet integration-tested on Windows/SQL Server.
#>
[CmdletBinding()]
param(
    [string]$SqlInstance = '',
    [string]$Database = '',
    [ValidateRange(0,60)][int]$Minutes = 10,
    [ValidateRange(5,300)][int]$IntervalSeconds = 15,
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$CaseId = 'case01',
    [ValidateSet('sql','onec','combined','other')][string]$Role = 'combined',
    [string]$OutputDirectory = (Join-Path $PSScriptRoot 'output'),
    [System.Management.Automation.PSCredential]$SqlCredential,
    [switch]$TrustServerCertificate,
    [switch]$SkipSql,
    [switch]$IncludeMaintenance,
    [ValidatePattern('^$|^[0-9a-fA-F]{40}$')][string]$SourceCommit = '',
    [ValidateRange(1,15)][int]$QueryTimeoutSeconds = 3,
    [ValidateRange(16,512)][int]$MaxOutputMB = 128
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Windows is required for the CIM/1C host profile.' }
if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit PowerShell.' }
if ($PSVersionTable.PSEdition -ne 'Desktop' -and $PSVersionTable.PSVersion.Major -lt 7) {
    throw 'Use PowerShell 7 (pwsh.exe) or Windows PowerShell 5.1.'
}
if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
    throw 'Get-CimInstance is unavailable. Use a standard Windows PowerShell installation with CimCmdlets.'
}
if (-not $SkipSql -and [string]::IsNullOrWhiteSpace($SqlInstance)) {
    throw 'Specify -SqlInstance, or use -SkipSql for Windows/1C host metrics only.'
}
# Windows PowerShell loads the Framework provider; PS7 ships a separate SqlClient assembly.
# No SQL module, NuGet download, compatibility process or driver install is required.
if (-not $SkipSql) {
    try {
        if ($PSVersionTable.PSEdition -eq 'Desktop') { Add-Type -AssemblyName System.Data }
        else { Add-Type -AssemblyName System.Data.SqlClient }
        $probe = New-Object System.Data.SqlClient.SqlConnection
        $probe.Dispose()  # Validate the provider without opening a connection.
    } catch {
        throw ('System.Data.SqlClient is unavailable in this PowerShell installation. ' +
            'Use a standard Windows x64 PowerShell distribution, or -SkipSql for host metrics. ' + $_.Exception.Message)
    }
}
$started = [DateTime]::UtcNow
$hostSafe = $env:COMPUTERNAME -replace '[^A-Za-z0-9_.-]','_'
$folderName = '{0}_{1}_{2}_{3}' -f $CaseId,$hostSafe,$started.ToString('yyyyMMddTHHmmssZ'),([guid]::NewGuid().ToString('N').Substring(0,6))
$root = [IO.Path]::GetFullPath((Join-Path $OutputDirectory $folderName))
if ($root.StartsWith('\\')) { throw 'Choose a local output directory, not a UNC share.' }
[void][IO.Directory]::CreateDirectory($root)
$utf8 = New-Object System.Text.UTF8Encoding($false)
$writer = New-Object System.IO.StreamWriter((Join-Path $root 'records.jsonl'),$false,$utf8)
$writer.AutoFlush = $true
$script:OutputBytes = 0L
$script:Failures = @{}
$script:Disabled = @{}
$script:Coverage = @{}
$script:SqlConnections = @{}
$script:SqlErrorHints = @{}
$script:RuntimeSqlAllowed = $false
$script:Major = 0
$script:Tick = -1
$script:LastRecord = $null
$maxBytes = [long]$MaxOutputMB * 1MB
$stopReason = 'interrupted_or_incomplete'
$manifest = [ordered]@{
    schema_version='0.1'; collector_version='0.1.3-pilot'; case_id=$CaseId;
    source_commit=$SourceCommit; collector_pid=$PID; powershell_version=$PSVersionTable.PSVersion.ToString();
    powershell_edition=$PSVersionTable.PSEdition; dotnet_version=[Environment]::Version.ToString();
    collector_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();
    host=$env:COMPUTERNAME; role=$Role; started_utc=$started.ToString('o');
    timezone=[TimeZoneInfo]::Local.Id; utc_offset_minutes=[TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalMinutes;
    sql_instance=$SqlInstance; selected_database=$Database; skip_sql=[bool]$SkipSql;
    minutes=$Minutes; interval_seconds=$IntervalSeconds; query_timeout_seconds=$QueryTimeoutSeconds;
    max_output_mb=$MaxOutputMB; include_maintenance=[bool]$IncludeMaintenance;
    sql_encryption=$true; trust_server_certificate=[bool]$TrustServerCertificate;
    query_text_collected=$false; query_plans_collected=$false; user_table_data_collected=$false;
    warning='Contains host names, database names, file paths, process IDs and job names. NOT anonymized. Do not upload without review.';
    windows_scope='LOCAL HOST ONLY; SQL may be remote. No hypervisor or SAN telemetry.';
    not_implemented=@('1C RAS/RAC','1C technological log','SQL query text/plans','SQL Query Store workload history','Extended Events','event logs','index/statistics deep audit','hypervisor/SAN metrics');
    sql_datetime_note='Unspecified SQL DateTime values retain SQL local time; explicit UTC fields are labeled.';
    test_status='Offline analyzer tests only. Collector requires a supervised pilot on Windows and SQL Server.'
}
function Save-Manifest {
    [IO.File]::WriteAllText((Join-Path $root 'manifest.json'),($manifest | ConvertTo-Json -Depth 8),$utf8)
}
function Emit-Record {
    param([hashtable]$Record)
    $Record['schema_version']='0.1'
    $Record['tick']=$script:Tick
    $Record['host']=$env:COMPUTERNAME
    $json=$Record | ConvertTo-Json -Depth 8 -Compress
    $writer.WriteLine($json)
    $script:OutputBytes += $utf8.GetByteCount($json)+2
    $script:LastRecord=$Record
    $key=[string]$Record.source
    if (-not $script:Coverage.ContainsKey($key)) {
        $script:Coverage[$key]=[ordered]@{source=$key;ok=0;error=0;skipped=0;truncated=0;total_ms=0.0}
    }
    $c=$script:Coverage[$key]
    $state=[string]$Record.status
    if ($c.Contains($state)) { $c[$state]++ }
    $c.total_ms += [double]$Record.duration_ms
}
function Get-OneCPerfSqlErrorHint {
    # Conservative message classification, not a certificate inspection or login test.
    # Unknown TLS errors, permissions and other sources must not suggest bypassing trust.
    param([string]$Source,[string]$Message)
    if ($Source -notlike 'sql.*') { return $null }
    $untrusted = $Message -match '(?i)certificate chain was issued by an authority that is not trusted' -or
        $Message -match '(?i)цепочка сертификатов выпущена центром сертификации, не имеющим доверия'
    if (-not $untrusted) { return $null }
    [pscustomobject]@{
        error_kind='sql_certificate_untrusted'
        suggested_action=('SQL certificate trust validation failed. Configure a verifiable server certificate and trusted CA chain. ' +
            'For a temporary diagnostic run against an explicitly trusted endpoint, the operator may add -TrustServerCertificate. ' +
            'Encrypt=True remains enabled, but server identity is not validated. No automatic retry or security downgrade is performed. ' +
            'If that switch is already set, investigate the actual endpoint/provider. This error does not establish a login, permission or performance problem.')
    }
}
function Collect-Source {
    param([string]$Source,[scriptblock]$Action,[int]$Limit=5000)
    if ($script:OutputBytes -ge $maxBytes) { return }
    if ($script:Disabled.ContainsKey($Source)) { return }
    $t=[DateTime]::UtcNow
    $sw=[Diagnostics.Stopwatch]::StartNew()
    try {
        $rows=@(& $Action)
        $status='ok'
        if ($rows.Count -gt $Limit) { $status='truncated'; $rows=@($rows | Select-Object -First $Limit) }
        $script:Failures[$Source]=0
        Emit-Record @{source=$Source;status=$status;collected_utc=$t.ToString('o');
            ended_utc=[DateTime]::UtcNow.ToString('o');duration_ms=$sw.Elapsed.TotalMilliseconds;
            row_count=$rows.Count;row_limit=$Limit;rows=$rows;error=$null}
    } catch {
        $errorMessage=$_.Exception.Message
        $errorKind=$null; $suggestedAction=$null
        $sqlHint=Get-OneCPerfSqlErrorHint -Source $Source -Message $errorMessage
        if ($null -ne $sqlHint) {
            $errorKind=$sqlHint.error_kind
            $suggestedAction=$sqlHint.suggested_action
            if (-not $script:SqlErrorHints.ContainsKey($errorKind)) {
                $script:SqlErrorHints[$errorKind]=$suggestedAction
                Write-Warning $suggestedAction
            }
        }
        if (-not $script:Failures.ContainsKey($Source)) { $script:Failures[$Source]=0 }
        $script:Failures[$Source]++
        if ($script:Failures[$Source] -eq 1) {
            Write-Warning ('Source '+$Source+' failed: '+$errorMessage)
        }
        if ($script:Failures[$Source] -ge 3) { $script:Disabled[$Source]=$true }
        Emit-Record @{source=$Source;status='error';collected_utc=$t.ToString('o');
            ended_utc=[DateTime]::UtcNow.ToString('o');duration_ms=$sw.Elapsed.TotalMilliseconds;
            row_count=0;rows=@();error=$errorMessage;
            error_kind=$errorKind;suggested_action=$suggestedAction;
            disabled_after_three_errors=$script:Disabled.ContainsKey($Source)}
    }
}
function Skip-Source {
    param([string]$Source,[string]$Reason)
    Emit-Record @{source=$Source;status='skipped';collected_utc=[DateTime]::UtcNow.ToString('o');
        ended_utc=[DateTime]::UtcNow.ToString('o');duration_ms=0;rows=@();row_count=0;error=$Reason}
}
function Read-Cim {
    param([string]$Class,[string[]]$Fields,[string]$Filter='')
    $argsCim=@{ClassName=$Class;Property=$Fields;OperationTimeoutSec=5;ErrorAction='Stop'}
    if ($Filter) { $argsCim.Filter=$Filter }
    Get-CimInstance @argsCim | Select-Object -Property $Fields
}
function New-OneCPerfSqlConnection {
    # Construct without connecting, so tests exercise the real connection-string path.
    param(
        [string]$Instance,
        [string]$Catalog,
        [int]$TimeoutSeconds = 3,
        [bool]$TrustCertificate = $false,
        [System.Management.Automation.PSCredential]$Credential
    )
    $builder=New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    # PowerShell can adapt this IDictionary before its CLR properties. Use the
    # provider's canonical keywords, not property names such as DataSource.
    $builder['Data Source']=$Instance
    $builder['Initial Catalog']=$Catalog
    $builder['Application Name']='OneCPerfDiag/0.1.3'
    $builder['Connect Timeout']=$TimeoutSeconds
    $builder['Encrypt']=$true
    $builder['TrustServerCertificate']=$TrustCertificate
    $builder['Persist Security Info']=$false
    $builder['Pooling']=$false
    $builder['Integrated Security']=($null -eq $Credential)
    $conn=New-Object System.Data.SqlClient.SqlConnection
    try {
        $conn.ConnectionString=$builder.get_ConnectionString()
        if ($null -ne $Credential) {
            $secure=$Credential.Password.Copy()
            $secure.MakeReadOnly()
            $conn.Credential=New-Object System.Data.SqlClient.SqlCredential($Credential.UserName,$secure)
        }
        return $conn
    } catch {
        $conn.Dispose()
        throw
    }
}
function Get-SqlConnection {
    param([string]$Catalog)
    if (-not $script:SqlConnections.ContainsKey($Catalog)) {
        $script:SqlConnections[$Catalog]=New-OneCPerfSqlConnection -Instance $SqlInstance -Catalog $Catalog `
            -TimeoutSeconds $QueryTimeoutSeconds -TrustCertificate ([bool]$TrustServerCertificate) -Credential $SqlCredential
    }
    $connection=$script:SqlConnections[$Catalog]
    if ($connection.State -ne [Data.ConnectionState]::Open) {
        $connection.Close()
        $connection.Open()
    }
    return $connection
}
function Read-Sql {
    param([string]$Name,[string]$Catalog='master',[int]$Limit=5000)
    $conn=Get-SqlConnection $Catalog
    $cmd=$conn.CreateCommand()
    $cmd.CommandTimeout=$QueryTimeoutSeconds
    $reader=$null
    try {
        $query=[IO.File]::ReadAllText((Join-Path $PSScriptRoot ('sql\'+$Name+'.sql')))
        $cmd.CommandText="SET NOCOUNT ON; SET DEADLOCK_PRIORITY LOW; SET LOCK_TIMEOUT 1000;`n"+$query
        if ($Name -eq 'backups') {
            [void]$cmd.Parameters.Add('@db',[Data.SqlDbType]::NVarChar,128)
            $cmd.Parameters['@db'].Value=$Database
        }
        $reader=$cmd.ExecuteReader()
        $count=0
        while ($reader.Read()) {
            $row=[ordered]@{}
            for ($i=0;$i -lt $reader.FieldCount;$i++) {
                $value=$reader.GetValue($i)
                if ($value -is [DBNull]) { $value=$null }
                elseif ($value -is [DateTime]) { $value=$value.ToString('o',[Globalization.CultureInfo]::InvariantCulture) }
                $row[$reader.GetName($i)]=$value
            }
            [pscustomobject]$row
            $count++
            if ($count -gt $Limit) { $cmd.Cancel(); break }
        }
    } finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $cmd.Dispose()
    }
}
function Collect-Sql {
    param([string]$Name,[string]$Catalog='master',[int]$Limit=5000)
    Collect-Source ('sql.'+$Name) { Read-Sql -Name $Name -Catalog $Catalog -Limit $Limit } -Limit $Limit
}
function Ensure-Space {
    $drive=New-Object System.IO.DriveInfo([IO.Path]::GetPathRoot($root))
    if ($drive.AvailableFreeSpace -lt 512MB) { throw 'Less than 512 MiB free on output volume. Collection stopped.' }
}
Save-Manifest
Write-Host ('Collector: '+$manifest.collector_version+'; source commit: '+$SourceCommit)
Write-Host ('Output: '+$root)
Write-Host 'Read-only pilot. Press Ctrl+C to stop. No services or tracing sessions will be left running.'
if (-not $SkipSql -and $TrustServerCertificate) {
    Write-Warning 'Operator selected -TrustServerCertificate for SQL only: Encrypt=True, server certificate validation bypassed. HTTPS download validation is unchanged.'
}
try {
    Ensure-Space
    Collect-Source 'windows.computer' { Read-Cim 'Win32_ComputerSystem' @('Manufacturer','Model','TotalPhysicalMemory','NumberOfLogicalProcessors','NumberOfProcessors','HypervisorPresent') }
    Collect-Source 'windows.os' { Read-Cim 'Win32_OperatingSystem' @('Caption','Version','BuildNumber','LastBootUpTime','TotalVisibleMemorySize','FreePhysicalMemory') }
    Collect-Source 'windows.cpu_inventory' { Read-Cim 'Win32_Processor' @('DeviceID','Name','NumberOfCores','NumberOfLogicalProcessors','MaxClockSpeed','CurrentClockSpeed') }
    Collect-Source 'windows.volumes' { Read-Cim 'Win32_LogicalDisk' @('DeviceID','DriveType','FileSystem','Size','FreeSpace') 'DriveType=3' }
    Collect-Source 'windows.disks' { Read-Cim 'Win32_DiskDrive' @('Index','Model','InterfaceType','Size','Partitions') }
    Collect-Source 'windows.power_plan' { Get-CimInstance -Namespace 'root/cimv2/power' -ClassName Win32_PowerPlan -Filter 'IsActive=True' -OperationTimeoutSec 5 | Select-Object ElementName,InstanceID,IsActive }
    # Do not collect service command lines: they can contain credentials.
    Collect-Source 'windows.services' { Read-Cim 'Win32_Service' @('Name','DisplayName','State','StartMode','ProcessId') "Name LIKE '%1C%' OR Name LIKE 'MSSQL%' OR Name LIKE 'SQLAgent%' OR Name LIKE 'SQLSERVERAGENT'" }
    Collect-Source 'windows.onec_versions' {
        Get-Process -Name rphost,rmngr,ragent -ErrorAction SilentlyContinue | ForEach-Object {
            $v=$null; $s='unavailable'
            try { $v=$_.MainModule.FileVersionInfo.FileVersion; $s='ok' } catch { }
            [pscustomobject]@{pid=$_.Id;process_name=$_.ProcessName;file_version=$v;version_status=$s}
        }
    }
    if (-not $SkipSql) {
        Collect-Sql 'instance'
        if ($script:LastRecord.status -eq 'ok' -and $script:LastRecord.rows.Count -gt 0) {
            $script:Major=[int](([string]$script:LastRecord.rows[0].product_version).Split('.')[0])
        }
        Collect-Sql 'permissions'
        if ($script:LastRecord.status -eq 'ok' -and $script:LastRecord.rows.Count -gt 0) {
            $perms=$script:LastRecord.rows[0]
            $script:RuntimeSqlAllowed=($perms.is_sysadmin -eq 1) -or
                (($script:Major -ge 16) -and ($perms.view_server_performance_state -eq 1)) -or
                (($script:Major -ge 13) -and ($script:Major -lt 16) -and ($perms.view_server_state -eq 1))
        }
        foreach ($name in @('configurations','databases','files')) { Collect-Sql $name }
        if (-not $script:RuntimeSqlAllowed) { Skip-Source 'sql.runtime' 'Version detection failed, SQL is older than 2016, or required server-wide DMV permission is absent. Runtime SQL collection skipped to prevent misleading partial session visibility.' }
        if ($Database) {
            foreach ($name in @('db_files','query_store_options','db_log_space')) { Collect-Sql $name $Database }
        } else { Skip-Source 'sql.database_details' 'No -Database selected.' }
        if ($IncludeMaintenance) {
            foreach ($name in @('backups','jobs','job_history')) { Collect-Sql $name 'msdb' 200 }
        } else { Skip-Source 'sql.maintenance' 'Use -IncludeMaintenance for a bounded read of msdb history.' }
    } else { Skip-Source 'sql.all' 'Operator selected -SkipSql.' }
    # Collection interval is a target, not a guarantee. Each source has its own timestamps.
    $watch=[Diagnostics.Stopwatch]::StartNew()
    do {
        Ensure-Space
        if ($script:OutputBytes -ge $maxBytes) { $stopReason='size_limit'; break }
        $script:Tick++
        $tickStart=$watch.Elapsed.TotalSeconds
        Collect-Source 'windows.cpu' { Read-Cim 'Win32_PerfFormattedData_PerfOS_Processor' @('Name','PercentProcessorTime','PercentPrivilegedTime') }
        Collect-Source 'windows.memory' { Read-Cim 'Win32_PerfFormattedData_PerfOS_Memory' @('AvailableMBytes','PagesInputPersec','PagesOutputPersec','CommittedBytes','CommitLimit') }
        Collect-Source 'windows.system' { Read-Cim 'Win32_PerfFormattedData_PerfOS_System' @('ProcessorQueueLength','ContextSwitchesPersec','SystemUpTime') }
        Collect-Source 'windows.processes' {
            Read-Cim 'Win32_PerfFormattedData_PerfProc_Process' @('Name','IDProcess','PercentProcessorTime','PrivateBytes','WorkingSet','IOReadBytesPersec','IOWriteBytesPersec') "Name LIKE 'sqlservr%' OR Name LIKE 'rphost%' OR Name LIKE 'rmngr%' OR Name LIKE 'ragent%' OR Name LIKE '1cv8%' OR Name LIKE 'w3wp%' OR Name LIKE 'powershell%' OR Name LIKE 'pwsh%'"
        } -Limit 1000
        # Store RAW disk counters. The offline analyzer computes latency from deltas;
        # formatted WMI averages can lose precision for sub-second disk latencies.
        Collect-Source 'windows.disk_raw' {
            Read-Cim 'Win32_PerfRawData_PerfDisk_LogicalDisk' @('Name','Timestamp_PerfTime','Frequency_PerfTime','AvgDisksecPerRead','AvgDisksecPerRead_Base','AvgDisksecPerWrite','AvgDisksecPerWrite_Base','DiskReadBytesPersec','DiskWriteBytesPersec','DiskReadsPersec','DiskWritesPersec','CurrentDiskQueueLength')
        }
        if (-not $SkipSql -and $script:RuntimeSqlAllowed) {
            foreach ($name in @('epoch','waits','io','requests','open_sessions','schedulers','memory','grants')) {
                $cap=5000
                if ($name -in @('requests','open_sessions')) { $cap=200 }
                Collect-Sql $name 'master' $cap
            }
        }
        $spent=$watch.Elapsed.TotalSeconds-$tickStart
        Emit-Record @{source='collector.tick';status='ok';collected_utc=[DateTime]::UtcNow.ToString('o');ended_utc=[DateTime]::UtcNow.ToString('o');
            duration_ms=$spent*1000;rows=@([pscustomobject]@{elapsed_seconds=$spent;interval_seconds=$IntervalSeconds;overrun=($spent -gt $IntervalSeconds)});row_count=1;error=$null}
        Write-Progress -Activity 'Collecting 1C / SQL / Windows diagnostics' -Status ('Sample {0}; {1:N1} MiB' -f $script:Tick,($script:OutputBytes/1MB))
        if ($Minutes -eq 0 -or $watch.Elapsed.TotalSeconds -ge $Minutes*60) { break }
        $remaining=$Minutes*60-$watch.Elapsed.TotalSeconds
        $pause=[Math]::Min([Math]::Max(0,$IntervalSeconds-$spent),$remaining)
        if ($pause -gt 0) { Start-Sleep -Milliseconds ([int]($pause*1000)) }
    } while ($watch.Elapsed.TotalSeconds -lt $Minutes*60)
    if ($stopReason -eq 'interrupted_or_incomplete') { $stopReason='completed' }
} catch {
    $stopReason='error'
    $manifest['fatal_error']=$_.Exception.Message
    Write-Warning $_.Exception.Message
} finally {
    foreach ($conn in $script:SqlConnections.Values) { $conn.Dispose() }
    $writer.Dispose()
    $manifest['ended_utc']=[DateTime]::UtcNow.ToString('o')
    $manifest['stop_reason']=$stopReason
    $manifest['samples_started']=$script:Tick+1
    $manifest['raw_output_bytes']=$script:OutputBytes
    $manifest['disabled_sources']=@($script:Disabled.Keys)
    $sourceErrors=0
    foreach ($entry in $script:Coverage.Values) { $sourceErrors += [int]$entry.error }
    $sqlRuntimeSamples=0
    if ($script:Coverage.ContainsKey('sql.epoch')) { $sqlRuntimeSamples=[int]$script:Coverage['sql.epoch'].ok }
    $manifest['source_error_count']=$sourceErrors
    $manifest['sql_runtime_sample_count']=$sqlRuntimeSamples
    $sqlDiagnostics=@($script:SqlErrorHints.Keys | Sort-Object | ForEach-Object {
        [pscustomobject]@{error_kind=$_;suggested_action=$script:SqlErrorHints[$_]}
    })
    $manifest['sql_connection_diagnostics']=$sqlDiagnostics
    if ($sourceErrors -gt 0) {
        Write-Warning ('Capture contains '+$sourceErrors+' source errors. Completed means the timer ended, not complete diagnostic coverage.')
    }
    if (-not $SkipSql -and $sqlRuntimeSamples -eq 0) {
        Write-Warning 'SQL runtime data was NOT collected. Do not use this archive to rule out SQL problems. See coverage.html.'
    }
    Save-Manifest
    $coverage=@($script:Coverage.Values | ForEach-Object { [pscustomobject]$_ })
    [IO.File]::WriteAllText((Join-Path $root 'coverage.json'),(ConvertTo-Json -InputObject $coverage -Depth 6),$utf8)
    $table=$coverage | ConvertTo-Html -Fragment
    $intro='<h1>1C / SQL diagnostic capture</h1><p>Coverage report, NOT a health verdict. Missing/truncated sources are NOT healthy results.</p><p>Run analyze.py on an administrator workstation for interval analysis. No Python is needed on the server.</p><p>Confidential: review before transferring. Includes machine/database names and paths. SQL text and plans are not included.</p>'
    if ($sqlDiagnostics.Count -gt 0) {
        $hintTable=$sqlDiagnostics | ConvertTo-Html -Fragment
        $intro += '<h2>SQL connection diagnostics</h2>'+($hintTable -join "`n")
    }
    $html=ConvertTo-Html -Title 'Diagnostic capture coverage' -Body ($intro+($table -join "`n"))
    [IO.File]::WriteAllText((Join-Path $root 'coverage.html'),($html -join "`n"),$utf8)
    try {
        $zip=$root+'.zip'
        Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip -CompressionLevel Fastest
        Write-Host ('Capture archive: '+$zip)
    } catch { Write-Warning ('ZIP creation failed; raw files remain in '+$root) }
    Write-Progress -Activity 'Collecting 1C / SQL / Windows diagnostics' -Completed
}
