-- Bound the metadata candidates BEFORE requesting their properties; no histograms or literals.
IF @Limit<1 OR @Limit>5001 OR @ObjectId<0 THROW 51107,'Invalid statistics limits.',1;
;WITH candidates AS (
 SELECT TOP (@Limit) st.object_id,st.stats_id,st.name AS statistics_name,
 s.name AS schema_name,t.name AS table_name,st.auto_created,st.user_created,
 st.no_recompute,st.has_filter,st.is_incremental,
 CONVERT(bit,CASE WHEN i.index_id IS NULL THEN 0 ELSE 1 END) AS is_index_statistics,
 COUNT_BIG(*) OVER() AS total_candidates
 FROM sys.stats st JOIN sys.tables t ON t.object_id=st.object_id
 JOIN sys.schemas s ON s.schema_id=t.schema_id
 LEFT JOIN sys.indexes i ON i.object_id=st.object_id AND i.index_id=st.stats_id
 WHERE t.is_ms_shipped=0 AND t.is_memory_optimized=0 AND (@ObjectId=0 OR t.object_id=@ObjectId)
 ORDER BY st.object_id,st.stats_id
)
SELECT DB_ID() AS database_id,DB_NAME() AS database_name,c.*,
 CONVERT(bit,CASE WHEN sp.object_id IS NULL THEN 0 ELSE 1 END) AS properties_available,
 sp.last_updated AS last_updated_sql_local,sp.rows AS rows_at_update,sp.rows_sampled,
 sp.unfiltered_rows,sp.modification_counter
FROM candidates c OUTER APPLY sys.dm_db_stats_properties(c.object_id,c.stats_id) sp
ORDER BY c.object_id,c.stats_id
OPTION (MAXDOP 1);
-- OUTER APPLY preserves missing permissions/empty statistics instead of hiding them.
