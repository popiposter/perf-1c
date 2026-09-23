-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT TOP (201) j.name AS job_name,h.step_id,h.run_status,
 h.run_date,h.run_time,h.run_duration,h.retries_attempted
 FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id=h.job_id
 WHERE h.step_id=0 ORDER BY h.instance_id DESC;
