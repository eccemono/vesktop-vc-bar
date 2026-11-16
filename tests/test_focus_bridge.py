import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("vc_bridge", ROOT / "vc-bridge/vc_bridge.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FocusStateTests(unittest.TestCase):
    def bridge(self, enabled=True):
        bridge = module.Bridge()
        bridge.plugin_ws = object()
        bridge.plugin_last_msg = module.now()
        bridge.last_snapshot = {
            "type": "state",
            "channel": {"id": "123", "name": "Study"},
            "self": {"userId": "456"},
            "members": [],
            "focus": {"enabled": enabled, "channelId": "123"},
        }
        return bridge

    def test_enabled_while_connected(self):
        self.assertEqual(self.bridge().build_public()["focus"], {"enabled": True, "channelId": "123"})

    def test_off_by_default_for_old_plugin(self):
        bridge = self.bridge()
        del bridge.last_snapshot["focus"]
        self.assertFalse(bridge.build_public()["focus"]["enabled"])

    def test_disconnect_clears_focus_not_persistence(self):
        bridge = self.bridge()
        bridge.plugin_ws = None
        self.assertEqual(bridge.build_public()["focus"], {"enabled": False, "channelId": None})

    def test_stale_connection_does_not_report_focus(self):
        bridge = self.bridge()
        bridge.plugin_last_msg = 0
        self.assertFalse(bridge.build_public()["focus"]["enabled"])

    def test_other_channel_not_focused(self):
        self.assertFalse(self.bridge(enabled=False).build_public()["focus"]["enabled"])

    def test_command_is_supported(self):
        self.assertIn("set_focus", module.ALLOWED_COMMANDS)


if __name__ == "__main__":
    unittest.main()
