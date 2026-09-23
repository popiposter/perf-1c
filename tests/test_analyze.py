import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from analyze import counter_delta, safe_ratio, summarize, render

def record(source,tick,rows,status='ok'):
    return dict(source=source,tick=tick,rows=rows,status=status,
                collected_utc=f'2026-09-23T09:00:{tick*15:02d}+00:00')

def epoch(tick,value='2026-09-20T08:00:00'):
    return record('sql.epoch',tick,[dict(sqlserver_start_time=value)])

def io(tick,reads,stalls,guid='same'):
    return record('sql.io',tick,[dict(database_id=5,file_id=1,file_guid=guid,
        physical_name='D:\\SQL\\pilot.mdf',type_desc='ROWS',num_of_reads=reads,
        io_stall_read_ms=stalls,num_of_bytes_read=reads*8192,num_of_writes=0,
        io_stall_write_ms=0,num_of_bytes_written=0)])

def wait(tick,value):
    return record('sql.waits',tick,[dict(wait_type='LCK_M_X',wait_time_ms=value,
                        waiting_tasks_count=value,signal_wait_time_ms=0)])

class AnalyzerTests(unittest.TestCase):
    def test_delta_missing_and_reset(self):
        self.assertIsNone(counter_delta({'n':20},{'n':5},('n',)))
        self.assertIsNone(counter_delta({'n':None},{'n':5},('n',)))
        self.assertEqual(counter_delta({'n':2},{'n':5},('n',)),{'n':3})

    def test_zero_io_not_zero_latency(self):
        self.assertIsNone(safe_ratio(0,0))
        r=summarize({},[epoch(0),io(0,10,50),epoch(1),io(1,10,50)])
        self.assertIsNone(r['sql_files'][0]['avg_read_ms'])

    def test_io_latency_weighted_not_mean_of_means(self):
        # First interval: 1 read at 100ms. Second: 99 reads totaling 99ms.
        r=summarize({},[epoch(0),io(0,0,0),epoch(1),io(1,1,100),epoch(2),io(2,100,199)])
        self.assertAlmostEqual(r['sql_files'][0]['avg_read_ms'],1.99)
        self.assertAlmostEqual(r['sql_files'][0]['covered_seconds'],30)

    def test_restart_excludes_deltas(self):
        r=summarize({},[epoch(0,'a'),io(0,0,0),epoch(1,'b'),io(1,10,30)])
        self.assertEqual(r['sql_files'],[])
        self.assertTrue(r['discarded_intervals'])

    def test_new_file_identity_excludes_deltas(self):
        r=summarize({},[epoch(0),io(0,0,0,'old'),epoch(1),io(1,10,30,'new')])
        self.assertEqual(r['sql_files'],[])

    def test_wait_reset_rejects_interval(self):
        r=summarize({},[epoch(0),wait(0,500),epoch(1),wait(1,10)])
        self.assertEqual(r['waits'],[])
        self.assertEqual(r['wait_valid_intervals'],0)

    def test_wait_increase(self):
        r=summarize({},[epoch(0),wait(0,500),epoch(1),wait(1,800)])
        self.assertEqual(r['waits'][0]['wait_time_ms'],300)
        self.assertEqual(r['wait_valid_intervals'],1)

    def test_missing_epoch_is_unknown(self):
        r=summarize({},[wait(0,500),wait(1,800)])
        self.assertEqual(r['waits'],[])
        self.assertIn('sql.epoch',r['missing_sources'])

    def test_truncation_not_success(self):
        r=summarize({},[record('sql.requests',0,[{'blocking_session_id':77}],'truncated')])
        self.assertIn('sql.requests',r['missing_sources'])
        self.assertEqual(len(r['collection_issues']),1)

    def test_negative_blocker_is_not_session(self):
        r=summarize({},[record('sql.requests',0,[dict(blocking_session_id=-5)])])
        self.assertEqual(r['blocking_observations_total'],0)

    def test_html_escapes_untrusted_names(self):
        r=summarize(dict(host='<script>alert(1)</script>'),[])
        html=render(r)
        self.assertNotIn('<script>',html)
        self.assertIn('&lt;script&gt;',html)

    def test_disk_raw_timer_formula(self):
        def d(tick,ts,latency,count):
            return record('windows.disk_raw',tick,[dict(Name='D:',Frequency_PerfTime=10000000,
                Timestamp_PerfTime=ts,AvgDisksecPerRead=latency,AvgDisksecPerRead_Base=count,
                AvgDisksecPerWrite=0,AvgDisksecPerWrite_Base=0,DiskReadBytesPersec=count*8192,
                DiskWriteBytesPersec=0)])
        r=summarize(dict(skip_sql=True),[d(0,1,0,0),d(1,150000001,5000000,100)])
        self.assertAlmostEqual(r['windows_disks'][0]['avg_read_ms'],5.0)
        self.assertIsNone(r['windows_disks'][0]['avg_write_ms'])

if __name__=='__main__': unittest.main()
