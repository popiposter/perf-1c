import copy
import json
from pathlib import Path
import tempfile
import unittest
from zipfile import ZipFile

import analyze
from index_advisor import recommend_indexes, render_index_document, quote_name

MANIFEST = {'schema_version': '0.1', 'profile': 'index-audit', 'host': 'synthetic-host',
            'selected_database': 'SyntheticDB', 'case_id': 'synthetic', 'started_utc': '2026-01-01T00:00:00Z'}


def index(**changes):
    row = dict(database_id=5, database_name='SyntheticDB', object_id=100, schema_name='dbo',
               table_name='SyntheticTable', index_id=1, index_name='SyntheticIndex', index_type=2,
               is_disabled=False, is_hypothetical=False, allow_page_locks=True,
               partition_number=1, partition_count=1, index_level=0, alloc_unit_type_desc='IN_ROW_DATA',
               page_count=2000, avg_fragmentation_in_percent=15, avg_page_space_used_in_percent=None, scan_mode='LIMITED')
    row.update(changes)
    return row


def stats(**changes):
    row = dict(database_id=5, database_name='SyntheticDB', object_id=100, schema_name='dbo',
               table_name='SyntheticTable', stats_id=1, statistics_name='SyntheticStats',
               properties_available=True, no_recompute=False, is_incremental=False, has_filter=False,
               last_updated_sql_local='2020-01-01T00:00:00', rows_at_update=10000, unfiltered_rows=10000,
               rows_sampled=1000, modification_counter=3000)
    row.update(changes)
    return row


def record(source, *rows, status='ok', **changes):
    r = dict(source=source, rows=list(rows), status=status, collected_utc='2026-01-01T00:00:01Z',
             tick=0, row_count=len(rows), error=None)
    r.update(changes)
    return r


def advise(row=None, **policy):
    return recommend_indexes(MANIFEST, [record('sql.index_health', row or index())], **policy)


class IndexAdvisorTests(unittest.TestCase):
    def test_threshold_boundaries(self):
        for frag, word in [(0, 'Не обслуживать'), (4.999, 'Не обслуживать'), (5, 'REORGANIZE'),
                           (29.999, 'REORGANIZE'), (30, 'REBUILD'), (100, 'REBUILD')]:
            with self.subTest(frag=frag):
                self.assertIn(word, advise(index(avg_fragmentation_in_percent=frag))['indexes'][0]['proposed'])

    def test_minimum_pages(self):
        self.assertIsNone(advise(index(page_count=999, avg_fragmentation_in_percent=90))['indexes'][0]['suggested_sql'])
        self.assertIn('REBUILD', advise(index(page_count=1000, avg_fragmentation_in_percent=90))['indexes'][0]['suggested_sql'])

    def test_configurable_policy(self):
        result = advise(index(avg_fragmentation_in_percent=40), reorganize_percent=20, rebuild_percent=60)
        self.assertIn('REORGANIZE', result['indexes'][0]['suggested_sql'])

    def test_invalid_policy(self):
        for kw in ({'reorganize_percent': 30, 'rebuild_percent': 30}, {'min_pages': -1},
                   {'rebuild_percent': 101}, {'rebuild_percent': True}, {'stats_min_changes': 0}):
            with self.subTest(kw=kw), self.assertRaises(ValueError):
                advise(**kw)

    def test_disabled_and_unsupported_indexes(self):
        for kw in ({'is_disabled': True}, {'is_hypothetical': True}, {'index_type': 5}, {'index_type': 0},
                   {'index_type': True}, {'alloc_unit_type_desc': 'LOB_DATA'}, {'index_level': 1}):
            with self.subTest(kw=kw):
                result = advise(index(**kw))
                self.assertEqual('unknown', result['indexes'][0]['status'])
                self.assertFalse(any(x['sql'] for x in result['findings']))

    def test_invalid_ids_and_partition(self):
        for kw in ({'object_id': None}, {'object_id': 0}, {'index_id': 0}, {'partition_number': 0},
                   {'partition_number': 3}, {'partition_count': None}, {'database_id': True}):
            with self.subTest(kw=kw):
                self.assertEqual('unknown', advise(index(**kw))['indexes'][0]['status'])

    def test_missing_or_bad_measurements(self):
        for kw in ({'page_count': None}, {'page_count': -1}, {'avg_fragmentation_in_percent': None},
                   {'avg_fragmentation_in_percent': float('nan')}, {'avg_fragmentation_in_percent': 101},
                   {'page_count': True}, {'scan_mode': 'DETAILED'}):
            with self.subTest(kw=kw):
                self.assertEqual('unknown', advise(index(**kw))['indexes'][0]['status'])

    def test_limited_density_is_unknown(self):
        self.assertIsNone(advise(index(avg_page_space_used_in_percent=80))['indexes'][0]['page_density_percent'])

    def test_sampled_density_visible(self):
        self.assertEqual(80, advise(index(scan_mode='SAMPLED', avg_page_space_used_in_percent=80))['indexes'][0]['page_density_percent'])

    def test_page_locks_not_silently_enabled(self):
        result = advise(index(allow_page_locks=False))
        self.assertIn('ALLOW_PAGE_LOCKS', result['indexes'][0]['proposed'])
        self.assertIsNone(result['indexes'][0]['suggested_sql'])

    def test_partition_scope_and_no_all(self):
        sql = advise(index(partition_number=2, partition_count=3, avg_fragmentation_in_percent=60))['indexes'][0]['suggested_sql']
        self.assertIn('PARTITION = 2', sql)
        self.assertNotIn('INDEX ALL', sql)
        self.assertIn('ONLINE = OFF', sql)
        self.assertNotIn('SORT_IN_TEMPDB = ON', sql)
        self.assertNotIn('PARTITION', advise()['indexes'][0]['suggested_sql'])

    def test_name_escaping(self):
        sql = advise(index(index_name="I]x';--", table_name='T]able'))['indexes'][0]['suggested_sql']
        self.assertIn("[I]]x';--]", sql)
        self.assertIn('[T]]able]', sql)
        for name in ('', 'x\ny', 'x' * 129):
            with self.assertRaises(ValueError):
                quote_name(name)

    def test_bad_names_no_sql(self):
        result = advise(index(index_name='bad\nname'))
        self.assertFalse(any(x['sql'] for x in result['findings']))

    def test_database_mismatch(self):
        result = advise(index(database_name='OtherDB'))
        self.assertEqual([], result['indexes'])
        self.assertTrue(any(x['rule_id'] == 'index_scope_mismatch' for x in result['findings']))

    def test_duplicate_not_summed(self):
        result = recommend_indexes(MANIFEST, [record('sql.index_health', index()), record('sql.index_health', index())])
        self.assertEqual(1, len(result['indexes']))
        self.assertEqual(2000, result['indexes'][0]['page_count'])
        self.assertTrue(any(x['rule_id'] == 'index_duplicate_measurement' for x in result['findings']))

    def test_error_and_truncation_visible(self):
        result = recommend_indexes(MANIFEST, [record('sql.index_health', index(), status='truncated'),
                                              record('sql.statistics_health', status='error', error='permission denied')])
        self.assertEqual(1, len(result['indexes']))
        self.assertTrue(any(x['rule_id'] == 'index_source_truncated' for x in result['findings']))
        self.assertTrue(any(x['reason'] == 'permission denied' for x in result['findings']))

    def test_missing_old_capture_unknown(self):
        result = recommend_indexes(MANIFEST, [])
        self.assertEqual({'index_audit_missing', 'statistics_audit_missing'}, {x['rule_id'] for x in result['findings']})
        self.assertTrue(all(x['status'] == 'unknown' for x in result['findings']))

    def test_statistics_modification_candidate(self):
        result = recommend_indexes(MANIFEST, [record('sql.statistics_health', stats())])
        self.assertEqual(30, result['statistics'][0]['modified_percent_estimate'])
        self.assertIn('UPDATE STATISTICS', result['statistics'][0]['suggested_sql'])
        self.assertNotIn('FULLSCAN', result['statistics'][0]['suggested_sql'])

    def test_old_unchanged_statistics_kept(self):
        result = recommend_indexes(MANIFEST, [record('sql.statistics_health', stats(modification_counter=0))])
        self.assertEqual('keep', result['statistics'][0]['status'])
        self.assertIsNone(result['statistics'][0]['suggested_sql'])

    def test_statistics_small_number_not_candidate(self):
        result = recommend_indexes(MANIFEST, [record('sql.statistics_health', stats(unfiltered_rows=100, modification_counter=499))])
        self.assertEqual('keep', result['statistics'][0]['status'])

    def test_statistics_missing_and_empty_unknown(self):
        for row in (stats(properties_available=False), stats(last_updated_sql_local=None, unfiltered_rows=0),
                    stats(modification_counter=None), stats(modification_counter=-1)):
            with self.subTest(row=row):
                result = recommend_indexes(MANIFEST, [record('sql.statistics_health', row)])
                self.assertEqual('unknown', result['statistics'][0]['status'])
                self.assertIsNone(result['statistics'][0]['suggested_sql'])

    def test_norecompute_and_incremental_no_blind_update(self):
        for kw in ({'no_recompute': True}, {'is_incremental': True}):
            result = recommend_indexes(MANIFEST, [record('sql.statistics_health', stats(**kw))])
            self.assertEqual('review', result['statistics'][0]['status'])
            self.assertIsNone(result['statistics'][0]['suggested_sql'])

    def test_filtered_denominator(self):
        result = recommend_indexes(MANIFEST, [record('sql.statistics_health', stats(has_filter=True, rows_at_update=10))])
        self.assertEqual(30, result['statistics'][0]['modified_percent_estimate'])

    def test_heap_never_creates_clustered_index(self):
        result = recommend_indexes(MANIFEST, [record('sql.heap_health', index(used_page_count=5000))])
        self.assertEqual(1, len(result['large_heaps']))
        self.assertFalse(any(x['sql'] for x in result['findings']))

    def test_evidence_line_preserved(self):
        result = recommend_indexes(MANIFEST, [record('sql.index_health', index(), _line=37)])
        self.assertEqual(37, result['indexes'][0]['evidence']['line'])

    def test_html_escaped_and_bounded(self):
        result = advise(index(table_name='<script>alert(1)</script>'))
        html = render_index_document(result, MANIFEST)
        self.assertNotIn('<script>', html)
        self.assertIn('&lt;script&gt;', html)
        self.assertIn('Не измерено', html)

    def test_input_not_modified(self):
        records = [record('sql.index_health', index())]
        old = copy.deepcopy(records)
        recommend_indexes(MANIFEST, records)
        self.assertEqual(old, records)

    def test_audit_integration_no_false_missing_cpu(self):
        result = analyze.summarize(MANIFEST, [record('sql.index_health', index())])
        self.assertNotIn('missing_sources', result)
        self.assertEqual('0.4.0-pilot', result['analyzer_version'])
        self.assertIn('REORGANIZE', analyze.render(result))
        json.dumps(result, allow_nan=False)

    def test_regular_report_retains_existing_sections(self):
        m = dict(MANIFEST, profile='runtime', skip_sql=True)
        result = analyze.summarize(m, [])
        html = analyze.render(result)
        self.assertIn('Настройки и обслуживание', html)
        self.assertIn('index-advisor', html)
        self.assertIn('Нагрузка по базам', html)
        self.assertEqual([], result['index_advisor']['indexes'])

    def test_capture_zip_contract(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'synthetic.zip'
            with ZipFile(p, 'w') as z:
                z.writestr('manifest.json', json.dumps(MANIFEST))
                z.writestr('records.jsonl', json.dumps(record('sql.index_health', index())) + '\n')
            m, records = analyze.read_capture(p)
            result = analyze.summarize(m, records)
            self.assertEqual(1, len(result['index_advisor']['indexes']))
            self.assertEqual(1, result['index_advisor']['indexes'][0]['evidence']['line'])


if __name__ == '__main__':
    unittest.main()
