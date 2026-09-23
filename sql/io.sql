-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT v.database_id,v.file_id,CONVERT(varchar(36),f.file_guid) AS file_guid,
 f.physical_name,f.type_desc,v.num_of_reads,v.num_of_bytes_read,v.io_stall_read_ms,
 v.num_of_writes,v.num_of_bytes_written,v.io_stall_write_ms,v.size_on_disk_bytes
 FROM sys.dm_io_virtual_file_stats(NULL,NULL) v
 LEFT JOIN sys.master_files f ON f.database_id=v.database_id AND f.file_id=v.file_id;
