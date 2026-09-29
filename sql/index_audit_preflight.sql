-- Read-only. Fail closed rather than returning a misleading partial catalog.
DECLARE @major int=TRY_CONVERT(int,SERVERPROPERTY('ProductMajorVersion'));
IF @major IS NULL OR @major<13 THROW 51100,'SQL Server 2016+ is required.',1;
IF DB_ID()<=4 OR NOT EXISTS (SELECT 1 FROM sys.databases WHERE database_id=DB_ID() AND state=0 AND replica_id IS NULL)
 THROW 51101,'Select one ONLINE user database outside an availability group.',1;
IF ISNULL(HAS_PERMS_BY_NAME(DB_NAME(),'DATABASE','VIEW DEFINITION'),0)<>1
 THROW 51102,'Database VIEW DEFINITION is required for catalog coverage.',1;
IF (@major<16 AND ISNULL(HAS_PERMS_BY_NAME(DB_NAME(),'DATABASE','VIEW DATABASE STATE'),0)<>1)
 OR (@major>=16 AND (ISNULL(HAS_PERMS_BY_NAME(DB_NAME(),'DATABASE','VIEW DATABASE PERFORMANCE STATE'),0)<>1
 OR ISNULL(HAS_PERMS_BY_NAME(DB_NAME(),'DATABASE','VIEW SECURITY DEFINITION'),0)<>1))
 THROW 51103,'Database performance DMV permissions are required for this SQL version.',1;
IF @ObjectId<0 OR (@ObjectId>0 AND NOT EXISTS (SELECT 1 FROM sys.tables WHERE object_id=@ObjectId AND is_ms_shipped=0 AND is_memory_optimized=0))
 THROW 51108,'Requested object_id is missing, inaccessible or unsupported.',1;
SELECT DB_ID() AS database_id,DB_NAME() AS database_name,@major AS product_major_version,
 CONVERT(nvarchar(128),SERVERPROPERTY('ProductVersion')) AS product_version,
 CONVERT(nvarchar(128),SERVERPROPERTY('Edition')) AS edition,
 d.create_date AS database_create_date_sql_local,d.is_read_only,d.is_auto_update_stats_on
FROM sys.databases d WHERE d.database_id=DB_ID();
