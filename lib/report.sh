#!/bin/bash
# bento — handoff HTML report generator
#
# Reads ~/.config/bento/state.json + ~/.config/bento/portainer.json + each
# stack's manifest, then writes a single self-contained HTML file with:
#   - the VPS overview (domain, IP, admin email)
#   - infra status + Portainer admin credentials
#   - one card per bento-deployed stack with envs (secrets masked)
#
# The file is meant to be shared with the customer the install was done for.
# It is intentionally print-friendly and works offline (no external CSS/JS).

[[ -n "${_BENTO_REPORT_LOADED:-}" ]] && return 0
_BENTO_REPORT_LOADED=1

# shellcheck source=lib/state.sh
source "$(dirname "${BASH_SOURCE[0]}")/state.sh"

readonly BENTO_REPORTS_DIR="${HOME}/.local/share/bento/reports"

# Public entry — writes a report and echoes its absolute path on success.
report_generate() {
    mkdir -p "$BENTO_REPORTS_DIR"
    chmod 700 "$BENTO_REPORTS_DIR"

    local ts out
    ts=$(date -u +%Y%m%d-%H%M%S)
    out="${BENTO_REPORTS_DIR}/handoff-${ts}.html"

    _report_write "$out"
    chmod 600 "$out"
    printf '%s' "$out"
}

# -----------------------------------------------------------------------------
# Internal — value formatting helpers
# -----------------------------------------------------------------------------
_html_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

# Render a "key: value" row. If hidden=1, mark it as a secret with a
# click-to-reveal toggle.
_secret_row() {
    local label="$1"
    local value="$2"
    local hidden="${3:-0}"
    local esc_label esc_value
    esc_label=$(_html_escape "$label")
    esc_value=$(_html_escape "$value")

    if [[ "$hidden" == "1" ]]; then
        cat <<HTML
<div class="row secret">
  <div class="key">${esc_label}</div>
  <div class="val">
    <code class="masked" data-secret="${esc_value}">••••••••••••••••</code>
    <button type="button" class="reveal" onclick="bentoReveal(this)">show</button>
  </div>
</div>
HTML
    else
        cat <<HTML
<div class="row">
  <div class="key">${esc_label}</div>
  <div class="val"><code>${esc_value}</code></div>
</div>
HTML
    fi
}

# -----------------------------------------------------------------------------
# Internal — section renderers
# -----------------------------------------------------------------------------
# If unattended_step3 (or stacks_step3_menu) recorded failures, surface
# them at the top of the report. The file is removed on a clean run so
# its presence reliably indicates "something needs your attention".
_section_failures() {
    local marker="${BENTO_STATE_DIR}/last-run-failures"
    [[ -f "$marker" ]] || return 0
    local list=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        list+="<li><code>$(_html_escape "$line")</code></li>"
    done < "$marker"
    [[ -z "$list" ]] && return 0
    cat <<HTML
<section class="failures">
<h2>⚠ Last run had failures</h2>
<p>The following stacks did not deploy cleanly. Re-run Step 3 to retry
or check <code>~/.local/state/bento/logs/</code> on the VPS.</p>
<ul>${list}</ul>
</section>
HTML
}

_section_vps() {
    local base_domain admin_email advertise_addr
    base_domain=$(state_get '.bootstrap.base_domain')
    admin_email=$(state_get '.bootstrap.admin_email')
    advertise_addr=$(state_get '.bootstrap.advertise_addr')

    cat <<HTML
<section class="card">
  <header><h2>VPS</h2><p class="lede">The host bento was installed on.</p></header>
  $(_secret_row "Public IP" "$advertise_addr" 0)
  $(_secret_row "Base domain" "$base_domain" 0)
  $(_secret_row "Admin email" "$admin_email" 0)
  $(_secret_row "SSH" "ssh user@$advertise_addr" 0)
</section>
HTML
}

_section_infra() {
    local portainer_host portainer_url portainer_user portainer_pass
    portainer_host=$(state_get '.bootstrap.portainer_host')
    portainer_url="https://${portainer_host}"
    portainer_user="deployer"
    portainer_pass=""
    if [[ -f "${BENTO_STATE_DIR}/portainer.json" ]]; then
        portainer_user=$(jq -r '.username // "deployer"' "${BENTO_STATE_DIR}/portainer.json")
        portainer_pass=$(jq -r '.password // ""'         "${BENTO_STATE_DIR}/portainer.json")
    fi

    cat <<HTML
<section class="card">
  <header><h2>Traefik</h2><p class="lede">Reverse proxy + Let's Encrypt.</p></header>
  $(_secret_row "ACME email" "$(state_get '.bootstrap.admin_email')" 0)
  $(_secret_row "Public ports" "80 (redirect), 443 (HTTPS)" 0)
</section>

<section class="card">
  <header><h2>Portainer</h2><p class="lede">Day-to-day operations (logs, restart, scale).</p></header>
  $(_secret_row "URL" "$portainer_url" 0)
  $(_secret_row "Username" "$portainer_user" 0)
  $(_secret_row "Password" "$portainer_pass" 1)
</section>
HTML
}

# Renders one card per deployed bento-managed stack.
_section_apps() {
    local stack_keys
    # Distinguish "state file is fine but no stacks yet" from "jq blew
    # up trying to read state". The previous form swallowed the jq exit
    # code, so a corrupt state.json silently produced an empty applist
    # in the handoff HTML — looked clean to the operator, but the
    # state was broken.
    if ! stack_keys=$(jq -r '.stacks // {} | keys[]?' "$BENTO_STATE_FILE" 2>&1); then
        cat <<HTML
<section class="card error">
  <header><h2>Applications</h2></header>
  <p class="empty">State file unreadable — jq said:</p>
  <pre>$(_html_escape "$stack_keys")</pre>
</section>
HTML
        return
    fi

    if [[ -z "$stack_keys" ]]; then
        cat <<HTML
<section class="card">
  <header><h2>Applications</h2></header>
  <p class="empty">No applications deployed yet.</p>
</section>
HTML
        return
    fi

    while IFS= read -r stack_key; do
        _render_app_card "$stack_key"
    done <<< "$stack_keys"
}

_render_app_card() {
    local stack_key="$1"
    local manifest_path description post_deploy_tpl url
    manifest_path=$(stacks_manifest_for_key "$stack_key")
    description=""
    post_deploy_tpl=""
    if [[ -n "$manifest_path" ]]; then
        description=$(jq -r '.description // ""' "$manifest_path")
        post_deploy_tpl=$(jq -r '.post_deploy_url // ""' "$manifest_path")
    fi
    url=""
    if [[ -n "$post_deploy_tpl" ]]; then
        url=$(stacks_substitute_template_with_stack_envs "$stack_key" "$post_deploy_tpl" 2>/dev/null || true)
    fi

    local esc_key esc_desc
    esc_key=$(_html_escape "$stack_key")
    esc_desc=$(_html_escape "$description")
    # $url is escaped inside _secret_row at the print site below, so we
    # don't need an esc_url here.

    cat <<HTML
<section class="card" id="stack-${esc_key}">
  <header>
    <h2>${esc_key}</h2>
    <p class="lede">${esc_desc}</p>
  </header>
HTML

    if [[ -n "$url" ]]; then
        printf '  %s\n' "$(_secret_row "URL" "$url" 0)"
    fi

    # Per-stack post-deploy notes. install.sh drops a marker file
    # under ${BENTO_STATE_DIR}/<stack>-<topic>.txt; if it exists we
    # surface the contents here. Today: paperclip's bootstrap-ceo
    # first-admin invite URL (single line, expires 24h after install).
    local marker="${BENTO_STATE_DIR}/${stack_key}-invite-url.txt"
    if [[ -s "$marker" ]]; then
        local invite_url esc_invite_url
        invite_url=$(head -1 "$marker")
        esc_invite_url=$(_html_escape "$invite_url")
        cat <<HTML
  <div class="post-deploy-note">
    <p class="post-deploy-note-title">First-admin claim — single use, expires 24h after install</p>
    <p>The first signup via this URL becomes <code>instance_admin</code>. Public signup is currently open on the public URL above; lock it later from Portainer (set <code>PAPERCLIP_AUTH_DISABLE_SIGN_UP</code> to <code>true</code>).</p>
    <p><a class="post-deploy-link" href="${esc_invite_url}" target="_blank" rel="noopener noreferrer">${esc_invite_url}</a></p>
  </div>
HTML
    fi

    # Iterate envs.
    local rows
    rows=$(jq -c ".envs[\"$stack_key\"] // {} | to_entries[]?" "$BENTO_STATE_FILE")
    if [[ -n "$rows" ]]; then
        while IFS= read -r row; do
            local name value hidden
            name=$(jq -r '.key'   <<< "$row")
            value=$(jq -r '.value' <<< "$row")
            hidden=0
            if [[ -n "$manifest_path" ]]; then
                hidden=$(jq --arg n "$name" \
                    'if (.env[]? | select(.name == $n) | .hide // false) == true then 1 else 0 end' \
                    "$manifest_path" 2>/dev/null | head -1)
                hidden=${hidden:-0}
            fi
            _secret_row "$name" "$value" "$hidden"
        done <<< "$rows"
    fi

    printf '</section>\n'
}

# -----------------------------------------------------------------------------
# Internal — HTML scaffolding
# -----------------------------------------------------------------------------
_report_write() {
    local out="$1"
    local base_domain title generated_at
    base_domain=$(state_get '.bootstrap.base_domain')
    generated_at=$(date -u +'%Y-%m-%d %H:%M UTC')
    title="bento handoff — $(_html_escape "$base_domain")"

    {
        cat <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${title}</title>
<style>
:root {
    --salmon: #FF6B6B;
    --wasabi: #06D6A0;
    --rice:   #FAF3DD;
    --ink:    #1C2433;
    --muted:  #6B7280;
    --line:   #E5E7EB;
    --bg:     #F8FAFC;
}
* { box-sizing: border-box; }
body {
    margin: 0;
    font: 15px/1.55 ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto,
          "Helvetica Neue", Arial, "Apple Color Emoji", "Segoe UI Emoji";
    color: var(--ink);
    background: var(--bg);
}
.wrap { max-width: 880px; margin: 32px auto; padding: 0 20px; }
header.hero {
    display: flex; align-items: center; gap: 16px;
    padding: 24px; border-radius: 16px;
    background: var(--ink); color: var(--rice);
    box-shadow: 0 1px 0 rgba(0,0,0,0.04), 0 8px 24px rgba(16,24,40,0.08);
    margin-bottom: 28px;
}
header.hero .logo {
    width: 56px; height: 56px; flex: 0 0 56px;
    border-radius: 12px; background: var(--salmon);
    display: grid; place-items: center; color: var(--ink);
    font-weight: 800; font-size: 22px;
}
header.hero h1 { margin: 0; font-size: 22px; letter-spacing: -0.01em; }
header.hero p { margin: 4px 0 0; color: rgba(250,243,221,0.7); font-size: 13px; }
.summary {
    display: grid; grid-template-columns: repeat(3, 1fr); gap: 12px;
    margin-bottom: 28px;
}
.summary .stat {
    background: white; border: 1px solid var(--line); border-radius: 12px;
    padding: 14px 16px;
}
.summary .stat .label { color: var(--muted); font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; }
.summary .stat .value { font-size: 18px; font-weight: 600; margin-top: 2px; word-break: break-all; }

section.card {
    background: white; border: 1px solid var(--line); border-radius: 14px;
    padding: 20px 22px; margin-bottom: 18px;
}
section.card header { border-bottom: 1px solid var(--line); padding-bottom: 12px; margin-bottom: 12px; }
section.card h2 { margin: 0; font-size: 18px; color: var(--ink); }
section.card .lede { margin: 4px 0 0; color: var(--muted); font-size: 13px; }

.row {
    display: grid; grid-template-columns: 200px 1fr;
    align-items: center; gap: 12px;
    padding: 10px 0; border-bottom: 1px dashed var(--line);
}
.row:last-child { border-bottom: 0; }
.row .key { color: var(--muted); font-size: 13px; }
.row .val { font-family: ui-monospace, "SF Mono", Menlo, Consolas, monospace; font-size: 13px; word-break: break-all; }
.row .val code { background: var(--bg); padding: 3px 8px; border-radius: 6px; border: 1px solid var(--line); }
.row.secret .val { display: flex; gap: 8px; align-items: center; }
.row.secret .val code.masked { letter-spacing: 0.1em; }
.row.secret button.reveal {
    border: 1px solid var(--line); background: white;
    border-radius: 6px; padding: 3px 10px; font-size: 12px;
    color: var(--salmon); cursor: pointer;
}
.row.secret button.reveal:hover { border-color: var(--salmon); }

.empty { color: var(--muted); font-style: italic; padding: 8px 0; }

section.failures {
    background: #fff3f3; border: 1px solid #f4b3b3; border-radius: 6px;
    padding: 14px 16px; margin-bottom: 18px; color: #6b1a1a;
}
section.failures h2 { margin: 0 0 6px; font-size: 16px; }
section.failures ul { margin: 6px 0 0 18px; }

footer {
    color: var(--muted); font-size: 12px; text-align: center;
    margin: 28px 0 12px;
}

@media print {
    body { background: white; }
    .wrap { margin: 0; padding: 0; max-width: 100%; }
    header.hero { background: white; color: var(--ink); border: 1px solid var(--line); }
    header.hero p { color: var(--muted); }
    .row.secret button.reveal { display: none; }
    .row.secret code.masked::after { content: attr(data-secret); letter-spacing: normal; }
    .row.secret code.masked { content-visibility: visible; }
    section.card { page-break-inside: avoid; }
}
</style>
</head>
<body>
<div class="wrap">

<header class="hero">
    <div class="logo">B</div>
    <div>
        <h1>${title}</h1>
        <p>Generated ${generated_at} · bento handoff report</p>
    </div>
</header>

<div class="summary">
    <div class="stat"><div class="label">Domain</div><div class="value">$(_html_escape "$base_domain")</div></div>
    <div class="stat"><div class="label">VPS IP</div><div class="value">$(_html_escape "$(state_get '.bootstrap.advertise_addr')")</div></div>
    <div class="stat"><div class="label">Apps deployed</div><div class="value">$(jq -r '.stacks // {} | length' "$BENTO_STATE_FILE")</div></div>
</div>
HTML

        _section_failures
        _section_vps
        _section_infra
        _section_apps

        cat <<'HTML'

<footer>
    Secrets are masked by default. Click <em>show</em> to reveal individual
    values. Print to PDF for offline distribution — secrets become visible
    automatically in the print stylesheet.
</footer>

</div>
<script>
function bentoReveal(btn) {
    var code = btn.parentNode.querySelector('code');
    if (code.dataset.shown === '1') {
        code.textContent = '••••••••••••••••';
        code.dataset.shown = '0';
        btn.textContent = 'show';
    } else {
        code.textContent = code.dataset.secret;
        code.dataset.shown = '1';
        btn.textContent = 'hide';
    }
}
</script>
</body>
</html>
HTML
    } > "$out"
}
