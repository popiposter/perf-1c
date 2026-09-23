#requires -Version 7.0
# Offline generator tests. Never connect to SQL, read CIM, or invoke generated SQL.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$script=Join-Path $root 'New-OneCMaintenance.ps1'
$tokens=$null; $errors=$null
[void][Management.Automation.Language.Parser]::ParseFile($script,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors -join "`n") }
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('perf-maint-test-'+[guid]::NewGuid())
try {
    & $script -Database "test]O'Hare" -BackupDirectory "D:\Synthetic\O'Hare" -OutputDirectory $tmp -NonInteractive
    $package=@(Get-ChildItem $tmp -Directory)[0].FullName
    $meta=Get-Content (Join-Path $package 'package.json') -Raw | ConvertFrom-Json
    if ($meta.applied -or $meta.job_count -ne 3) { throw 'Default must generate three disabled jobs, without connecting.' }
    $install=Get-Content (Join-Path $package 'install.sql') -Raw
    foreach ($required in @('@enabled=0','BEGIN TRANSACTION','THROW 51016','CHECKSUM, COMPRESSION','VERIFYONLY','sp_updatestats','MAXDOP=2',"test]]O''Hare","O''''Hare")) {
        if (-not $install.Contains($required)) { throw "Missing generated contract: $required" }
    }
    if ($install -match 'sp_start_job|REPAIR_ALLOW_DATA_LOSS|DBCC SHRINK|ALTER INDEX.*REBUILD') { throw 'Unsafe default action generated.' }
    & $script -Database 'test2' -BackupDirectory 'D:\Synthetic' -OutputDirectory $tmp -LogBackupMinutes 15 -Apply -WhatIf -NonInteractive
    foreach ($folder in Get-ChildItem $tmp -Directory) {
        $m=Get-Content (Join-Path $folder.FullName 'package.json') -Raw | ConvertFrom-Json
        if ($m.applied) { throw 'Preview/WhatIf must not apply anything.' }
        if (-not (Get-Content (Join-Path $folder.FullName 'enable.sql') -Raw).Contains('@Approved bit=0')) { throw 'Explicit enable approval missing.' }
    }
    foreach ($name in @('disable.sql','remove.sql')) {
        $control=Get-Content (Join-Path $package $name) -Raw
        if ($control -match 'THROW 51012|THROW 51013|THROW 51014|THROW 51017') { throw 'Disable/remove must work when the target database is unavailable.' }
    }
    $failed=$false
    try { & $script -Database 'master' -BackupDirectory 'D:\Synthetic' -OutputDirectory $tmp -NonInteractive } catch { $failed=$true }
    if (-not $failed) { throw 'System database must require a separate policy.' }
    Write-Host 'PASS: offline syntax/generation/quoting/preview checks. No SQL integration tested.'
} finally { if(Test-Path $tmp){Remove-Item $tmp -Recurse -Force} }
