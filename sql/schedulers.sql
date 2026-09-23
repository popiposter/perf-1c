-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT parent_node_id,COUNT(*) AS visible_online_schedulers,
 SUM(runnable_tasks_count) AS runnable_tasks,MAX(runnable_tasks_count) AS max_runnable_per_scheduler,
 SUM(work_queue_count) AS queued_work,SUM(current_workers_count) AS current_workers,
 SUM(active_workers_count) AS active_workers,SUM(pending_disk_io_count) AS pending_disk_io
 FROM sys.dm_os_schedulers WHERE status='VISIBLE ONLINE' GROUP BY parent_node_id;
