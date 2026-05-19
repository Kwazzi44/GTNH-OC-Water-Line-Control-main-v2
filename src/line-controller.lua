-- src/line-controller.lua
-- Контроллер очистной установки (Water Purification Plant) с поддержкой горячего переподключения и защиты от сбоев

local event = require("event")
local componentDiscoverLib = require("lib.component-discover-lib")

local lineController = {}

function lineController:newFormConfig(config)
  return self:new(config or {})
end

function lineController:new(config)
  local obj = {}

  obj.config = config
  obj.controllerProxy = nil
  local lastWorkProgress = 0
  local lastReconnectTime = 0
  local reconnectInterval = 5 -- Пытаемся переподключиться каждые 5 секунд при потере связи

  -- Попытка найти прокси машины
  function obj:findMachineProxy()
    local lineCfg = self.config.lineController or self.config
    local machineName = lineCfg.machineName or "multimachine.purificationplant"
    
    local proxy = componentDiscoverLib.discoverGtMachine(machineName, lineCfg.machineAddress)
    if proxy then
      self.controllerProxy = proxy
      return true
    end
    return false
  end

  -- Инициализация
  function obj:init()
    self:findMachineProxy()
  end

  -- Основной цикл опроса
  function obj:loop()
    if self.controllerProxy == nil then
      -- Попытка восстановить подключение
      local computer = require("computer")
      local now = computer.uptime()
      if now - lastReconnectTime >= reconnectInterval then
        lastReconnectTime = now
        componentDiscoverLib.invalidateMachineCache()
        if self:findMachineProxy() then
          event.push("log_info", "[Line] Water Purification Plant reconnected successfully")
        end
      end
      return
    end

    -- Защищенный опрос состояния
    local ok, hasWork = pcall(self.controllerProxy.hasWork)
    if not ok then
      self.controllerProxy = nil
      event.push("log_warning", "[Line] Connection lost to Water Purification Plant")
      return
    end

    local ok2, workProgress = pcall(self.controllerProxy.getWorkProgress)
    if not ok2 or not workProgress then
      workProgress = 0
    end

    if lastWorkProgress > workProgress or (hasWork == false and lastWorkProgress ~= 0) then
      event.push("cycle_end")
      lastWorkProgress = 0
    end

    if hasWork then 
      lastWorkProgress = workProgress
    end
  end

  -- Получить состояние для вывода в GUI
  function obj:getState()
    if self.controllerProxy == nil then
      return "DISCONNECTED"
    end

    local ok, hasWork = pcall(self.controllerProxy.hasWork)
    if not ok then
      return "DISCONNECTED"
    end

    if hasWork then
      local ok2, progress = pcall(self.controllerProxy.getWorkProgress)
      local ok3, maxProgress = pcall(self.controllerProxy.getWorkMaxProgress)
      if ok2 and ok3 and progress and maxProgress and maxProgress > 0 then
        return tostring(math.ceil(progress / 20)) .. "/" .. tostring(math.ceil(maxProgress / 20))
      end
    end

    local ok4, allowed = pcall(self.controllerProxy.isWorkAllowed)
    if ok4 and allowed == false then
      return "Disabled"
    end

    return "Idle"
  end

  -- Отключить работу установки
  function obj:disable()
    if self.controllerProxy ~= nil then
      pcall(self.controllerProxy.setWorkAllowed, false)
    end
  end

  setmetatable(obj, self)
  self.__index = self
  return obj
end

return lineController
