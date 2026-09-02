// Corero WAAP Demo Rig — Docker Desktop extension UI.
//
// A thin front end over the rig-launcher container: every button runs the
// bundled host helper `corewaf-rig <profile> <image> <verb>`, which is the
// README's `docker run … rig/launcher <verb>` with ~/.aws and the docker
// socket attached. Status comes straight from the engine (rig-* containers).
// Terminals are Docker Desktop's own: node chips deep-link to the container
// view, whose Exec tab lands in the hypervisor shell (motd + prompt).
import { useCallback, useEffect, useRef, useState } from 'react';
import { createDockerDesktopClient } from '@docker/extension-api-client';
import {
  Alert, Box, Button, Chip, Dialog, DialogActions, DialogContent, DialogTitle,
  Divider, Link, Stack, TextField, Tooltip, Typography,
} from '@mui/material';
import HelpDialog from './HelpDialog';
import AddKitDialog, { type KitMode } from './AddKitDialog';
import DemoKitPanel from './DemoKitPanel';
import { renderAnsi } from './ansi';

const ddClient = createDockerDesktopClient();

// Channel is baked at build time: the stable extension build defaults to the
// :stable launcher (which in turn checks out the stable rig branch).
const CHANNEL = import.meta.env.VITE_LAUNCHER_TAG ?? 'latest';
const DEFAULT_IMAGE =
  `123517950721.dkr.ecr.us-east-1.amazonaws.com/io.corewaf.ghcr/rig/launcher:${CHANNEL}`;
const DEFAULT_PROFILE = 'corewaf-ecr';
const NODES = ['app-1', 'dns-1', 'dns-2', 'gw-1', 'gw-2', 'obs-1'];
const KITS = ['demo', 'a', 'b'];

type Row = { id: string; name: string; state: string; health: string; image: string; ports: string[] };

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
  const [image, setImage] = useState(() => load(`rig.image.${CHANNEL}`, DEFAULT_IMAGE));
  const [guiPortCfg, setGuiPortCfg] = useState(() => load('rig.httpPort', '28080'));
  const [grafanaPortCfg, setGrafanaPortCfg] = useState(() => load('rig.grafanaPort', '23000'));
  const [size, setSize] = useState(() => load('rig.size', 'full'));
  const [rows, setRows] = useState<Row[]>([]);
  const [busy, setBusy] = useState<string | null>(null);
  const [log, setLog] = useState('');
  const [confirm, setConfirm] = useState<null | 'down' | 'reset'>(null);
  const [addKitOpen, setAddKitOpen] = useState(false);
  const [helpOpen, setHelpOpen] = useState(false);
  const [demoKit, setDemoKit] = useState<{ kit: string; token: string } | null>(null);
  const logRef = useRef<HTMLPreElement>(null);

  useEffect(() => save('rig.profile', profile), [profile]);
  useEffect(() => save(`rig.image.${CHANNEL}`, image), [image]);
  useEffect(() => save('rig.httpPort', guiPortCfg), [guiPortCfg]);
  useEffect(() => save('rig.grafanaPort', grafanaPortCfg), [grafanaPortCfg]);
  useEffect(() => save('rig.size', size), [size]);

  const refresh = useCallback(async () => {
    try {
      const list = (await ddClient.docker.listContainers({ all: true, filters: JSON.stringify({ name: ['rig-'] }) })) as any[];
      setRows(
        list
          .map((c) => ({
            id: String(c.Id ?? ''),
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


  // URLs come from the configured ports (container port sniffing was unreliable
  // on Docker Desktop); the fields below are the single source of truth.
  const guiPort = guiPortCfg || '28080';
  const grafanaPort = grafanaPortCfg || '23000';
  const appHealthy = rows.find((r) => r.name === 'rig-app-1')?.health === 'healthy';
  const activeNodes = size === 'minimal' ? NODES.filter((n) => !['dns-2', 'gw-2'].includes(n)) : NODES;
  const infraUp = activeNodes.filter((n) => rows.find((r) => r.name === `rig-${n}`)?.health === 'healthy').length;
  const kitStates = Object.fromEntries(
    KITS.map((k) => [k, rows.find((r) => r.name === `rig-kit-${k}`)?.health || rows.find((r) => r.name === `rig-kit-${k}`)?.state || '']),
  );

  const run = (verb: string, ...args: string[]) => {
    if (busy) return;
    setBusy(verb);
    setLog((l) => `${l}\n$ corewaf-rig ${verb} ${args.join(' ')}\n`);
    let captured = '';
    const envArgs = [`RIG_HTTP_PORT=${guiPortCfg || '28080'}`, `RIG_GRAFANA_PORT=${grafanaPortCfg || '23000'}`, `RIG_SIZE=${size}`];
    ddClient.extension.host?.cli.exec('corewaf-rig', [profile, image, verb, ...envArgs, ...args], {
      stream: {
        onOutput: (d) => {
          captured += d.stdout ?? '';
          if (verb === 'stage') {
            const m = captured.match(/^TOKEN=(\S+)/m);
            if (m) setDemoKit({ kit: args[0] ?? 'demo', token: m[1] });
          }
          setLog((l) => l + (d.stdout ?? '') + (d.stderr ?? ''));
        },
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
  // Jump to the node container in Docker Desktop — its Exec tab is a full
  // interactive terminal; the container shell prints a status motd, then a prompt.
  const openContainer = (name: string) => {
    const r = rows.find((x) => x.name === name);
    if (r?.id) void ddClient.desktopUI.navigate.viewContainer(r.id);
  };

  return (
    <Box sx={{ p: 2, display: 'flex', flexDirection: 'column', gap: 2, height: '100vh', boxSizing: 'border-box' }}>
      <Stack direction="row" alignItems="center" justifyContent="space-between">
        <Box>
          <Typography variant="h3">Corero WAAP Demo Rig</Typography>
          <Typography variant="body2" color="text.secondary">
            Six VMs (QEMU/KVM in containers) + demo kits, driven by the rig-launcher. Needs /dev/kvm (Windows: WSL2 nested virtualization) and an AWS pull profile.
          </Typography>
        </Box>
        <Stack direction="row" spacing={1} alignItems="center">
          <Button size="small" sx={{ height: 32 }} variant="contained" disabled={!appHealthy} onClick={() => open(`http://gui-1.localhost:${guiPort}`)}>
            Open GUI
          </Button>
          <Button size="small" sx={{ height: 32 }} variant="outlined" disabled={rows.find((r) => r.name === 'rig-obs-1')?.health !== 'healthy'} onClick={() => open(`http://grafana.localhost:${grafanaPort}`)}>
            Grafana
          </Button>
          <Tooltip title="Backstage developer portal — a plain container (no VM); first click starts it, then opens it"><span>
            <Button size="small" sx={{ height: 32 }} variant="outlined" disabled={!!busy}
              onClick={() => {
                if (rows.some((r) => r.name === 'rig-backstage' && r.state === 'running')) open('http://localhost:27007');
                else run('portal');
              }}>Backstage</Button>
          </span></Tooltip>
          <Tooltip title="How to use this extension"><span>
            <Button size="small" sx={{ height: 32, minWidth: 36, fontWeight: 700 }} variant="outlined" onClick={() => setHelpOpen(true)} aria-label="help">?</Button>
          </span></Tooltip>
        </Stack>
      </Stack>

      <Stack direction="row" spacing={2} alignItems="center">
        <TextField size="small" label="AWS profile" value={profile} onChange={(e) => setProfile(e.target.value.trim())} sx={{ width: 200 }} />
        <TextField size="small" label="GUI port" value={guiPortCfg} onChange={(e) => setGuiPortCfg(e.target.value.replace(/\D/g, ''))} sx={{ width: 110 }} />
        <TextField size="small" label="Grafana port" value={grafanaPortCfg} onChange={(e) => setGrafanaPortCfg(e.target.value.replace(/\D/g, ''))} sx={{ width: 110 }} />
        <TextField size="small" select SelectProps={{ native: true }} label="System size" value={size} onChange={(e) => setSize(e.target.value)} sx={{ width: 220 }}
          helperText={size === 'minimal' ? 'no dns-2/gw-2, no Backstage — saves 2 VMs' : 'full topology incl. redundancy'}>
          <option value="full">Full (redundancy)</option>
          <option value="minimal">Minimal (saves 2 VMs)</option>
        </TextField>
        <TextField size="small" label="Launcher image" value={image} onChange={(e) => setImage(e.target.value.trim())} sx={{ flex: 1 }} />
      </Stack>

      <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap alignItems="center">
        <Tooltip title="Pull the launcher, refresh the registry login, boot/refresh all six VMs (first boot ≈ 10 min)"><span>
          <Button size="small" sx={{ height: 32 }} variant="contained" disabled={!!busy} onClick={() => run('up')}>Up</Button>
        </span></Tooltip>
        <Tooltip title="Full health checklist, run inside the rig network"><span>
          <Button size="small" sx={{ height: 32 }} variant="outlined" disabled={!!busy || !appHealthy} onClick={() => run('verify')}>Verify</Button>
        </span></Tooltip>
        <Tooltip title="Add a WAAP kit — automated enrolment, or staged for a manual in-VM demo"><span>
          <Button size="small" sx={{ height: 32 }} variant="outlined" disabled={!!busy || !appHealthy} onClick={() => setAddKitOpen(true)}>+ Add kit</Button>
        </span></Tooltip>
        <Tooltip title="Recreate the kit containers with fresh network endpoints — fixes kits gone stale (Docker Desktop endpoint aging). Identities and enrolments persist; tunnels reconnect in ~1 min."><span>
          <Button size="small" sx={{ height: 32 }} variant="outlined"
            disabled={!!busy || !rows.some((r) => r.name.startsWith('rig-kit-'))}
            onClick={() => run('refresh-kits')}>Refresh kits</Button>
        </span></Tooltip>
        <Box sx={{ flex: 1 }} />
        <Tooltip title="Graceful VM shutdown; disks kept"><span>
          <Button size="small" sx={{ height: 32 }} variant="outlined" disabled={!!busy} onClick={() => run('stop')}>Stop</Button>
        </span></Tooltip>
        <Tooltip title="Remove the containers; volumes kept — next Up boots the same VMs"><span>
          <Button size="small" sx={{ height: 32 }} variant="outlined" color="warning" disabled={!!busy} onClick={() => setConfirm('down')}>Down</Button>
        </span></Tooltip>
        <Tooltip title="Wipe EVERYTHING — VM disks, CA, secrets, kit identities"><span>
          <Button size="small" sx={{ height: 32 }} variant="outlined" color="error" disabled={!!busy} onClick={() => setConfirm('reset')}>Reset</Button>
        </span></Tooltip>
      </Stack>

      {demoKit && (
        <DemoKitPanel kit={demoKit.kit} token={demoKit.token}
          onOpenTerminal={() => openContainer(`rig-kit-${demoKit.kit}`)}
          onDismiss={() => setDemoKit(null)} />
      )}

      {busy && <Alert severity="info">Running <b>{busy}</b>… output below.</Alert>}

      <Divider />
      <Box>
        <Stack direction="row" spacing={1} alignItems="baseline">
          <Typography variant="subtitle1">Nodes ({infraUp}/{activeNodes.length} healthy)</Typography>
          <Typography variant="caption" color="text.secondary">— click a node → its terminal (Exec tab): a status printout, then a prompt; <code>vm-ssh</code> enters the VM</Typography>
        </Stack>
        <Stack direction="row" spacing={1} alignItems="center" flexWrap="wrap" useFlexGap sx={{ mt: 0.75 }}>
          {rows.length === 0 && <Typography variant="body2" color="text.secondary">no rig containers — press Up</Typography>}
          {rows.map((r) => (
            <Tooltip key={r.name} title={`${r.image} · ${r.state}${r.ports.length ? ' · ' + r.ports.join(', ') : ''} — click: terminal (Exec tab)`}>
              <Chip label={`❯ ${r.name.replace(/^rig-/, '')}`} clickable color={healthColor(r.health)} variant={r.state === 'running' ? 'filled' : 'outlined'} size="small"
                sx={{ '& .MuiChip-label': { fontFamily: 'inherit' }, cursor: 'pointer' }}
                onClick={() => openContainer(r.name)} />
            </Tooltip>
          ))}
        </Stack>
      </Box>

      <Box component="pre" ref={logRef} sx={{
        flex: 1, minHeight: 200, m: 0, p: 1.5, overflow: 'auto', fontSize: 12, lineHeight: 1.4,
        bgcolor: 'background.default', border: 1, borderColor: 'divider', borderRadius: 1, whiteSpace: 'pre-wrap',
      }}>
        {log ? renderAnsi(log) : 'Output of the last action appears here.'}
      </Box>

      <Typography variant="caption" color="text.secondary">
        Same rig as the curl / <code>docker run</code> paths — interchangeable.{' '}
        <Link component="button" variant="caption" onClick={() => open('https://github.com/ext-corero/corewaf-demo-rig#readme')}>README</Link>
      </Typography>

      <Dialog open={!!confirm} onClose={() => setConfirm(null)}>
        <DialogTitle>{confirm === 'reset' ? 'Are you sure? This wipes the whole rig.' : 'Take the rig down?'}</DialogTitle>
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
            {confirm === 'reset' ? 'Yes, reset everything' : 'Down'}
          </Button>
        </DialogActions>
      </Dialog>

      <HelpDialog open={helpOpen} onClose={() => setHelpOpen(false)}
        onOpenReadme={() => open('https://github.com/ext-corero/corewaf-demo-rig#readme')} />
      <AddKitDialog open={addKitOpen} kitStates={kitStates} busy={!!busy}
        onClose={() => setAddKitOpen(false)}
        onStart={(slot: string, mode: KitMode) => {
          setAddKitOpen(false);
          setDemoKit(null);
          run(mode === 'auto' ? 'kit' : 'stage', slot);
        }} />
    </Box>
  );
}
