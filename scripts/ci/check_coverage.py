"""Apex coverage gate for CI.

Reads the code-coverage file written by `sf apex run test --code-coverage --output-dir <dir>` and fails when any
non-test class is below --min-class or the overall figure is below --min-overall. The platform's own 75% floor is
an org-wide minimum, not a quality bar, so the pipeline enforces its own.

Usage: python3 scripts/ci/check_coverage.py test-results --min-class 85 --min-overall 90
"""
import argparse
import glob
import json
import os
import sys


def load_rows(results_dir):
    candidates = glob.glob(os.path.join(results_dir, '*codecoverage*.json'))
    if not candidates:
        sys.exit(f'No code-coverage JSON found in {results_dir}')
    with open(candidates[0]) as handle:
        data = json.load(handle)
    return data if isinstance(data, list) else data.get('coverage', data.get('records', []))


def percent(row):
    if row.get('coveredPercent') is not None:
        return float(row['coveredPercent']), row.get('totalCovered', 0), row.get('totalLines', 0)
    total = row.get('totalLines') or (row.get('numLinesCovered', 0) + row.get('numLinesUncovered', 0))
    covered = row.get('totalCovered', row.get('numLinesCovered', 0))
    return (100.0 * covered / total if total else 100.0), covered, total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('results_dir')
    parser.add_argument('--min-class', type=float, default=85)
    parser.add_argument('--min-overall', type=float, default=90)
    args = parser.parse_args()

    failures, covered_sum, total_sum = [], 0, 0
    for row in load_rows(args.results_dir):
        name = row.get('name') or row.get('ApexClassOrTrigger', {}).get('Name', '?')
        pct, covered, total = percent(row)
        covered_sum += covered
        total_sum += total
        status = 'OK ' if pct >= args.min_class else 'LOW'
        print(f'{status} {pct:6.1f}%  {name}')
        if pct < args.min_class:
            failures.append(name)

    overall = 100.0 * covered_sum / total_sum if total_sum else 0.0
    print(f'Overall {overall:.1f}% (minimum {args.min_overall}%), per class minimum {args.min_class}%')
    if failures or overall < args.min_overall:
        sys.exit(f'Coverage gate failed: {", ".join(failures) or "overall below minimum"}')


if __name__ == '__main__':
    main()
