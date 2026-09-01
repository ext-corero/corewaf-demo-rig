// In-app instructions — curated from the repo README + docs/demo-kit.md.
import { Button, Dialog, DialogActions, DialogContent, DialogTitle, Typography } from '@mui/material';

const S = ({ t, children }: { t: string; children: React.ReactNode }) => (
  <>
    <Typography variant="subtitle2" sx={{ mt: 2 }}>{t}</Typography>
    <Typography variant="body2" color="text.secondary" component="div">{children}</Typography>
  </>
);
const C = ({ children }: { children: React.ReactNode }) => (
  <code style={{ fontSize: 12 }}>{children}</code>
);

export default function HelpDialog({ open, onClose, onOpenReadme }: {
  open: boolean; onClose: () => void; onOpenReadme: () => void;
}) {
  return (
    <Dialog open={open} onClose={onClose} maxWidth="md" fullWidth scroll="paper">
      <DialogTitle>Corero WAAP Demo Rig — how to use this extension</DialogTitle>
      <DialogContent dividers>
        <Typography variant="body2" color="text.secondary">
          The rig is six VMs (QEMU/KVM inside containers) — control plane, two DNS bridges, two
          tunnel gateways, observability — plus up to three WAF "kits" you can enrol. Everything the
          buttons do runs the same <C>rig-launcher</C> used by the curl and <C>docker run</C> paths.
        </Typography>

        <S t="Requirements">
          <ul style={{ margin: '4px 0 0 18px' }}>
            <li>KVM available to containers. Windows: <C>%UserProfile%\.wslconfig</C> needs{' '}
              <C>nestedVirtualization=true</C> (and ≈24 GB memory), then <C>wsl --shutdown</C>.</li>
            <li>An AWS profile with the Corero WAAP registry pull policy (ask your operator), configured
              once on the host: <C>aws configure --profile &lt;name&gt;</C> — set that name in the
              "AWS profile" field above.</li>
          </ul>
        </S>

        <S t="First run">
          Press <b>Up</b>. It refreshes the rig checkout, logs into the registry, and boots all six
          VMs — a cold start takes ~10 minutes (image pulls inside the VMs). Chips turn green as each
          node's stack comes up; then <b>Open GUI</b>.
        </S>

        <S t="Adding a kit (+ Add kit)">
          A kit is a customer-edge WAAP VM (own disk, TPM-backed identity). Two modes:
          <ul style={{ margin: '4px 0 0 18px' }}>
            <li><b>Automated</b> — boots, stages, mints a provisioning token and enrols in one go
              (~3–5 min). Best for quickly populating the fleet.</li>
            <li><b>Manual demo</b> — boots + stages the kit and mints a token but does <i>not</i>{' '}
              enrol. You then open the embedded terminal and run the enrolment inside the VM — the
              exact customer experience (public starter-kit bootstrap + <C>corewaf-demo-up</C>). The
              dialog shows every command with copy buttons; the terminal is Docker Desktop's own
              Exec tab on the kit container (click any node chip to jump there; type{' '}
              <C>vm-ssh</C> for a shell inside that VM, <C>console</C> for serial).</li>
          </ul>
        </S>

        <S t="Watching the rig">
          <b>Verify</b> = full health checklist (31+ checks). <b>Containers</b> = every container
          inside every VM. <b>Stat</b> = per-VM uptime/load/memory/disk. Node chips show docker
          health; hover for image + ports.
        </S>

        <S t="Lifecycle">
          <b>Stop</b> shuts the VMs down gracefully (disks kept). <b>Down</b> removes the containers
          but keeps volumes — the next Up boots the same VMs. <b>Reset</b> wipes everything including
          VM disks, CA, secrets and kit identities — the next Up is a cold start.
        </S>

        <S t="Troubleshooting">
          <ul style={{ margin: '4px 0 0 18px' }}>
            <li>First press after an update may show old output — the launcher image refreshes in the
              background; press again.</li>
            <li><C>KVM not available</C>: fix <C>.wslconfig</C>, <C>wsl --shutdown</C>, restart
              Docker Desktop.</li>
            <li>Registry errors: the AWS profile name must match a configured profile in{' '}
              <C>~/.aws</C> on this machine.</li>
            <li>A single red chip usually recovers with a plain <C>docker restart rig-&lt;node&gt;</C>.</li>
          </ul>
        </S>
      </DialogContent>
      <DialogActions>
        <Button onClick={onOpenReadme}>Open full README</Button>
        <Button variant="contained" onClick={onClose}>Close</Button>
      </DialogActions>
    </Dialog>
  );
}
