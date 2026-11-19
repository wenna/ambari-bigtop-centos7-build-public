import importlib.util
import unittest
from pathlib import Path


path = Path(__file__).resolve().parents[1] / "ops" / "prepare-config.py"
spec = importlib.util.spec_from_file_location("prepare_config", str(path))
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class PrepareHosts(unittest.TestCase):
    def test_preserves_existing_records_and_replays(self):
        values = ["192.0.2.12 worker.site.test", "192.0.2.11 master.site.test"]
        old = "# local settings\n127.0.0.1 localhost\n192.0.2.11 master.site.test master\n"
        output = config.render("hosts", old, values)
        self.assertTrue(output.startswith(old))
        self.assertEqual(output.count("192.0.2.11"), 1)
        self.assertEqual(output, config.render("hosts", output, values))

    def test_rejects_conflicting_address_or_canonical_name(self):
        for line in ("192.0.2.77 master.site.test\n", "192.0.2.11 old master.site.test\n"):
            with self.assertRaises(ValueError):
                config.render("hosts", line, ["192.0.2.11 master.site.test"])

    def test_replaces_only_stock_ntp_sources(self):
        old = ("# keep this\nserver 0.centos.pool.ntp.org iburst\n"
               "server ntp1.site.test key 42\nrtcsync\n")
        sources = ["ntp1.site.test", "ntp2.site.test"]
        output = config.render("chrony", old, sources)
        self.assertIn("server ntp1.site.test key 42\nrtcsync\n", output)
        self.assertIn("server ntp2.site.test iburst\n", output)
        self.assertNotIn("centos.pool", output)
        self.assertEqual(output, config.render("chrony", output, sources))

    def test_refuses_existing_external_time_policy_and_malformed_blocks(self):
        for value in ("peer somewhere.site\n", "include /etc/chrony.other\n",
                      "refclock PPS /dev/pps0\n", config.BEGIN + "\n", config.END + "\n"):
            with self.assertRaises(ValueError):
                config.render("chrony", value, ["ntp.site.test"])


if __name__ == "__main__":
    unittest.main()
