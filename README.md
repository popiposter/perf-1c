# perf-1c

Локальная диагностика производительности **1С + Microsoft SQL Server**.
Измерения → гипотезы → рекомендации с доказательствами → отдельное согласованное изменение.

**Анализатор 0.3.0-pilot; сборщик 0.1.3-pilot.** Добавлен аудит настроек и обслуживания,
рекомендации «текущее → предлагается» и генератор отключённых SQL Agent jobs.
Базовый сбор Windows/SQL подтверждён одним пилотным окружением. Новые SQL-запросы аудита
и установщик jobs ещё не прошли Windows/SQL integration. Не автоматический оптимизатор.

## Одна команда: сбор в PowerShell 7 x64 на Windows

```powershell
& { $s=Join-Path $env:TEMP ('perf-1c-'+[guid]::NewGuid()+'.ps1'); Invoke-WebRequest 'https://raw.githubusercontent.com/popiposter/perf-1c/main/Start-OneCPerf.ps1' -OutFile $s -ErrorAction Stop; & $s -Minutes 1 -IncludeMaintenance }
```

Экземпляр и SQL-база запрашиваются интерактивно. Enter для экземпляра — `.`, для базы —
без деталей выбранной базы. Windows-аутентификация текущего пользователя; можно передать
SqlCredential как PSCredential. Для основного замера — Minutes 10 во время проблемы.
Для отдельного узла 1С — SkipSql и Role onec. Вопросы можно отключить NonInteractive,
передав SqlInstance и Database явно.

Код: `%LOCALAPPDATA%\perf-1c\downloads`; данные: `%LOCALAPPDATA%\perf-1c\captures`.
Путь ZIP выводится в конце. Git, Python и SqlServer module на сервере не нужны.
`stop_reason=completed` — окончание таймера, не гарантия полноты. Смотрите coverage.html
и ошибки. Метрики Windows относятся только к узлу запуска; SQL может быть удалённым.

Для недоверенной SQL-цепочки существует явный `-TrustServerCertificate`: шифрование
сохраняется, а подлинность сервера сертификатом не проверяется. Только для проверенного
узла по решению оператора; постоянное решение — корректная доверенная цепочка.
Подробнее: [подключение SQL](docs/sql-connection.md).

Загрузчик фиксирует commit SHA, скачивает новый каталог, не запускает старую копию после
ошибки. Для закрепления версии замените main в URL и Ref на один проверенный SHA.
DownloadOnly — скачать без сбора. ExecutionPolicy, HTTPS, права и службы не меняются.
Полная инструкция исходного профиля: [README_RU.md](README_RU.md).

## Отчёт с рекомендациями

На рабочем компьютере администратора, Python 3.10+, без сторонних пакетов:

```powershell
python analyze.py PATH_TO_CAPTURE.zip --output analysis-output
```

В `report.html`: ресурсы, запросы, ожидания, настройки и обслуживание. Для каждой
рекомендации — текущее/предлагаемое значение, риск, область действия, строки исходного
журнала и источник. `recommendations.json` — те же рекомендации для автоматизации.
Старый архив не требует повторного сбора ради базовых рекомендаций, но новые сведения
о расписаниях и шагах получаются только новым запуском с IncludeMaintenance.

[Настройки, аудит и правила обслуживания](docs/maintenance.md).
[Связь нагрузки с запросом и Get-OneCQuery.ps1](docs/workload-analysis.md).

## Одна команда: подготовить задания обслуживания

```powershell
& { $s=Join-Path $env:TEMP ('perf-maint-'+[guid]::NewGuid()+'.ps1'); Invoke-WebRequest 'https://raw.githubusercontent.com/popiposter/perf-1c/main/New-OneCMaintenance.ps1' -OutFile $s -ErrorAction Stop; & $s -Database 'DB_NAME' }
```

`DB_NAME` — пример. Сценарий запросит существующий каталог копий, доступный службе SQL.
**По умолчанию только локальные файлы, без подключения к SQL.** Пакет: install.sql,
enable.sql, disable.sql, remove.sql, package.json. `-Apply` после подтверждения устанавливает
отключённые jobs. Ничего не запускается автоматически. Это Agent → Jobs, не графические SSIS-планы.

Стартовый профиль: ежедневный FULL backup с CHECKSUM/COMPRESSION и VERIFYONLY;
ночные изменённые статистики; еженедельный CHECKDB. LOG backups включаются только параметром
LogBackupMinutes для FULL/BULK_LOGGED. Без изменения recovery model, SHRINK и REBUILD ALL.

**До включения:** согласовать существующие цепочки/расписания, RPO/RTO, место и retention,
внешние копии, уведомления, системные базы и тест восстановления. Эти задачи не заменяются
наличием новых jobs. Смотрите [полный порядок установки и ограничения](docs/maintenance.md).

## Разработка и проверки

- `analysis_core.py` — прежний движок интервалов/нагрузки без изменения расчётов.
- `analyze.py` — CLI и объединение отчёта; `recommendations.py` — проверяемые правила.
- `workload.py` — связь снимков с базами/процессами/шаблонами запросов.
- `sql/` и Collect-OneCPerf.ps1 — чтение; New-OneCMaintenance.ps1 — отдельный генератор/установщик.
- `AGENTS.md`, `docs/roadmap.md` — правила и развитие. SHA256SUMS.txt относится только к импорту 0.1.

```powershell
python -m unittest discover -s tests -v
pwsh -NoProfile -File .\tests\Test-Maintenance.ps1
```

В среде доработки выполнены 12 исходных тестов анализатора и 22 новых теста рекомендаций.
Тест PowerShell добавлен, но не выполнен: PS/Windows/SQL runtime здесь недоступен.
Новые источники и установка требуют тестового прогона; CI автоматически не включён.

**Репозиторий публичный, данные — нет.** Не публикуйте реальные ZIP, SQL-планы, пароли,
сведения серверов/баз/клиентов. Генерируемые пакеты обслуживания тоже содержат внутренние
имена и пути. Ничего автоматически не отправляется наружу; .gitignore не заменяет ревизию.
