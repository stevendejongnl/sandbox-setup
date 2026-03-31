#!/bin/bash
# install.sh — Installs the sandbox web terminal on the local machine.
# Requires: Debian/Ubuntu, root.
# Usage: bash install.sh
#   SANDBOX_PORT=7681  (optional, default 7681)
set -euo pipefail

PORT="${SANDBOX_PORT:-7681}"

echo "==> [1/6] Installing system packages"
apt-get update -qq
apt-get install -y tmux curl wget git build-essential python3 ca-certificates 2>&1 | tail -3

echo "==> [2/6] Installing ttyd"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  TTYD_BIN="ttyd.x86_64" ;;
  aarch64) TTYD_BIN="ttyd.aarch64" ;;
  *)       echo "Unsupported arch: $ARCH"; exit 1 ;;
esac
if [ ! -x /usr/local/bin/ttyd ]; then
  curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/$TTYD_BIN" \
    -o /usr/local/bin/ttyd
  chmod +x /usr/local/bin/ttyd
  echo "  installed ttyd"
else
  echo "  ttyd already installed"
fi

echo "==> [3/6] Writing service scripts"

# ttyd-start — launches ttyd with custom mobile UI
mkdir -p /usr/local/share/sandbox
cat > /usr/local/bin/ttyd-start << SCRIPT_EOF
#!/bin/bash
exec /usr/local/bin/ttyd \\
  --writable \\
  --port $PORT \\
  --index /usr/local/share/sandbox/index.html \\
  --client-option fontFamily=monospace \\
  --client-option fontSize=15 \\
  /usr/local/bin/sandbox-session
SCRIPT_EOF
chmod 755 /usr/local/bin/ttyd-start

# sandbox-session — wraps tmux; resets environment when session actually ends
cat > /usr/local/bin/sandbox-session << 'SCRIPT_EOF'
#!/bin/bash
tmux new-session -A -s main

# If session still exists, this was a detach or browser disconnect — do nothing.
tmux has-session -t main 2>/dev/null && exit 0

# Session ended — reset environment for next user.
BASELINE=/etc/sandbox-baseline-packages
if [ -f "$BASELINE" ]; then
  TO_REMOVE=$(comm -23 \
    <(dpkg --get-selections | grep -v deinstall | awk '{print $1}' | sort) \
    <(sort "$BASELINE"))
  if [ -n "$TO_REMOVE" ]; then
    # shellcheck disable=SC2086
    apt-get purge -y $TO_REMOVE 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
  fi
fi

if [ -f /root/setup/bootstrap.sh ]; then
  bash /root/setup/bootstrap.sh
fi

rm -f /tmp/.sandbox_welcomed
SCRIPT_EOF
chmod 755 /usr/local/bin/sandbox-session

# restore-session — kills the session; sandbox-session handles cleanup
cat > /usr/local/bin/restore-session << 'SCRIPT_EOF'
#!/bin/bash
echo "==> Ending session..."
tmux kill-session -t main 2>/dev/null && echo "Session killed." || echo "No active session."
echo "==> Environment will reset and reconnect in a moment."
SCRIPT_EOF
chmod 755 /usr/local/bin/restore-session

echo "==> [4/6] Generating mobile UI"
# Start ttyd briefly on a temp port to fetch its built-in HTML, then patch it.
# Note: HTML-injected <div> elements are dropped by Preact's reconciliation pass
# (Preact owns document.body). The toolbar must be created via JS after page load.
FETCH_PORT=$((PORT + 1))
/usr/local/bin/ttyd --port "$FETCH_PORT" /bin/bash >/dev/null 2>&1 &
TTYD_FETCH_PID=$!
sleep 2
if curl -sf "http://localhost:$FETCH_PORT/" -o /tmp/ttyd-orig.html; then
  echo "  fetched ttyd HTML ($(wc -c < /tmp/ttyd-orig.html) bytes)"
  kill "$TTYD_FETCH_PID" 2>/dev/null; wait "$TTYD_FETCH_PID" 2>/dev/null || true

  python3 << 'PYEOF'
import re

with open('/tmp/ttyd-orig.html') as f:
    html = f.read()

# Add/replace viewport meta for proper mobile zoom
viewport = '<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">'
if re.search(r'<meta name="viewport"', html, re.IGNORECASE):
    html = re.sub(r'<meta[^>]+name="viewport"[^>]*>', viewport, html, flags=re.IGNORECASE)
else:
    html = html.replace('<head>', '<head>\n  ' + viewport, 1)

# Single early script injected into <head>:
#   1. WebSocket interception (captures socket before app code runs)
#   2. Toolbar CSS injection
#   3. Toolbar DOM creation on window load (programmatic — HTML-injected divs are
#      dropped during Preact's reconciliation of document.body)
early_script = r"""<script>
(function () {
  /* 1. Capture the ttyd WebSocket so toolbar buttons can send input.
        ttyd protocol: binary frame, first byte 0x30 ('0') = INPUT. */
  var _WS = window.WebSocket;
  var _sock = null;
  window.WebSocket = function () {
    var args = Array.prototype.slice.call(arguments);
    var ws = new (Function.prototype.bind.apply(_WS, [null].concat(args)))();
    _sock = ws;
    return ws;
  };
  Object.setPrototypeOf(window.WebSocket, _WS);

  var _enc = new TextEncoder();

  window.__sbSend = function (seq) {
    if (!_sock || _sock.readyState !== 1) { return; }
    var data = _enc.encode(seq);
    var frame = new Uint8Array(data.length + 1);
    frame[0] = 0x30; /* INPUT command */
    frame.set(data, 1);
    _sock.send(frame.buffer);
  };

  /* 2. Toolbar CSS */
  var style = document.createElement('style');
  style.textContent = [
    '#sandbox-toolbar{position:fixed;bottom:0;left:0;right:0;display:flex;',
    'flex-wrap:nowrap;overflow-x:auto;-webkit-overflow-scrolling:touch;',
    'scrollbar-width:none;gap:5px;padding:5px 8px;',
    'padding-bottom:max(5px,env(safe-area-inset-bottom));',
    'background:#1a1a1a;border-top:1px solid #333;z-index:9999;box-sizing:border-box;}',
    '#sandbox-toolbar::-webkit-scrollbar{display:none;}',
    '#sandbox-toolbar button{flex-shrink:0;background:#2d2d2d;color:#ccc;',
    'border:1px solid #484848;border-radius:5px;padding:6px 10px;',
    'font-size:13px;font-family:monospace;min-width:36px;height:36px;line-height:1;',
    'touch-action:manipulation;-webkit-tap-highlight-color:transparent;',
    'cursor:pointer;user-select:none;white-space:nowrap;}',
    '#sandbox-toolbar button:active{background:#444;color:#fff;}',
    '.sb-sep{flex-shrink:0;width:1px;background:#3a3a3a;margin:4px 2px;align-self:stretch;}'
  ].join('');
  document.head.appendChild(style);

  /* 3. Build toolbar DOM after page loads (avoids Preact reconciliation issues) */
  function parseSeq(s) {
    return s.replace(/\\x([0-9a-fA-F]{2})/g, function (_, h) {
      return String.fromCharCode(parseInt(h, 16));
    });
  }

  var BUTTONS = [
    ['\\x1b', 'ESC'],  ['\\x09', 'Tab'],  ['\\x03', '^C'],
    ['\\x04', '^D'],   ['\\x0c', '^L'],   null,
    ['\\x1b[A', '\u2191'], ['\\x1b[B', '\u2193'],
    ['\\x1b[D', '\u2190'], ['\\x1b[C', '\u2192'], null,
    ['\\x01',   'C-a'], ['\\x01d',   'det'], ['\\x01%', 'v|'],
    ['\\x01"',  'h-'],  ['\\x01[',   'scrl'],
    ['\\x01n',  'nxt'], ['\\x01p',   'prv'], null,
    ['|', '|'], ['~', '~'], ['-', '-'], ['/', '/'], ['\\r', '\u21b5']
  ];

  function buildToolbar() {
    if (document.getElementById('sandbox-toolbar')) { return; }
    var bar = document.createElement('div');
    bar.id = 'sandbox-toolbar';
    BUTTONS.forEach(function (btn) {
      if (!btn) {
        var sep = document.createElement('div');
        sep.className = 'sb-sep';
        bar.appendChild(sep);
        return;
      }
      var b = document.createElement('button');
      b.type = 'button';
      b.dataset.seq = btn[0];
      b.textContent = btn[1];
      bar.appendChild(b);
    });
    bar.addEventListener('click', function (e) {
      var el = e.target;
      while (el && el !== bar) {
        if (el.tagName === 'BUTTON' && el.dataset.seq !== undefined) {
          window.__sbSend(parseSeq(el.dataset.seq));
          return;
        }
        el = el.parentElement;
      }
    });
    document.body.appendChild(bar);
  }

  window.addEventListener('load', buildToolbar);
})();
</script>"""

html = html.replace('<head>', '<head>\n' + early_script, 1)

with open('/usr/local/share/sandbox/index.html', 'w') as f:
    f.write(html)

print('  mobile UI saved (%d bytes)' % len(html))
PYEOF

else
  kill "$TTYD_FETCH_PID" 2>/dev/null; wait "$TTYD_FETCH_PID" 2>/dev/null || true
  echo "  WARNING: could not fetch ttyd HTML — mobile UI skipped"
  echo "  Re-run install.sh or copy index.html manually to /usr/local/share/sandbox/"
fi

echo "==> [5/6] Configuring systemd service"
cat > /etc/systemd/system/ttyd.service << 'SVC_EOF'
[Unit]
Description=ttyd web terminal
After=network.target

[Service]
ExecStart=/usr/local/bin/ttyd-start
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable --now ttyd

echo "==> [6/6] Saving baseline package list"
dpkg --get-selections | grep -v deinstall | awk '{print $1}' \
  > /etc/sandbox-baseline-packages
echo "  $(wc -l < /etc/sandbox-baseline-packages) packages in baseline"

echo ""
echo "Done! ttyd is running on port $PORT."
echo "  Point a reverse proxy at this machine:$PORT"
echo "  Inside tmux: git clone https://github.com/stevendejongnl/sandbox-setup.git ~/setup && ~/setup/bootstrap.sh"
