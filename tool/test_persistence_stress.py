#!/usr/bin/env python3
"""Kill actual SQLite worker processes, verify reopening, then measure large migrations."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
WORKER_ROOT = ROOT


def invoke(folder, mode, rows, journal, phase='', expected='old', recovery=False, delay=None):
    env = os.environ.copy()
    env.update({f'TUNAI_STRESS_{k}': str(v) for k, v in {
        'MODE': mode, 'DB': folder / 'cache.db', 'ROWS': rows, 'JOURNAL': journal,
        'PHASE': phase, 'EXPECT': expected, 'RECOVERY': int(recovery),
        'MARKER': folder / 'marker.json', 'RESULT': folder / f'{mode}.json',
        'PID': folder / 'worker.pid',
    }.items()})
    (folder / 'worker.pid').unlink(missing_ok=True)
    log = (folder / f'{mode}.log').open('w')
    proc = subprocess.Popen(['flutter', 'test', 'tool/persistence_worker_test.dart', '--reporter', 'expanded'], cwd=WORKER_ROOT, env=env, stdout=log, stderr=subprocess.STDOUT)
    start = time.monotonic()
    peak_disk = peak_rss = peak_journal = 0
    killed = False
    try:
        while proc.poll() is None:
            if time.monotonic() - start > 1800:
                raise TimeoutError(f'worker timed out: {folder}')
            peak_disk = max(peak_disk, sum(p.stat().st_size for p in folder.glob('cache.db*') if p.is_file()))
            peak_journal = max(peak_journal, sum(p.stat().st_size for p in folder.glob('cache.db-*') if p.is_file() and p.suffix != '.json'))
            pidfile = folder / 'worker.pid'
            if pidfile.exists():
                rss = subprocess.run(['ps', '-o', 'rss=', '-p', pidfile.read_text().strip()], capture_output=True, text=True, errors='replace').stdout.strip()
                if rss.isdigit():
                    peak_rss = max(peak_rss, int(rss) * 1024)
            marker = folder / 'marker.json'
            if phase and marker.exists() and not killed:
                checkpoint = json.loads(marker.read_text())
                assert checkpoint['phase'] == phase
                if delay is not None:
                    (folder / 'marker.json.go').touch()
                    time.sleep(delay)
                os.kill(checkpoint['pid'], signal.SIGKILL)
                killed = True
            time.sleep(0.05)
        assert (proc.returncode != 0) if phase else (proc.returncode == 0), f'{folder}: see {mode}.log'
        if phase:
            assert killed, f'checkpoint was never reached: {folder}'
        return {'seconds': round(time.monotonic()-start, 3), 'peak_disk_bytes': peak_disk, 'peak_worker_rss_bytes': peak_rss, 'peak_journal_bytes': peak_journal, 'killed': killed}
    finally:
        if proc.poll() is None:
            # The file is written afresh by this worker before opening SQLite.
            pidfile = folder / 'worker.pid'
            if pidfile.exists():
                try:
                    os.kill(int(pidfile.read_text()), signal.SIGKILL)
                except ProcessLookupError:
                    pass
            proc.terminate()
            proc.wait(timeout=30)
        log.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--interrupt-rows', type=int, default=50000)
    parser.add_argument('--large-rows', type=int, nargs='*', default=[100000, 1000000])
    parser.add_argument('--only', choices=['interruptions', 'large', 'all'], default='all')
    args = parser.parse_args()
    root = args.output.resolve()
    if root.exists() and any(root.iterdir()):
        parser.error('--output must be empty so stale markers cannot influence a kill')
    root.mkdir(parents=True, exist_ok=True)
    global WORKER_ROOT
    WORKER_ROOT = root / 'worker_project'
    WORKER_ROOT.mkdir()
    shutil.copytree(ROOT / 'lib', WORKER_ROOT / 'lib')
    (WORKER_ROOT / 'tool').mkdir()
    shutil.copy2(ROOT / 'tool/persistence_worker_test.dart', WORKER_ROOT / 'tool/persistence_worker_test.dart')
    for name in ['pubspec.yaml', 'pubspec.lock', 'analysis_options.yaml']:
        shutil.copy2(ROOT / name, WORKER_ROOT / name)
    with (root / 'pub_get.log').open('w') as log:
        subprocess.run(['flutter', 'pub', 'get'], cwd=WORKER_ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
    report = []
    if args.only != 'large':
        for journal in ['WAL', 'DELETE']:
            seed = root / f'seed_{journal}'
            seed.mkdir(exist_ok=True)
            invoke(seed, 'seed', args.interrupt_rows, journal)
            cuts = [(p, False, None) for p in ['created','copy_1','copy_20','before_drop','after_drop','before_commit','after_commit']]
            cuts += [('recovery_drop', True, None), ('after_commit', True, None)]
            cuts += [('active_copy', False, delay) for delay in [0.002, 0.02, 0.1]]
            cuts += [('active_commit', False, delay) for delay in [0, 0.01, 0.02]]
            for index, (phase, recovery, delay) in enumerate(cuts):
                folder = root / f'{journal}_{index}_{phase}'
                folder.mkdir(exist_ok=True)
                for suffix in ['', '.schema.json']:
                    shutil.copy2(seed / f'cache.db{suffix}', folder / f'cache.db{suffix}')
                metrics = invoke(folder, 'migrate', args.interrupt_rows, journal, phase, recovery=recovery, delay=delay)
                if phase in ['before_drop', 'after_drop', 'before_commit'] and args.interrupt_rows >= 50000:
                    assert metrics['peak_journal_bytes'] > 131072, 'must exercise actual disk journal writes'
                expected = 'either' if delay is not None else 'new' if phase == 'after_commit' else 'old'
                invoke(folder, 'verify', args.interrupt_rows, journal, expected=expected, recovery=recovery)
                item = {'rows': args.interrupt_rows, 'journal': journal, 'phase': phase, 'recovery': recovery, 'delay': delay, **metrics, **json.loads((folder / 'verify.json').read_text())}
                report.append(item)
                (root / 'report.json').write_text(json.dumps(report, indent=2))
                print(json.dumps(item), flush=True)
    if args.only != 'interruptions':
        for rows in args.large_rows:
            folder = root / f'large_{rows}'
            folder.mkdir(exist_ok=True)
            invoke(folder, 'seed', rows, 'WAL')
            baseline = (folder / 'cache.db').stat().st_size
            metrics = invoke(folder, 'migrate', rows, 'WAL')
            migration = json.loads((folder / 'migrate.json').read_text())
            invoke(folder, 'verify', rows, 'WAL', expected='new')
            item = {'rows': rows, 'baseline_bytes': baseline, 'final_bytes': (folder / 'cache.db').stat().st_size, **metrics, **migration}
            report.append(item)
            (root / 'report.json').write_text(json.dumps(report, indent=2))
            print(json.dumps(item), flush=True)


if __name__ == '__main__':
    main()
