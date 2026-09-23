-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT TOP (201) s.session_id,s.status,s.host_name,s.host_process_id,s.program_name,
 s.open_transaction_count,s.transaction_isolation_level,
 CONVERT(varchar(33),s.login_time,126) AS login_time_sql_local,
 CONVERT(varchar(33),s.last_request_start_time,126) AS last_request_start_time_sql_local,
 CONVERT(varchar(33),s.last_request_end_time,126) AS last_request_end_time_sql_local,
 CASE WHEN EXISTS(SELECT 1 FROM sys.dm_exec_requests r WHERE r.blocking_session_id=s.session_id)
 THEN 1 ELSE 0 END AS is_observed_blocker
 FROM sys.dm_exec_sessions s
 WHERE s.is_user_process=1 AND s.session_id<>@@SPID
 AND (s.open_transaction_count>0 OR EXISTS(
 SELECT 1 FROM sys.dm_exec_requests r WHERE r.blocking_session_id=s.session_id))
 ORDER BY is_observed_blocker DESC,s.open_transaction_count DESC,s.last_request_end_time;
