"""Evidence-based configuration/maintenance advice. Never connects or applies changes."""
from __future__ import annotations
from collections import defaultdict
from datetime import datetime, timedelta
from html import escape
import json

RULESET_VERSION = '0.3.0-pilot'
DOC = 'https://learn.microsoft.com/en-us/'
SOURCES = {
    'workers': DOC+'sql/database-engine/configure-windows/configure-the-max-worker-threads-server-configuration-option',
    'memory': DOC+'sql/database-engine/configure-windows/server-memory-server-configuration-options',
    'parallelism': DOC+'sql/database-engine/configure-windows/configure-the-max-degree-of-parallelism-server-configuration-option',
    'growth': DOC+'troubleshoot/sql/database-engine/database-file-operations/considerations-autogrow-autoshrink',
    'backup': DOC+'sql/relational-databases/backup-restore/create-a-full-database-backup-sql-server',
    'checksum': DOC+'sql/database-engine/configure-windows/backup-checksum-default',
    'compression': DOC+'sql/relational-databases/backup-restore/backup-compression-sql-server',
    'indexes': DOC+'sql/relational-databases/indexes/reorganize-and-rebuild-indexes',
    'stats': DOC+'sql/relational-databases/system-stored-procedures/sp-updatestats-transact-sql',
    'checkdb': DOC+'sql/t-sql/database-console-commands/dbcc-checkdb-transact-sql',
    'database': DOC+'sql/t-sql/statements/alter-database-transact-sql-set-options',
    'jobs': DOC+'sql/ssms/agent/monitor-and-respond-to-events',
    'tempdb': DOC+'sql/relational-databases/databases/tempdb-database',
    'versions': DOC+'troubleshoot/sql/releases/download-and-install-latest-updates',
}


def integer(value):
    try:
        if value is None or isinstance(value, bool):
            return None
        return int(value) if str(value).strip() == str(int(value)) else None
    except (ValueError, TypeError, OverflowError):
        return None


def identifier(value: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 128 or any(ord(c) < 32 for c in value):
        raise ValueError('Invalid SQL identifier')
    return '[' + value.replace(']', ']]') + ']'


def literal(value: str) -> str:
    identifier(value)  # Same input constraints; quote identifiers and values separately.
    return "N'" + value.replace("'", "''") + "'"


def recommend(manifest: dict, records: list[dict]) -> dict:
    by_source = defaultdict(list)
    for n, record in enumerate(records, 1):
        by_source[record.get('source')].append((record.get('_line', n), record))

    def data(source):
        # A partial/error snapshot must never certify absence or a current value.
        seq = by_source[source]
        if not seq or any(r.get('status') != 'ok' for _, r in seq):
            return []
        return [(row, {'source': source, 'line': line, 'time': r.get('collected_utc')})
                for line, r in seq for row in r.get('rows', []) if isinstance(row, dict)]

    def complete(source):
        return bool(by_source[source]) and all(r.get('status') == 'ok' for _, r in by_source[source])

    findings = []
    def add(rule, scope, current, proposed, status, reason, risk, evidence, source, apply=None, rollback=None):
        findings.append(dict(rule_id=rule, scope=scope, current=current, proposed=proposed,
                             status=status, reason=reason, risk=risk, evidence=evidence,
                             reference=SOURCES[source], sql=apply, rollback_sql=rollback,
                             verify='Повторить тот же сценарий и сбор; проверить ошибки, длительность, CPU, I/O и блокировки.'))

    configs = {r.get('name'): (r, e) for r, e in data('sql.configurations')}
    for name, (r, e) in configs.items():
        v = integer(r.get('running_value'))
        if v is None:
            continue
        if name == 'max worker threads':
            add('workers', 'Экземпляр', v, 0 if v else 0, 'review' if v else 'keep',
                'Автовыбор 0 подходит большинству систем. Перед возвратом выяснить причину ручного значения; это не диагноз торможения.',
                'Проверить THREADPOOL, активные workers, блокировки и специальную нагрузку. Не повышать/понижать вслепую.', [e], 'workers')
        elif name in ('backup checksum default', 'backup compression default'):
            is_check = name == 'backup checksum default'
            add('backup_checksum' if is_check else 'backup_compression', 'Экземпляр', v, 1,
                'review' if v != 1 else 'keep',
                name+': рекомендуется явно задавать '+('CHECKSUM' if is_check else 'COMPRESSION')+' в новых backup jobs; изменение server default отдельно.',
                'Добавляет CPU/чтение для проверки; учесть существующее ПО резервного копирования. Default=0 не доказывает отсутствие опции в командах.',
                [e], 'checksum' if is_check else 'compression')
        elif name == 'max server memory (MB)':
            unlimited = v >= 2147483647
            add('memory', 'Экземпляр', v, 'Рассчитать бюджет SQL + ОС + 1С' if unlimited else v,
                'review' if unlimited else 'keep',
                'Нельзя назначать SQL 80–90% RAM на совместном сервере 1С. Конечный лимит пока оставить; нужен длительный замер пиков и учёт всех процессов.',
                'Один короткий замер не определяет оптимальный лимит. Слишком малый лимит тоже ухудшает работу.', [e], 'memory')
        elif name in ('max degree of parallelism', 'cost threshold for parallelism'):
            add('maxdop' if name.startswith('max degree') else 'cost_threshold', 'Экземпляр', v, v, 'keep',
                name+': сохранить до сравнения плана и времени проблемного запроса. MAXDOP 1 можно сравнить с текущим значением в контролируемом тесте.',
                'CXPACKET/CXCONSUMER сами по себе не обосновывают изменение всех баз. Учитывать NUMA и рекомендации для конкретной версии 1С.', [e], 'parallelism')
    if not configs:
        add('config_unknown', 'Экземпляр', 'Нет полного источника', 'Повторить сбор SQL', 'unknown',
            'Настройки не прочитаны или выборка неполна.', 'Не формировать SQL исправлений без исходных значений.', [], 'memory')

    # Audit only the selected and observed active databases. Never infer every DB is a 1C DB.
    selected = manifest.get('selected_database')
    names = defaultdict(set)
    dbrows = {}
    for r, e in data('sql.databases'):
        names[r.get('database_id')].add(r.get('name'))
        dbrows[r.get('database_id')] = (r, e)
    dbnames = {k: next(iter(v)) for k, v in names.items() if isinstance(k,int) and not isinstance(k,bool) and k>0 and len(v) == 1 and isinstance(next(iter(v)), str)}
    active = {r.get('database_id') for r, _ in data('sql.requests')}
    scope_ids = {k for k, name in dbnames.items() if name == selected or k in active}
    for dbid in sorted(scope_ids):
        r, e = dbrows[dbid]
        name = dbnames[dbid]
        for field, expected, option in [('is_auto_close_on', False, 'AUTO_CLOSE'),
                                       ('is_auto_shrink_on', False, 'AUTO_SHRINK'),
                                       ('is_auto_create_stats_on', True, 'AUTO_CREATE_STATISTICS'),
                                       ('is_auto_update_stats_on', True, 'AUTO_UPDATE_STATISTICS')]:
            if r.get(field) not in (True, False, 0, 1) or r.get(field) is None:
                continue
            current = 'ON' if r[field] else 'OFF'
            target = 'ON' if expected else 'OFF'
            add('db_'+option.lower(), name, current, target, 'keep' if current == target else 'change',
                option+': базовый профиль проверки для выбранных/активных баз.',
                'Изменения согласовать с DBA; для статистик проверить намеренные исключения и планы.', [e], 'database')
        add('recovery', name, r.get('recovery_model_desc'), r.get('recovery_model_desc'), 'review',
            'Модель восстановления выбирается по допустимой потере данных. SIMPLE не позволяет point-in-time восстановление по LOG backups.',
            'Не переключать автоматически. Для FULL нужны исходная полная копия и регулярные LOG backups; согласовать RPO/RTO.', [e], 'backup')
        add('page_verify', name, r.get('page_verify_option_desc'), 'CHECKSUM',
            'keep' if r.get('page_verify_option_desc') == 'CHECKSUM' else 'review',
            'PAGE_VERIFY CHECKSUM помогает обнаруживать повреждения при чтении страниц.',
            'Включение не проверяет ранее записанные страницы и не заменяет CHECKDB/backup.', [e], 'database')
        checked = r.get('last_good_checkdb_sql_local')
        if str(checked).startswith(('1900-', '0001-')): checked = None
        add('integrity', name, checked or 'Нет сведений о последнем CHECKDB', 'Регулярный CHECKDB и контроль результата',
            'review' if checked else 'unknown',
            'Отметка LastGoodCheckDbTime — дополнительное свидетельство; по ней нельзя доказать полноту проверки или проверить внешний restore-test.',
            'CHECKDB создаёт нагрузку и внутренний snapshot; никакого REPAIR_ALLOW_DATA_LOSS.', [e], 'checkdb')

    for r, e in data('sql.files'):
        if r.get('database_id') not in scope_ids or r.get('state_desc') != 'ONLINE':
            continue
        growth = integer(r.get('growth')); size = integer(r.get('allocated_bytes'))
        percent = r.get('is_percent_growth')
        if growth is None or size is None or growth <= 0 or percent not in (True, False):
            continue
        kind = r.get('type_desc')
        if kind not in ('ROWS', 'LOG'):
            continue
        mb = growth / 128
        if not percent and mb >= 64:
            continue
        target = 256 if kind == 'ROWS' else 128
        db, file = dbnames[r['database_id']], r.get('name')
        current = str(growth)+'%' if percent else f'{mb:g} МиБ'
        sql = back = None
        try:
            prefix = f'ALTER DATABASE {identifier(db)} MODIFY FILE (NAME = {literal(file)}, FILEGROWTH = '
            sql = prefix+f'{target}MB);'
            back = prefix+(str(growth)+'%' if percent else f'{growth*8}KB')+');'
        except ValueError:
            pass
        add('file_growth', db+' / '+str(file), current, f'{target} МиБ', 'review',
            'Предлагаемый стартовый шаг, не универсальный норматив. Выделить место заранее; не полагаться только на autogrow.',
            f'Файл {size/1024**3:.2f} ГиБ. Проверить свободное место, MAXSIZE, историю роста и VLF; большой рост журнала может приостанавливать транзакции. Не выполнять SHRINK.',
            [e], 'growth', sql, back)

    tmp = [r for r, _ in data('sql.files') if r.get('database_id') == 2 and r.get('type_desc') == 'ROWS']
    if tmp:
        equal = len({(r.get('allocated_bytes'), r.get('growth'), r.get('is_percent_growth')) for r in tmp}) == 1
        add('tempdb', 'tempdb', f'{len(tmp)} файлов данных; одинаковые размер/рост: {equal}',
            'Сохранить' if equal else 'Согласовать одинаковые размеры и рост', 'keep' if equal else 'review',
            'Количество файлов не равно количеству всех vCPU автоматически; проверять contention в tempdb и свободное место.',
            'Не добавлять файлы только из-за CXPACKET. Равные файлы не доказывают отсутствие bottleneck.',
            [e for _, e in data('sql.files')][:1], 'tempdb')

    jobs = []
    history = defaultdict(list)
    for r, _ in data('sql.job_history'):
        history[r.get('job_name')].append(r)
    for r, e in data('sql.jobs'):
        last = max(history[r.get('name')], key=lambda x: (x.get('run_date',0), x.get('run_time',0)), default={})
        jobs.append(dict(name=r.get('name'), enabled=r.get('enabled'), category=r.get('category'),
            last_run_date=r.get('last_run_date') or last.get('run_date'),
            last_run_status=r.get('last_run_status') if r.get('last_run_status') is not None else last.get('run_status'),
            active_schedule_count=r.get('active_schedule_count'),
            schedules=r.get('schedules_json'), steps=r.get('steps_json'),
            maintenance_plan=r.get('maintenance_plan_name'), evidence=e))
    for job in jobs:
        if job['enabled'] == 1 and job['active_schedule_count'] == 0:
            add('job_schedule', job['name'], 'Включено, активных расписаний 0', 'Проверить назначение и добавить расписание для регулярного задания', 'review',
                'Задание может запускаться вручную или внешней системой. Нулевое расписание не доказывает отсутствие запусков.',
                'Не включать неизвестное обслуживание по одному имени.', [job['evidence']], 'jobs')
        if job['last_run_status'] == 0:
            add('job_failure', job['name'], 'Последний сохранённый запуск завершился ошибкой', 'Разобрать Job History и восстановить выполнение', 'review',
                'Ошибка касается последнего сохранённого выполнения, не текущего состояния базы.',
                'Сначала причина ошибки, затем контролируемый повтор.', [job['evidence']], 'jobs')
    expanded = complete('sql.jobs') and all('active_schedule_count' in r and (integer(r.get('step_count')) or 0)<=50 and (integer(r.get('schedule_count')) or 0)<=50 for r, _ in data('sql.jobs'))
    add('maintenance_coverage', 'Экземпляр', f'Видимых заданий: {len(jobs)}' if complete('sql.jobs') else 'Нет полной выборки заданий',
        'Проверить расписания, операции, охват баз и успешные выполнения', 'review' if expanded else 'unknown',
        'Наличие SSIS-плана не обязательно: T-SQL jobs и внешние системы тоже могут обслуживать базы. Совпадение слова в шаге — только подсказка.',
        'Сначала исключить дублирование существующего обслуживания; неполная история не доказывает его отсутствие.',
        [e for _, e in data('sql.jobs')][:1], 'jobs')
    backuprows = data('sql.backups')
    complete_backups = complete('sql.backups') and bool(manifest.get('include_maintenance'))
    backup_scope = selected or 'Все видимые базы (ограниченная выборка)'
    add('backup_coverage', backup_scope,
        f'Записей за 14 дней: {len(backuprows)}' if complete_backups else 'Источник не собран/неполон',
        'Подтвердить полные/разностные/LOG копии и тест восстановления',
        'review' if complete_backups else 'unknown',
        'Выборка ограничена 14 днями и выбранной базой; отсутствие записей не исключает внешние копии и удалённую историю msdb.',
        'VERIFYONLY не заменяет восстановление. Для SIMPLE LOG backup не создаётся; хранение вне исходного сервера обязательно рассмотреть.',
        [e for _, e in backuprows][:1], 'backup')
    add('stats_indexes', ', '.join(dbnames[k] for k in sorted(scope_ids)) or 'Базы не определены',
        'Актуальность статистик и необходимость index maintenance не измерены',
        'Ночью обновлять изменённые статистики; индексы обслуживать адресно по измерениям', 'unknown',
        'Не назначать nightly REBUILD ALL + FULLSCAN ALL. REORGANIZE не обновляет статистики; REBUILD не обновляет все column statistics.',
        'Обслуживание потребляет CPU/I/O/tempdb/log и может блокировать пользователей; массовая индексация в стандартный пакет не входит.', [], 'indexes')
    add('version_review', 'Экземпляр', next((r.get('product_version') for r,_ in data('sql.instance')), 'Не определена'),
        'Сверить текущую сборку с актуальными обновлениями Microsoft', 'review',
        'Офлайн-отчёт не содержит выдуманного latest-CU и не скачивает данные сервера в интернет.',
        'Обновление отдельно: резервная копия, проверка совместимости, тест и окно работ.',
        [e for _, e in data('sql.instance')], 'versions')
    return dict(ruleset_version=RULESET_VERSION, findings=findings, jobs=jobs, known_database_count=len(dbnames),
                selected_database=selected, database_scope=[dbnames[k] for k in sorted(scope_ids)],
                expanded_jobs_collected=expanded,
                note='Рекомендации не применены. review — проверить условия; change — обоснованная базовая корректировка; keep — пока оставить, не сертификат исправности; unknown — данных не хватает.')


def render_recommendations(result: dict) -> str:
    blocks=['<section id="recommendations"><h2>Настройки и обслуживание: сейчас → рекомендуется</h2><p>'+escape(result['note'])+'</p>']
    statuses={'review':'Проверить перед изменением','change':'Предлагается изменить','keep':'Пока оставить','unknown':'Не хватает данных'}
    for item in result['findings']:
        ev='; '.join(f"{x['source']} / records.jsonl:{x['line']} / {x.get('time')}" for x in item['evidence']) or 'Источник не собран'
        blocks.append('<details'+(' open' if item['status'] != 'keep' else '')+'><summary><b>'+escape(item['scope'])+'</b> · '+escape(item['rule_id'])+' · '+escape(statuses[item['status']])+'</summary><p><b>Сейчас:</b> '+escape(str(item['current']))+'<br><b>Предлагается:</b> '+escape(str(item['proposed']))+'</p><p>'+escape(item['reason'])+'</p><p><b>Условия и риск:</b> '+escape(item['risk'])+'</p><p><small>'+escape(ev)+'</small></p>')
        if item['sql']:
            blocks.append('<p>Команда для ручного согласования (не выполнена):</p><pre>'+escape(item['sql'])+'</pre><p>Возврат настройки роста (не уменьшает файл):</p><pre>'+escape(item['rollback_sql'])+'</pre>')
        blocks.append('<p><a href="'+escape(item['reference'],quote=True)+'">Основание / документация</a></p></details>')
    blocks.append('<h3>Задания SQL Agent</h3><p>Коды результата: 0 — ошибка; 1 — успех; 3 — отмена. Нет значения — неизвестно. Дата в формате YYYYMMDD, время SQL Server.</p><table><tr><th>Задание</th><th>Включено</th><th>Последняя дата</th><th>Результат</th><th>Активных расписаний</th></tr>')
    for job in result['jobs']:
        blocks.append('<tr>'+''.join('<td>'+escape(str(job.get(k)) if job.get(k) is not None else 'Нет данных')+'</td>' for k in ['name','enabled','last_run_date','last_run_status','active_schedule_count'])+'</tr>')
    blocks.append('</table><details><summary>Метаданные расписаний и шагов (без команд)</summary><pre>'+escape(json.dumps(result['jobs'],ensure_ascii=False,indent=2))+'</pre></details></section>')
    return ''.join(blocks)
