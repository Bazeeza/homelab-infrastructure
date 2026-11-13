"""Offline tests of relay/telegram_relay.py.

No network and no Telegram account: a fake Bot API and a fake webhook run on
127.0.0.1 in threads, and the test token has no real format.

    python3 -m unittest discover -s tests -p "test_*.py" -v
"""

import contextlib
import http.server
import io
import json
import os
import pathlib
import sys
import tempfile
import threading
import unittest
import urllib.error

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "relay"))

import telegram_relay as relay  # noqa: E402  (path set just above)

TOKEN = "123:TEST_token-for-offline-tests"
OWNER = 111111111
STRANGER = 222222222
WEBHOOK = "http://127.0.0.1:5678/webhook/test"
UNIT_FILE = ROOT / "configs" / "systemd" / "telegram-relay.service"
EXAMPLE_SETTINGS = ROOT / "configs" / "systemd" / "telegram-relay.conf.example"
INSTALLER = ROOT / "scripts" / "install-telegram-relay.sh"


def make_config(**overrides):
    environ = {"RELAY_ALLOWED_USER_ID": str(OWNER), "RELAY_WEBHOOK_URL": WEBHOOK}
    environ.update(overrides)
    return relay.load_config(environ)


def message_update(update_id, text, sender=OWNER, chat_id=None, chat_type="private"):
    return {
        "update_id": update_id,
        "message": {
            "message_id": update_id * 10,
            "from": {"id": sender},
            "chat": {"id": sender if chat_id is None else chat_id, "type": chat_type},
            "text": text,
        },
    }


@contextlib.contextmanager
def captured_log():
    buffer = io.StringIO()
    with contextlib.redirect_stdout(buffer):
        yield buffer


class RecordingTelegram:
    """Stands in for relay.Telegram in the filter tests."""

    def __init__(self):
        self.sent = []

    def send(self, chat_id, text):
        self.sent.append((chat_id, text))


class RecordingForward:
    """Stands in for forward_to_webhook; can fail on chosen calls."""

    def __init__(self, errors=None):
        self.calls = []
        self.errors = list(errors or [])

    def __call__(self, url, payload):
        self.calls.append((url, payload))
        error = self.errors.pop(0) if self.errors else None
        if error is not None:
            raise error
        return 200


class FakeServer:
    """Records every POST and answers with the queued (status, body) for its path."""

    def __init__(self):
        self.requests = []
        self.responses = {}
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                length = int(self.headers.get("Content-Length", 0))
                body = json.loads(self.rfile.read(length) or b"{}")
                outer.requests.append((self.path, body))
                status, answer = outer.answer_for(self.path)
                data = json.dumps(answer).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def queue(self, suffix, status, body):
        self.responses.setdefault(suffix, []).append((status, body))

    def answer_for(self, path):
        for suffix, queue in self.responses.items():
            if path.endswith(suffix) and queue:
                return queue.pop(0)
        return 200, {"ok": True, "result": True}

    def bodies(self, suffix):
        return [body for path, body in self.requests if path.endswith(suffix)]

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


class ConfigTests(unittest.TestCase):
    def test_minimal_settings(self):
        config = make_config()
        self.assertEqual(config.allowed_user_id, OWNER)
        self.assertEqual(config.webhook_url, WEBHOOK)
        self.assertEqual(config.commands, ("/status",))
        self.assertEqual(config.api_base, relay.DEFAULT_API_BASE)
        self.assertEqual(config.poll_timeout, 50)
        self.assertEqual(config.state_dir, ".")

    def test_commands_are_normalized(self):
        config = make_config(RELAY_COMMANDS="/Status, /uptime")
        self.assertEqual(config.commands, ("/status", "/uptime"))
        self.assertIn("/uptime", config.help_text)

    def test_missing_settings_are_refused(self):
        with self.assertRaises(relay.ConfigError):
            relay.load_config({"RELAY_WEBHOOK_URL": WEBHOOK})
        with self.assertRaises(relay.ConfigError):
            relay.load_config({"RELAY_ALLOWED_USER_ID": str(OWNER)})

    def test_user_id_must_be_numeric(self):
        for value in ("<TELEGRAM_USER_ID>", "-5", "0", "12ab", "1 2"):
            with self.subTest(value=value), self.assertRaises(relay.ConfigError):
                make_config(RELAY_ALLOWED_USER_ID=value)

    def test_webhook_must_be_on_loopback(self):
        refused = (
            "http://192.0.2.20:5678/webhook/test",
            "http://example.com/webhook/test",
            "http://127.0.0.1.example.com/webhook/test",
            "ftp://127.0.0.1/webhook/test",
        )
        for url in refused:
            with self.subTest(url=url), self.assertRaises(relay.ConfigError):
                make_config(RELAY_WEBHOOK_URL=url)
        for url in ("http://localhost:5678/w", "http://[::1]:5678/w", "http://127.0.0.2:5678/w"):
            with self.subTest(url=url):
                self.assertEqual(make_config(RELAY_WEBHOOK_URL=url).webhook_url, url)

    def test_bad_command_names_are_refused(self):
        for value in ("status", "/rm -rf", "/" + "a" * 33, "/st.atus"):
            with self.subTest(value=value), self.assertRaises(relay.ConfigError):
                make_config(RELAY_COMMANDS=value)

    def test_api_base_requires_https_except_on_loopback(self):
        with self.assertRaises(relay.ConfigError):
            make_config(RELAY_API_BASE="http://api.example.com")
        self.assertEqual(make_config(RELAY_API_BASE="https://api.example.com/").api_base, "https://api.example.com")
        self.assertEqual(make_config(RELAY_API_BASE="http://127.0.0.1:8081").api_base, "http://127.0.0.1:8081")

    def test_poll_timeout_range(self):
        self.assertEqual(make_config(RELAY_POLL_TIMEOUT="0").poll_timeout, 0)
        for value in ("51", "abc", "-1", "100"):
            with self.subTest(value=value), self.assertRaises(relay.ConfigError):
                make_config(RELAY_POLL_TIMEOUT=value)

    def test_first_state_directory_is_used(self):
        self.assertEqual(make_config(STATE_DIRECTORY="/var/lib/a:/var/lib/b").state_dir, "/var/lib/a")

    def test_example_settings_file(self):
        known = {"RELAY_ALLOWED_USER_ID", "RELAY_WEBHOOK_URL", "RELAY_COMMANDS", "RELAY_POLL_TIMEOUT", "RELAY_API_BASE"}
        settings = {}
        for line in EXAMPLE_SETTINGS.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            key, _, value = line.partition("=")
            settings[key] = value
        self.assertLessEqual(set(settings), known)
        self.assertIn("RELAY_ALLOWED_USER_ID", settings)
        self.assertIn("RELAY_WEBHOOK_URL", settings)
        # As published: placeholders only, so the relay must refuse to start
        with self.assertRaises(relay.ConfigError):
            relay.load_config(settings)
        # Once the placeholders are filled in, the settings are valid
        filled = {key: value.replace("<TELEGRAM_USER_ID>", str(OWNER)).replace("<WEBHOOK_PATH>", "test")
                  for key, value in settings.items()}
        self.assertEqual(relay.load_config(filled).allowed_user_id, OWNER)


class TokenTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.directory.name, relay.TOKEN_CREDENTIAL)

    def tearDown(self):
        self.directory.cleanup()

    def write(self, content):
        with open(self.path, "w", encoding="utf-8") as handle:
            handle.write(content)

    def test_needs_the_credential_directory(self):
        with self.assertRaises(relay.ConfigError):
            relay.read_token({})

    def test_missing_or_empty_token_is_refused(self):
        environ = {"CREDENTIALS_DIRECTORY": self.directory.name}
        with self.assertRaises(relay.ConfigError):
            relay.read_token(environ)
        self.write("   \n")
        with self.assertRaises(relay.ConfigError):
            relay.read_token(environ)

    def test_malformed_token_is_refused_without_echo(self):
        self.write("123:abc/def")
        with self.assertRaises(relay.ConfigError) as context:
            relay.read_token({"CREDENTIALS_DIRECTORY": self.directory.name})
        self.assertNotIn("abc/def", str(context.exception))

    def test_token_is_read_and_stripped(self):
        self.write(f"  {TOKEN}\n")
        self.assertEqual(relay.read_token({"CREDENTIALS_DIRECTORY": self.directory.name}), TOKEN)


class FilterTests(unittest.TestCase):
    def setUp(self):
        self.config = make_config()
        self.telegram = RecordingTelegram()

    def handle(self, update, forward=None):
        forward = forward or RecordingForward()
        with captured_log() as log:
            outcome = relay.handle_update(update, self.config, self.telegram, forward)
        return outcome, forward, log.getvalue()

    def test_parse_command(self):
        cases = {
            "/status": "/status",
            "/Status@example_bot": "/status",
            "  /STATUS now please": "/status",
            "hello": "hello",
            "": "",
            None: "",
        }
        for text, expected in cases.items():
            with self.subTest(text=text):
                self.assertEqual(relay.parse_command(text), expected)

    def test_known_command_is_forwarded_without_the_text(self):
        outcome, forward, _ = self.handle(message_update(1, "/status@example_bot extra words"))
        self.assertEqual(outcome, "forwarded")
        self.assertEqual(forward.calls, [(WEBHOOK, {"command": "/status", "from_id": OWNER, "message_id": 10})])
        self.assertEqual(self.telegram.sent, [])

    def test_stranger_gets_no_answer_and_text_is_not_logged(self):
        outcome, forward, log = self.handle(message_update(2, "/status secret words", sender=STRANGER))
        self.assertEqual(outcome, "rejected")
        self.assertEqual(forward.calls, [])
        self.assertEqual(self.telegram.sent, [])
        self.assertIn(f"sender={STRANGER}", log)
        self.assertNotIn("secret words", log)

    def test_owner_outside_a_private_chat_is_rejected(self):
        for update in (
            message_update(3, "/status", chat_id=-100123, chat_type="group"),
            message_update(4, "/status", chat_id=STRANGER),
            message_update(5, "/status", sender=str(OWNER)),
        ):
            with self.subTest(update=update):
                outcome, forward, _ = self.handle(update)
                self.assertEqual(outcome, "rejected")
                self.assertEqual(forward.calls, [])
        missing_sender = message_update(6, "/status")
        del missing_sender["message"]["from"]
        self.assertEqual(self.handle(missing_sender)[0], "rejected")
        self.assertEqual(self.telegram.sent, [])

    def test_update_without_message_is_ignored(self):
        self.assertEqual(self.handle({"update_id": 7, "edited_message": {}})[0], "ignored")

    def test_free_text_from_owner_gets_help_only(self):
        for text in ("what is up", None):
            with self.subTest(text=text):
                self.telegram.sent.clear()
                outcome, forward, _ = self.handle(message_update(8, text))
                self.assertEqual(outcome, "help")
                self.assertEqual(forward.calls, [])
                self.assertEqual(self.telegram.sent, [(OWNER, self.config.help_text)])

    def test_webhook_refusal_is_reported_to_owner(self):
        error = urllib.error.HTTPError(WEBHOOK, 404, "Not Found", None, None)
        outcome, _, log = self.handle(message_update(9, "/status"), RecordingForward([error]))
        self.assertEqual(outcome, "webhook-refused")
        self.assertIn("HTTP 404", log)
        self.assertEqual(len(self.telegram.sent), 1)
        self.assertIn("HTTP 404", self.telegram.sent[0][1])

    def test_unreachable_webhook_is_reported_to_owner(self):
        error = urllib.error.URLError("connection refused")
        outcome, _, _ = self.handle(message_update(10, "/status"), RecordingForward([error]))
        self.assertEqual(outcome, "webhook-unreachable")
        self.assertEqual(self.telegram.sent[0][0], OWNER)


class TelegramClientTests(unittest.TestCase):
    def setUp(self):
        self.server = FakeServer()
        self.client = relay.Telegram(TOKEN, self.server.base)

    def tearDown(self):
        self.server.close()

    def test_call_posts_json_to_the_method_path(self):
        self.assertTrue(self.client.call("getMe", {"a": 1}, 5))
        self.assertEqual(self.server.requests, [(f"/bot{TOKEN}/getMe", {"a": 1})])

    def test_http_error_never_shows_the_token(self):
        self.server.queue("/sendMessage", 401, {"ok": False, "description": "Unauthorized"})
        with self.assertRaises(relay.TelegramError) as context:
            self.client.send(OWNER, "hello")
        self.assertIn("HTTP 401", str(context.exception))
        self.assertNotIn(TOKEN, str(context.exception))
        self.assertIsNone(context.exception.__cause__)
        self.assertTrue(context.exception.__suppress_context__)

    def test_refused_answer_carries_the_description(self):
        self.server.queue("/sendMessage", 200, {"ok": False, "description": "Bad Request: chat not found"})
        with self.assertRaises(relay.TelegramError) as context:
            self.client.send(OWNER, "hello")
        self.assertIn("chat not found", str(context.exception))

    def test_network_error_never_shows_the_token(self):
        closed = relay.Telegram(TOKEN, "http://127.0.0.1:1")
        with self.assertRaises(relay.TelegramError) as context:
            closed.call("getMe", {}, 5)
        self.assertNotIn(TOKEN, str(context.exception))
        self.assertNotIn(TOKEN, repr(closed))


class WebhookTests(unittest.TestCase):
    def setUp(self):
        self.server = FakeServer()
        self.config = make_config(RELAY_WEBHOOK_URL=self.server.base + "/webhook/test")
        self.telegram = RecordingTelegram()

    def tearDown(self):
        self.server.close()

    def test_payload_reaches_the_webhook(self):
        with captured_log():
            outcome = relay.handle_update(message_update(1, "/status"), self.config, self.telegram)
        self.assertEqual(outcome, "forwarded")
        self.assertEqual(self.server.bodies("/webhook/test"),
                         [{"command": "/status", "from_id": OWNER, "message_id": 10}])

    def test_inactive_workflow_answers_404(self):
        self.server.queue("/webhook/test", 404, {"message": "not registered"})
        with captured_log():
            outcome = relay.handle_update(message_update(2, "/status"), self.config, self.telegram)
        self.assertEqual(outcome, "webhook-refused")

    def test_stopped_engine_is_unreachable(self):
        config = make_config(RELAY_WEBHOOK_URL="http://127.0.0.1:1/webhook/test")
        with captured_log():
            outcome = relay.handle_update(message_update(3, "/status"), config, self.telegram)
        self.assertEqual(outcome, "webhook-unreachable")


class OffsetStoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.store = relay.OffsetStore(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def test_missing_file_means_no_offset(self):
        self.assertIsNone(self.store.load())

    def test_save_then_load_leaves_no_temporary_file(self):
        self.store.save(42)
        self.assertEqual(self.store.load(), 42)
        self.assertEqual(os.listdir(self.directory.name), ["offset"])

    def test_damaged_file_means_no_offset(self):
        for content in ("garbage", "0", "-3", ""):
            with self.subTest(content=content):
                with open(self.store.path, "w", encoding="ascii") as handle:
                    handle.write(content)
                self.assertIsNone(self.store.load())


class PollingTests(unittest.TestCase):
    def setUp(self):
        self.server = FakeServer()
        self.directory = tempfile.TemporaryDirectory()
        self.config = make_config(RELAY_API_BASE=self.server.base, RELAY_POLL_TIMEOUT="0",
                                  STATE_DIRECTORY=self.directory.name)
        self.telegram = relay.Telegram(TOKEN, self.config.api_base)
        self.store = relay.OffsetStore(self.directory.name)

    def tearDown(self):
        self.server.close()
        self.directory.cleanup()

    def test_one_poll_handles_every_update_and_saves_the_offset(self):
        self.server.queue("/getUpdates", 200, {"ok": True, "result": [
            message_update(5, "/status", sender=STRANGER),
            message_update(6, "/status"),
            message_update(7, "hello"),
        ]})
        forward = RecordingForward()
        with captured_log():
            offset = relay.poll_once(self.config, self.telegram, self.store, None, forward)
        self.assertEqual(offset, 8)
        self.assertEqual(self.store.load(), 8)
        self.assertEqual(len(forward.calls), 1)
        self.assertEqual([body["chat_id"] for body in self.server.bodies("/sendMessage")], [OWNER])
        request = self.server.bodies("/getUpdates")[0]
        self.assertNotIn("offset", request)
        self.assertEqual(request["timeout"], 0)
        self.assertEqual(request["allowed_updates"], ["message"])

    def test_next_poll_confirms_with_the_offset(self):
        self.server.queue("/getUpdates", 200, {"ok": True, "result": []})
        with captured_log():
            offset = relay.poll_once(self.config, self.telegram, self.store, 8, RecordingForward())
        self.assertEqual(offset, 8)
        self.assertEqual(self.server.bodies("/getUpdates")[0]["offset"], 8)

    def test_a_crashing_update_does_not_stop_the_others(self):
        self.server.queue("/getUpdates", 200, {"ok": True, "result": [
            message_update(10, "/status"),
            message_update(11, "/status"),
        ]})
        forward = RecordingForward([RuntimeError("boom"), None])
        with captured_log() as log:
            offset = relay.poll_once(self.config, self.telegram, self.store, None, forward)
        self.assertEqual(offset, 12)
        self.assertEqual(len(forward.calls), 2)
        self.assertIn("error on update 10: RuntimeError", log.getvalue())

    def test_unexpected_result_is_an_api_error(self):
        self.server.queue("/getUpdates", 200, {"ok": True, "result": True})
        with self.assertRaises(relay.TelegramError):
            relay.poll_once(self.config, self.telegram, self.store, None, RecordingForward())

    def test_run_resets_the_webhook_and_backs_off_on_errors(self):
        self.store.save(99)
        self.server.queue("/getUpdates", 502, {"ok": False, "description": "Bad Gateway"})
        self.server.queue("/getUpdates", 502, {"ok": False, "description": "Bad Gateway"})
        self.server.queue("/getUpdates", 200, {"ok": True, "result": []})
        sleeps = []
        with captured_log() as log:
            relay.run(self.config, self.telegram, self.store, sleep=sleeps.append, max_cycles=3)
        self.assertEqual(self.server.bodies("/deleteWebhook"), [{"drop_pending_updates": False}])
        self.assertEqual(sleeps, [1, 2])
        self.assertEqual([body["offset"] for body in self.server.bodies("/getUpdates")], [99, 99, 99])
        self.assertNotIn(TOKEN, log.getvalue())


class MainTests(unittest.TestCase):
    def run_main(self, argv, environ):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = relay.main(argv, environ)
        return code, out.getvalue(), err.getvalue()

    def test_check_config_without_credentials(self):
        code, out, _ = self.run_main(["--check-config"], {"RELAY_ALLOWED_USER_ID": str(OWNER), "RELAY_WEBHOOK_URL": WEBHOOK})
        self.assertEqual(code, 0)
        self.assertIn("configuration OK", out)
        self.assertIn("not checked", out)

    def test_check_config_reads_the_token_without_printing_it(self):
        with tempfile.TemporaryDirectory() as directory:
            with open(os.path.join(directory, relay.TOKEN_CREDENTIAL), "w", encoding="utf-8") as handle:
                handle.write(TOKEN)
            environ = {"RELAY_ALLOWED_USER_ID": str(OWNER), "RELAY_WEBHOOK_URL": WEBHOOK,
                       "CREDENTIALS_DIRECTORY": directory}
            code, out, _ = self.run_main(["--check-config"], environ)
        self.assertEqual(code, 0)
        self.assertIn("readable", out)
        self.assertNotIn(TOKEN, out)

    def test_configuration_errors_exit_with_code_2(self):
        code, _, err = self.run_main(["--check-config"], {})
        self.assertEqual(code, relay.EXIT_CONFIG)
        self.assertIn("RELAY_ALLOWED_USER_ID", err)
        code, _, err = self.run_main([], {"RELAY_ALLOWED_USER_ID": str(OWNER), "RELAY_WEBHOOK_URL": WEBHOOK})
        self.assertEqual(code, relay.EXIT_CONFIG)
        self.assertIn("CREDENTIALS_DIRECTORY", err)


class UnitFileTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.settings = {}
        for line in UNIT_FILE.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith(("#", "[")):
                continue
            key, _, value = line.partition("=")
            cls.settings.setdefault(key, []).append(value)
        cls.installer = INSTALLER.read_text(encoding="utf-8")

    def value(self, key):
        self.assertIn(key, self.settings, f"{key}= is missing from the unit")
        return self.settings[key][-1]

    def test_hardening_directives(self):
        expected = {
            "DynamicUser": "yes",
            "NoNewPrivileges": "yes",
            "ProtectSystem": "strict",
            "ProtectHome": "yes",
            "PrivateTmp": "yes",
            "PrivateDevices": "yes",
            "MemoryDenyWriteExecute": "yes",
            "CapabilityBoundingSet": "",
            "Restart": "on-failure",
            "RestartPreventExitStatus": str(relay.EXIT_CONFIG),
        }
        for key, value in expected.items():
            with self.subTest(key=key):
                self.assertEqual(self.value(key), value)

    def test_only_internet_and_local_sockets(self):
        self.assertEqual(self.value("RestrictAddressFamilies").split(), ["AF_INET", "AF_INET6", "AF_UNIX"])

    def test_token_comes_from_a_credential_not_the_environment(self):
        name, _, source = self.value("LoadCredential").partition(":")
        self.assertEqual(name, relay.TOKEN_CREDENTIAL)
        self.assertEqual(source, "/etc/telegram-relay/telegram.token")
        self.assertNotIn("Environment", self.settings)
        self.assertIn("etc/telegram-relay/telegram.token", self.installer)

    def test_paths_match_the_installer(self):
        self.assertTrue(self.value("ExecStart").endswith("/usr/local/lib/telegram-relay/telegram_relay.py"))
        self.assertIn("usr/local/lib/telegram-relay", self.installer)
        self.assertEqual(self.value("EnvironmentFile"), "/etc/telegram-relay/relay.conf")
        self.assertIn("etc/telegram-relay/relay.conf", self.installer)


if __name__ == "__main__":
    unittest.main()
