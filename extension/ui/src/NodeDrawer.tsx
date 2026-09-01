// Per-VM drill-down: Containers / Stat tabs (scoped `rig ps|stat <node>`)
// plus the Terminal jump (Docker Desktop container view → Exec tab).
import { useEffect, useState } from 'react';
import {
  Box, Button, CircularProgress, Drawer, IconButton, Stack, Tab, Tabs, Typography,
} from '@mui/material';
import { renderAnsi } from './ansi';

export default function NodeDrawer({ node, runCapture, onOpenTerminal, onClose }: {
  /** node name without the rig- prefix (app-1, dns-1, …, kit-a); null = closed */
  node: string | null;
  /** run a launcher verb quietly, resolving with its combined output */
  runCapture: (verb: string, ...args: string[]) => Promise<string>;
  onOpenTerminal: (node: string) => void;
  onClose: () => void;
}) {
  const [tab, setTab] = useState<'ps' | 'stat'>('ps');
  const [out, setOut] = useState<Record<string, string>>({});
  const [loading, setLoading] = useState(false);

  const fetchTab = async (n: string, verb: 'ps' | 'stat', force = false) => {
    const k = `${n}:${verb}`;
    if (!force && out[k]) return;
    setLoading(true);
    try {
      const text = await runCapture(verb, n);
      setOut((o) => ({ ...o, [k]: text }));
    } catch (e: any) {
      setOut((o) => ({ ...o, [k]: `error: ${e?.message ?? e}` }));
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    if (node) { setTab('ps'); setOut({}); void fetchTab(node, 'ps', true); }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [node]);

  const current = node ? out[`${node}:${tab}`] : undefined;

  return (
    <Drawer anchor="bottom" open={!!node} onClose={onClose}
      PaperProps={{ sx: { height: '55vh', display: 'flex', flexDirection: 'column', p: 1.5 } }}>
      <Stack direction="row" alignItems="center" spacing={2}>
        <Typography variant="subtitle1" sx={{ fontFamily: 'monospace' }}>{node}</Typography>
        <Tabs value={tab} onChange={(_, v) => { setTab(v); if (node) void fetchTab(node, v); }} sx={{ minHeight: 32 }}>
          <Tab value="ps" label="Containers" sx={{ minHeight: 32, py: 0 }} />
          <Tab value="stat" label="Stat" sx={{ minHeight: 32, py: 0 }} />
        </Tabs>
        <Button size="small" variant="outlined" disabled={loading}
          onClick={() => node && void fetchTab(node, tab, true)}>Refresh</Button>
        <Box sx={{ flex: 1 }} />
        <Button size="small" variant="contained" onClick={() => node && onOpenTerminal(node)}>
          Terminal (Exec tab, then vm-ssh)
        </Button>
        <IconButton size="small" onClick={onClose} sx={{ fontSize: 13 }}>✕</IconButton>
      </Stack>
      <Box component="pre" sx={{
        flex: 1, minHeight: 0, m: 0, mt: 1, p: 1.5, overflow: 'auto', fontSize: 12, lineHeight: 1.5,
        bgcolor: 'background.default', border: 1, borderColor: 'divider', borderRadius: 1, whiteSpace: 'pre',
      }}>
        {loading && !current ? <CircularProgress size={18} /> : renderAnsi(current ?? '')}
      </Box>
    </Drawer>
  );
}
