import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).parents[1]
MOD_PATH = ROOT / "scripts/excel/validate_workbook_query_contract.py"
spec = importlib.util.spec_from_file_location("query_contract", MOD_PATH)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


OUT = ROOT / "outputs/019fe209-a32e-7040-84de-fe9e289219a5"


class WorkbookQueryContractTests(unittest.TestCase):
    def test_clean_package_exposes_the_actual_mismatch(self):
        report = mod.inspect(OUT / "AmarTrading_Excel_Master_Analytics_Clean.xlsx")
        issues = mod.failures(report)
        self.assertEqual(set(report["embedded_queries"]), {"amartrading_Baskets", "amartrading_SyncStatus"})
        self.assertTrue(any("MoneyMachine" in issue for issue in issues))
        self.assertTrue(any("worksheet-wired" in issue for issue in issues))

    def test_final_package_has_matching_embedded_and_connection_names_but_duplicate_wiring(self):
        report = mod.inspect(OUT / "AmarTrading_Excel_Master_Analytics_Final.xlsx")
        self.assertTrue(any("exactly 2" in issue for issue in mod.failures(report)))
        self.assertEqual(set(report["embedded_queries"]), mod.EXPECTED)


if __name__ == "__main__":
    unittest.main()
