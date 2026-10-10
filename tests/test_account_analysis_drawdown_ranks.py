"""Pure-Python contract for Account Analysis drawdown ranking semantics."""

from __future__ import annotations

import csv
import unittest
from pathlib import Path


def top_basket_drawdowns(rows: list[dict], account: str, run_id: str, n: int = 10) -> list[float]:
    """Largest individual-basket MaxFloatingDrawdownAbs for one Account#+RunID."""
    dds: list[float] = []
    for row in rows:
        if str(row.get("AccountNumber", "")) != str(account):
            continue
        if str(row.get("RunID", "")) != str(run_id):
            continue
        raw = row.get("MaxFloatingDrawdownAbs") or 0
        try:
            dds.append(float(raw))
        except (TypeError, ValueError):
            continue
    dds.sort(reverse=True)
    return dds[:n]


class DrawdownRankContractTests(unittest.TestCase):
    def test_fixture_top3_and_avg10(self) -> None:
        path = Path("/tmp/master-dd-metrics-39ce/fixture/amartrading/VPS_newvps01/Account_18335349/Baskets.csv")
        if not path.is_file():
            self.skipTest("synthetic fixture not staged")
        rows = list(csv.DictReader(path.open(newline="", encoding="utf-8-sig")))
        run_id = rows[0]["RunID"]
        top = top_basket_drawdowns(rows, "18335349", run_id, 10)
        self.assertEqual([round(x, 2) for x in top[:3]], [486.79, 93.94, 56.71])
        self.assertAlmostEqual(sum(float(r["ClosePL"]) for r in rows), 210.14, places=2)
        self.assertAlmostEqual(sum(top) / len(top), 78.294, places=3)

    def test_ignores_other_run_and_stale_flat(self) -> None:
        rows = [
            {"AccountNumber": "18335349", "RunID": "CURRENT", "MaxFloatingDrawdownAbs": "486.79", "ClosePL": "10"},
            {"AccountNumber": "18335349", "RunID": "CURRENT", "MaxFloatingDrawdownAbs": "93.94", "ClosePL": "10"},
            {"AccountNumber": "18335349", "RunID": "STALE_RUN", "MaxFloatingDrawdownAbs": "2.24", "ClosePL": "1"},
            {"AccountNumber": "999", "RunID": "CURRENT", "MaxFloatingDrawdownAbs": "999", "ClosePL": "1"},
        ]
        top = top_basket_drawdowns(rows, "18335349", "CURRENT", 10)
        self.assertEqual(top, [486.79, 93.94])
        # Stale 2.24 must not dilute avg when filtering current run only
        self.assertNotIn(2.24, top)


if __name__ == "__main__":
    unittest.main()
