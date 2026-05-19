-- lib/logger.lua
-- Модуль логирования с поддержкой записи в файл, вывода на экран, буфера в памяти и отправки логов по сети

local logger = {}
local lineCount = 0
local memoryLogs = {}
local maxMemoryLogs = 50

-- Получить лог-события из памяти (для отображения в GUI)
function logger.getMemoryLogs()
  return memoryLogs
end

-- Добавить лог в память вручную (например, полученный по сети от Daemon)
function logger.pushMemoryLog(level, tag, message, time)
  table.insert(memoryLogs, {
    time = time or os.date("%H:%M:%S"),
    level = level:upper(),
    tag = tag,
    message = message
  })
  if #memoryLogs > maxMemoryLogs then
    table.remove(memoryLogs, 1)
  end
end

-- Создать новый объект логгера
function logger:new(config, prefix)
  local obj = {}
  obj.config = config or { level = "info", printToScreen = false, file = "waterline.log" }
  obj.prefix = prefix or ""

  local levels = { debug = 1, info = 2, warning = 3, error = 4 }

  local function log(level, message)
    local configLevel = levels[obj.config.level] or 2
    local messageLevel = levels[level] or 2

    if messageLevel >= configLevel then
      local time = os.date("%H:%M:%S")
      local tag = obj.prefix ~= "" and obj.prefix or "System"
      local formattedMessage = string.format("[%s] [%s] [%s] %s", time, level:upper(), tag, message)

      -- 1. Записать в локальный буфер в памяти
      table.insert(memoryLogs, {
        time = time,
        level = level:upper(),
        tag = tag,
        message = message
      })
      if #memoryLogs > maxMemoryLogs then
        table.remove(memoryLogs, 1)
      end

      -- 2. Отправить по сети (если это сервер Daemon)
      -- Избегаем циклического require, обращаясь к package.loaded
      local network = package.loaded["lib.network"]
      if network and network.modem and _G.waterline_role == "daemon" then
        pcall(function()
          network.broadcastLog(level, tag, message, time)
        end)
      end

      -- 3. Вывести на экран (если включено)
      if obj.config.printToScreen then
        print(formattedMessage)
      end

      -- 4. Записать в файл на диск
      if obj.config.file then
        lineCount = lineCount + 1
        local mode = "a"
        if lineCount >= 250 then
          mode = "w" -- Перетираем лог при превышении 250 строк, чтобы не забивать диск
          lineCount = 1
        end

        local f = io.open(obj.config.file, mode)
        if f then
          f:write(formattedMessage .. "\n")
          f:close()
        end
      end
    end
  end

  function obj:debug(message) log("debug", message) end
  function obj:info(message) log("info", message) end
  function obj:warning(message) log("warning", message) end
  function obj:error(message) log("error", message) end

  return obj
end

return logger
