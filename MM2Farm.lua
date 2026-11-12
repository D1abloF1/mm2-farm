--[[
  MM2 FARM  v1.4  (Murder Mystery 2, place 142823291)
  v1.4:
    * авто-покупка тиров Хэллоуин-пасса за конфеты (Candies2026)
    * авто-сбор наград пасса (ClaimBattlePassReward) + кнопка "Забрать"
    * HUD: уровень пасса, цена тира, на сколько тиров хватает конфет
    * кнопка включения/выключения авто-покупки пасса
  v1.3:
    * шаг сбора обёрнут в pcall: одна ошибка больше не убивает фарм навсегда
    * цель полёта = позиция монеты (пол только проверяет, что под ней есть земля)
    * fly: защита от падения - при просадке по Y сразу доводим до цели
  Структура игры (проверено в клиенте):
    пикапы:  Workspace.<Map>.CoinContainer.Coin_Server (+ CoinVisual)
    сбор:    ReplicatedStorage.Remotes.Gameplay.CoinCollected (kind, dailyTotal)
    профиль: Remotes.Inventory.GetProfileData:InvokeServer() -> Materials.Owned
             .Halloween2026.CurrentTier / .ClaimedRewards
    пасс:    Remotes.Events.Halloween2026Remotes.BuyBattlePassTiers:FireServer(1)
             Remotes.Events.Halloween2026Remotes.ClaimBattlePassReward:FireServer(тир)
    раунд:   Workspace.RoundTimerPart:GetAttribute("Time" / "RoundLength")
  Клавиши: RightShift пауза, RightAlt режим, RightCtrl HUD.
  Стоп: _G.MM2FarmStop()
]]
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local TS = game:GetService("TeleportService")
local UIS = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Http = game:GetService("HttpService")
local lp = Players.LocalPlayer
local CONFIG_PATH = "MM2FarmConfig.json"
local VERSION = "1.4"
local DEFAULTS = {
	farm = true,
	mode = "fly",       -- fly | walk | tp  (tp ловит античит - только на свой риск)
	flySpeed = 130,     -- studs/сек в полёте
	walkSpeed = 55,     -- studs/сек в наземном режиме
	humanize = true,
	scanDelay = 0.35,
	minPlayers = 2,
	soloSeconds = 25,
	antiAfk = true,
	afkSeconds = 60,
	autoRejoin = false,
	hud = true,
	profileRefresh = 15,
	hopOnStuck = false,
	stuckSeconds = 75,
	autoBuyPass = true,    -- покупать тиры пасса за Candies2026
	autoClaimPass = true,  -- забирать награды полученных тиров
	autoClosePopup = true, -- закрывать окно "New Item -> Claim"
	passTierCost = 600,    -- фолбэк, если цену не удалось прочитать из GUI
	maxPassTier = 30,
}
local cfg = table.clone(DEFAULTS)
local function loadConfig()
	local ok, raw = pcall(readfile, CONFIG_PATH)
	if not ok or type(raw) ~= "string" then return end
	local ok2, tbl = pcall(function() return Http:JSONDecode(raw) end)
	if ok2 and type(tbl) == "table" then
		for k, v in pairs(tbl) do
			if DEFAULTS[k] ~= nil then cfg[k] = v end
		end
		if cfg.mode == "tp" then cfg.mode = "fly" end -- TP убран: ловит античит
	end
end
local function saveConfig()
	pcall(function() writefile(CONFIG_PATH, Http:JSONEncode(cfg)) end)
end
-- 1. зачистка прошлой версии
local GENERATION = os.clock() + math.random()
_G.MM2FarmGeneration = GENERATION
local old = _G.__MM2Farm
if type(old) == "table" and type(old.stop) == "function" then
	pcall(function() old.stop("restart") end)
end
local function wipeGui(container)
	if not container then return end
	for _, g in ipairs(container:GetChildren()) do
		if g:IsA("ScreenGui") and g.Name == "MM2FarmHUD" then
			pcall(function() g:Destroy() end)
		end
	end
end
wipeGui(lp:FindFirstChild("PlayerGui"))
pcall(function() wipeGui(game:GetService("CoreGui")) end)
pcall(function() wipeGui(gethui()) end)
local function uiParent()
	local ok, hui = pcall(gethui)
	if ok and typeof(hui) == "Instance" then return hui end
	return lp:FindFirstChild("PlayerGui")
end
loadConfig()
-- 2. состояние
local state = {
	running = true,
	status = "запуск",
	map = "—",
	roundTime = "—",
	players = 0,
	pickups = 0,
	balanceDelta = 0,
	baseBalance = nil,
	coinsOnMap = 0,
	errorText = "",
	startedAt = os.clock(),
	account = {},
	level = 0,
	xp = 0,
	hops = 0,
	soloSince = nil,
	inRound = false,
	lastCoinAt = os.clock(),
	passTier = 0,
	passMax = 30,
	passCost = 600,
	passClaimed = {},
	passBuys = 0,
	passClaims = 0,
	passAffordable = 0,
	passLastBuyAt = 0,
	popupClosed = 0,
	afkPulses = 0,
	afkLast = 0,
	lastPassUiRead = 0,
	profileBusy = false,
	ui = nil,
}
local CANDIES_KEY = "Candies2026"
local function candiesOf(fallback)
	local v = state.account and state.account[CANDIES_KEY]
	v = tonumber(v)
	if v ~= nil then return v end
	return fallback
end
local connections = {}
local function track(conn)
	connections[#connections + 1] = conn
	return conn
end
local function disconnectAll()
	for _, c in ipairs(connections) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(connections)
end
local function alive()
	return state.running and _G.MM2FarmGeneration == GENERATION
end
-- 3. утилиты
local function log(fmt, ...)
	print("[MM2Farm] " .. string.format(fmt, ...))
end
local function num(n)
	n = tonumber(n)
	if not n then return "0" end
	local s = tostring(math.floor(n))
	local out = s:reverse():gsub("(%d%d%d)", "%1 "):reverse()
	return (out:gsub("^%s+", ""))
end
local function humanoidRoot()
	local ch = lp.Character
	return ch and ch:FindFirstChild("HumanoidRootPart")
end
local function isPickup(d)
	if not d:IsA("BasePart") then return false end
	local n = d.Name
	if n == "CoinVisual" then return false end
	return (n:find("Coin") or n:find("Candy") or n:find("Egg")
		or n:find("BeachBall") or n:find("SnowToken")) ~= nil
end
local function findMap()
	for _, m in ipairs(workspace:GetChildren()) do
		if m:IsA("Model") and m.Name ~= "Lobby" and m:FindFirstChild("CoinContainer", true) then
			return m
		end
	end
end
local skipCoins = {}
local function shouldSkip(coin)
	local at = skipCoins[coin]
	if not at then return false end
	if not coin.Parent or os.clock() - at > 6 then
		skipCoins[coin] = nil
		return false
	end
	return true
end
local function collectPickups(origin)
	local list = {}
	local count = 0
	local dead = 0
	for _, d in ipairs(workspace:GetDescendants()) do
		if d.Parent and isPickup(d) then
			count += 1
			list[#list + 1] = d
			if skipCoins[d] and os.clock() - skipCoins[d] > 6 then
				skipCoins[d] = nil
				dead += 1
			end
		end
	end
	state.coinsOnMap = count
	if not origin then return nil end
	table.sort(list, function(a, b)
		return (a.Position - origin).Magnitude < (b.Position - origin).Magnitude
	end)
	for _, c in ipairs(list) do
		if not shouldSkip(c) then return c end
	end
	return nil
end
local function skipCoin(coin)
	skipCoins[coin] = os.clock()
end
-- 4. счётчики
track(RS.Remotes.Gameplay.CoinCollected.OnClientEvent:Connect(function(kind)
	state.pickups += 1
	state.lastCoinAt = os.clock()
end))
local function refreshProfileInner()
	local rf = RS:FindFirstChild("Remotes")
		and RS.Remotes:FindFirstChild("Inventory")
		and RS.Remotes.Inventory:FindFirstChild("GetProfileData")
	if not rf then return end
	local done, data = false, nil
	task.spawn(function()
		local ok, res = pcall(function() return rf:InvokeServer() end)
		if ok then data = res end
		done = true
	end)
	local waited = 0
	while not done and waited < 4 do
		task.wait(0.1)
		waited += 0.1
	end
	if type(data) ~= "table" then return end
	local acc = {}
	local owned = data.Materials and data.Materials.Owned
	if type(owned) == "table" then
		for k, v in pairs(owned) do acc[tostring(k)] = tonumber(v) or v end
	end
	state.account = acc
	state.xp = tonumber(data.NewXP) or 0
	state.level = tonumber(lp:GetAttribute("Level")) or 0
	local key = "Candies2026"
	if acc[key] ~= nil then
		if state.baseBalance == nil then state.baseBalance = acc[key] end
		state.balanceDelta = math.max(0, (acc[key] or 0) - (state.baseBalance or 0))
	end
	-- пасс: тир и забранные награды (профиль авторитетнее GUI)
	local hall = data.Halloween2026
	if type(hall) == "table" then
		local t = tonumber(hall.CurrentTier)
		if t then state.passTier = t end
		local cr = hall.ClaimedRewards
		if type(cr) == "table" then
			local clean = {}
			for k, v in pairs(cr) do
				local n = tonumber(k)
				if n and v then clean[n] = true end
			end
			state.passClaimed = clean
		end
	end
end
local function refreshProfile()
	if state.profileBusy then return end
	state.profileBusy = true
	local ok, err = pcall(refreshProfileInner)
	state.profileBusy = false
	if not ok then log("профиль: ошибка %s", tostring(err)) end
end
-- 4.1 пасс: авто-покупка тиров, авто-сбор наград, закрытие попапа
local function passRemote(name)
	local remotes = RS:FindFirstChild("Remotes")
	local events = remotes and remotes:FindFirstChild("Events")
	local hall = events and events:FindFirstChild("Halloween2026Remotes")
	return hall and hall:FindFirstChild(name)
end
local function passGui()
	local pg = lp:FindFirstChild("PlayerGui")
	local cp = pg and pg:FindFirstChild("CrossPlatform")
	local hall = cp and cp:FindFirstChild("Halloween2026")
	local main = hall and hall:FindFirstChild("MainEvent")
	main = main and main:FindFirstChild("Main")
	return main and main:FindFirstChild("BattlePass")
end
local function numberFrom(text)
	local digits = tostring(text or ""):gsub("[^%d]", "")
	return tonumber(digits)
end
local function readPassUi()
	local bp = passGui()
	if not bp then return end
	local title = bp:FindFirstChild("Title")
	local tierBox = title and title:FindFirstChild("YourTier")
	local lbl = tierBox and tierBox:FindFirstChild("TextLabel")
	if lbl then
		local cur, max = tostring(lbl.Text):match("(%d+)%s*/%s*(%d+)")
		if tonumber(cur) then state.passTier = tonumber(cur) end
		if tonumber(max) then state.passMax = tonumber(max) end
	end
	local buy = bp:FindFirstChild("BuyTiers")
	local token = buy and buy:FindFirstChild("TokenBuy")
	local container = token and token:FindFirstChild("Container")
	local info = container and container:FindFirstChild("BuyInfo")
	if info then
		local total = info:FindFirstChild("TotalCost")
		local amount = info:FindFirstChild("TierAmount")
		local cost = numberFrom(total and total.Text)
		local count = numberFrom(amount and amount.Text) or 1
		if cost and count and count > 0 and cost > 0 then
			state.passCost = math.max(1, math.floor(cost / count + 0.5))
		end
	end
end
-- окно "New Item -> Claim": жмём Claim и, если не закрылось, скрываем
local function closeItemPopup()
	if not cfg.autoClosePopup then return end
	local pg = lp:FindFirstChild("PlayerGui")
	if not pg then return end
	local popups = {}
	local cp = pg:FindFirstChild("CrossPlatform")
	local cpItem = cp and cp:FindFirstChild("NewItem")
	if cpItem then popups[#popups + 1] = cpItem end
	local mg = pg:FindFirstChild("MainGUI")
	local gm = mg and mg:FindFirstChild("Game")
	local mgItem = gm and gm:FindFirstChild("NewItem")
	if mgItem then popups[#popups + 1] = mgItem end
	for _, popup in ipairs(popups) do
		if popup:IsA("GuiObject") and popup.Visible then
			local medium = popup:FindFirstChild("Medium")
			local cont = medium and medium:FindFirstChild("Container")
			local btn = cont and cont:FindFirstChild("Claim")
			if btn then
				local ok, conns = pcall(getconnections, btn.Activated)
				if ok then
					for _, c in ipairs(conns) do
						pcall(function() c:Fire() end)
					end
				end
			end
			task.wait(0.15)
			if popup.Visible then
				pcall(function() popup.Visible = false end)
			end
			state.popupClosed += 1
		end
	end
end
local function passTick()
	if not alive() then return end
	readPassUi()
	local tier = math.max(0, tonumber(state.passTier) or 0)
	local maxTier = math.max(tier, tonumber(state.passMax) or cfg.maxPassTier or 30)
	local cost = tonumber(state.passCost) or tonumber(cfg.passTierCost) or 0
	local candies = candiesOf(0)
	state.passAffordable = (cost > 0) and math.floor(candies / cost) or 0
	-- 1. сбор наград пасса
	if cfg.autoClaimPass and tier > 0 then
		local claimed = state.passClaimed or {}
		local got = 0
		for t = 1, tier do
			if got >= 8 then break end
			if not claimed[t] then
				local rem = passRemote("ClaimBattlePassReward")
				if not rem then break end
				local ok = pcall(function() rem:FireServer(t) end)
				if not ok then break end
				claimed[t] = true
				state.passClaims += 1
				got += 1
				log("пасс: забрана награда тира %d", t)
				task.wait(0.7)
			end
		end
		if got > 0 then
			task.wait(1)
			refreshProfile()
			candies = candiesOf(candies)
			state.passAffordable = (cost > 0) and math.floor(candies / cost) or 0
		end
		state.passClaimed = claimed
	end
	-- 2. покупка следующего тира за конфеты
	if cfg.autoBuyPass and cost > 0 and tier >= 1 and tier < maxTier and candies >= cost then
		if os.clock() - (state.passLastBuyAt or 0) >= 4 then
			state.passLastBuyAt = os.clock()
			local rem = passRemote("BuyBattlePassTiers")
			if rem then
				local ok = pcall(function() rem:FireServer(1) end)
				if ok then
					state.passBuys += 1
					log("пасс: тир %d -> %d за %d (конфет %d)", tier, tier + 1, cost, candies)
					task.wait(1.5)
					refreshProfile()
				else
					log("пасс: ошибка покупки тира")
				end
			end
		end
	end
end
-- окно "New Item -> Claim" закрываем постоянно, а не один раз
task.spawn(function()
	while alive() do
		pcall(closeItemPopup)
		task.wait(0.6)
	end
end)
-- 5. автофарм
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local function hasFloor(point, hrp)
	rayParams.FilterDescendantsInstances = { lp.Character }
	return workspace:Raycast(point + Vector3.new(0, 60, 0), Vector3.new(0, -320, 0), rayParams)
end
local function goalFor(coin, hrp)
	local base = coin.Position
	if not hasFloor(base, hrp) then
		return nil -- под монетой пустота: не летим туда
	end
	local goal = Vector3.new(base.X, base.Y + 3.2, base.Z)
	if cfg.humanize then
		goal = goal + Vector3.new(math.random(-5, 5) / 10, 0, math.random(-5, 5) / 10)
	end
	return goal
end
local function waitCollected(coin, timeout)
	local waited = 0
	while coin.Parent and waited < timeout do
		task.wait(0.01)
		waited += 0.01
	end
	return coin.Parent == nil
end
-- ПЛАВНЫЙ ПОЛЁТ: CFrame-шаги по кадрам.
-- CFrame двигает персонажа напрямую, поэтому стены и коллизии его не держат.
-- Шаг за кадр маленький (скорость * dt) - это не телепорт, античит не кикает.
local noClipParts = {}
local function setNoClip(on, hrp)
	local char = hrp and hrp.Parent
	if not char then return end
	if on then
		for _, p in ipairs(char:GetDescendants()) do
			if p:IsA("BasePart") and p.CanCollide then
				p.CanCollide = false
				noClipParts[p] = true
			end
		end
	else
		for p in pairs(noClipParts) do
			if p and p.Parent then pcall(function() p.CanCollide = true end) end
		end
		table.clear(noClipParts)
	end
end
local function flyTo(coin, goal)
	local hrp = humanoidRoot()
	if not hrp then return false end
	-- на старте раунда ждём пол под ногами, иначе noclip уронит в пустоту
	local fhit = hasFloor(hrp.Position, hrp)
	if not fhit or (hrp.Position.Y - fhit.Position.Y) > 30 then task.wait(0.8) end
	hrp = humanoidRoot()
	if not hrp then return false end
	-- отключаем физику гуманоида, иначе он тянет вниз и мешает CFrame
	local char = hrp.Parent
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		pcall(function() hum.PlatformStand = true end)
		pcall(function() hum:ChangeState(Enum.HumanoidStateType.Physics) end)
	end
	-- игра может вернуть CanCollide после смены состояния - ставим ещё раз
	setNoClip(true, hrp)
	pcall(function() hrp.AssemblyLinearVelocity = Vector3.zero end)
	local deadline = os.clock() + 15
	while alive() and coin.Parent and os.clock() < deadline do
		local dt = RunService.Heartbeat:Wait()
		dt = math.clamp(dt, 0.001, 0.05)
		local h = humanoidRoot()
		if not h then break end
		if h.Parent ~= char then
			char = h.Parent
			hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum then
				pcall(function() hum.PlatformStand = true end)
				pcall(function() hum:ChangeState(Enum.HumanoidStateType.Physics) end)
			end
		end
		-- держим noclip и Physics каждый кадр: MM2 умеет возвращать коллизии
		setNoClip(true, h)
		if h.Position.Y < goal.Y - 80 then pcall(function() h.CFrame = CFrame.new(goal) end) break end
		if hum and hum:GetState() ~= Enum.HumanoidStateType.Physics then
			pcall(function() hum:ChangeState(Enum.HumanoidStateType.Physics) end)
		end
		local pos = h.Position
		local delta = goal - pos
		local dist = delta.Magnitude
		if dist < 2 then break end
		-- строго по прямой к монете, без подстройки под пол/крышу
		local speed = math.min(cfg.flySpeed, math.max(18, dist * 4))
		local step = math.min(dist, speed * dt)
		pcall(function() h.CFrame = CFrame.new(pos + delta.Unit * step) end)
		pcall(function() h.AssemblyLinearVelocity = Vector3.zero end)
	end
	-- финальная доводка + удержание: без коллизий персонаж иначе падает сквозь пол
	-- и монета не успевает засчитаться
	local guard = 0
	local held = 0
	while alive() and coin.Parent and held < 0.7 do
		local h = humanoidRoot()
		if not h then break end
		setNoClip(true, h)
		local delta = goal - h.Position
		if delta.Magnitude > 0.6 then
			local dt = RunService.Heartbeat:Wait()
			local step = math.min(delta.Magnitude, math.max(6, math.min(delta.Magnitude * 8, cfg.flySpeed)) * math.clamp(dt, 0.001, 0.05))
			pcall(function() h.CFrame = CFrame.new(h.Position + delta.Unit * step) end)
		else
			pcall(function() h.CFrame = CFrame.new(goal) end)
			task.wait(0.03)
			held += 0.03
		end
		pcall(function() h.AssemblyLinearVelocity = Vector3.zero end)
		guard += 1
		if guard > 400 then break end
	end
	waitCollected(coin, 0.15)
	if hum then
		pcall(function() hum.PlatformStand = false end)
		pcall(function() hum:ChangeState(Enum.HumanoidStateType.GettingUp) end)
	end
	setNoClip(false, humanoidRoot())
	return coin.Parent == nil
end
-- наземный режим: обычная ходьба ускоренным шагом (самый "легальный" для сервера)
local function walkTo(coin, goal)
	local hrp = humanoidRoot()
	if not hrp then return false end
	local humanoid = hrp.Parent and hrp.Parent:FindFirstChildOfClass("Humanoid")
	if humanoid then pcall(function() humanoid.WalkSpeed = cfg.walkSpeed end) end
	local deadline = os.clock() + 20
	local lastPos = hrp.Position
	local stuck = 0
	while alive() and coin.Parent and os.clock() < deadline do
		local h = humanoidRoot()
		if not h then break end
		local delta = goal - h.Position
		local flat = Vector3.new(delta.X, 0, delta.Z)
		if flat.Magnitude < 2.5 then break end
		local dir = flat.Unit
		pcall(function()
			h.AssemblyLinearVelocity = Vector3.new(dir.X * cfg.walkSpeed, h.AssemblyLinearVelocity.Y, dir.Z * cfg.walkSpeed)
		end)
		if (h.Position - lastPos).Magnitude < 0.2 then
			stuck += 1
			if stuck >= 8 and humanoid then pcall(function() humanoid.Jump = true end) end
		else
			stuck = 0
		end
		lastPos = h.Position
		task.wait(0.03)
	end
	local h = humanoidRoot()
	if h then pcall(function() h.AssemblyLinearVelocity = Vector3.new(0, h.AssemblyLinearVelocity.Y, 0) end) end
	waitCollected(coin, 0.4)
	return coin.Parent == nil
end
-- один шаг сбора: возвращает паузу перед следующим шагом
local function collectStep()
	if not cfg.farm then return 0.15 end
	local hrp = humanoidRoot()
	if not hrp then
		state.status = "ожидание"
		return 0.35
	end
	local map = findMap()
	state.map = map and map.Name or "Лобби"
	local coin = collectPickups(hrp.Position)
	if not coin then
		state.inRound = false
		state.status = "ждём раунд"
		return cfg.scanDelay
	end
	-- в лобби карта тоже лежит в workspace, но монеты далеко: это не раунд
	if (coin.Position - hrp.Position).Magnitude > 400 then
		state.inRound = false
		state.status = "ждём раунд"
		return 0.5
	end
	if not state.inRound then state.lastCoinAt = os.clock() end
	state.inRound = true
	local goal = goalFor(coin, hrp)
	if not goal then
		skipCoin(coin) -- под монетой нет пола: не телепортимся, берём следующую
		return 0.02
	end
	if cfg.mode == "fly" then
		if not flyTo(coin, goal) then skipCoin(coin) end
	elseif cfg.mode == "walk" then
		if not walkTo(coin, goal) then skipCoin(coin) end
	else
		if not flyTo(coin, goal) then skipCoin(coin) end
	end
	return 0
end
task.spawn(function()
	while alive() do
		local ok, res = pcall(collectStep)
		if ok then
			if type(res) == "number" and res > 0 then task.wait(res) end
			state.errorText = ""
		else
			state.errorText = tostring(res)
			log("ошибка шага: %s", tostring(res))
			task.wait(1)
		end
	end
end)
local MODES = { "fly", "walk" }
local MODE_TITLE = { fly = "FLY", walk = "WALK", tp = "TP" }
local function cycleMode()
	local idx = 1
	for i, m in ipairs(MODES) do
		if m == cfg.mode then idx = i end
	end
	cfg.mode = MODES[idx % #MODES + 1]
	saveConfig()
	if cfg.mode ~= "fly" then
		pcall(function() setNoClip(false, humanoidRoot()) end)
	end
	log("режим: %s", MODE_TITLE[cfg.mode] or cfg.mode)
end
-- 6. анти-АФК (механизмы из ZaLupa Hub)
--   1) глушим обработчики LocalPlayer.Idled (getconnections -> Disable/Disconnect)
--   2) VirtualUser: CaptureController + ClickButton2 (имитация правого клика)
--   3) VirtualInputManager: нажатие/отпускание ЛКМ
--   4) импульс раз в 60с и по событию Idled; всё в pcall (набор API зависит от экзекутора)
local ourIdled
local function killIdled()
	local ok, conns = pcall(getconnections, lp.Idled)
	if not ok or type(conns) ~= "table" then return 0 end
	local killed = 0
	for _, c in ipairs(conns) do
		local mine = false
		if ourIdled then pcall(function() mine = (c.Function == ourIdled) end) end
		if not mine then
			local done = false
			pcall(function()
				c:Disable()
				done = true
			end)
			if not done then
				done = pcall(function()
					c:Disconnect()
				end)
			end
			if done then killed += 1 end
		end
	end
	return killed
end
local function antiAfkPulse()
	-- не чаще раза в 5с: Idled может срабатывать пачками
	if state.afkLast and os.clock() - state.afkLast < 5 then return false end
	state.afkLast = os.clock()
	pcall(killIdled)
	pcall(function()
		local vu = game:GetService("VirtualUser")
		vu:CaptureController()
		vu:ClickButton2(Vector2.zero, workspace.CurrentCamera.CFrame)
	end)
	pcall(function()
		local vim = game:GetService("VirtualInputManager")
		vim:SendMouseButtonEvent(0, 0, 0, true, game, 0)
	end)
	task.wait(0.05)
	pcall(function()
		local vim = game:GetService("VirtualInputManager")
		vim:SendMouseButtonEvent(0, 0, 0, false, game, 0)
	end)
	-- плюс маленький шаг персонажем: серверу видно реальное движение
	pcall(function()
		local h = lp.Character and lp.Character:FindFirstChildOfClass("Humanoid")
		if h and h.Health > 0 then h.Jump = true end
	end)
	state.afkPulses += 1
	return true
end
ourIdled = function()
	if cfg.antiAfk then pcall(antiAfkPulse) end
end
track(lp.Idled:Connect(ourIdled))
task.spawn(function()
	pcall(killIdled)
	pcall(antiAfkPulse)
	while alive() do
		if cfg.antiAfk then
			pcall(antiAfkPulse)
			task.wait(cfg.afkSeconds or 60)
		else
			task.wait(2)
		end
	end
end)
-- 7. реджойн
local function hop()
	state.hops += 1
	log("реджойн #%d (игроков: %d)", state.hops, state.players)
	saveConfig()
	pcall(function() TS:Teleport(game.PlaceId, lp) end)
	task.wait(2)
	pcall(function() TS:Teleport(game.PlaceId) end)
end
task.spawn(function()
	while alive() do
		state.players = #Players:GetPlayers()
		if cfg.autoRejoin and state.players < cfg.minPlayers and state.players > 0 then
			state.soloSince = state.soloSince or os.clock()
			if os.clock() - state.soloSince > cfg.soloSeconds then
				state.soloSince = nil
				hop()
				task.wait(6)
			end
		else
			state.soloSince = nil
		end
		if cfg.hopOnStuck and cfg.autoRejoin and cfg.farm and state.inRound and state.status == "фарм" then
			if os.clock() - state.lastCoinAt > cfg.stuckSeconds then
				state.lastCoinAt = os.clock()
				hop()
				task.wait(6)
			end
		end
		task.wait(2)
	end
end)
-- 8. профиль и таймер
task.spawn(function()
	local last = 0
	while alive() do
		if os.clock() - last >= cfg.profileRefresh then
			last = os.clock()
			refreshProfile()
			pcall(passTick)
		end
		local rt = workspace:FindFirstChild("RoundTimerPart")
		local t = rt and tonumber(rt:GetAttribute("Time"))
		state.roundTime = t and string.format("%d:%02d", math.floor(t / 60), math.floor(t % 60)) or "—"
		task.wait(0.5)
	end
end)
-- 9. GUI с кнопками
local ACCENT = Color3.fromRGB(122, 92, 255)
local DANGER = Color3.fromRGB(210, 72, 72)
local function makeButton(parent, text, pos, size, color)
	local b = Instance.new("TextButton")
	b.Size = size
	b.Position = pos
	b.BackgroundColor3 = color or Color3.fromRGB(30, 30, 38)
	b.AutoButtonColor = false
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamMedium
	b.TextSize = 12
	b.TextColor3 = Color3.fromRGB(236, 236, 242)
	b.Text = text
	b.ZIndex = 101
	b.Parent = parent
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = b
	local s = Instance.new("UIStroke")
	s.Color = Color3.fromRGB(64, 64, 78)
	s.Thickness = 1
	s.Transparency = 0.25
	s.Parent = b
	b.MouseEnter:Connect(function() s.Color = ACCENT end)
	b.MouseLeave:Connect(function() s.Color = Color3.fromRGB(64, 64, 78) end)
	return b
end
local function buildGui()
	local pg = uiParent()
	if not pg then return end
	local gui = Instance.new("ScreenGui")
	gui.Name = "MM2FarmHUD"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 2147483647
	gui.IgnoreGuiInset = true
	gui.Parent = pg
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromOffset(336, 222)
	frame.Position = UDim2.fromOffset(14, 14)
	frame.BackgroundColor3 = Color3.fromRGB(10, 10, 13)
	frame.BackgroundTransparency = 0.12
	frame.BorderSizePixel = 0
	frame.Active = true
	frame.ZIndex = 100
	frame.Parent = gui
	local fc = Instance.new("UICorner")
	fc.CornerRadius = UDim.new(0, 10)
	fc.Parent = frame
	local fs = Instance.new("UIStroke")
	fs.Color = ACCENT
	fs.Thickness = 1
	fs.Transparency = 0.55
	fs.Parent = frame
	local title = Instance.new("TextLabel")
	title.Size = UDim2.new(1, -20, 0, 20)
	title.Position = UDim2.fromOffset(10, 6)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.TextSize = 13
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.RichText = true
	title.TextColor3 = Color3.fromRGB(240, 240, 248)
	title.ZIndex = 101
	title.Text = "MM2 FARM <font color=\"#8f7bff\">v" .. VERSION .. "</font>"
	title.Parent = frame
	local info = Instance.new("TextLabel")
	info.Size = UDim2.new(1, -20, 0, 92)
	info.Position = UDim2.fromOffset(10, 26)
	info.BackgroundTransparency = 1
	info.Font = Enum.Font.Code
	info.TextSize = 12
	info.TextXAlignment = Enum.TextXAlignment.Left
	info.TextYAlignment = Enum.TextYAlignment.Top
	info.RichText = true
	info.TextColor3 = Color3.fromRGB(215, 215, 226)
	info.ZIndex = 101
	info.Text = ""
	info.Parent = frame
	local farmBtn = makeButton(frame, "⏸ Пауза", UDim2.fromOffset(10, 122), UDim2.fromOffset(155, 26), Color3.fromRGB(40, 40, 52))
	local modeBtn = makeButton(frame, "Режим: TP", UDim2.fromOffset(171, 122), UDim2.fromOffset(155, 26), Color3.fromRGB(38, 34, 60))
	local passBtn = makeButton(frame, "🎃 Пасс: ВКЛ", UDim2.fromOffset(10, 154), UDim2.fromOffset(155, 26), Color3.fromRGB(58, 40, 22))
	local claimBtn = makeButton(frame, "🎁 Забрать", UDim2.fromOffset(171, 154), UDim2.fromOffset(155, 26), Color3.fromRGB(30, 52, 40))
	local hopBtn = makeButton(frame, "↻ Хоп", UDim2.fromOffset(10, 186), UDim2.fromOffset(99, 26))
	local hideBtn = makeButton(frame, "HUD", UDim2.fromOffset(118, 186), UDim2.fromOffset(99, 26))
	local stopBtn = makeButton(frame, "Стоп", UDim2.fromOffset(226, 186), UDim2.fromOffset(99, 26), DANGER)
	local dragging, dragStart, startPos = false, nil, nil
	track(frame.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging, dragStart, startPos = true, input.Position, frame.Position
		end
	end))
	track(UIS.InputChanged:Connect(function(input)
		if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
			local delta = input.Position - dragStart
			frame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
		end
	end))
	track(UIS.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end))
	track(farmBtn.MouseButton1Click:Connect(function()
		cfg.farm = not cfg.farm
		saveConfig()
		log(cfg.farm and "фарм включён" or "фарм на паузе")
	end))
	track(modeBtn.MouseButton1Click:Connect(function()
		cycleMode()
	end))
	track(hopBtn.MouseButton1Click:Connect(function() hop() end))
	track(passBtn.MouseButton1Click:Connect(function()
		cfg.autoBuyPass = not cfg.autoBuyPass
		saveConfig()
		log(cfg.autoBuyPass and "авто-покупка пасса включена" or "авто-покупка пасса выключена")
	end))
	track(claimBtn.MouseButton1Click:Connect(function()
		cfg.autoClaimPass = true
		saveConfig()
		task.spawn(function() pcall(passTick) end)
		log("пасс: ручной сбор наград (тир %d)", tonumber(state.passTier) or 0)
	end))
	track(hideBtn.MouseButton1Click:Connect(function()
		cfg.hud = false
		gui.Enabled = false
		saveConfig()
	end))
	track(stopBtn.MouseButton1Click:Connect(function()
		state.running = false
		disconnectAll()
		gui:Destroy()
		state.ui = nil
		log("остановлен (кнопка) | пикапов: %d", state.pickups)
	end))
	state.ui = { gui = gui, frame = frame, info = info, farmBtn = farmBtn, modeBtn = modeBtn, passBtn = passBtn }
end
task.spawn(function()
	if cfg.hud then buildGui() end
	while alive() do
		if cfg.farm then
			if not humanoidRoot() then
				state.status = "ожидание"
			elseif state.inRound then
				state.status = "фарм"
			else
				state.status = "ждём раунд"
			end
		end
		local ui = state.ui
		if ui then
			local dot, color
			if not cfg.farm then dot, color = "пауза", "#ffb347"
			elseif state.status == "фарм" then dot, color = "фарм", "#57ff8a"
			elseif state.status == "ждём раунд" then dot, color = "ждём раунд", "#ffd166"
			else dot, color = state.status, "#9aa0a6" end
			local elapsed = math.max(os.clock() - state.startedAt, 1)
			local perHour = state.pickups / elapsed * 3600
			if os.clock() - (state.lastPassUiRead or 0) > 2 then
				state.lastPassUiRead = os.clock()
				pcall(readPassUi)
			end
			local passCost = tonumber(state.passCost) or 0
			local candies = candiesOf(0)
			state.passAffordable = (passCost > 0) and math.floor(candies / passCost) or 0
			local claimedCount = 0
			for _ in pairs(state.passClaimed or {}) do claimedCount += 1 end
			ui.info.Text = table.concat({
				'<font color="' .. color .. '">● ' .. dot .. '</font>   карта <b>' .. state.map .. '</b>   ' .. state.roundTime,
				'Собрано: <b>' .. num(state.pickups) .. '</b>   ' .. num(perHour) .. '/ч   сверка ' .. num(state.balanceDelta),
				'Монет на карте: ' .. state.coinsOnMap .. '   сервер: ' .. state.players,
				'Пасс: <b>' .. tostring(state.passTier) .. '/' .. tostring(state.passMax) .. '</b>   тир ' .. num(passCost)
					.. '   хватает на ' .. tostring(state.passAffordable)
					.. '   награды ' .. claimedCount .. '/' .. tostring(state.passTier),
				'Аккаунт: ' .. (function()
					local t = {}
					for k, v in pairs(state.account) do t[#t + 1] = k .. " " .. num(v) end
					table.sort(t)
					return #t > 0 and table.concat(t, "  ") or "—"
				end)(),
				(state.errorText ~= "" and ('<font color="#ff6b6b">ошибка: ' .. state.errorText:sub(1, 90) .. '</font>') or ('хопов: ' .. state.hops .. '   lvl ' .. tostring(state.level) .. '   попапов закрыто: ' .. state.popupClosed .. '   afk ' .. state.afkPulses)),
			}, "\n")
			ui.farmBtn.Text = cfg.farm and "⏸ Пауза" or "▶ Старт"
			ui.modeBtn.Text = "Режим: " .. (MODE_TITLE[cfg.mode] or string.upper(tostring(cfg.mode)))
			ui.passBtn.Text = cfg.autoBuyPass and "🎃 Пасс: ВКЛ" or "🎃 Пасс: ВЫКЛ"
		end
		task.wait(0.25)
	end
end)
-- 10. клавиши и остановка
track(UIS.InputBegan:Connect(function(input, processed)
	if processed then return end
	if input.KeyCode == Enum.KeyCode.RightShift then
		cfg.farm = not cfg.farm
		saveConfig()
		log(cfg.farm and "фарм включён" or "фарм на паузе")
	elseif input.KeyCode == Enum.KeyCode.RightControl then
		cfg.hud = not cfg.hud
		if state.ui then state.ui.gui.Enabled = cfg.hud end
		saveConfig()
	elseif input.KeyCode == Enum.KeyCode.RightAlt then
		cycleMode()
	end
end))
local function stop(reason)
	if not state.running then return end
	state.running = false
	disconnectAll()
	pcall(function() setNoClip(false, humanoidRoot()) end)
	if state.ui then pcall(function() state.ui.gui:Destroy() end) end
	state.ui = nil
	log("остановлен (%s) | пикапов: %d | по балансу: %d | пасс %d/%d, куплено %d, наград %d",
		tostring(reason or "manual"), state.pickups, state.balanceDelta,
		state.passTier, state.passMax, state.passBuys, state.passClaims)
end
_G.MM2FarmStop = function() stop("manual") end
_G.__MM2Farm = { version = VERSION, generation = GENERATION, state = state, cfg = cfg, stop = stop }
log("v%s | старый экземпляр снят | карта %s | игроков %d", VERSION, state.map, #Players:GetPlayers())
task.spawn(function()
	task.wait(2)
	refreshProfile()
	log("профиль: lvl %s", tostring(state.level))
end)
