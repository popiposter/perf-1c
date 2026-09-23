import sys
from pathlib import Path
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from recommendations import recommend, render_recommendations, identifier, literal, integer

M={'selected_database':'test_db','include_maintenance':True,'role':'combined'}
def record(source, rows, status='ok'):
    return dict(source=source,status=status,rows=rows,collected_utc='2026-01-01T01:00:00Z')
def config(name, value):
    return record('sql.configurations',[dict(name=name,running_value=str(value),configured_value=str(value))])
def dbs():
    return record('sql.databases',[dict(database_id=5,name='test_db',recovery_model_desc='SIMPLE'),dict(database_id=6,name='other_db')])
def file(dbid=5, percent=False, growth=128, name='data'):
    return record('sql.files',[dict(database_id=dbid,name=name,type_desc='ROWS',growth=growth,
                                   is_percent_growth=percent,allocated_bytes=16*1024**3,state_desc='ONLINE')])
def find(out,key):
    return next(x for x in out['findings'] if x['rule_id']==key)

class AdviceTests(unittest.TestCase):
    def test_numeric_string_config(self):
        self.assertEqual(find(recommend(M,[config('max worker threads',2048)]),'workers')['proposed'],0)
    def test_keep_finite_memory_no_automatic_80_percent(self):
        f=find(recommend(M,[config('max server memory (MB)',30000)]),'memory')
        self.assertEqual((f['status'],f['proposed']),('keep',30000))
    def test_unlimited_memory_needs_budget_not_guessed_number(self):
        f=find(recommend(M,[config('max server memory (MB)',2147483647)]),'memory')
        self.assertEqual(f['status'],'review'); self.assertIsInstance(f['proposed'],str)
    def test_parallel_waits_do_not_set_global_maxdop_one(self):
        f=find(recommend(M,[config('max degree of parallelism',4)]),'maxdop')
        self.assertEqual(f['proposed'],4); self.assertIsNone(f['sql'])
    def test_growth_page_units(self):
        f=find(recommend(M,[dbs(),file()]),'file_growth')
        self.assertEqual(f['current'],'1 МиБ'); self.assertEqual(f['proposed'],'256 МиБ')
        self.assertIn('1024KB',f['rollback_sql'])
    def test_growth_percent_rollback(self):
        f=find(recommend(M,[dbs(),file(percent=True,growth=10)]),'file_growth')
        self.assertIn('10%',f['rollback_sql'])
    def test_existing_large_fixed_growth_not_flagged(self):
        out=recommend(M,[dbs(),file(growth=32768)])
        self.assertFalse(any(x['rule_id']=='file_growth' for x in out['findings']))
    def test_never_treat_zero_growth_as_small_increment(self):
        out=recommend(M,[dbs(),file(growth=0)])
        self.assertFalse(any(x['rule_id']=='file_growth' for x in out['findings']))
    def test_selected_scope_is_not_all_databases(self):
        self.assertEqual(recommend(M,[dbs(),file(dbid=6)])['database_scope'],['test_db'])
    def test_observed_active_database_in_scope(self):
        out=recommend(M,[dbs(),record('sql.requests',[{'database_id':6}]),file(dbid=6)])
        self.assertEqual(out['database_scope'],['test_db','other_db'])
        self.assertIn('other_db',find(out,'file_growth')['scope'])
    def test_truncated_data_not_accepted(self):
        r=config('max worker threads',2048); r['status']='truncated'
        self.assertEqual(find(recommend(M,[r]),'config_unknown')['status'],'unknown')
    def test_empty_backup_source_is_not_no_backups_verdict(self):
        f=find(recommend(M,[record('sql.backups',[])]),'backup_coverage')
        self.assertEqual(f['current'],'Записей за 14 дней: 0')
        self.assertIn('не исключает',f['reason']); self.assertEqual(f['scope'],'test_db')
    def test_skipped_backups_not_zero(self):
        f=find(recommend(M,[record('sql.backups',[],'skipped')]),'backup_coverage')
        self.assertEqual(f['status'],'unknown')
    def test_job_name_is_not_operation_proof(self):
        out=recommend(M,[record('sql.jobs',[{'name':'Nightly Backups','enabled':1}])])
        self.assertFalse(out['expanded_jobs_collected'])
        self.assertEqual(find(out,'maintenance_coverage')['status'],'unknown')
    def test_schedule_zero_not_no_execution_verdict(self):
        r=record('sql.jobs',[{'name':'synthetic','enabled':1,'active_schedule_count':0}])
        f=find(recommend(M,[r]),'job_schedule')
        self.assertIn('внешней',f['reason'])
    def test_nested_cap_marks_incomplete(self):
        r=record('sql.jobs',[{'name':'synthetic','active_schedule_count':1,'step_count':51}])
        self.assertFalse(recommend(M,[r])['expanded_jobs_collected'])
    def test_identifier_and_literal_escape_differ(self):
        self.assertEqual(identifier("x]O'Hare"),"[x]]O'Hare]")
        self.assertEqual(literal("x]O'Hare"),"N'x]O''Hare'")
    def test_control_characters_disallowed(self):
        with self.assertRaises(ValueError): identifier('bad\nname')
    def test_hostile_file_name_is_quoted_and_html_escaped(self):
        f=file(name="x]';<script>alert(1)</script>--")
        out=recommend(M,[dbs(),f]); text=render_recommendations(out)
        self.assertNotIn('<script>',text); self.assertIn('&lt;script&gt;',text)
        self.assertIn("NAME = N'x]'';",find(out,'file_growth')['sql'])
    def test_bool_not_numeric_configuration(self):
        self.assertIsNone(integer(True)); self.assertIsNone(integer('NaN'))
    def test_good_page_verification_is_kept(self):
        d=dbs();d['rows'][0]['page_verify_option_desc']='CHECKSUM'
        self.assertEqual(find(recommend(M,[d]),'page_verify')['status'],'keep')
    def test_unknown_database_id_not_silently_mapped(self):
        d=dbs();d['rows'].append({'database_id':None,'name':'test_db'})
        self.assertEqual(recommend(M,[d])['database_scope'],['test_db'])

if __name__=='__main__':unittest.main()
