-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT TOP (201) database_name,type,backup_start_date,backup_finish_date,
 backup_size,compressed_backup_size,is_copy_only,has_backup_checksums
 FROM msdb.dbo.backupset WHERE backup_finish_date>=DATEADD(day,-14,GETDATE())
 AND (@db=N'' OR database_name=@db) ORDER BY backup_set_id DESC;
