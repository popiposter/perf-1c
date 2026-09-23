-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT HAS_PERMS_BY_NAME(NULL,NULL,'VIEW SERVER STATE') AS view_server_state,
 HAS_PERMS_BY_NAME(NULL,NULL,'VIEW SERVER PERFORMANCE STATE') AS view_server_performance_state,
 HAS_PERMS_BY_NAME(NULL,NULL,'VIEW ANY DATABASE') AS view_any_database,
 IS_SRVROLEMEMBER('sysadmin') AS is_sysadmin;
