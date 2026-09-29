# perf-1c

Локальная диагностика производительности **1С + Microsoft SQL Server**.
Измерения → гипотезы → рекомендации с доказательствами → отдельное согласованное изменение.

**Анализатор 0.4.0-pilot; основной сборщик 0.1.3-pilot.** Добавлены отдельный ограниченный
аудит индексов/статистик и генератор условного обслуживания индексов. Это не автоматический
оптимизатор: на сервере ничего не исправляется по факту скачивания или диагностики.
Новые PowerShell/SQL пути ещё требуют испытаний на Windows/SQL Server.

## Одна команда: обычный срез в PS7 x64 на Windows

```powershell
& { $s=Join-Path $env:TEMP ('perf-1c-'+[guid]::NewGuid()+'.ps1'); Invoke-WebRequest 'https://raw.githubusercontent.com/popiposter/perf-1c/main/Start-OneCPerf.ps1' -OutFile $s -ErrorAction Stop; & $s -Minutes 1 -IncludeMaintenance }
```

Экземпляр и SQL-база запрашиваются интерактивно. Enter для экземпляра — `.`, для базы —
без деталей выбранной базы. Windows-аутентификация текущего пользователя; SqlCredential
передаётся как PSCredential. Основной замер — Minutes 10 во время проблемы. Для отдельного
узла 1С — SkipSql и Role onec. Для запуска без вопросов задайте SqlInstance, Database и NonInteractive.

Код: `%LOCALAPPDATA%\perf-1c\downloads`; данные: `%LOCALAPPDATA%\perf-1c\captures`.
Git, Python и SqlServer module на сервере не нужны. `completed` в обычном срезе означает
окончание таймера, не полноту измерений. Проверяйте coverage.html и ошибки.
Метрики Windows относятся только к узлу запуска; SQL может быть удалённым.

Загрузчик разрешает main в commit SHA и скачивает новый каталог без использования старого
кода после ошибки. Для фиксации версии замените main в URL и Ref одним SHA. DownloadOnly
скачивает код без сбора. HTTPS, ExecutionPolicy, права и службы не изменяются автоматически.
`-TrustServerCertificate` — только явное решение для проверенного SQL-узла: шифрование
остаётся, проверка подлинности сертификатом пропускается. [Подключение SQL](docs/sql-connection.md).
[Полная инструкция исходного среза](README_RU.md).

## Одна команда: аудит индексов и статистик

```powershell
& { $s=Join-Path $env:TEMP ('perf-1c-'+[guid]::NewGuid()+'.ps1'); Invoke-WebRequest 'https://raw.githubusercontent.com/popiposter/perf-1c/main/Start-OneCPerf.ps1' -OutFile $s -ErrorAction Stop; & $s -IndexAudit -SqlInstance 'SQL_HOST' -Database 'DB_NAME' -NonInteractive }
```

SQL_HOST/DB_NAME — примеры. Это отдельный профиль: не совмещать с Minutes, IncludeMaintenance
или SkipSql. Никаких ALTER INDEX или UPDATE STATISTICS. По умолчанию до **30 крупнейших
подходящих секций**, **1000 статистик**, режим **LIMITED**, мягкий бюджет **60 секунд**,
таймаут запроса **3 секунды**. Не полный аудит всей базы. Даже read-only physical_stats
создаёт I/O и берёт блокировки; первый запуск проводить в тихий период.

Лимиты, фактический охват, ошибки и недоступные свойства сохраняются в отдельном index_*.zip.
Плотность страниц в LIMITED не измеряется. SAMPLED — только с явным IndexAuditObjectId.
Полная логика, права и исключения: **[Индексы и статистики](docs/index-maintenance.md)**.

## Единый анализатор

На рабочем месте администратора, Python 3.10+, стандартная библиотека:

```powershell
python analyze.py PATH_TO_CAPTURE.zip --output analysis-output
```

Создаёт report.html, summary.json и recommendations.json. Обычный срез сохраняет разделы
ресурсов/запросов/настроек; index-аудит получает свой профиль без ложных требований к CPU-снимкам.
В новом разделе: физические имена объектов, секции, страницы, фрагментация, доступная плотность,
изменения статистик, рекомендации, SQL для ручного согласования, риски и строки records.jsonl.
Старые архивы не превращаются в «все индексы исправны»: недостающие данные отмечаются явно.

Пороги советчика настраиваются, например:

```powershell
python analyze.py index_capture.zip --output analysis-output --index-min-pages 2000 --index-reorganize-percent 10 --index-rebuild-percent 40
```

Пороги 5/30% и 1000 страниц — эвристика проекта, не универсальный норматив. По возрасту статистики
не назначается безусловный FULLSCAN. [Настройки и базовое обслуживание](docs/maintenance.md).
[Связь нагрузки с запросом и Get-OneCQuery.ps1](docs/workload-analysis.md).

## Подготовить задания обслуживания

Базовый пакет FULL/LOG/STATS/CHECKDB:

```powershell
& { $s=Join-Path $env:TEMP ('perf-maint-'+[guid]::NewGuid()+'.ps1'); Invoke-WebRequest 'https://raw.githubusercontent.com/popiposter/perf-1c/main/New-OneCMaintenance.ps1' -OutFile $s -ErrorAction Stop; & $s -Database 'DB_NAME' }
```

Сценарий запросит существующий каталог копий, доступный службе SQL. LOG — только явным
LogBackupMinutes для FULL/BULK_LOGGED, без изменения модели восстановления.

Дополнительный пакет INDEX:

```powershell
& { $s=Join-Path $env:TEMP ('perf-index-maint-'+[guid]::NewGuid()+'.ps1'); Invoke-WebRequest 'https://raw.githubusercontent.com/popiposter/perf-1c/main/New-OneCIndexMaintenance.ps1' -OutFile $s -ErrorAction Stop; & $s -Database 'DB_NAME' }
```

**Оба генератора по умолчанию только создают локальные файлы, без соединения с SQL.**
install.sql устанавливает отключённые jobs; enable.sql — отдельное согласованное включение;
disable.sql/remove.sql — контроль принадлежащих пакету заданий; package.json — параметры.
`-Apply` после ShouldProcess выполняет только установку. Ни одно задание не запускается автоматически.

INDEX: до 50 секций за запуск с ротацией, проверка текущего состояния, общий с STATS/CHECKDB
applock, собственный журнал в msdb. REORGANIZE — по политике; REBUILD откладывается, пока
оператор явно не задаст AllowOfflineRebuild. Это блокирующий OFFLINE rebuild, не ONLINE.
Бюджет времени не прерывает уже начатую операцию. Нет REBUILD ALL, изменения FILLFACTOR,
создания clustered index в 1С или дополнительного FULLSCAN после каждого индекса.

Перед включением: испытать на тестовом SQL, проверить действующие backup chains/расписания,
окно, место/журнал, хранение, внешние копии, уведомления, системные базы и реальное восстановление.
[Полный порядок INDEX](docs/index-maintenance.md), [базовое обслуживание](docs/maintenance.md).

## Разработка и проверки

`analysis_core.py` и workload.py — прежние расчёты; analyze.py объединяет отчёт,
recommendations.py проверяет настройки, index_advisor.py — индексы и статистики.
Collect-OneCPerf.ps1 и Get-OneCIndexAudit.ps1 — чтение; два New-*Maintenance.ps1 — отдельные установщики.
Правила: AGENTS.md. SHA256SUMS.txt относится только к исходному импорту 0.1.

```powershell
python -m unittest discover -s tests -v
pwsh -NoProfile -File .\tests\Test-IndexMaintenance.ps1
```

В текущей доработке прошли 49 целевых Python-проверок: 12 прежних, 30 новых правил/отчёта,
7 статических контрактов SQL/PS. Это не полный повтор всех прежних тестов. PowerShell-тест
добавлен, но не выполнен: PS7/Windows/SQL здесь недоступны. Новые запросы и установка jobs
не объявляются проверенными по результатам Python. CI не включался.

**Репозиторий публичный, данные — нет.** Не публикуйте реальные ZIP, планы, пароли и сведения
серверов/баз. Пакеты установки также содержат внутренние имена и команды. Ничего автоматически
не отправляется наружу; .gitignore не заменяет ревизию.
