-- main.lua
-- Главная точка входа для Water Line Control v2

local args = {...}
if #args > 0 then
  local cmd = args[1]
  if cmd == "--update" then
    print("Running update...")
    os.execute("lua update.lua")
    return
  elseif cmd == "--setup" then
    print("Running setup...")
    os.execute("lua setup.lua")
    return
  elseif cmd == "--uninstall" then
    print("Uninstalling Water Line Control v2...")
    local fs = require("filesystem")
    local filesToDelete = {
      "main.lua", "setup.lua", "config.lua", "registry.lua", "update.lua",
      "waterline.log", "/usr/etc/waterline_registry.cfg",
      "lib/logger.lua", "lib/theme.lua", "lib/gui.lua", "lib/state.lua",
      "lib/state-machine-lib.lua", "lib/component-discover-lib.lua", "lib/gt-sensor-parser.lua",
      "lib/input-lib.lua", "lib/controller-init-lib.lua", "lib/cycle-end-lib.lua", "lib/network.lua",
      "src/line-controller.lua", "src/t3-controller.lua", "src/t4-controller.lua",
      "src/t5-controller.lua", "src/t6-controller.lua", "src/t7-controller.lua", "src/t8-controller.lua"
    }
    local cwd = require("shell").getWorkingDirectory() or "/home"
    if cwd:sub(-1) ~= "/" then cwd = cwd .. "/" end
    for _, path in ipairs(filesToDelete) do
      local absPath = cwd .. path
      if fs.exists(absPath) then pcall(fs.remove, absPath) end
    end
    pcall(fs.remove, cwd .. "src")
    pcall(fs.remove, cwd .. "lib")
    print("Uninstalled successfully.")
    return
  end
end

package.loaded.config = nil
local config = require("config")
local registry = require("registry")
local state = require("lib.state")
local input = require("lib.input-lib")
local network = require("lib.network")

-- Загружаем динамические настройки из реестра и переопределяем config
local regData = registry.load()
if regData.role then
  config.role = regData.role
end
_G.waterline_role = config.role

if regData.lineController and regData.lineController.machineAddress then
  config.lineController.machineAddress = regData.lineController.machineAddress
end

if regData.controllers then
  for tier, regConf in pairs(regData.controllers) do
    if config.controllers[tier] then
      local c = config.controllers[tier]
      for k, v in pairs(regConf) do
        if k == "enable" then
          c.enable = (v == true)
        elseif v and v ~= "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" then
          c[k] = v
        end
      end
    end
  end
end

local event = require("event")
local keyboard = require("keyboard")
local computer = require("computer")
local component = require("component")
local filesystem = require("filesystem")

-- Инициализируем сетевую плату (модем)
local networkOk, netErr = network.init(config.network.port)
if (config.role == "daemon" or config.role == "gui") and not networkOk then
  error("Network Card (modem) is required for daemon/gui roles! Details: " .. tostring(netErr))
end

local loggerLib = require("lib.logger")
local mainLogger = loggerLib:new(config.logger, "Main")

mainLogger:info("Starting Water Line Control v2 (Role: " .. config.role:upper() .. ")...")

local lineController = nil
local activeControllers = {}
local controllerInitLib = nil
local cycleEndLib = nil

if config.role ~= "gui" then
  local lineControllerLib = require("src.line-controller")
  lineController = lineControllerLib:newFormConfig(config)
  controllerInitLib = require("lib.controller-init-lib")
  cycleEndLib = require("lib.cycle-end-lib")
end

local gui = nil
if config.role ~= "daemon" then
  gui = require("lib.gui")
  gui.init()
  state.line.status = "INITIALIZING"
  for _, tier in ipairs({"t3", "t4", "t5", "t6", "t7", "t8"}) do
    if state[tier] and config.controllers[tier] and config.controllers[tier].enable then
      state[tier].status = "INITIALIZING"
      state[tier].color = 0xB58900
    end
  end
  gui.drawLayout()
end

local tierInitKeys = {}
if config.role ~= "gui" then
  for _, tier in ipairs({"t3", "t4", "t5", "t6", "t7", "t8"}) do
    if config.controllers[tier] and config.controllers[tier].enable then
      table.insert(tierInitKeys, tier)
    end
  end
end

local initPhase = "line"
local tierInitIndex = 1
local pendingTierCtrl = nil
local pendingTierKey = nil
local lineInitOk = false
local initComplete = (config.role == "gui")
local quitFlag = false
local isUpdatingRemote = false

-- Завершение работы контроллеров тиров
local function clear()
  local ok, term = pcall(require, "term")
  if ok and term and term.clear then
    term.clear()
  end
end

local function shutdownControllers()
  for _, item in pairs(activeControllers) do
    if item.ctrl and item.ctrl.shutdown then
      pcall(function() item.ctrl:shutdown() end)
    end
  end
  if cycleEndLib then
    cycleEndLib.clear()
  end
end

-- Обработчики сетевых логов от Daemon к GUI
local function onLogInfo(_, msg)
  mainLogger:info(msg)
end
local function onLogWarning(_, msg)
  mainLogger:warning(msg)
end
local function onLogError(_, msg)
  mainLogger:error(msg)
end

if config.role ~= "gui" then
  event.listen("log_info", onLogInfo)
  event.listen("log_warning", onLogWarning)
  event.listen("log_error", onLogError)
end

-- Локальный пошаговый инициализатор
local function runNextInitStep()
  if initPhase == "line" then
    local ok, err = pcall(function() lineController:init() end)
    if ok and lineController.controllerProxy then
      mainLogger:info("Line Controller (WPP) initialized successfully.")
      lineInitOk = true
      state.line.status = "IDLE"
      state.line.color = 0x2AA198
    else
      mainLogger:warning("WPP Line Controller not found. Setup mode.")
      state.line.status = "NOT BOUND"
      state.line.color = 0xCB4B16
    end
    initPhase = "tier_load"
    return
  end

  if initPhase == "tier_load" then
    local key = tierInitKeys[tierInitIndex]
    if not key then
      initComplete = true
      mainLogger:info("All active controllers initialized.")
      if gui then gui.drawLayout() end
      return
    end

    pendingTierKey = key
    local controllerConfig = config.controllers[key]
    state[key].status = "INITIALIZING"
    state[key].color = 0xB58900

    mainLogger:info("Loading controller: " .. key:upper())
    local success, lib = pcall(require, "src." .. key .. "-controller")
    if not success then
      mainLogger:warning("Failed to load controller src/" .. key .. "-controller.lua: " .. tostring(lib))
      state[key].status = "INIT FAILED"
      state[key].color = 0xDC322F
      tierInitIndex = tierInitIndex + 1
      return
    end

    local ok, ctrl = pcall(function() return lib:newFormConfig(controllerConfig) end)
    if not ok or not ctrl then
      mainLogger:warning("Failed to create controller " .. key:upper() .. ": " .. tostring(ctrl))
      state[key].status = "INIT FAILED"
      state[key].color = 0xDC322F
      tierInitIndex = tierInitIndex + 1
      return
    end

    pendingTierCtrl = ctrl
    controllerInitLib.begin(pendingTierCtrl)
    initPhase = "tier_step"
    return
  end

  if initPhase == "tier_step" then
    local done, err = controllerInitLib.step(pendingTierCtrl)
    if not done then return end

    local key = pendingTierKey
    local controllerConfig = config.controllers[key]

    if err then
      mainLogger:warning("Failed to initialize controller " .. key:upper() .. ": " .. tostring(err))
      state[key].status = "INIT FAILED"
      state[key].color = 0xDC322F
    else
      activeControllers[key] = {
        ctrl = pendingTierCtrl,
        pollInterval = controllerConfig.pollInterval or 0.5,
        lastPoll = 0
      }
      state[key].status = "IDLE"
      state[key].color = 0x2AA198
    end

    pendingTierCtrl = nil
    pendingTierKey = nil
    tierInitIndex = tierInitIndex + 1
    initPhase = "tier_load"
  end
end

-- Обработчики сетевого протокола
local netCallbacks = {}

-- 1. Получение состояния (на GUI)
function netCallbacks.onState(sender, stateData)
  if config.role == "gui" then
    for k, v in pairs(stateData) do
      state[k] = v
    end
    if gui then gui.drawLayout() end
  end
end

-- 2. Получение логов (на GUI)
function netCallbacks.onLog(sender, level, tag, message, timeStr)
  if config.role == "gui" then
    loggerLib.pushMemoryLog(level, tag or "Daemon", message, timeStr)
    if gui then gui.drawLayout() end
  end
end

-- 3. Выполнение удаленной команды (на Daemon)
function netCallbacks.onCmd(sender, cmdName, ...)
  if config.role == "daemon" then
    local args = {...}
    if cmdName == "toggle_tier" then
      local tier = args[1]
      if config.controllers[tier] then
        local targetVal = not config.controllers[tier].enable
        config.controllers[tier].enable = targetVal
        regData.controllers[tier].enable = targetVal
        registry.save(regData)
        mainLogger:info("Remote command: Toggled " .. tier:upper() .. " to " .. tostring(targetVal))
        -- Перезагружаем контроллеры
        computer.shutdown(true)
      end
    end
  end
end

-- 4. Входящее удаленное обновление (на Daemon)
function netCallbacks.onUpdateStart(sender)
  if config.role == "daemon" then
    mainLogger:info("Remote update started by " .. sender)
    isUpdatingRemote = true
    shutdownControllers()
  end
end

function netCallbacks.onUpdateFile(sender, filePath, content)
  if config.role == "daemon" and isUpdatingRemote then
    mainLogger:info("Updating file: " .. filePath)
    local dir = filesystem.path(filePath)
    if dir and dir ~= "" and not filesystem.exists(dir) then
      filesystem.makeDirectory(dir)
    end
    local f = io.open(filePath, "w")
    if f then
      f:write(content)
      f:close()
    end
  end
end

function netCallbacks.onUpdateEnd(sender)
  if config.role == "daemon" and isUpdatingRemote then
    mainLogger:info("Remote update complete! Rebooting daemon...")
    os.sleep(1)
    computer.shutdown(true)
  end
end

network.startListening(netCallbacks)

-- Функция отправки обновлений по сети на Daemon
local function pushUpdateToDaemon()
  if not component.isAvailable("internet") then
    print("Ошибка: Для скачивания обновлений с GitHub требуется Интернет-карта!")
    os.sleep(2)
    return
  end

  print("Запуск обновления GUI...")
  os.execute("lua update.lua")
  
  -- Синхронизируем файлы с Daemon
  print("Отправка обновления на сервер Daemon по сети...")
  network.sendUpdateStart()
  
  local files = {
    "main.lua", "setup.lua", "lib/network.lua", "lib/theme.lua", "lib/gui.lua",
    "lib/state.lua", "lib/logger.lua", "lib/input-lib.lua", "lib/gt-sensor-parser.lua",
    "lib/component-discover-lib.lua", "lib/state-machine-lib.lua", "lib/cycle-end-lib.lua",
    "lib/controller-init-lib.lua", "src/line-controller.lua", "src/t3-controller.lua",
    "src/t4-controller.lua", "src/t5-controller.lua", "src/t6-controller.lua",
    "src/t7-controller.lua", "src/t8-controller.lua"
  }

  for _, path in ipairs(files) do
    if filesystem.exists(path) then
      local f = io.open(path, "r")
      if f then
        local content = f:read("*a")
        f:close()
        network.sendUpdateFile(path, content)
        print("Отправлен файл: " .. path)
        os.sleep(0.05)
      end
    end
  end

  network.sendUpdateEnd()
  print("Обновление полностью отправлено!")
  os.sleep(1.5)
end

-- Обработчик клавиш
local function handleKey(ev, addr, char, code)
  if not input.isKeyEvent(ev) then return false end

  if input.pressed(ev, code, char, keyboard.keys.q, string.byte("q")) then
    quitFlag = true
    return true
  elseif input.pressed(ev, code, char, keyboard.keys.f1) then
    quitFlag = true
    shutdownControllers()
    network.stopListening()
    if component.gpu then
      component.gpu.setActiveBuffer(0)
      pcall(component.gpu.freeAllBuffers)
      component.gpu.setBackground(0x000000)
      component.gpu.setForeground(0xFFFFFF)
    end
    clear()
    os.execute("lua setup.lua")
    computer.shutdown(true)
    return true
  elseif input.pressed(ev, code, char, keyboard.keys.f5) then
    shutdownControllers()
    network.stopListening()
    if component.gpu then
      component.gpu.setActiveBuffer(0)
      pcall(component.gpu.freeAllBuffers)
      component.gpu.setBackground(0x000000)
      component.gpu.setForeground(0xFFFFFF)
    end
    clear()
    if config.role == "gui" then
      pushUpdateToDaemon()
    else
      os.execute("lua update.lua")
    end
    computer.shutdown(true)
    quitFlag = true
    return true
  elseif input.pressed(ev, code, char, keyboard.keys.f3) then
    if gui then
      gui.init()
      gui.drawLayout()
    end
    return true
  elseif input.pressed(ev, code, char, keyboard.keys.f4) then
    if config.role ~= "daemon" then
      local logViewer = require("lib.log_viewer")
      if config.role ~= "gui" then
        event.ignore("log_info", onLogInfo)
        event.ignore("log_warning", onLogWarning)
        event.ignore("log_error", onLogError)
      end
      logViewer.show(config)
      if config.role ~= "gui" then
        event.listen("log_info", onLogInfo)
        event.listen("log_warning", onLogWarning)
        event.listen("log_error", onLogError)
      end
      if gui then
        gui.init()
        gui.drawLayout()
      end
    end
    return true
  end

  return false
end

-- Главный неблокирующий цикл
local lastLinePoll = 0
local lastRedraw = 0
local lineInterval = config.lineController.pollInterval or 1

while not quitFlag do
  input.drain(handleKey)

  local now = computer.uptime()

  if not initComplete then
    runNextInitStep()
    if now - lastRedraw >= 0.15 and gui then
      gui.drawLayout()
      lastRedraw = now
    end
    event.pull(0.02)
  else
    -- Опрос железа (только на standalone или daemon)
    if config.role ~= "gui" and not isUpdatingRemote then
      if now - lastLinePoll >= lineInterval then
        if lineInitOk and lineController.controllerProxy then
          pcall(function()
            lineController:loop()
            local proxy = lineController.controllerProxy
            local allowed = true
            pcall(function() allowed = proxy.isWorkAllowed() end)

            if not allowed then
              state.line.status = "DISABLED"
              state.line.progress = 0
              state.line.maxProgress = 0
            elseif proxy.hasWork() then
              state.line.status = "WORKING"
              state.line.progress = proxy.getWorkProgress()
              state.line.maxProgress = proxy.getWorkMaxProgress()
            else
              state.line.status = "IDLE"
              state.line.progress = 0
              state.line.maxProgress = 0
            end
          end)
        else
          state.line.status = "NOT BOUND"
          state.line.progress = 0
          state.line.maxProgress = 0
        end
        lastLinePoll = now
      end

      for key, item in pairs(activeControllers) do
        if now - item.lastPoll >= item.pollInterval then
          pcall(function() item.ctrl:loop() end)
          item.lastPoll = now
        end
      end
    end

    -- Отрисовка интерфейса и отправка данных по сети
    if now - lastRedraw >= 1 then
      if config.role ~= "gui" and not isUpdatingRemote then
        for key, item in pairs(activeControllers) do
          local stateName = "IDLE"
          local color = 0x839496
          local ctrl = item.ctrl

          local ok, res = pcall(function() return ctrl:getState() end)
          if ok and res then
            stateName = res:gsub("^State:%s*", "")
            local lowerState = stateName:lower()
            if lowerState:find("disabled") then
              color = 0x586E75
            elseif lowerState:find("wait") or lowerState:find("idle") then
              color = 0x2AA198
            else
              color = 0xCB4B16
            end
          else
            stateName = "ERROR"
            color = 0xDC322F
          end

          if state[key] then
            state[key].status = stateName
            state[key].color = color
          end
        end

        -- Транслируем состояние по сети (если мы Daemon)
        if config.role == "daemon" then
          local data = {
            line = state.line,
            t3 = state.t3,
            t4 = state.t4,
            t5 = state.t5,
            t6 = state.t6,
            t7 = state.t7,
            t8 = state.t8
          }
          network.broadcastState(data)
        end
      end

      if config.role ~= "daemon" and gui then
        gui.drawLayout()
      end
      lastRedraw = now
    end

    event.pull(0.05)
  end
end

-- Корректное выключение при выходе
if config.role ~= "gui" then
  shutdownControllers()
  event.ignore("log_info", onLogInfo)
  event.ignore("log_warning", onLogWarning)
  event.ignore("log_error", onLogError)
end

network.stopListening()

if config.role ~= "daemon" and component.gpu then
  component.gpu.setActiveBuffer(0)
  pcall(component.gpu.freeAllBuffers)
  component.gpu.setBackground(0x000000)
  component.gpu.setForeground(0xFFFFFF)
  clear()
end

mainLogger:info("Water Line Control stopped.")
