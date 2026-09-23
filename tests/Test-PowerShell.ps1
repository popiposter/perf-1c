#requires -Version 7.0
# Offline targeted tests: no Pester, database connections, CIM reads or real HTTP calls.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script:checks = 0
function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
$launcherAst = $null
foreach ($name in @('Start-OneCPerf.ps1','Collect-OneCPerf.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $name),[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) ($name + ': ' + ($errors -join '; '))
    if ($name -eq 'Start-OneCPerf.ps1') { $launcherAst = $ast }
}
# Load only the pure/testable function definitions; never execute either script entry point.
foreach ($name in @('Resolve-OneCPerfCommit','Get-OneCPerfCollectorParameters')) {
    $definition = $launcherAst.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    },$true)
    if ($null -eq $definition) { throw "Missing function: $name" }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$sha = '1234567890abcdef1234567890abcdef12345678'
$script:httpCalls = 0
$script:httpResult = @{sha=$sha}
function Invoke-RestMethod {
    param($Uri,$Headers,$TimeoutSec,$ErrorAction)
    $script:httpCalls++
    $script:lastUri = $Uri
    if ($script:httpResult -is [Exception]) { throw $script:httpResult }
    return $script:httpResult
}
Assert-True ((Resolve-OneCPerfCommit $sha.ToUpperInvariant()) -ceq $sha) 'SHA must be normalized.'
Assert-True ($script:httpCalls -eq 0) 'An explicit commit must not call the API.'
Assert-True ((Resolve-OneCPerfCommit 'feature/test') -eq $sha) 'Branch resolution failed.'
Assert-True ($script:lastUri.EndsWith('/feature%2Ftest')) 'Branch names must be URL-encoded.'
$script:httpResult = @{sha='not-a-sha'}
$failed = $false
try { Resolve-OneCPerfCommit 'main' | Out-Null } catch { $failed = $true }
Assert-True $failed 'Malformed SHA must stop the launch.'
$script:httpResult = [InvalidOperationException]::new('synthetic network error')
$failed = $false
try { Resolve-OneCPerfCommit 'main' | Out-Null } catch { $failed = $true }
Assert-True $failed 'Network failure must not fall back to stale source.'
$secure = ConvertTo-SecureString 'synthetic-test-password' -AsPlainText -Force
$credential = [pscredential]::new('synthetic-user',$secure)
$bound = @{
    SqlInstance='test-host'; Database='test-db'; Minutes=1; SkipSql=$false;
    SqlCredential=$credential; TrustServerCertificate=$true; IncludeMaintenance=$true;
    Ref='main'; DownloadOnly=$true; NonInteractive=$true; WorkDirectory='unused'; OutputDirectory='wrong'
}
$forward = Get-OneCPerfCollectorParameters -Bound $bound -Commit $sha -Destination 'captures'
Assert-True ($forward.SqlInstance -eq 'test-host' -and $forward.Database -eq 'test-db' -and $forward.Minutes -eq 1) 'Collector parameters lost.'
Assert-True ([object]::ReferenceEquals($credential,$forward.SqlCredential)) 'Credential must be forwarded as an object.'
Assert-True ($forward.TrustServerCertificate -and $forward.IncludeMaintenance -and -not $forward.SkipSql) 'Switch values changed.'
Assert-True ($forward.OutputDirectory -eq 'captures' -and $forward.SourceCommit -eq $sha) 'Provenance or output override lost.'
Assert-True (-not $forward.ContainsKey('Ref') -and -not $forward.ContainsKey('DownloadOnly') -and
    -not $forward.ContainsKey('WorkDirectory') -and -not $forward.ContainsKey('NonInteractive')) 'Launcher-only parameters leaked.'
if ($IsWindows) {
    Add-Type -AssemblyName System.Data.SqlClient
    $connection = [System.Data.SqlClient.SqlConnection]::new()
    try { Assert-True ($connection.State -eq [System.Data.ConnectionState]::Closed) 'Unexpected open SQL connection.' }
    finally { $connection.Dispose() }
} else { Write-Host 'SKIP: Windows SQL provider construction (non-Windows test host).' }
Write-Host ("PASS: $script:checks targeted checks. No Windows/CIM/SQL integration was performed.")
