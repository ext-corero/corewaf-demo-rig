// CoreWAF Demo Rig — Docker Desktop extension UI.
//
// A thin front end over the rig-launcher container: every button runs the
// bundled host helper `corewaf-rig <profile> <image> <verb>`, which is the
// README's `docker run … rig/launcher <verb>` with ~/.aws and the docker
// socket attached. Status comes straight from the engine (rig-* containers).
import { useCallback, useEffect, useRef, useState } from 'react';
import { createDockerDesktopClient } from '@docker/extension-api-client';
import {
  Alert, Box, Button, Chip, Dialog, DialogActions, DialogContent, DialogTitle,
  Divider, FormControl, InputLabel, Link, MenuItem, Select, Stack, TextField,
  Tooltip, Typography,
} from '@mui/material';

const ddClient = createDockerDesktopClient();

const DEFAULT_IMAGE =
  '123517950721.dkr.ecr.us-east-1.amazonaws.com/io.corewaf.ghcr/rig/launcher:latest';
const DEFAULT_PROFILE = 'corewaf-ecr';
const NODES = ['app-1', 'dns-1', 'dns-2', 'gw-1', 'gw-2', 'obs-1'];
const KITS = ['demo', 'a', 'b'];

type Row = { name: string; state: string; health: string; image: string; ports: string[] };

function load(key: string, fallback: string): string {
  try { return localStorage.getItem(key) || fallback; } catch { return fallback; }
}
function save(key: string, v: string) { try { localStorage.setItem(key, v); } catch { /* ignore */ } }

function healthColor(h: string): 'success' | 'warning' | 'error' | 'default' {
  if (h === 'healthy') return 'success';
  if (h === 'starting') return 'warning';
  if (h === 'unhealthy') return 'error';
  return 'default';
}

export default function App() {
  const [profile, setProfile] = useState(() => load('rig.profile', DEFAULT_PROFILE));
  const [image, setImage] = useState(() => load('rig.image', DEFAULT_IMAGE));
  const [kit, setKit] = useState('demo');
  const [rows, setRows] = useState<Row[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [log, setLog] = useState('');
  const [confirm, setConfirm] = useState<null | 'down' | 'reset'>(null);
  const logRef = useRef<HTMLPreElement>(null);

  useEffect(() => save('rig.profile', profile), [profile]);
  useEffect(() => save('rig.image', image), [image]);

  const refresh = useCallback(async () => {
    try {
      const list = (await ddClient.docker.listContainers({ all: true, filters: JSON.stringify({ name: ['rig-'] }) })) as any[];
      setRows(
        list
          .map((c) => ({
            name: String(c.Names?.[0] ?? '').replace(/^\//, ''),
            state: String(c.State ?? ''),
            health: (String(c.Status ?? '').match(/\((healthy|unhealthy|health: starting)\)/)?.[1] ?? '').replace('health: ', ''),
            image: String(c.Image ?? '').replace(/^.*\//, ''),
            ports: (c.Ports ?? [])
              .filter((p: any) => p.PublicPort)
              .map((p: any) => `${p.PublicPort}→${p.PrivatePort}`),
          }))
          .filter((r) => r.name.startsWith('rig-') && r.name !== 'rig-init')
          .sort((a, b) => a.name.localeCompare(b.name)),
      );
    } catch (e: any) {
      setLog((l) => l + `\n[status] ${e?.message ?? e}\n`);
    }
  }, []);

  useEffect(() => {
    refresh();
    const t = setInterval(refresh, 5000);
    return () => clearInterval(t);
  }, [refresh]);

  useEffect(() => { logRef.current?.scrollTo({ top: logRef.current.scrollHeight }); }, [log]);

  const hostPort = (node: string, guestPort: number): number | null => {
    const r = rows.find((x) => x.name === `rig-${node}`);
    const m = r?.ports.map((p) => p.split('→').map(Number)).find(([, g]) => g === guestPort);
    return m ? m[0] : null;
  };
  const guiPort = hostPort('app-1', 8080);
  const grafanaPort = hostPort('obs-1', 3000);
  const appHealthy = rows.find((r) => r.name === 'rig-app-1')?.health === 'healthy';
  const infraUp = NODES.filter((n) => rows.find((r) => r.name === `rig-${n}`)?.health === 'healthy').length;

  const run = (verb: string, ...args: string[]) => {
    if (busy) return;
    setBusy(verb);
    setLog((l) => `${l}\n$ corewaf-rig ${verb} ${args.join(' ')}\n`);
    ddClient.extension.host?.cli.exec('corewaf-rig', [profile, image, verb, ...args], {
      stream: {
        onOutput: (d) => setLog((l) => l + (d.stdout ?? '') + (d.stderr ?? '')),
        onError: (e) => setLog((l) => `${l}\n[error] ${e}\n`),
        onClose: (code) => {
          setLog((l) => `${l}\n[${verb} exited ${code}]\n`);
          setBusy(null);
          refresh();
        },
        splitOutputLines: false,
      },
    });
  };

  const open = (url: string) => ddClient.host.openExternal(url);

  return (
    <Box sx={{ p: 2, display: 'flex', flexDirection: 'column', gap: 2, height: '100vh', boxSizing: 'border-box' }}>
      <Stack direction="row" alignItems="center" justifyContent="space-between">
        <Box>
          <Typography variant="h3">CoreWAF Demo Rig</Typography>
          <Typography variant="body2" color="text.secondary">
            Six VMs (QEMU/KVM in containers) + demo kits, driven by the rig-launcher. Needs /dev/kvm (Windows: WSL2 nested virtualization) and an AWS pull profile.
          </Typography>
        </Box>
        <Stack direction="row" spacing={1}>
          <Button variant="contained" disabled={!appHealthy || !guiPort} onClick={() => open(`http://gui-1.localhost:${guiPort}`)}>
            Open GUI
          </Button>
          <Button variant="outlined" disabled={!grafanaPort} onClick={() => open(`http://grafana.localhost:${grafanaPort}`)}>
            Grafana
          </Button>
        </Stack>
      </Stack>

      <Stack direction="row" spacing={2} alignItems="center">
        <TextField size="small" label="AWS profile" value={profile} onChange={(e) => setProfile(e.target.value.trim())} sx={{ width: 200 }} />
        <TextField size="small" label="Launcher image" value={image} onChange={(e) => setImage(e.target.value.trim())} sx={{ flex: 1 }} />
      </Stack>

      <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap>
        <Tooltip title="Pull the launcher, refresh the registry login, boot/refresh all six VMs (first boot ≈ 10 min)">
          <span><Button variant="contained" disabled={!!busy} onClick={() => run('up')}>Up</Button></span>
        </Tooltip>
        <Button variant="outlined" disabled={!!busy || !appHealthy} onClick={() => run('verify')}>Verify</Button>
        <FormControl size="small" sx={{ minWidth: 110 }}>
          <InputLabel>Kit</InputLabel>
          <Select label="Kit" value={kit} onChange={(e) => setKit(String(e.target.value))}>
            {KITS.map((k) => <MenuItem key={k} value={k}>kit-{k}</MenuItem>)}
          </Select>
        </FormControl>
        <Tooltip title="Boot the kit VM, mint a token and enrol a WAF instance">
          <span><Button variant="outlined" disabled={!!busy || !appHealthy} onClick={() => run('kit', kit)}>Enrol kit</Button></span>
        </Tooltip>
        <Box sx={{ flex: 1 }} />
        <Button variant="outlined" disabled={!!busy} onClick={() => run('stop')}>Stop</Button>
        <Button variant="outlined" color="warning" disabled={!!busy} onClick={() => setConfirm('down')}>Down</Button>
        <Button variant="outlined" color="error" disabled={!!busy} onClick={() => setConfirm('reset')}>Reset</Button>
      </Stack>

      {busy && <Alert severity="info">Running <b>{busy}</b>… output below.</Alert>}

      <Divider />
      <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap>
        <Typography variant="subtitle1">Nodes ({infraUp}/{NODES.length} healthy)</Typography>
        {rows.length === 0 && <Typography variant="body2" color="text.secondary">no rig containers — press Up</Typography>}
        {rows.map((r) => (
          <Tooltip key={r.name} title={`${r.image} · ${r.state}${r.ports.length ? ' · ' + r.ports.join(', ') : ''}`}>
            <Chip label={r.name.replace(/^rig-/, '')} color={healthColor(r.health)} variant={r.state === 'running' ? 'filled' : 'outlined'} size="small" />
          </Tooltip>
        ))}
      </Stack>

      <Box component="pre" ref={logRef} sx={{
        flex: 1, minHeight: 200, m: 0, p: 1.5, overflow: 'auto', fontSize: 12, lineHeight: 1.4,
        bgcolor: 'background.default', border: 1, borderColor: 'divider', borderRadius: 1, whiteSpace: 'pre-wrap',
      }}>
        {log || 'Output of the last action appears here.'}
      </Box>

      <Typography variant="caption" color="text.secondary">
        Same rig as the curl / <code>docker run</code> paths — interchangeable.{' '}
        <Link component="button" variant="caption" onClick={() => open('https://github.com/ext-corero/corewaf-demo-rig#readme')}>README</Link>
      </Typography>

      <Dialog open={!!confirm} onClose={() => setConfirm(null)}>
        <DialogTitle>{confirm === 'reset' ? 'Reset the rig?' : 'Take the rig down?'}</DialogTitle>
        <DialogContent>
          <Typography variant="body2">
            {confirm === 'reset'
              ? 'Removes every rig container AND its volumes (VM disks, CA, secrets, enrolled kits). The next Up is a cold start (~10 min) and kits get new identities.'
              : 'Removes the rig containers; VM disks and secrets are kept, so the next Up boots the same VMs.'}
          </Typography>
        </DialogContent>
        <DialogActions>
          <Button onClick={() => setConfirm(null)}>Cancel</Button>
          <Button color={confirm === 'reset' ? 'error' : 'warning'} variant="contained" onClick={() => { const v = confirm!; setConfirm(null); run(v); }}>
            {confirm === 'reset' ? 'Reset' : 'Down'}
          </Button>
        </DialogActions>
      </Dialog>
    </Box>
  );
}
