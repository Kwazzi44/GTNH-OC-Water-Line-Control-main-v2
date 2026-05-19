-- update.lua
-- Скрипт обновления Water Line Control v2 с GitHub

local REPO = "https://raw.githubusercontent.com/Kwazzi44/GTNH-OC-Water-Line-Control-main-v2/main"

local component  = require("component")
local filesystem = require("filesystem")
local internet   = require("internet")
local shell      = require("shell")

if not component.isAvailable("internet") then
  io.write("[ERROR] Internet Card not found!\n")
  os.exit(1)
end

local FILES = {
  { "/config.lua",                      "config.lua"                      },
  { "/registry.lua",                    "registry.lua"                    },
  { "/main.lua",                        "main.lua"                        },
  { "/setup.lua",                       "setup.lua"                       },
  { "/update.lua",                      "update.lua"                      },
  { "/lib/network.lua",                  "lib/network.lua"                  },
  { "/lib/theme.lua",                   "lib/theme.lua"                   },
  { "/lib/gui.lua",                     "lib/gui.lua"                     },
  { "/lib/state.lua",                   "lib/state.lua"                   },
  { "/lib/logger.lua",                  "lib/logger.lua"                  },
  { "/lib/input-lib.lua",               "lib/input-lib.lua"               },
  { "/lib/gt-sensor-parser.lua",        "lib/gt-sensor-parser.lua"        },
  { "/lib/component-discover-lib.lua",  "lib/component-discover-lib.lua"  },
  { "/lib/state-machine-lib.lua",       "lib/state-machine-lib.lua"       },
  { "/lib/cycle-end-lib.lua",            "lib/cycle-end-lib.lua"            },
  { "/lib/controller-init-lib.lua",     "lib/controller-init-lib.lua"     },
  { "/src/line-controller.lua",         "src/line-controller.lua"         },
  { "/src/t3-controller.lua",           "src/t3-controller.lua"           },
  { "/src/t4-controller.lua",           "src/t4-controller.lua"           },
  { "/src/t5-controller.lua",           "src/t5-controller.lua"           },
  { "/src/t6-controller.lua",           "src/t6-controller.lua"           },
  { "/src/t7-controller.lua",           "src/t7-controller.lua"           },
  { "/src/t8-controller.lua",           "src/t8-controller.lua"           },
}

local function resolvePath(p)
  if p:sub(1, 1) == "/" then
    return p
  else
    local cwd = shell.getWorkingDirectory() or "/home"
    if cwd:sub(-1) ~= "/" then
      cwd = cwd .. "/"
    end
    return cwd .. p
  end
end

local function mkdirs(dest)
  local absDest = resolvePath(dest)
  local dir = filesystem.path(absDest)
  if dir:sub(-1) == "/" then
    dir = dir:sub(1, -2)
  end
  if dir and dir ~= "" and dir ~= "." and not filesystem.exists(dir) then
    filesystem.makeDirectory(dir)
  end
end

local function download(url, dest)
  local absDest = resolvePath(dest)
  mkdirs(absDest)

  local bust = "?v=" .. tostring(math.random(1000000, 9999999))
  local ok, err = pcall(function()
    local resp, rerr = internet.request(url .. bust)
    if not resp then error(rerr or "connection failed") end
    local f = assert(io.open(absDest, "w"))
    for chunk in resp do f:write(chunk) end
    f:close()
    if type(resp.close) == "function" then
      resp.close()
    end
  end)
  return ok, err
end

io.write("\n==========================================\n")
io.write("  GTNH Water Line Control v2 — UPDATER    \n")
io.write("==========================================\n")
io.write("[NOTE] config.lua is NOT overwritten if it exists.\n\n")

local ok_n, fail_n = 0, 0
for _, e in ipairs(FILES) do
  local src_path = e[1]
  local dest_path = e[2]
  local abs_dest = resolvePath(dest_path)
  
  if (src_path == "/config.lua" or src_path == "/registry.lua") and filesystem.exists(abs_dest) then
    io.write(string.format("  [SKIPPED] %-35s (File preserved)\n", dest_path))
  else
    io.write(string.format("  [..] %-35s", dest_path))
    local ok, err = download(REPO .. src_path, dest_path)
    if ok then
      io.write("\r  [OK] " .. dest_path .. "   \n")
      ok_n = ok_n + 1
    else
      io.write("\r  [!!] " .. dest_path .. "   \n")
      io.write("       " .. tostring(err) .. "\n")
      fail_n = fail_n + 1
    end
  end
  os.sleep(0.05)
end

io.write(string.format("\nDone: %d updated, %d failed\n", ok_n, fail_n))
if fail_n == 0 then
  io.write("\nUpdate complete!\n\n")
end
