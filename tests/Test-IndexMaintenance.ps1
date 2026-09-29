#requires -Version 7.0
# Local-only regression checks. No SQL/CIM access, no Pester or network dependencies.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$checks=0
function Assert-IndexTest([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checks++
}
$asts=@{}
foreach ($file in @('Start-OneCPerf.ps1','Get-OneCIndexAudit.ps1','New-OneCIndexMaintenance.ps1')) {
    $tokens=$null;$errors=$null
    $asts[$file]=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors)
    Assert-IndexTest ($errors.Count -eq 0) ($file+': '+($errors -join '; '))
}
$definition=$asts['Start-OneCPerf.ps1'].Find({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OneCIndexAuditParameters'
},$true)
. ([scriptblock]::Create($definition.Extent.Text))
$credential=[pscredential]::new('synthetic-user',(ConvertTo-SecureString 'synthetic-only' -AsPlainText -Force))
$bound=@{SqlInstance='synthetic';Database='SyntheticDB';SqlCredential=$credential;TrustServerCertificate=$true;
    IndexAudit=$true;IndexAuditMaxIndexes=7;IndexAuditMinPages=2000;IndexAuditScanMode='SAMPLED';
    IndexAuditObjectId=123;IndexAuditBudgetSeconds=15;Minutes=2;Apply=$true;Ref='main'}
$p=Get-OneCIndexAuditParameters $bound ('a'*40) 'synthetic-captures'
Assert-IndexTest ($p.MaxIndexes -eq 7 -and $p.MinPages -eq 2000 -and $p.ObjectId -eq 123 -and $p.ScanMode -eq 'SAMPLED' -and $p.BudgetSeconds -eq 15) 'Audit policy forwarding failed.'
Assert-IndexTest ([object]::ReferenceEquals($credential,$p.SqlCredential)) 'Credential was not forwarded as an object.'
Assert-IndexTest (-not $p.ContainsKey('Minutes') -and -not $p.ContainsKey('Apply') -and -not $p.ContainsKey('Ref')) 'Launcher parameters leaked.'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('perf-index-test-'+[guid]::NewGuid().ToString('N'))
try {
    $db="Synthetic]O'Brien"
    & (Join-Path $root 'New-OneCIndexMaintenance.ps1') -Database $db -OutputDirectory $temp
    $dir=@(Get-ChildItem -LiteralPath $temp -Directory)[0].FullName
    $install=Get-Content -LiteralPath (Join-Path $dir 'install.sql') -Raw
    $enable=Get-Content -LiteralPath (Join-Path $dir 'enable.sql') -Raw
    $package=Get-Content -LiteralPath (Join-Path $dir 'package.json') -Raw | ConvertFrom-Json
    Assert-IndexTest ($package.apply_status -eq 'not_requested') 'Preview unexpectedly applied.'
    Assert-IndexTest ($package.jobs.Count -eq 1 -and -not $package.allow_offline_rebuild) 'Wrong default job scope/policy.'
    Assert-IndexTest ($package.jobs[0].command.Contains("USE [Synthetic]]O''Brien];")) 'Identifier/literal escaping in nested SQL failed.'
    Assert-IndexTest ($install.Contains('@enabled=0') -and -not $install.Contains('sp_start_job')) 'Jobs must start disabled and never be executed by install.'
    Assert-IndexTest ($enable.Contains('DECLARE @Approved bit=0')) 'Missing enable approval gate.'
    Assert-IndexTest (-not $install.Contains('{{')) 'Unexpanded SQL template token.'
    Assert-IndexTest ($install.Contains('offline_not_approved') -and $install.Contains('ONLINE = OFF')) 'Offline guard missing.'
    & (Join-Path $root 'New-OneCIndexMaintenance.ps1') -Database 'SyntheticOther' -OutputDirectory (Join-Path $temp 'whatif') -Apply -WhatIf
    $whatDir=@(Get-ChildItem -LiteralPath (Join-Path $temp 'whatif') -Directory)[0].FullName
    $what=Get-Content -LiteralPath (Join-Path $whatDir 'package.json') -Raw | ConvertFrom-Json
    Assert-IndexTest ($what.apply_status -eq 'not_applied_whatif_or_declined') 'WhatIf attempted a connection.'
    $failed=$false
    try { & (Join-Path $root 'New-OneCIndexMaintenance.ps1') -Database 'master' -OutputDirectory $temp } catch { $failed=$true }
    Assert-IndexTest $failed 'System database accepted.'
    $failed=$false
    try { & (Join-Path $root 'New-OneCIndexMaintenance.ps1') -Database 'SyntheticDB' -ReorganizePercent 30 -RebuildPercent 30 -OutputDirectory $temp } catch { $failed=$true }
    Assert-IndexTest $failed 'Invalid thresholds accepted.'
} finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force } }
Write-Host ("PASS: $checks index checks. No SQL/CIM runtime validation performed.")
