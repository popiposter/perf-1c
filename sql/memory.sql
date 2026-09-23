-- Read-only diagnostic SELECT. Do not add remediation commands.
SELECT physical_memory_in_use_kb,locked_page_allocations_kb,
 large_page_allocations_kb,virtual_address_space_committed_kb,
 available_commit_limit_kb,process_physical_memory_low,process_virtual_memory_low
 FROM sys.dm_os_process_memory;
