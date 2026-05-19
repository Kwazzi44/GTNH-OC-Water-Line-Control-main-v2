-- src/t4-controller.lua
-- Контроллер для T4 очищенной воды (pH Neutralized Water) с поддержкой горячего переподключения

local sides = require("sides")
local event = require("event")
local computer = require("computer")

local stateMachineLib = require("lib.state-machine-lib")
local componentDiscoverLib = require("lib.component-discover-lib")
local gtSensorParserLib = require("lib.gt-sensor-parser")
local cycleEndLib = require("lib.cycle-end-lib")

local t4controller = {}

function t4controller:newFormConfig(config)
  return self:new(config)
end

function t4controller:new(config)
  local obj = {}

  obj.config = config
  obj.hydrochloricAcidTransposerProxy = nil
  obj.sodiumHydroxideTransposerProxy = nil
  obj.controllerProxy = nil
  obj.gtSensorParser = nil

  obj.stateMachine = stateMachineLib:new()
  obj.transposerLiquids = {}
  obj.transposerItems = {}
  obj._hadWorkDuringCycle = false

  local lastReconnectTime = 0
  local reconnectInterval = 5
  local initCompleted = false

  -- Подключение оборудования тира T4
  function obj:connectHardware()
    local machineName = self.config.machineName or "multimachine.purificationunitphadjustment"

    -- 1. Ищем саму машину GregTech
    local ctrl = componentDiscoverLib.discoverGtMachine(machineName, self.config.machineAddress)
    if not ctrl then
      return false, "pH Adjustment Unit not found"
    end
    self.controllerProxy = ctrl
    self.gtSensorParser = gtSensorParserLib:new(ctrl)

    -- 2. Ищем транспозер соляной кислоты
    local hclTrans, err1 = componentDiscoverLib.discoverProxy(
      self.config.hydrochloricAcidTransposerAddress,
      "[T4] HCL Transposer",
      "transposer")
    if not hclTrans then
      return false, err1 or "HCL Transposer not found"
    end
    self.hydrochloricAcidTransposerProxy = hclTrans

    -- 3. Ищем транспозер гидроксида натрия
    local naohTrans, err2 = componentDiscoverLib.discoverProxy(
      self.config.sodiumHydroxideTransposerAddress,
      "[T4] NaOH Transposer",
      "transposer")
    if not naohTrans then
      return false, err2 or "NaOH Transposer not found"
    end
    self.sodiumHydroxideTransposerProxy = naohTrans

    -- 4. Ищем соляную кислоту (hydrochloricacid_gt5u)
    local fluids, skippedFluids = componentDiscoverLib.discoverTransposerFluidStorage(
      hclTrans, {"hydrochloricacid_gt5u"}, {sides.up})
    if #skippedFluids ~= 0 then
      return false, "Can't find liquid: " .. table.concat(skippedFluids, ", ")
    end
    for key, value in pairs(fluids) do
      self.transposerLiquids[key] = value
    end

    -- 5. Ищем порошок гидроксида натрия (Sodium Hydroxide Dust)
    local items, skippedItems = componentDiscoverLib.discoverTransposerItemStorage(
      naohTrans, {"Sodium Hydroxide Dust"}, {sides.up})
    if #skippedItems ~= 0 then
      return false, "Can't find items: " .. table.concat(skippedItems, ", ")
    end
    for key, value in pairs(items) do
      self.transposerItems[key] = value
    end

    return true
  end

  function obj:_initBody()
    local ok, err = self:connectHardware()
    if not ok then
      event.push("log_warning", "[T4] Hardware connection failed: " .. tostring(err))
    end

    -- Настройка конечного автомата
    self.stateMachine.states.idle = self.stateMachine:createState("Idle")
    self.stateMachine.states.idle.update = function()
      if self.controllerProxy then
        local ok_hw, hasWork = pcall(self.controllerProxy.hasWork)
        if ok_hw and hasWork then
          self.stateMachine:setState(self.stateMachine.states.work)
        end
      end
    end

    self.stateMachine.states.work = self.stateMachine:createState("Work")
    self.stateMachine.states.work.init = function()
      self.stateMachine.data.phWaitStart = computer.uptime()
    end
    self.stateMachine.states.work.update = function()
      if not self.controllerProxy then
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      local phValue = self.gtSensorParser:getNumber(4, "Current pH Value:", nil, { "pH Value:", "Current pH:" })

      if phValue == nil then
        if computer.uptime() - (self.stateMachine.data.phWaitStart or 0) > 30 then
          event.push("log_warning", "[T4] pH sensor timeout, skipping adjustment")
          self.stateMachine:setState(self.stateMachine.states.waitEnd)
        end
        return
      end

      local diffPh = 7 - phValue
      local count = math.floor(math.abs(diffPh / 0.01))

      if count == 0 then
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
        return
      end

      -- Регулируем pH
      if diffPh > 0 then
        self:putSodiumHydroxide(count)
      else
        self:putHydrochloricAcid(count)
      end

      self.stateMachine:setState(self.stateMachine.states.waitEnd)
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

  function obj:putSodiumHydroxide(count)
    if not self.sodiumHydroxideTransposerProxy or not self.transposerItems["Sodium Hydroxide Dust"] then
      return
    end

    local item = self.transposerItems["Sodium Hydroxide Dust"]
    for i = 1, math.ceil(count / 64), 1 do
      local sodiumHydroxideCount = 0

      if (count - 64 * (i - 1) > 64) then
        sodiumHydroxideCount = 64
      else
        sodiumHydroxideCount = math.floor(count % 64)
      end

      local ok_transfer, result = pcall(self.sodiumHydroxideTransposerProxy.transferItem,
        item.side,
        sides.bottom,
        sodiumHydroxideCount,
        item.slot
      )

      if not ok_transfer or result ~= sodiumHydroxideCount then
        pcall(self.controllerProxy.setWorkAllowed, false)
        event.push("log_warning", "[T4] Not enough Sodium Hydroxide for craft")
        break
      end
    end
  end

  function obj:putHydrochloricAcid(count)
    if not self.hydrochloricAcidTransposerProxy or not self.transposerLiquids["hydrochloricacid_gt5u"] then
      return
    end

    local liq = self.transposerLiquids["hydrochloricacid_gt5u"]
    local hydrochloricAcidCount = count * 10

    local ok_transfer, _, result = pcall(self.hydrochloricAcidTransposerProxy.transferFluid,
      liq.side,
      sides.bottom,
      hydrochloricAcidCount,
      liq.tank
    )

    if not ok_transfer or result ~= hydrochloricAcidCount then
      pcall(self.controllerProxy.setWorkAllowed, false)
      event.push("log_warning", "[T4] Not enough Hydrochloric Acid for craft")
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
    -- Если подключение к железу отсутствует, пытаемся переподключиться
    if not self.controllerProxy or not self.hydrochloricAcidTransposerProxy or not self.sodiumHydroxideTransposerProxy then
      local now = computer.uptime()
      if now - lastReconnectTime >= reconnectInterval then
        lastReconnectTime = now
        componentDiscoverLib.invalidateMachineCache()
        local ok, err = self:connectHardware()
        if ok then
          event.push("log_info", "[T4] Hardware reconnected successfully")
        end
      end
      return
    end

    local ok_allowed, allowed = pcall(self.controllerProxy.isWorkAllowed)
    if not ok_allowed then
      self.controllerProxy = nil
      self.hydrochloricAcidTransposerProxy = nil
      self.sodiumHydroxideTransposerProxy = nil
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
      self.hydrochloricAcidTransposerProxy = nil
      self.sodiumHydroxideTransposerProxy = nil
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
    if not self.controllerProxy or not self.hydrochloricAcidTransposerProxy or not self.sodiumHydroxideTransposerProxy then
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

return t4controller
