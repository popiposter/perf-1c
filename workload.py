"""Evidence-linked workload observations. No I/O, SQL execution or health verdicts."""
from __future__ import annotations
from collections import Counter, defaultdict
from typing import Any


def number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def summarize_workload(manifest: dict, records: list[dict]) -> dict:
    by_source = defaultdict(list)
    for line, record in enumerate(records, 1):
        if record.get('status') == 'ok':
            by_source[record['source']].append((record.get('_line', line), record))
    # Only unambiguous names are used; a reused database ID must not be silently relabeled.
    names = defaultdict(set)
    for _, record in by_source['sql.databases']:
        for row in record['rows']:
            if isinstance(row.get('name'), str):
                names[row.get('database_id')].add(row['name'])
    dbnames = {key: next(iter(values)) for key, values in names.items() if len(values) == 1}
    selected = manifest.get('selected_database', '')
    selected_ids = {key for key, name in dbnames.items() if name == selected}
    versions = {}
    for _, record in by_source['windows.onec_versions']:
        for row in record['rows']:
            versions[row.get('pid')] = row
    groups = {}
    per_database = Counter()
    request_sources = []
    for sample, (line, record) in enumerate(by_source['sql.requests']):
        request_sources.append({'line': line, 'tick': record.get('tick'),
                                'collected_utc': record['collected_utc'], 'rows': len(record['rows'])})
        # Deduplicate identical rows in a snapshot, but never sum request CPU/elapsed across snapshots.
        seen = set()
        for row in record['rows']:
            identity = (row.get('connection_id'), row.get('session_id'), row.get('request_id'),
                        row.get('request_start_time_sql_local'), row.get('statement_start_offset'),
                        row.get('statement_end_offset'))
            query = row.get('query_hash')
            # Unknown hashes are NOT one common query template.
            template = query or (row.get('sql_handle'), identity, sample)
            key = (row.get('database_id'), template, row.get('query_plan_hash'),
                   row.get('host_name'), row.get('host_process_id'), row.get('program_name'))
            if (key, identity) in seen:
                continue
            seen.add((key, identity))
            per_database[row.get('database_id')] += 1
            if key not in groups:
                local = str(row.get('host_name') or '').casefold() == str(manifest.get('host') or '').casefold()
                version = versions.get(row.get('host_process_id'), {}) if local else {}
                groups[key] = dict(database_id=row.get('database_id'),
                    database_name=dbnames.get(row.get('database_id')),
                    query_hash=query, query_plan_hash=row.get('query_plan_hash'),
                    host_name=row.get('host_name'), host_process_id=row.get('host_process_id'),
                    program_name=row.get('program_name'), local_process_name=version.get('process_name'),
                    local_process_version=version.get('file_version'),
                    request_observations=0, max_elapsed_ms=None, max_cpu_ms=None,
                    first_observed_utc=record['collected_utc'], last_observed_utc=record['collected_utc'],
                    evidence_lines=[], _instances=set(), _samples=Counter(), _waits=Counter())
            group = groups[key]
            group['request_observations'] += 1
            # This is a lower bound of observed request/statement instances, not completed executions.
            group['_instances'].add(identity)
            group['_samples'][sample] += 1
            group['_waits'][row.get('wait_type') or '(none)'] += 1
            group['last_observed_utc'] = record['collected_utc']
            if line not in group['evidence_lines']:
                group['evidence_lines'].append(line)
            for field, original in [('max_elapsed_ms', 'total_elapsed_time'), ('max_cpu_ms', 'cpu_time')]:
                value = row.get(original)
                if number(value):
                    group[field] = max(group[field], value) if group[field] is not None else value
    out = []
    for group in groups.values():
        group['distinct_request_instances_observed'] = len(group.pop('_instances'))
        samples = group.pop('_samples')
        group['samples_with_query'] = len(samples)
        group['max_concurrent_in_sample'] = max(samples.values())
        group['waits_in_samples'] = dict(group.pop('_waits'))
        out.append(group)
    out.sort(key=lambda group: (group['max_concurrent_in_sample'], group['request_observations'],
                               group['max_elapsed_ms'] or 0), reverse=True)
    snapshots = []
    for line, record in by_source['sql.schedulers']:
        values = [row.get('runnable_tasks') for row in record['rows']]
        snapshots.append({'line': line, 'collected_utc': record['collected_utc'],
                          'runnable_tasks': sum(values) if values and all(number(x) for x in values) else None})
    grants = []
    for line, record in by_source['sql.grants']:
        for row in record['rows']:
            grants.append(dict(line=line, collected_utc=record['collected_utc'], **row))
    observed = [dict(database_id=dbid, database_name=dbnames.get(dbid), request_observations=count)
                for dbid, count in per_database.most_common()]
    other = sum(count for dbid, count in per_database.items() if dbid not in selected_ids and dbid in dbnames)
    notes = []
    if selected and selected_ids and other:
        notes.append(f'Выбрана база {selected}, но {other} наблюдений активных запросов относятся к другим базам. '
                     'Показатели всего экземпляра нельзя приписывать выбранной базе.')
    if any(group['max_concurrent_in_sample'] > 1 and group['query_hash'] for group in out):
        notes.append('В одном снимке есть несколько запросов с одинаковым query_hash. '
                     'Это запросы сходной структуры, не обязательно одинаковые параметры или дубли бизнес-операции.')
    settings = [row for _, record in by_source['sql.configurations'] for row in record['rows']
                if row.get('name') in {'max server memory (MB)', 'max degree of parallelism',
                                      'cost threshold for parallelism', 'max worker threads'}]
    return dict(selected_database=selected, selected_database_ids=sorted(selected_ids),
        selected_request_observations=sum(per_database[x] for x in selected_ids) if selected_ids else None,
        other_database_request_observations=other if selected_ids else None,
        request_sample_count=len(request_sources), request_samples=request_sources,
        databases=observed, query_groups=out, scheduler_snapshots=snapshots,
        memory_grant_snapshots=grants, settings=settings, observations=notes,
        limitations=[
            'Наблюдения и уникальные видимые запросы не равны числу завершённых выполнений или доле CPU базы.',
            'MAX CPU и MAX elapsed — независимые максимумы, а не сумма или полное время завершённых операций.',
            'query_hash группирует сходные запросы; значения параметров могут различаться.',
            'Для параллельных row-mode запросов reads/writes/logical_reads координатора могут не обновляться.',
            'Версия локального процесса — сопоставление PID и имени хоста с отдельным снимком, не идентификатор сеанса 1С.',
            'Memory grants и очереди планировщиков относятся к экземпляру, не автоматически к группе запросов.',
        ])
