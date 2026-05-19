-- lib/controller-init-lib.lua
-- Утилита для выполнения инициализации контроллеров по шагам с использованием сопрограмм (coroutines)

local controllerInit = {}

function controllerInit.begin(ctrl)
  if not ctrl._initBody then
    error("Controller missing _initBody() for async init")
  end
  ctrl._initCo = coroutine.create(function()
    ctrl:_initBody()
  end)
  return true
end

function controllerInit.step(ctrl)
  if not ctrl._initCo then
    return true, nil
  end

  local ok, err = coroutine.resume(ctrl._initCo)
  if not ok then
    ctrl._initCo = nil
    return true, err
  end

  if coroutine.status(ctrl._initCo) == "dead" then
    ctrl._initCo = nil
    return true, nil
  end

  return false, nil
end

function controllerInit.runSync(ctrl)
  controllerInit.begin(ctrl)
  while true do
    local done, err = controllerInit.step(ctrl)
    if done then
      return err == nil, err
    end
  end
end

return controllerInit
