-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT actual_state_desc,desired_state_desc,readonly_reason,
 current_storage_size_mb,max_storage_size_mb,query_capture_mode_desc,
 interval_length_minutes,stale_query_threshold_days FROM sys.database_query_store_options;
