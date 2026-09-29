-- NEVER pass NULL/0 object/index/partition to the physical DMV: it means a wildcard scan.
IF @ObjectId IS NULL OR @ObjectId<=0 OR @IndexId IS NULL OR @IndexId<=0
 OR @PartitionNumber IS NULL OR @PartitionNumber<=0
 OR @ScanMode IS NULL OR @ScanMode NOT IN (N'LIMITED',N'SAMPLED')
 THROW 51105,'An explicit object, index, partition and supported scan mode are required.',1;
IF NOT EXISTS (SELECT 1 FROM sys.tables t JOIN sys.indexes i ON i.object_id=t.object_id
 WHERE t.object_id=@ObjectId AND i.index_id=@IndexId AND i.type IN (1,2)
 AND t.is_ms_shipped=0 AND t.is_memory_optimized=0 AND i.is_disabled=0 AND i.is_hypothetical=0
 AND t.name=@ObjectName AND i.name=@IndexName AND t.create_date=@ObjectCreateDate)
 THROW 51106,'Index identity changed or is unsupported. No wildcard fallback.',1;
SELECT DB_ID() AS database_id,DB_NAME() AS database_name,
 ips.object_id,OBJECT_SCHEMA_NAME(ips.object_id) AS schema_name,OBJECT_NAME(ips.object_id) AS table_name,
 i.index_id,i.name AS index_name,i.type AS index_type,i.is_disabled,i.is_hypothetical,
 i.allow_page_locks,i.fill_factor,ips.partition_number,
 (SELECT COUNT(*) FROM sys.partitions p WHERE p.object_id=i.object_id AND p.index_id=i.index_id) AS partition_count,
 ips.index_level,ips.alloc_unit_type_desc,ips.page_count,ips.avg_fragmentation_in_percent,
 ips.avg_page_space_used_in_percent,@ScanMode AS scan_mode
FROM sys.dm_db_index_physical_stats(DB_ID(),@ObjectId,@IndexId,@PartitionNumber,@ScanMode) ips
JOIN sys.indexes i ON i.object_id=ips.object_id AND i.index_id=ips.index_id
WHERE ips.index_level=0 AND ips.alloc_unit_type_desc=N'IN_ROW_DATA'
OPTION (MAXDOP 1);
