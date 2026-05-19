-- src/t7-controller.lua
-- Контроллер для T7 очищенной воды (Decontaminated Degassed Water) с поддержкой горячего переподключения

local sides = require("sides")
local event = require("event")
local computer = require("computer")

local stateMachineLib = require("lib.state-machine-lib")
local componentDiscoverLib = require("lib.component-discover-lib")
local gtSensorParserLib = require("lib.gt-sensor-parser")
local cycleEndLib = require("lib.cycle-end-lib")

local t7controller = {}

function t7controller:newFormConfig(config)
  return self:new(config)
end

function t7controller:new(config)
  local obj = {}

  obj.config = config
  obj.inertGasTransposerProxy = nil
  obj.superConductorTransposerProxy = nil
  obj.netroniumTransposerProxy = nil
  obj.coolantTransposerProxy = nil
  obj.controllerProxy = nil
  obj.gtSensorParser = nil

  obj.transposerLiquids = {}
  obj.stateMachine = stateMachineLib:new()
  obj._hadWorkDuringCycle = false

  obj.superconductorCount = 1440
  obj.neutroniumCount = 4608
  obj.supercoolantCount = 10000

  local lastReconnectTime = 0
  local reconnectInterval = 5
  local initCompleted = false

  -- Подключение оборудования тира T7
  function obj:connectHardware()
    local machineName = self.config.machineName or "multimachine.purificationunitdegasser"

    -- 1. Ищем саму машину GregTech
    local ctrl = componentDiscoverLib.discoverGtMachine(machineName, self.config.machineAddress)
    if not ctrl then
      return false, "Degasser Unit not found"
    end
    self.controllerProxy = ctrl
    self.gtSensorParser = gtSensorParserLib:new(ctrl)

    -- 2. Ищем транспозер инертного газа
    local gasTrans, err1 = componentDiscoverLib.discoverProxy(
      self.config.inertGasTransposerAddress,
      "[T7] Inert Gas Transposer",
      "transposer")
    if not gasTrans then return false, err1 or "Inert Gas Transposer not found" end
    self.inertGasTransposerProxy = gasTrans

    -- 3. Ищем транспозер сверхпроводника
    local condTrans, err2 = componentDiscoverLib.discoverProxy(
      self.config.superConductorTransposerAddress,
      "[T7] Super Conductor Transposer",
      "transposer")
    if not condTrans then return false, err2 or "Super Conductor Transposer not found" end
    self.superConductorTransposerProxy = condTrans

    -- 4. Ищем транспозер нейтрония
    local neutrTrans, err3 = componentDiscoverLib.discoverProxy(
      self.config.netroniumTransposerAddress,
      "[T7] Neutronium Transposer",
      "transposer")
    if not neutrTrans then return false, err3 or "Neutronium Transposer not found" end
    self.netroniumTransposerProxy = neutrTrans

    -- 5. Ищем транспозер хладагента
    local coolTrans, err4 = componentDiscoverLib.discoverProxy(
      self.config.coolantTransposerAddress,
      "[T7] Coolant Transposer",
      "transposer")
    if not coolTrans then return false, err4 or "Coolant Transposer not found" end
    self.coolantTransposerProxy = coolTrans

    -- 6. Находим жидкости для каждого транспозера
    local fluids1, skipped1 = componentDiscoverLib.discoverTransposerFluidStorage(gasTrans, {"helium", "neon", "krypton", "xenon"}, {sides.up})
    if #skipped1 ~= 0 then return false, "Can't find gases: " .. table.concat(skipped1, ", ") end
    for k, v in pairs(fluids1) do self.transposerLiquids[k] = v end

    local fluids2, skipped2 = componentDiscoverLib.discoverTransposerFluidStorage(condTrans, {"superconductor"}, {sides.up})
    if #skipped2 ~= 0 then return false, "Can't find liquid: superconductor" end
    for k, v in pairs(fluids2) do self.transposerLiquids[k] = v end

    local fluids3, skipped3 = componentDiscoverLib.discoverTransposerFluidStorage(neutrTrans, {"neutronium"}, {sides.up})
    if #skipped3 ~= 0 then return false, "Can't find liquid: neutronium" end
    for k, v in pairs(fluids3) do self.transposerLiquids[k] = v end

    local fluids4, skipped4 = componentDiscoverLib.discoverTransposerFluidStorage(coolTrans, {"supercoolant"}, {sides.up})
    if #skipped4 ~= 0 then return false, "Can't find liquid: supercoolant" end
    for k, v in pairs(fluids4) do self.transposerLiquids[k] = v end

    return true
  end

  function obj:_initBody()
    local ok, err = self:connectHardware()
    if not ok then
      event.push("log_warning", "[T7] Hardware connection failed: " .. tostring(err))
    end

    -- Настройка конечного автомата
    self.stateMachine.states.idle = self.stateMachine:createState("Idle")
    self.stateMachine.states.idle.update = function()
      if not self.controllerProxy then return end
      local success = self.gtSensorParser:getNumber(2, "Success chance:", nil, { "Success:", "chance:" })
      
      local ok_hw, hasWork = pcall(self.controllerProxy.hasWork)
      if success == 100 then
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
      elseif ok_hw and hasWork then
        self.stateMachine:setState(self.stateMachine.states.work)
      end
    end

    self.stateMachine.states.work = self.stateMachine:createState("Work")
    self.stateMachine.states.work.init = function()
      if not self.controllerProxy then
        self.stateMachine:setState(self.stateMachine.states.idle)
        return
      end

      local bitString = self.gtSensorParser:getString(4, "Current control signal (binary): 0b",
        nil, { "control signal", "binary):" })

      if bitString == nil then
        bitString = "0000"
      end

      local bits = self:bitParser(bitString)

      -- 0000 - Сигнал завершения/подачи хладагента
      if bits[1] == false and bits[2] == false and bits[3] == false and bits[4] == false then
        self:putCoolant()
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
        return
      end

      -- Если 4-й бит установлен, ничего не делаем
      if bits[4] == true then
        self.stateMachine:setState(self.stateMachine.states.waitEnd)
        return
      end

      -- Обработка битовых флагов добавления реагентов
      if bits[1] == true then self:putInertGas(bits) end
      if bits[2] == true then self:putSuperConductor() end
      if bits[3] == true then self:putNeutronium() end

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

  -- Парсер битовой маски
  function obj:bitParser(bitString)
    bitString = string.rep("0", 4 - #bitString)..bitString

    local bits = {
      tonumber(bitString:sub(4, 4)) == 1,
      tonumber(bitString:sub(3, 3)) == 1,
      tonumber(bitString:sub(2, 2)) == 1,
      tonumber(bitString:sub(1, 1)) == 1,
    }
    return bits
  end

  function obj:putInertGas(bits)
    if not self.inertGasTransposerProxy then return end
    local inertGas = ""
    local count = 0

    if bits[2] == false and bits[3] == false then
      inertGas = "helium"
      count = 10000
    elseif bits[2] == true and bits[3] == false then
      inertGas = "neon"
      count = 7500
    elseif bits[2] == false and bits[3] == true then
      inertGas = "krypton"
      count = 5000
    elseif bits[2] == true and bits[3] == true then
      inertGas = "xenon"
      count = 2500
    end

    local liq = self.transposerLiquids[inertGas]
    if not liq then return end

    local ok_transfer, result = pcall(self.inertGasTransposerProxy.transferFluid,
      liq.side,
      sides.up,
      count,
      liq.tank
    )

    if not ok_transfer or result ~= count then
      pcall(self.controllerProxy.setWorkAllowed, false)
      event.push("log_warning", "[T7] Not enough " .. inertGas .. " for craft")
    end
  end

  function obj:putSuperConductor()
    if not self.superConductorTransposerProxy or not self.transposerLiquids["superconductor"] then return end
    local liq = self.transposerLiquids["superconductor"]

    local ok_transfer, result = pcall(self.superConductorTransposerProxy.transferFluid,
      liq.side,
      sides.up,
      self.superconductorCount,
      liq.tank
    )

    if not ok_transfer or result ~= self.superconductorCount then
      pcall(self.controllerProxy.setWorkAllowed, false)
      event.push("log_warning", "[T7] Not enough superconductor for craft")
    end
  end

  function obj:putNeutronium()
    if not self.netroniumTransposerProxy or not self.transposerLiquids["neutronium"] then return end
    local liq = self.transposerLiquids["neutronium"]

    local ok_transfer, result = pcall(self.netroniumTransposerProxy.transferFluid,
      liq.side,
      sides.up,
      self.neutroniumCount,
      liq.tank
    )

    if not ok_transfer or result ~= self.neutroniumCount then
      pcall(self.controllerProxy.setWorkAllowed, false)
      event.push("log_warning", "[T7] Not enough neutronium for craft")
    end
  end

  function obj:putCoolant()
    if not self.coolantTransposerProxy or not self.transposerLiquids["supercoolant"] then return end
    local liq = self.transposerLiquids["supercoolant"]

    local ok_transfer, result = pcall(self.coolantTransposerProxy.transferFluid,
      liq.side,
      sides.up,
      self.supercoolantCount,
      liq.tank
    )

    if not ok_transfer or result ~= self.supercoolantCount then
      pcall(self.controllerProxy.setWorkAllowed, false)
      event.push("log_warning", "[T7] Not enough coolant for craft")
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
    -- Пытаемся переподключить оборудование при потере связи
    if not self.controllerProxy or not self.inertGasTransposerProxy or not self.superConductorTransposerProxy or not self.netroniumTransposerProxy or not self.coolantTransposerProxy then
      local now = computer.uptime()
      if now - lastReconnectTime >= reconnectInterval then
        lastReconnectTime = now
        componentDiscoverLib.invalidateMachineCache()
        local ok, err = self:connectHardware()
        if ok then
          event.push("log_info", "[T7] Hardware reconnected successfully")
        end
      end
      return
    end

    local ok_allowed, allowed = pcall(self.controllerProxy.isWorkAllowed)
    if not ok_allowed then
      self.controllerProxy = nil
      self.inertGasTransposerProxy = nil
      self.superConductorTransposerProxy = nil
      self.netroniumTransposerProxy = nil
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
      self.inertGasTransposerProxy = nil
      self.superConductorTransposerProxy = nil
      self.netroniumTransposerProxy = nil
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
    if not self.controllerProxy or not self.inertGasTransposerProxy or not self.superConductorTransposerProxy or not self.netroniumTransposerProxy or not self.coolantTransposerProxy then
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

return t7controller
