import copy
import unittest
from workload import summarize_workload
import analyze


def record(source, rows, tick=0, status='ok'):
    return dict(source=source, rows=rows, tick=tick, status=status,
                collected_utc=f'2026-01-01T00:00:{tick:02d}+00:00')


def request(session=11, db=7, start='2026-01-01T00:00:00', **kw):
    row=dict(session_id=session, request_id=0, connection_id='conn', database_id=db,
             request_start_time_sql_local=start, query_hash='0x1111111111111111',
             query_plan_hash='0x2222222222222222', host_name='test', host_process_id=100,
             program_name='synthetic', cpu_time=20, total_elapsed_time=50,
             wait_type='CXPACKET', statement_start_offset=0, statement_end_offset=-1)
    row.update(kw)
    return row


class WorkloadTests(unittest.TestCase):
    def setUp(self):
        self.manifest=dict(host='test', selected_database='selected')
        self.base=[record('sql.databases', [dict(database_id=6,name='selected'), dict(database_id=7,name='busy')]),
                   record('windows.onec_versions', [dict(pid=100,process_name='rphost',file_version='synthetic')])]

    def run_workload(self, tail):
        return summarize_workload(self.manifest, self.base+tail)

    def test_cross_database_scope(self):
        result=self.run_workload([record('sql.requests', [request()])])
        self.assertEqual(result['selected_request_observations'],0)
        self.assertEqual(result['other_database_request_observations'],1)
        self.assertEqual(result['query_groups'][0]['database_name'],'busy')
        self.assertTrue(result['observations'])

    def test_repeated_snapshots_do_not_sum_cpu_or_executions(self):
        result=self.run_workload([record('sql.requests',[request()],0),
            record('sql.requests',[request(cpu_time=35,total_elapsed_time=80)],1)])['query_groups'][0]
        self.assertEqual(result['request_observations'],2)
        self.assertEqual(result['distinct_request_instances_observed'],1)
        self.assertEqual(result['max_cpu_ms'],35)
        self.assertEqual(result['max_concurrent_in_sample'],1)

    def test_concurrent_and_reused_sessions(self):
        result=self.run_workload([record('sql.requests',[request(11),request(12)],0),
            record('sql.requests',[request(11,start='2026-01-01T00:01:00')],1)])['query_groups'][0]
        self.assertEqual(result['distinct_request_instances_observed'],3)
        self.assertEqual(result['max_concurrent_in_sample'],2)

    def test_unknown_hashes_not_one_pattern(self):
        result=self.run_workload([record('sql.requests',[request(11,query_hash=None),request(12,query_hash=None)])])
        self.assertEqual(len(result['query_groups']),2)

    def test_remote_pid_not_matched_to_local_process(self):
        result=self.run_workload([record('sql.requests',[request(host_name='remote')])])
        self.assertIsNone(result['query_groups'][0]['local_process_version'])

    def test_truncated_source_not_treated_as_full_snapshot(self):
        result=self.run_workload([record('sql.requests',[request()],status='truncated')])
        self.assertEqual(result['request_sample_count'],0)
        self.assertEqual(result['query_groups'],[])

    def test_evidence_lines_escaping_and_mutation(self):
        rows=self.base+[record('sql.requests',[request()])]
        rows[-1]['_line']=42
        original=copy.deepcopy(rows)
        result=summarize_workload(self.manifest,rows)
        self.assertEqual(rows,original)
        self.assertEqual(result['query_groups'][0]['evidence_lines'],[42])
        text=analyze.table([dict(name='<script>bad()</script>')],[('name','name')])
        self.assertNotIn('<script>',text)
        self.assertIn('&lt;script&gt;',text)

    def test_reused_database_id_not_mislabeled(self):
        result=self.run_workload([record('sql.databases',[dict(database_id=7,name='replacement')]),
                                  record('sql.requests',[request()])])
        self.assertIsNone(result['query_groups'][0]['database_name'])

    def test_internal_waits_visible_separately(self):
        rows=[]
        for tick in (0,1):
            rows += [record('sql.epoch',[dict(sqlserver_start_time='epoch')],tick),
                record('sql.waits',[dict(wait_type=name,waiting_tasks_count=1+tick,
                       wait_time_ms=10+tick*100,signal_wait_time_ms=tick)
                       for name in ('SOS_WORK_DISPATCHER','CXPACKET')],tick)]
        result=analyze.summarize(self.manifest,rows)
        self.assertEqual(result['waits'][0]['wait_type'],'CXPACKET')
        self.assertEqual(result['background_waits'][0]['wait_type'],'SOS_WORK_DISPATCHER')
        self.assertEqual(result['background_waits'][0]['wait_time_ms'],100)


if __name__=='__main__':
    unittest.main()
