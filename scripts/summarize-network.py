#!/usr/bin/env python3
"""Aggregate O2 sysstat and TCP samples within each loadgen stage."""

import csv
import gzip
import json
import re
import statistics
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo


def sysstat_rows(path):
    """Use each sysstat header to decode its following timestamped rows."""
    header = []
    rows = []
    for line in path.read_text().splitlines():
        fields = line.lstrip('# ').split()
        if not fields:
            continue
        if any(key in fields for key in ('IFACE', 'CPU', 'active/s', 'atmptf/s')):
            header = ['time', *fields[1:]]
        elif re.fullmatch(r'\d{2}:\d{2}:\d{2}', fields[0]):
            if header and len(fields) == len(header):
                rows.append(dict(zip(header, fields)))
    return rows


def queue_samples(path):
    """Sum established TCP send queues in each three-second ss snapshot."""
    opener = gzip.open if path.suffix == '.gz' else open
    samples = []
    stamp = None
    queued = 0
    with opener(path, 'rt') as source:
        for line in source:
            if re.match(r'^\d{4}-\d\d-\d\dT', line):
                if stamp is not None:
                    samples.append({'time': stamp, 'queued': queued})
                stamp = datetime.fromisoformat(line.strip()).strftime('%H:%M:%S')
                queued = 0
            else:
                fields = line.split()
                if fields and fields[0] == 'ESTAB':
                    queued += int(fields[2])
    if stamp is not None:
        samples.append({'time': stamp, 'queued': queued})
    return samples


def mean(rows, key, **selectors):
    """Average one metric from rows with the requested labels."""
    values = [
        float(row[key]) for row in rows
        if key in row and all(row.get(k) == v for k, v in selectors.items())
    ]
    if not values:
        raise ValueError(f'Missing {key} samples for {selectors}')
    return statistics.mean(values)


def summarize(directory):
    """Exclude five warm-up seconds and emit a table.sh-compatible use.csv."""
    sources = {
        'a_net': sysstat_rows(directory / 'sar.log'),
        'a_cpu': sysstat_rows(directory / 'mpstat.log'),
        'a_process': sysstat_rows(directory / 'pidstat.log'),
        'b_net': sysstat_rows(directory / 'client/sar.log'),
        'b_cpu': sysstat_rows(directory / 'client/mpstat.log'),
    }
    queue_path = directory / 'ss.log.gz'
    if not queue_path.exists():
        queue_path = directory / 'ss.log'
    sources['queues'] = queue_samples(queue_path)
    with (directory / 'client/steps.csv').open() as source:
        steps = list(csv.DictReader(source))
    result = []
    for step in steps:
        if step['step'] == 'all':
            continue
        start = datetime.fromtimestamp(
            int(step['start_unix']) + 5, ZoneInfo('Asia/Shanghai')
        ).strftime('%H:%M:%S')
        end = datetime.fromtimestamp(
            int(step['end_unix']), ZoneInfo('Asia/Shanghai')
        ).strftime('%H:%M:%S')
        window = {
            name: [row for row in rows if start < row['time'] <= end]
            for name, rows in sources.items()
        }
        result.append({
            'step': step['step'],
            'target_rps': step['target_rps'],
            'a_tx_gbps': mean(window['a_net'], 'txkB/s', IFACE='eth0') * 8192 / 1e9,
            'b_rx_gbps': mean(window['b_net'], 'rxkB/s', IFACE='eth0') * 8192 / 1e9,
            'a_cpu_pct': 100 - mean(window['a_cpu'], '%idle', CPU='all'),
            'a_process_cpu_pct': mean(window['a_process'], '%CPU'),
            'b_cpu_pct': 100 - mean(window['b_cpu'], '%idle', CPU='all'),
            'retrans_per_s': mean(window['a_net'], 'retrans/s'),
            'send_queue_max_mib': max(row['queued'] for row in window['queues']) / 1048576,
        })
    (directory / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    with (directory / 'use.csv').open('w') as target:
        writer = csv.DictWriter(target, fieldnames=result[0].keys(), lineterminator='\n')
        writer.writeheader()
        for row in result:
            writer.writerow({
                key: f'{value:.3f}' if isinstance(value, float) else value
                for key, value in row.items()
            })
    # Keep the client output unchanged when placing it beside the derived CSV.
    (directory / 'steps.csv').write_bytes((directory / 'client/steps.csv').read_bytes())


if __name__ == '__main__':
    for argument in sys.argv[1:]:
        summarize(Path(argument))
