local socket = require("socket")
local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local url = require("socket.url")
local json = require("dkjson")
local operations = require("agentrelay.generated")

local M = {
  VERSION = "0.1.0",
  MANAGED_ORIGIN = "https://relay.web-tasarimci.com",
}

local RETRYABLE = { [429] = true, [502] = true, [503] = true, [504] = true }
local key_counter = 0

local Error = {}
Error.__index = Error
function Error:__tostring()
  return string.format("AgentRelay %s (%s): %s", tostring(self.code), tostring(self.status), tostring(self.message))
end
M.Error = Error

local Client = {}
Client.__index = Client
M.Client = Client

local function fail(message, level)
  error(message, (level or 1) + 1)
end

local function redact(value, credential)
  if value == nil then return nil end
  local text = tostring(value)
  if credential and credential ~= "" then
    text = text:gsub(credential:gsub("([^%w])", "%%%1"), "[REDACTED]")
  end
  return text
end

local function header(headers, name)
  name = string.lower(name)
  for k, v in pairs(headers or {}) do
    if string.lower(k) == name then return v end
  end
  return nil
end

local function escape_component(value)
  return (url.escape(tostring(value)):gsub("+", "%%20"))
end

local function encode_query(query)
  if not query then return "" end
  local parts = {}
  for k, v in pairs(query) do
    if v ~= nil then
      if type(v) == "table" then
        for _, item in ipairs(v) do
          parts[#parts + 1] = escape_component(k) .. "=" .. escape_component(item)
        end
      else
        parts[#parts + 1] = escape_component(k) .. "=" .. escape_component(v)
      end
    end
  end
  table.sort(parts)
  if #parts == 0 then return "" end
  return "?" .. table.concat(parts, "&")
end

local function default_transport(req, timeout)
  local sink = {}
  local source = req.body and ltn12.source.string(req.body) or nil
  local mod = req.url:sub(1, 8) == "https://" and https or http
  local old_timeout = mod.TIMEOUT
  mod.TIMEOUT = timeout
  local ok, code, headers, status = mod.request({
    url = req.url,
    method = req.method,
    headers = req.headers,
    source = source,
    sink = ltn12.sink.table(sink),
    redirect = false,
  })
  mod.TIMEOUT = old_timeout
  if ok == nil then
    return nil, tostring(code or status or "network request failed")
  end
  return {
    status = tonumber(code) or 0,
    headers = headers or {},
    body = table.concat(sink),
    status_line = status,
  }
end

local function new_key()
  key_counter = key_counter + 1
  local micros = math.floor((socket.gettime and socket.gettime() or os.time()) * 1000000)
  return string.format("lua-%x-%x-%x", micros, key_counter, math.random(0, 0x7fffffff))
end

local function parse_origin(origin)
  if type(origin) ~= "string" then fail("origin must be a string", 2) end
  local scheme, authority, rest = origin:match("^(https?)://([^/]+)(.*)$")
  if not scheme or not authority then fail("origin must be an HTTPS origin", 2) end
  if authority:find("@", 1, true) then fail("origin must not contain credentials", 2) end
  if rest ~= "" and rest ~= "/" then fail("origin must not contain path, query, or fragment", 2) end
  local host = authority:gsub(":%d+$", "")
  local loopback = scheme == "http" and (host == "localhost" or host == "127.0.0.1" or host == "[::1]")
  return scheme, loopback
end

local function safe_path(path)
  if type(path) ~= "string" or path:sub(1, 4) ~= "/v1/" then fail("only public v1 paths are allowed", 2) end
  if path:find("://", 1, true) or path:find("?", 1, true) or path:find("#", 1, true) or path:find("\\", 1, true) then
    fail("invalid public v1 path", 2)
  end
  if path:find("//", 1, true) or path:match("/%.%.?/") or path:match("/%.%.?$") then fail("invalid path traversal", 2) end
  if not (path == "/v1/service" or path == "/v1/workspaces" or path:sub(1, 15) == "/v1/workspaces/") then
    fail("private paths are not available through the hosted client", 2)
  end
  for segment in path:gmatch("[^/]+") do
    if segment == "admin" or segment == "saas-admin" or segment == "internal" or segment == "webhooks"
       or segment == "payments" or segment == "checkout" then
      fail("private paths are not available through the hosted client", 2)
    end
  end
  return path
end

local function make_error(status, body, credential, fallback)
  local parsed = json.decode(body or "")
  local detail = type(parsed) == "table" and parsed.error or nil
  if type(detail) ~= "table" then detail = {} end
  local err = setmetatable({
    status = status or 0,
    code = redact(detail.code or fallback or "HTTP_ERROR", credential),
    message = redact(detail.message or "request failed", credential),
    request_id = redact(detail.requestId, credential),
    retry_after_seconds = tonumber(detail.retryAfterSeconds),
    upgrade_url = redact(detail.upgradeUrl, credential),
    account_url = redact(detail.accountUrl, credential),
    quota_used = tonumber(detail.quotaUsed),
    quota_limit = tonumber(detail.quotaLimit),
    quota_reset_at = redact(detail.quotaResetAt, credential),
  }, Error)
  return err
end

local function exact_keys(actual, expected)
  local want = {}
  for _, key in ipairs(expected or {}) do want[key] = true end
  local count = 0
  for key, _ in pairs(actual or {}) do
    if not want[key] then return false end
    count = count + 1
  end
  return count == #(expected or {})
end

function M.new(opts)
  opts = opts or {}
  local api_key, bearer = opts.api_key, opts.bearer_token
  if (api_key and bearer) or (not api_key and not bearer) or api_key == "" or bearer == "" then
    fail("provide exactly one non-empty API key or Bearer token", 2)
  end
  local origin = (opts.origin or M.MANAGED_ORIGIN):gsub("/$", "")
  local scheme, loopback = parse_origin(origin)
  if scheme ~= "https" and not (opts.allow_insecure_loopback and loopback) then
    fail("origin must be HTTPS", 2)
  end
  if origin ~= M.MANAGED_ORIGIN and not opts.allow_custom_origin then
    fail("custom origin requires allow_custom_origin=true", 2)
  end
  local timeout = tonumber(opts.timeout or 15)
  local retries = tonumber(opts.retries or 1)
  if not timeout or timeout <= 0 then fail("timeout must be positive", 2) end
  if not retries or retries < 0 or retries % 1 ~= 0 then fail("retries must be a nonnegative integer", 2) end
  return setmetatable({
    credential = api_key or bearer,
    origin = origin,
    timeout = timeout,
    retries = retries,
    transport = opts.transport or default_transport,
    user_agent = "agentrelay/" .. M.VERSION .. " lua",
  }, Client)
end

function Client:__tostring()
  return string.format("AgentRelayClient(origin=%s, credential=[REDACTED])", self.origin)
end

function Client:request(method, path, opts)
  opts = opts or {}
  method = string.upper(method or "GET")
  if not ({GET=true,POST=true,PUT=true,PATCH=true,DELETE=true})[method] then fail("unsupported HTTP method", 2) end
  path = safe_path(path)
  if method ~= "GET" and not opts.billable then fail("extension writes must declare billable=true", 2) end
  if method == "GET" and opts.billable then fail("GET cannot be billable", 2) end

  local idempotency_key = opts.idempotency_key
  if opts.billable then
    idempotency_key = idempotency_key or new_key()
    if #idempotency_key < 8 or #idempotency_key > 200 then fail("invalid idempotency key length", 2) end
  end

  local body, content_type = opts.body, opts.content_type
  if type(body) == "table" then
    body = json.encode(body)
    content_type = content_type or "application/json"
  elseif body ~= nil and type(body) ~= "string" then
    fail("body must be table, string, or nil", 2)
  end

  local headers = {
    ["Authorization"] = "Bearer " .. self.credential,
    ["User-Agent"] = self.user_agent,
    ["Accept"] = "application/json, application/octet-stream",
  }
  if content_type then headers["Content-Type"] = content_type end
  if body then headers["Content-Length"] = tostring(#body) end
  if idempotency_key then headers["Idempotency-Key"] = idempotency_key end

  local retry_enabled = opts.retry == true and (method == "GET" or idempotency_key ~= nil)
  local attempts = retry_enabled and (self.retries + 1) or 1
  local last_error
  for attempt = 1, attempts do
    local response, network_error = self.transport({
      method = method,
      url = self.origin .. path .. encode_query(opts.query),
      headers = headers,
      body = body,
    }, self.timeout)
    if not response then
      last_error = setmetatable({status=0, code="NETWORK_ERROR", message="network request failed"}, Error)
    else
      local status = tonumber(response.status) or 0
      if status >= 200 and status < 300 then
        local media = tostring(header(response.headers, "content-type") or "")
        if media:lower():find("json", 1, true) and response.body ~= "" then
          local decoded, _, err = json.decode(response.body)
          if err then error(setmetatable({status=0, code="INVALID_RESPONSE", message="invalid JSON response"}, Error), 0) end
          return decoded
        end
        return response.body or ""
      end
      last_error = make_error(status, response.body, self.credential)
      if last_error.code == "QUOTA_EXCEEDED" then error(last_error, 0) end
      if not RETRYABLE[status] then error(last_error, 0) end
    end
    if attempt < attempts then socket.sleep(math.min(0.25 * (2 ^ (attempt - 1)), 2.0)) end
  end
  error(last_error or setmetatable({status=0,code="NETWORK_ERROR",message="network request failed"}, Error), 0)
end

local function multipart(fields)
  local boundary = "agentrelay-" .. new_key():gsub("[^%w]", "")
  local chunks = {}
  for name, value in pairs(fields) do
    if type(name) ~= "string" or name:find('[\r\n"]') then fail("invalid multipart field name", 2) end
    local head = "--" .. boundary .. "\r\nContent-Disposition: form-data; name=\"" .. name .. "\""
    if name == "file" then
      if type(value) ~= "string" then fail("file must be a binary string", 2) end
      local filename = tostring(fields.filename or "upload.bin")
      if filename:find('[\r\n"\\/]') then fail("invalid filename", 2) end
      head = head .. "; filename=\"" .. filename .. "\"\r\nContent-Type: application/octet-stream"
    end
    chunks[#chunks + 1] = head .. "\r\n\r\n" .. tostring(value) .. "\r\n"
  end
  chunks[#chunks + 1] = "--" .. boundary .. "--\r\n"
  return table.concat(chunks), "multipart/form-data; boundary=" .. boundary
end

function Client:call(operation_id, opts)
  opts = opts or {}
  local op = operations[operation_id]
  if not op then fail("unknown operation: " .. tostring(operation_id), 2) end
  local path_params = opts.path or {}
  if not exact_keys(path_params, op.path_params) then fail("path parameters do not match operation", 2) end

  local allowed_query = {}
  for _, key in ipairs(op.query_params or {}) do allowed_query[key] = true end
  for key, _ in pairs(opts.query or {}) do
    if not allowed_query[key] then fail("query parameters do not match operation", 2) end
  end

  local route = op.path
  for _, key in ipairs(op.path_params or {}) do
    local value = path_params[key]
    if type(value) ~= "string" or value == "" or value:find("/", 1, true) then fail("invalid path parameter", 2) end
    route = route:gsub("{" .. key .. "}", escape_component(value))
  end

  local body, content_type = opts.body, op.request_media
  if content_type == "multipart/form-data" and type(body) == "table" then
    body, content_type = multipart(body)
  end
  return self:request(op.method, route, {
    query = opts.query,
    body = body,
    content_type = content_type,
    idempotency_key = opts.idempotency_key,
    billable = op.idempotent_write,
    retry = true,
  })
end

function Client:list_workspaces(opts)
  opts = opts or {}
  return self:call("listWorkspaces", {query={cursor=opts.cursor, limit=opts.limit or 50}})
end
function Client:list_agents(workspace_id, opts)
  opts = opts or {}
  return self:call("listAgents", {path={workspaceId=workspace_id}, query={cursor=opts.cursor, limit=opts.limit or 50}})
end
function Client:send_message(workspace_id, agent_id, text, opts)
  opts = opts or {}
  return self:call("sendAgentMessage", {
    path={workspaceId=workspace_id, agentId=agent_id},
    body={text=text, parseMode=opts.parse_mode or "plain"},
    idempotency_key=opts.idempotency_key,
  })
end
Client.send_notification = Client.send_message
function Client:send_file(workspace_id, agent_id, file, opts)
  opts = opts or {}
  local body={kind=opts.kind or "document", file=file, filename=opts.filename or "upload.bin"}
  if opts.caption ~= nil then body.caption=opts.caption end
  return self:call("sendAgentFile", {path={workspaceId=workspace_id,agentId=agent_id}, body=body, idempotency_key=opts.idempotency_key})
end
function Client:list_inbox(workspace_id, agent_id, opts)
  opts = opts or {}
  return self:call("listInboxEvents", {path={workspaceId=workspace_id,agentId=agent_id}, query={cursor=opts.cursor,limit=opts.limit or 50}})
end
function Client:get_inbox_event(workspace_id, agent_id, event_id)
  return self:call("getInboxEvent", {path={workspaceId=workspace_id,agentId=agent_id,eventId=event_id}})
end
function Client:reply(workspace_id, agent_id, event_id, text, opts)
  opts = opts or {}
  return self:call("replyToInboxEvent", {
    path={workspaceId=workspace_id,agentId=agent_id,eventId=event_id},
    body={text=text, parseMode=opts.parse_mode or "plain"},
    idempotency_key=opts.idempotency_key,
  })
end
function Client:reply_file(workspace_id, agent_id, event_id, file, opts)
  opts = opts or {}
  local body={kind=opts.kind or "document", file=file, filename=opts.filename or "upload.bin"}
  if opts.caption ~= nil then body.caption=opts.caption end
  return self:call("replyToInboxEventWithFile", {
    path={workspaceId=workspace_id,agentId=agent_id,eventId=event_id},
    body=body, idempotency_key=opts.idempotency_key,
  })
end
function Client:download_file(workspace_id, agent_id, file_id)
  return self:call("downloadAgentFile", {path={workspaceId=workspace_id,agentId=agent_id,fileId=file_id}})
end

return M
