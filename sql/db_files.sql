-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT file_id,name,type_desc,physical_name,CAST(size AS bigint)*8192 AS allocated_bytes,
 CONVERT(bigint,FILEPROPERTY(name,'SpaceUsed'))*8192 AS space_used_bytes,
 max_size,growth,is_percent_growth FROM sys.database_files ORDER BY file_id;
