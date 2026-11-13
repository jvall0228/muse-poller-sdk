// In-memory source adapter for the daemon tests.
import { SourceError } from "../../local-subagent-poller/templates/daemon.ts";
import type { Channel, Config, Item, Source } from "../../local-subagent-poller/templates/daemon.ts";

export class FakeSource implements Source {
  items: Record<string, Item[]> = {}; // oldest first
  errors: Record<string, Error> = {}; // persistent until recovered
  calls: Array<[string, string | undefined]> = [];
  private seq = 0;
  constructor(public selfId = "bot") {}

  push(channelId: string, text: string, author = "alice"): Item {
    const item: Item = { id: String(++this.seq), author_id: author, text };
    (this.items[channelId] ??= []).push(item);
    return item;
  }
  fail(channelId: string, status: number | undefined, message = "boom"): void {
    this.errors[channelId] = new SourceError(message, status);
  }
  recover(channelId: string): void {
    delete this.errors[channelId];
  }

  async fetch(channel: Channel, since: string | undefined): Promise<Item[]> {
    this.calls.push([channel.id, since]);
    const err = this.errors[channel.id];
    if (err) throw err;
    let items = this.items[channel.id] ?? [];
    items = since === undefined ? items.slice(-10) : items.filter((i) => Number(i.id) > Number(since));
    return [...items].reverse();
  }
  isNew(item: Item): boolean {
    return item.author_id !== this.selfId;
  }
  cursorOf(item: Item): string {
    return String(item.id);
  }
  toQueueItem(channel: Channel, item: Item): Item {
    return { id: item.id, channel_id: channel.id, channel_name: channel.name,
      author_id: item.author_id, text: item.text };
  }
}

export function makeSource(config: Config): Source {
  return new FakeSource(String(config.adapterOptions.self_id ?? "bot"));
}
