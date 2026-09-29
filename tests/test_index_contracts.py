"""Offline source contracts, NOT a SQL/PowerShell parser or runtime validation."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]


class IndexSourceContracts(unittest.TestCase):
    def test_read_only_queries(self):
        for name in ('index_audit_preflight', 'index_inventory', 'index_health', 'statistics_health', 'heap_health'):
            text = (ROOT/'sql'/f'{name}.sql').read_text()
            text = re.sub(r'--[^\n]*', '', text)
            self.assertIsNone(re.search(r'\b(ALTER|UPDATE|DELETE|INSERT|CREATE|TRUNCATE|DROP|BACKUP|RESTORE)\b', text, re.I), name)

    def test_physical_scan_has_no_wildcards(self):
        text = (ROOT/'sql/index_health.sql').read_text()
        self.assertIn('sys.dm_db_index_physical_stats(DB_ID(),@ObjectId,@IndexId,@PartitionNumber,@ScanMode)', text)
        self.assertLess(text.index('@ObjectId IS NULL'), text.index('FROM sys.dm_db_index_physical_stats'))
        self.assertIn('t.create_date=@ObjectCreateDate', text)
        self.assertNotIn("N'DETAILED'", text)

    def test_statistics_preserve_missing_properties(self):
        text = (ROOT/'sql/statistics_health.sql').read_text()
        self.assertIn('OUTER APPLY sys.dm_db_stats_properties', text)
        self.assertLess(text.index('TOP (@Limit)'), text.index('sys.dm_db_stats_properties('))
        self.assertNotIn('filter_definition', text)
        self.assertNotIn('DBCC SHOW_STATISTICS', text)

    def test_collector_bounds_and_opt_in(self):
        text = (ROOT/'Get-OneCIndexAudit.ps1').read_text()
        self.assertIn('$ScanMode -eq \'SAMPLED\' -and $ObjectId -eq 0', text)
        self.assertIn('$cmd.CommandTimeout=$QueryTimeoutSeconds', text)
        self.assertIn('$script:watch.Elapsed.TotalSeconds -ge $BudgetSeconds', text)
        self.assertIn('$physicalErrors -ge 3', text)
        self.assertIn('32MB', text)
        self.assertNotIn('Invoke-Expression', text)
        self.assertNotIn('Set-ExecutionPolicy', text)

    def test_installer_is_separate_and_disabled(self):
        text = (ROOT/'New-OneCIndexMaintenance.ps1').read_text()
        self.assertIn('SupportsShouldProcess', text)
        self.assertIn('$Apply -and $PSCmdlet.ShouldProcess', text)
        self.assertIn('sp_add_job @job_name=$n,@enabled=0', text)
        self.assertIn('DECLARE @Approved bit=0', text)
        self.assertNotIn('sp_start_job', text.lower())
        self.assertNotIn('REBUILD ALL', text)
        self.assertNotIn('ALTER INDEX ALL', text)
        self.assertNotIn('REPAIR_ALLOW_DATA_LOSS', text)

    def test_conditional_job_records_failures(self):
        text = (ROOT/'New-OneCIndexMaintenance.ps1').read_text()
        for term in ('offline_not_approved','page_locks_disabled','budget_stop','completed_subset',
                     "@errors>=3", "perf-1c:heavy-maintenance", 'perf1c_IndexMaintenanceLog_v1',
                     'hist.last_checked ASC', 'LOB_COMPACTION = OFF'):
            self.assertIn(term, text)
        self.assertIn('{{ALLOW_OFFLINE}}=0', text)
        self.assertIn('IF @errors>0 OR @budget=1 OR @deferred>0 THROW', text)
        self.assertIn('ONLINE = OFF', text)
        self.assertNotIn('ONLINE = ON', text)
        self.assertNotIn('UPDATE STATISTICS', text)

    def test_launcher_profile_does_not_leak_parameters(self):
        text = (ROOT/'Start-OneCPerf.ps1').read_text(encoding='utf-8-sig')
        self.assertIn('Get-OneCIndexAuditParameters', text)
        section = text.split('function Get-OneCIndexAuditParameters', 1)[1].split('# Resolve operator', 1)[0]
        self.assertIn("IndexAuditMaxIndexes='MaxIndexes'", section)
        self.assertIn("IndexAuditBudgetSeconds='BudgetSeconds'", section)
        self.assertIn("'Get-OneCIndexAudit.ps1'", text)


if __name__ == '__main__':
    unittest.main()
