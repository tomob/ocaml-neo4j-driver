#!/usr/bin/env python3
"""Run a single TestKit test module and print a machine-readable RESULT line.

Usage:
  testkit_module_result.py <test-module>

The module is loaded with unittest.TestLoader.loadTestsFromName so it may be a
module, a test class or a single test. On success prints:

  RESULT module=<name> run=<N> passed=<N> skipped=<N> failures=<N> errors=<N>

and exits 0 when there were no failures/errors, 1 otherwise. An import error
is reported as errors=1 with an import_error=... tag. The environment (the
testkit checkout on PYTHONPATH, the TEST_* harness variables) must already be
set up by the calling script.
"""

import sys
import unittest


def main():
    if len(sys.argv) != 2:
        print("usage: testkit_module_result.py <test-module>", file=sys.stderr)
        return 2
    module = sys.argv[1]

    loader = unittest.TestLoader()
    try:
        suite = loader.loadTestsFromName(module)
    except Exception as exc:  # noqa: BLE001 - report any import/load failure
        print(
            f"RESULT module={module} run=0 passed=0 skipped=0 failures=0 "
            f"errors=1 import_error={exc!r}"
        )
        return 1

    runner = unittest.TextTestRunner(verbosity=1, stream=sys.stdout)
    result = runner.run(suite)

    skipped = len(result.skipped)
    failures = len(result.failures)
    errors = len(result.errors)
    run = result.testsRun
    passed = run - skipped - failures - errors
    print(
        f"RESULT module={module} run={run} passed={passed} "
        f"skipped={skipped} failures={failures} errors={errors}"
    )
    return 1 if (failures or errors) else 0


if __name__ == "__main__":
    sys.exit(main())
