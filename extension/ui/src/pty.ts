// Client for the extension backend's WebSocket→PTY bridge (see ../vm/main.go).
// Session handshake goes through the extension VM service proxy when available
// (the documented path), falling back to the published localhost port.
import { createDockerDesktopClient } from '@docker/extension-api-client';

const ddClient = createDockerDesktopClient();
const PORT = 53289;

export type PtyCmd = 'vm-ssh' | 'console';

export async function openPtySession(kit: string, cmd: PtyCmd): Promise<string> {
  const body = { kit, cmd };
  try {
    const r: any = await (ddClient.extension.vm?.service as any)?.post('/session', body);
    const tok = r?.token ?? (typeof r === 'string' ? JSON.parse(r)?.token : undefined);
    if (tok) return tok;
  } catch {
    /* fall back to the published port */
  }
  const resp = await fetch(`http://localhost:${PORT}/session`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  if (!resp.ok) throw new Error(`pty session: HTTP ${resp.status}`);
  return (await resp.json()).token as string;
}

export function ptyWsUrl(token: string): string {
  return `ws://localhost:${PORT}/ws?token=${encodeURIComponent(token)}`;
}
