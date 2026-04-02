#!/bin/bash
# install.sh — Installs the sandbox web terminal on the local machine.
# Requires: Debian/Ubuntu, root.
# Usage: bash install.sh
#   SANDBOX_PORT=7681  (optional, default 7681)
set -euo pipefail

PORT="${SANDBOX_PORT:-7681}"

echo "==> [1/8] Installing system packages"
apt-get update -qq
apt-get install -y tmux curl wget git build-essential python3 ca-certificates nginx 2>&1 | tail -3

echo "==> [2/8] Installing ttyd"
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

echo "==> [3/8] Writing service scripts"

# ttyd-start — launches ttyd with custom mobile UI
mkdir -p /usr/local/share/sandbox
cat > /usr/local/bin/ttyd-start << SCRIPT_EOF
#!/bin/bash
exec /usr/local/bin/ttyd \\
  --writable \\
  --port $((PORT + 1)) \\
  --index /usr/local/share/sandbox/index.html \\
  --client-option fontFamily=monospace \\
  --client-option fontSize=15 \\
  /usr/local/bin/sandbox-session
SCRIPT_EOF
chmod 755 /usr/local/bin/ttyd-start

# sandbox-session — wraps tmux; resets environment when session actually ends
cat > /usr/local/bin/sandbox-session << 'SCRIPT_EOF'
#!/bin/bash
cd /root || true
tmux new-session -A -s main -c /root

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

echo "==> [4/8] Generating mobile UI"
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

  /* 3. Layout adjustment — keeps terminal + toolbar within the visual viewport.
        On iOS, opening the keyboard shrinks visualViewport.height but NOT
        window.innerHeight. position:fixed elements stay anchored to the full
        document, so the toolbar disappears behind the keyboard. Fix: translate
        the toolbar up by the keyboard height and shrink the terminal to match. */
  /* Baseline visual-viewport height captured before any keyboard opens */
  var _noKbdH = window.visualViewport ? window.visualViewport.height : window.innerHeight;
  var _syntheticResize = false;

  function adjustLayout() {
    var bar = document.getElementById('sandbox-toolbar');
    var tc  = document.getElementById('terminal-container');
    if (!bar || !tc) { return; }

    var vv = window.visualViewport;
    var visH, keyboardH;
    if (vv) {
      visH      = vv.height;
      keyboardH = Math.max(0, window.innerHeight - vv.offsetTop - vv.height);
      bar.style.transform = keyboardH > 0 ? 'translateY(-' + keyboardH + 'px)' : '';
    } else {
      visH      = window.innerHeight;
      keyboardH = 0;
      bar.style.transform = '';
    }

    tc.style.height = (visH - bar.offsetHeight) + 'px';

    /* Update keyboard-toggle button to reflect current keyboard state */
    var kbdBtn = document.getElementById('sb-kbd-btn');
    if (kbdBtn) {
      var kbdOpen = visH < _noKbdH - 100;
      kbdBtn.style.background = kbdOpen ? '#1a3a1a' : '#2d2d2d';
      kbdBtn.textContent = kbdOpen ? '\u2328\u2715' : '\u2328';
    }

    /* Trigger xterm's fit addon. Guard against recursive calls because
       dispatching 'resize' on window may fire our own listener again. */
    if (!_syntheticResize) {
      _syntheticResize = true;
      window.dispatchEvent(new Event('resize'));
      _syntheticResize = false;
    }
  }

  if (window.visualViewport) {
    window.visualViewport.addEventListener('resize', adjustLayout);
    window.visualViewport.addEventListener('scroll', adjustLayout);
  }
  /* Standard resize for Android Chrome (window.innerHeight changes there) */
  window.addEventListener('resize', function () {
    if (!_syntheticResize) { adjustLayout(); }
  });

  /* 4. Build toolbar DOM after page loads (avoids Preact reconciliation issues) */
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
    if (document.getElementById('sandbox-toolbar')) {
      adjustLayout();
      return;
    }
    var bar = document.createElement('div');
    bar.id = 'sandbox-toolbar';

    /* Keyboard toggle button — first in the bar */
    var kbdBtn = document.createElement('button');
    kbdBtn.type = 'button';
    kbdBtn.id = 'sb-kbd-btn';
    kbdBtn.title = 'Toggle keyboard';
    kbdBtn.textContent = '\u2328'; /* ⌨ */
    kbdBtn.addEventListener('click', function () {
      var ta = document.querySelector('.xterm-helper-textarea');
      if (!ta) { return; }
      if (document.activeElement === ta) {
        ta.blur();
      } else {
        ta.focus();
      }
    });
    bar.appendChild(kbdBtn);

    /* Separator */
    var sep0 = document.createElement('div');
    sep0.className = 'sb-sep';
    bar.appendChild(sep0);

    /* Key-sequence buttons */
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

    /* Button action dispatcher (shared by touch and mouse paths) */
    function handleBtn(el) {
      if (el.id === 'sb-kbd-btn') {
        var ta = document.querySelector('.xterm-helper-textarea');
        if (!ta) { return; }
        if (document.activeElement === ta) { ta.blur(); } else { ta.focus(); }
      } else if (el.dataset.seq !== undefined) {
        window.__sbSend(parseSeq(el.dataset.seq));
      }
    }

    /* Touch path: act on touchend and prevent the synthesized mousedown that
       would steal focus from xterm (closing the keyboard).
       touchstart is NOT prevented so horizontal swipe-to-scroll still works. */
    bar.addEventListener('touchend', function (e) {
      var el = e.target;
      while (el && el !== bar) {
        if (el.tagName === 'BUTTON') {
          e.preventDefault(); /* blocks synthesized mousedown/focus transfer */
          handleBtn(el);
          return;
        }
        el = el.parentElement;
      }
    }, { passive: false });

    /* Desktop mouse path */
    bar.addEventListener('click', function (e) {
      var el = e.target;
      while (el && el !== bar) {
        if (el.tagName === 'BUTTON') { handleBtn(el); return; }
        el = el.parentElement;
      }
    });

    document.body.appendChild(bar);
    /* Initial layout: shrink terminal to leave room for toolbar */
    requestAnimationFrame(adjustLayout);
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

echo "==> [5/8] Configuring ttyd systemd service"
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

echo "==> [6/8] Configuring nginx reverse proxy"
# nginx was installed in step 1; disable the default site and write ours.
rm -f /etc/nginx/sites-enabled/default
cat > /etc/nginx/sites-available/sandbox << NGINX_EOF
server {
    listen $PORT;

    # ttyd WebSocket terminal (internal port $((PORT + 1)))
    location / {
        proxy_pass         http://127.0.0.1:$((PORT + 1));
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_read_timeout 7d;
        proxy_buffering    off;
    }

    # Claude Code transparency dashboard
    location = /dashboard {
        return 302 /dashboard/;
    }
    location /dashboard/ {
        proxy_pass         http://127.0.0.1:5000/;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host \$host;
        proxy_set_header   X-Real-IP \$remote_addr;
        proxy_buffering    off;
    }
}
NGINX_EOF
ln -sf /etc/nginx/sites-available/sandbox /etc/nginx/sites-enabled/sandbox
nginx -t
systemctl enable --now nginx

echo "==> [7/8] Installing Docker and claude-dashboard"
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
fi

DASH_DIR="/opt/claude-dashboard"
if [ -d "$DASH_DIR/.git" ]; then
  git -C "$DASH_DIR" pull --ff-only 2>/dev/null || true
else
  git clone https://github.com/stevendejongnl/claude-dashboard.git "$DASH_DIR"
fi

# Generate mitmproxy CA cert on first run so Claude Code TLS works through the proxy
if [ ! -f /root/.mitmproxy/mitmproxy-ca-cert.pem ]; then
  mkdir -p /root/.mitmproxy
  docker run --rm \
    -v /root/.mitmproxy:/home/mitmproxy/.mitmproxy \
    mitmproxy/mitmproxy mitmdump --quiet &
  MITM_INIT_PID=$!
  sleep 5
  kill "$MITM_INIT_PID" 2>/dev/null || true
  wait "$MITM_INIT_PID" 2>/dev/null || true
fi

if [ -f /root/.mitmproxy/mitmproxy-ca-cert.pem ]; then
  cp /root/.mitmproxy/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/mitmproxy.crt
  update-ca-certificates
fi

cat > /etc/systemd/system/claude-dashboard.service << 'SVC_EOF'
[Unit]
Description=Claude Dashboard (mitmproxy + FastAPI)
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=simple
WorkingDirectory=/opt/claude-dashboard
ExecStartPre=-/usr/bin/docker compose down
ExecStart=/usr/bin/docker compose up --build
ExecStop=/usr/bin/docker compose down
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC_EOF

systemctl daemon-reload
systemctl enable --now claude-dashboard

echo "==> [8/8] Saving baseline package list"
dpkg --get-selections | grep -v deinstall | awk '{print $1}' \
  > /etc/sandbox-baseline-packages
echo "  $(wc -l < /etc/sandbox-baseline-packages) packages in baseline"

echo ""
echo "Done! nginx is running on port $PORT."
echo "  Terminal:   http://this-machine:$PORT/"
echo "  Dashboard:  http://this-machine:$PORT/dashboard"
echo "  Point a reverse proxy at this machine:$PORT — Zoraxy config unchanged."
echo "  Inside tmux: git clone https://github.com/stevendejongnl/sandbox-setup.git ~/setup && ~/setup/bootstrap.sh"
