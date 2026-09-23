#requires -Version 5.1
# Exercise the collector's real constructor, without opening a SQL connection.
# Only synthetic identifiers and credentials are used. No CIM, HTTP or SQL reads.
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) {
    throw 'Run this provider test in Windows x64 PowerShell 7 or Windows PowerShell 5.1.'
}
if ($PSVersionTable.PSEdition -eq 'Desktop') { Add-Type -AssemblyName System.Data }
else { Add-Type -AssemblyName System.Data.SqlClient }
$script:checks=0
function Assert-True {
    param([bool]$Condition,[string]$Message)
    if (-not $Condition) { throw $Message }
    $script:checks++
}
$path=Join-Path (Split-Path $PSScriptRoot -Parent) 'Collect-OneCPerf.ps1'
$tokens=$null; $errors=$null
$ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
Assert-True ($errors.Count -eq 0) ('Collector syntax: '+($errors -join '; '))
$definition=$ast.Find({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq 'New-OneCPerfSqlConnection'
},$true)
Assert-True ($null -ne $definition) 'Missing real connection constructor.'
# Do not dot-source the collector entry point or duplicate the implementation.
. ([scriptblock]::Create($definition.Extent.Text))
$secure=ConvertTo-SecureString 'synthetic-test-password' -AsPlainText -Force
$credential=New-Object System.Management.Automation.PSCredential('synthetic-user',$secure)
try {
    foreach ($sqlAuth in @($false,$true)) {
        foreach ($trust in @($false,$true)) {
            $parameters=@{Instance='test-sql\INSTANCE';Catalog='db;Name="Synthetic"';TimeoutSeconds=7;TrustCertificate=$trust}
            if ($sqlAuth) { $parameters.Credential=$credential }
            $connection=New-OneCPerfSqlConnection @parameters
            try {
                Assert-True ($connection.State -eq [System.Data.ConnectionState]::Closed) 'Test must never open SQL.'
                $builder=New-Object System.Data.SqlClient.SqlConnectionStringBuilder($connection.ConnectionString)
                Assert-True ($builder.get_DataSource() -ceq $parameters.Instance) 'Instance lost during round trip.'
                Assert-True ($builder.get_InitialCatalog() -ceq $parameters.Catalog) 'Catalog quoting/injection boundary failed.'
                Assert-True ($builder.get_ApplicationName() -ceq 'OneCPerfDiag/0.1.2') 'Application name missing.'
                Assert-True ($builder.get_ConnectTimeout() -eq 7) 'Timeout lost.'
                Assert-True ($builder.get_Encrypt()) 'Encryption must remain enabled.'
                Assert-True ($builder.get_TrustServerCertificate() -eq $trust) 'Certificate option changed.'
                Assert-True (-not $builder.get_PersistSecurityInfo() -and -not $builder.get_Pooling()) 'Security/pooling options changed.'
                Assert-True ($builder.get_IntegratedSecurity() -eq (-not $sqlAuth)) 'Authentication mode changed.'
                Assert-True ($builder.get_Password() -eq '' -and $builder.get_UserID() -eq '') 'Secrets must not enter the connection string.'
                if ($sqlAuth) {
                    Assert-True ($connection.Credential.UserId -ceq 'synthetic-user') 'SQL credential lost.'
                    Assert-True ($connection.Credential.Password.IsReadOnly()) 'SQL password copy must be read-only.'
                    Assert-True (-not [object]::ReferenceEquals($connection.Credential.Password,$secure)) 'Do not mutate the caller password.'
                } else {
                    Assert-True ($null -eq $connection.Credential) 'Unexpected SQL credential in Windows auth.'
                }
            } finally { $connection.Dispose() }
        }
    }
} finally { $secure.Dispose() }
Write-Host ("PASS: $script:checks real constructor checks. No SQL connections or host collection performed.")
