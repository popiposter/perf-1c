-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT wait_type,waiting_tasks_count,wait_time_ms,signal_wait_time_ms
 FROM sys.dm_os_wait_stats;
