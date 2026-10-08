#!/usr/bin/env python3
"""Pure-Python model of the Master latest-file-per-account selection rules."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone


@dataclass(frozen=True)
class SourceFile:
    folder_path: str
    name: str
    folder_priority: int
    date_modified: datetime
    row_count: int

    @property
    def folder_account_number(self) -> str | None:
        leaf = self.folder_path.rstrip("\\").split("\\")[-1]
        if leaf.startswith("Account_"):
            return leaf[len("Account_") :]
        return None

    @property
    def vps_id(self) -> str:
        parts = self.folder_path.rstrip("\\").split("\\")
        parent = parts[-2] if len(parts) >= 2 else ""
        if parent.startswith("VPS_"):
            return parent[len("VPS_") :]
        return "legacy-unassigned"

    @property
    def path_key(self) -> str:
        return (self.folder_path.rstrip("\\") + "\\" + self.name).lower()

    @property
    def vps_rank(self) -> int:
        return 1 if self.vps_id == "legacy-unassigned" else 0


def select_latest_per_account(files: list[SourceFile]) -> list[SourceFile]:
    basket = [f for f in files if f.name == "Baskets.csv" and f.folder_account_number]
    canonical_accounts = {
        f.folder_account_number
        for f in basket
        if f.folder_priority == 0 and f.folder_account_number
    }
    preferred = [
        f
        for f in basket
        if f.vps_id != "legacy-unassigned"
        or f.folder_priority == 0
        or f.folder_account_number not in canonical_accounts
    ]
    path_deduped: dict[str, SourceFile] = {}
    for f in sorted(preferred, key=lambda x: x.folder_priority):
        path_deduped.setdefault(f.path_key, f)
    # Sort key matches M: account asc, date desc, vps_rank asc, priority asc.
    ordered = sorted(
        path_deduped.values(),
        key=lambda f: (
            f.folder_account_number or "",
            -(f.date_modified.timestamp()),
            f.vps_rank,
            f.folder_priority,
        ),
    )
    latest: dict[str, SourceFile] = {}
    for f in ordered:
        assert f.folder_account_number is not None
        latest.setdefault(f.folder_account_number, f)
    return list(latest.values())


def test_prefers_newer_vps_folder_over_stale_flat_account() -> None:
    stale = SourceFile(
        folder_path=r"C:\Users\user\OneDrive\amartrading\Account_18335349",
        name="Baskets.csv",
        folder_priority=0,
        date_modified=datetime(2026, 9, 28, 12, 0, tzinfo=timezone.utc),
        row_count=74,
    )
    fresh = SourceFile(
        folder_path=r"C:\Users\user\OneDrive\amartrading\VPS_newvps\Account_18335349",
        name="Baskets.csv",
        folder_priority=0,
        date_modified=datetime(2026, 10, 7, 18, 0, tzinfo=timezone.utc),
        row_count=759,
    )
    selected = select_latest_per_account([stale, fresh])
    assert len(selected) == 1
    assert selected[0] is fresh
    assert selected[0].row_count == 759


def test_dedupes_case_insensitive_duplicate_root_scan() -> None:
    a = SourceFile(
        folder_path=r"C:\Users\user\OneDrive\amartrading\VPS_x\Account_1",
        name="Baskets.csv",
        folder_priority=0,
        date_modified=datetime(2026, 10, 7, tzinfo=timezone.utc),
        row_count=10,
    )
    b = SourceFile(
        folder_path=r"C:\Users\user\OneDrive\AmmarTrading\VPS_x\Account_1",
        name="Baskets.csv",
        folder_priority=1,
        date_modified=datetime(2026, 10, 7, tzinfo=timezone.utc),
        row_count=10,
    )
    selected = select_latest_per_account([a, b])
    assert len(selected) == 1
    assert selected[0].folder_priority == 0


def test_prefers_vps_when_dates_equal() -> None:
    flat = SourceFile(
        folder_path=r"C:\Users\user\OneDrive\amartrading\Account_9",
        name="Baskets.csv",
        folder_priority=0,
        date_modified=datetime(2026, 10, 7, tzinfo=timezone.utc),
        row_count=5,
    )
    nested = SourceFile(
        folder_path=r"C:\Users\user\OneDrive\amartrading\VPS_abc\Account_9",
        name="Baskets.csv",
        folder_priority=0,
        date_modified=datetime(2026, 10, 7, tzinfo=timezone.utc),
        row_count=50,
    )
    selected = select_latest_per_account([flat, nested])
    assert selected[0] is nested


if __name__ == "__main__":
    test_prefers_newer_vps_folder_over_stale_flat_account()
    test_dedupes_case_insensitive_duplicate_root_scan()
    test_prefers_vps_when_dates_equal()
    print("latest account source selection tests passed")
