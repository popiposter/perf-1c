-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT CONVERT(varchar(33),sqlserver_start_time,126) AS sqlserver_start_time,
 cpu_count,scheduler_count,hyperthread_ratio,physical_memory_kb,
 committed_kb,committed_target_kb,virtual_machine_type_desc,
 CONVERT(varchar(33),SYSUTCDATETIME(),126) AS sql_utc
 FROM sys.dm_os_sys_info;
