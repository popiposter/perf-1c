#!/usr/bin/env python3
"""Offline interval analysis plus evidence-based settings/maintenance recommendations."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
from zipfile import BadZipFile
import analysis_core as core
# Preserve the existing pure helper API used by tests and operator scripts.
from analysis_core import (counter_delta, safe_ratio, read_capture, timestamp, numeric,
                           wait_category, table, display)
from recommendations import recommend, render_recommendations

ANALYZER_VERSION = '0.3.0-pilot'


def summarize(manifest: dict, records: list[dict]) -> dict:
    result = core.summarize(manifest, records)
    result['analyzer_version'] = ANALYZER_VERSION
    result['recommendations'] = recommend(manifest, records)
    return result


def render(summary: dict) -> str:
    html = core.render(summary).replace('АНАЛИЗАТОР 0.2', 'АНАЛИЗАТОР 0.3')
    section = render_recommendations(summary['recommendations'])
    anchor = '<h2>Нагрузка по базам и шаблонам запросов</h2>'
    return html.replace(anchor, section+anchor, 1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('capture', type=Path, help='Capture ZIP or extracted directory')
    parser.add_argument('--output', type=Path, default=Path('analysis-output'))
    args = parser.parse_args()
    try:
        manifest, records = read_capture(args.capture)
        result = summarize(manifest, records)
        args.output.mkdir(parents=True, exist_ok=True)
        (args.output/'summary.json').write_text(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False), encoding='utf-8')
        (args.output/'recommendations.json').write_text(json.dumps(result['recommendations'], ensure_ascii=False, indent=2, allow_nan=False), encoding='utf-8')
        (args.output/'report.html').write_text(render(result), encoding='utf-8')
        print(args.output.resolve()/'report.html')
    except (OSError, ValueError, KeyError, TypeError, BadZipFile) as exc:
        parser.exit(2, f'Cannot analyze capture: {exc}\n')


if __name__ == '__main__':
    main()
