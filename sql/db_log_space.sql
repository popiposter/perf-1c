-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT database_id,total_log_size_in_bytes,used_log_space_in_bytes,
 used_log_space_in_percent FROM sys.dm_db_log_space_usage;
