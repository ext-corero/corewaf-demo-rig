// Minimal ANSI SGR → styled spans (the launcher's ✓/✗ colors, bold, dim).
// Anything else (cursor movement etc.) is stripped.
import React from 'react';

const COLORS: Record<number, string> = {
  30: '#000', 31: '#e5484d', 32: '#30a46c', 33: '#f5a524', 34: '#3e63dd',
  35: '#ab4aba', 36: '#12a594', 37: '#ccc',
  90: '#777', 91: '#ff6369', 92: '#3dd68c', 93: '#ffd60a', 94: '#849dff',
  95: '#d19dff', 96: '#0ac5b3', 97: '#eee',
};

export function renderAnsi(text: string): React.ReactNode[] {
  const out: React.ReactNode[] = [];
  let style: React.CSSProperties = {};
  let buf = '';
  let key = 0;
  const flush = () => {
    if (!buf) return;
    out.push(Object.keys(style).length
      ? <span key={key++} style={{ ...style }}>{buf}</span>
      : <React.Fragment key={key++}>{buf}</React.Fragment>);
    buf = '';
  };
  // eslint-disable-next-line no-control-regex
  const re = /\x1b\[([0-9;]*)m|\x1b\[[0-9;?]*[A-Za-ln-z]/g;
  let last = 0;
  for (let m = re.exec(text); m; m = re.exec(text)) {
    buf += text.slice(last, m.index);
    last = re.lastIndex;
    if (m[1] === undefined) continue; // non-SGR escape: strip
    flush();
    for (const p of (m[1] === '' ? '0' : m[1]).split(';').map(Number)) {
      if (p === 0) style = {};
      else if (p === 1) style = { ...style, fontWeight: 700 };
      else if (p === 2) style = { ...style, opacity: 0.7 };
      else if (p === 22) { const { fontWeight, opacity, ...rest } = style; style = rest; }
      else if (p === 39) { const { color, ...rest } = style; style = rest; }
      else if (COLORS[p]) style = { ...style, color: COLORS[p] };
    }
  }
  buf += text.slice(last);
  flush();
  return out;
}
