local M = { count = 0, failed = 0 }

function M.eq(actual, expected, message)
  M.count = M.count + 1
  if actual ~= expected then
    M.failed = M.failed + 1
    error((message or "values differ") .. ": expected " .. tostring(expected) ..
      ", got " .. tostring(actual), 2)
  end
end

function M.truthy(value, message) M.eq(not not value, true, message) end

function M.raises(fn, predicate, message)
  M.count = M.count + 1
  local ok, err = pcall(fn)
  if ok or (predicate and not predicate(err)) then
    M.failed = M.failed + 1
    error(message or "expected matching error", 2)
  end
  return err
end

return M

