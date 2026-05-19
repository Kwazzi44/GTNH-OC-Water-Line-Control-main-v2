-- lib/network.lua
-- Модуль сетевого взаимодействия для связи между GUI и Daemon через модем OpenComputers

local component = require("component")
local serialization = require("serialization")
local event = require("event")

local network = {
  port = 2424,
  modem = nil,
  listeners = {}
}

-- Инициализация сетевого соединения
function network.init(port)
  network.port = port or 2424
  if component.isAvailable("modem") then
    network.modem = component.modem
    network.modem.open(network.port)
    
    -- Для беспроводных плат устанавливаем радиус действия (по умолчанию 0)
    if network.modem.isWireless and network.modem.isWireless() then
      pcall(function() network.modem.setStrength(400) end)
    end
    
    return true
  else
    return false, "Modem component not found"
  end
end

-- Отправить сообщение (широковещательно)
local function broadcast(header, ...)
  if not network.modem then return false, "Modem not initialized" end
  local args = {...}
  local payload = serialization.serialize({ header = header, data = args })
  network.modem.broadcast(network.port, "waterline_msg", payload)
  return true
end

-- Отправка состояния (Daemon -> GUI)
function network.broadcastState(stateData)
  return broadcast("state", stateData)
end

-- Отправка лога (Daemon -> GUI)
function network.broadcastLog(level, tag, message, time)
  return broadcast("log", level, tag, message, time)
end

-- Отправка управляющей команды (GUI -> Daemon)
function network.sendCommand(cmdName, ...)
  return broadcast("cmd", cmdName, ...)
end

-- Отправка файла обновления (GUI -> Daemon)
function network.sendUpdateFile(filePath, fileContent)
  return broadcast("update_file", filePath, fileContent)
end

-- Сигналы начала и конца обновления
function network.sendUpdateStart()
  return broadcast("update_start")
end

-- Сигналы начала и конца обновления
function network.sendUpdateEnd()
  return broadcast("update_end")
end

-- Регистрация обработчиков сетевых сообщений
-- Обработчик вызывается при поступлении сообщений waterline_msg
function network.startListening(callbacks)
  network.listeners = callbacks or {}

  local function onModemMessage(_, localAddress, remoteAddress, port, distance, messageType, payload)
    if port ~= network.port or messageType ~= "waterline_msg" then
      return
    end

    local success, packet = pcall(serialization.unserialize, payload)
    if not success or not packet or type(packet) ~= "table" then
      return
    end

    local header = packet.header
    local data = packet.data or {}

    if header == "state" and network.listeners.onState then
      network.listeners.onState(remoteAddress, unpack(data))
    elseif header == "log" and network.listeners.onLog then
      network.listeners.onLog(remoteAddress, unpack(data))
    elseif header == "cmd" and network.listeners.onCmd then
      network.listeners.onCmd(remoteAddress, unpack(data))
    elseif header == "update_file" and network.listeners.onUpdateFile then
      network.listeners.onUpdateFile(remoteAddress, unpack(data))
    elseif header == "update_start" and network.listeners.onUpdateStart then
      network.listeners.onUpdateStart(remoteAddress, unpack(data))
    elseif header == "update_end" and network.listeners.onUpdateEnd then
      network.listeners.onUpdateEnd(remoteAddress, unpack(data))
    end
  end

  event.listen("modem_message", onModemMessage)
  network.modemMessageCallback = onModemMessage
end

-- Остановка прослушивания
function network.stopListening()
  if network.modemMessageCallback then
    event.ignore("modem_message", network.modemMessageCallback)
    network.modemMessageCallback = nil
  end
end

return network
