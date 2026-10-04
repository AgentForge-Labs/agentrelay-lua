package = "agentrelay-lua"
version = "0.1.0-1"
source = {
  url = "git+https://github.com/AgentForge-Labs/agentrelay-lua.git",
  tag = "v0.1.0"
}
description = {
  summary = "Official thin Lua client for the hosted AgentRelay service",
  detailed = [[AgentRelay is the hosted notification relay. This rock contains only a thin client and generated public API metadata. It does not ship the Telegram Gateway backend, Telegram bot tokens, chat IDs, or registry secrets.]],
  homepage = "https://github.com/AgentForge-Labs/agentrelay-lua",
  license = "AGPL-3.0-or-later"
}
dependencies = {
  "lua >= 5.1, < 5.5",
  "luasocket >= 3.1.0",
  "luasec >= 1.3.0",
  "dkjson >= 2.6"
}
build = {
  type = "builtin",
  modules = {
    ["agentrelay"] = "src/agentrelay.lua",
    ["agentrelay.generated"] = "src/agentrelay/generated.lua"
  }
}
