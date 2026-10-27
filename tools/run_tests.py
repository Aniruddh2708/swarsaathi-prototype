"""Run the actual unittest suite and save outcomes, including skips and failures."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import time
import unittest


class RecordedResult(unittest.TextTestResult):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.records = []

    def startTest(self, test):
        self.began = time.perf_counter()
        super().startTest(test)

    def _record(self, test, outcome, detail=None):
        self.records.append(dict(test=test.id(), outcome=outcome,
                                 seconds=time.perf_counter() - getattr(self, 'began', time.perf_counter()), detail=detail))

    def addSuccess(self, test):
        self._record(test, 'passed')
        super().addSuccess(test)

    def addFailure(self, test, err):
        self._record(test, 'failed', self._exc_info_to_string(err, test))
        super().addFailure(test, err)

    def addError(self, test, err):
        self._record(test, 'error', self._exc_info_to_string(err, test))
        super().addError(test, err)

    def addSkip(self, test, reason):
        self._record(test, 'skipped', reason)
        super().addSkip(test, reason)

    def addExpectedFailure(self, test, err):
        self._record(test, 'expected_failure', self._exc_info_to_string(err, test))
        super().addExpectedFailure(test, err)

    def addUnexpectedSuccess(self, test):
        self._record(test, 'unexpected_success')
        super().addUnexpectedSuccess(test)

    def addSubTest(self, test, subtest, err):
        if err is not None:
            outcome = 'failed' if issubclass(err[0], test.failureException) else 'error'
            self._record(subtest, outcome, self._exc_info_to_string(err, test))
        super().addSubTest(test, subtest, err)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', default='artifacts/test_results.json')
    args = parser.parse_args(argv)
    root = Path(__file__).resolve().parents[1]
    suite = unittest.defaultTestLoader.discover(str(root / 'tests'), top_level_dir=str(root))
    began = time.perf_counter()
    result = unittest.TextTestRunner(verbosity=2, resultclass=RecordedResult).run(suite)
    counts = {key: sum(row['outcome'] == key for row in result.records)
              for key in ('passed', 'failed', 'error', 'skipped', 'expected_failure', 'unexpected_success')}
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(dict(
        run_utc=datetime.now(timezone.utc).isoformat(), tests_run=result.testsRun,
        seconds=time.perf_counter() - began, successful=result.wasSuccessful(),
        counts=counts, records=result.records,
        hardware='Hardware tests are a separate manual protocol; this suite uses synthetic data and mocks.'
    ), indent=2), encoding='utf-8')
    return 0 if result.wasSuccessful() and result.testsRun > 0 else 1


if __name__ == '__main__':
    raise SystemExit(main())
