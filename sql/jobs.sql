-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT TOP (201) j.name,j.enabled,j.date_modified,c.name AS category
 FROM msdb.dbo.sysjobs j LEFT JOIN msdb.dbo.syscategories c
 ON c.category_id=j.category_id ORDER BY j.name;
