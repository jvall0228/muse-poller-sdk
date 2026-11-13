"""Example source adapter: a generic HTTP-JSON list endpoint.

Config (`adapter_options`):
  base_url   - API root, e.g. "https://api.example.invalid/v1"
  token_env  - name of the environment variable holding the bearer token
  self_id    - the bot's own author id (its lines are never queued)

Expected API: GET {base_url}/channels/{channel.id}/items?after=<cursor>&limit=25
returns a JSON array, newest first, each item having at least
`id`, `author_id`, `text`, `created_at`.

Select it with `"adapter": "example_http_adapter"` in the poller config.
"""
import json
import os
import urllib.error
import urllib.request
from typing import Any

from daemon import Channel, Config, SourceError


class HttpJsonSource:
    def __init__(self, config: Config):
        opts = config.adapter_options
        self.base_url = str(opts["base_url"]).rstrip("/")
        self.token = os.environ.get(str(opts.get("token_env", "")), "")
        self.self_id = opts.get("self_id")
        self.timeout = config.call_timeout_secs

    def fetch(self, channel: Channel, since: str | None) -> list[dict[str, Any]]:
        url = f"{self.base_url}/channels/{channel.id}/items?limit=25"
        if since:
            url += f"&after={since}"
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.token}"})
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                body = json.load(resp)
        except urllib.error.HTTPError as e:
            raise SourceError(f"HTTP {e.code}", status=e.code) from e
        except (urllib.error.URLError, TimeoutError) as e:
            raise SourceError(f"request failed: {e}") from e
        if not isinstance(body, list):
            raise SourceError("unexpected non-array response")
        return body

    def is_new(self, item: dict[str, Any], since: str | None) -> bool:
        return item.get("author_id") != self.self_id

    def cursor_of(self, item: dict[str, Any]) -> str:
        return str(item["id"])

    def to_queue_item(self, channel: Channel, item: dict[str, Any]) -> dict[str, Any]:
        return {
            "id": item["id"],
            "channel_id": channel.id,
            "channel_name": channel.name,
            "author_id": item.get("author_id"),
            "text": item.get("text", ""),
            "created_at": item.get("created_at"),
        }


def make_source(config: Config) -> HttpJsonSource:
    return HttpJsonSource(config)
