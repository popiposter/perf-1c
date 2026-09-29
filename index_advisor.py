"""Pure, evidence-linked index/statistics advice. No SQL execution or universal health verdict."""
from __future__ import annotations
from collections import Counter
from html import escape
import json
import math
from typing import Any

VERSION = '0.1.0-pilot'
DOC_INDEX = 'https://learn.microsoft.com/en-us/sql/relational-databases/indexes/reorganize-and-rebuild-indexes'
DOC_PHYSICAL = 'https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-index-physical-stats-transact-sql'
DOC_STATS = 'https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-objects/sys-dm-db-stats-properties-transact-sql'


def finite(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def positive_int(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value > 0


def quote_name(value: str) -> str:
    if not isinstance(value, str) or not value or len(value) > 128 or any(ord(c) < 32 for c in value):
        raise ValueError('Invalid SQL identifier')
    return '[' + value.replace(']', ']]') + ']'


def object_sql(row: dict) -> tuple[str, str]:
    return quote_name(row['database_name']), quote_name(row['schema_name']) + '.' + quote_name(row['table_name'])


def recommend_indexes(manifest: dict, records: list[dict], *, reorganize_percent: int = 5,
                      rebuild_percent: int = 30, min_pages: int = 1000,
                      stats_min_changes: int = 500, stats_change_percent: int = 20) -> dict:
    for value in (reorganize_percent, rebuild_percent, min_pages, stats_min_changes, stats_change_percent):
        if not isinstance(value, int) or isinstance(value, bool):
            raise ValueError('Policy values must be integers')
    if not 0 <= reorganize_percent < rebuild_percent <= 100 or min_pages < 0 or stats_min_changes < 1 or not 1 <= stats_change_percent <= 100:
        raise ValueError('Invalid index/statistics policy')
    policy = dict(reorganize_percent=reorganize_percent, rebuild_percent=rebuild_percent,
                  min_pages=min_pages, stats_min_changes=stats_min_changes, stats_change_percent=stats_change_percent)
    coverage: dict[str, Counter] = {}
    findings: list[dict] = []
    indexes, statistics, heaps, history, audit_summary = [], [], [], [], []
    relevant = {'sql.index_health', 'sql.statistics_health', 'sql.heap_health', 'sql.index_inventory',
                'sql.index_audit_preflight', 'sql.index_audit_summary', 'sql.index_maintenance_history'}
    selected = manifest.get('selected_database')

    def add(rule, scope, current, proposed, status, reason, risk, evidence, reference, sql=None):
        findings.append(dict(rule_id=rule, scope=scope, current=current, proposed=proposed, status=status,
                             reason=reason, risk=risk, evidence=[evidence] if evidence else [],
                             reference=reference, sql=sql, rollback_sql=None,
                             verify='Сравнить ту же операцию до/после: время, чтения, CPU, блокировки; проверить журнал обслуживания.'))

    # Only one-shot audit sources are expected. Repeated physical rows are not summed.
    seen = set()
    for number, record in enumerate(records, 1):
        source = record.get('source')
        if source not in relevant:
            continue
        state = record.get('status', 'unknown')
        coverage.setdefault(source, Counter())[state] += 1
        ev = {'source': source, 'line': record.get('_line', number), 'time': record.get('collected_utc')}
        if state not in ('ok', 'truncated'):
            add('index_source_incomplete', source, state, 'Повторить адресный сбор', 'unknown',
                record.get('error') or 'Источник не прочитан.', 'Пропуск не означает отсутствие проблемы.', ev, DOC_PHYSICAL)
            continue
        if state == 'truncated':
            add('index_source_truncated', source, record.get('row_count'), 'Уточнить область/лимит и повторить сбор', 'unknown',
                'Рекомендации ниже относятся только к сохранённой части выборки.',
                'Не увеличивать объём физического сканирования на загруженном сервере без оценки воздействия.', ev, DOC_PHYSICAL)
        for raw in record.get('rows', []):
            if not isinstance(raw, dict):
                continue
            row = dict(raw)
            row['evidence'] = ev
            if source == 'sql.index_audit_summary':
                audit_summary.append(row)
                continue
            if source == 'sql.index_maintenance_history':
                history.append(row)
                continue
            if source not in ('sql.index_health', 'sql.statistics_health', 'sql.heap_health'):
                continue
            if selected and row.get('database_name') != selected:
                add('index_scope_mismatch', source, row.get('database_name'), 'Проверить принадлежность данных базе', 'unknown',
                    'Имя базы источника не совпадает с выбранной базой.', 'SQL исправлений не формируется.', ev, DOC_PHYSICAL)
                continue
            try:
                db, table = object_sql(row)
                scope = f'{db}.{table}'
            except (ValueError, KeyError, TypeError):
                add('index_identity_unknown', source, 'Некорректное имя объекта', 'Повторить сбор', 'unknown',
                    'Недостаточно валидных идентификаторов для SQL-команды.', 'Не угадывать имя таблицы 1С.', ev, DOC_PHYSICAL)
                continue
            if source == 'sql.heap_health':
                heaps.append(row)
                add('large_heap_review', scope, row.get('used_page_count'), 'Проверить модель и операции с heap', 'review',
                    'Таблица без clustered index найдена по метаданным; наличие heap само по себе допустимо.',
                    'Не создавать clustered index напрямую в базе 1С. Нужна проверка метаданных конфигурации и конкретной нагрузки.', ev, DOC_INDEX)
                continue
            if source == 'sql.index_health':
                identity = tuple(row.get(k) for k in ('database_id', 'object_id', 'index_id', 'partition_number'))
                if identity in seen:
                    add('index_duplicate_measurement', scope, identity, 'Проверить повторные измерения', 'unknown',
                        'Повторное физическое измерение не суммируется и не заменяет предыдущее автоматически.',
                        'Сравнить время и идентичность объектов.', ev, DOC_PHYSICAL)
                    continue
                seen.add(identity)
                valid = (all(positive_int(row.get(k)) for k in ('database_id', 'object_id', 'index_id', 'partition_number', 'partition_count'))
                         and row.get('partition_number') <= row.get('partition_count')
                         and row.get('index_type') in (1, 2) and not isinstance(row.get('index_type'), bool)
                         and row.get('is_disabled') in (False, 0) and row.get('is_hypothetical') in (False, 0)
                         and row.get('index_level') == 0 and row.get('alloc_unit_type_desc') == 'IN_ROW_DATA'
                         and row.get('scan_mode') in ('LIMITED', 'SAMPLED'))
                frag, pages = row.get('avg_fragmentation_in_percent'), row.get('page_count')
                if not valid or not finite(frag) or not 0 <= frag <= 100 or not finite(pages) or pages < 0:
                    row['proposed'] = 'Нет надёжных данных'; row['status'] = 'unknown'; indexes.append(row)
                    add('index_measurement_unknown', scope, {'fragmentation': frag, 'pages': pages}, row['proposed'], 'unknown',
                        'Нужны поддерживаемый rowstore leaf, валидные идентификаторы и конечные числовые показатели.',
                        'Нельзя назначать обслуживание по отсутствующим/неподдерживаемым данным.', ev, DOC_PHYSICAL)
                    continue
                try:
                    index = quote_name(row['index_name'])
                except (ValueError, KeyError, TypeError):
                    add('index_identity_unknown', scope, 'Нет имени индекса', 'Повторить сбор', 'unknown',
                        'SQL-команда не формируется.', 'Не угадывать идентификаторы.', ev, DOC_PHYSICAL)
                    continue
                # LIMITED explicitly cannot measure page density; a synthetic non-null value is not accepted.
                density = row.get('avg_page_space_used_in_percent') if row['scan_mode'] == 'SAMPLED' else None
                row['page_density_percent'] = density if finite(density) and 0 <= density <= 100 else None
                part = f" PARTITION = {row['partition_number']}" if row['partition_count'] > 1 else ''
                prefix = f'USE {db};\nALTER INDEX {index} ON {table} '
                sql = None
                if pages < min_pages or frag < reorganize_percent:
                    proposed, status = 'Не обслуживать по выбранному порогу', 'keep'
                    reason = 'Не достигнуты выбранные пороги размера/фрагментации; это не оценка всех причин медленной работы.'
                elif frag >= rebuild_percent:
                    proposed, status = 'Кандидат REBUILD — после согласования окна', 'review'
                    reason = 'Достигнут порог-кандидат, не доказан выигрыш. На Standard учитывается блокирующий offline rebuild.'
                    sql = prefix + f'REBUILD{part} WITH (ONLINE = OFF, MAXDOP = 2);'
                elif row.get('allow_page_locks') not in (True, 1):
                    proposed, status = 'Проверить ALLOW_PAGE_LOCKS; автоматически не менять', 'review'
                    reason = 'REORGANIZE нельзя выполнять при ALLOW_PAGE_LOCKS=OFF или неизвестном значении.'
                else:
                    proposed, status = 'Кандидат REORGANIZE', 'review'
                    reason = 'Достигнут порог-кандидат; проверить пользу для диапазонных чтений и стоимость обслуживания.'
                    sql = prefix + f'REORGANIZE{part} WITH (LOB_COMPACTION = OFF);'
                row.update(proposed=proposed, status=status, suggested_sql=sql)
                indexes.append(row)
                add('index_maintenance_candidate', scope + '.' + index + f" / partition {row['partition_number']}",
                    {'fragmentation_percent': frag, 'pages': pages, 'page_density_percent': row['page_density_percent']},
                    proposed, status, reason,
                    'Пороги 5/30% и 1000 страниц — настраиваемая эвристика. Нужны свободное место, журнал и окно; '
                    'команда не выполняется. REBUILD не имеет простой обратной команды, статистика/планы могут измениться.', ev, DOC_INDEX, sql)
                continue
            # Statistics: last_updated alone is NEVER a staleness verdict.
            try:
                name = quote_name(row['statistics_name'])
            except (ValueError, KeyError, TypeError):
                add('statistics_identity_unknown', scope, 'Нет имени статистики', 'Повторить сбор', 'unknown',
                    'SQL-команда не формируется.', 'Не угадывать идентификаторы.', ev, DOC_STATS)
                continue
            available = row.get('properties_available') in (True, 1)
            mods, count = row.get('modification_counter'), row.get('unfiltered_rows')
            if count is None:
                count = row.get('rows_at_update')
            ratio = 100.0 * mods / count if finite(mods) and mods >= 0 and finite(count) and count > 0 else None
            row['modified_percent_estimate'] = ratio
            sql = None
            if not available or not finite(mods) or mods < 0 or not finite(count) or count < 0:
                proposed, status = 'Уточнить доступность свойств статистики', 'unknown'
                reason = 'Свойства не получены или непригодны. Пустой результат функции может означать недостаточные права.'
            elif row.get('no_recompute') in (True, 1):
                proposed, status = 'Проверить намеренное NORECOMPUTE', 'review'
                reason = 'Автообновление отключено для объекта статистики. Не сбрасывать политику автоматически.'
            elif row.get('last_updated_sql_local') is None:
                proposed, status = 'Проверить пустую/новую или фильтрованную статистику', 'unknown'
                reason = 'NULL даты допустим для пустой/новой статистики; это не дата последней дефрагментации.'
            elif ratio is not None and mods >= stats_min_changes and ratio >= stats_change_percent:
                proposed, status = 'Кандидат адресного UPDATE STATISTICS', 'review'
                reason = 'Есть существенные изменения ведущего столбца. Порог проекта не повторяет алгоритм автоматического обновления SQL.'
                if not row.get('is_incremental') and row.get('no_recompute') in (False, 0):
                    sql = f'USE {db};\nUPDATE STATISTICS {table} {name};'
                else:
                    reason += ' Инкрементальную статистику и её секции разбирать отдельно.'
            else:
                proposed, status = 'Пока не обновлять только из-за возраста', 'keep'
                reason = 'Возраст и доля выборки сами по себе не доказывают плохую статистику; сравнить оценки и фактические строки запроса.'
            row.update(proposed=proposed, status=status, suggested_sql=sql)
            statistics.append(row)
            add('statistics_maintenance_candidate', scope + '.' + name,
                {'last_updated_sql_local': row.get('last_updated_sql_local'), 'modification_counter': mods,
                 'rows_sampled': row.get('rows_sampled'), 'modified_percent_estimate': ratio},
                proposed, status, reason,
                'UPDATE STATISTICS может изменить планы. REORGANIZE статистику не обновляет; обычный REBUILD обновляет '
                'статистику самого индекса, но не все отдельные статистики столбцов. Нет безусловного FULLSCAN ALL.', ev, DOC_STATS, sql)

    if 'sql.index_inventory' not in coverage and 'sql.index_health' not in coverage:
        add('index_audit_missing', selected or 'Выбранная база', 'Физическое состояние не измерено',
            'Выполнить Start-OneCPerf.ps1 -IndexAudit с явной базой', 'unknown',
            'Обычный минутный срез не содержит аудита индексов.', 'Не объявлять отсутствие дефрагментации без измерений.', None, DOC_PHYSICAL)
    if 'sql.statistics_health' not in coverage:
        add('statistics_audit_missing', selected or 'Выбранная база', 'Свойства статистик не собраны',
            'Выполнить адресный аудит статистик', 'unknown', 'Нет данных о модификациях и выборке.',
            'Дата последнего CHECKDB/backup не заменяет данные о статистике.', None, DOC_STATS)
    return dict(version=VERSION, policy=policy, selected_database=selected,
                coverage={k: dict(v) for k, v in coverage.items()}, audit_summary=audit_summary,
                indexes=indexes, statistics=statistics, large_heaps=heaps, history=history, findings=findings,
                limitations=[
                    'Это кандидаты на проверку, не установленная причина торможения и не команды автоматического исправления.',
                    'LIMITED не измеряет плотность страниц; SAMPLED включается только для явного object_id и тоже создаёт I/O/блокировки.',
                    'Малые, неподдерживаемые и не попавшие в лимит объекты не признаются исправными. Нет аудита columnstore/XML/spatial/memory-optimized.',
                    'Сбор сортирует кандидатов по размеру, не по ещё неизвестной фрагментации; метаданные статистик — по object_id/stats_id.',
                    'Дата last_updated относится к статистике. История дефрагментации доступна только при наличии собственного журнала; внешнее обслуживание неизвестно.',
                    'Физические SQL-имена не преобразуются в имена объектов 1С без карты метаданных.',
                ])


def _table(rows: list[dict], columns: list[tuple[str, str]], limit: int = 100) -> str:
    if not rows:
        return '<p>Нет пригодных строк; это не заключение об отсутствии проблемы.</p>'
    def fmt(v):
        if v is None:
            return 'Не измерено / неизвестно'
        return str(round(v, 3)) if isinstance(v, float) and math.isfinite(v) else str(v)
    header = '<tr>' + ''.join('<th>' + escape(label) + '</th>' for _, label in columns) + '</tr>'
    body = ''.join('<tr>' + ''.join('<td>' + escape(fmt(row.get(k))) + '</td>' for k, _ in columns) + '</tr>' for row in rows[:limit])
    return f'<div class="scroll"><table>{header}{body}</table></div><p>Показано {min(len(rows), limit)} из {len(rows)}. Полные строки — summary.json.</p>'


def render_index_advice(result: dict) -> str:
    blocks = ['<section id="index-advisor"><h2>Индексы и статистики: что проверить и обслужить</h2>',
              '<p>Рекомендации не выполнены. Пороговая политика проекта: <code>' + escape(json.dumps(result['policy'], ensure_ascii=False)) + '</code>.</p>']
    if result['audit_summary']:
        blocks.append(_table(result['audit_summary'], [('completion', 'Полнота'), ('candidate_partitions', 'Кандидатов-секций'),
            ('attempted_partitions', 'Проверено попыток'), ('measured_partitions', 'Измерено'), ('budget_hit', 'Достигнут бюджет')]))
    blocks.append(_table(result['indexes'], [('table_name', 'Таблица SQL'), ('index_name', 'Индекс'), ('partition_number', 'Секция'),
        ('page_count', 'Страниц'), ('avg_fragmentation_in_percent', 'Фрагментация, %'),
        ('page_density_percent', 'Плотность, %'), ('proposed', 'Рекомендация')]))
    blocks.append('<h3>Статистики</h3>' + _table(result['statistics'], [('table_name', 'Таблица'), ('statistics_name', 'Статистика'),
        ('last_updated_sql_local', 'Обновлено (SQL local)'), ('modification_counter', 'Изменений'),
        ('rows_sampled', 'Строк выборки'), ('modified_percent_estimate', 'Изменения, оценка %'), ('proposed', 'Рекомендация')]))
    blocks.append('<h3>Крупные heaps — не автоматический дефект</h3>' + _table(result['large_heaps'], [('table_name', 'Таблица'), ('used_page_count', 'Страниц'), ('row_count', 'Строк')]))
    blocks.append('<h3>Рекомендации и доказательства</h3>')
    # Rendering is bounded; ALL findings are retained in JSON, including valid rows from truncated sources.
    ordered = sorted(result['findings'], key=lambda x: {'unknown': 0, 'review': 1, 'keep': 2}.get(x['status'], 3))
    for item in ordered[:200]:
        blocks.append('<details><summary>' + escape(item['scope'] + ' · ' + item['proposed']) + '</summary><p>' + escape(item['reason']) +
                      '</p><p><b>Риск и условия:</b> ' + escape(item['risk']) + '</p><pre>' +
                      escape(json.dumps(item['evidence'], ensure_ascii=False)) + '</pre>')
        if item['sql']:
            blocks.append('<p><b>Только образец для ручного согласования, НЕ выполнен:</b></p><pre>' + escape(item['sql']) +
                          '</pre><p>Простой обратной команды для физического обслуживания нет. Не включать без оценки блокировок и места.</p>')
        blocks.append('<p><a href="' + escape(item['reference'], quote=True) + '">Документация</a></p></details>')
    blocks.append(f'<p>Показано {min(200, len(ordered))} из {len(ordered)} рекомендаций; остальные сохранены в JSON.</p>')
    blocks.append('<h3>Журнал заданий perf-1c (не история всех средств обслуживания)</h3>' + _table(result['history'],
        [('database_name', 'База'), ('table_name', 'Таблица'), ('index_name', 'Индекс'), ('action', 'Действие'),
         ('outcome', 'Результат'), ('started_utc', 'Начало UTC'), ('ended_utc', 'Конец UTC'), ('message', 'Подробности'), ('note', 'Доступность')]))
    blocks.extend('<p>' + escape(text) + '</p>' for text in result['limitations'])
    return ''.join(blocks) + '</section>'


def render_index_document(result: dict, manifest: dict) -> str:
    title = '1С + SQL Server · аудит индексов и статистик'
    return ('<!doctype html><html lang="ru"><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
            '<title>' + title + '</title><style>body{font:15px/1.5 system-ui,sans-serif;max-width:1380px;margin:28px auto;padding:0 24px}'
            'table{border-collapse:collapse;width:100%;font-size:13px}td,th{padding:8px;text-align:left;border:1px solid #ccc;overflow-wrap:anywhere}'
            '.scroll{overflow:auto}pre{white-space:pre-wrap;overflow-wrap:anywhere}details{margin:10px 0}summary{cursor:pointer}</style><body><h1>' + title +
            '</h1><p>' + escape(str(manifest.get('host')) + ' / ' + str(manifest.get('selected_database')) + ' / ' + str(manifest.get('started_utc'))) +
            '</p><p><b>Конфиденциально. Отчёт без автоматического исправления. Неполный охват — не отсутствие проблемы.</b></p>' +
            render_index_advice(result) + '</body></html>')
