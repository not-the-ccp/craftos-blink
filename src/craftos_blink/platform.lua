local M = {}

function M.now_ms()
  if type(os.epoch) == "function" then return os.epoch("utc") end
  return os.clock() * 1000
end

function M.cooperative_yield()
  if type(os.queueEvent) ~= "function" or type(os.pullEventRaw) ~= "function" then return nil end
  local marker = "craftos_blink_slice"
  local queued = {}
  os.queueEvent(marker)
  while true do
    local event = { os.pullEventRaw() }
    if event[1] == marker then break end
    if event[1] == "terminate" then
      for _, e in ipairs(queued) do os.queueEvent(unpack(e)) end
      return "terminate"
    end
    queued[#queued + 1] = event
  end
  for _, event in ipairs(queued) do os.queueEvent(unpack(event)) end
  return nil
end

return M

