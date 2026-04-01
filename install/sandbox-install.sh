#!/usr/bin/env bash
# sandbox-install.sh — Installs the sandbox web terminal inside an LXC container.
# Called by ct/sandbox.sh via pct exec, or run directly on any Debian/Ubuntu machine:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/stevendejongnl/sandbox-setup/main/install/sandbox-install.sh)"
# shellcheck source=/dev/null

# Community-scripts helpers (msg_info / msg_ok / $STD).
# When called from build_container, FUNCTIONS_FILE_PATH is already set.
# When run standalone, fetch install.func directly.
if [[ -n "${FUNCTIONS_FILE_PATH:-}" ]]; then
  source "${FUNCTIONS_FILE_PATH}"
else
  source /dev/stdin <<< "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/install.func)"
fi

PORT="${SANDBOX_PORT:-7681}"

set -euo pipefail

# ── 1. System packages ────────────────────────────────────────────────────────
msg_info "Installing system packages"
$STD apt-get update
$STD apt-get install -y tmux curl wget git build-essential python3 ca-certificates
msg_ok "Installed system packages"

# ── 2. fakeid.so — makes process.getuid() return 1000 so Claude Code doesn't ──
# ──    warn about running as root (LD_PRELOAD'd via claude() in .bashrc)      ──
msg_info "Building fakeid.so"
cat > /tmp/fakeid.c << 'EOF'
#include <sys/types.h>
uid_t getuid(void)   { return 1000; }
uid_t geteuid(void)  { return 1000; }
gid_t getgid(void)   { return 1000; }
gid_t getegid(void)  { return 1000; }
EOF
gcc -shared -fPIC -nostartfiles -o /usr/local/lib/fakeid.so /tmp/fakeid.c
rm /tmp/fakeid.c
# PATH-level whoami wrapper so subprocesses also return the sandbox alias
cat > /usr/local/bin/whoami << 'EOF'
#!/bin/bash
echo "${USER:-root}"
EOF
chmod 755 /usr/local/bin/whoami
msg_ok "Built fakeid.so"

# ── 3. ttyd ──────────────────────────────────────────────────────────────────
msg_info "Installing ttyd"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  TTYD_BIN="ttyd.x86_64" ;;
  aarch64) TTYD_BIN="ttyd.aarch64" ;;
  *)       msg_error "Unsupported arch: $ARCH"; exit 1 ;;
esac
if [ ! -x /usr/local/bin/ttyd ]; then
  curl -fsSL "https://github.com/tsl0922/ttyd/releases/latest/download/$TTYD_BIN" \
    -o /usr/local/bin/ttyd
  chmod +x /usr/local/bin/ttyd
fi
msg_ok "Installed ttyd"

# ── 4. Service scripts ────────────────────────────────────────────────────────
msg_info "Writing service scripts"
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

cat > /usr/local/bin/restore-session << 'SCRIPT_EOF'
#!/bin/bash
echo "==> Ending session..."
tmux kill-session -t main 2>/dev/null && echo "Session killed." || echo "No active session."
echo "==> Environment will reset and reconnect in a moment."
SCRIPT_EOF
chmod 755 /usr/local/bin/restore-session
msg_ok "Wrote service scripts"

# ── 5. Mobile UI ──────────────────────────────────────────────────────────────
msg_info "Generating mobile UI"
FETCH_PORT=$((PORT + 1))
/usr/local/bin/ttyd --port "$FETCH_PORT" /bin/bash >/dev/null 2>&1 &
TTYD_FETCH_PID=$!
sleep 2
if curl -sf "http://localhost:$FETCH_PORT/" -o /tmp/ttyd-orig.html; then
  kill "$TTYD_FETCH_PID" 2>/dev/null; wait "$TTYD_FETCH_PID" 2>/dev/null || true

  python3 << 'PYEOF'
import re

with open('/tmp/ttyd-orig.html') as f:
    html = f.read()

viewport = '<meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">'
if re.search(r'<meta name="viewport"', html, re.IGNORECASE):
    html = re.sub(r'<meta[^>]+name="viewport"[^>]*>', viewport, html, flags=re.IGNORECASE)
else:
    html = html.replace('<head>', '<head>\n  ' + viewport, 1)

early_script = r"""<script>
(function () {
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
    frame[0] = 0x30;
    frame.set(data, 1);
    _sock.send(frame.buffer);
  };

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

    var kbdBtn = document.getElementById('sb-kbd-btn');
    if (kbdBtn) {
      var kbdOpen = visH < _noKbdH - 100;
      kbdBtn.style.background = kbdOpen ? '#1a3a1a' : '#2d2d2d';
      kbdBtn.textContent = kbdOpen ? '\u2328\u2715' : '\u2328';
    }

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
  window.addEventListener('resize', function () {
    if (!_syntheticResize) { adjustLayout(); }
  });

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

    var kbdBtn = document.createElement('button');
    kbdBtn.type = 'button';
    kbdBtn.id = 'sb-kbd-btn';
    kbdBtn.title = 'Toggle keyboard';
    kbdBtn.textContent = '\u2328';
    kbdBtn.addEventListener('click', function () {
      var ta = document.querySelector('.xterm-helper-textarea');
      if (!ta) { return; }
      if (document.activeElement === ta) { ta.blur(); } else { ta.focus(); }
    });
    bar.appendChild(kbdBtn);

    var sep0 = document.createElement('div');
    sep0.className = 'sb-sep';
    bar.appendChild(sep0);

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

    function handleBtn(el) {
      if (el.id === 'sb-kbd-btn') {
        var ta = document.querySelector('.xterm-helper-textarea');
        if (!ta) { return; }
        if (document.activeElement === ta) { ta.blur(); } else { ta.focus(); }
      } else if (el.dataset.seq !== undefined) {
        window.__sbSend(parseSeq(el.dataset.seq));
      }
    }

    bar.addEventListener('touchend', function (e) {
      var el = e.target;
      while (el && el !== bar) {
        if (el.tagName === 'BUTTON') {
          e.preventDefault();
          handleBtn(el);
          return;
        }
        el = el.parentElement;
      }
    }, { passive: false });

    bar.addEventListener('click', function (e) {
      var el = e.target;
      while (el && el !== bar) {
        if (el.tagName === 'BUTTON') { handleBtn(el); return; }
        el = el.parentElement;
      }
    });

    document.body.appendChild(bar);
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
  echo "WARNING: could not fetch ttyd HTML — mobile UI skipped"
fi
msg_ok "Generated mobile UI"

# ── 6. systemd service ────────────────────────────────────────────────────────
msg_info "Configuring systemd service"
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
$STD systemctl enable --now ttyd
msg_ok "Configured systemd service"

# ── 7. Package baseline ───────────────────────────────────────────────────────
msg_info "Saving package baseline"
dpkg --get-selections | grep -v deinstall | awk '{print $1}' \
  > /etc/sandbox-baseline-packages
msg_ok "Saved $(wc -l < /etc/sandbox-baseline-packages) packages to baseline"

# ── 8. Clone sandbox-setup repo ───────────────────────────────────────────────
msg_info "Cloning sandbox-setup"
git clone https://github.com/stevendejongnl/sandbox-setup.git /root/setup
bash /root/setup/bootstrap.sh
msg_ok "Cloned and bootstrapped sandbox-setup"
