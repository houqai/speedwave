#!/bin/bash
# Module: SelfSteal Template (single "IP blocked" page mimicking a hosting provider)
#
# Replaces the old random-template downloader. Writes one self-contained page to
# /var/www/html that looks like a hosting provider's automated security block
# ("your IP address has been blocked"). No external downloads — works offline and
# leaks nothing. Served by the node's nginx for the selfsteal/masking site.

install_blocked_template() {
    local www="/var/www/html"
    local ref date
    ref="$(openssl rand -hex 6 2>/dev/null | tr 'a-f' 'A-F')"
    [ -z "$ref" ] && ref="$(date +%s)"
    date="$(date -u '+%Y-%m-%d %H:%M UTC' 2>/dev/null)"

    echo -e "${COLOR_YELLOW}${LANG[APPLY_TEMPLATE]:-Applying template...}${COLOR_RESET}"

    mkdir -p "$www" || { echo "Failed to create $www"; return 1; }
    rm -rf "${www:?}/"* 2>/dev/null

    cat > "$www/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="robots" content="noindex, nofollow">
<title>Access Restricted</title>
<style>
  :root{
    --bg:#0f1115; --card:#171a21; --line:#262b36; --txt:#e6e8ec;
    --muted:#9aa3b2; --accent:#3b82f6; --danger:#e0685a; --ok:#7fb069;
  }
  *{box-sizing:border-box}
  html,body{height:100%}
  body{
    margin:0; background:var(--bg); color:var(--txt);
    font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    display:flex; flex-direction:column; min-height:100vh;
  }
  header{
    border-bottom:1px solid var(--line); padding:18px 24px;
    display:flex; align-items:center; gap:12px;
  }
  .logo{display:flex; align-items:center; gap:10px; font-weight:700; letter-spacing:.3px}
  .logo svg{width:26px; height:26px}
  .logo span b{color:var(--accent)}
  main{flex:1; display:flex; align-items:center; justify-content:center; padding:32px 16px}
  .card{
    width:100%; max-width:560px; background:var(--card);
    border:1px solid var(--line); border-radius:14px; padding:36px 34px;
    box-shadow:0 12px 40px rgba(0,0,0,.35);
  }
  .badge{
    display:inline-flex; align-items:center; gap:8px; font-size:13px; font-weight:600;
    color:var(--danger); background:rgba(224,104,90,.12);
    border:1px solid rgba(224,104,90,.35); padding:6px 12px; border-radius:999px;
  }
  h1{font-size:24px; margin:18px 0 8px}
  p{color:var(--muted); margin:0 0 14px}
  .details{
    margin-top:22px; border-top:1px solid var(--line); padding-top:18px;
    display:grid; grid-template-columns:auto 1fr; gap:8px 18px; font-size:14px;
  }
  .details dt{color:var(--muted)}
  .details dd{margin:0; font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
  .actions{margin-top:26px; display:flex; gap:12px; flex-wrap:wrap}
  .btn{
    text-decoration:none; font-weight:600; font-size:14px; padding:10px 16px;
    border-radius:9px; border:1px solid var(--line); color:var(--txt);
  }
  .btn.primary{background:var(--accent); border-color:var(--accent); color:#fff}
  footer{
    border-top:1px solid var(--line); padding:16px 24px; color:var(--muted);
    font-size:13px; display:flex; justify-content:space-between; flex-wrap:wrap; gap:8px;
  }
  a{color:var(--accent)}
</style>
</head>
<body>
  <header>
    <div class="logo">
      <svg viewBox="0 0 24 24" fill="none" stroke="#3b82f6" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="11" width="18" height="11" rx="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/></svg>
      <span>Stark<b>Host</b> &middot; Cloud Infrastructure</span>
    </div>
  </header>

  <main>
    <div class="card">
      <span class="badge">
        <svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/></svg>
        Error 403 &middot; Access Restricted
      </span>

      <h1>Your IP address has been blocked</h1>
      <p>
        Access to this server has been temporarily restricted by our automated
        security system. This usually happens after unusual or suspicious network
        activity was detected coming from your IP address.
      </p>
      <p>
        If you believe this is a mistake, please contact our support team and
        include the reference ID below.
      </p>

      <dl class="details">
        <dt>Reference ID</dt><dd>__REF__</dd>
        <dt>Timestamp</dt><dd>__DATE__</dd>
        <dt>Status</dt><dd>403 Forbidden</dd>
      </dl>

      <div class="actions">
        <a class="btn primary" href="mailto:abuse@starkhost.net">Contact support</a>
        <a class="btn" href="/">Try again</a>
      </div>
    </div>
  </main>

  <footer>
    <span>&copy; StarkHost Cloud Infrastructure</span>
    <span>Powered by StarkHost Edge Network</span>
  </footer>
</body>
</html>
HTML

    sed -i "s/__REF__/$ref/g; s/__DATE__/$date/g" "$www/index.html" 2>/dev/null

    if [ -s "$www/index.html" ]; then
        echo -e "${COLOR_GREEN}${LANG[TEMPLATE_COPY]}${COLOR_RESET}"
        return 0
    fi
    echo -e "${COLOR_RED}${LANG[UNPACK_ERROR]:-Failed to write template}${COLOR_RESET}"
    return 1
}
