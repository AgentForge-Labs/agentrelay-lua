# AgentRelay for Lua

Official thin Lua/LuaJIT client for the hosted AgentRelay managed service. It is
not the self-hosted AgentForge Telegram Gateway and it does not contain the
backend. Normal calls use AgentRelay workspace/agent IDs; callers never paste
Telegram bot tokens or Telegram chat IDs into this client.

## Install

After the public LuaRocks release is activated:

    luarocks install agentrelay-lua

Supported runtimes are Lua 5.1, 5.2, 5.3, 5.4 and LuaJIT where LuaSocket,
LuaSec and dkjson are available.

## Free-account quickstart

Create a free hosted account at https://relay.web-tasarimci.com/account and
create an API key. The hosted free entitlement is enforced by the service; the
client never implements quota bypasses or local unlimited mode.

    local agentrelay = require("agentrelay")
    local relay = agentrelay.new({ api_key = os.getenv("AGENTRELAY_API_KEY") })
    local result = relay:send_message(
      "workspace-id", "agent-id", "Hello from Lua",
      { idempotency_key = "order-12345" }
    )
    print(result.deliveryId)

Billable writes always carry an Idempotency-Key. Automatic retries reuse the
same key. Auth, quota and delivery failures are structured AgentRelay error
objects, and credential values are redacted from error text.

## Product boundary

This rock is hosted-commercial client code only. The community package
agentforge-telegram-gateway remains a separate self-hosted product and does not
consume AgentRelay cloud quota. This Lua rock contains no Telegram bot token,
chat ID, server-side quota logic, tenant database code or publication secret.

The pinned openapi.snapshot.json and generated.lua represent the contract used
by this client version. Backward-compatible server changes do not force a new
rock; a LuaRocks release is intentional only when the Lua client artifact
changes.
