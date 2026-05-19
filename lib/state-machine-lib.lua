-- lib/state-machine-lib.lua
-- Простая реализация конечного автомата (FSM) для логики тиров

local stateMachine = {}

function stateMachine:new()
  local obj = {}

  obj.states = {}
  obj.data = {}
  obj.currentState = nil

  -- Создать новое состояние
  function obj:createState(name)
    return {name = name}
  end

  -- Обновить текущее состояние
  function obj:update()
    if self.currentState ~= nil then
      if self.currentState.update then
        self.currentState:update()
      end
    end
  end

  -- Перейти в новое состояние
  function obj:setState(state)
    assert(state ~= nil, "Cannot set a nil state.")

    if self.currentState ~= nil then
      if self.currentState.exit then
        self.currentState:exit()
      end
    end

    self.currentState = state

    if self.currentState.init then
      self.currentState:init()
    end
  end

  setmetatable(obj, self)
  self.__index = self
  return obj
end

return stateMachine
