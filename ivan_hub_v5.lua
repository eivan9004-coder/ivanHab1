--[[ ====================================================================
     Иван Хаб | Steal an Egg  (v5 — простая версия с отладкой)
     Вставь в экзекьютор и нажми Execute. RightShift — скрыть/показать меню.
     Каждый этап пишет в консоль (F9) строки вида [DEBUG] ...
     и последние строки лога видны прямо в меню (вкладка «Кража»).

     Пути:
       Яйца ........ Workspace.World.Areas.GuardAreas.[Биом].Nests.NestModel
                     (внутри NestModel: EggSpotBottom, EggFitBounds)
       База ........ Workspace.World.Areas.EggCarryBounds.SafeZone
       Хэллоуин .... Workspace.HalloweenDimension.WorldEggs.HalloweenEgg
                     Workspace.HalloweenDimension.Zones.SafeZone
       Дорожка ..... Workspace.Plots.[Номер].TreadmillBottom
==================================================================== ]]

local function IvanHubMain()

-- ============================== КОНФИГ ==================================
local Config = {
    Debug = true,               -- печатать [DEBUG] в консоль
    StartBiome = "Forest",      -- "Forest" | любой биом | "Auto" (с последнего к первому) | "All"
    Priority = "Closest",       -- Closest | Income | Rarity
    Halloween = false,          -- брать яйца из HalloweenDimension и нести в её SafeZone
    TryUnknownNests = true,     -- если в гнезде не видно ни prompt, ни яйца — всё равно пробуем
    Cooldown = 1,               -- пауза между циклами (сек)
    AutoTreadmill = false,      -- авто-дорожка (пока идёт кража, дорожка на паузе)
    TreadmillDir = 1,           -- 1 или -1: куда бежать относительно LookVector
    TreadmillUsePrompt = true,  -- после того как встал на дорожку, один раз нажать её prompt/click
    ESP = false,                -- подсветка и подписи над яйцами
    Volume = 0.5,               -- громкость музыки
    Music = {                   -- 3 трека; можно заменить ID прямо в меню («Музыка»)
        { name = "Трек 1", id = "rbxassetid://1837879082" },
        { name = "Трек 2", id = "rbxassetid://1843463175" },
        { name = "Трек 3", id = "rbxassetid://1845554017" },
    },
}

local Biomes = { "Forest", "Lake", "Desert", "Jungle", "Snow", "Volcano", "Abyss Ocean", "Prehistoric",
    "Cosmic", "Cherry Blossom", "Titan Temple", "Angels & Demons", "Enchanted Forest" }
local Rarities = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Secret", "Cosmic", "Divine" }
local RarityRank = {}
for i, r in ipairs(Rarities) do RarityRank[r] = i end
local RarityColor = {
    Common = Color3.fromRGB(190, 190, 190), Uncommon = Color3.fromRGB(110, 220, 110), Rare = Color3.fromRGB(90, 160, 255),
    Epic = Color3.fromRGB(180, 100, 255), Legendary = Color3.fromRGB(255, 190, 60), Mythic = Color3.fromRGB(255, 90, 120),
    Secret = Color3.fromRGB(235, 235, 235), Cosmic = Color3.fromRGB(100, 240, 255), Divine = Color3.fromRGB(255, 245, 160),
}
local MARKERS = { EggSpotBottom = true, EggFitBounds = true }   -- маркеры гнезда, это НЕ яйцо

-- ============================== СЕРВИСЫ / СОСТОЯНИЕ =====================
local env = (getgenv and getgenv()) or _G
if env.IvanHub and env.IvanHub.Unload then pcall(env.IvanHub.Unload) end      -- выгружаем старые версии (v3/v4)
if env.IvanHubV5 and env.IvanHubV5.Unload then pcall(env.IvanHubV5.Unload) end
local IH = { Alive = true, Conns = {} }
env.IvanHubV5 = IH

local cloneref = cloneref or function(x) return x end
local Players = cloneref(game:GetService("Players"))
local PathfindingService = cloneref(game:GetService("PathfindingService"))
local SoundService = cloneref(game:GetService("SoundService"))
local UIS = cloneref(game:GetService("UserInputService"))
local CoreGui = cloneref(game:GetService("CoreGui"))
local TweenService = cloneref(game:GetService("TweenService"))
local LP = Players.LocalPlayer

local State = { running = false, gen = 0, cycleNo = 0, farming = false, blacklist = {}, spawnPos = nil,
    treadSnap = true, plotCache = nil, plotDumped = false, stats = { eggs = 0, fails = 0 } }
local logLines = {}
local ui = {}          -- ссылки на элементы интерфейса

-- ============================== ОТЛАДКА =================================
local function dbg(msg, ...)
    local args = table.pack(...)
    local parts = { tostring(msg) }
    for i = 1, args.n do parts[#parts + 1] = tostring(args[i]) end
    local line = table.concat(parts, " ")
    if Config.Debug then print("[DEBUG] " .. line) end
    logLines[#logLines + 1] = line
    if #logLines > 7 then table.remove(logLines, 1) end
    if ui.log then ui.log.Text = table.concat(logLines, "\n") end
end
local function setStatus(t)
    if ui.status then ui.status.Text = "Статус: " .. tostring(t) end
    dbg("СТАТУС:", t)
end

local function tb(e)
    return tostring(e) .. " | " .. ((debug and debug.traceback) and debug.traceback("", 2) or "")
end

-- ============================== УТИЛИТЫ =================================
local function getChar() return LP.Character end
local function getHum() local c = LP.Character; return c and c:FindFirstChildOfClass("Humanoid") end
local function getHRP() local c = LP.Character; return c and c:FindFirstChild("HumanoidRootPart") end
local function alive() local h = getHum(); return h ~= nil and h.Health > 0 and getHRP() ~= nil end
local function hdist(a, b) return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude end

local function dig(root, path)
    local n = root
    for seg in tostring(path):gmatch("[^%.]+") do
        if not n then return nil end
        n = n:FindFirstChild(seg)
    end
    return n
end
local function norm(s) return (tostring(s):lower():gsub("[^%w]", "")) end
local function childNames(inst)
    local t = {}
    for _, c in ipairs(inst:GetChildren()) do t[#t + 1] = c.Name .. "(" .. c.ClassName .. ")" end
    return table.concat(t, ", ")
end
local function posOf(inst)
    local ok, p = pcall(function()
        if inst:IsA("BasePart") then return inst.Position end
        if inst:IsA("Model") then return inst:GetPivot().Position end
        local sum, n = Vector3.zero, 0
        for _, d in ipairs(inst:GetDescendants()) do
            if d:IsA("BasePart") then sum += d.Position; n += 1 end
        end
        if n > 0 then return sum / n end
    end)
    return ok and p or nil
end
local function boxOf(inst)
    if not inst then return nil end
    if inst:IsA("BasePart") then return inst.CFrame, inst.Size end
    if inst:IsA("Model") then
        local ok, cf, sz = pcall(function() return inst:GetBoundingBox() end)
        if ok then return cf, sz end
    end
    local minV, maxV, n = Vector3.one * math.huge, Vector3.one * -math.huge, 0
    for _, d in ipairs(inst:GetDescendants()) do
        if d:IsA("BasePart") then
            local p, s = d.Position, d.Size / 2
            minV = Vector3.new(math.min(minV.X, p.X - s.X), math.min(minV.Y, p.Y - s.Y), math.min(minV.Z, p.Z - s.Z))
            maxV = Vector3.new(math.max(maxV.X, p.X + s.X), math.max(maxV.Y, p.Y + s.Y), math.max(maxV.Z, p.Z + s.Z))
            n += 1
        end
    end
    if n == 0 then return nil end
    return CFrame.new((minV + maxV) / 2), maxV - minV
end
local function insideBox(inst, margin)
    local cf, size = boxOf(inst)
    local hrp = getHRP()
    if not cf or not hrp then return false end
    local rel = cf:PointToObjectSpace(hrp.Position)
    margin = margin or 0
    return math.abs(rel.X) <= size.X / 2 + margin and math.abs(rel.Z) <= size.Z / 2 + margin and math.abs(rel.Y) <= size.Y / 2 + 12
end
local function groundAt(x, z, yTop)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = { LP.Character }
    local r = workspace:Raycast(Vector3.new(x, yTop + 60, z), Vector3.new(0, -500, 0), params)
    return r and (r.Position.Y + 3) or (yTop + 3)
end
local function parseNum(v)
    if type(v) == "number" then return v end
    if type(v) ~= "string" then return nil end
    local s = v:gsub("[%$,%s]", "")
    local num, suf = s:match("^([%d%.]+)(%a*)$")
    local n = tonumber(num)
    if not n then return nil end
    local mult = ({ K = 1e3, M = 1e6, B = 1e9, T = 1e12 })[(suf or ""):upper()]
    return n * (mult or 1)
end
local function fmt(n)
    if not n then return "?" end
    for _, u in ipairs({ { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
        if n >= u[1] then return ("%.2f%s"):format(n / u[1], u[2]) end
    end
    return tostring(math.floor(n))
end
local function connect(sig, fn)
    local c = sig:Connect(function(...)
        local ok, e = pcall(fn, ...)
        if not ok then dbg("ОШИБКА в обработчике:", e) end
    end)
    IH.Conns[#IH.Conns + 1] = c
    return c
end

-- ============================== ПОИСК ЯИЦ ===============================
-- Данные яйца: Income / Weight / Value / Rarity (Value-объекты, атрибуты, TextLabel в BillboardGui)
local function readEggData(model)
    local d = { texts = {} }
    local function take(name, v)
        local n = tostring(name):lower()
        if n == "income" or n == "incomepersecond" then d.income = parseNum(v)
        elseif n == "weight" or n == "size" or n == "mass" then d.weight = parseNum(v)
        elseif n == "value" or n == "price" or n == "cost" then d.value = parseNum(v)
        elseif n == "rarity" then d.rarity = tostring(v)
        elseif n == "mutation" or n == "mutations" then d.mutation = tostring(v) end
    end
    for k, v in pairs(model:GetAttributes()) do take(k, v) end
    for _, x in ipairs(model:GetDescendants()) do
        if x:IsA("StringValue") or x:IsA("NumberValue") or x:IsA("IntValue") then take(x.Name, x.Value) end
        if x:IsA("TextLabel") and x.Text ~= "" and x:FindFirstAncestorWhichIsA("BillboardGui") then
            d.texts[#d.texts + 1] = x.Text
        end
    end
    if #d.texts > 0 then
        local txt = table.concat(d.texts, " | ")
        d.text = txt
        local low = txt:lower()
        if not d.rarity then
            for _, r in ipairs(Rarities) do if low:find(r:lower(), 1, true) then d.rarity = r end end
        end
        if not d.income then
            local m = txt:match("%$?([%d%.]+%a*)%s*/%s*[sS]")
            d.income = parseNum(m)
        end
        if not d.weight then
            local m = txt:match("([%d%.]+%a*)%s*[kK][gG]")
            d.weight = parseNum(m)
        end
        if not d.value then
            local m = txt:match("%$%s*([%d%.]+%a*)")
            d.value = parseNum(m)
        end
    end
    d.rarity = d.rarity or "?"
    return d
end

-- Состояние гнезда: true (яйцо есть), false (нет), nil (неизвестно)
local function nestState(nest)
    local prompt = nest:FindFirstChildWhichIsA("ProximityPrompt", true)
    if prompt then return prompt.Enabled, prompt end
    for _, d in ipairs(nest:GetDescendants()) do
        if (d:IsA("Model") or d:IsA("BasePart")) and not MARKERS[d.Name] and d.Name:lower():find("egg") then
            return true, nil
        end
    end
    return nil, nil
end

local function buildEgg(model, biome, prompt)
    local spot = model:FindFirstChild("EggSpotBottom", true) or model:FindFirstChild("EggFitBounds", true)
    local pos = (spot and spot:IsA("BasePart") and spot.Position) or posOf(model)
    local approach = pos
    if prompt and prompt.Parent then approach = posOf(prompt.Parent) or pos end
    local data = readEggData(model)
    return { model = model, biome = biome, pos = pos, approach = approach, prompt = prompt, spot = spot, data = data,
        name = data.text and data.text:sub(1, 24) or model.Name }
end

local function collectNests(container, out, depth)
    for _, c in ipairs(container:GetChildren()) do
        if c:FindFirstChild("EggSpotBottom") or c:FindFirstChild("EggFitBounds") or c.Name == "NestModel" then
            out[#out + 1] = c
        elseif depth < 3 and (c:IsA("Folder") or c:IsA("Model")) then
            collectNests(c, out, depth + 1)
        end
    end
end

local function getBiomeFolder(name)
    local ga = dig(workspace, "World.Areas.GuardAreas")
    if not ga then return nil, "GuardAreas не найден (Workspace.World.Areas.GuardAreas)" end
    local f = ga:FindFirstChild(name)
    if f then return f end
    local key = norm(name)
    for _, c in ipairs(ga:GetChildren()) do if norm(c.Name) == key then return c end end
    return nil, "в GuardAreas нет «" .. name .. "». Есть: " .. childNames(ga)
end

local function findEggs(biomeName, silent)
    if not silent then print("[DEBUG] Проверяю биом: ", biomeName) end
    local eggs, unknown = {}, {}
    local folder, why = getBiomeFolder(biomeName)
    if not folder then
        if not silent then dbg("Папка биома:", why); print("[DEBUG] Найдено яиц: ", 0) end
        return eggs
    end
    local nf = folder:FindFirstChild("Nests")
    if not nf then
        if not silent then dbg("Нет Nests в биоме", biomeName, "| внутри:", childNames(folder)); print("[DEBUG] Найдено яиц: ", 0) end
        return eggs
    end
    local nests = {}
    collectNests(nf, nests, 0)
    if not silent then dbg("Гнёзд (NestModel) в биоме:", #nests) end
    for _, nest in ipairs(nests) do
        local state, prompt = nestState(nest)
        if not (State.blacklist[nest] and tick() < State.blacklist[nest]) then
            local egg = buildEgg(nest, biomeName, prompt)
            if state == true then eggs[#eggs + 1] = egg elseif state == nil then unknown[#unknown + 1] = egg end
            if not silent then
                dbg(("  гнездо %s | яйцо=%s | prompt=%s | дох=%s вес=%s ред=%s"):format(nest:GetFullName():gsub("^Workspace%.", ""),
                    tostring(state), prompt and "да" or "нет", fmt(egg.data.income), fmt(egg.data.weight), egg.data.rarity))
            end
        end
    end
    if #eggs == 0 and Config.TryUnknownNests and #unknown > 0 then
        eggs = unknown
        if not silent then dbg("Подтверждённых яиц нет → беру гнёзда с неизвестным состоянием:", #unknown) end
    end
    if not silent then print("[DEBUG] Найдено яиц: ", #eggs) end
    return eggs
end

local function findHalloweenEggs(silent)
    local f = dig(workspace, "HalloweenDimension.WorldEggs")
    local eggs = {}
    if not silent then print("[DEBUG] Проверяю Хэллоуин: HalloweenDimension.WorldEggs") end
    if not f then
        if not silent then dbg("WorldEggs не найден"); print("[DEBUG] Найдено яиц: ", 0) end
        return eggs
    end
    local function add(c)
        if (c:IsA("Model") or c:IsA("BasePart")) and not (State.blacklist[c] and tick() < State.blacklist[c]) then
            local prompt = c:FindFirstChildWhichIsA("ProximityPrompt", true)
            local egg = buildEgg(c, "Halloween", prompt)
            egg.pos = posOf(c) or egg.pos
            if not prompt then egg.approach = egg.pos end
            eggs[#eggs + 1] = egg
        end
    end
    for _, c in ipairs(f:GetChildren()) do
        if c:IsA("Folder") then for _, cc in ipairs(c:GetChildren()) do add(cc) end else add(c) end
    end
    if not silent then print("[DEBUG] Найдено яиц: ", #eggs) end
    return eggs
end

-- Выбор яйца по режиму StartBiome и приоритету
local function gatherEggs(silent)
    if Config.Halloween then return findHalloweenEggs(silent), "Halloween" end
    local list = {}
    if Config.StartBiome == "Auto" then
        for i = #Biomes, 1, -1 do
            list = findEggs(Biomes[i], silent)
            if #list > 0 then return list, Biomes[i] end
        end
        return list, "Auto"
    elseif Config.StartBiome == "All" then
        for _, b in ipairs(Biomes) do
            for _, e in ipairs(findEggs(b, silent)) do list[#list + 1] = e end
        end
        return list, "All"
    end
    return findEggs(Config.StartBiome, silent), Config.StartBiome
end

local function pickEgg(list)
    local hrp = getHRP()
    local best, bs
    for _, e in ipairs(list) do
        local s
        if Config.Priority == "Income" then s = e.data.income or e.data.value or 0
        elseif Config.Priority == "Rarity" then s = (RarityRank[e.data.rarity] or 0) * 1e6
        else s = hrp and -(e.pos - hrp.Position).Magnitude or 0 end
        if not bs or s > bs then best, bs = e, s end
    end
    return best
end

-- ============================== ДВИЖЕНИЕ (без телепорта) ================
-- Идём к точке: MoveTo + MoveToFinished, застрял 2 сек → прыжок
local function stepTo(target, timeout, cond, early)
    local hum, hrp = getHum(), getHRP()
    if not hum or not hrp then return "dead" end
    hum:MoveTo(target)
    local finished, reachedFlag = false, false
    local conn = hum.MoveToFinished:Connect(function(r) finished = true; reachedFlag = r end)
    local t0, lastCheck, lastPos = os.clock(), os.clock(), hrp.Position
    local result = "timeout"
    while os.clock() - t0 < timeout and cond() do
        task.wait(0.1)
        hrp = getHRP()
        if not hrp or not alive() then result = "dead"; break end
        if hdist(hrp.Position, target) <= 3.5 then result = "reached"; break end
        if early and early() then result = "reached"; break end
        if finished then
            result = reachedFlag and "reached" or "stuck"
            if not reachedFlag then dbg("MoveToFinished(false) — цель не достигнута") end
            break
        end
        if os.clock() - lastCheck >= 2 then
            if (hrp.Position - lastPos).Magnitude < 1 then
                dbg("Застрял: за 2 сек сдвинулся <1 stud → Jump")
                hum.Jump = true
                result = "stuck"
                break
            end
            lastPos, lastCheck = hrp.Position, os.clock()
        end
    end
    conn:Disconnect()
    if not cond() then return "abort" end
    return result
end

local function followPath(target, cond, early)
    local hrp = getHRP()
    local path = PathfindingService:CreatePath({ AgentRadius = 2.5, AgentHeight = 5, AgentCanJump = true, AgentCanClimb = true, WaypointSpacing = 6 })
    local ok, err = pcall(function() path:ComputeAsync(hrp.Position, target) end)
    if not ok or path.Status ~= Enum.PathStatus.Success then
        dbg("Pathfinding: путь не построен, статус =", ok and tostring(path.Status) or tostring(err))
        return "nopath"
    end
    local wps = path:GetWaypoints()
    dbg("Pathfinding: точек в пути =", #wps)
    for i = 2, #wps do
        if not cond() then return "abort" end
        if early and early() then return "done" end
        if wps[i].Action == Enum.PathWaypointAction.Jump then local h = getHum(); if h then h.Jump = true end end
        local r = stepTo(wps[i].Position, 6, cond, early)
        if r == "stuck" then
            dbg("Застрял на точке", i, "из", #wps, "→ прыжок и пересчёт пути")
            local h = getHum(); if h then h.Jump = true end
            return "stuck"
        elseif r == "dead" or r == "abort" then return r end
    end
    return "done"
end

local function walkTo(target, stop, cond, early)
    stop = stop or 4
    local forcePath, tries = false, 0
    while cond() and tries < 15 do
        tries += 1
        local hrp = getHRP()
        if not hrp or not alive() then dbg("Персонаж мёртв/недоступен"); return false end
        local dist = hdist(hrp.Position, target)
        if dist <= stop or (early and early()) then dbg(("Дошёл (осталось %.0f studs)"):format(dist)); return true end
        local r
        if dist > 50 or forcePath then
            dbg(("До цели %.0f studs → PathfindingService%s"):format(dist, forcePath and " (после застревания)" or ""))
            r = followPath(target, cond, early)
            if r == "nopath" then
                dbg("Иду напрямую через MoveTo")
                r = stepTo(target, 8, cond, early)
            end
        else
            dbg(("До цели %.0f studs → MoveTo"):format(dist))
            r = stepTo(target, 8, cond, early)
        end
        if r == "stuck" then forcePath = true elseif r == "reached" or r == "done" then forcePath = false
        elseif r == "abort" or r == "dead" then return false end
    end
    return false
end

-- ============================== КРАЖА ===================================
local function isCarrying()
    local c = getChar()
    if not c then return false end
    for _, k in ipairs({ "Carrying", "CarryingEgg", "HasEgg", "IsCarrying" }) do
        if LP:GetAttribute(k) or c:GetAttribute(k) then return true end
    end
    for _, d in ipairs(c:GetDescendants()) do
        if d.Name:lower():find("egg") then return true end
    end
    return false
end

local function steal(egg)
    local model = egg.model
    local prompt = egg.prompt or model:FindFirstChildWhichIsA("ProximityPrompt", true)
    local click = model:FindFirstChildWhichIsA("ClickDetector", true)
    local part = egg.spot or model:FindFirstChildWhichIsA("BasePart", true)
    dbg("КРАЖА: prompt =", prompt and prompt:GetFullName() or "нет", "| click =", click and "да" or "нет", "| touch-часть =", part and part.Name or "нет")

    if prompt then
        local pp = prompt.Parent and posOf(prompt.Parent)
        local hrp = getHRP()
        if pp and hrp then
            local d = (hrp.Position - pp).Magnitude
            local need = (prompt.MaxActivationDistance or 10) - 1.5
            dbg(("Расстояние до prompt %.1f, активация до %.1f"):format(d, prompt.MaxActivationDistance or 10))
            if d > need then
                dbg("Слишком далеко от prompt — подхожу ближе")
                walkTo(pp, math.max(2, need - 1), function() return IH.Alive and State.running end)
            end
        end
        pcall(function() prompt.HoldDuration = 0; prompt.RequiresLineOfSight = false end)
        if fireproximityprompt then
            dbg("Вызываю fireproximityprompt(prompt)")
            local ok, err = pcall(fireproximityprompt, prompt)
            dbg("fireproximityprompt результат:", ok, err)
        else
            dbg("fireproximityprompt недоступен в экзекьюторе → InputHoldBegin/End")
            pcall(function() prompt:InputHoldBegin(); task.wait(0.2); prompt:InputHoldEnd() end)
        end
        task.wait(0.5)
    elseif click and fireclickdetector then
        dbg("Нет prompt → fireclickdetector")
        local ok, err = pcall(fireclickdetector, click)
        dbg("fireclickdetector результат:", ok, err)
        task.wait(0.5)
    elseif part and firetouchinterest and getHRP() then
        dbg("Нет prompt/click → firetouchinterest")
        pcall(function() firetouchinterest(getHRP(), part, 0); task.wait(0.1); firetouchinterest(getHRP(), part, 1) end)
        task.wait(0.5)
    else
        dbg("НЕТ СПОСОБА ЗАБРАТЬ: у яйца нет prompt/click, а firetouchinterest недоступен")
        return false
    end
    local carrying = isCarrying()
    local stillThere = model.Parent ~= nil
    local promptOff = prompt and not prompt.Enabled
    dbg("После кражи: несу яйцо =", carrying, "| prompt выключился =", promptOff and true or false, "| модель на месте =", stillThere)
    return carrying or (promptOff and true or false)
end

local function deliver(zone, zoneName)
    if not zone then dbg("База не найдена:", zoneName); return false end
    local cf, size = boxOf(zone)
    if not cf then dbg("Не удалось получить размеры базы"); return false end
    local top = cf.Position.Y + size.Y / 2
    local target = Vector3.new(cf.Position.X, groundAt(cf.Position.X, cf.Position.Z, top), cf.Position.Z)
    dbg("Иду на базу:", zoneName, "| центр =", math.floor(target.X) .. "," .. math.floor(target.Z))
    local ok = walkTo(target, 6, function() return IH.Alive and State.running end, function() return insideBox(zone, -2) end)
    dbg("Доставка:", ok and "в зоне" or "не дошёл", "| несу яйцо =", isCarrying())
    task.wait(0.6)
    return ok
end

local function cycle(my)
    State.cycleNo += 1
    print("[DEBUG] ===== Цикл " .. State.cycleNo .. " =====")
    if not alive() then setStatus("жду персонажа"); task.wait(1); return end
    local function cond() return IH.Alive and State.running and State.gen == my end

    local list, label = gatherEggs(false)
    if #list == 0 then setStatus("яиц нет (" .. tostring(label) .. ")"); task.wait(2); return end
    local egg = pickEgg(list)
    dbg("Выбрано:", egg.model:GetFullName(), "| биом:", egg.biome, "| доход:", fmt(egg.data.income), "| вес:", fmt(egg.data.weight),
        "| редкость:", egg.data.rarity)

    State.farming = true
    setStatus("иду к яйцу")
    print("[DEBUG] Иду к яйцу: ", egg.model.Name, egg.model:GetFullName())
    local arrived = walkTo(egg.approach, 4, cond)
    if not cond() then State.farming = false; return end
    if not arrived then
        dbg("НЕ ДОШЁЛ до яйца → пропускаю его на 30 сек")
        State.blacklist[egg.model] = tick() + 30
        State.stats.fails += 1
        State.farming = false
        return
    end

    setStatus("краду яйцо")
    local taken = steal(egg)
    if not taken then
        dbg("КРАЖА НЕ УДАЛАСЬ → пропускаю яйцо на 30 сек")
        State.blacklist[egg.model] = tick() + 30
        State.stats.fails += 1
        State.farming = false
        return
    end

    setStatus("несу на базу")
    local zone, zoneName
    if Config.Halloween then zone, zoneName = dig(workspace, "HalloweenDimension.Zones.SafeZone"), "HalloweenDimension.Zones.SafeZone"
    else zone, zoneName = dig(workspace, "World.Areas.EggCarryBounds.SafeZone"), "World.Areas.EggCarryBounds.SafeZone" end
    if deliver(zone, zoneName) then
        State.stats.eggs += 1
        setStatus("сдано! всего: " .. State.stats.eggs)
    else
        State.stats.fails += 1
        setStatus("не удалось донести")
    end
    State.farming = false
end

local function startFarm()
    State.gen += 1
    local my = State.gen
    State.running = true
    dbg("СТАРТ автокражи | биом:", Config.StartBiome, "| приоритет:", Config.Priority, "| Хэллоуин:", Config.Halloween)
    task.spawn(function()
        while IH.Alive and State.running and State.gen == my do
            local ok, err = xpcall(cycle, tb, my)
            State.farming = false
            if not ok then dbg("ОШИБКА В ЦИКЛЕ:", err); task.wait(1) end
            task.wait(Config.Cooldown)
        end
        State.farming = false
    end)
end
local function stopFarm()
    State.running = false; State.gen += 1; State.farming = false
    dbg("СТОП автокражи")
    local hum = getHum()
    if hum and getHRP() then hum:MoveTo(getHRP().Position) end
end

-- ============================== ДОРОЖКА =================================
local function findMyPlot()
    if State.plotCache and State.plotCache.Parent then return State.plotCache end
    local pf = workspace:FindFirstChild("Plots")
    if not pf then dbg("ДОРОЖКА: Workspace.Plots не найден"); return nil end
    local dump = not State.plotDumped
    State.plotDumped = true
    local function mine(plot)
        for k, v in pairs(plot:GetAttributes()) do
            local s = tostring(v)
            if (k:lower():find("owner") or k:lower():find("user") or k:lower():find("player")) and
                (s == LP.Name or s == tostring(LP.UserId) or s == LP.DisplayName) then return true, "атрибут " .. k end
        end
        for _, ch in ipairs(plot:GetChildren()) do
            if ch:IsA("ValueBase") and ch.Name:lower():find("owner") and
                (ch.Value == LP or tostring(ch.Value) == LP.Name or tostring(ch.Value) == tostring(LP.UserId)) then return true, "значение " .. ch.Name end
        end
        local n = 0
        for _, d in ipairs(plot:GetDescendants()) do
            if d:IsA("TextLabel") and (d.Text:find(LP.Name, 1, true) or d.Text:find(LP.DisplayName, 1, true)) then return true, "табличка с именем" end
            n += 1
            if n > 600 then break end
        end
        return false
    end
    local found
    for _, plot in ipairs(pf:GetChildren()) do
        local ok, why = mine(plot)
        if dump then dbg("  плот", plot.Name, "| мой =", ok and ("да, " .. why) or "нет", "| внутри:", childNames(plot):sub(1, 120)) end
        if ok and not found then found = plot end
    end
    if not found and State.spawnPos then
        local bd
        for _, plot in ipairs(pf:GetChildren()) do
            local p = posOf(plot)
            if p then
                local d = (p - State.spawnPos).Magnitude
                if not bd or d < bd then found, bd = plot, d end
            end
        end
        if found then dbg("ДОРОЖКА: владелец не определён — беру плот, ближайший к месту появления:", found.Name) end
    end
    State.plotCache = found
    if found then dbg("ДОРОЖКА: мой плот =", found:GetFullName()) else dbg("ДОРОЖКА: плот не найден") end
    return found
end

local function onTreadmill(tm)
    local hrp = getHRP()
    if not hrp then return false end
    local rel = tm.CFrame:PointToObjectSpace(hrp.Position)
    return math.abs(rel.X) <= tm.Size.X / 2 + 1.5 and math.abs(rel.Z) <= tm.Size.Z / 2 + 1.5
        and rel.Y >= -tm.Size.Y / 2 - 2 and rel.Y <= tm.Size.Y / 2 + 8
end

local function treadmillInteract(tm, plot)
    local pr = tm:FindFirstChildWhichIsA("ProximityPrompt", true)
    local cd = tm:FindFirstChildWhichIsA("ClickDetector", true)
    if not pr and not cd and tm.Parent and tm.Parent ~= plot then
        pr = tm.Parent:FindFirstChildWhichIsA("ProximityPrompt", true)
        cd = tm.Parent:FindFirstChildWhichIsA("ClickDetector", true)
    end
    return pr, cd
end

-- Сначала физически встаём на дорожку, ждём 0.5 c, и только потом жмём prompt/click
local function enterTreadmill(tm, plot, cond)
    local center = tm.Position + Vector3.new(0, tm.Size.Y / 2 + 3, 0)
    local look = tm.CFrame.LookVector
    for attempt = 1, 3 do
        if not cond() or not alive() then return false end
        dbg("ДОРОЖКА: иду на дорожку, попытка", attempt)
        if hdist(getHRP().Position, center) > 12 then
            walkTo(center + look * 2, 4, cond)                    -- далеко: пешком (Pathfinding при >50 studs)
        end
        if not cond() or not alive() then return false end
        getHum():MoveTo(center + look * 2)                        -- шаг на дорожку
        task.wait(0.4)
        if not onTreadmill(tm) then
            dbg("ДОРОЖКА: MoveTo не поставил на дорожку → PivotTo в центр")
            local hrp = getHRP()
            pcall(function() getChar():PivotTo(CFrame.new(center) * (hrp.CFrame - hrp.CFrame.Position)) end)
        end
        task.wait(0.5)                                            -- даём игре засчитать, что мы на дорожке
        if onTreadmill(tm) then
            dbg("ДОРОЖКА: стою на дорожке")
            local pr, cd = treadmillInteract(tm, plot)
            if Config.TreadmillUsePrompt and (pr or cd) then
                if pr and fireproximityprompt then
                    dbg("ДОРОЖКА: fireproximityprompt →", pr:GetFullName())
                    pcall(fireproximityprompt, pr)
                elseif cd and fireclickdetector then
                    dbg("ДОРОЖКА: fireclickdetector →", cd:GetFullName())
                    pcall(fireclickdetector, cd)
                else
                    dbg("ДОРОЖКА: у экзекьютора нет fireproximityprompt/fireclickdetector")
                end
                task.wait(0.3)
            else
                dbg("ДОРОЖКА: prompt/click не найден или отключён — просто стою и бегу")
            end
            return true
        end
        dbg("ДОРОЖКА: всё ещё не на дорожке — повторяю")
    end
    dbg("ДОРОЖКА: встать не удалось → prompt НЕ вызываю (иначе игра ответит: Not at treadmill)")
    return false
end

local function treadmillTick()
    if not Config.AutoTreadmill or not alive() then State.treadEntered = false; return end
    if State.running and State.farming then State.treadEntered = false; return end   -- кража важнее
    local plot = findMyPlot()
    local tm = plot and plot:FindFirstChild("TreadmillBottom", true)
    if not tm then
        if not State.warnedTread then dbg("ДОРОЖКА: TreadmillBottom не найден в", plot and plot.Name or "?"); State.warnedTread = true end
        return
    end
    local cond = function() return IH.Alive and Config.AutoTreadmill and not (State.running and State.farming) end
    local center = tm.Position + Vector3.new(0, tm.Size.Y / 2 + 3, 0)
    local d = hdist(getHRP().Position, center)
    if not State.treadEntered or d > 30 or not onTreadmill(tm) then
        if State.treadEntered then dbg(("ДОРОЖКА: слетел (%.0f studs от центра) — возвращаюсь"):format(d)) end
        State.treadEntered = enterTreadmill(tm, plot, cond)
        if not State.treadEntered then task.wait(2) end
        return
    end
    getHum():MoveTo(center + tm.CFrame.LookVector * Config.TreadmillDir * 50)       -- бежим по LookVector
end

-- ============================== МУЗЫКА ==================================
local sound = Instance.new("Sound")
sound.Name = "IvanHubMusic"; sound.Looped = true; sound.Volume = Config.Volume; sound.Parent = SoundService

local function resolveSoundId(id)
    id = tostring(id or "")
    if id:match("^%d+$") then return "rbxassetid://" .. id end
    if id:match("^rbxassetid://") or id:match("^rbxasset://") or id:match("^rbxplay://") then return id end
    if getcustomasset and isfile and isfile(id) then
        local ok, a = pcall(getcustomasset, id)
        if ok then return a end
    end
    return id
end
local function playTrack(i)
    local tr = Config.Music[i]
    if not tr then return end
    sound:Stop()
    sound.SoundId = resolveSoundId(tr.id)
    sound.Volume = Config.Volume
    sound:Play()
    dbg("МУЗЫКА: играю", tr.name, "|", sound.SoundId)
    if ui.musicStatus then ui.musicStatus.Text = "Играет: " .. tr.name end
    task.delay(5, function()
        if IH.Alive and sound.IsPlaying and sound.TimeLength == 0 then
            dbg("МУЗЫКА: трек не загрузился (ID недоступен). Вставь свой ID или путь к файлу в поле ниже.")
            if ui.musicStatus then ui.musicStatus.Text = "Не загрузился: ID недоступен" end
        end
    end)
end
local function stopMusic()
    sound:Stop()
    dbg("МУЗЫКА: стоп")
    if ui.musicStatus then ui.musicStatus.Text = "Остановлено" end
end

-- ============================== ESP / ПАНЕЛЬ ЯИЦ ========================
local espFolder = nil
local espObjs = {}
local function espUpdate(eggs)
    if not espFolder then return end
    local seen, hl = {}, 0
    if Config.ESP then
        for i, e in ipairs(eggs) do
            if i > 60 then break end
            seen[e.model] = true
            local o = espObjs[e.model]
            local anchor = e.spot or e.model:FindFirstChildWhichIsA("BasePart", true) or (e.model:IsA("BasePart") and e.model)
            if anchor then
                if not o or not o.bb.Parent then
                    local bb = Instance.new("BillboardGui")
                    bb.Adornee = anchor; bb.AlwaysOnTop = true; bb.Size = UDim2.fromOffset(190, 66); bb.StudsOffset = Vector3.new(0, 4, 0)
                    bb.MaxDistance = math.huge; bb.Parent = espFolder
                    local tl = Instance.new("TextLabel")
                    tl.BackgroundTransparency = 1; tl.Size = UDim2.fromScale(1, 1); tl.Font = Enum.Font.GothamBold; tl.TextSize = 12
                    tl.TextStrokeTransparency = 0.3; tl.Parent = bb
                    o = { bb = bb, tl = tl }
                    espObjs[e.model] = o
                end
                local d = e.data
                local hrp = getHRP()
                local dist = hrp and math.floor((e.pos - hrp.Position).Magnitude) or 0
                o.tl.Text = ("🥚 %s\nДоход: %s · Вес: %s\n%d studs"):format(d.rarity, fmt(d.income), fmt(d.weight), dist)
                o.tl.TextColor3 = RarityColor[d.rarity] or Color3.fromRGB(255, 220, 80)
                if hl < 25 then
                    hl += 1
                    if not o.hl or not o.hl.Parent then
                        local h = Instance.new("Highlight")
                        h.Adornee = e.model; h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop; h.FillTransparency = 0.55
                        h.OutlineColor = Color3.new(1, 1, 1); h.Parent = espFolder
                        o.hl = h
                    end
                    o.hl.FillColor = o.tl.TextColor3
                end
            end
        end
    end
    for k, o in pairs(espObjs) do
        if not seen[k] then
            pcall(function() o.bb:Destroy() end)
            if o.hl then pcall(function() o.hl:Destroy() end) end
            espObjs[k] = nil
        end
    end
end

local panelRows = {}
local function panelUpdate(eggs)
    if not ui.list then return end
    for _, r in ipairs(panelRows) do r:Destroy() end
    panelRows = {}
    local hrp = getHRP()
    table.sort(eggs, function(a, b)
        local ra, rb = RarityRank[a.data.rarity] or 0, RarityRank[b.data.rarity] or 0
        if ra ~= rb then return ra > rb end
        return (a.data.income or 0) > (b.data.income or 0)
    end)
    ui.listTitle.Text = ("Яйца: %d"):format(#eggs)
    for i, e in ipairs(eggs) do
        if i > 40 then break end
        local d = e.data
        local row = Instance.new("TextLabel")
        row.Size = UDim2.new(1, -6, 0, 52); row.BackgroundColor3 = Color3.fromRGB(34, 24, 60); row.BorderSizePixel = 0
        row.TextWrapped = true; row.TextXAlignment = Enum.TextXAlignment.Left; row.TextYAlignment = Enum.TextYAlignment.Top
        row.Font = Enum.Font.Gotham; row.TextSize = 12; row.RichText = true; row.Parent = ui.list
        local c = RarityColor[d.rarity] or Color3.new(1, 1, 1)
        local hex = ("#%02x%02x%02x"):format(math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
        row.Text = ("  <b>%s</b>  <font color='%s'>%s</font>\n  Доход: %s · Вес: %s · Знач.: %s\n  %s · %d studs"):format(
            e.biome, hex, d.rarity, fmt(d.income), fmt(d.weight), fmt(d.value), d.mutation and ("мут: " .. d.mutation) or "без мутаций",
            hrp and math.floor((e.pos - hrp.Position).Magnitude) or 0)
        row.TextColor3 = Color3.fromRGB(235, 230, 250)
        local cr = Instance.new("UICorner"); cr.CornerRadius = UDim.new(0, 6); cr.Parent = row
        panelRows[#panelRows + 1] = row
    end
end

-- ============================== ИНТЕРФЕЙС ===============================
local function buildGui()
    local gui = Instance.new("ScreenGui")
    gui.Name = "IvanHubV5"; gui.ResetOnSpawn = false; gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; gui.DisplayOrder = 999
    pcall(function() if syn and syn.protect_gui then syn.protect_gui(gui) end end)
    local okp = pcall(function() gui.Parent = (gethui and gethui()) or CoreGui end)
    if not okp or not gui.Parent then gui.Parent = LP:WaitForChild("PlayerGui") end
    ui.gui = gui
    espFolder = Instance.new("Folder"); espFolder.Name = "ESP"; espFolder.Parent = gui

    local BG, PANEL, ACC, ACC2 = Color3.fromRGB(16, 11, 30), Color3.fromRGB(34, 24, 60), Color3.fromRGB(138, 92, 255), Color3.fromRGB(255, 140, 40)
    local TXT = Color3.fromRGB(240, 235, 252)
    local function corner(i, r) local c = Instance.new("UICorner"); c.CornerRadius = UDim.new(0, r or 8); c.Parent = i end
    local function tw(i, t, p) TweenService:Create(i, TweenInfo.new(t, Enum.EasingStyle.Quad), p):Play() end
    local function txt(parent, text, size, pos, fs, bold)
        local l = Instance.new("TextLabel")
        l.BackgroundTransparency = 1; l.Size = size; l.Position = pos or UDim2.new(); l.Text = text; l.TextColor3 = TXT
        l.Font = bold and Enum.Font.GothamBold or Enum.Font.Gotham; l.TextSize = fs or 13; l.TextWrapped = true
        l.TextXAlignment = Enum.TextXAlignment.Left; l.TextYAlignment = Enum.TextYAlignment.Top; l.Parent = parent
        return l
    end

    local root = Instance.new("Frame")
    root.Size = UDim2.fromOffset(780, 420); root.Position = UDim2.new(0.5, -390, 0.5, -210); root.BackgroundTransparency = 1; root.Parent = gui
    local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
    local sc = Instance.new("UIScale"); sc.Scale = math.min(1, (vp.X - 16) / 780, (vp.Y - 16) / 420); sc.Parent = root

    local main = Instance.new("Frame")
    main.Size = UDim2.fromOffset(460, 420); main.BackgroundColor3 = BG; main.BorderSizePixel = 0; main.Parent = root
    corner(main, 12)
    do local s = Instance.new("UIStroke"); s.Color = ACC; s.Thickness = 1.4; s.Transparency = 0.35; s.Parent = main end
    local head = Instance.new("TextButton")
    head.Size = UDim2.new(1, 0, 0, 34); head.Text = ""; head.AutoButtonColor = false; head.BorderSizePixel = 0; head.Parent = main
    head.BackgroundColor3 = Color3.new(1, 1, 1); corner(head, 12)
    do local g = Instance.new("UIGradient"); g.Color = ColorSequence.new(ACC, ACC2); g.Parent = head end
    txt(head, "Иван Хаб  ·  Steal an Egg  ·  v5 (отладка)", UDim2.new(1, -16, 1, 0), UDim2.fromOffset(12, 8), 14, true).TextColor3 = Color3.new(1, 1, 1)

    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(312, 420); panel.Position = UDim2.fromOffset(468, 0); panel.BackgroundColor3 = BG; panel.BorderSizePixel = 0; panel.Parent = root
    corner(panel, 12)
    do local s = Instance.new("UIStroke"); s.Color = ACC2; s.Thickness = 1.4; s.Transparency = 0.35; s.Parent = panel end
    local ph = Instance.new("TextButton")
    ph.Size = UDim2.new(1, 0, 0, 34); ph.Text = ""; ph.AutoButtonColor = false; ph.BorderSizePixel = 0; ph.Parent = panel
    ph.BackgroundColor3 = Color3.new(1, 1, 1); corner(ph, 12)
    do local g = Instance.new("UIGradient"); g.Color = ColorSequence.new(ACC2, ACC); g.Parent = ph end
    ui.listTitle = txt(ph, "⚙ Панель кражи · яйца", UDim2.new(1, -16, 1, 0), UDim2.fromOffset(12, 8), 14, true)
    ui.listTitle.TextColor3 = Color3.new(1, 1, 1)
    ui.list = Instance.new("ScrollingFrame")
    ui.list.Size = UDim2.new(1, -12, 1, -42); ui.list.Position = UDim2.fromOffset(6, 38); ui.list.BackgroundTransparency = 1
    ui.list.BorderSizePixel = 0; ui.list.ScrollBarThickness = 3; ui.list.AutomaticCanvasSize = Enum.AutomaticSize.Y; ui.list.CanvasSize = UDim2.new()
    ui.list.Parent = panel
    do local l = Instance.new("UIListLayout"); l.Padding = UDim.new(0, 4); l.Parent = ui.list end

    -- перетаскивание за шапки
    local function drag(handle)
        local dragging, ds, sp
        handle.InputBegan:Connect(function(i)
            if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
                dragging, ds, sp = true, i.Position, root.Position
                i.Changed:Connect(function() if i.UserInputState == Enum.UserInputState.End then dragging = false end end)
            end
        end)
        connect(UIS.InputChanged, function(i)
            if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
                local d = i.Position - ds
                root.Position = UDim2.new(sp.X.Scale, sp.X.Offset + d.X, sp.Y.Scale, sp.Y.Offset + d.Y)
            end
        end)
    end
    drag(head); drag(ph)
    connect(UIS.InputBegan, function(i, gp)
        if not gp and i.KeyCode == Enum.KeyCode.RightShift then root.Visible = not root.Visible end
    end)

    -- вкладки
    local tabsBar = Instance.new("Frame")
    tabsBar.Size = UDim2.new(1, -16, 0, 28); tabsBar.Position = UDim2.fromOffset(8, 40); tabsBar.BackgroundTransparency = 1; tabsBar.Parent = main
    do local l = Instance.new("UIListLayout"); l.FillDirection = Enum.FillDirection.Horizontal; l.Padding = UDim.new(0, 6); l.Parent = tabsBar end
    local pages, tabBtns = {}, {}
    local function select(name)
        for n, p in pairs(pages) do p.Visible = (n == name) end
        for n, b in pairs(tabBtns) do tw(b, 0.15, { BackgroundColor3 = n == name and ACC or PANEL }) end
    end
    local function page(name)
        local p = Instance.new("ScrollingFrame")
        p.Size = UDim2.new(1, -16, 1, -76); p.Position = UDim2.fromOffset(8, 72); p.BackgroundTransparency = 1; p.BorderSizePixel = 0
        p.ScrollBarThickness = 3; p.AutomaticCanvasSize = Enum.AutomaticSize.Y; p.CanvasSize = UDim2.new(); p.Visible = false; p.Parent = main
        local l = Instance.new("UIListLayout"); l.Padding = UDim.new(0, 6); l.Parent = p
        pages[name] = p
        local b = Instance.new("TextButton")
        b.Size = UDim2.fromOffset(100, 28); b.Text = name; b.Font = Enum.Font.GothamMedium; b.TextSize = 13; b.TextColor3 = TXT
        b.BackgroundColor3 = PANEL; b.AutoButtonColor = false; b.Parent = tabsBar; corner(b, 7)
        tabBtns[name] = b
        b.MouseButton1Click:Connect(function() select(name) end)
        return p
    end
    local function button(pg, text, fn, colorful)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(1, -6, 0, 32); b.Text = text; b.TextColor3 = Color3.new(1, 1, 1); b.Font = Enum.Font.GothamBold; b.TextSize = 13
        b.BackgroundColor3 = colorful and Color3.new(1, 1, 1) or PANEL; b.Parent = pg; corner(b, 7)
        if colorful then local g = Instance.new("UIGradient"); g.Color = ColorSequence.new(ACC, ACC2); g.Parent = b end
        b.MouseButton1Click:Connect(function() task.spawn(function() local ok, e = pcall(fn, b); if not ok then dbg("ОШИБКА кнопки:", e) end end) end)
        return b
    end
    local function cycler(pg, label, getv, options, setv)
        local b
        b = button(pg, "", function()
            local cur, idx = getv(), 1
            for i, o in ipairs(options) do if o == cur then idx = i end end
            local nv = options[idx % #options + 1]
            setv(nv)
            b.Text = label .. ": " .. tostring(nv) .. "  ›"
            dbg("НАСТРОЙКА:", label, "=", nv)
        end)
        b.Text = label .. ": " .. tostring(getv()) .. "  ›"
        return b
    end

    -- Кража
    local pS = page("Кража")
    ui.status = txt(pS, "Статус: ожидание", UDim2.new(1, -6, 0, 18), nil, 13, true)
    local startBtn
    startBtn = button(pS, "▶ Старт автокражи", function()
        if State.running then stopFarm(); startBtn.Text = "▶ Старт автокражи" else startFarm(); startBtn.Text = "■ Стоп автокражи" end
    end, true)
    local bOpts = { "Auto", "All" }
    for _, b in ipairs(Biomes) do bOpts[#bOpts + 1] = b end
    cycler(pS, "Биом", function() return Config.StartBiome end, bOpts, function(v) Config.StartBiome = v end)
    cycler(pS, "Приоритет", function() return Config.Priority end, { "Closest", "Income", "Rarity" }, function(v) Config.Priority = v end)
    cycler(pS, "Хэллоуин", function() return Config.Halloween and "ВКЛ" or "ВЫКЛ" end, { "ВЫКЛ", "ВКЛ" }, function(v) Config.Halloween = (v == "ВКЛ") end)
    cycler(pS, "ESP", function() return Config.ESP and "ВКЛ" or "ВЫКЛ" end, { "ВЫКЛ", "ВКЛ" }, function(v) Config.ESP = (v == "ВКЛ") end)
    cycler(pS, "Debug-print", function() return Config.Debug and "ВКЛ" or "ВЫКЛ" end, { "ВКЛ", "ВЫКЛ" }, function(v) Config.Debug = (v == "ВКЛ") end)
    button(pS, "Дамп структуры гнёзд (в консоль)", function()
        print("[DEBUG] ===== ДАМП СТРУКТУРЫ =====")
        local ga = dig(workspace, "World.Areas.GuardAreas")
        print("[DEBUG] GuardAreas:", ga and ga:GetFullName() or "НЕ НАЙДЕН")
        if ga then
            for _, area in ipairs(ga:GetChildren()) do
                local nf = area:FindFirstChild("Nests")
                local nests = {}
                if nf then collectNests(nf, nests, 0) end
                print("[DEBUG] Биом:", area.Name, "| внутри:", childNames(area):sub(1, 140), "| гнёзд:", #nests)
                if nests[1] then
                    print("[DEBUG]   пример гнезда:", nests[1]:GetFullName())
                    for _, d in ipairs(nests[1]:GetDescendants()) do
                        print("[DEBUG]     ", d.ClassName, d.Name, d:IsA("BasePart") and ("Transparency=" .. d.Transparency) or "")
                    end
                end
            end
        end
        print("[DEBUG] SafeZone:", dig(workspace, "World.Areas.EggCarryBounds.SafeZone") and "есть" or "НЕ НАЙДЕНА")
        print("[DEBUG] HalloweenEggs:", dig(workspace, "HalloweenDimension.WorldEggs") and "есть" or "нет",
            "| Halloween SafeZone:", dig(workspace, "HalloweenDimension.Zones.SafeZone") and "есть" or "нет")
        print("[DEBUG] fireproximityprompt:", fireproximityprompt ~= nil, "| fireclickdetector:", fireclickdetector ~= nil,
            "| firetouchinterest:", firetouchinterest ~= nil)
    end)
    ui.log = txt(pS, "(лог появится здесь)", UDim2.new(1, -6, 0, 110), nil, 11)
    ui.log.TextColor3 = Color3.fromRGB(180, 175, 205)

    -- Дорожка
    local pT = page("Дорожка")
    local tBtn
    tBtn = button(pT, "Авто-дорожка: ВЫКЛ", function()
        Config.AutoTreadmill = not Config.AutoTreadmill
        State.treadSnap = true; State.treadEntered = false
        tBtn.Text = "Авто-дорожка: " .. (Config.AutoTreadmill and "ВКЛ" or "ВЫКЛ")
        dbg("ДОРОЖКА:", Config.AutoTreadmill and "включена" or "выключена")
    end, true)
    button(pT, "Развернуть направление бега", function()
        Config.TreadmillDir = -Config.TreadmillDir
        dbg("ДОРОЖКА: направление =", Config.TreadmillDir)
    end)
    button(pT, "Найти мой плот (дамп в консоль)", function()
        State.plotCache = nil; State.plotDumped = false; State.warnedTread = false
        local p = findMyPlot()
        if p then dbg("TreadmillBottom:", p:FindFirstChild("TreadmillBottom", true) and "найден" or "НЕ НАЙДЕН") end
    end)
    txt(pT, "Кража имеет приоритет: пока яйцо несётся, дорожка на паузе. Слетел дальше 30 studs — вернётся в центр.", UDim2.new(1, -6, 0, 50), nil, 12)

    -- Музыка
    local pM = page("Музыка")
    ui.musicStatus = txt(pM, "Остановлено", UDim2.new(1, -6, 0, 18), nil, 13, true)
    for i, tr in ipairs(Config.Music) do
        button(pM, "▶ " .. tr.name, function() playTrack(i) end, true)
        local tb = Instance.new("TextBox")
        tb.Size = UDim2.new(1, -6, 0, 28); tb.BackgroundColor3 = PANEL; tb.Text = tr.id; tb.TextColor3 = TXT; tb.Font = Enum.Font.Gotham
        tb.TextSize = 12; tb.ClearTextOnFocus = false; tb.PlaceholderText = "ID, rbxassetid://... или файл IvanHub/music/1.mp3"; tb.Parent = pM
        tb.TextXAlignment = Enum.TextXAlignment.Left; corner(tb, 6)
        tb.FocusLost:Connect(function() Config.Music[i].id = tb.Text; dbg("МУЗЫКА: ID трека", i, "=", tb.Text) end)
    end
    button(pM, "■ Стоп", function() stopMusic() end)
    cycler(pM, "Громкость", function() return Config.Volume end, { 0.2, 0.5, 0.8, 1 }, function(v) Config.Volume = v; sound.Volume = v end)

    select("Кража")
end

-- ============================== ЗАПУСК ==================================
IH.Unload = function()
    IH.Alive = false
    State.running = false; State.gen += 1
    for _, c in ipairs(IH.Conns) do pcall(function() c:Disconnect() end) end
    pcall(function() sound:Stop(); sound:Destroy() end)
    pcall(function() if ui.gui then ui.gui:Destroy() end end)
    env.IvanHubV5 = nil
    print("[DEBUG] Скрипт выгружен")
end

dbg("Скрипт запущен. Игрок:", LP.Name)
local okGui, errGui = pcall(buildGui)
if not okGui then print("[DEBUG] ОШИБКА ПОСТРОЕНИЯ GUI:", errGui) end

task.spawn(function()
    local okS, errS = xpcall(function()
    for _ = 1, 40 do if getHRP() then break end; task.wait(0.25) end
    State.spawnPos = getHRP() and getHRP().Position
    -- стартовая проверка путей
    local ga = dig(workspace, "World.Areas.GuardAreas")
    dbg("Проверка путей: GuardAreas =", ga and "есть" or "НЕТ", "| SafeZone =",
        dig(workspace, "World.Areas.EggCarryBounds.SafeZone") and "есть" or "НЕТ",
        "| Plots =", workspace:FindFirstChild("Plots") and "есть" or "НЕТ")
    if ga then dbg("Биомы в GuardAreas:", childNames(ga)) end
    dbg("Функции экзекьютора: fireproximityprompt =", fireproximityprompt ~= nil, "| fireclickdetector =", fireclickdetector ~= nil,
        "| firetouchinterest =", firetouchinterest ~= nil)
    setStatus("готов. Нажми «Старт автокражи»")
    end, tb)
    if not okS then dbg("ОШИБКА СТАРТА:", errS) end
end)

-- панель яиц + ESP (тихое сканирование, без спама в консоль)
task.spawn(function()
    while IH.Alive do
        local ok, err = xpcall(function()
            local eggs = gatherEggs(true)
            panelUpdate(eggs)
            espUpdate(eggs)
        end, tb)
        if not ok then dbg("ОШИБКА панели/ESP:", err) end
        task.wait(2)
    end
end)

-- дорожка
task.spawn(function()
    while IH.Alive do
        local ok, err = xpcall(treadmillTick, tb)
        if not ok then dbg("ОШИБКА дорожки:", err) end
        task.wait(0.25)
    end
end)

connect(LP.CharacterAdded, function()
    task.wait(1.5)
    State.treadSnap = true; State.treadEntered = false
    dbg("Респавн: персонаж создан заново")
end)

end

local okMain, errMain = xpcall(IvanHubMain, function(e)
    return tostring(e) .. " | " .. ((debug and debug.traceback) and debug.traceback("", 2) or "")
end)
if not okMain then print("[DEBUG] КРИТИЧЕСКАЯ ОШИБКА СКРИПТА (моего кода):", errMain) end
