-- setup.lua
-- Интерактивный мастер настройки Water Line Control v2

local component = require("component")
local term = require("term")
local serialization = require("serialization")
local filesystem = require("filesystem")
local registry = require("registry")

local function clear()
  term.clear()
end

local function printHeader()
  clear()
  print("================================================================================")
  print("                       WATER LINE CONTROL v2 - SETUP WIZARD                     ")
  print("================================================================================")
  print()
end

local function selectRole(regData)
  while true do
    printHeader()
    local currentRole = regData.role or "не установлена"
    print("Текущая настроенная роль: " .. currentRole:upper())
    print("--------------------------------------------------------------------------------")
    print("Выберите роль для этого компьютера:")
    print(" 1. Standalone (Все-в-одном: опрашивает машины, управляет и рисует GUI)")
    print(" 2. Daemon (Сервер: опрашивает машины, управляет по сети, без экрана)")
    print(" 3. GUI (Клиент: ставится у экрана, общается с сервером по сети)")
    print()
    io.write("Введите номер (1-3) или Q для выхода: ")
    local choice = io.read()
    if choice == "1" then
      regData.role = "standalone"
      return true
    elseif choice == "2" then
      regData.role = "daemon"
      return true
    elseif choice == "3" then
      regData.role = "gui"
      return true
    elseif choice:lower() == "q" then
      return false
    end
  end
end

-- Вспышка редстоуна для проверки какой это транспозер в мире Minecraft
local function testTransposer(address)
  local trans = component.proxy(address)
  if not trans then
    print("Ошибка: не удалось подключиться к транспозеру.")
    os.sleep(1.5)
    return
  end
  print("Подаем редстоун сигнал на все стороны транспозера на 2 секунды...")
  for side = 0, 5 do
    pcall(trans.setRedstoneOutput, side, 15)
  end
  os.sleep(2)
  for side = 0, 5 do
    pcall(trans.setRedstoneOutput, side, 0)
  end
  print("Сигнал выключен.")
  os.sleep(1)
end

local function getTransposerContentSummary(address)
  local trans = component.proxy(address)
  if not trans then return "[Недоступен]" end
  
  local contents = {}
  
  for side = 0, 5 do
    -- Жидкости
    local ok_tanks, count = pcall(trans.getTankCount, side)
    if ok_tanks and count and count > 0 then
      for tankIdx = 1, count do
        local ok_fluid, fluid = pcall(trans.getFluidInTank, side, tankIdx)
        if ok_fluid and fluid and fluid.name and fluid.amount > 0 then
          table.insert(contents, fluid.name)
        end
      end
    end
    
    -- Предметы
    local ok_stacks, stacks = pcall(trans.getAllStacks, side)
    if ok_stacks and stacks then
      local ok_all, slots = pcall(stacks.getAll)
      if ok_all and slots then
        for _, slot in pairs(slots) do
          if slot and slot.label and slot.size > 0 then
            table.insert(contents, slot.label)
          end
        end
      end
    end
  end
  
  local seen = {}
  local unique = {}
  for _, item in ipairs(contents) do
    if not seen[item] then
      seen[item] = true
      table.insert(unique, item)
    end
  end
  
  if #unique == 0 then
    return "[Пусто]"
  else
    local limit = 3
    if #unique > limit then
      local extra = #unique - limit
      local truncated = {}
      for i = 1, limit do table.insert(truncated, unique[i]) end
      return "[" .. table.concat(truncated, ", ") .. " + " .. extra .. "]"
    else
      return "[" .. table.concat(unique, ", ") .. "]"
    end
  end
end

local function configureTransposers(regData)
  local transposers = {}
  for addr, type in component.list("transposer") do
    table.insert(transposers, addr)
  end

  if #transposers == 0 then
    printHeader()
    print("ВНИМАНИЕ: На этом компьютере не обнаружено подключенных транспозеров!")
    print("Если вы настраиваете роль 'gui', это нормально.")
    print("Если это 'standalone' или 'daemon', подключите транспозеры через кабели.")
    print()
    io.write("Нажмите Enter для продолжения...")
    io.read()
    return
  end

  local tiers = {
    { key = "t3", label = "Tier 3: Flocculation (1 transposer)", fields = {"transposerAddress"} },
    { key = "t4", label = "Tier 4: pH Adjustment (2 transposers)", fields = {"hydrochloricAcidTransposerAddress", "sodiumHydroxideTransposerAddress"} },
    { key = "t5", label = "Tier 5: Plasma Heater (2 transposers)", fields = {"plasmaTransposerAddress", "coolantTransposerAddress"} },
    { key = "t6", label = "Tier 6: UV Treatment (1 transposer)", fields = {"transposerAddress"} },
    { key = "t7", label = "Tier 7: Degasser (4 transposers)", fields = {"inertGasTransposerAddress", "superConductorTransposerAddress", "netroniumTransposerAddress", "coolantTransposerAddress"} },
    { key = "t8", label = "Tier 8: Extractor (1 transposer)", fields = {"transposerAddress"} },
  }

  for _, t in ipairs(tiers) do
    if not regData.controllers[t.key] then
      regData.controllers[t.key] = { enable = false }
    end

    while true do
      printHeader()
      print("Настройка " .. t.label)
      print("Хотите включить этот тир в работу? (y/n): ")
      local enableChoice = io.read():lower()
      if enableChoice == "n" then
        regData.controllers[t.key].enable = false
        break
      elseif enableChoice == "y" then
        regData.controllers[t.key].enable = true
        
        -- Проходим по каждому транспозеру для этого тира
        for _, fieldName in ipairs(t.fields) do
          while true do
            printHeader()
            print("Привязка транспозера для: " .. t.key:upper() .. " -> " .. fieldName)
            print("Список подключенных транспозеров:")
            for idx, addr in ipairs(transposers) do
              local summary = getTransposerContentSummary(addr)
              print(string.format(" %d. %s %s", idx, addr:sub(1, 8) .. "...", summary))
            end
            print()
            print("Вы можете протестировать транспозер (подать редстоун-вспышку).")
            print("Для привязки введите: номер")
            print("Для теста введите: t <номер>")
            print()
            io.write("Выбор: ")
            local input = io.read():lower()
            
            if input:sub(1, 2) == "t " then
              local num = tonumber(input:sub(3))
              if num and transposers[num] then
                testTransposer(transposers[num])
              else
                print("Неверный номер.")
                os.sleep(1)
              end
            else
              local num = tonumber(input)
              if num and transposers[num] then
                regData.controllers[t.key][fieldName] = transposers[num]
                break
              else
                print("Неверный ввод. Попробуйте еще раз.")
                os.sleep(1)
              end
            end
          end
        end
        break
      end
    end
  end
end

local function autoDiscoverGtMachines(regData)
  printHeader()
  print("Поиск GregTech машин в сети...")
  print("Это нужно, чтобы Daemon не тратил время на сканирование при каждом запуске.")
  print("--------------------------------------------------------------------------------")
  
  local machines = {}
  for addr, _ in component.list("gt_machine") do
    table.insert(machines, addr)
  end

  if #machines == 0 then
    print("Машины GregTech не найдены в сети.")
    os.sleep(1)
    return
  end

  regData.lineController = regData.lineController or {}
  if not regData.controllers then
    regData.controllers = {}
  end
  for _, tier in ipairs({"t3", "t4", "t5", "t6", "t7", "t8"}) do
    regData.controllers[tier] = regData.controllers[tier] or { enable = false }
  end

  local nameMap = {
    ["multimachine.purificationplant"] = { target = regData.lineController, label = "Очистная установка (WPP)" },
    ["multimachine.purificationunitflocculator"] = { target = regData.controllers.t3, label = "Tier 3 Flocculator" },
    ["multimachine.purificationunitphadjustment"] = { target = regData.controllers.t4, label = "Tier 4 pH Adjustment" },
    ["multimachine.purificationunitplasmaheater"] = { target = regData.controllers.t5, label = "Tier 5 Plasma Heater" },
    ["multimachine.purificationunituvtreatment"] = { target = regData.controllers.t6, label = "Tier 6 UV Treatment" },
    ["multimachine.purificationunitdegasser"] = { target = regData.controllers.t7, label = "Tier 7 Degasser" },
    ["multimachine.purificationunitextractor"] = { target = regData.controllers.t8, label = "Tier 8 Extractor" }
  }

  for idx, addr in ipairs(machines) do
    io.write(string.format("[%d/%d] Опрос %s... ", idx, #machines, addr:sub(1, 8)))
    
    local ok, proxy = pcall(component.proxy, addr)
    if ok and proxy then
      local ok2, name = pcall(proxy.getName)
      if ok2 and name then
        local match = nameMap[name]
        if match then
          match.target.machineAddress = addr
          print("Найден: " .. match.label)
        else
          print("Неизвестный прибор (" .. name .. ")")
        end
      else
        print("Ошибка получения имени")
      end
    else
      print("Ошибка подключения")
    end
    os.sleep(0.1)
  end
  
  print("--------------------------------------------------------------------------------")
  print("Сканирование завершено.")
  os.sleep(2)
end

local function configureScreen(regData)
  local screens = {}
  for addr, _ in component.list("screen") do
    table.insert(screens, addr)
  end

  if #screens <= 1 then
    regData.screenAddress = nil
    return
  end

  printHeader()
  print("Обнаружено несколько мониторов в сети.")
  print("Хотите привязать этот компьютер к конкретному монитору? (y/n): ")
  local choice = io.read():lower()
  if choice == "y" then
    while true do
      printHeader()
      print("Выберите монитор для этого компьютера:")
      for idx, addr in ipairs(screens) do
        print(string.format(" %d. %s", idx, addr:sub(1, 8) .. "..."))
      end
      print()
      io.write("Выбор: ")
      local num = tonumber(io.read())
      if num and screens[num] then
        regData.screenAddress = screens[num]
        break
      else
        print("Неверный ввод.")
        os.sleep(1)
      end
    end
  else
    regData.screenAddress = nil
  end
end

local function configureDiscord(regData)
  printHeader()
  print("Настройка Discord Webhook (опционально):")
  print("Хотите настроить вебхук отправки уведомлений о сбоях? (y/n): ")
  local choice = io.read():lower()
  if choice == "y" then
    io.write("Введите URL вебхука Discord: ")
    local url = io.read()
    if url ~= "" then
      regData.discordWebhook = url
    end
  else
    regData.discordWebhook = nil
  end
end

local function main()
  local regData = registry.load()
  
  if not selectRole(regData) then
    print("Установка отменена.")
    return
  end

  configureScreen(regData)

  if regData.role == "standalone" or regData.role == "daemon" then
    autoDiscoverGtMachines(regData)
    configureTransposers(regData)
    configureDiscord(regData)
  end

  local ok, err = registry.save(regData)
  printHeader()
  if ok then
    print("Успех: Конфигурация успешно сохранена в реестр!")
    print("Роль: " .. regData.role:upper())
    if regData.screenAddress then
      print("Привязанный монитор: " .. regData.screenAddress:sub(1, 8) .. "...")
    end
    print("Запустите main.lua для запуска системы.")
  else
    print("Ошибка сохранения реестра: " .. tostring(err))
  end
  print()
  io.write("Нажмите Enter для завершения...")
  io.read()
end

main()
