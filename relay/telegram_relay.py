#!/usr/bin/env python3
"""Telegram relay: long polling in, one local webhook out.

Generic version of the relay that runs on node-b. The workflow engine (n8n)
listens on 127.0.0.1 only, so Telegram cannot push messages to it with a
webhook. The relay does the opposite: it opens an outbound connection to the
Telegram Bot API (long polling), keeps only the known commands of the single
allowed user, and posts them to the local webhook. No inbound port is opened.

Every value that depends on the installation comes from the environment
(systemd EnvironmentFile=), and the bot token comes from a systemd credential
(LoadCredential=), never from the code, the environment or the logs:

    RELAY_ALLOWED_USER_ID   numeric Telegram user ID allowed to use the bot (required)
    RELAY_WEBHOOK_URL       local webhook, loopback only, for example
                            http://127.0.0.1:5678/webhook/<WEBHOOK_PATH> (required)
    RELAY_COMMANDS          commands to forward, separated by spaces (default: /status)
    RELAY_POLL_TIMEOUT      long polling timeout in seconds, 0 to 50 (default: 50)
    RELAY_API_BASE          Bot API base URL (default: https://api.telegram.org)
    CREDENTIALS_DIRECTORY   set by systemd; must contain the telegram.token file
    STATE_DIRECTORY         set by systemd; the update offset is kept there

Python standard library only: nothing to install. See docs/relay/README.md.
"""

import argparse
import collections
import ipaddress
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_API_BASE = "https://api.telegram.org"
DEFAULT_COMMANDS = ("/status",)
DEFAULT_POLL_TIMEOUT = 50
TOKEN_CREDENTIAL = "telegram.token"
COMMAND_PATTERN = re.compile(r"^/[a-z0-9_]{1,32}$")
USER_ID_PATTERN = re.compile(r"^[1-9][0-9]{0,15}$")
TOKEN_PATTERN = re.compile(r"^[0-9]+:[A-Za-z0-9_-]+$")
HTTP_TIMEOUT = 15

# Exit code for a configuration error. The systemd unit lists it in
# RestartPreventExitStatus=, so a wrong setting does not cause a restart loop.
EXIT_CONFIG = 2

Config = collections.namedtuple(
    "Config",
    "allowed_user_id webhook_url commands api_base poll_timeout state_dir help_text",
)


class ConfigError(Exception):
    """A setting is missing or unsafe. The message never contains a secret."""


class TelegramError(Exception):
    """A Bot API call failed. The message never contains the token."""


def log(message):
    # Under systemd, stdout goes to the journal: journalctl -u telegram-relay
    print(message, flush=True)


def is_loopback_host(host):
    if not host:
        return False
    if host.lower() == "localhost":
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def _required(environ, name):
    value = environ.get(name, "").strip()
    if not value:
        raise ConfigError(f"{name} is not set")
    return value


def load_config(environ):
    """Read and validate the settings. Raises ConfigError on the first problem."""
    raw_id = _required(environ, "RELAY_ALLOWED_USER_ID")
    if not USER_ID_PATTERN.match(raw_id):
        raise ConfigError("RELAY_ALLOWED_USER_ID must be the numeric Telegram user ID")

    webhook_url = _required(environ, "RELAY_WEBHOOK_URL")
    parts = urllib.parse.urlsplit(webhook_url)
    if parts.scheme not in ("http", "https") or not is_loopback_host(parts.hostname):
        # The relay must never forward commands to another machine.
        raise ConfigError(
            "RELAY_WEBHOOK_URL must be an http(s) URL on the loopback interface, "
            "for example http://127.0.0.1:5678/webhook/<WEBHOOK_PATH>"
        )

    raw_commands = environ.get("RELAY_COMMANDS", "").replace(",", " ").split()
    commands = tuple(command.lower() for command in raw_commands) or DEFAULT_COMMANDS
    for command in commands:
        if not COMMAND_PATTERN.match(command):
            raise ConfigError(
                f"RELAY_COMMANDS: {command!r} is not a bot command "
                "(a slash, then up to 32 letters, digits or underscores)"
            )

    api_base = environ.get("RELAY_API_BASE", "").strip().rstrip("/") or DEFAULT_API_BASE
    parts = urllib.parse.urlsplit(api_base)
    secure = parts.scheme == "https" and bool(parts.hostname)
    local = parts.scheme == "http" and is_loopback_host(parts.hostname)
    if not (secure or local):
        # The token travels in the URL path: plain http is accepted on loopback only (tests).
        raise ConfigError("RELAY_API_BASE must use https (plain http only on loopback, for tests)")

    raw_timeout = environ.get("RELAY_POLL_TIMEOUT", "").strip() or str(DEFAULT_POLL_TIMEOUT)
    if not re.fullmatch(r"[0-9]{1,2}", raw_timeout) or int(raw_timeout) > 50:
        raise ConfigError("RELAY_POLL_TIMEOUT must be a number of seconds from 0 to 50")

    # systemd joins several state directories with ":"; the relay uses the first one.
    state_dir = environ.get("STATE_DIRECTORY", "").split(":")[0] or "."

    help_text = "Available commands:\n" + "\n".join(commands)
    return Config(
        allowed_user_id=int(raw_id),
        webhook_url=webhook_url,
        commands=commands,
        api_base=api_base,
        poll_timeout=int(raw_timeout),
        state_dir=state_dir,
        help_text=help_text,
    )


def read_token(environ):
    """Read the bot token from the systemd credential directory."""
    directory = environ.get("CREDENTIALS_DIRECTORY", "")
    if not directory:
        raise ConfigError(
            "CREDENTIALS_DIRECTORY is not set: start the relay with systemd (LoadCredential=)"
        )
    try:
        with open(os.path.join(directory, TOKEN_CREDENTIAL), encoding="utf-8") as handle:
            token = handle.read().strip()
    except (OSError, ValueError):
        raise ConfigError(f"cannot read the {TOKEN_CREDENTIAL} credential") from None
    if not token:
        raise ConfigError(f"the {TOKEN_CREDENTIAL} credential is empty")
    if not TOKEN_PATTERN.match(token):
        # Also stops a token with a slash or a space from changing the API URL.
        raise ConfigError(f"the {TOKEN_CREDENTIAL} credential does not look like a bot token")
    return token


class Telegram:
    """Minimal Bot API client. The token is only used to build the request URL."""

    def __init__(self, token, api_base=DEFAULT_API_BASE):
        self._token = token
        self._api_base = api_base

    def __repr__(self):
        return "Telegram(<token hidden>)"

    def call(self, method, params, timeout):
        url = f"{self._api_base}/bot{self._token}/{method}"
        request = urllib.request.Request(
            url,
            data=json.dumps(params).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        # "from None" cuts the exception chain: no traceback can show the URL,
        # so none can show the token.
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            raise TelegramError(f"{method}: HTTP {error.code}") from None
        except (urllib.error.URLError, OSError, ValueError) as error:
            raise TelegramError(f"{method}: network or response error ({type(error).__name__})") from None
        if not isinstance(result, dict) or not result.get("ok"):
            description = result.get("description") if isinstance(result, dict) else None
            raise TelegramError(f"{method}: {description or 'request refused'}")
        return result.get("result")

    def send(self, chat_id, text):
        self.call("sendMessage", {"chat_id": chat_id, "text": text}, HTTP_TIMEOUT)


class OffsetStore:
    """Keeps the next update offset on disk, so a restart does not replay old messages."""

    def __init__(self, directory):
        self.path = os.path.join(directory, "offset")

    def load(self):
        try:
            with open(self.path, encoding="ascii") as handle:
                value = int(handle.read().strip())
        except (OSError, ValueError):
            return None
        return value if value > 0 else None

    def save(self, offset):
        temporary = self.path + ".tmp"
        with open(temporary, "w", encoding="ascii") as handle:
            handle.write(str(offset))
        os.replace(temporary, self.path)  # atomic: the file is never half written


def _as_dict(value):
    return value if isinstance(value, dict) else {}


def parse_command(text):
    """'/Status@SomeBot now' -> '/status'. Empty string when there is no text."""
    words = text.split() if isinstance(text, str) else []
    if not words:
        return ""
    return words[0].split("@", 1)[0].lower()


def is_authorized(message, allowed_user_id):
    """Filter 1: the allowed user, in a private chat with the bot. Nothing else."""
    sender = _as_dict(message.get("from")).get("id")
    chat = _as_dict(message.get("chat"))
    return (
        type(sender) is int
        and sender == allowed_user_id
        and chat.get("type") == "private"
        and chat.get("id") == allowed_user_id
    )


def forward_to_webhook(url, payload, timeout=HTTP_TIMEOUT):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.status


def handle_update(update, config, telegram, forward=forward_to_webhook):
    """Handle one update and return what happened (used by the tests)."""
    message = update.get("message")
    if not isinstance(message, dict):
        log(f"ignored: update {update.get('update_id')!r} has no message")
        return "ignored"

    if not is_authorized(message, config.allowed_user_id):
        # No answer at all: a stranger learns nothing about the bot.
        # Only the numeric sender ID and the chat type are logged, never the text.
        sender = _as_dict(message.get("from")).get("id")
        chat_type = _as_dict(message.get("chat")).get("type")
        log(f"rejected: sender={sender!r} chat={chat_type!r}")
        return "rejected"

    command = parse_command(message.get("text"))
    if command not in config.commands:
        # Filter 2: free text and unknown commands never reach the workflow engine.
        telegram.send(config.allowed_user_id, config.help_text)
        return "help"

    payload = {
        "command": command,
        "from_id": config.allowed_user_id,
        "message_id": message.get("message_id"),
    }
    try:
        status = forward(config.webhook_url, payload)
    except urllib.error.HTTPError as error:
        # 404 usually means the workflow is inactive or its webhook path changed.
        log(f"webhook refused {command}: HTTP {error.code}")
        telegram.send(
            config.allowed_user_id,
            f"The workflow refused the request (HTTP {error.code}). Is it active?",
        )
        return "webhook-refused"
    except (urllib.error.URLError, OSError) as error:
        log(f"webhook unreachable: {type(error).__name__}")
        telegram.send(config.allowed_user_id, "The workflow engine is unreachable on this node.")
        return "webhook-unreachable"
    log(f"{command} forwarded (HTTP {status})")
    return "forwarded"


def poll_once(config, telegram, store, offset, forward=forward_to_webhook):
    """One getUpdates call; handle every update; return the next offset."""
    params = {"timeout": config.poll_timeout, "allowed_updates": ["message"]}
    if offset is not None:
        params["offset"] = offset
    updates = telegram.call("getUpdates", params, config.poll_timeout + HTTP_TIMEOUT)
    for update in updates or []:
        update_id = _as_dict(update).get("update_id")
        if type(update_id) is not int:
            log("ignored: update without a numeric update_id")
            continue
        # Move the offset forward BEFORE handling the update: an update that
        # crashes the handler is confirmed anyway and never replayed in a loop.
        offset = update_id + 1
        store.save(offset)
        try:
            handle_update(update, config, telegram, forward)
        except Exception as error:  # one bad update must never stop the relay
            log(f"error on update {update_id}: {type(error).__name__}")
    return offset


def run(config, telegram, store, sleep=time.sleep, max_cycles=None):
    # getUpdates fails (HTTP 409) while a webhook is registered for the bot,
    # for example after a test of a webhook-based trigger. Go back to polling,
    # and keep the pending messages (drop_pending_updates=False).
    try:
        telegram.call("deleteWebhook", {"drop_pending_updates": False}, HTTP_TIMEOUT)
    except TelegramError as error:
        log(f"deleteWebhook: {error}")

    offset = store.load()
    log(f"relay started, offset={offset}, commands={' '.join(config.commands)}")
    pause = 1
    cycles = 0
    while max_cycles is None or cycles < max_cycles:
        cycles += 1
        try:
            offset = poll_once(config, telegram, store, offset)
            pause = 1
        except TelegramError as error:
            # Network cut or Bot API unavailable: retry with a growing delay, up to 60 s.
            log(f"{error}; retrying in {pause} s")
            sleep(pause)
            pause = min(pause * 2, 60)
    return offset


def main(argv=None, environ=None):
    parser = argparse.ArgumentParser(
        description="Relay Telegram bot commands to a local webhook (long polling, no inbound port)."
    )
    parser.add_argument(
        "--check-config",
        action="store_true",
        help="validate the settings (and the token credential when CREDENTIALS_DIRECTORY is set), then exit",
    )
    args = parser.parse_args(argv)
    environ = os.environ if environ is None else environ

    try:
        config = load_config(environ)
        token = read_token(environ) if (not args.check_config or environ.get("CREDENTIALS_DIRECTORY")) else None
    except ConfigError as error:
        print(f"configuration error: {error}", file=sys.stderr)
        return EXIT_CONFIG

    if args.check_config:
        print("configuration OK")
        print(f"  webhook     : {config.webhook_url}")
        print(f"  commands    : {' '.join(config.commands)}")
        print(f"  poll timeout: {config.poll_timeout} s")
        print(f"  token       : {'readable' if token else 'not checked (CREDENTIALS_DIRECTORY not set)'}")
        return 0

    run(config, Telegram(token, config.api_base), OffsetStore(config.state_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
