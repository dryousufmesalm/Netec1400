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
    def _report(self, embedded=None, connections=None, links=None, query_parts=None):
        connections = connections or [
            {"id": "1", "location": "AmarTrading_Baskets", "command": "SELECT * FROM [AmarTrading_Baskets]"},
            {"id": "2", "location": "AmarTrading_SyncStatus", "command": "SELECT * FROM [AmarTrading_SyncStatus]"},
        ]
        return {
            "embedded_queries": embedded or sorted(mod.EXPECTED), "connections": connections,
            "query_tables": query_parts or [{"part": "xl/queryTables/queryTable1.xml", "connectionId": "1"}, {"part": "xl/queryTables/queryTable2.xml", "connectionId": "2"}],
            "wired_query_tables": links or [{"table_rels": "xl/tables/_rels/table1.xml.rels", "target": "../queryTables/queryTable1.xml"}, {"table_rels": "xl/tables/_rels/table3.xml.rels", "target": "../queryTables/queryTable2.xml"}],
            "folder_files_arguments": [], "uses_onedrive_amartrading": True, "mashup_length_mismatch": False,
        }

    def test_valid_contract_has_no_failures(self):
        self.assertEqual(mod.failures(self._report()), [])

    def test_old_case_and_money_machine_names_are_rejected(self):
        report = self._report(embedded=["amartrading_Baskets", "amartrading_SyncStatus"], connections=[
            {"id": str(i), "location": "MoneyMachine_Baskets" if i % 2 else "MoneyMachine_SyncStatus", "command": "SELECT * FROM [MoneyMachine_Baskets]"} for i in range(1, 7)])
        issues = mod.failures(report)
        self.assertTrue(any("embedded queries" in issue for issue in issues))
        self.assertTrue(any("MoneyMachine" in issue for issue in issues))

    def test_duplicate_connections_are_rejected(self):
        report = self._report(connections=[self._report()["connections"][0]] * 6)
        self.assertTrue(any("exactly 2" in issue for issue in mod.failures(report)))

    def test_missing_relationship_target_is_rejected(self):
        report = self._report(links=[{"table_rels": "xl/tables/_rels/table1.xml.rels", "target": "../queryTables/missing.xml"}])
        self.assertTrue(any("missing queryTable part" in issue for issue in mod.failures(report)))

    @unittest.skipUnless((OUT / "AmarTrading_Excel_Master_Analytics_Clean.xlsx").exists(), "generated artifact not checked out")
    def test_real_clean_artifact_regression(self):
        report = mod.inspect(OUT / "AmarTrading_Excel_Master_Analytics_Clean.xlsx")
        self.assertTrue(any("MoneyMachine" in issue for issue in mod.failures(report)))


if __name__ == "__main__":
    unittest.main()
