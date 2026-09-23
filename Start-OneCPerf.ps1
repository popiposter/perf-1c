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
    [switch]$DownloadOnly
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
$collector = Join-Path $sourceRoot 'Collect-OneCPerf.ps1'
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
$collectorParams = Get-OneCPerfCollectorParameters -Bound $PSBoundParameters -Commit $commit -Destination $OutputDirectory
Write-Host 'Read-only pilot. Check coverage.html after collection; errors are missing data, not a healthy result.'
& $collector @collectorParams
