-- registry.lua
-- Модуль для сохранения и загрузки динамических настроек (адресов транспозеров и роли) на диск

local serialization = require("serialization")
local filesystem = require("filesystem")

local registry = {}
local REGISTRY_PATH = "/usr/etc/waterline_registry.cfg"

-- Дефолтная структура реестра
local function getDefaultRegistry()
  local data = {
    role = "standalone",
    lineController = { machineAddress = nil },
    controllers = {}
  }
  for i = 3, 8 do
    data.controllers["t" .. i] = { enable = false }
  end
  -- Заранее заготовим слоты под адреса транспозеров для каждого тира
  data.controllers.t3.transposerAddress = nil
  
  data.controllers.t4.hydrochloricAcidTransposerAddress = nil
  data.controllers.t4.sodiumHydroxideTransposerAddress = nil
  
  data.controllers.t5.plasmaTransposerAddress = nil
  data.controllers.t5.coolantTransposerAddress = nil
  
  data.controllers.t6.transposerAddress = nil
  
  data.controllers.t7.inertGasTransposerAddress = nil
  data.controllers.t7.superConductorTransposerAddress = nil
  data.controllers.t7.netroniumTransposerAddress = nil
  data.controllers.t7.coolantTransposerAddress = nil
  
  data.controllers.t8.transposerAddress = nil
  data.controllers.t8.subMeInterfaceAddress = nil

  return data
end

-- Загрузить настройки с диска
function registry.load()
  if not filesystem.exists(REGISTRY_PATH) then
    -- Если файла нет, возвращаем дефолтные настройки
    return getDefaultRegistry()
  end

  local file, err = io.open(REGISTRY_PATH, "r")
  if not file then
    return getDefaultRegistry()
  end

  local content = file:read("*a")
  file:close()

  local success, data = pcall(serialization.unserialize, content)
  if not success or not data or type(data) ~= "table" then
    return getDefaultRegistry()
  end

  -- Гарантируем наличие всех необходимых полей
  if not data.role then data.role = "standalone" end
  if not data.lineController then data.lineController = { machineAddress = nil } end
  if not data.controllers then data.controllers = {} end
  
  local default = getDefaultRegistry()
  for key, val in pairs(default.controllers) do
    if not data.controllers[key] then
      data.controllers[key] = val
    else
      for k, v in pairs(val) do
        if data.controllers[key][k] == nil then
          data.controllers[key][k] = v
        end
      end
    end
  end

  return data
end

-- Сохранить настройки на диск
function registry.save(data)
  local dir = filesystem.path(REGISTRY_PATH)
  if not filesystem.exists(dir) then
    filesystem.makeDirectory(dir)
  end

  local file, err = io.open(REGISTRY_PATH, "w")
  if not file then
    return false, "Cannot open registry file for writing: " .. tostring(err)
  end

  local content = serialization.serialize(data)
  file:write(content)
  file:close()
  return true
end

return registry
