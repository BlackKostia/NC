"""Run independent test cases concurrently. PTY and subprocess tests spend their time waiting (sleeps, child processes), so threads give a
near-linear speed-up; every case owns its temp directory and sessions. The first failure is re-raised after all cases have finished, so a
failing case never leaves another one running behind the traceback."""

import os
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor


def run_parallel(calls: list[Callable[[], object]], jobs: int | None = None) -> list[object]:
    jobs = jobs or min(len(calls), int(os.environ.get("DUOP_TEST_JOBS", "0")) or 6)
    with ThreadPoolExecutor(max_workers=max(1, jobs)) as pool:
        futures = [pool.submit(c) for c in calls]
        results, error = [], None
        for f in futures:
            try:
                results.append(f.result())
            except BaseException as exc:                      # noqa: BLE001 - keep the first one, finish the rest
                error = error or exc
        if error:
            raise error
        return results
