// Embedded terminal (xterm.js) over the extension backend's PTY bridge.
import { useEffect, useRef } from 'react';
import { Drawer, IconButton, Stack, Typography } from '@mui/material';
import { Terminal } from '@xterm/xterm';
import { FitAddon } from '@xterm/addon-fit';
import '@xterm/xterm/css/xterm.css';
import { openPtySession, ptyWsUrl, type PtyCmd } from './pty';

export default function TerminalDrawer({
  target, onClose,
}: {
  /** null = closed; otherwise which kit + how to attach */
  target: { kit: string; cmd: PtyCmd } | null;
  onClose: () => void;
}) {
  const holder = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!target || !holder.current) return;
    const term = new Terminal({ fontSize: 13, cursorBlink: true, convertEol: false });
    const fit = new FitAddon();
    term.loadAddon(fit);
    term.open(holder.current);
    fit.fit();
    term.writeln(`Connecting to rig-kit-${target.kit} (${target.cmd})…`);

    let ws: WebSocket | null = null;
    let closed = false;
    const resize = () => {
      fit.fit();
      ws?.readyState === WebSocket.OPEN &&
        ws.send(JSON.stringify({ resize: { cols: term.cols, rows: term.rows } }));
    };
    const ro = new ResizeObserver(resize);
    ro.observe(holder.current);

    (async () => {
      try {
        const token = await openPtySession(target.kit, target.cmd);
        if (closed) return;
        ws = new WebSocket(ptyWsUrl(token));
        ws.binaryType = 'arraybuffer';
        ws.onopen = () => { term.focus(); resize(); };
        ws.onmessage = (ev) =>
          term.write(typeof ev.data === 'string' ? ev.data : new Uint8Array(ev.data));
        ws.onclose = () => term.writeln('\r\n[session closed]');
        ws.onerror = () => term.writeln('\r\n[connection error — is the extension backend running?]');
        term.onData((d) => ws?.readyState === WebSocket.OPEN && ws.send(d));
      } catch (e: any) {
        term.writeln(`\r\n[${e?.message ?? e}]`);
      }
    })();

    return () => { closed = true; ro.disconnect(); ws?.close(); term.dispose(); };
  }, [target]);

  return (
    <Drawer anchor="bottom" open={!!target} onClose={onClose} PaperProps={{ sx: { height: '55vh', p: 1 } }}>
      <Stack direction="row" alignItems="center" justifyContent="space-between" sx={{ px: 1 }}>
        <Typography variant="subtitle2">
          rig-kit-{target?.kit} — {target?.cmd === 'console' ? 'serial console (login alpine / alpine)' : 'ssh'}
        </Typography>
        <IconButton size="small" onClick={onClose} aria-label="close terminal" sx={{ fontSize: 13 }}>✕</IconButton>
      </Stack>
      <div ref={holder} style={{ flex: 1, minHeight: 0, padding: 4 }} />
    </Drawer>
  );
}
