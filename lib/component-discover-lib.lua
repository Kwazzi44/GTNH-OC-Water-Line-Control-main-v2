-- lib/component-discover-lib.lua
-- Модуль обнаружения компонентов (машин GregTech, транспозеров) с кэшированием и обработкой ошибок

local component = require("component")
local event = require("event")

local function yieldToUi()
  event.pull(0)
end

-- Экранирование специальных символов регулярных выражений
local function escapePattern(text)
  local specialChars = "().%+-*?[^$"
  local escapePattern = text:gsub("([%" .. specialChars .. "])", "%%%1")
  return escapePattern
end

-- Фильтрация сторон транспозера для проверки
local function getSidesForCheck(ignoreSides)
  local ignoreSet = {}
  for _, side in ipairs(ignoreSides or {}) do
    ignoreSet[side] = true
  end

  local sidesForCheck = {}
  for side = 0, 5 do
    if not ignoreSet[side] then
      table.insert(sidesForCheck, side)
    end
  end

  return sidesForCheck
end

local componentDiscover = {}
local machineCache = nil

-- Защищенное создание прокси компонента по частичному/полному адресу
function componentDiscover.discoverProxy(address, name, type)
  if not address or address == "" or address:sub(1, 4) == "aaaa" then
    return nil, "Address not configured"
  end
  local fullAddress, err = component.get(address, type)
  if fullAddress == nil then
    return nil, "Component " .. tostring(name) .. " (" .. tostring(type) .. ") not found on network: " .. tostring(err)
  end
  
  local ok, proxy = pcall(component.proxy, fullAddress, type)
  if not ok or not proxy then
    return nil, "Failed to create proxy for " .. tostring(name)
  end
  return proxy
end

-- Поиск машины GregTech по имени или адресу с кэшированием
function componentDiscover.discoverGtMachine(machineName, machineAddress)
  if machineAddress and machineAddress ~= "" and machineAddress:sub(1, 4) ~= "aaaa" then
    local fullAddress = component.get(machineAddress, "gt_machine")
    if fullAddress == nil then
      return nil
    end
    local ok, proxy = pcall(component.proxy, fullAddress)
    if ok and proxy then
      return proxy
    end
  end

  -- Если адрес не задан, ищем по имени в кэше/списке
  if not machineCache then
    machineCache = {}
    for key, value in pairs(component.list("gt_machine")) do
      local ok, machineProxy = pcall(component.proxy, key)
      if ok and machineProxy then
        local ok2, name = pcall(machineProxy.getName)
        if ok2 and name then
          machineCache[name] = machineProxy
        end
      end
      yieldToUi()
    end
  end
  return machineCache[machineName]
end

-- Сброс кэша машин (для повторного сканирования)
function componentDiscover.invalidateMachineCache()
  machineCache = nil
end

-- Определение сторон подключения инвентарей к транспозеру
function componentDiscover.discoverTransposerItemStorageSide(proxy, ignoreSides)
  ignoreSides = ignoreSides or {}
  local sides = {}
  local sidesForCheck = getSidesForCheck(ignoreSides)

  for _, side in pairs(sidesForCheck) do
    local ok, stacks = pcall(proxy.getAllStacks, side)
    if ok and stacks ~= nil then
      table.insert(sides, side)
    end
    yieldToUi()
  end
  return sides
end

-- Поиск ячеек с конкретными предметами у транспозера
function componentDiscover.discoverTransposerItemStorage(proxy, itemLabels, ignoreSides)
  ignoreSides = ignoreSides or {}
  local itemStorageDescriptor = {}
  local sidesForCheck = getSidesForCheck(ignoreSides)

  local remainingLabels = {}
  for _, label in ipairs(itemLabels) do
    remainingLabels[label] = true
  end

  for _, side in pairs(sidesForCheck) do
    local ok, stacks = pcall(proxy.getAllStacks, side)
    if ok and stacks ~= nil then
      local ok2, slots = pcall(stacks.getAll)
      if ok2 and slots then
        for slotIndex, slot in pairs(slots) do
          if slot and next(slot) ~= nil then
            for itemLabel in pairs(remainingLabels) do
              if slot.label ~= nil and string.match(slot.label, escapePattern(itemLabel)) then
                remainingLabels[itemLabel] = nil
                itemStorageDescriptor[itemLabel] = {side = side, slot = slotIndex + 1}
                break
              end
            end
          end
        end
      end
    end
    yieldToUi()
  end

  local skipped = {}
  for label in pairs(remainingLabels) do
    table.insert(skipped, label)
  end
  return itemStorageDescriptor, skipped
end

-- Поиск резервуаров с конкретной жидкостью у транспозера
function componentDiscover.discoverTransposerFluidStorage(proxy, fluidNames, ignoreSides)
  ignoreSides = ignoreSides or {}
  local fluidStorageDescriptor = {}
  local sidesForCheck = getSidesForCheck(ignoreSides)

  local remainingFluids = {}
  for _, name in ipairs(fluidNames) do
    remainingFluids[name] = true
  end

  for _, side in pairs(sidesForCheck) do
    local ok, count = pcall(proxy.getTankCount, side)
    if ok and count and count ~= 0 then
      for tankIndex = 1, count, 1 do
        local ok2, fluid = pcall(proxy.getFluidInTank, side, tankIndex)
        if ok2 and fluid and fluid.name then
          for fluidName in pairs(remainingFluids) do
            if string.match(fluid.name, escapePattern(fluidName)) then
              remainingFluids[fluidName] = nil
              fluidStorageDescriptor[fluidName] = {side = side, tank = tankIndex}
              break
            end
          end
        end
        yieldToUi()
      end
    end
    yieldToUi()
  end

  local skipped = {}
  for name in pairs(remainingFluids) do
    table.insert(skipped, name)
  end
  return fluidStorageDescriptor, skipped
end

return componentDiscover
