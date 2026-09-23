#requires -Version 5.1
# Synthetic offline tests. No Windows, database, CIM or network calls.
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Collect-OneCPerf.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count -gt 0) { throw ($errors -join '; ') }
$script:checks=1
function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
foreach ($name in @('Get-OneCPerfSqlErrorHint','Collect-Source')) {
    $definition=$ast.Find({ param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    },$true)
    if ($null -eq $definition) { throw ('Missing function: '+$name) }
    . ([scriptblock]::Create($definition.Extent.Text))
}
$en='SSL Provider: The certificate chain was issued by an authority that is not trusted.'
$ru='Цепочка сертификатов выпущена центром сертификации, не имеющим доверия.'
foreach ($message in @($en, $ru, ('Exception calling Open: "'+$en+'"'))) {
    $hint=Get-OneCPerfSqlErrorHint -Source 'sql.instance' -Message $message
    Assert-True ($null -ne $hint -and $hint.error_kind -eq 'sql_certificate_untrusted') 'Trust message not classified.'
    Assert-True ($hint.suggested_action.Contains('-TrustServerCertificate') -and $hint.suggested_action.Contains('Encrypt=True')) 'Explicit opt-in/encryption guidance missing.'
}
foreach ($message in @('Login failed for user synthetic.', 'Execution timeout expired.', 'SSL Provider: handshake failed.', 'Keyword not supported: DataSource.', '', 'Certificate name mismatch.')) {
    Assert-True ($null -eq (Get-OneCPerfSqlErrorHint -Source 'sql.instance' -Message $message)) 'Unrelated error must not suggest trust bypass.'
}
Assert-True ($null -eq (Get-OneCPerfSqlErrorHint -Source 'windows.os' -Message $en)) 'Non-SQL source was misclassified.'
# Run the real catch path with stubbed output, keeping the collector entry point untouched.
$script:OutputBytes=0L; $maxBytes=1MB
$script:Failures=@{}; $script:Disabled=@{}; $script:SqlErrorHints=@{}
$script:emitted=@(); $script:warnings=@()
function Emit-Record { param([hashtable]$Record) $script:emitted += $Record }
function Write-Warning { param([string]$Message) $script:warnings += $Message }
Collect-Source 'sql.instance' { throw $en }
Collect-Source 'sql.permissions' { throw $en }
Assert-True ($script:emitted.Count -eq 2) 'Source errors were lost.'
Assert-True ($script:emitted[0].status -eq 'error' -and $script:emitted[0].error_kind -eq 'sql_certificate_untrusted') 'Structured diagnostic missing from real catch path.'
Assert-True ($script:SqlErrorHints.Count -eq 1) 'Repeated failures must share one hint.'
Assert-True (@($script:warnings | Where-Object { $_ -like '*operator may add*' }).Count -eq 1) 'Actionable hint should appear only once.'
Collect-Source 'sql.jobs' { throw 'synthetic permission denied' }
Assert-True ($script:emitted[2].status -eq 'error' -and $null -eq $script:emitted[2].error_kind) 'Unknown failures must remain errors without a TLS diagnosis.'
Collect-Source 'sql.files' { [pscustomobject]@{name='synthetic'} }
Assert-True ($script:emitted[3].status -eq 'ok') 'Successful collection changed.'
Write-Host ("PASS: $script:checks targeted checks. No Windows/CIM/SQL integration was performed.")
