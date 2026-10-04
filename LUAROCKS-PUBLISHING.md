# LuaRocks publication

Canonical public source: AgentForge-Labs/agentrelay-lua.
Package: agentrelay-lua.
Initial rock version: 0.1.0-1.

Release flow validates the generated contract and hosted conformance, validates
and installs the rock in clean Lua environments, publishes the exact source
tag, uploads the rockspec with an AgentForge Labs LuaRocks API key, verifies
the registry version, and performs a clean public install smoke test.

The release workflow fails closed when LUAROCKS_API_KEY is absent. Publication
credentials must exist only in the protected GitHub environment and must never
be committed into source or embedded in the rock.

At implementation time this repository does not expose a LuaRocks publication
secret. Until an authorized AgentForge Labs LuaRocks API key is configured, the
source, rockspec, CI and verification workflow are ready but the final public
registry upload cannot be truthfully claimed.
