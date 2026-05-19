-- src/t3-controller.lua
-- Контроллер для T3 очищенной воды (Flocculated Water) с поддержкой горячего переподключения

local sides = require("sides")
local event = require("event")
local computer = require("computer")

local stateMachineLib = require("lib.state-machine-lib")
local componentDiscoverLib = require("lib.component-discover-lib")
local gtSensorParserLib = require("lib.gt-sensor-parser")
local cycleEndLib = require("lib.cycle-end-lib")

local t3controller = {}

function t3controller:newFormConfig(config)
  return self:new(config)
end

function t3controller:new(config)
  local obj = {}

  obj.config = config
  obj.transposerProxy = nil
  obj.controllerProxy = nil
  obj.gtSensorParser = nil

  obj.stateMachine = stateMachineLib:new()
  obj.transposerLiquids = {}
  obj._hadWorkDuringCycle = false

  obj.requiredCount = config.requiredCount or 900000
  
  local lastReconnectTime = 0
  local reconnectInterval = 5
  local initCompleted = false

  -- Поиск и инициализация компонентов
  function obj:connectHardware()
    local machineName = self.config.machineName or "multimachine.purificationunitflocculator"
    
    -- 1. Ищем саму машину GregTech
    local ctrl = componentDiscoverLib.discoverGtMachine(machineName, self.config.machineAddress)
    if not ctrl then
      return false, "Flocculation Unit not found"
    end
    self.controllerProxy = ctrl
    self.gtSensorParser = gtSensorParserLib:new(ctrl)

    -- 2. Ищем транспозер
    local trans, err = componentDiscoverLib.discoverProxy(self.config.transposerAddress, "[T3] Transposer", "transposer")
    if not trans then
      return false, err or "Transposer not found"
    end
    self.transposerProxy = trans

    -- 3. Ищем резервуар с реагентом Polyaluminium Chloride
    local result, skipped = componentDiscoverLib.discoverTransposerFluidStorage(trans, {"polyaluminiumchloride"}, {sides.up})
    if #skipped ~= 0 then
      return false, "Can't find fluid: " .. table.concat(skipped, ", ")
    end

    for key, value in pairs(result) do
      self.transposerLiquids[key] = value
    end

    return true
  end

  function obj:_initBody()
    local ok, err = self:connectHardware()
    if not ok then
      event.push("log_warning", "[T3] Hardware connection failed: " .. tostring(err))
    end

    -- Настраиваем конечный автомат тира
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
      if not self.controllerProxy or not self.transposerProxy then
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      -- Считываем сколько реагента потрачено в текущем цикле
      local currentCount = self.gtSensorParser:getNumber(4, "Polyaluminium Chloride consumed this cycle:",
        nil, { "Polyaluminium Chloride consumed this cycle: " })

      if currentCount ~= nil and currentCount >= self.requiredCount then
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
        return
      end

      -- Проверяем сколько жидкости в баке транспозера
      local liq = self.transposerLiquids["polyaluminiumchloride"]
      local ok_fluid, fluidInTank = pcall(self.transposerProxy.getFluidInTank, liq.side, liq.tank)
      
      if not ok_fluid or not fluidInTank then
        event.push("log_warning", "[T3] Failed to query fluid tank")
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      local countToAdd = self.requiredCount

      if fluidInTank.amount < self.requiredCount then
        pcall(self.controllerProxy.setWorkAllowed, false)
        event.push("log_warning", "[T3] Not enough Polyaluminium Chloride for craft")
        countToAdd = fluidInTank.amount - (fluidInTank.amount % 100000)
      end

      if countToAdd <= 0 then
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      -- Переливаем реагент в машину (жидкостный люк сверху, sides.up)
      local ok_transfer, result = pcall(self.transposerProxy.transferFluid,
        liq.side,
        sides.up,
        countToAdd,
        liq.tank
      )

      if not ok_transfer or result ~= countToAdd then
        event.push("log_warning", "[T3] Fluid transfer error")
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
    -- Инициализируем контроллер
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

  -- Основной цикл работы контроллера тира
  function obj:loop()
    -- Если подключение к железу отсутствует, пытаемся переподключиться
    if not self.controllerProxy or not self.transposerProxy then
      local now = computer.uptime()
      if now - lastReconnectTime >= reconnectInterval then
        lastReconnectTime = now
        componentDiscoverLib.invalidateMachineCache()
        local ok, err = self:connectHardware()
        if ok then
          event.push("log_info", "[T3] Hardware reconnected successfully")
        end
      end
      return
    end

    -- Защищенный опрос состояния работы
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

    -- Обновляем состояние FSM
    pcall(function() self.stateMachine:update() end)
  end

  -- Возвращает статус тира для отрисовки в GUI
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

return t3controller
