#!/bin/bash
# bento — Cloudflare DNS API wrappers
#
# Optional integration. When the user provides a Cloudflare API token with
# Zone:DNS:Edit permission on the BASE_DOMAIN zone, bento can auto-create
# the wildcard + root A records that Traefik needs for Let's Encrypt to
# succeed in Step 2.
#
# Token scope (minimum):
#   - Token type:      Custom (or template "Edit zone DNS")
#   - Permissions:     Zone → DNS → Edit
#   - Zone Resources:  Include → Specific zone → <user's domain>
#
# Endpoints used:
#   GET  /user/tokens/verify
#   GET  /zones?name=<domain>
#   GET  /zones/<id>/dns_records?type=A&name=<fqdn>
#   POST /zones/<id>/dns_records
#   PUT  /zones/<id>/dns_records/<record_id>

readonly BENTO_CF_API="https://api.cloudflare.com/client/v4"

# Template URL that pre-fills the Cloudflare token creation form with the
# exact permission bento needs (DNS:Edit). The user lands directly on the
# review screen with the right scope already selected — they just click
# "Continue to summary" → "Create Token" → copy.
#
# Docs:
#   https://developers.cloudflare.com/fundamentals/api/how-to/account-owned-token-template/
readonly BENTO_CF_TOKEN_TEMPLATE_URL='https://dash.cloudflare.com/profile/api-tokens?permissionGroupKeys=%5B%7B%22key%22%3A%22dns%22%2C%22type%22%3A%22edit%22%7D%5D&zoneId=all&name=Bento%20DNS'

# Shared curl wrapper — adds Authorization, accepts trailing API path args.
cloudflare_api() {
    local method="$1"
    local path="$2"
    shift 2
    local token
    token="$(state_get '.bootstrap.cloudflare_api_token')"
    if [[ -z "$token" ]]; then
        echo "Cloudflare API token missing from state." >&2
        return 1
    fi
    if [[ "${BENTO_VERBOSE:-0}" == "1" ]]; then
        printf '→ cloudflare %s %s\n' "$method" "$path" >&2
    fi
    curl --silent --show-error -X "$method" "${BENTO_CF_API}${path}" \
        -H "Authorization: Bearer ${token}" \
        -H "Content-Type: application/json" \
        "$@"
}

# Returns 0 if the token is active. Echoes nothing on success.
cloudflare_verify_token() {
    local resp
    resp="$(cloudflare_api GET /user/tokens/verify)" || return 1
    [[ "$(jq -r '.success' <<< "$resp")" == "true" ]]
}

# Looks up the zone ID for a domain. Echoes the ID on success.
cloudflare_zone_id() {
    local domain="$1"
    local resp
    resp="$(cloudflare_api GET "/zones?name=${domain}")" || return 1
    if [[ "$(jq -r '.success' <<< "$resp")" != "true" ]]; then
        echo "Cloudflare zone lookup failed for ${domain}:" >&2
        jq -r '.errors // empty' <<< "$resp" >&2
        return 1
    fi
    local id
    id="$(jq -r '.result[0].id // empty' <<< "$resp")"
    if [[ -z "$id" ]]; then
        echo "Domain ${domain} is not in any zone reachable by this token." >&2
        return 1
    fi
    printf '%s' "$id"
}

# Echoes the DNS record ID if a record matching <type> + <name> exists in
# <zone_id>. Exit 1 (silent) if missing.
cloudflare_record_id() {
    local zone_id="$1"
    local type="$2"
    local name="$3"
    local resp id
    resp="$(cloudflare_api GET "/zones/${zone_id}/dns_records?type=${type}&name=${name}")" \
        || return 1
    id="$(jq -r '.result[0].id // empty' <<< "$resp")"
    [[ -n "$id" ]] && printf '%s' "$id"
}

# Creates or updates an A record so <name> in <zone> points to <content>.
# Idempotent: re-running with the same args is a no-op (record exists with
# the desired content). Wildcard names (`*.domain.com`) are accepted.
cloudflare_ensure_a_record() {
    local zone_id="$1"
    local name="$2"
    local content="$3"
    local ttl="${4:-1}"    # 1 = Cloudflare's "Auto" TTL
    local proxied="${5:-false}"

    local record_id current_content
    record_id="$(cloudflare_record_id "$zone_id" A "$name")"

    local payload
    payload=$(jq -n \
        --arg t  A \
        --arg n  "$name" \
        --arg c  "$content" \
        --argjson ttl     "$ttl" \
        --argjson proxied "$proxied" \
        '{type: $t, name: $n, content: $c, ttl: $ttl, proxied: $proxied}')

    if [[ -n "$record_id" ]]; then
        # Skip the network round-trip if content already matches.
        current_content="$(cloudflare_api GET \
            "/zones/${zone_id}/dns_records/${record_id}" \
            | jq -r '.result.content // empty')"
        if [[ "$current_content" == "$content" ]]; then
            return 0
        fi
        cloudflare_api PUT "/zones/${zone_id}/dns_records/${record_id}" \
            --data "$payload" > /dev/null
    else
        cloudflare_api POST "/zones/${zone_id}/dns_records" \
            --data "$payload" > /dev/null
    fi
}

# Ensures the two records bento needs:
#   *.<domain>  A  <advertise_addr>
#    <domain>   A  <advertise_addr>
# Caller must have set BASE_DOMAIN and ADVERTISE_ADDR in state.
cloudflare_sync_required_records() {
    local domain advertise zone_id
    domain="$(state_get '.bootstrap.base_domain')"
    advertise="$(state_get '.bootstrap.advertise_addr')"

    zone_id="$(cloudflare_zone_id "$domain")" || return 1
    state_set '.bootstrap.cloudflare_zone_id' "$zone_id"

    cloudflare_ensure_a_record "$zone_id" "*.${domain}" "$advertise" || return 1
    cloudflare_ensure_a_record "$zone_id" "$domain"     "$advertise" || return 1
}
