-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT database_id,file_id,name,type_desc,physical_name,
 CAST(size AS bigint)*8192 AS allocated_bytes,max_size,growth,is_percent_growth,
 state_desc FROM sys.master_files ORDER BY database_id,file_id;
