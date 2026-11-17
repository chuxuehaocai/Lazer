-- This bridge handles requests during short, bounded timer callbacks. Never
-- block the serial Lua VM with a permanent accept loop or wait for player events.
local running, token, clients = false, nil, {}
local server_id, timer_id = "frontend", "frontend-pump"

host.add_setting({id="start", type="action", title="启动独立前端桥"})
host.add_setting({id="stop", type="action", title="停止独立前端桥"})
host.add_page({id="connection", title="独立前端连接", elements={
  {type="text", id="status", text="尚未启动。点击插件设置中的启动按钮。"},
  {type="text_field", id="url", title="WebSocket 地址", value=""},
  {type="text_field", id="token", title="本次连接令牌", value=""},
  {type="text", text="在浏览器打开本插件 frontend/index.html，复制地址和令牌。每次启动令牌都会更换。"},
}})

local function connection_page(status, url, secret)
  host.update_page_element({page="connection", id="status", text=status})
  host.update_page_element({page="connection", id="url", value=url or ""})
  host.update_page_element({page="connection", id="token", value=secret or ""})
end

local function socket(operation, extra)
  local spec = {id=server_id, operation=operation}
  for key, value in pairs(extra or {}) do spec[key] = value end
  return host.websocket_server(spec)
end

local function stop()
  running = false
  host.timer({operation="cancel", id=timer_id})
  if token then pcall(socket, "close") end
  token, clients = nil, {}
  connection_page("已停止。", "", "")
end

local function start()
  stop()
  local config = host.json_decode(host.resource("bridge.json"))
  local server = socket("listen", {host="127.0.0.1", port=config.port, path="/lazer"})
  token, clients = host.random_hex(32), {}
  running = true
  host.timer({id=timer_id, intervalMs=100})
  connection_page("运行中。数据权限会在首次使用时由 Lazer 单独询问。",
    "ws://127.0.0.1:" .. server.port .. "/lazer", token)
end

local player_commands = {play=true, pause=true, toggle=true, stop=true,
  next=true, previous=true, seek=true, volume=true, play_index=true,
  shuffle=true, ["repeat"]=true}
local library_operations = {playlists=true, tracks=true, album=true,
  search=true, ["local"]=true, play=true}
local user_operations = {profile=true, platforms=true, statistics=true}
local scopes = {library=true, profile=true, history=true}

local function dispatch(method, args)
  if method == "state" then return host.player_state() end
  if method == "queue" then return host.player_queue() end
  if method == "lyrics" then return host.player_lyrics() end
  if method == "permissions" then return host.permissions() end
  if method == "permission" and scopes[args.scope] then
    return host.request_permission(args.scope)
  end
  if method == "player" and player_commands[args.command] then
    return host.player_control(args)
  end
  if method == "library" and library_operations[args.operation] then
    return host.library(args)
  end
  if method == "user" and user_operations[args.operation] then
    return host.user(args)
  end
  error("Unsupported request")
end

local function close_client(id)
  clients[id] = nil
  pcall(socket, "close_client", {clientId=id})
end

local function handle(id, session, data)
  if type(data) ~= "string" or string.len(data) > 65536 then close_client(id); return end
  local valid, request = pcall(host.json_decode, data)
  if not valid or type(request) ~= "table" or type(request.id) ~= "number"
      or request.id < 0 or request.id > 9007199254740991
      or type(request.method) ~= "string"
      or (request.args ~= nil and type(request.args) ~= "table") then
    close_client(id); return
  end
  local args, success, result = request.args or {}, false, nil
  if not session.authenticated then
    success = request.method == "hello" and args.token == token
    if success then session.authenticated = true; result = {version=1} end
  elseif request.method ~= "hello" then
    success, result = pcall(dispatch, request.method, args)
  end
  local response = {id=request.id, ok=success}
  if success then response.result = result
  else response.error = "Request denied or unavailable" end
  local sent = pcall(socket, "send", {clientId=id, data=host.json_encode(response)})
  if not sent or not session.authenticated then close_client(id) end
end

local function pump()
  if not running then return end
  for _ = 1, 8 do
    local accepted = socket("accept", {timeoutMs=0})
    if not accepted then break end
    clients[accepted.clientId] = {authenticated=false, since=host.now()}
  end
  local live = {}
  for _, id in ipairs(socket("clients")) do live[id] = true end
  local remaining = 16
  for id, session in pairs(clients) do
    if not live[id] or (not session.authenticated and host.now() - session.since > 10000) then
      close_client(id)
    elseif remaining > 0 then
      -- One message per client per tick keeps an aggressive peer from starving
      -- the other clients or normal host calls. Socket queues are also bounded.
      local data = socket("receive", {clientId=id, timeoutMs=0})
      if data then
        remaining = remaining - 1
        handle(id, session, data)
      end
    end
  end
end

return {call=function(operation, args)
  if operation == "describe" then return {providers={}} end
  if operation == "timer" and args.id == timer_id then pump(); return true end
  if operation == "setting_changed" then
    if args.id == "start" then start(); return true end
    if args.id == "stop" then stop(); return true end
  end
end}
