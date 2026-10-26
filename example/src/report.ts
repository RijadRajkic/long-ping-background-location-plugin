// Activity log: every plugin event and command result. Kept in memory for the screen and, when REPORT_URL is
// set, POSTed to it as JSON lines ({at, kind, name, ok, payload}), in order, batched, retried while it is down.
import { REPORT_URL } from './config';

export type EntryKind = 'cmd' | 'event' | 'app';

export interface Entry {
  at: string;
  kind: EntryKind;
  name: string;
  ok: boolean;
  payload: unknown;
}

type Listener = (entry: Entry) => void;

const MAX_PENDING = 5000;
const MAX_PER_POST = 200;
const RETRY_MS = 3000;

const listeners = new Set<Listener>();
const pending: string[] = [];
let posting = false;
let retryTimer: ReturnType<typeof setTimeout> | null = null;

export function report(kind: EntryKind, name: string, ok: boolean, payload: unknown): Entry {
  const entry: Entry = { at: new Date().toISOString(), kind, name, ok, payload: payload ?? null };
  listeners.forEach((listener) => listener(entry));
  if (REPORT_URL) {
    pending.push(JSON.stringify(entry));
    // Drop the oldest unsent lines, but never the batch that is in flight.
    if (pending.length > MAX_PENDING) pending.splice(posting ? MAX_PER_POST : 0, pending.length - MAX_PENDING);
    flush();
  }
  return entry;
}

export function onEntry(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

/** Error → plain object with the plugin's error code. */
export function describeError(error: unknown): { code: string; message: string } {
  const e = error as { code?: unknown; message?: unknown } | null;
  return {
    code: typeof e?.code === 'string' ? e.code : 'ERROR',
    message: typeof e?.message === 'string' ? e.message : String(error),
  };
}

async function flush(): Promise<void> {
  if (posting || retryTimer || pending.length === 0 || !REPORT_URL) return;
  posting = true;
  const batch = pending.slice(0, MAX_PER_POST);
  let delivered = false;
  try {
    const response = await fetch(REPORT_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain' },
      body: batch.join('\n'),
    });
    delivered = response.ok;
  } catch {
    delivered = false;
  }
  posting = false;
  if (delivered) {
    pending.splice(0, batch.length);
    if (pending.length) flush();
  } else {
    retryTimer = setTimeout(() => {
      retryTimer = null;
      flush();
    }, RETRY_MS);
  }
}
