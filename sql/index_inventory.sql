-- Metadata only. @Limit is MaxIndexes+1. The extra row detects truncation.
-- Largest eligible rowstore partitions first; this is NOT all indexes or a worst-fragmentation ranking.
IF @Limit<1 OR @Limit>201 OR @MinPages<0 OR @ObjectId<0 THROW 51104,'Invalid inventory limits.',1;
SELECT TOP (@Limit) DB_ID() AS database_id,DB_NAME() AS database_name,
 t.object_id,t.create_date AS object_create_date_sql_local,s.name AS schema_name,t.name AS table_name,
 i.index_id,i.name AS index_name,i.type AS index_type,i.type_desc AS index_type_desc,
 i.is_disabled,i.is_hypothetical,i.allow_page_locks,i.fill_factor,
 p.partition_number,p.in_row_data_page_count AS page_count,p.used_page_count AS used_page_count,
 p.row_count,part.data_compression_desc,
 (SELECT COUNT(*) FROM sys.partitions pp WHERE pp.object_id=i.object_id AND pp.index_id=i.index_id) AS partition_count,
 COUNT_BIG(*) OVER() AS total_candidates
FROM sys.tables t
JOIN sys.schemas s ON s.schema_id=t.schema_id
JOIN sys.indexes i ON i.object_id=t.object_id
JOIN sys.dm_db_partition_stats p ON p.object_id=i.object_id AND p.index_id=i.index_id
JOIN sys.partitions part ON part.partition_id=p.partition_id
WHERE t.is_ms_shipped=0 AND t.is_memory_optimized=0
 AND i.type IN (1,2) AND i.is_disabled=0 AND i.is_hypothetical=0
 AND p.in_row_data_page_count>=@MinPages AND (@ObjectId=0 OR t.object_id=@ObjectId)
ORDER BY p.in_row_data_page_count DESC,t.object_id,i.index_id,p.partition_number
OPTION (MAXDOP 1);
