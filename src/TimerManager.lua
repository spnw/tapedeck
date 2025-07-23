local function remove_timer(timer)
  if renoise.tool():has_timer(timer) then
    renoise.tool():remove_timer(timer)
  end
end

class "TimerManager"

function TimerManager:__init()
  self.timers = {}
end

function TimerManager:schedule(delay, fn, args)
  local timer
  timer = function()
    local continue
    continue, args = fn(unpack(args or {}))
    if not continue then remove_timer(timer) end
  end
  renoise.tool():add_timer(timer, delay)
  table.insert(self.timers, timer)
end

function TimerManager:cancel_all()
  for _, timer in ipairs(self.timers) do
    remove_timer(timer)
  end
  self.timers = {}
end
