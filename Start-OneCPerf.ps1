#requires -Version 7.0
<#
Download a pinned source snapshot from the public popiposter/perf-1c repository,
then run the collector in the current PowerShell 7 process on Windows x64.
No installation, elevation, execution-policy changes or automatic data upload.
Use -DownloadOnly to inspect the downloaded source before execution.
#>
[CmdletBinding()]
param(
    [string]$SqlInstance = '',
    [string]$Database = '',
    [ValidateRange(0,60)][int]$Minutes = 10,
    [ValidateRange(5,300)][int]$IntervalSeconds = 15,
    [ValidatePattern('^[A-Za-z0-9_-]{1,64}$')][string]$CaseId = 'case01',
    [ValidateSet('sql','onec','combined','other')][string]$Role = 'combined',
    [string]$OutputDirectory = '',
    [System.Management.Automation.PSCredential]$SqlCredential,
    [switch]$TrustServerCertificate,
    [switch]$SkipSql,
    [switch]$IncludeMaintenance,
    [ValidateRange(1,15)][int]$QueryTimeoutSeconds = 3,
    [ValidateRange(16,512)][int]$MaxOutputMB = 128,
    [ValidateNotNullOrEmpty()][string]$Ref = 'main',
    [string]$WorkDirectory = '',
    [switch]$NonInteractive,
    [switch]$DownloadOnly,
    [switch]$IndexAudit,
    [ValidateRange(1,200)][int]$IndexAuditMaxIndexes = 30,
    [ValidateRange(1,5000)][int]$IndexAuditMaxStatistics = 1000,
    [ValidateRange(1,900)][int]$IndexAuditBudgetSeconds = 60,
    [ValidateRange(0,1000000000)][int]$IndexAuditMinPages = 1000,
    [ValidateRange(0,2147483647)][int]$IndexAuditObjectId = 0,
    [ValidateSet('LIMITED','SAMPLED')][string]$IndexAuditScanMode = 'LIMITED'
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'Run this launcher in PowerShell 7 x64 on Windows (pwsh.exe).'
}

function Resolve-OneCPerfCommit {
    param([string]$Revision)
    if ($Revision -match '^[0-9a-fA-F]{40}$') { return $Revision.ToLowerInvariant() }
    $encoded = [Uri]::EscapeDataString($Revision)
    try {
        $result = Invoke-RestMethod -Uri "https://api.github.com/repos/popiposter/perf-1c/commits/$encoded" `
            -Headers @{'User-Agent'='perf-1c-launcher';'Accept'='application/vnd.github+json'} `
            -TimeoutSec 30 -ErrorAction Stop
    } catch {
        throw ('Cannot resolve the GitHub revision. Check network/proxy access or the GitHub API limit; ' +
            'an explicit 40-character -Ref commit skips the API lookup. ' + $_.Exception.Message)
    }
    if ([string]$result.sha -notmatch '^[0-9a-fA-F]{40}$') { throw 'GitHub returned an invalid commit SHA.' }
    return ([string]$result.sha).ToLowerInvariant()
}

function Get-OneCPerfCollectorParameters {
    param([System.Collections.IDictionary]$Bound,[string]$Commit,[string]$Destination)
    $forward = @{}
    foreach ($name in @('SqlInstance','Database','Minutes','IntervalSeconds','CaseId','Role',
        'SqlCredential','TrustServerCertificate','SkipSql','IncludeMaintenance','QueryTimeoutSeconds','MaxOutputMB')) {
        if ($Bound.Keys -contains $name) { $forward[$name] = $Bound[$name] }
    }
    $forward['OutputDirectory'] = $Destination
    $forward['SourceCommit'] = $Commit
    return $forward
}

function Get-OneCIndexAuditParameters {
    param([System.Collections.IDictionary]$Bound,[string]$Commit,[string]$Destination)
    $forward = @{}
    foreach ($name in @('SqlInstance','Database','CaseId','SqlCredential','TrustServerCertificate','QueryTimeoutSeconds')) {
        if ($Bound.Keys -contains $name) { $forward[$name] = $Bound[$name] }
    }
    $map = @{IndexAuditMaxIndexes='MaxIndexes';IndexAuditMaxStatistics='MaxStatistics';
        IndexAuditBudgetSeconds='BudgetSeconds';IndexAuditMinPages='MinPages';
        IndexAuditObjectId='ObjectId';IndexAuditScanMode='ScanMode'}
    foreach ($name in $map.Keys) {
        if ($Bound.Keys -contains $name) { $forward[$map[$name]] = $Bound[$name] }
    }
    $forward.OutputDirectory = $Destination; $forward.SourceCommit = $Commit
    return $forward
}
if ($IndexAudit -and ($SkipSql -or $IncludeMaintenance -or $PSBoundParameters.ContainsKey('Minutes') -or
    $PSBoundParameters.ContainsKey('IntervalSeconds') -or $PSBoundParameters.ContainsKey('MaxOutputMB'))) {
    throw 'IndexAudit is a separate one-shot SQL profile. Do not combine it with SkipSql, IncludeMaintenance, Minutes, IntervalSeconds or MaxOutputMB; use IndexAuditBudgetSeconds.'
}
if (-not $IndexAudit -and @($PSBoundParameters.Keys | Where-Object { $_ -like 'IndexAudit*' -and $_ -ne 'IndexAudit' }).Count) {
    throw 'IndexAudit settings require -IndexAudit.'
}

# Resolve operator input before collection; no environment-specific server/base is assumed.
# A fully parameterized invocation never prompts. An empty explicit -Database means instance scope only.
if (-not $DownloadOnly -and -not $SkipSql) {
    if ([string]::IsNullOrWhiteSpace($SqlInstance)) {
        if ($NonInteractive) { throw 'Specify -SqlInstance or -SkipSql with -NonInteractive.' }
        $SqlInstance = (Read-Host 'SQL instance (Enter = local default instance .)').Trim()
        if (-not $SqlInstance) { $SqlInstance = '.' }
        $PSBoundParameters['SqlInstance'] = $SqlInstance
        if (-not $PSBoundParameters.ContainsKey('Database')) {
            $Database = (Read-Host 'SQL database name (Enter = instance metrics only)').Trim()
            $PSBoundParameters['Database'] = $Database
        }
    }
    if (-not $Database) { Write-Warning 'No database selected: per-database details will be skipped.' }
}
if ($IndexAudit -and -not $DownloadOnly -and [string]::IsNullOrWhiteSpace($Database)) {
    if ($NonInteractive) { throw 'IndexAudit requires an explicit -Database.' }
    $Database = (Read-Host 'User database for index audit (required)').Trim()
    if (-not $Database) { throw 'IndexAudit requires an explicit user database.' }
    $PSBoundParameters['Database'] = $Database
}
if ([string]::IsNullOrWhiteSpace($WorkDirectory)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { throw 'Specify a local -WorkDirectory.' }
    $WorkDirectory = Join-Path $env:LOCALAPPDATA 'perf-1c'
}
$WorkDirectory = [IO.Path]::GetFullPath($WorkDirectory)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $WorkDirectory 'captures' }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if ($WorkDirectory.StartsWith('\\') -or $OutputDirectory.StartsWith('\\')) {
    throw 'Choose local WorkDirectory and OutputDirectory paths, not UNC shares.'
}
$commit = Resolve-OneCPerfCommit -Revision $Ref
# Every launch uses a fresh directory: no stale code after a failed download, no overwriting captures.
$downloadRoot = Join-Path $WorkDirectory ('downloads/' + $commit + '_' + [guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($downloadRoot)
$archivePath = Join-Path $downloadRoot 'source.zip'
$archiveUrl = "https://codeload.github.com/popiposter/perf-1c/zip/$commit"
Write-Host "Downloading popiposter/perf-1c @ $commit"
Invoke-WebRequest -Uri $archiveUrl -OutFile $archivePath -TimeoutSec 120 -ErrorAction Stop
Expand-Archive -LiteralPath $archivePath -DestinationPath $downloadRoot -ErrorAction Stop
$sourceRoot = Join-Path $downloadRoot "perf-1c-$commit"
$collectorName = if ($IndexAudit) { 'Get-OneCIndexAudit.ps1' } else { 'Collect-OneCPerf.ps1' }
$collector = Join-Path $sourceRoot $collectorName
if (-not (Test-Path -LiteralPath $collector -PathType Leaf) -or
    -not (Test-Path -LiteralPath (Join-Path $sourceRoot 'sql') -PathType Container)) {
    throw 'The downloaded archive is incomplete: collector or sql directory is missing. Nothing was run.'
}
$origin = [ordered]@{
    repository='popiposter/perf-1c'; requested_ref=$Ref; commit=$commit;
    downloaded_utc=[DateTime]::UtcNow.ToString('o'); archive_url=$archiveUrl;
    archive_sha256=(Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant();
    launcher_sha256=(Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash.ToLowerInvariant();
    powershell_version=$PSVersionTable.PSVersion.ToString()
}
$origin | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $downloadRoot 'source.json') -Encoding utf8
Write-Host "Source: $sourceRoot"
Write-Host "Captures: $OutputDirectory"
if ($DownloadOnly) {
    Write-Host 'Download-only: no diagnostic sources were accessed. Review the source before running Collect-OneCPerf.ps1.'
    return
}
$collectorParams = if ($IndexAudit) {
    Get-OneCIndexAuditParameters -Bound $PSBoundParameters -Commit $commit -Destination $OutputDirectory
} else {
    Get-OneCPerfCollectorParameters -Bound $PSBoundParameters -Commit $commit -Destination $OutputDirectory
}
Write-Host 'Read-only pilot. Check coverage.html after collection; errors are missing data, not a healthy result.'
& $collector @collectorParams
