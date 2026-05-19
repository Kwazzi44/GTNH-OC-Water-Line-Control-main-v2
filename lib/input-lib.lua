-- lib/input-lib.lua
-- Неблокирующие утилиты ввода клавиатуры для GUI OpenComputers

local keyboard = require("keyboard")
local event = require("event")
local computer = require("computer")

local input = {}

-- Очистить очередь клавиатурных событий и направить их в обработчик
function input.drain(handler, maxEvents)
  maxEvents = maxEvents or 32
  for _ = 1, maxEvents do
    local ev, addr, char, code, player = event.pull(0)
    if not ev then
      break
    end
    if handler(ev, addr, char, code, player) then
      return true
    end
  end
  return false
end

-- Проверка, является ли событие клавиатурным
function input.isKeyEvent(ev)
  return ev == "key_down" or ev == "key_up"
end

-- Проверка на совпадение кода клавиши
function input.codeMatches(code, ...)
  for i = 1, select("#", ...) do
    if code == select(i, ...) then
      return true
    end
  end
  return false
end

-- Проверка на совпадение символа
function input.charMatches(char, ...)
  if char == nil then
    return false
  end
  for i = 1, select("#", ...) do
    if char == select(i, ...) then
      return true
    end
  end
  return false
end

-- Проверка, нажата ли определенная кнопка (учитывает как коды, так и символы)
function input.pressed(ev, code, char, keyConst, charCode)
  if not input.isKeyEvent(ev) then
    return false
  end
  if keyConst and code == keyConst then
    return true
  end
  if charCode and input.charMatches(char, charCode, charCode - 32, charCode + 32) then
    return true
  end
  return false
end

-- Ожидание клавиши с таймаутом и условием
function input.waitKey(timeout, predicate)
  local deadline = computer.uptime() + (timeout or math.huge)
  while true do
    local remaining = deadline - computer.uptime()
    if remaining <= 0 then
      return nil
    end
    local ev, addr, char, code, player = event.pull(math.min(remaining, 0.05))
    if ev and predicate(ev, addr, char, code, player) then
      return ev, addr, char, code, player
    end
  end
end

return input
