// Post-`stage` result card: the minted token + the exact in-VM enrolment
// commands (docs/demo-kit.md), each copyable, and the embedded terminal.
import { Alert, Button, IconButton, Stack, Tooltip, Typography } from '@mui/material';

function CopyRow({ label, value }: { label: string; value: string }) {
  return (
    <Stack direction="row" spacing={1} alignItems="center">
      <Typography variant="caption" color="text.secondary" sx={{ width: 90, flexShrink: 0 }}>{label}</Typography>
      <Typography component="code" sx={{ fontSize: 12, fontFamily: 'monospace', overflowX: 'auto', whiteSpace: 'nowrap', flex: 1 }}>
        {value}
      </Typography>
      <Tooltip title="Copy">
        <IconButton size="small" onClick={() => navigator.clipboard.writeText(value)} sx={{ fontSize: 13 }}>⧉</IconButton>
      </Tooltip>
    </Stack>
  );
}

export default function DemoKitPanel({ kit, token, onOpenTerminal, onDismiss }: {
  kit: string; token: string;
  onOpenTerminal: () => void; onDismiss: () => void;
}) {
  const bootstrap = `NO_UP=1 TOKEN=${token} bash <(curl -fsSL https://raw.githubusercontent.com/ext-corero/corewaf-starter-kit/main/bootstrap.sh)`;
  return (
    <Alert severity="success" icon={false}
      action={<IconButton size="small" onClick={onDismiss} sx={{ fontSize: 13 }}>✕</IconButton>}
      sx={{ '& .MuiAlert-message': { width: '100%' } }}>
      <Typography variant="subtitle2" sx={{ mb: 1 }}>
        kit-{kit} is staged and NOT enrolled — finish it inside the VM (the customer experience)
      </Typography>
      <Stack spacing={0.5}>
        <CopyRow label="token" value={token} />
        <CopyRow label="step 1 (in VM)" value={bootstrap} />
        <CopyRow label="step 2 (in VM)" value="corewaf-demo-up" />
      </Stack>
      <Stack direction="row" spacing={1} sx={{ mt: 1.5 }} alignItems="center">
        <Button size="small" variant="contained" onClick={onOpenTerminal}>Open terminal in kit-{kit}</Button>
        <Typography variant="caption" color="text.secondary">
          then paste step 1, wait for it to finish, paste step 2 — the instance appears in the GUI under WAF instances → Pending.
        </Typography>
      </Stack>
    </Alert>
  );
}
