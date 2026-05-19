-- lib/log_viewer.lua
-- Псевдографический интерфейс просмотра логов с фильтрацией и прокруткой

local component = require("component")
local event = require("event")
local keyboard = require("keyboard")
local theme = require("lib.theme")
local input = require("lib.input-lib")

local logViewer = {}

local function loadAndParseLogs(filePath, filterTag)
  local logs = {}
  local f = io.open(filePath, "r")
  if not f then return logs end

  for line in f:lines() do
    line = line:gsub("[\r\n]", "")
    if line ~= "" then
      local time, level, tag, msg = line:match("^%[(%d%d:%d%d:%d%d)%]%s*%[(%w+)%]%s*%[(%w+)%]%s*(.*)$")
      if time then
        local matched = false
        if filterTag == "ALL" then
          matched = true
        elseif filterTag == "MAIN" and tag == "Main" then
          matched = true
        elseif filterTag == "LINE" and tag == "Line" then
          matched = true
        elseif tag:upper() == filterTag:upper() then
          matched = true
        end

        if matched then
          table.insert(logs, {
            time = time,
            level = level,
            tag = tag,
            message = msg
          })
        end
      else
        if filterTag == "ALL" or filterTag == "MAIN" then
          table.insert(logs, {
            time = "",
            level = "INFO",
            tag = "System",
            message = line
          })
        end
      end
    end
  end
  f:close()
  return logs
end

function logViewer.show(config)
  local gpu = component.gpu
  if not gpu then return end
  
  local W, H = theme.getRes()
  local filePath = config.logger.file or "waterline.log"
  
  local filters = {"ALL", "MAIN", "LINE", "T3", "T4", "T5", "T6", "T7", "T8"}
  local activeFilterIdx = 1
  local scrollOffset = 0
  
  local startY = 7
  local endY = H - 3
  local height = endY - startY + 1
  
  local function drawScreen()
    local buf = theme.beginDoubleBuffer()

    theme.gfill(1, 1, W, H, " ", theme.C.text, theme.C.bg)
    theme.drawHeader("WATER LINE LOG VIEWER", "LOG ANALYSIS PANEL")
    theme.drawFooter({
      {"Left/Right", "Filter"},
      {"Up/Down", "Scroll"},
      {"B/Q", "Back to Hub"},
    })
    
    -- Рисуем панель фильтров
    theme.gset(3, 5, "Filter:", theme.C.text, theme.C.bg)
    local x = 11
    for i, filter in ipairs(filters) do
      if i == activeFilterIdx then
        theme.gset(x, 5, "[ " .. filter .. " ]", theme.C.sel_fg, theme.C.sel_bg)
      else
        theme.gset(x, 5, "  " .. filter .. "  ", theme.C.dim, theme.C.bg)
      end
      x = x + #filter + 4
    end
    
    -- Загружаем логи
    local filteredLogs = loadAndParseLogs(filePath, filters[activeFilterIdx])
    
    -- Рамка списка логов
    theme.gset(2, startY - 1, "+" .. string.rep("-", W - 4) .. "+", theme.C.border, theme.C.bg)
    for y = startY, endY do
      theme.gset(2, y, "|", theme.C.border, theme.C.bg)
      theme.gset(W - 1, y, "|", theme.C.border, theme.C.bg)
    end
    theme.gset(2, endY + 1, "+" .. string.rep("-", W - 4) .. "+", theme.C.border, theme.C.bg)
    
    -- Отрисовка записей логов
    local startIdx = 1
    local endIdx = #filteredLogs
    
    if #filteredLogs > height then
      local maxOffset = #filteredLogs - height
      if scrollOffset > maxOffset then scrollOffset = maxOffset end
      if scrollOffset < 0 then scrollOffset = 0 end
      
      startIdx = #filteredLogs - height + 1 - scrollOffset
      endIdx = #filteredLogs - scrollOffset
    end
    
    local drawY = startY
    for idx = startIdx, endIdx do
      local item = filteredLogs[idx]
      if item then
        local color = theme.C.text
        if item.level == "DEBUG" then
          color = theme.C.dim
        elseif item.level == "WARNING" then
          color = theme.C.warn
        elseif item.level == "ERROR" then
          color = theme.C.ring_down
        end
        
        local prefixStr = ""
        if item.time ~= "" then
          prefixStr = "[" .. item.time .. "] [" .. item.tag .. "] "
        else
          prefixStr = "[" .. item.tag .. "] "
        end
        
        local lineText = prefixStr .. item.message
        lineText = theme.pad(lineText, W - 6)
        theme.gset(3, drawY, lineText, color, theme.C.bg)
      end
      drawY = drawY + 1
    end
    
    -- Очистка пустых строк в списке
    for y = drawY, endY do
      theme.gfill(3, y, W - 4, 1, " ", theme.C.text, theme.C.bg)
    end
    
    -- Индикатор прокрутки
    if #filteredLogs > height then
      local scrollPercent = math.floor((scrollOffset / (#filteredLogs - height)) * 100)
      local indicatorText = string.format(" %d%% ", 100 - scrollPercent)
      theme.gset(W - 10, startY - 1, indicatorText, theme.C.title, theme.C.bg)
    end

    theme.endDoubleBuffer(buf)
  end
  
  drawScreen()
  
  -- Цикл обработки клавиш в просмотре логов
  while true do
    local ev, _, char, keyCode = event.pull(0.05)

    if input.isKeyEvent(ev) then
      if input.pressed(ev, keyCode, char, keyboard.keys.q, string.byte("q"))
          or input.pressed(ev, keyCode, char, keyboard.keys.b, string.byte("b"))
          or input.pressed(ev, keyCode, char, keyboard.keys.escape, 1) then
        break
      elseif input.pressed(ev, keyCode, char, keyboard.keys.left) then
        activeFilterIdx = activeFilterIdx - 1
        if activeFilterIdx < 1 then activeFilterIdx = #filters end
        scrollOffset = 0
        drawScreen()
      elseif input.pressed(ev, keyCode, char, keyboard.keys.right) then
        activeFilterIdx = activeFilterIdx + 1
        if activeFilterIdx > #filters then activeFilterIdx = 1 end
        scrollOffset = 0
        drawScreen()
      elseif input.pressed(ev, keyCode, char, keyboard.keys.up) then
        local filteredLogs = loadAndParseLogs(filePath, filters[activeFilterIdx])
        if #filteredLogs > height then
          scrollOffset = math.min(#filteredLogs - height, scrollOffset + 1)
          drawScreen()
        end
      elseif input.pressed(ev, keyCode, char, keyboard.keys.down) then
        if scrollOffset > 0 then
          scrollOffset = scrollOffset - 1
          drawScreen()
        end
      end
    end
  end
end

return logViewer
