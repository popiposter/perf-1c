-- Local package history only; absence never proves that external index maintenance did not run.
IF OBJECT_ID(N'dbo.perf1c_IndexMaintenanceLog_v1',N'U') IS NULL
 SELECT CAST(0 AS bit) AS history_available,N'No local package log visible; external maintenance is unknown.' AS note;
ELSE
 EXEC sys.sp_executesql N'
 SELECT TOP (@Limit) CAST(1 AS bit) AS history_available,log_id,run_id,database_name,
 object_id,index_id,partition_number,schema_name,table_name,index_name,action,outcome,
 started_utc,ended_utc,page_count,fragmentation_percent,error_number,message
 FROM dbo.perf1c_IndexMaintenanceLog_v1
 WHERE database_name=@Database
 ORDER BY log_id DESC;',N'@Limit int,@Database sysname',@Limit=@Limit,@Database=@Database;
