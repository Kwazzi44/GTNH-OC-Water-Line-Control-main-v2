-- src/t5-controller.lua
-- Контроллер для T5 очищенной воды (Supercooled Water) с поддержкой горячего переподключения

local sides = require("sides")
local event = require("event")
local computer = require("computer")

local stateMachineLib = require("lib.state-machine-lib")
local componentDiscoverLib = require("lib.component-discover-lib")
local gtSensorParserLib = require("lib.gt-sensor-parser")
local cycleEndLib = require("lib.cycle-end-lib")

local t5controller = {}

function t5controller:newFormConfig(config)
  return self:new(config)
end

function t5controller:new(config)
  local obj = {}

  obj.config = config
  obj.plasmaTransposerProxy = nil
  obj.coolantTransposerProxy = nil
  obj.controllerProxy = nil
  obj.gtSensorParser = nil

  obj.stateMachine = stateMachineLib:new()
  obj.transposerLiquids = {}
  obj._hadWorkDuringCycle = false

  obj.coolantCount = config.coolantCount or 2000
  obj.plasmaCount = config.plasmaCount or 100

  local lastReconnectTime = 0
  local reconnectInterval = 5
  local initCompleted = false

  -- Подключение оборудования тира T5
  function obj:connectHardware()
    local machineName = self.config.machineName or "multimachine.purificationunitplasmaheater"

    -- 1. Ищем саму машину GregTech
    local ctrl = componentDiscoverLib.discoverGtMachine(machineName, self.config.machineAddress)
    if not ctrl then
      return false, "Plasma Heater Unit not found"
    end
    self.controllerProxy = ctrl
    self.gtSensorParser = gtSensorParserLib:new(ctrl)

    -- 2. Ищем транспозер гелиевой плазмы
    local plasTrans, err1 = componentDiscoverLib.discoverProxy(
      self.config.plasmaTransposerAddress,
      "[T5] Plasma Transposer",
      "transposer")
    if not plasTrans then
      return false, err1 or "Plasma Transposer not found"
    end
    self.plasmaTransposerProxy = plasTrans

    -- 3. Ищем транспозер хладагента
    local coolTrans, err2 = componentDiscoverLib.discoverProxy(
      self.config.coolantTransposerAddress,
      "[T5] Coolant Transposer",
      "transposer")
    if not coolTrans then
      return false, err2 or "Coolant Transposer not found"
    end
    self.coolantTransposerProxy = coolTrans

    -- 4. Ищем Helium Plasma (plasma.helium)
    local fluids1, skippedFluids1 = componentDiscoverLib.discoverTransposerFluidStorage(
      plasTrans, {"plasma.helium"}, {sides.up})
    if #skippedFluids1 ~= 0 then
      return false, "Can't find liquid: " .. table.concat(skippedFluids1, ", ")
    end
    for key, value in pairs(fluids1) do
      self.transposerLiquids[key] = value
    end

    -- 5. Ищем Super Coolant (supercoolant)
    local fluids2, skippedFluids2 = componentDiscoverLib.discoverTransposerFluidStorage(
      coolTrans, {"supercoolant"}, {sides.up})
    if #skippedFluids2 ~= 0 then
      return false, "Can't find liquid: " .. table.concat(skippedFluids2, ", ")
    end
    for key, value in pairs(fluids2) do
      self.transposerLiquids[key] = value
    end

    return true
  end

  function obj:_initBody()
    local ok, err = self:connectHardware()
    if not ok then
      event.push("log_warning", "[T5] Hardware connection failed: " .. tostring(err))
    end

    -- Настройка конечного автомата
    self.stateMachine.states.idle = self.stateMachine:createState("Idle")
    self.stateMachine.states.idle.init = function()
      if not self.controllerProxy then return end
      local temperature = self.gtSensorParser:getNumber(4, "Current temperature:", nil, { "temperature:", "Temp:" })

      local ok_hw, hasWork = pcall(self.controllerProxy.hasWork)
      if ok_hw and hasWork and temperature ~= nil and temperature ~= 0 then
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
      end
    end
    self.stateMachine.states.idle.update = function()
      if not self.controllerProxy then return end
      local ok_prog, progress = pcall(self.controllerProxy.getWorkProgress)
      if ok_prog and progress and progress > 900 then 
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
        return
      end

      local ok_hw, hasWork = pcall(self.controllerProxy.hasWork)
      if ok_hw and hasWork then
        self.stateMachine.data.iterations = 0
        self.stateMachine:setState(self.stateMachine.states.heating)
      end
    end

    self.stateMachine.states.heating = self.stateMachine:createState("Heating")
    self.stateMachine.states.heating.init = function()
      if not self.controllerProxy or not self.plasmaTransposerProxy or not self.transposerLiquids["plasma.helium"] then
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      if self.stateMachine.data.iterations >= 2 then
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
        return
      end

      local liq = self.transposerLiquids["plasma.helium"]
      local ok_transfer, result = pcall(self.plasmaTransposerProxy.transferFluid,
        liq.side,
        sides.up,
        self.plasmaCount,
        liq.tank
      )

      if not ok_transfer or result ~= self.plasmaCount then
        pcall(self.controllerProxy.setWorkAllowed, false)
        event.push("log_warning", "[T5] Not enough Helium Plasma for craft")
      end
    end
    self.stateMachine.states.heating.update = function()
      if not self.controllerProxy then return end
      local temperature = self.gtSensorParser:getNumber(4, "Current temperature:", nil, { "temperature:", "Temp:" })

      local ok_hw, hasWork = pcall(self.controllerProxy.hasWork)
      if ok_hw and hasWork == false then
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      if temperature and temperature >= 10000 then
        self.stateMachine:setState(self.stateMachine.states.cooling)
      end
    end

    self.stateMachine.states.cooling = self.stateMachine:createState("Cooling")
    self.stateMachine.states.cooling.init = function()
      if not self.controllerProxy or not self.coolantTransposerProxy or not self.transposerLiquids["supercoolant"] then
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      local liq = self.transposerLiquids["supercoolant"]
      local ok_transfer, result = pcall(self.coolantTransposerProxy.transferFluid,
        liq.side,
        sides.up,
        self.coolantCount,
        liq.tank
      )

      if not ok_transfer or result ~= self.coolantCount then
        pcall(self.controllerProxy.setWorkAllowed, false)
        event.push("log_warning", "[T5] Not enough Super Coolant for craft")
      end
    end
    self.stateMachine.states.cooling.update = function()
      if not self.controllerProxy then return end
      local temperature = self.gtSensorParser:getNumber(4, "Current temperature:", nil, { "temperature:", "Temp:" })

      local ok_hw, hasWork = pcall(self.controllerProxy.hasWork)
      if ok_hw and hasWork == false then
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      if temperature and temperature <= 0 then
        self.stateMachine:setState(self.stateMachine.states.heating)
        self.stateMachine.data.iterations = self.stateMachine.data.iterations + 1
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

  function obj:checkLocalCycleEnd(hasWork)
    if self.stateMachine.currentState == self.stateMachine.states.waitEnd
        and self._hadWorkDuringCycle and not hasWork then
      self.stateMachine:setState(self.stateMachine.states.idle)
    end
    self._hadWorkDuringCycle = hasWork
  end

  function obj:loop()
    -- Пытаемся переподключиться к железу при потере связи
    if not self.controllerProxy or not self.plasmaTransposerProxy or not self.coolantTransposerProxy then
      local now = computer.uptime()
      if now - lastReconnectTime >= reconnectInterval then
        lastReconnectTime = now
        componentDiscoverLib.invalidateMachineCache()
        local ok, err = self:connectHardware()
        if ok then
          event.push("log_info", "[T5] Hardware reconnected successfully")
        end
      end
      return
    end

    local ok_allowed, allowed = pcall(self.controllerProxy.isWorkAllowed)
    if not ok_allowed then
      self.controllerProxy = nil
      self.plasmaTransposerProxy = nil
      self.coolantTransposerProxy = nil
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
      self.plasmaTransposerProxy = nil
      self.coolantTransposerProxy = nil
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
    if not self.controllerProxy or not self.plasmaTransposerProxy or not self.coolantTransposerProxy then
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

return t5controller
