#!/usr/bin/env python3
"""
aggregate-benchmarks.py — Aggregate multiple benchmark iterations into one report.

Usage:
    python3 aggregate-benchmarks.py --dir <artifacts_dir> --platform <name> --output <path>
"""

import argparse
import glob
import json
import os
import re
import sys


def parse_benchmark_log(path):
    """Parse a benchmark log file for timing data."""
    results = []
    pattern = re.compile(
        r'(?P<name>[\w/.-]+)\s+'
        r'(?P<time>\d+\.?\d*)\s+(?P<unit>\w+)'
    )
    with open(path) as f:
        for line in f:
            m = pattern.search(line)
            if m:
                results.append({
                    'name': m.group('name'),
                    'time': float(m.group('time')),
                    'unit': m.group('unit'),
                })
    return results


def main():
    parser = argparse.ArgumentParser(description='Aggregate benchmark results')
    parser.add_argument('--dir', required=True, help='Artifacts directory')
    parser.add_argument('--platform', required=True, help='Platform name')
    parser.add_argument('--output', required=True, help='Output JSON path')
    args = parser.parse_args()

    all_iterations = []
    for log_path in sorted(glob.glob(os.path.join(args.dir, 'bench-iter-*.log'))):
        iteration_num = re.search(r'bench-iter-(\d+)', log_path)
        iteration_num = int(iteration_num.group(1)) if iteration_num else 0
        data = parse_benchmark_log(log_path)
        all_iterations.append({'iteration': iteration_num, 'results': data})

    report = {
        'platform': args.platform,
        'iterations': len(all_iterations),
        'timestamp': __import__('datetime').datetime.utcnow().isoformat() + 'Z',
        'results': all_iterations,
    }

    os.makedirs(os.path.dirname(args.output) or '.', exist_ok=True)
    with open(args.output, 'w') as f:
        json.dump(report, f, indent=2)

    print(f'Benchmark report written to {args.output}')
    print(f'  Platform: {args.platform}')
    print(f'  Iterations: {len(all_iterations)}')


if __name__ == '__main__':
    main()
