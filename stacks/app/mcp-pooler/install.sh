#!/bin/bash
# mcp-pooler post-deploy notes.
#
# The pooler is a stateless caching proxy — no database and no volumes to set up.
# It opens ONE persistent session to the MetaMCP namespace given by
# MCP_POOLER_UPSTREAM_URL (auth: MCP_POOLER_UPSTREAM_KEY) and re-exposes it on
# network_public as  ${BENTO_STACK_KEY}_pooler:9100  with a cached tools/list.
set -euo pipefail

cat <<EOF

  mcp-pooler — deployed.

  Endpoint (internal overlay):  http://${BENTO_STACK_KEY}_pooler:9100/mcp/
  Health:                       http://${BENTO_STACK_KEY}_pooler:9100/health

  Point your ephemeral MCP clients at the pooler instead of the MetaMCP namespace
  directly. For Hermes, set the data MCP server URL to the endpoint above — agents
  then get native tool discovery within their short discovery window.

  The MetaMCP admin stays the source of truth for the catalog; new MCPs appear
  through the pooler within MCP_POOLER_REFRESH_SEC (default 45s).

EOF
