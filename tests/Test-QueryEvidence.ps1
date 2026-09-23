#requires -Version 7.0
# Targeted syntax and real connection-construction checks. No SQL connection is opened.
$ErrorActionPreference='Stop'
$path=Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-OneCQuery.ps1'
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors -join '; ') }
$definition=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-QueryConnection'},$true)
if ($null -eq $definition) { throw 'Connection constructor not found.' }
. ([scriptblock]::Create($definition.Extent.Text))
if (-not $IsWindows) { Write-Host 'PASS syntax. SKIP Windows provider construction.'; return }
Add-Type -AssemblyName System.Data.SqlClient
$credential=[pscredential]::new('synthetic-user',(ConvertTo-SecureString 'synthetic-secret' -AsPlainText -Force))
foreach ($auth in @($null,$credential)) {
    foreach ($trust in @($false,$true)) {
        $conn=New-QueryConnection -Instance 'synthetic-host' -Catalog 'test;database' -Timeout 3 -Trust $trust -Credential $auth
        try {
            $b=[System.Data.SqlClient.SqlConnectionStringBuilder]::new($conn.ConnectionString)
            if ($b['Initial Catalog'] -ne 'test;database' -or -not $b['Encrypt']) { throw 'Quoting or TLS lost.' }
            if ($b['TrustServerCertificate'] -ne $trust) { throw 'Certificate default changed.' }
            if ($b['Integrated Security'] -ne ($null -eq $auth)) { throw 'Authentication mode changed.' }
            if ($conn.ConnectionString.Contains('synthetic-secret')) { throw 'Secret in connection string.' }
            if ($conn.State -ne [Data.ConnectionState]::Closed) { throw 'Connection must stay closed.' }
        } finally { $conn.Dispose() }
    }
}
Write-Host 'PASS syntax and four provider-construction cases. No SQL/CIM runtime test.'
