-- No timer or native work at import. A user action triggers each operation.
host.add_setting({id="diagnose", type="action", title="Read audio diagnostics"})
host.add_setting({id="floating", type="action", title="Enable floating lyrics"})
host.add_setting({id="off", type="action", title="Disable lyrics overlay"})
host.add_page({id="diagnostics", title="Native audio diagnostics", elements={
  {id="result", type="text", text="Use a plugin action to request a snapshot."},
}})

local function execute(id)
  if id == "diagnose" then
    local capabilities = host.native()
    if not capabilities.operations["audio.status"].supported then
      return {ok=false, supported=false, error={code="native_engine_unavailable"}}
    end
    local audio = host.native({operation="audio.status"})
    local devices = host.native({operation="audio.devices"})
    return {audio=audio, devices=devices}
  end
  if id == "floating" then
    return host.native({operation="lyrics.configure", mode="floating", lines=3})
  end
  if id == "off" then
    return host.native({operation="lyrics.configure", mode="off"})
  end
  return {ok=false, error={code="unknown_action"}}
end

return {call=function(operation, args)
  if operation == "describe" then return {providers={}} end
  if operation == "setting_changed" then
    local success, result = pcall(execute, args.id)
    if not success then result = {ok=false, error={code="permission_denied_or_inactive"}} end
    host.update_page_element({page="diagnostics", id="result", text=host.json_encode(result)})
    return result
  end
end}
