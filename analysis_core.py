#!/usr/bin/env python3
"""Offline interval summary. Python 3.10+, standard library only. Never connects to servers."""
from __future__ import annotations
import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
from html import escape
import json
from pathlib import Path
import statistics
from typing import Any
from zipfile import ZipFile, BadZipFile
from workload import summarize_workload

ANALYZER_VERSION = "0.2.0-pilot"
# Internal waits are shown separately, not asserted to be harmless.
INTERNAL_WAITS = {"SOS_WORK_DISPATCHER", "SQLTRACE_INCREMENTAL_FLUSH_SLEEP"}

MAX_INPUT_BYTES = 256 * 1024 * 1024
IDLE_WAITS = {
    'SLEEP_TASK', 'SLEEP_SYSTEMTASK', 'WAITFOR', 'BROKER_RECEIVE_WAITFOR',
    'BROKER_TASK_STOP', 'BROKER_EVENTHANDLER', 'LAZYWRITER_SLEEP',
    'SQLTRACE_BUFFER_FLUSH', 'XE_TIMER_EVENT', 'XE_DISPATCHER_WAIT',
    'REQUEST_FOR_DEADLOCK_SEARCH', 'LOGMGR_QUEUE', 'CHECKPOINT_QUEUE',
    'DIRTY_PAGE_POLL', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
    'HADR_FILESTREAM_IOMGR_IOCOMPLETION', 'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP',
    'QDS_ASYNC_QUEUE', 'SP_SERVER_DIAGNOSTICS_SLEEP', 'ONDEMAND_TASK_QUEUE',
}
WAIT_COUNTERS = ('waiting_tasks_count', 'wait_time_ms', 'signal_wait_time_ms')
IO_COUNTERS = ('num_of_reads', 'num_of_bytes_read', 'io_stall_read_ms',
               'num_of_writes', 'num_of_bytes_written', 'io_stall_write_ms')

def timestamp(value: str) -> datetime:
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    if result.tzinfo is None:
        raise ValueError('An explicit timezone is required for capture timestamps.')
    return result.astimezone(timezone.utc)

def numeric(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)

def counter_delta(before: dict, after: dict, fields: tuple[str, ...]) -> dict | None:
    """Missing or decreasing cumulative counters invalidate the interval; never clamp to zero."""
    if any(not numeric(before.get(k)) or not numeric(after.get(k)) for k in fields):
        return None
    result = {k: after[k] - before[k] for k in fields}
    return None if any(v < 0 for v in result.values()) else result

def safe_ratio(a: float, b: float) -> float | None:
    return a / b if b > 0 else None

def wait_category(name: str) -> str:
    if name.startswith('LCK_M_'): return 'Блокировки SQL'
    if name.startswith('PAGEIOLATCH_'): return 'Ожидание страниц с диска'
    if name == 'WRITELOG': return 'Запись журнала транзакций'
    if name.startswith('PAGELATCH_'): return 'Синхронизация страниц в памяти, не дисковое I/O'
    if name.startswith('RESOURCE_SEMAPHORE'): return 'Память для запросов / компиляции'
    if name == 'ASYNC_NETWORK_IO': return 'Клиент забирает результат / сеть'
    if name == 'SOS_SCHEDULER_YIELD': return 'Выполнение SQL / очередь CPU'
    if name.startswith('CX'): return 'Параллельное выполнение; не самостоятельный диагноз'
    if name == 'HADR_SYNC_COMMIT': return 'Подтверждение синхронной реплики'
    return 'Нужна интерпретация конкретного ожидания'

def read_capture(path: Path) -> tuple[dict, list[dict]]:
    if path.is_dir():
        def read(name: str) -> str:
            f = path / name
            if f.stat().st_size > MAX_INPUT_BYTES:
                raise ValueError(f'{name}: file exceeds input limit')
            return f.read_text(encoding='utf-8-sig')
        manifest_text, record_text = read('manifest.json'), read('records.jsonl')
    else:
        with ZipFile(path) as z:
            if sum(i.file_size for i in z.infolist()) > MAX_INPUT_BYTES:
                raise ValueError('Archive exceeds the uncompressed size limit')
            def read(name: str) -> str:
                entries = [i for i in z.infolist() if Path(i.filename).name == name]
                if len(entries) != 1:
                    raise ValueError(f'Expected exactly one {name} in capture archive')
                # Read in memory; never extract untrusted file paths.
                return z.read(entries[0]).decode('utf-8-sig')
            manifest_text, record_text = read('manifest.json'), read('records.jsonl')
    manifest = json.loads(manifest_text)
    if manifest.get('schema_version') != '0.1':
        raise ValueError('Unsupported capture schema version')
    records = []
    for number, line in enumerate(record_text.splitlines(), 1):
        if not line.strip(): continue
        try:
            record = json.loads(line)
            if not isinstance(record, dict) or not isinstance(record.get('rows'), list):
                raise ValueError('record must contain a rows array')
            timestamp(record['collected_utc'])
            record["_line"] = number
            records.append(record)
        except (ValueError, KeyError, TypeError) as e:
            raise ValueError(f'Invalid records.jsonl line {number}: {e}') from e
    return manifest, records

def summarize(manifest: dict, records: list[dict]) -> dict:
    by_source: dict[str, list[dict]] = defaultdict(list)
    coverage = defaultdict(Counter)
    for r in records:
        by_source[r['source']].append(r)
        coverage[r['source']][r['status']] += 1
    for seq in by_source.values():
        seq.sort(key=lambda r: timestamp(r['collected_utc']))
    def good(source: str) -> list[dict]:
        return [r for r in by_source[source] if r['status'] == 'ok']
    epochs = {r['tick']: r['rows'][0].get('sqlserver_start_time')
              for r in good('sql.epoch') if r['rows']}
    invalid = Counter()
    def pairs(source: str, require_epoch: bool = True):
        seq = good(source)
        for a, b in zip(seq, seq[1:]):
            if b['tick'] != a['tick'] + 1:
                invalid[source + ':missing_intermediate_sample'] += 1
                continue
            if require_epoch and (not epochs.get(a['tick']) or epochs[a['tick']] != epochs.get(b['tick'])):
                invalid[source + ':restart_or_missing_epoch'] += 1
                continue
            seconds = (timestamp(b['collected_utc']) - timestamp(a['collected_utc'])).total_seconds()
            if seconds <= 0:
                invalid[source + ':clock_error'] += 1
                continue
            yield a, b, seconds

    wait_totals: dict[str, Counter] = defaultdict(Counter)
    wait_seconds = 0.0
    valid_wait_intervals = 0
    for a, b, seconds in pairs('sql.waits'):
        old, new = ({r['wait_type']: r for r in x['rows']} for x in (a, b))
        # Reject the ENTIRE interval if any existing wait counter decreased.
        deltas = {}
        reset = False
        for name in old.keys() & new.keys():
            delta = counter_delta(old[name], new[name], WAIT_COUNTERS)
            if delta is None: reset = True; break
            deltas[name] = delta
        if reset:
            invalid['sql.waits:counter_reset_or_missing_value'] += 1
            continue
        if old.keys() != new.keys():
            # New/removed wait rows are not assumed to start at zero.
            invalid['sql.waits:changed_wait_catalog'] += 1
            continue
        valid_wait_intervals += 1
        wait_seconds += seconds
        for name, delta in deltas.items(): wait_totals[name].update(delta)
    waits = sorted(({'wait_type': name, 'category': wait_category(name), **dict(values)}
                    for name, values in wait_totals.items()
                    if name not in IDLE_WAITS | INTERNAL_WAITS and values['wait_time_ms'] > 0),
                   key=lambda r: r['wait_time_ms'], reverse=True)

    background_waits = sorted(({'wait_type': name, **dict(values)}
        for name, values in wait_totals.items()
        if name in IDLE_WAITS | INTERNAL_WAITS and values['wait_time_ms'] > 0),
        key=lambda row: row['wait_time_ms'], reverse=True)

    io_totals: dict[tuple, Counter] = defaultdict(Counter)
    def file_key(row: dict) -> tuple:
        return (row.get('database_id'), row.get('file_id'), row.get('file_guid'),
                row.get('physical_name'), row.get('type_desc'))
    for a, b, seconds in pairs('sql.io'):
        old = {file_key(r): r for r in a['rows']}
        for row in b['rows']:
            k = file_key(row)
            if k not in old:
                invalid['sql.io:new_or_changed_file'] += 1; continue
            delta = counter_delta(old[k], row, IO_COUNTERS)
            if delta is None:
                invalid['sql.io:counter_reset_or_missing_value'] += 1; continue
            io_totals[k].update(delta)
            io_totals[k]['covered_seconds'] += seconds
            io_totals[k]['valid_intervals'] += 1
    files = []
    for key, values in io_totals.items():
        files.append(dict(database_id=key[0], file_id=key[1], file_guid=key[2], path=key[3],
                          type=key[4], **dict(values),
                          avg_read_ms=safe_ratio(values['io_stall_read_ms'], values['num_of_reads']),
                          avg_write_ms=safe_ratio(values['io_stall_write_ms'], values['num_of_writes']),
                          read_mib_per_second=safe_ratio(values['num_of_bytes_read']/1048576, values['covered_seconds']),
                          write_mib_per_second=safe_ratio(values['num_of_bytes_written']/1048576, values['covered_seconds'])))
    files.sort(key=lambda r: max(r['avg_read_ms'] or 0, r['avg_write_ms'] or 0), reverse=True)

    disk_totals: dict[str, Counter] = defaultdict(Counter)
    for a, b, _ in pairs('windows.disk_raw', require_epoch=False):
        old = {r['Name']: r for r in a['rows']}
        for row in b['rows']:
            name = row['Name']
            before = old.get(name)
            if before is None: continue
            freq = row.get('Frequency_PerfTime')
            if not numeric(freq) or freq <= 0 or freq != before.get('Frequency_PerfTime'):
                invalid['windows.disk_raw:invalid_frequency'] += 1; continue
            fields = ('Timestamp_PerfTime','AvgDisksecPerRead','AvgDisksecPerRead_Base',
                      'AvgDisksecPerWrite','AvgDisksecPerWrite_Base',
                      'DiskReadBytesPersec','DiskWriteBytesPersec')
            delta = counter_delta(before, row, fields)
            if delta is None or delta['Timestamp_PerfTime'] <= 0:
                invalid['windows.disk_raw:counter_reset_or_missing_value'] += 1; continue
            out = disk_totals[name]
            out['read_latency_seconds'] += delta['AvgDisksecPerRead']/freq
            out['write_latency_seconds'] += delta['AvgDisksecPerWrite']/freq
            out['read_operations'] += delta['AvgDisksecPerRead_Base']
            out['write_operations'] += delta['AvgDisksecPerWrite_Base']
            out['read_bytes'] += delta['DiskReadBytesPersec']
            out['write_bytes'] += delta['DiskWriteBytesPersec']
            out['covered_seconds'] += delta['Timestamp_PerfTime']/freq
    disks = [dict(name=name, **dict(v),
                  avg_read_ms=safe_ratio(v['read_latency_seconds']*1000, v['read_operations']),
                  avg_write_ms=safe_ratio(v['write_latency_seconds']*1000, v['write_operations']))
             for name, v in disk_totals.items()]

    cpu = [row['PercentProcessorTime'] for r in good('windows.cpu') for row in r['rows']
           if row.get('Name') == '_Total' and numeric(row.get('PercentProcessorTime'))]
    available = [row['AvailableMBytes'] for r in good('windows.memory') for row in r['rows']
                 if numeric(row.get('AvailableMBytes'))]
    blocking = []
    for r in good('sql.requests'):
        for row in r['rows']:
            if numeric(row.get('blocking_session_id')) and row['blocking_session_id'] > 0:
                blocking.append(dict(collected_utc=r['collected_utc'], **row))
    blockers = Counter(r['blocking_session_id'] for r in blocking)
    grants = [row.get('waiting_requests') or 0 for r in good('sql.grants') for row in r['rows']]
    # Only recorded observations are reported. There is intentionally no automatic "healthy" verdict.
    workload = summarize_workload(manifest, records)
    observations = list(workload['observations'])
    if blocking:
        observations.append('В снимках есть блокируемые запросы SQL. Проверить головного блокировщика и открытую транзакцию, включая спящий сеанс.')
    if grants and max(grants) > 0:
        observations.append('Есть запросы, ожидающие выделения памяти. Нужны планы и объёмы memory grants; это ещё не доказательство нехватки физической RAM.')
    if cpu and max(cpu) >= 85:
        observations.append('Есть снимки с общей загрузкой CPU не ниже 85%. Это сигнальный порог пилота, не доказательство необходимости нового процессора.')
    if not observations:
        observations.append('Автоматически интерпретируемых признаков недостаточно. Это не заключение об отсутствии проблемы.')
    expected = ['windows.cpu','windows.memory','windows.disk_raw']
    if not manifest.get('skip_sql'): expected += ['sql.epoch','sql.waits','sql.io','sql.requests','sql.open_sessions','sql.grants']
    missing = [s for s in expected if not good(s)]
    issues = [{'source': r['source'], 'status': r['status'], 'time': r['collected_utc'],
               'detail': r.get('error') or 'Result exceeded row cap; interpretation is incomplete.'}
              for r in records if r['status'] != 'ok']
    return dict(
        schema_version='0.1', analyzer_version=ANALYZER_VERSION, manifest=manifest,
        workload=workload, background_waits=background_waits,
        interpretation='Наблюдения за интервалом, не установленная первопричина. Сравнить с временем жалобы пользователя.',
        coverage={s: dict(c) for s,c in sorted(coverage.items())}, missing_sources=missing,
        observations=observations, collection_issues=issues,
        discarded_intervals=dict(invalid),
        cpu=dict(sample_count=len(cpu), sampled_mean_percent=statistics.mean(cpu) if cpu else None,
                 sampled_max_percent=max(cpu) if cpu else None),
        memory=dict(sample_count=len(available), min_sampled_available_mib=min(available) if available else None),
        waits=waits, wait_valid_intervals=valid_wait_intervals, wait_covered_seconds=wait_seconds,
        sql_files=files, windows_disks=disks,
        blocking_observations=blocking[:200], blocking_observations_total=len(blocking),
        blocker_sample_hits=dict(blockers),
        max_sampled_waiting_memory_grants=max(grants) if grants else None,
        limitations=[
            'Отсутствие события в периодических снимках не доказывает его отсутствия между снимками.',
            'Длительность и CPU активного SQL-запроса — накопленные значения самого запроса; они не суммируются по снимкам.',
            'Ожидания SQL относятся ко всему экземпляру, не только к выбранной базе.',
            'Суммарное время ожиданий параллельных потоков может быть больше длительности наблюдения.',
            'Средняя задержка I/O — сумма приращений задержек / сумма операций; без операций значение неизвестно, а не ноль.',
            'Полный сброс и быстрый повторный рост счётчиков между снимками не всегда можно обнаружить.',
            'Гостевая ОС не даёт полной картины загрузки гипервизора, SAN и соседних VM.',
            'Не собраны: RAC/ТЖ 1С, история запросов Query Store, планы, тексты SQL, XE, ошибки ОС/SQL, подробная статистика/индексы.',
            'Пустая или ограниченная история msdb не доказывает отсутствие обслуживания и резервных копий.',
        ])

def display(value: Any) -> str:
    if value is None: return 'Нет данных'
    if isinstance(value, float): return f'{value:,.2f}'
    return str(value)

def table(rows: list[dict], columns: list[tuple[str,str]], limit: int = 50) -> str:
    if not rows: return '<p>Нет пригодных данных для этой таблицы.</p>'
    head = ''.join('<th>'+escape(label)+'</th>' for _,label in columns)
    body = ''.join('<tr>'+''.join('<td>'+escape(display(row.get(key)))+'</td>' for key,_ in columns)+'</tr>' for row in rows[:limit])
    note = f'<p>Показано {min(len(rows),limit)} из {len(rows)} строк. Полные расчёты — summary.json.</p>'
    return '<div class="scroll"><table><thead><tr>'+head+'</tr></thead><tbody>'+body+'</tbody></table></div>'+note

def render(summary: dict) -> str:
    m=summary['manifest']
    heading='1С + SQL Server · диагностический срез'
    blocks=[f'<header><div>ДИАГНОСТИКА / АНАЛИЗАТОР 0.2</div><h1>{heading}</h1><p>'+escape(f"{m.get('case_id')} / {m.get('host')} / {m.get('started_utc')} — {m.get('ended_utc')}")+'</p></header>',
            '<section class="notice"><b>Причина ещё не установлена.</b> Этот отчёт показывает измерения и пропуски сбора. Отсутствие предупреждения не означает, что сервер исправен.</section>',
            '<h2>Наблюдения</h2>']
    for text in summary['observations']: blocks.append('<p>'+escape(text)+'</p>')
    w = summary.get('workload', {})
    blocks.append('<h2>Нагрузка по базам и шаблонам запросов</h2><p>Мгновенные наблюдения, не число завершений и не доля CPU. Запросы всего экземпляра; выбранная база: '+escape(str(w.get('selected_database') or 'не выбрана'))+'</p>')
    blocks.append(table(w.get('query_groups', []), [
        ('database_name','База'),('query_hash','Query hash'),('host_process_id','PID клиента'),
        ('local_process_version','Версия локального процесса'),('request_observations','Наблюдений'),
        ('max_concurrent_in_sample','Одновременно, макс.'),('max_elapsed_ms','Возраст запроса, макс. мс'),
        ('max_cpu_ms','CPU запроса, макс. мс'),('waits_in_samples','Ожидания в снимках'),
        ('evidence_lines','Строки records.jsonl')]))
    for text in w.get('limitations', []): blocks.append('<p>'+escape(text)+'</p>')
    blocks.append('<h2>Очереди SQL и память запросов</h2>')
    blocks.append(table(w.get('scheduler_snapshots', []), [('collected_utc','UTC'),('runnable_tasks','Готовы к выполнению'),('line','Строка журнала')]))
    blocks.append(table(w.get('memory_grant_snapshots', []), [('collected_utc','UTC'),('grant_requests','Запросов'),('waiting_requests','Ждут память'),('granted_memory_kb','Выделено, КиБ'),('line','Строка журнала')]))
    blocks.append('<h2>Настройки экземпляра — не предписание изменять</h2>')
    blocks.append(table(w.get('settings', []), [('name','Параметр'),('configured_value','Задано'),('running_value','Применено')]))
    blocks.append('<h2>Ресурсы гостевой ОС</h2>')
    blocks.append(table([dict(metric='CPU: среднее по снимкам, %',value=summary['cpu']['sampled_mean_percent']),
                         dict(metric='CPU: максимум в снимках, %',value=summary['cpu']['sampled_max_percent']),
                         dict(metric='Доступная память: минимум в снимках, MiB',value=summary['memory']['min_sampled_available_mib'])], [('metric','Метрика'),('value','Значение')]))
    blocks.append('<h2>Прирост ожиданий SQL</h2><p>Экземпляр целиком. Фоновые ожидания отфильтрованы только в представлении; исходные данные сохранены. Это не проценты загрузки CPU.</p>')
    blocks.append(f'<p>Пригодных интервалов: {summary["wait_valid_intervals"]}; покрыто {summary["wait_covered_seconds"]:.1f} секунд.</p>')
    blocks.append(table(summary['waits'],[('wait_type','Ожидание'),('category','Направление проверки'),('wait_time_ms','Прирост, мс'),('waiting_tasks_count','Количество'),('signal_wait_time_ms','Signal wait, мс')],20))
    blocks.append('<details><summary>Внутренние и фоновые ожидания: сохранены отдельно, не являются диагнозом</summary>'+table(summary.get('background_waits', []), [('wait_type','Ожидание'),('wait_time_ms','Прирост, мс')],50)+'</details>')
    blocks.append('<h2>Файлы SQL: I/O за пригодные интервалы</h2><p>Высокая задержка не определяет виновника: сопоставить с объёмом I/O, нагрузкой ОС и запросами.</p>')
    blocks.append(table(summary['sql_files'],[('database_id','База ID'),('file_id','Файл ID'),('type','Тип'),('path','Путь'),('num_of_reads','Чтений'),('avg_read_ms','Чтение, мс'),('num_of_writes','Записей'),('avg_write_ms','Запись, мс'),('covered_seconds','Покрытие, с')]))
    blocks.append('<h2>Тома Windows</h2>')
    blocks.append(table(summary['windows_disks'],[('name','Том'),('read_operations','Чтений'),('avg_read_ms','Чтение, мс'),('write_operations','Записей'),('avg_write_ms','Запись, мс')]))
    blocks.append('<h2>Блокировки, замеченные в снимках</h2><p>Повторные попадания сеанса — не количество инцидентов. Отрицательные blocking_session_id не трактуются как пользовательские сеансы.</p>')
    blocks.append(table(summary['blocking_observations'],[('collected_utc','Время UTC'),('session_id','Ждущий'),('blocking_session_id','Блокировщик'),('wait_type','Ожидание'),('wait_time','Текущее ожидание, мс'),('database_id','База ID'),('program_name','Программа')]))
    blocks.append('<h2>Полнота сбора</h2>')
    if summary['missing_sources']: blocks.append('<p><b>Нет полных пригодных снимков:</b> '+escape(', '.join(summary['missing_sources']))+'</p>')
    coverage=[dict(source=s,**v) for s,v in summary['coverage'].items()]
    blocks.append(table(coverage,[('source','Источник'),('ok','OK'),('error','Ошибки'),('skipped','Пропущено'),('truncated','Усечено')],100))
    blocks.append(table(summary['collection_issues'],[('source','Источник'),('status','Статус'),('detail','Подробности')],30))
    if summary['discarded_intervals']:
        blocks.append('<h3>Исключённые интервалы</h3><pre>'+escape(json.dumps(summary['discarded_intervals'],ensure_ascii=False,indent=2))+'</pre>')
    blocks.append('<h2>Границы интерпретации</h2>')
    for text in summary['limitations']: blocks.append('<p>'+escape(text)+'</p>')
    blocks.append('<footer>Локальный отчёт без внешних ресурсов. Конфиденциально: имена серверов, баз и пути не обезличены.</footer>')
    css='''body{font:15px/1.5 system-ui,sans-serif;max-width:1320px;margin:28px auto;padding:0 24px;color:#162a35;background:#f5f7f9}header{padding:24px;background:#173243;color:white;border-radius:8px}h1{font-size:30px;margin:6px 0}h2{font-size:22px;margin-top:32px}.notice{margin-top:20px;padding:18px;background:#fff2d8;border-left:4px solid #b67a1b}table{border-collapse:collapse;background:white;width:100%;font-size:13px}th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #dde3e7;vertical-align:top}th{background:#e8eef2}td{max-width:420px;overflow-wrap:anywhere}.scroll{overflow-x:auto}footer{margin:36px 0;font-size:12px}pre{white-space:pre-wrap}'''
    return '<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>'+heading+'</title><style>'+css+'</style><body>'+''.join(blocks)+'</body></html>'

def main() -> None:
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture',type=Path,help='Capture ZIP or extracted directory')
    parser.add_argument('--output',type=Path,default=Path('analysis-output'))
    args=parser.parse_args()
    try:
        manifest,records=read_capture(args.capture)
        result=summarize(manifest,records)
        args.output.mkdir(parents=True,exist_ok=True)
        (args.output/'summary.json').write_text(json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False),encoding='utf-8')
        (args.output/'report.html').write_text(render(result),encoding='utf-8')
        print(args.output.resolve()/'report.html')
    except (OSError,ValueError,KeyError,TypeError,BadZipFile) as exc:
        parser.exit(2,f'Cannot analyze capture: {exc}\n')
if __name__=='__main__': main()
