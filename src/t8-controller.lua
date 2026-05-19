-- src/t8-controller.lua
-- Контроллер для T8 очищенной воды (Cosmic Water) с поддержкой горячего переподключения и автозаказом кварков в ME-сети

local sides = require("sides")
local event = require("event")
local computer = require("computer")

local stateMachineLib = require("lib.state-machine-lib")
local componentDiscoverLib = require("lib.component-discover-lib")
local gtSensorParserLib = require("lib.gt-sensor-parser")
local cycleEndLib = require("lib.cycle-end-lib")

local t8controller = {}

function t8controller:newFormConfig(config)
  return self:new(config)
end

function t8controller:new(config)
  local obj = {}

  obj.config = config
  obj.maxQuarkCount = config.maxQuarkCount or 4

  obj.transposerProxy = nil
  obj.subMeInterfaceProxy = nil
  obj.controllerProxy = nil
  obj.gtSensorParser = nil

  obj.stateMachine = stateMachineLib:new()
  obj.transposerItems = {}
  obj._hadWorkDuringCycle = false
  obj._meCraftQueue = nil
  obj._meCraftCooldown = 4
  obj._meCraftBatchSize = 2

  local lastReconnectTime = 0
  local reconnectInterval = 5
  local initCompleted = false

  -- Проверка статуса датчика
  function obj:_sensorHasYes()
    if not self.gtSensorParser or not self.gtSensorParser.sensorData then
      return false
    end
    local line = #self.gtSensorParser.sensorData
    if line < 1 then
      return false
    end
    return self.gtSensorParser:stringHasAny(line, { "Yes", "yes", "YES" }) == true
  end

  -- Подключение оборудования тира T8
  function obj:connectHardware()
    local machineName = self.config.machineName or "multimachine.purificationunitextractor"

    -- 1. Ищем саму машину GregTech
    local ctrl = componentDiscoverLib.discoverGtMachine(machineName, self.config.machineAddress)
    if not ctrl then
      return false, "Extractor Unit not found"
    end
    self.controllerProxy = ctrl
    self.gtSensorParser = gtSensorParserLib:new(ctrl)

    -- 2. Ищем транспозер
    local trans, err1 = componentDiscoverLib.discoverProxy(
      self.config.transposerAddress,
      "[T8] Transposer",
      "transposer")
    if not trans then return false, err1 or "Transposer not found" end
    self.transposerProxy = trans

    -- 3. Ищем ME-интерфейс
    local meInt, err2 = componentDiscoverLib.discoverProxy(
      self.config.subMeInterfaceAddress,
      "[T8] Sub Me Interface",
      "me_interface")
    if not meInt then return false, err2 or "Sub ME Interface not found" end
    self.subMeInterfaceProxy = meInt

    -- 4. Ищем катализаторы кварков у транспозера
    local catalysts = {
      "Up-Quark Releasing Catalyst",
      "Down-Quark Releasing Catalyst",
      "Strange-Quark Releasing Catalyst",
      "Charm-Quark Releasing Catalyst",
      "Bottom-Quark Releasing Catalyst",
      "Top-Quark Releasing Catalyst"
    }
    local result, skipped = componentDiscoverLib.discoverTransposerItemStorage(trans, catalysts, {sides.up})
    if #skipped ~= 0 then
      return false, "Can't find quarks: " .. table.concat(skipped, ", ")
    end

    for key, value in pairs(result) do
      self.transposerItems[key] = value
    end

    return true
  end

  function obj:_initBody()
    local ok, err = self:connectHardware()
    if not ok then
      event.push("log_warning", "[T8] Hardware connection failed: " .. tostring(err))
    end

    -- Настройка конечного автомата
    self.stateMachine.states.idle = self.stateMachine:createState("Idle")
    self.stateMachine.states.idle.update = function()
      if not self.controllerProxy then return end
      local ok_hw, hasWork = pcall(self.controllerProxy.hasWork)
      if ok_hw and hasWork then
        if self:_sensorHasYes() then
          self.stateMachine:setState(self.stateMachine.states.waitEnd)
        else
          self.stateMachine:setState(self.stateMachine.states.putFirst)
        end
      end
    end

    self.stateMachine.states.putFirst = self.stateMachine:createState("Put First")
    self.stateMachine.states.putFirst.init = function()
      if self:putQuarks(1) then
        self.stateMachine:setState(self.stateMachine.states.resultPutFirst)
      end
    end

    self.stateMachine.states.resultPutFirst = self.stateMachine:createState("Result Put First")
    self.stateMachine.states.resultPutFirst.update = function()
      if self:_sensorHasYes() then
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
      else
        self.stateMachine:setState(self.stateMachine.states.putSecond)
      end
    end

    self.stateMachine.states.putSecond = self.stateMachine:createState("Put Second")
    self.stateMachine.states.putSecond.init = function()
      if self:putQuarks(2) then
        self.stateMachine:setState(self.stateMachine.states.resultPutSecond)
      end
    end

    self.stateMachine.states.resultPutSecond = self.stateMachine:createState("Result Put Second")
    self.stateMachine.states.resultPutSecond.update = function()
      if self:_sensorHasYes() then
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
      else
        self.stateMachine:setState(self.stateMachine.states.putThird)
      end
    end

    self.stateMachine.states.putThird = self.stateMachine:createState("Put Third")
    self.stateMachine.states.putThird.init = function()
      if self:putQuarks(3) then
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
      end
    end

    self.stateMachine.states.waitEnd = self.stateMachine:createState("Wait End")

    self.stateMachine.states.craftQuarks = self.stateMachine:createState("Craft Quarks")
    self.stateMachine.states.craftQuarks.init = function()
      self.stateMachine.data.craftWaitTime = computer.uptime() + 3
    end
    self.stateMachine.states.craftQuarks.update = function()
      if computer.uptime() < self.stateMachine.data.craftWaitTime then
        return
      end

      if not self.subMeInterfaceProxy then
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      if self._meCraftBusyUntil and computer.uptime() < self._meCraftBusyUntil then
        return
      end

      -- Автозаказ катализаторов кварков в ME сети
      if not self._meCraftQueue then
        self._meCraftQueue = {}
        local ok_items, quarks = pcall(self.subMeInterfaceProxy.getItemsInNetwork, { name = "gregtech:gt.metaitem.03" })
        if ok_items and quarks then
          for _, quark in pairs(quarks) do
            if quark.label ~= "Unaligned Quark Releasing Catalyst" and quark.size < self.maxQuarkCount then
              table.insert(self._meCraftQueue, quark)
            end
          end
        end
      end

      local processed = 0
      while #self._meCraftQueue > 0 and processed < self._meCraftBatchSize do
        local quark = table.remove(self._meCraftQueue, 1)
        local ok_crafts, crafts = pcall(self.subMeInterfaceProxy.getCraftables, { label = quark.label })

        if not ok_crafts or not crafts or crafts[1] == nil then
          event.push("log_warning", "[T8] No craft for: " .. quark.label)
          pcall(self.controllerProxy.setWorkAllowed, false)
        else
          pcall(crafts[1].request, self.maxQuarkCount - quark.size)
        end

        processed = processed + 1
      end

      if #self._meCraftQueue > 0 then
        self._meCraftBusyUntil = computer.uptime() + self._meCraftCooldown
        return
      end

      self._meCraftQueue = nil
      self._meCraftBusyUntil = nil
      self.stateMachine:setState(self.stateMachine.states.idle)
    end

    cycleEndLib.register(self, function()
      if self.stateMachine.currentState == self.stateMachine.states.waitEnd then
        self._meCraftQueue = nil
        self._meCraftBusyUntil = nil
        self.stateMachine:setState(self.stateMachine.states.craftQuarks)
      end
    end)

    self.stateMachine:setState(self.stateMachine.states.idle)
    initCompleted = true
  end

  function obj:init()
    self:_initBody()
  end

  function obj:shutdown()
    cycleEndLib.unregister(self)
    self._meCraftQueue = nil
  end

  -- Перенос кварков в машину (входной автобус сверху, sides.up)
  function obj:putQuarks(index)
    if not self.transposerProxy then return false end

    local drops = {
      {
        "Up-Quark Releasing Catalyst",
        "Down-Quark Releasing Catalyst",
        "Strange-Quark Releasing Catalyst",
        "Charm-Quark Releasing Catalyst",
        "Bottom-Quark Releasing Catalyst",
        "Top-Quark Releasing Catalyst"
      },
      {
        "Up-Quark Releasing Catalyst",
        "Strange-Quark Releasing Catalyst",
        "Bottom-Quark Releasing Catalyst",
        "Down-Quark Releasing Catalyst",
        "Top-Quark Releasing Catalyst",
        "Charm-Quark Releasing Catalyst"
      },
      {
        "Up-Quark Releasing Catalyst",
        "Bottom-Quark Releasing Catalyst",
        "Down-Quark Releasing Catalyst",
        "Charm-Quark Releasing Catalyst",
        "Strange-Quark Releasing Catalyst",
        "Top-Quark Releasing Catalyst"
      }
    }

    self.stateMachine.data.lastPut = index

    for i = 1, 6, 1 do
      local name = drops[index][i]
      local item = self.transposerItems[name]
      if not item then return false end

      local ok_transfer, transfered = pcall(self.transposerProxy.transferItem,
        item.side,
        sides.up,
        1,
        item.slot
      )

      if not ok_transfer or transfered == 0 then
        pcall(self.controllerProxy.setWorkAllowed, false)
        event.push("log_warning", "[T8] Not enough quarks on slot: " .. name)
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
        return false
      end
    end
    return true
  end

  function obj:checkLocalCycleEnd(hasWork)
    if self.stateMachine.currentState == self.stateMachine.states.waitEnd
        and self._hadWorkDuringCycle and not hasWork then
      self.stateMachine:setState(self.stateMachine.states.idle)
    end
    self._hadWorkDuringCycle = hasWork
  end

  function obj:loop()
    -- Пытаемся переподключить оборудование при потере связи
    if not self.controllerProxy or not self.transposerProxy or not self.subMeInterfaceProxy then
      local now = computer.uptime()
      if now - lastReconnectTime >= reconnectInterval then
        lastReconnectTime = now
        componentDiscoverLib.invalidateMachineCache()
        local ok, err = self:connectHardware()
        if ok then
          event.push("log_info", "[T8] Hardware reconnected successfully")
        end
      end
      return
    end

    local ok_allowed, allowed = pcall(self.controllerProxy.isWorkAllowed)
    if not ok_allowed then
      self.controllerProxy = nil
      self.transposerProxy = nil
      self.subMeInterfaceProxy = nil
      return
    end
    self._isWorkAllowed = allowed

    if not allowed then
      self._hasWork = false
      self._successChance = 0
      return
    end

    local ok_work, hasWork = pcall(self.controllerProxy.hasWork)
    if not ok_work then
      self.controllerProxy = nil
      self.transposerProxy = nil
      self.subMeInterfaceProxy = nil
      return
    end
    self._hasWork = hasWork

    self:checkLocalCycleEnd(hasWork)

    if hasWork then
      self.gtSensorParser:getInformation()
      local success = self.gtSensorParser:getNumber(2, "Success chance:", nil, { "Success:", "chance:" })
      self._successChance = success or 0
    else
      self._successChance = 0
    end

    pcall(function() self.stateMachine:update() end)
  end

  function obj:getState()
    if not self.controllerProxy or not self.transposerProxy or not self.subMeInterfaceProxy then
      return "DISCONNECTED"
    end

    if self._isWorkAllowed == false then
      return "Controller disabled"
    end

    if self._hasWork == false then
      return "Wait cycle"
    end

    local state = self.stateMachine.currentState and self.stateMachine.currentState.name or "nil"
    local successChance = self._successChance or 0

    return "State: ["..state.."] Success: ["..successChance.."%]"
  end

  setmetatable(obj, self)
  self.__index = self
  return obj
end

return t8controller
