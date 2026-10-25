-- AncestorsCodex v23 — sense-mode encyclopedia panel + debug harness.
-- Debug keys: F3 show panel for NEAREST character · F4 hide · F7 aim/state dump ·
--             F8 panel on/off · F9 full state dump
-- Verified-safe API use only: no SetFont, no StaticConstructObject widgets, no ForEachUObject,
-- no actor spawning (a spawned BP's BeginPlay crashes the game without a controller).
local DUMP_PATH = "ue4ss/Mods/AncestorsCodex/dump.txt"
local function log(s) print("[AncestorsCodex] " .. tostring(s)) end
local function dump_line(s)
    local f = io.open(DUMP_PATH, "a")
    if f then f:write(tostring(s) .. "\n") f:close() end
end
local function safe(fn, default)
    local ok, v = pcall(fn)
    if ok then return v end
    return default
end
local function str(v) if v == nil then return "nil" end return tostring(v) end
local function v2s(v)
    if v == nil then return "nil" end
    local x, y, z = safe(function() return v.X end, nil), safe(function() return v.Y end, nil), safe(function() return v.Z end, nil)
    return string.format("(%.0f, %.0f, %.0f)", tonumber(x) or 0, tonumber(y) or 0, tonumber(z) or 0)
end
local function cls_name(o) return safe(function() return o:GetClass():GetFName():ToString() end, "?") end
local function nm(o) return safe(function() return o:GetFName():ToString() end, "?") end

local LIB_PATH = "/Script/UMG.Default__WidgetBlueprintLibrary"
local WIDGET_BASE = "/Game/Prod/Data/UI/HUD/BP_InteractionDiscoveryWidget"
local WIDGET_CLS = "BP_InteractionDiscoveryWidget_C"

local AIM_ANGLE = 25.0
local AIM_DIST = 3000

-- panel layout (1920x1080 canvas, top-left origin)
-- geometry: popup itself sits ~96 px in from the screen edge, hence the negative x
local X_PLATE, W_PLATE = -96, 640
local X_PANEL, W_TEXT = X_PLATE + 26, 596
local PAD_Y = 20
local LINE_H, CHAR_W = 21.0, 8.4      -- metrics of the 16 px text at scale 1.0
local H_MIN, H_MAX = 210, 560
local ICON_SIZE = 74
local SCALE_BODY = 1.0
local DEBUG_TEXT = true
local SENSE_ONLY = true
local g_armed = false
local g_plate_applied = false
local ANIM_ON = false      -- the widget has exactly one animation; it may be a fade-out, so it is opt-in (F6)   -- show only while the game senses are active (hearing/sight/smell)

local g_pc, g_world, g_w, g_map
local g_panel_on = false
local g_last_target = ""
local g_level_announced = false
local g_last_tick = 0
local g_last_hb = 0
local g_self_addr = nil

-- ---------------------------------------------------------------- description DB (EN/RU)
local DB = {
    { keys = { "machairodus" }, kicker = "СЛУХ · ХИЩНИК · САБЛЕЗУБ", name = "Machairodus  ·  махайрод",
      body = "Крупнейшая саблезубая кошка Олдувая. Плечи выше человеческого роста, клыки до 20 см.\n" ..
          "Охотится в одиночку из засады у водопоев. Чует кровь издалека.\n" ..
          "Опасно: не подходите раненым и без заточенной палки — удар сзади по голове надёжнее." },
    { keys = { "greenmamba" }, kicker = "СЛУХ · ЗМЕЯ · ЯДОВИТАЯ", name = "Eastern Green Mamba  ·  зелёная мамба",
      body = "Древесная змея ярко-зелёного цвета, до 2 метров. Яд нервно-паралитический.\n" ..
          "Держится в кронах и кустах, атакует при резком приближении.\n" ..
          "Совет: не хватайте руками — укус требует лечения и отдыха." },
    { keys = { "blackmamba" }, kicker = "СЛУХ · ЗМЕЯ · ЯДОВИТАЯ", name = "Black Mamba  ·  чёрная мамба",
      body = "Самая быстрая змея Африки: до 3 метров, бросок быстрее человеческой реакции.\n" ..
          "Яд смертелен без лечения. Активна днём, любит сухие открытые места.\n" ..
          "Совет: заметив — уходите, не поворачиваясь спиной." },
    { keys = { "python" }, kicker = "СЛУХ · ЗМЕЯ · УДАВ", name = "African Rock Python  ·  африканский питон",
      body = "Крупный неядовитый удав до 4 метров. Убивает удушением.\n" ..
          "Медлителен, но бросок внезапен. Мясо съедобно после обработки." },
    { keys = { "scolopendra", "centipede" }, kicker = "СЛУХ · НАСЕКОМОЕ", name = "Megarian Banded Centipede  ·  сколопендра",
      body = "40 см хитина, ядовитые ногочелюсти. Укус болезненный, но не смертельный.\n" ..
          "Хороший источник белка, если убить палкой." },
    { keys = { "leopard" }, kicker = "СЛУХ · ХИЩНИК", name = "Leopard  ·  леопард",
      body = "Пятнистый хищник, охотится ночью и в сумерках. Тащит добычу на дерево.\n" ..
          "В зарослях опаснее махайрода: подходит вплотную незамеченным." },
    { keys = { "warthog", "swine" }, kicker = "СЛУХ · ДОБЫЧА", name = "Giant Warthog  ·  гигантский бородавочник",
      body = "Крупная свинья с клыками. Обычно убегает, раненый бросается в атаку.\n" ..
          "Много калорий. Убивается камнем или палкой в голову." },
    { keys = { "eagle" }, kicker = "СЛУХ · ПТИЦА", name = "Eagle  ·  орёл",
      body = "Хищная птица, кружит высоко. Может унести детёныша.\n" ..
          "Гнездо с яйцами — ценный белок, но подъём на дерево опасен." },
    { keys = { "pelagornis", "giantbird", "bird" }, kicker = "СЛУХ · ПТИЦА", name = "Pelagornis  ·  пелагорнис",
      body = "Гигантская птица, размах до 6 метров. Падальщик и охотник.\n" ..
          "Держитесь под кронами: пикирует сверху без предупреждения." },
    { keys = { "gazelle" }, kicker = "СЛУХ · ДОБЫЧА", name = "Dorcas Gazelle  ·  газель доркас",
      body = "Небольшая антилопа, держится стадом. Быстрая, но любопытная.\n" ..
          "Лучшая первая добыча: мяса немного, зато догоняется камнем." },
    { keys = { "buffalo" }, kicker = "СЛУХ · ОПАСНО", name = "African Buffalo  ·  африканский буйвол",
      body = "Тонна мышц и рогов. Стадо агрессивно защищает молодняк.\n" ..
          "Один удар выбрасывает гоминида в воздух. Не подходить без копья и группы." },
    { keys = { "elephant" }, kicker = "СЛУХ · ГИГАНТ", name = "Elephant  ·  слон",
      body = "Самый крупный зверь Олдувая. Не охотится, но топчет всё на пути.\n" ..
          "Держитесь с подветренной стороны: чует за сотни метров." },
    { keys = { "hippo" }, kicker = "СЛУХ · ОПАСНО", name = "Hippo  ·  гиппопотам",
      body = "В воде быстрее человека, на земле — тоже. Территориален.\n" ..
          "Водопой с гиппо — не место для купания." },
    { keys = { "rhino" }, kicker = "СЛУХ · ГИГАНТ", name = "White Rhino  ·  белый носорог",
      body = "Мирный травоядный гигант с плоской мордой. Плохо видит, но чует отлично.\n" ..
          "Опасен только при защите детёныша." },
    { keys = { "zebra" }, kicker = "СЛУХ · ДОБЫЧА", name = "Zebra  ·  зебра",
      body = "Полосатая лошадь саванны. Быстрая, бьёт копытами.\n" ..
          "Отбившегося от стада жеребёнка можно догнать." },
    { keys = { "crocodile", "croco" }, kicker = "СЛУХ · ОПАСНО", name = "Crocodile  ·  крокодил",
      body = "Ждёт в воде у берега. Хватка не отпускает, тянет под воду.\n" ..
          "Никогда не пейте там, где видели крокодила." },
    { keys = { "otter" }, kicker = "СЛУХ · ХИЩНИК", name = "Giant Otter  ·  гигантская выдра",
      body = "Стайный хищник у воды, до 2 метров. Нападает группой, кусает за конечности.\n" ..
          "Опаснее на мелководье, чем кажется." },
    { keys = { "hyena" }, kicker = "СЛУХ · ПАДАЛЬЩИК", name = "Hyena  ·  гиена",
      body = "Стайный падальщик, отбирает добычу у одиночек. Смелеет к ночи.\n" ..
          "Отгоняется камнями и огнём." },
    { keys = { "jackal" }, kicker = "СЛУХ · ПАДАЛЬЩИК", name = "Black-Backed Jackal  ·  чепрачный шакал",
      body = "Мелкий хищник, таскает яйца и детёнышей. Одиночка, но хитрый.\n" ..
          "Убивается одним ударом камня." },
    { keys = { "horse" }, kicker = "СЛУХ · ДОБЫЧА", name = "Miocene African Horse  ·  миоценовая лошадь",
      body = "Трёхпалая лошадь миоцена размером с пони. Стадная, пугливая.\n" ..
          "Мясо жирное — редкость в этих краях." },
    { keys = { "baby" }, kicker = "СЛУХ · КЛАН · РЕБЁНОК", name = "Детёныш клана",
      body = "Малыш племени. Не может сам добывать еду и убегать от хищников.\n" ..
          "Носите на спине в опасных местах — иначе его унесут птицы или пантера." },
    { keys = { "elder" }, kicker = "СЛУХ · КЛАН · СТАРИК", name = "Старейшина клана",
      body = "Самый опытный сородич: знает больше нейронных узлов.\n" ..
          "У стариков меньше здоровья — не берите их в дальние вылазки." },
    { keys = { "sahel", "female", "male", "hominid", "homo", "orrorin", "ardi" },
      kicker = "СЛУХ · КЛАН · СОРОДИЧ", name = "Сородич  ·  Sahelanthropus",
      body = "Представитель вашего вида. Сородичи читают эмоции по лицу.\n" ..
          "Общайтесь жестами: доверие растёт, клан держится вместе." },
}

local function lookup(classname)
    local lc = string.lower(classname or "")
    for _, e in ipairs(DB) do
        for _, k in ipairs(e.keys) do
            if lc:find(k, 1, true) then return e end
        end
    end
    return nil
end

-- ---------------------------------------------------------------- content database (Scripts/codex_data.lua)
local codex = nil
do
    local ok, res = pcall(dofile, "ue4ss/Mods/AncestorsCodex/Scripts/codex_data.lua")
    if ok and type(res) == "table" then
        codex = res
    else
        log("codex_data.lua not loaded: " .. tostring(res))
    end
end
if codex then
    local entries = {}
    local function add(list)
        for _, e in ipairs(list or {}) do
            if e.keys and e.en then
                table.insert(entries, {
                    keys = e.keys,
                    kicker = "СЛУХ · " .. tostring(e.cat or "СУЩНОСТЬ"),
                    name = tostring(e.en) .. "  ·  " .. tostring(e.ru or ""),
                    body = tostring(e.body or "") .. (e.variants and ("\n" .. tostring(e.variants)) or ""),
                })
            end
        end
    end
    add(codex.animals)
    add(codex.clan)
    add(codex.items)
    if #entries > 0 then DB = entries end
    log("codex data: " .. tostring(#DB) .. " entries (animals " ..
        tostring(#(codex.animals or {})) .. ", items " .. tostring(#(codex.items or {})) ..
        ", clan " .. tostring(#(codex.clan or {})) .. ")")
end

-- ---------------------------------------------------------------- level & camera
local function any_character()
    return FindFirstOf("VL01_Sahel_Male_Pawn_C")
        or FindFirstOf("VL01_Sahel_Female_Pawn_C")
        or FindFirstOf("VL01_Sahel_Baby_Pawn_C")
        or FindFirstOf("Character")
end

-- a level is loaded when the player controller actually controls a clan pawn (main menu has neither)
local function in_game()
    if not g_pc then g_pc = FindFirstOf("PlayerController") end
    if not g_pc then return false end
    if not g_world then g_world = safe(function() return g_pc:GetWorld() end, nil) end
    local p = safe(function() return g_pc.Pawn end, nil)
    if not p then
        g_self_addr = nil
        return false
    end
    local cn = cls_name(p)
    return cn:find("_Pawn_C", 1, true) ~= nil
end

local function self_addr()
    if g_self_addr then return g_self_addr end
    local a = safe(function() return g_pc.Pawn end, nil)
    if a then g_self_addr = safe(function() return a:GetAddress() end, nil) end
    return g_self_addr
end

local function is_self(actor)
    local sa = self_addr()
    if not sa then return false end
    local aa = safe(function() return actor:GetAddress() end, nil)
    return aa ~= nil and aa == sa
end

local function camera_state()
    local pcm = safe(function() return g_pc.PlayerCameraManager end, nil)
    local loc, rot
    if pcm then
        loc = safe(function() return pcm:GetCameraLocation() end, nil)
        rot = safe(function() return pcm:GetCameraRotation() end, nil)
    end
    if not loc then
        local pawn = any_character()
        loc = pawn and safe(function() return pawn:K2_GetActorLocation() end, nil) or nil
    end
    if not rot then rot = safe(function() return g_pc:GetControlRotation() end, nil) end
    return loc, rot
end

local function forward_of(rot)
    local pitch = tonumber(safe(function() return rot.Pitch end, 0)) or 0
    local yaw = tonumber(safe(function() return rot.Yaw end, 0)) or 0
    local p, y = math.rad(pitch), math.rad(yaw)
    local cp = math.cos(p)
    return { X = cp * math.cos(y), Y = cp * math.sin(y), Z = math.sin(p) }
end

local function characters()
    local ok, list = pcall(FindAllOf, "Character")
    if ok and list then return list end
    return {}
end

local function aim_target()
    local loc, rot = camera_state()
    if not loc or not rot then return nil end
    local fwd = forward_of(rot)
    local best, best_ang = nil, AIM_ANGLE
    for _, a in ipairs(characters()) do
        if not is_self(a) then
            local aloc = safe(function() return a:K2_GetActorLocation() end, nil)
            if aloc then
                local dx, dy, dz = aloc.X - loc.X, aloc.Y - loc.Y, aloc.Z - loc.Z
                local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
                if dist <= AIM_DIST and dist > 20 then
                    local dot = (fwd.X * dx + fwd.Y * dy + fwd.Z * dz) / dist
                    if dot > 1 then dot = 1 elseif dot < -1 then dot = -1 end
                    local ang = math.deg(math.acos(dot))
                    if ang <= best_ang then
                        best_ang = ang
                        best = { actor = a, ang = ang, dist = dist, cls = cls_name(a) }
                    end
                end
            end
        end
    end
    return best
end

local function nearest_target(maxdist)
    local loc = camera_state()
    if not loc then return nil end
    local best, bestd = nil, maxdist or 6000
    for _, a in ipairs(characters()) do
        if not is_self(a) then
            local aloc = safe(function() return a:K2_GetActorLocation() end, nil)
            if aloc then
                local dx, dy, dz = aloc.X - loc.X, aloc.Y - loc.Y, aloc.Z - loc.Z
                local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                if d < bestd then
                    bestd = d
                    best = { actor = a, ang = 0, dist = d, cls = cls_name(a) }
                end
            end
        end
    end
    return best
end

-- ---------------------------------------------------------------- panel
local function walk_tree(widget)
    local map, count = {}, 0
    local function walk(x, depth)
        if depth > 14 or not x then return end
        local n = nm(x)
        if n then map[n] = x count = count + 1 end
        local cnt = safe(function() return x:GetChildrenCount() end, nil)
        if type(cnt) == "number" then
            for i = 0, math.min(cnt - 1, 64) do walk(safe(function() return x:GetChildAt(i) end, nil), depth + 1) end
        end
    end
    local wt = safe(function() return widget.WidgetTree end, nil)
    local root = wt and safe(function() return wt.RootWidget end, nil) or nil
    if root then walk(root, 1) end
    return map, count
end

-- Hot reload leaves the previous widget instance in the viewport (Mod shared vars are not reliable here),
-- so every panel instance except the newest is removed by scanning the class.
local function remove_previous(keep)
    local ok, list = pcall(FindAllOf, WIDGET_CLS)
    if not ok or not list then return end
    local removed = 0
    local keepaddr = keep and safe(function() return keep:GetAddress() end, nil) or nil
    for _, w in ipairs(list) do
        local addr = safe(function() return w:GetAddress() end, nil)
        if not (keepaddr and addr == keepaddr) then
            pcall(function() w:RemoveFromParent() end)
            removed = removed + 1
        end
    end
    if removed > 0 then log("removed " .. removed .. " stale panel instance(s)") end
end

-- UMG animations shipped inside the widget: "the hint comes out with the game's own animation"
local g_anim = nil
local g_anim_names = {}

local function collect_animations(w)
    g_anim_names = {}
    g_anim = nil
    local arr = safe(function() return w.Animations end, nil)
    local n = arr and safe(function() return arr:GetArrayNum() end, 0) or 0
    for i = 0, math.max(0, (tonumber(n) or 0) - 1) do
        local a = safe(function() return arr[i] end, nil)
        if a then
            local nmv = safe(function() return a:GetFName():ToString() end, "?")
            table.insert(g_anim_names, nmv)
            if not g_anim then g_anim = a end
        end
    end
    log("panel animations (" .. tostring(#g_anim_names) .. "): " .. table.concat(g_anim_names, ", "))
    return g_anim
end

local function play_anim()
    if not g_w or not g_anim then return false end
    local ok = pcall(function() g_w:PlayAnimation(g_anim, 0.0, 1, 0, 1.0) end)
    if not ok then
        ok = pcall(function() g_w:PlayAnimation(g_anim, 0.0, 1) end)
    end
    log("PlayAnimation(" .. tostring(g_anim_names[1]) .. ") ok=" .. tostring(ok))
    return ok
end

local function ensure_widget()
    if g_w and safe(function() return g_w:IsValid() end, false) then return g_w end
    if not in_game() then return nil end
    remove_previous(nil)
    local lib = StaticFindObject(LIB_PATH)
    local cls = StaticFindObject(WIDGET_BASE .. "." .. WIDGET_CLS)
    if not (lib and cls and g_world and g_pc) then log("panel: missing lib/cls/world") return nil end
    local ok, w = pcall(function() return lib:Create(g_world, cls, g_pc) end)
    if not ok or not w then log("panel: Create failed") return nil end
    pcall(function() return w:AddToViewport(300) end)
    g_map = walk_tree(w)
    g_w = w
    pcall(collect_animations, w)
    log("panel: created")
    return w
end

local function slot_rect(widget, x, y, w, h)
    local slot = widget and safe(function() return widget.Slot end, nil)
    if not slot then return end
    pcall(function() slot:SetAnchors({ Minimum = { X = 0, Y = 0 }, Maximum = { X = 0, Y = 0 } }) end)
    pcall(function() slot:SetAlignment({ X = 0, Y = 0 }) end)
    pcall(function() slot:SetAutoSize(false) end)
    pcall(function() slot:SetPosition({ X = x, Y = y }) end)
    pcall(function() slot:SetSize({ X = w, Y = h }) end)
end

local function scale_widget(widget, s)
    if not widget or s == 1.0 then return end
    -- pivot must be the top-left, otherwise scaling grows around the centre and runs off-screen
    pcall(function() widget:SetRenderTransformPivot({ X = 0.0, Y = 0.0 }) end)
    pcall(function() widget:SetRenderScale({ X = s, Y = s }) end)
end

-- Game-styled panel: real game textures (pause background plate, ornate border, species sense icon).
-- NOTE: UImage:SetColorAndOpacity takes FLinearColor (R,G,B,A) — passing an FSlateColor table silently gives alpha 0.
local function tint_image(img, r, g, b, a)
    if not img then return false end
    local ok = pcall(function() img:SetColorAndOpacity({ R = r, G = g, B = b, A = a }) end)
    return ok
end

local TEX_PLATE = "/Game/GUI/Menus/InGameMenu/assets/pause_bg"
local TEX_BORDER = "/Game/GUI/Menus/InGameMenu/assets/option_button_border"
local ICON_DIR = "/Game/Prod/Data/UI/HUD/Assets/SenseIcons/Hud_Icons/"

-- species -> game sense icon (real HUD art shipped with the game)
local ICON_BY_KEY = {
    { "machairodus", "Enemy_Leopard" }, { "buffalo", "Enemy_Buffalo" },
    { "crocodile", "Enemy_Croco" }, { "croco", "Enemy_Croco" },
    { "eagle", "Enemy_Eagle" }, { "elephant", "Enemy_Elephant" }, { "gazelle", "Enemy_Gazelle" },
    { "pelagornis", "Enemy_Pelago" }, { "giantbird", "Enemy_GiantBird" }, { "hippo", "Enemy_Hippo" },
    { "hyena", "Enemy_Hyena" }, { "jackal", "Enemy_Jackal" }, { "leopard", "Enemy_Leopard" },
    { "otter", "Enemy_Otter" }, { "rhino", "Enemy_RHino" }, { "scolopendra", "Enemy_Scolo" },
    { "centipede", "Enemy_Scolo" }, { "python", "Enemy_Snake" }, { "mamba", "Enemy_SnakePoison" },
    { "vervet", "Enemy_Vervet" }, { "monkey", "Enemy_Vervet" }, { "warthog", "Enemy_Warthog" },
    { "swine", "Enemy_Warthog" }, { "zebra", "Enemy_Zebra" },
}

local function icon_for(classname)
    local lc = string.lower(classname or "")
    for _, pair in ipairs(ICON_BY_KEY) do
        if lc:find(pair[1], 1, true) then return ICON_DIR .. pair[2] end
    end
    return nil
end

-- load a game asset by package path and return the object inside it
local function load_asset(path)
    if not path then return nil end
    local leaf = path:match("[^/]+$")
    local obj = StaticFindObject(path .. "." .. leaf)
    if obj then return obj end
    pcall(LoadAsset, path)
    return StaticFindObject(path .. "." .. leaf)
end

local function apply_skin(classname)
    -- plate: the pause-menu background texture, darkened and translucent
    -- the shipped pause background is a light frosted texture and reads as grey once tinted, so the plate
    -- stays a tinted white square while the real game art goes into the icon and the rule
    local dark = g_map and g_map["dark"]
    if dark then
        -- the engine's white square draws as a grey plate here; the game's own panel brush looks right
        -- 1) try the game's UI material for this brush (materials carry the proper blend/tint),
        -- 2) then a dark shipped texture, 3) fall back to the engine white square
        -- plate texture: the BP animates this image's colour every frame, so only a naturally dark
        -- texture reads as a dark plate (tint is overridden by the widget's own animation)
        -- applying a brush to a still-streaming texture crashes the game, so it happens exactly once per session
        if not g_plate_applied then
            g_plate_applied = true
            local best = nil
            for _, p in ipairs({
                "/Game/Prod/Data/UI/HUD/Brush/Regimen/background",
                "/Game/GUI/Menus/MainMenu/Textures/loading_bg",
                "/Game/GUI/Menus/InGameMenu/assets/pause_bg",
            }) do
                best = load_asset(p)
                if best then log("plate texture: " .. p) break end
            end
            if best then pcall(function() dark:SetBrushFromTexture(best, false) end) end
        end
        local borrowed = g_plate_applied
        for _, host in ipairs({ "BP_GameItemDiscoveryWidget_C", "BP_InteractionDiscoveryWidget_C", "BP_TutorialWidget_C" }) do
            local h = FindFirstOf(host)
            if h then
                for _, part in ipairs({ "confirm_bg", "dark", "confirm_text" }) do
                    local src = safe(function() return h:GetWidgetFromName(FName(part)) end, nil)
                    local brush = src and safe(function() return src.Brush end, nil)
                    if brush then
                        local okb = pcall(function() dark:SetBrush(brush) end)
                        if okb then borrowed = true break end
                    end
                end
            end
            if borrowed then break end
        end
        if not borrowed then
            local white = load_asset("/Engine/EngineResources/WhiteSquareTexture")
            if white then pcall(function() dark:SetBrushFromTexture(white, false) end) end
        end
        tint_image(dark, 0.05, 0.06, 0.09, 0.92)
    end
    -- thin gold rule along the plate top (the frame texture is opaque and washes the panel out when stretched)
    local frame = g_map and g_map["flash"]
    if frame then
        local white = load_asset("/Engine/EngineResources/WhiteSquareTexture")
        if white then pcall(function() frame:SetBrushFromTexture(white, false) end) end
        tint_image(frame, 0.88, 0.76, 0.46, 0.80)
    end
    -- species icon from the game's sense-icon set
    local icon = g_map and g_map["Icon"]
    local iconpath = icon_for(classname)
    if icon and iconpath then
        local tex = load_asset(iconpath)
        if tex then
            pcall(function() icon:SetBrushFromTexture(tex, false) end)
            tint_image(icon, 1.0, 1.0, 1.0, 0.95)
            return true
        end
    end
    return false
end

local function ensure_backdrop()
    -- kept for compatibility: apply_skin does the real work
    apply_skin(nil)
end

local function show_panel(kicker, name, body, dbg, cls)
    if not ensure_widget() then return false end
    local root, popup = g_map["CanvasPanel_0"], g_map["CanvasPanel_120"]
    if root then pcall(function() root:SetVisibility(4) end) slot_rect(root, 0, 0, 1920, 1080) end
    if popup then pcall(function() popup:SetVisibility(4) end) slot_rect(popup, 0, 0, 1920, 1080) end
    for _, n in ipairs({ "Icon", "flash", "circle1", "circle2", "circle3", "circle4",
        "circle_appear", "dashcircle", "disc_circle" }) do
        local o = g_map[n]
        if o then pcall(function() o:SetVisibility(1) end) end
    end
    apply_skin(cls)
    -- one text block only: the three blocks live in the same layout box and fight each other when moved
    local head = kicker
    if DEBUG_TEXT and dbg then head = head .. "   " .. dbg end
    local text = head .. "\n" .. name .. "\n\n" .. body

    -- size the plate to the text so empty space is not rendered at all
    local wrap = math.max(20, math.floor(W_TEXT / CHAR_W))
    local lines = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        local len = safe(function() return utf8.len(line) end, nil) or #line
        lines = lines + math.max(1, math.ceil(len / wrap))
    end
    local h = math.max(H_MIN, math.min(H_MAX, lines * LINE_H + PAD_Y * 2 + 10))
    local y = math.floor((1080 - h) / 2)      -- vertically centred

    local dark = g_map["dark"]
    if dark then
        pcall(function() dark:SetVisibility(4) end)
        pcall(function() dark:SetRenderOpacity(1.0) end)
        slot_rect(dark, X_PLATE, y, W_PLATE, h)
    end
    -- gold rule along the top edge
    local frame = g_map["flash"]
    if frame then
        pcall(function() frame:SetVisibility(4) end)
        slot_rect(frame, X_PLATE + PAD_Y, y, W_PLATE - PAD_Y, 2)
    end
    -- accent bar hugging the screen edge
    local accent = g_map["dashcircle"]
    if accent then
        pcall(function() accent:SetVisibility(4) end)
        local white = load_asset("/Engine/EngineResources/WhiteSquareTexture")
        if white then pcall(function() accent:SetBrushFromTexture(white, false) end) end
        tint_image(accent, 0.85, 0.70, 0.38, 0.85)
        slot_rect(accent, X_PLATE, y, 3, h)
    end
    -- species icon (game sense icon), top-right of the plate
    local icon = g_map["Icon"]
    if icon and icon_for(cls) then
        pcall(function() icon:SetVisibility(4) end)
        pcall(function() icon:SetRenderOpacity(1.0) end)
        slot_rect(icon, X_PLATE + W_PLATE - ICON_SIZE - 12, y + 12, ICON_SIZE, ICON_SIZE)
    end
    local TBN, TBE, TBB = g_map["TB_GameItemName"], g_map["EnglishName"], g_map["discovery_title"]
    pcall(function() TBB:SetText(FText(text)) end)
    for _, w in ipairs({ TBN, TBE, TBB }) do
        pcall(function() w:SetVisibility(1) end)
    end
    pcall(function() TBB:SetAutoWrapText(true) end)
    pcall(function() TBB:SetVisibility(4) end)
    pcall(function() TBB:SetRenderOpacity(1.0) end)
    pcall(function() TBB:SetJustification(0) end)
    slot_rect(TBB, X_PANEL, y + PAD_Y, W_TEXT, h - PAD_Y * 2)
    scale_widget(TBB, SCALE_BODY)
    if ANIM_ON then play_anim() end
    pcall(function() g_w:SetVisibility(4) end)
    g_panel_on = true
    return true
end

local function hide_panel()
    if g_w then pcall(function() g_w:SetVisibility(1) end) end
    g_panel_on = false
end

local function describe(t, dbg)
    if not t then hide_panel() return end
    local e = lookup(t.cls)
    if e then
        show_panel(e.kicker, e.name, e.body, dbg, t.cls)
    else
        show_panel("СЛУХ · НЕИЗВЕСТНОЕ СУЩЕСТВО", t.cls,
            "Описания для этого вида пока нет в базе.\nКласс: " .. t.cls, dbg, t.cls)
    end
end

-- ---------------------------------------------------------------- driver
local function announce_level()
    if g_level_announced then return end
    if in_game() then
        g_level_announced = true
        log("LEVEL_READY")
        dump_line("LEVEL_READY " .. tostring(os.date and os.date("%H:%M:%S") or ""))
    end
end

local function sense_count()
    local n = #(safe(function() return FindAllOf("BP_SenseIconActor_C") end, {}) or {})
    n = n + #(safe(function() return FindAllOf("BP_FocusIconActor_C") end, {}) or {})
    return n
end

local function update_aim(force)
    if not in_game() then return end
    announce_level()
    if SENSE_ONLY and sense_count() == 0 then
        if g_panel_on then hide_panel() end
        g_last_target = ""
        return
    end
    local t = aim_target()
    local key = t and (t.cls .. "|" .. nm(t.actor)) or ""
    if key ~= g_last_target or force then
        g_last_target = key
        if t then
            local dbg = string.format("[%.0f deg, %.0f m]", t.ang, t.dist / 100)
            describe(t, dbg)
            log(string.format("target %s ang=%.1f dist=%.0f", t.cls, t.ang, t.dist))
        else
            hide_panel()
            log("target none")
        end
    end
end

local function tick_body()
    if not g_armed then return end          -- nothing touches the engine until the player presses a mod key
    if not in_game() then return end
    local now = tonumber(safe(function() return os.clock() end, 0)) or 0
    if now - g_last_hb > 15 then
        g_last_hb = now
        log("HB in_game")   -- heartbeat for the test harness
    end
    if now - g_last_tick < 0.2 then return end
    g_last_tick = now
    pcall(function() update_aim(false) end)
end

-- ---------------------------------------------------------------- keybinds
local function refresh_globals()
    g_pc = g_pc or FindFirstOf("PlayerController")
    if g_pc and not g_world then g_world = safe(function() return g_pc:GetWorld() end, nil) end
end

local function guarded(name, fn)
    g_armed = true
    refresh_globals()
    local ok, err = pcall(function()
        if not in_game() then
            log(name .. ": skipped — level not loaded")
            return
        end
        fn()
    end)
    if not ok then log(name .. " err: " .. tostring(err)) end
end

RegisterKeyBind(Key.F3, function()
    guarded("F3", function()
        local t = nearest_target(6000)
        if t then
            describe(t, string.format("[near %.0fm]", t.dist / 100))
            log("F3 nearest " .. t.cls .. " dist=" .. string.format("%.0f", t.dist))
        else
            log("F3 no character nearby")
        end
    end)
end)

RegisterKeyBind(Key.F4, function()
    guarded("F4", function()
        hide_panel()
        g_last_target = ""
        log("F4 panel hidden")
    end)
end)

RegisterKeyBind(Key.F7, function()
    guarded("F7", function()
        local loc, rot = camera_state()
        local t = aim_target()
        local out = {
            "--- F7 " .. tostring(os.date and os.date("%H:%M:%S") or ""),
            "camera=" .. v2s(loc) .. " pitch=" .. string.format("%.1f", tonumber(safe(function() return rot.Pitch end, 0)) or 0)
                .. " yaw=" .. string.format("%.1f", tonumber(safe(function() return rot.Yaw end, 0)) or 0),
            "characters=" .. tostring(#characters()),
            "aim=" .. (t and (t.cls .. " ang=" .. string.format("%.1f", t.ang) .. " dist=" .. string.format("%.0f", t.dist)) or "NONE"),
            "senseIcons=" .. tostring(#(safe(function() return FindAllOf("BP_SenseIconActor_C") end, {}) or {})),
            "focusIcons=" .. tostring(#(safe(function() return FindAllOf("BP_FocusIconActor_C") end, {}) or {})),
        }
        dump_line(table.concat(out, "\n"))
        for _, l in ipairs(out) do log("F7 " .. l) end
    end)
end)

RegisterKeyBind(Key.F8, function()
    guarded("F8", function()
        if g_panel_on then
            hide_panel()
            log("F8 panel off")
        else
            update_aim(true)
            if not g_panel_on then
                local t = nearest_target(6000)
                if t then describe(t, "[dbg]") end
            end
            log("F8 panel on=" .. tostring(g_panel_on))
        end
    end)
end)

RegisterKeyBind(Key.F2, function()
    guarded("F2", function()
        SENSE_ONLY = not SENSE_ONLY
        log("F2 sense-only = " .. tostring(SENSE_ONLY))
        g_last_target = ""
        update_aim(true)
    end)
end)

RegisterKeyBind(Key.F6, function()
    guarded("F6", function()
        ANIM_ON = not ANIM_ON
        log("F6 animation = " .. tostring(ANIM_ON))
        g_last_target = ""
        update_aim(true)
        if ANIM_ON then play_anim() end
    end)
end)

RegisterKeyBind(Key.F5, function()
    guarded("F5", function()
        DEBUG_TEXT = not DEBUG_TEXT
        log("F5 debug text = " .. tostring(DEBUG_TEXT))
        update_aim(true)
    end)
end)

RegisterKeyBind(Key.F9, function()
    guarded("F9", function()
        local loc, rot = camera_state()
        local out = {
            "=== F9 " .. tostring(os.date and os.date("%H:%M:%S") or ""),
            "pc=" .. (g_pc and nm(g_pc) or "nil"),
            "selfAddr=" .. tostring(self_addr()),
            "camera=" .. v2s(loc) .. " pitch=" .. tostring(safe(function() return rot.Pitch end, "?")),
            "characters=" .. tostring(#characters()),
        }
        local seen = {}
        for _, c in ipairs(characters()) do
            local cn = cls_name(c)
            seen[cn] = (seen[cn] or 0) + 1
        end
        table.insert(out, "--- classes")
        for cn, cnt in pairs(seen) do table.insert(out, "  " .. cn .. " = " .. cnt) end
        dump_line(table.concat(out, "\n"))
        for _, l in ipairs(out) do log("F9 " .. l) end
    end)
end)

-- (no engine calls at load: the object array is not ready yet and FindAllOf there can crash the game)
log("AncestorsCodex v24 loaded (F3 nearest, F4 hide, F5 debug text, F7 dump, F8 toggle, F9 state)")

pcall(function()
    LoopAsync(250, function()
        pcall(function() ExecuteInGameThread(tick_body) end)
        return false
    end)
end)
log("tick: LoopAsync + ExecuteInGameThread")
