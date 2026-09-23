-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT database_id,name,state_desc,user_access_desc,compatibility_level,
 recovery_model_desc,log_reuse_wait_desc,is_read_only,is_auto_close_on,is_auto_shrink_on,
 is_auto_create_stats_on,is_auto_update_stats_on,is_auto_update_stats_async_on,
 page_verify_option_desc,is_read_committed_snapshot_on,snapshot_isolation_state_desc
 FROM sys.databases ORDER BY database_id;
