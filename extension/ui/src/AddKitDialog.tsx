// "+ Add kit" — slot picker + the two enrolment modes, fully explained.
import { useState } from 'react';
import {
  Button, Card, CardActionArea, CardContent, Chip, Dialog, DialogActions,
  DialogContent, DialogTitle, Stack, ToggleButton, ToggleButtonGroup, Typography,
} from '@mui/material';

export type KitMode = 'auto' | 'manual';

export default function AddKitDialog({ open, kitStates, busy, onClose, onStart }: {
  open: boolean;
  /** slot -> health/state string ('' = container absent) */
  kitStates: Record<string, string>;
  busy: boolean;
  onClose: () => void;
  onStart: (slot: string, mode: KitMode) => void;
}) {
  const [slot, setSlot] = useState('demo');
  const [mode, setMode] = useState<KitMode>('auto');

  const ModeCard = ({ m, title, body }: { m: KitMode; title: string; body: string }) => (
    <Card variant="outlined" sx={{ flex: 1, borderColor: mode === m ? 'primary.main' : 'divider' }}>
      <CardActionArea onClick={() => setMode(m)} sx={{ height: '100%' }}>
        <CardContent>
          <Typography variant="subtitle2">{title}</Typography>
          <Typography variant="body2" color="text.secondary">{body}</Typography>
        </CardContent>
      </CardActionArea>
    </Card>
  );

  return (
    <Dialog open={open} onClose={onClose} maxWidth="sm" fullWidth>
      <DialogTitle>Add a WAF kit</DialogTitle>
      <DialogContent>
        <Typography variant="body2" color="text.secondary" sx={{ mb: 2 }}>
          A kit is a customer-edge WAF VM with its own disk and TPM-backed identity. Pick a slot and
          how to enrol it.
        </Typography>
        <Stack direction="row" spacing={1} alignItems="center" sx={{ mb: 2 }}>
          <ToggleButtonGroup exclusive size="small" value={slot} onChange={(_, v) => v && setSlot(v)}>
            {['demo', 'a', 'b'].map((k) => (
              <ToggleButton key={k} value={k}>kit-{k}</ToggleButton>
            ))}
          </ToggleButtonGroup>
          {kitStates[slot] ? (
            <Chip size="small" color="warning" label={`already running (${kitStates[slot]}) — re-running re-stages it`} />
          ) : (
            <Chip size="small" label="free slot" />
          )}
        </Stack>
        <Stack direction="row" spacing={1.5}>
          <ModeCard m="auto" title="Automated enrolment"
            body="Boots the kit VM, stages it, mints a provisioning token and enrols the WAF instance — all in one go (~3–5 min). Progress streams to the output panel; the instance then appears in the GUI." />
          <ModeCard m="manual" title="Manual demo (in-VM)"
            body="Boots + stages the kit and mints a token, but does NOT enrol. You then run the enrolment inside the VM — the exact customer experience. The next screen shows the token and every command, plus an embedded terminal." />
        </Stack>
      </DialogContent>
      <DialogActions>
        <Button onClick={onClose}>Cancel</Button>
        <Button variant="contained" disabled={busy} onClick={() => onStart(slot, mode)}>
          {mode === 'auto' ? `Enrol kit-${slot} automatically` : `Stage kit-${slot} for manual demo`}
        </Button>
      </DialogActions>
    </Dialog>
  );
}
