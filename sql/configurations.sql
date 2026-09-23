-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT name, CONVERT(nvarchar(128),value) AS configured_value,
 CONVERT(nvarchar(128),value_in_use) AS running_value, is_dynamic
 FROM sys.configurations ORDER BY name;
