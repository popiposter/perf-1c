-- Metadata only. A heap is not automatically a defect; never propose CREATE CLUSTERED INDEX for 1C.
SELECT TOP (@Limit) DB_ID() AS database_id,DB_NAME() AS database_name,
 t.object_id,s.name AS schema_name,t.name AS table_name,
 SUM(p.used_page_count) AS used_page_count,SUM(p.row_count) AS row_count,COUNT_BIG(*) OVER() AS total_candidates
FROM sys.tables t JOIN sys.schemas s ON s.schema_id=t.schema_id
JOIN sys.dm_db_partition_stats p ON p.object_id=t.object_id AND p.index_id=0
WHERE t.is_ms_shipped=0 AND t.is_memory_optimized=0 AND (@ObjectId=0 OR t.object_id=@ObjectId)
GROUP BY t.object_id,s.name,t.name
HAVING SUM(p.used_page_count)>=@MinPages
ORDER BY SUM(p.used_page_count) DESC,t.object_id
OPTION (MAXDOP 1);
