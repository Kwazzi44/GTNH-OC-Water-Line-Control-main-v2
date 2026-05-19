-- config.lua
-- Конфигурационный файл для системы автоматизации Water Line v2

local config = {
  -- Роль компьютера: 
  -- "standalone" (все-в-одном: опрос и GUI локально)
  -- "daemon"     (сервер-контроллер: опрос машин и управление, без GUI, вещание по сети)
  -- "gui"        (клиент-монитор: только отрисовка интерфейса, получение данных по сети)
  role = "standalone",

  -- Настройки сети
  network = {
    port = 2424, -- Сетевой порт для обмена данными
  },

  -- Автоматическое обновление при запуске (только для ролей с интернет-картой)
  enableAutoUpdate = false,

  -- Настройки логирования
  logger = {
    level = "info",           -- Уровни: "debug", "info", "warning", "error"
    file = "waterline.log",   -- Файл для записи логов на диск
    printToScreen = false,    -- Выводить ли логи в стандартный вывод терминала
  },

  -- Конфигурация главного контроллера линии (очистной установки)
  lineController = {
    machineName = "multimachine.purificationplant", -- Имя блока в GregTech
    pollInterval = 1,                              -- Интервал опроса в секундах
  },

  -- Настройки контроллеров тиров (T3 - T8)
  controllers = {
    t3 = {
      enable = false,
      machineName = "multimachine.purificationunitflocculator",
      requiredCount = 900000,                      -- Количество реагента на цикл
      pollInterval = 0.5,
    },
    t4 = {
      enable = false,
      machineName = "multimachine.purificationunitphadjustment",
      pollInterval = 0.5,
    },
    t5 = {
      enable = false,
      machineName = "multimachine.purificationunitplasmaheater",
      coolantCount = 2000,
      plasmaCount = 100,
      pollInterval = 0.5,
    },
    t6 = {
      enable = false,
      machineName = "multimachine.purificationunituvtreatment",
      pollInterval = 0.5,
    },
    t7 = {
      enable = false,
      machineName = "multimachine.purificationunitdegasser",
      pollInterval = 0.5,
    },
    t8 = {
      enable = false,
      machineName = "multimachine.purificationunitextractor",
      maxQuarkCount = 4,
      pollInterval = 0.5,
    }
  }
}

return config
