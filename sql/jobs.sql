-- Read-only, bounded metadata. No job commands, connection strings or output messages leave SQL.
-- A restricted SQLAgentUserRole view must not be presented as all jobs on the instance.
IF ISNULL(IS_SRVROLEMEMBER(N'sysadmin'),0) <> 1
 AND ISNULL(IS_ROLEMEMBER(N'SQLAgentReaderRole'),0) <> 1
 AND ISNULL(IS_ROLEMEMBER(N'SQLAgentOperatorRole'),0) <> 1
    THROW 50001, 'Full SQL Agent metadata visibility is required (sysadmin or msdb SQLAgentReaderRole/OperatorRole).', 1;
SELECT TOP (201) j.name,j.enabled,j.date_modified,c.name AS category,
 j.notify_level_email,
 (SELECT COUNT(*) FROM msdb.dbo.sysjobsteps WHERE job_id=j.job_id) AS step_count,
 (SELECT COUNT(*) FROM msdb.dbo.sysjobschedules WHERE job_id=j.job_id) AS schedule_count,
 CASE WHEN o.id IS NOT NULL AND o.enabled=1 AND NULLIF(o.email_address,N'') IS NOT NULL THEN 1 ELSE 0 END AS has_enabled_email_operator,
 h.run_date AS last_run_date,h.run_time AS last_run_time,h.run_status AS last_run_status,
 h.run_duration AS last_run_duration_hhmmss,
 (SELECT COUNT(*) FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules s ON s.schedule_id=js.schedule_id
  WHERE js.job_id=j.job_id AND s.enabled=1
    AND s.active_start_date<=CONVERT(int,CONVERT(char(8),GETDATE(),112))
    AND s.active_end_date>=CONVERT(int,CONVERT(char(8),GETDATE(),112))) AS active_schedule_count,
 (SELECT TOP (50) s.name,s.enabled,s.freq_type,s.freq_interval,s.freq_subday_type,s.freq_subday_interval,
         s.freq_relative_interval,s.freq_recurrence_factor,s.active_start_date,s.active_end_date,
         s.active_start_time,s.active_end_time,js.next_run_date,js.next_run_time
  FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules s ON s.schedule_id=js.schedule_id
  WHERE js.job_id=j.job_id FOR JSON PATH) AS schedules_json,
 -- Pattern flags are hints, not proof: commands can call wrappers or contain comments.
 (SELECT TOP (50) st.step_id,st.subsystem,st.database_name,st.retry_attempts,
    CASE WHEN st.command LIKE N'%BACKUP%DATABASE%' OR st.command LIKE N'%DatabaseBackup%' THEN 1 ELSE 0 END AS backup_hint,
    CASE WHEN st.command LIKE N'%BACKUP%LOG%' THEN 1 ELSE 0 END AS log_backup_hint,
    CASE WHEN st.command LIKE N'%CHECKDB%' OR st.command LIKE N'%DatabaseIntegrityCheck%' THEN 1 ELSE 0 END AS checkdb_hint,
    CASE WHEN st.command LIKE N'%UPDATE%STATISTICS%' OR st.command LIKE N'%sp_updatestats%' THEN 1 ELSE 0 END AS statistics_hint,
    CASE WHEN st.command LIKE N'%ALTER%INDEX%' OR st.command LIKE N'%IndexOptimize%' THEN 1 ELSE 0 END AS index_hint,
    CASE WHEN st.command LIKE N'%SHRINKDATABASE%' OR st.command LIKE N'%SHRINKFILE%' THEN 1 ELSE 0 END AS shrink_hint
  FROM msdb.dbo.sysjobsteps st WHERE st.job_id=j.job_id ORDER BY st.step_id FOR JSON PATH) AS steps_json,
 p.name AS maintenance_plan_name,sub.subplan_name
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.syscategories c ON c.category_id=j.category_id
LEFT JOIN msdb.dbo.sysoperators o ON o.id=j.notify_email_operator_id
LEFT JOIN msdb.dbo.sysmaintplan_subplans sub ON sub.job_id=j.job_id
LEFT JOIN msdb.dbo.sysmaintplan_plans p ON p.id=sub.plan_id
OUTER APPLY (SELECT TOP (1) run_date,run_time,run_status,run_duration
             FROM msdb.dbo.sysjobhistory WHERE job_id=j.job_id AND step_id=0 ORDER BY instance_id DESC) h
ORDER BY j.name;
