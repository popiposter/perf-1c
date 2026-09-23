-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT TOP (201) r.session_id,r.request_id,r.database_id,
 CONVERT(varchar(36),r.connection_id) AS connection_id,
 CONVERT(varchar(33),r.start_time,126) AS request_start_time_sql_local,
 r.status,r.command,r.cpu_time,r.total_elapsed_time,r.reads,r.writes,r.logical_reads,
 r.wait_type,r.wait_time,r.wait_resource,r.blocking_session_id,r.open_transaction_count,
 r.percent_complete,r.transaction_id,r.statement_start_offset,r.statement_end_offset,
 CONVERT(varchar(18),r.query_hash,1) AS query_hash,
 CONVERT(varchar(18),r.query_plan_hash,1) AS query_plan_hash,
 CONVERT(varchar(130),r.sql_handle,1) AS sql_handle,
 CONVERT(varchar(130),r.plan_handle,1) AS plan_handle,
 s.host_name,s.host_process_id,s.program_name
 FROM sys.dm_exec_requests r JOIN sys.dm_exec_sessions s ON s.session_id=r.session_id
 WHERE s.is_user_process=1 AND r.session_id<>@@SPID
 ORDER BY CASE WHEN r.blocking_session_id>0 THEN 0 ELSE 1 END,r.total_elapsed_time DESC;
