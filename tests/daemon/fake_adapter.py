"""In-memory source adapter for the daemon tests."""
from __future__ import annotations

from typing import Any

from daemon import Channel, Config, SourceError


class FakeSource:
    def __init__(self, self_id: str = "bot") -> None:
        self.self_id = self_id
        self.items: dict[str, list[dict[str, Any]]] = {}  # oldest first
        self.errors: dict[str, Exception] = {}  # persistent until cleared
        self.calls: list[tuple[str, str | None]] = []
        self._seq = 0

    def push(self, channel_id: str, text: str, author: str = "alice") -> dict[str, Any]:
        self._seq += 1
        item = {"id": str(self._seq), "author_id": author, "text": text}
        self.items.setdefault(channel_id, []).append(item)
        return item

    def fail(self, channel_id: str, status: int | None, message: str = "boom") -> None:
        self.errors[channel_id] = SourceError(message, status=status)

    def recover(self, channel_id: str) -> None:
        self.errors.pop(channel_id, None)

    # --- Source interface ---
    def fetch(self, channel: Channel, since: str | None) -> list[dict[str, Any]]:
        self.calls.append((channel.id, since))
        if channel.id in self.errors:
            raise self.errors[channel.id]
        items = self.items.get(channel.id, [])
        if since is not None:
            items = [i for i in items if int(i["id"]) > int(since)]
        else:
            items = items[-10:]
        return list(reversed(items))

    def is_new(self, item: dict[str, Any], since: str | None) -> bool:
        return item["author_id"] != self.self_id

    def cursor_of(self, item: dict[str, Any]) -> str:
        return item["id"]

    def to_queue_item(self, channel: Channel, item: dict[str, Any]) -> dict[str, Any]:
        return {"id": item["id"], "channel_id": channel.id, "channel_name": channel.name,
                "author_id": item["author_id"], "text": item["text"]}


def make_source(config: Config) -> FakeSource:
    return FakeSource(str(config.adapter_options.get("self_id", "bot")))
