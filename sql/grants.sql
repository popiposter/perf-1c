-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT COUNT_BIG(*) AS grant_requests,
 SUM(CASE WHEN grant_time IS NULL THEN CONVERT(bigint,1) ELSE 0 END) AS waiting_requests,
 SUM(CONVERT(bigint,requested_memory_kb)) AS requested_memory_kb,
 SUM(CONVERT(bigint,granted_memory_kb)) AS granted_memory_kb,
 MAX(wait_time_ms) AS max_wait_time_ms FROM sys.dm_exec_query_memory_grants
 WHERE session_id<>@@SPID;
