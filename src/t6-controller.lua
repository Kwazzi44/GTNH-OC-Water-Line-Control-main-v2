-- src/t6-controller.lua
-- Контроллер для T6 очищенной воды (Sterilized Water) с поддержкой горячего переподключения и автоматической сменой линз

local sides = require("sides")
local event = require("event")
local computer = require("computer")

local stateMachineLib = require("lib.state-machine-lib")
local componentDiscoverLib = require("lib.component-discover-lib")
local gtSensorParserLib = require("lib.gt-sensor-parser")
local cycleEndLib = require("lib.cycle-end-lib")

local t6controller = {}

function t6controller:newFormConfig(config)
  return self:new(config)
end

function t6controller:new(config)
  local obj = {}

  obj.config = config
  obj.transposerProxy = nil
  obj.controllerProxy = nil
  obj.gtSensorParser = nil

  obj.stateMachine = stateMachineLib:new()
  obj.transposerItems = {}
  obj._hadWorkDuringCycle = false

  local lastReconnectTime = 0
  local reconnectInterval = 5
  local initCompleted = false

  -- Подключение оборудования тира T6
  function obj:connectHardware()
    local machineName = self.config.machineName or "multimachine.purificationunituvtreatment"

    -- 1. Ищем саму машину GregTech
    local ctrl = componentDiscoverLib.discoverGtMachine(machineName, self.config.machineAddress)
    if not ctrl then
      return false, "UV Treatment Unit not found"
    end
    self.controllerProxy = ctrl
    self.gtSensorParser = gtSensorParserLib:new(ctrl)

    -- 2. Ищем транспозер
    local trans, err = componentDiscoverLib.discoverProxy(self.config.transposerAddress, "[T6] Transposer", "transposer")
    if not trans then
      return false, err or "Transposer not found"
    end
    self.transposerProxy = trans

    -- 3. Вынимаем старую линзу, если она осталась в разъеме
    pcall(function() self:resetLenses() end)

    -- 4. Ищем доступные линзы в сундуках
    local lensList = {
      "Orundum Lens",
      "Amber Lens",
      "Aer Lens",
      "Emerald Lens",
      "Mana Diamond Lens",
      "Blue Topaz Lens",
      "Amethyst Lens",
      "Fluor-Buergerite Lens",
      "Dilithium Lens"
    }
    local result, skipped = componentDiscoverLib.discoverTransposerItemStorage(trans, lensList)

    -- Dilithium Lens опциональна, остальные обязательны
    if #skipped ~= 0 then
      if not (#skipped == 1 and skipped[1] == "Dilithium Lens") then
        return false, "Can't find lenses: " .. table.concat(skipped, ", ")
      end
    end

    for key, value in pairs(result) do
      self.transposerItems[key] = value
    end

    return true
  end

  function obj:_initBody()
    local ok, err = self:connectHardware()
    if not ok then
      event.push("log_warning", "[T6] Hardware connection failed: " .. tostring(err))
    end

    -- Настройка конечного автомата
    self.stateMachine.states.idle = self.stateMachine:createState("Idle")
    self.stateMachine.states.idle.init = function()
      if not self.transposerProxy then return end
      if self.stateMachine.data.currentLens ~= nil then
        local lens = self.stateMachine.data.currentLens
        if self.transposerItems[lens] then
          pcall(self.transposerProxy.transferItem,
            sides.bottom, 
            self.transposerItems[lens].side,
            1,
            1,
            self.transposerItems[lens].slot
          )
        end
      end
    end
    self.stateMachine.states.idle.update = function()
      if not self.controllerProxy then return end
      local ok_hw, hasWork = pcall(self.controllerProxy.hasWork)
      if ok_hw and hasWork then
        self.stateMachine:setState(self.stateMachine.states.changeLens)
      end
    end

    self.stateMachine.states.changeLens = self.stateMachine:createState("Change Lens")
    self.stateMachine.states.changeLens.init = function()
      if not self.controllerProxy then
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      local lens = self.gtSensorParser:getString(5, "Current lens requested: ", nil, { "lens requested:", "Lens:" })
      local recipeError = self.gtSensorParser:getString(6, "Removed lens", nil, { "Failing this recipe", "too early" })

      if lens == nil or (recipeError and recipeError:find("Removed lens")) then
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
        return
      end

      self:putLens(lens)
    end

    self.stateMachine.states.waitLens = self.stateMachine:createState("Wait Lens")
    self.stateMachine.states.waitLens.update = function()
      if not self.controllerProxy then return end
      local lens = self.gtSensorParser:getString(5, "Current lens requested: ", nil, { "lens requested:", "Lens:" })

      local ok_hw, hasWork = pcall(self.controllerProxy.hasWork)
      if ok_hw and hasWork == false then
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      if self.stateMachine.data.currentLens ~= lens then
        self.stateMachine:setState(self.stateMachine.states.changeLens)
      end
    end

    self.stateMachine.states.waitEnd = self.stateMachine:createState("Wait End")

    cycleEndLib.register(self, function()
      if self.stateMachine.currentState == self.stateMachine.states.waitEnd then
        self.stateMachine:setState(self.stateMachine.states.idle)
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
  end

  -- Сбросить линзы (вынуть активную линзу обратно в сундук)
  function obj:resetLenses()
    if not self.transposerProxy then return end
    local transposerSides = componentDiscoverLib.discoverTransposerItemStorageSide(self.transposerProxy, {sides.bottom})
    if transposerSides[1] ~= nil then
      pcall(self.transposerProxy.transferItem, sides.bottom, transposerSides[1], 1)
    end
  end

  -- Установка требуемой линзы
  function obj:putLens(lens)
    if not self.transposerProxy then return end

    -- Возвращаем текущую линзу в сундук
    if self.stateMachine.data.currentLens ~= nil then
      local oldLens = self.stateMachine.data.currentLens
      if self.transposerItems[oldLens] then
        pcall(self.transposerProxy.transferItem,
          sides.bottom,
          self.transposerItems[oldLens].side,
          1,
          1,
          self.transposerItems[oldLens].slot
        )
      end
    end

    -- Проверка на Dilithium Lens (которая может отсутствовать)
    if lens == "Dilithium Lens" and self.transposerItems[lens] == nil then
      self.stateMachine.data.currentLens = nil
      self.stateMachine:setState(self.stateMachine.states.waitEnd)
      return
    end

    if not self.transposerItems[lens] then
      event.push("log_warning", "[T6] Lens not found in configuration: " .. lens)
      self.stateMachine:setState(self.stateMachine.states.waitEnd)
      return
    end

    local item = self.transposerItems[lens]
    local ok_transfer, result = pcall(self.transposerProxy.transferItem,
      item.side,
      sides.bottom,
      1,
      item.slot
    )

    if not ok_transfer or result ~= 1 then
      pcall(self.controllerProxy.setWorkAllowed, false)
      self.stateMachine.data.currentLens = nil
      self.stateMachine:setState(self.stateMachine.states.waitEnd)
      event.push("log_warning", "[T6] Failed to transfer lens: " .. lens)
      return
    end

    self.stateMachine.data.currentLens = lens

    if lens == "Dilithium Lens" then
      self.stateMachine:setState(self.stateMachine.states.waitEnd)
    else
      self.stateMachine:setState(self.stateMachine.states.waitLens)
    end
  end

  function obj:checkLocalCycleEnd(hasWork)
    if self.stateMachine.currentState == self.stateMachine.states.waitEnd
        and self._hadWorkDuringCycle and not hasWork then
      self.stateMachine:setState(self.stateMachine.states.idle)
    end
    self._hadWorkDuringCycle = hasWork
  end

  function obj:loop()
    -- Пытаемся переподключиться при потере связи
    if not self.controllerProxy or not self.transposerProxy then
      local now = computer.uptime()
      if now - lastReconnectTime >= reconnectInterval then
        lastReconnectTime = now
        componentDiscoverLib.invalidateMachineCache()
        local ok, err = self:connectHardware()
        if ok then
          event.push("log_info", "[T6] Hardware reconnected successfully")
        end
      end
      return
    end

    local ok_allowed, allowed = pcall(self.controllerProxy.isWorkAllowed)
    if not ok_allowed then
      self.controllerProxy = nil
      self.transposerProxy = nil
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
    if not self.controllerProxy or not self.transposerProxy then
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

return t6controller
