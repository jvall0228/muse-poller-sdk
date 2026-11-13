// Example source adapter: a generic HTTP-JSON list endpoint.
//
// Config (`adapter_options`):
//   base_url   - API root, e.g. "https://api.example.invalid/v1"
//   token_env  - name of the environment variable holding the bearer token
//   self_id    - the bot's own author id (its lines are never queued)
//
// Expected API: GET {base_url}/channels/{channel.id}/items?after=<cursor>&limit=25
// returns a JSON array, newest first, each item having at least
// `id`, `author_id`, `text`, `created_at`.
//
// Select it with `"adapter": "./example-http-adapter.ts"` in the poller config.
import { SourceError } from "./daemon.ts";
import type { Channel, Config, Item, Source } from "./daemon.ts";

export function makeSource(config: Config): Source {
  const opts = config.adapterOptions;
  const baseUrl = String(opts.base_url ?? "").replace(/\/+$/, "");
  const token = process.env[String(opts.token_env ?? "")] ?? "";
  const selfId = opts.self_id;
  return {
    async fetch(channel: Channel, since: string | undefined): Promise<Item[]> {
      let url = `${baseUrl}/channels/${encodeURIComponent(channel.id)}/items?limit=25`;
      if (since) url += `&after=${encodeURIComponent(since)}`;
      let res: Response;
      try {
        res = await fetch(url, {
          headers: { Authorization: `Bearer ${token}` },
          signal: AbortSignal.timeout(config.callTimeoutSecs * 1000),
        });
      } catch (e) {
        throw new SourceError(`request failed: ${(e as Error).message}`);
      }
      // Attach the HTTP status: the daemon decides auth on it, never on text.
      if (!res.ok) throw new SourceError(`HTTP ${res.status}`, res.status);
      const body: unknown = await res.json();
      if (!Array.isArray(body)) throw new SourceError("unexpected non-array response");
      return body as Item[];
    },
    isNew: (item) => item.author_id !== selfId,
    cursorOf: (item) => String(item.id),
    toQueueItem: (channel, item) => ({
      id: item.id,
      channel_id: channel.id,
      channel_name: channel.name,
      author_id: item.author_id,
      text: item.text ?? "",
      created_at: item.created_at,
    }),
  };
}
