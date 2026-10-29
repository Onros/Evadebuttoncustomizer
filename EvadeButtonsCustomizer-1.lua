--[[
	Jump Button Customizer (LocalScript / Executor)

	HOW TO USE
	- Open the ⚙️ panel -> turn Drag Mode ON -> drag the jump button anywhere (blue ring shows).
	- Turn Drag Mode OFF (or close the panel) to jump normally. Position is saved on release.
	- ⚙️ button (top-left) opens the panel: size slider + reset.

	PANEL: drag it by its title bar. The lock/unlock button next to the gear toggles Drag Mode.
	REVIVE / CARRY: while Drag Mode is ON they are shown even with no downed player nearby, so you can
	         place them. Turn Drag Mode OFF and they hide again, then appear in their new spot when needed.
	PRESETS: list Slide / Revive / Carry etc. in the PRESETS table below and they are draggable
	         right away, without picking them.

	WHY THE RESPAWN BUG IS GONE
	- The ORIGINAL JumpButton is never moved or resized anymore.
	  (The game's other mobile buttons are laid out relative to it, which is why they
	  "rose" with it after respawn.)
	- We hide the original (transparent) and draw our own copy in a separate ScreenGui.
	  The copy jumps the character itself, so everything else in the game stays put.

	SAVING
	- Saved to a file via writefile/readfile if your executor supports them.
	  Otherwise settings last until you leave the game.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- CONFIG
local HOLD_TIME = 0.45                          -- seconds to hold before drag mode starts
local MOVE_TOLERANCE = 14                       -- px the finger may drift while holding
local SAVE_FILE = "JumpButtonSettings.json"

-- BUILT-IN BUTTONS: draggable without picking them.
-- Use { path = "A/B/C" } (path under PlayerGui, from ButtonScanner) or { name = "SlideButton" }
-- (first button with that exact Name anywhere under PlayerGui). Buttons that appear only
-- sometimes (Revive / Carry) are picked up automatically as soon as they exist.
local PRESETS = {
	{ path = "Game/HUD/Mobile/Right/Mobile/CrouchButton" },  -- Crouch / Slide
	{ path = "Game/HUD/Mobile/Right/Mobile/EmoteButton" },   -- Emote
	{ path = "Game/HUD/Mobile/Right/Mobile/UsableButton" },  -- Inventory / Usable
	{ path = "Game/HUD/Mobile/Center/Interact/Interact/HealIcon", force = true },   -- Revive (only near a downed player)
	{ path = "Game/HUD/Mobile/Center/Interact/Interact/CarryIcon", force = true },  -- Carry (only near a downed player)
}
local OPEN_BTN_POS = UDim2.new(0, 15, 0, 80)    -- ⚙️ button position (change here)

-- Buttons the game shows only near a downed player (force = true in PRESETS) are shown
-- anyway while Drag Mode is ON, so you can place them. Turn Drag Mode OFF and the game
-- controls them again: they appear at their new spot whenever a downed player is near.
local forcePaths = {}
for _, p in ipairs(PRESETS) do
	if p.force and p.path then forcePaths[p.path] = true end
end

-- THEME
local COLOR_BG = Color3.fromRGB(18, 18, 22)
local COLOR_PANEL = Color3.fromRGB(30, 30, 36)
local COLOR_ACCENT = Color3.fromRGB(110, 20, 30)
local COLOR_HIGHLIGHT = Color3.fromRGB(90, 170, 255)
local COLOR_TEXT_DIM = Color3.fromRGB(150, 150, 160)

----------------------------------------------------------------------
-- STATE / CLEANUP (safe to execute the script more than once)
----------------------------------------------------------------------
local orig, origTransparency, clone, ring, sink
local dragEnabled, onDragModeChanged = false, nil
local refreshBound, setActive, onMenuClosed, applyPresets
local panelBusy = false -- true while the panel itself is being dragged
local removedPresets = {}
local activeKey = "jump" -- which button the size slider edits
local cleanupFns = {}
local connections, guis = {}, {}

local function connect(signal, fn)
	local c = signal:Connect(fn)
	table.insert(connections, c)
	return c
end

if _G.JumpCustomizerCleanup then
	pcall(_G.JumpCustomizerCleanup)
end

_G.JumpCustomizerCleanup = function()
	for _, f in ipairs(cleanupFns) do pcall(f) end
	for _, c in ipairs(connections) do
		pcall(function() c:Disconnect() end)
	end
	table.clear(connections)
	for _, g in ipairs(guis) do
		pcall(function() g:Destroy() end)
	end
	table.clear(guis)
	if orig and origTransparency then
		pcall(function() orig.ImageTransparency = origTransparency end)
	end
end

----------------------------------------------------------------------
-- SETTINGS (x / y = button CENTER as a fraction of the screen; nil = default spot)
----------------------------------------------------------------------
local settings = { size = 100, opacity = 100, x = nil, y = nil, buttons = {} }

local loadedFromFile = false
local function loadSettings()
	local ok, data = pcall(function()
		if isfile and readfile and isfile(SAVE_FILE) then
			return HttpService:JSONDecode(readfile(SAVE_FILE))
		end
	end)
	if ok and type(data) == "table" then
		loadedFromFile = true
		settings.size = math.clamp(tonumber(data.size) or 100, 50, 200)
		settings.opacity = math.clamp(tonumber(data.opacity) or 100, 10, 100)
		settings.x = tonumber(data.x)
		settings.y = tonumber(data.y)
		if type(data.buttons) == "table" then
			for path, e in pairs(data.buttons) do
				if type(path) == "string" and type(e) == "table" then
					settings.buttons[path] = {
						dx = tonumber(e.dx) or 0,
						dy = tonumber(e.dy) or 0,
						scale = math.clamp(tonumber(e.scale) or 100, 50, 200),
						opacity = math.clamp(tonumber(e.opacity) or 100, 10, 100),
					}
				end
			end
		end
	end
end

local saveQueued = false
local function saveSettings()
	if saveQueued then return end
	saveQueued = true
	task.delay(0.4, function()
		saveQueued = false
		pcall(function()
			if writefile then
				writefile(SAVE_FILE, HttpService:JSONEncode(settings))
			end
		end)
	end)
end

loadSettings()

----------------------------------------------------------------------
-- HELPERS
----------------------------------------------------------------------
local function playClick()
	pcall(function()
		local s = Instance.new("Sound")
		s.SoundId = "rbxassetid://87437544236708"
		s.Volume = 0.22
		s.Parent = SoundService
		s:Play()
		Debris:AddItem(s, 1)
	end)
end

local function isPointer(input)
	return input.UserInputType == Enum.UserInputType.Touch
		or input.UserInputType == Enum.UserInputType.MouseButton1
end

local function pos2(input)
	return Vector2.new(input.Position.X, input.Position.Y)
end

-- same finger / same mouse button?
local function sameInput(a, b)
	if a == b then return true end
	return a.UserInputType == Enum.UserInputType.MouseButton1
		and b.UserInputType == Enum.UserInputType.MouseButton1
end

----------------------------------------------------------------------
-- SETTINGS PANEL
----------------------------------------------------------------------
local panelGui = Instance.new("ScreenGui")
panelGui.Name = "JumpSettingsGui"
panelGui.ResetOnSpawn = false
panelGui.IgnoreGuiInset = true
panelGui.DisplayOrder = 1000
panelGui.Parent = playerGui
table.insert(guis, panelGui)

local PANEL_W, PANEL_H = 300, 336

local Frame = Instance.new("Frame")
Frame.Size = UDim2.new(0, PANEL_W, 0, PANEL_H)
Frame.Position = UDim2.new(0.5, -PANEL_W / 2, 1, 340) -- hidden
Frame.BackgroundColor3 = COLOR_PANEL
Frame.Active = true
Frame.BorderSizePixel = 0
Frame.Parent = panelGui
Instance.new("UICorner", Frame).CornerRadius = UDim.new(0, 12)
local frameStroke = Instance.new("UIStroke", Frame)
frameStroke.Color = Color3.fromRGB(40, 40, 46)
frameStroke.Thickness = 1
frameStroke.Transparency = 0.35

local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1, 0, 0, 48)
TitleBar.BackgroundColor3 = COLOR_BG
TitleBar.Active = true
TitleBar.BorderSizePixel = 0
TitleBar.Parent = Frame
Instance.new("UICorner", TitleBar).CornerRadius = UDim.new(0, 10)

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Size = UDim2.new(1, -80, 1, 0)
TitleLabel.Position = UDim2.new(0, 16, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.Text = "Button Layout"
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextSize = 15
TitleLabel.TextColor3 = Color3.new(1, 1, 1)
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Text = TitleLabel.Text .. "  ✥"
TitleLabel.Parent = TitleBar

local CloseBtn = Instance.new("TextButton")
CloseBtn.Size = UDim2.new(0, 36, 0, 28)
CloseBtn.Position = UDim2.new(1, -54, 0.5, -14)
CloseBtn.BackgroundColor3 = COLOR_ACCENT
CloseBtn.BorderSizePixel = 0
CloseBtn.Text = "❌"
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 16
CloseBtn.TextColor3 = Color3.new(1, 1, 1)
CloseBtn.Parent = TitleBar
Instance.new("UICorner", CloseBtn).CornerRadius = UDim.new(1, 0)

local Content = Instance.new("Frame")
Content.Size = UDim2.new(1, -28, 1, -64)
Content.Position = UDim2.new(0, 14, 0, 58)
Content.BackgroundTransparency = 1
Content.Parent = Frame

-- friendly names for the selected button
local NICE_NAMES = {
	jump = "Jump", CrouchButton = "Slide", EmoteButton = "Emote", UsableButton = "Inventory",
	HealIcon = "Revive", CarryIcon = "Carry",
}
local function niceName(key)
	if key == "jump" then return NICE_NAMES.jump end
	local last = string.match(key, "[^/]+$") or key
	return NICE_NAMES[last] or last
end

-- credit footer: shimmering line + colour-wave name. Tap it to copy the discord name.
local CREDIT_BY, CREDIT_NAME, CREDIT_DISCORD = "made by", "hasson", "illxyz"

local creditFrame = Instance.new("Frame")
creditFrame.Size = UDim2.new(1, -28, 0, 30)
creditFrame.Position = UDim2.new(0, 14, 1, -38)
creditFrame.BackgroundTransparency = 1
creditFrame.ZIndex = 5
creditFrame.Parent = Frame

local creditLine = Instance.new("Frame")
creditLine.Size = UDim2.new(1, 0, 0, 1)
creditLine.BackgroundColor3 = Color3.new(1, 1, 1)
creditLine.BorderSizePixel = 0
creditLine.ZIndex = 5
creditLine.Parent = creditFrame
local lineGrad = Instance.new("UIGradient")
lineGrad.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, COLOR_ACCENT),
	ColorSequenceKeypoint.new(0.5, COLOR_HIGHLIGHT),
	ColorSequenceKeypoint.new(1, COLOR_ACCENT),
})
lineGrad.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(1, 1),
})
lineGrad.Offset = Vector2.new(-0.6, 0)
lineGrad.Parent = creditLine
pcall(function()
	TweenService:Create(lineGrad, TweenInfo.new(2.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ Offset = Vector2.new(0.6, 0) }):Play()
end)

local creditText = Instance.new("TextLabel")
creditText.Size = UDim2.new(1, 0, 1, -4)
creditText.Position = UDim2.new(0, 0, 0, 4)
creditText.BackgroundTransparency = 1
creditText.RichText = true
creditText.Font = Enum.Font.GothamMedium
creditText.TextSize = 12
creditText.TextColor3 = Color3.new(1, 1, 1)
creditText.ZIndex = 5
creditText.Parent = creditFrame

-- a soft light wave sweeping across the text
local textGrad = Instance.new("UIGradient")
textGrad.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.35, 0),
	NumberSequenceKeypoint.new(0.5, 0.65),
	NumberSequenceKeypoint.new(0.65, 0),
	NumberSequenceKeypoint.new(1, 0),
})
textGrad.Offset = Vector2.new(-1, 0)
textGrad.Parent = creditText
pcall(function()
	TweenService:Create(textGrad, TweenInfo.new(2.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, false, 1.4),
		{ Offset = Vector2.new(1, 0) }):Play()
end)

-- the name's letters flow through blue / violet / pink
local function creditRich(t)
	local name = {}
	for i = 1, #CREDIT_NAME do
		local c = Color3.fromHSV(0.66 + 0.13 * math.sin(t * 2.2 + i * 0.75), 0.5, 1)
		name[#name + 1] = string.format('<font color="rgb(%d,%d,%d)">%s</font>',
			math.floor(c.R * 255), math.floor(c.G * 255), math.floor(c.B * 255), CREDIT_NAME:sub(i, i))
	end
	return '<font color="rgb(150,150,160)">' .. CREDIT_BY .. '</font> <b>' .. table.concat(name) .. '</b>'
		.. '  <font color="rgb(90,90,100)">·</font>  <font color="rgb(90,170,255)">discord @' .. CREDIT_DISCORD .. '</font>'
end
creditText.Text = creditRich(0)

local creditTap = Instance.new("TextButton")
creditTap.Size = UDim2.new(1, 0, 1, 0)
creditTap.BackgroundTransparency = 1
creditTap.Text = ""
creditTap.ZIndex = 7
creditTap.Parent = creditFrame

-- toast (small message at the top of the screen)
local toast = Instance.new("TextLabel")
toast.Size = UDim2.new(0, 260, 0, 34)
toast.Position = UDim2.new(0.5, -130, 0, 24)
toast.BackgroundColor3 = COLOR_BG
toast.BackgroundTransparency = 0.1
toast.TextColor3 = Color3.new(1, 1, 1)
toast.Font = Enum.Font.GothamBold
toast.TextSize = 13
toast.Visible = false
toast.Parent = panelGui
Instance.new("UICorner", toast).CornerRadius = UDim.new(0, 10)

local toastToken = 0
local function showToast(text, duration)
	toastToken += 1
	local mine = toastToken
	toast.Text = text
	toast.Visible = true
	task.delay(duration or 1.6, function()
		if toastToken == mine then toast.Visible = false end
	end)
end

-- slider
local function createSlider(parent, labelText, desc, yPos, minV, maxV, initial, onChange)
	local container = Instance.new("Frame")
	container.Size = UDim2.new(1, 0, 0, 56)
	container.Position = UDim2.new(0, 0, 0, yPos)
	container.BackgroundTransparency = 1
	container.Parent = parent

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, -64, 0, 18)
	label.BackgroundTransparency = 1
	label.Text = labelText
	label.Font = Enum.Font.GothamBold
	label.TextSize = 13
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Parent = container

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Size = UDim2.new(0, 56, 0, 18)
	valueLabel.Position = UDim2.new(1, -56, 0, 0)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Font = Enum.Font.GothamBold
	valueLabel.TextSize = 13
	valueLabel.TextColor3 = COLOR_HIGHLIGHT
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.Parent = container

	local descLabel = Instance.new("TextLabel")
	descLabel.Size = UDim2.new(1, 0, 0, 14)
	descLabel.Position = UDim2.new(0, 0, 0, 18)
	descLabel.BackgroundTransparency = 1
	descLabel.Text = desc
	descLabel.Font = Enum.Font.Gotham
	descLabel.TextSize = 10
	descLabel.TextColor3 = COLOR_TEXT_DIM
	descLabel.TextXAlignment = Enum.TextXAlignment.Left
	descLabel.Parent = container

	local track = Instance.new("Frame")
	track.Size = UDim2.new(1, 0, 0, 8)
	track.Position = UDim2.new(0, 0, 0, 38)
	track.BackgroundColor3 = Color3.fromRGB(42, 42, 50)
	track.BorderSizePixel = 0
	track.Parent = container
	Instance.new("UICorner", track).CornerRadius = UDim.new(1, 0)

	local fill = Instance.new("Frame")
	fill.BackgroundColor3 = COLOR_HIGHLIGHT
	fill.BorderSizePixel = 0
	fill.Parent = track
	Instance.new("UICorner", fill).CornerRadius = UDim.new(1, 0)

	local thumb = Instance.new("Frame")
	thumb.Size = UDim2.new(0, 20, 0, 20)
	thumb.BackgroundColor3 = Color3.fromRGB(245, 245, 245)
	thumb.BorderSizePixel = 0
	thumb.Parent = track
	Instance.new("UICorner", thumb).CornerRadius = UDim.new(1, 0)
	local tStroke = Instance.new("UIStroke", thumb)
	tStroke.Color = COLOR_HIGHLIGHT
	tStroke.Thickness = 3

	local hit = Instance.new("TextButton")
	hit.Size = UDim2.new(1, 24, 1, 24)
	hit.Position = UDim2.new(0, -12, 0, -12)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.Parent = track

	local value = initial
	local function setValue(v, silent)
		value = math.clamp(math.floor(v + 0.5), minV, maxV)
		local r = (value - minV) / (maxV - minV)
		fill.Size = UDim2.new(r, 0, 1, 0)
		thumb.Position = UDim2.new(r, -10, 0.5, -10)
		valueLabel.Text = tostring(value)
		if not silent and onChange then onChange(value) end
	end
	setValue(initial, true)

	local active
	local enabled = true
	local function updateFromX(x)
		local r = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
		setValue(minV + r * (maxV - minV))
	end

	connect(hit.InputBegan, function(input)
		if enabled and not panelBusy and isPointer(input) then
			active = input
			updateFromX(input.Position.X)
		end
	end)
	connect(UserInputService.InputChanged, function(input)
		if not active or panelBusy then return end
		if input == active or (active.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseMovement) then
			updateFromX(input.Position.X)
		end
	end)
	connect(UserInputService.InputEnded, function(input)
		if active and sameInput(input, active) then active = nil end
	end)

	local function setEnabled(on)
		enabled = on
		if not on then active = nil end
		local col = on and COLOR_HIGHLIGHT or Color3.fromRGB(95, 95, 105)
		fill.BackgroundColor3 = col
		tStroke.Color = col
		valueLabel.TextColor3 = col
		thumb.BackgroundColor3 = on and Color3.fromRGB(245, 245, 245) or Color3.fromRGB(150, 150, 155)
		descLabel.Text = on and desc or "Locked: turn Drag Mode ON to resize"
	end

	return {
		SetValue = setValue,
		Label = label,
		SetEnabled = setEnabled,
		Cancel = function() active = nil end,
	}
end

local selLabel = Instance.new("TextLabel")
selLabel.Size = UDim2.new(1, 0, 0, 18)
selLabel.BackgroundTransparency = 1
selLabel.Font = Enum.Font.GothamBold
selLabel.TextSize = 13
selLabel.TextColor3 = COLOR_HIGHLIGHT
selLabel.TextXAlignment = Enum.TextXAlignment.Left
selLabel.Text = "Selected: Jump"
selLabel.Parent = Content

local sizeSlider = createSlider(Content, "Size", "100 = default size", 26, 50, 200, settings.size, function(v)
	if activeKey == "jump" then
		settings.size = v
	elseif settings.buttons[activeKey] then
		settings.buttons[activeKey].scale = v
	end
	saveSettings()
end)
sizeSlider.Label.Text = "Size"

local opacitySlider = createSlider(Content, "Opacity", "100 = fully visible", 88, 10, 100, settings.opacity, function(v)
	if activeKey == "jump" then
		settings.opacity = v
	elseif settings.buttons[activeKey] then
		settings.buttons[activeKey].opacity = v
	end
	saveSettings()
end)


local ResetBtn = Instance.new("TextButton")
ResetBtn.Size = UDim2.new(0.5, -4, 0, 36)
ResetBtn.Position = UDim2.new(0.5, 4, 0, 196)
ResetBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 46)
ResetBtn.BorderSizePixel = 0
ResetBtn.Font = Enum.Font.GothamBold
ResetBtn.Text = "Reset all"
ResetBtn.TextSize = 14
ResetBtn.TextColor3 = Color3.new(1, 1, 1)
ResetBtn.Parent = Content
Instance.new("UICorner", ResetBtn).CornerRadius = UDim.new(0, 8)

local ResetOneBtn = Instance.new("TextButton")
ResetOneBtn.Size = UDim2.new(0.5, -4, 0, 36)
ResetOneBtn.Position = UDim2.new(0, 0, 0, 196)
ResetOneBtn.BackgroundColor3 = Color3.fromRGB(40, 40, 46)
ResetOneBtn.BorderSizePixel = 0
ResetOneBtn.Font = Enum.Font.GothamBold
ResetOneBtn.Text = "Reset selected"
ResetOneBtn.TextSize = 14
ResetOneBtn.TextColor3 = Color3.new(1, 1, 1)
ResetOneBtn.Parent = Content
Instance.new("UICorner", ResetOneBtn).CornerRadius = UDim.new(0, 8)

local DragBtn = Instance.new("TextButton")
DragBtn.Size = UDim2.new(1, 0, 0, 38)
DragBtn.Position = UDim2.new(0, 0, 0, 150)
DragBtn.BorderSizePixel = 0
DragBtn.Font = Enum.Font.GothamBold
DragBtn.TextSize = 14
DragBtn.TextColor3 = Color3.new(1, 1, 1)
DragBtn.AutoButtonColor = false
DragBtn.Parent = Content
Instance.new("UICorner", DragBtn).CornerRadius = UDim.new(0, 8)

-- quick on-screen lock/unlock button (next to the gear)
local MoveBtn = Instance.new("TextButton")
MoveBtn.Size = UDim2.new(0, 44, 0, 44)
MoveBtn.Position = OPEN_BTN_POS + UDim2.fromOffset(54, 0)
MoveBtn.BorderSizePixel = 0
MoveBtn.TextSize = 22
MoveBtn.Font = Enum.Font.GothamBold
MoveBtn.TextColor3 = Color3.new(1, 1, 1)
MoveBtn.AutoButtonColor = false
MoveBtn.Parent = panelGui
Instance.new("UICorner", MoveBtn).CornerRadius = UDim.new(1, 0)

local function setDragMode(on)
	dragEnabled = on
	sizeSlider.SetEnabled(on)
	opacitySlider.SetEnabled(on)
	MoveBtn.Text = on and "🔓" or "🔒"
	MoveBtn.BackgroundColor3 = on and Color3.fromRGB(40, 110, 70) or Color3.fromRGB(38, 38, 44)
	DragBtn.Text = on and "🔓 Drag Mode: ON" or "🔒 Drag Mode: OFF"
	DragBtn.BackgroundColor3 = on and Color3.fromRGB(40, 110, 70) or Color3.fromRGB(40, 40, 46)
	if onDragModeChanged then onDragModeChanged() end
end
setDragMode(false)
local function toggleDrag()
	playClick()
	setDragMode(not dragEnabled)
	if dragEnabled then
		showToast("Drag Mode ON · Revive & Carry shown", 2)
	else
		showToast("Locked ✓", 1)
	end
end
connect(DragBtn.MouseButton1Click, toggleDrag)
connect(MoveBtn.MouseButton1Click, toggleDrag)

local function addHover(btn, normal, hover)
	connect(btn.MouseEnter, function()
		TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = hover }):Play()
	end)
	connect(btn.MouseLeave, function()
		TweenService:Create(btn, TweenInfo.new(0.12), { BackgroundColor3 = normal }):Play()
	end)
end

local OpenBtn = Instance.new("TextButton")
OpenBtn.Size = UDim2.new(0, 44, 0, 44)
OpenBtn.Position = OPEN_BTN_POS
OpenBtn.BackgroundColor3 = Color3.fromRGB(38, 38, 44)
OpenBtn.BorderSizePixel = 0
OpenBtn.Text = "⚙️"
OpenBtn.TextSize = 22
OpenBtn.Font = Enum.Font.GothamBold
OpenBtn.TextColor3 = Color3.new(1, 1, 1)
OpenBtn.AutoButtonColor = false
OpenBtn.Parent = panelGui
Instance.new("UICorner", OpenBtn).CornerRadius = UDim.new(1, 0)

addHover(ResetBtn, ResetBtn.BackgroundColor3, Color3.fromRGB(55, 55, 60))
addHover(ResetOneBtn, ResetOneBtn.BackgroundColor3, Color3.fromRGB(55, 55, 60))
addHover(CloseBtn, COLOR_ACCENT, Color3.fromRGB(170, 40, 60))
addHover(OpenBtn, OpenBtn.BackgroundColor3, Color3.fromRGB(55, 55, 60))

local menuOpen = false
local menuTween
local panelOpenPos = UDim2.new(0.5, -PANEL_W / 2, 0.5, -PANEL_H / 2)
local function toggleMenu(show)
	if show == nil then menuOpen = not menuOpen else menuOpen = show end
	if not menuOpen and onMenuClosed then onMenuClosed() end
	playClick()
	local target = menuOpen
		and panelOpenPos
		or UDim2.new(0.5, -PANEL_W / 2, 1, 340)
	if menuTween then menuTween:Cancel() end
	menuTween = TweenService:Create(Frame, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = target })
	menuTween:Play()
end

connect(OpenBtn.MouseButton1Click, function() toggleMenu() end)
connect(CloseBtn.MouseButton1Click, function() toggleMenu(false) end)

-- animate the credit while the panel is open; tap it to copy the discord name
local creditAcc = 0
connect(RunService.Heartbeat, function(dt)
	if not menuOpen then return end
	creditAcc += dt
	if creditAcc < 0.07 then return end
	creditAcc = 0
	creditText.Text = creditRich(os.clock())
end)
connect(creditTap.MouseButton1Click, function()
	playClick()
	if setclipboard then
		pcall(setclipboard, CREDIT_DISCORD)
		showToast("Discord copied: " .. CREDIT_DISCORD, 1.6)
	else
		showToast("Discord: " .. CREDIT_DISCORD, 2)
	end
end)

-- drag the panel by its title bar: starts only after ~10px of finger movement (a tap never moves it),
-- then the panel stays locked to the finger. While it moves, the slider is ignored.
local panelDrag, panelStart, panelInput0, panelMoving
connect(TitleBar.InputBegan, function(input)
	if not isPointer(input) or panelDrag then return end
	local p = pos2(input)
	local cp, cs = CloseBtn.AbsolutePosition, CloseBtn.AbsoluteSize
	if p.X >= cp.X - 8 and p.X <= cp.X + cs.X + 8 and p.Y >= cp.Y - 8 and p.Y <= cp.Y + cs.Y + 8 then
		return -- that's the close button
	end
	sizeSlider.Cancel() -- a touch on the title can never be a slider touch
	opacitySlider.Cancel()
	panelDrag = input
	panelInput0 = p
	panelMoving = false
end)
connect(UserInputService.InputChanged, function(input)
	if not panelDrag then return end
	local same = input == panelDrag
		or (panelDrag.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseMovement)
	if not same then return end
	local p = pos2(input)
	if not panelMoving then
		if (p - panelInput0).Magnitude < 10 then return end
		panelMoving, panelBusy = true, true
		if menuTween then menuTween:Cancel() end
		panelStart = Frame.AbsolutePosition
		panelInput0 = p -- start from here, so the panel does not jump by the threshold
	end
	local gs = panelGui.AbsoluteSize
	local np = panelStart + (p - panelInput0)
	panelOpenPos = UDim2.fromOffset(
		math.clamp(np.X, 80 - PANEL_W, math.max(80 - PANEL_W, gs.X - 80)),
		math.clamp(np.Y, 0, math.max(0, gs.Y - 48))
	)
	Frame.Position = panelOpenPos
end)
connect(UserInputService.InputEnded, function(input)
	if panelDrag and sameInput(input, panelDrag) then
		panelDrag, panelMoving, panelBusy = nil, false, false
	end
end)

connect(ResetBtn.MouseButton1Click, function()
	playClick()
	settings.size = 100
	settings.opacity = 100
	settings.x = nil
	settings.y = nil
	table.clear(settings.buttons)
	table.clear(removedPresets)
	if applyPresets then applyPresets() end
	if refreshBound then refreshBound() end
	if setActive then setActive("jump") end
	saveSettings()
	showToast("Everything reset ✓", 1.2)
end)

connect(ResetOneBtn.MouseButton1Click, function()
	playClick()
	local key = activeKey
	if key == "jump" then
		settings.x, settings.y, settings.size, settings.opacity = nil, nil, 100, 100
	else
		local e = settings.buttons[key]
		if not e then return end
		e.dx, e.dy, e.scale, e.opacity = 0, 0, 100, 100
	end
	if setActive then setActive(key) end
	saveSettings()
	showToast("Reset: " .. niceName(key), 1.2)
end)

----------------------------------------------------------------------
-- CUSTOM JUMP BUTTON
----------------------------------------------------------------------
local jumpGui = Instance.new("ScreenGui")
jumpGui.Name = "CustomJumpGui"
jumpGui.ResetOnSpawn = false
jumpGui.DisplayOrder = 50
jumpGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
jumpGui.Parent = playerGui
table.insert(guis, jumpGui)

-- invisible blocker over the ORIGINAL button's spot (so the hidden original can't be tapped)
sink = Instance.new("TextButton")
sink.AnchorPoint = Vector2.new(0.5, 0.5)
sink.BackgroundTransparency = 1
sink.Text = ""
sink.AutoButtonColor = false
sink.Active = true
sink.Visible = false
sink.ZIndex = 4
sink.Parent = jumpGui

-- Our copy lives in the SAME ScreenGui as the original jump button (TouchGui), so it sits on the
-- same layer as the game's own buttons: anything the game draws above them (the radio...) is above it too.
local function jumpSpace()
	local par = clone and clone.Parent
	if par and par:IsA("ScreenGui") then return par end
	return jumpGui
end

table.insert(cleanupFns, function()
	if clone then pcall(function() clone:Destroy() end) end
	if sink then pcall(function() sink:Destroy() end) end
end)

local tracked, startPos, grab, dragCenter
local pressAnim = 1
local lastJumpVis
local dragging, cancelled, jumpHeld = false, false, false

local function findOriginal()
	local tg = playerGui:FindFirstChild("TouchGui")
	local ctrl = tg and tg:FindFirstChild("TouchControlFrame")
	return ctrl and ctrl:FindFirstChild("JumpButton", true)
end

local function effectiveVisible(obj)
	local cur = obj
	while cur and cur ~= playerGui do
		if cur:IsA("GuiObject") and not cur.Visible then return false end
		if cur:IsA("ScreenGui") and not cur.Enabled then return false end
		cur = cur.Parent
	end
	return cur == playerGui
end

local function getHumanoid()
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

-- Forward a press to the ORIGINAL button's own handlers, so the game's jump logic runs as usual.
local forwardedInput
local function fireConnections(signal, input)
	local fired = false
	if getconnections then
		local ok, conns = pcall(getconnections, signal)
		if ok and type(conns) == "table" then
			for _, c in ipairs(conns) do
				local okc = pcall(function() c:Fire(input, false) end)
				if not okc then okc = pcall(function() c.Function(input, false) end) end
				fired = fired or okc
			end
		end
	end
	if not fired and firesignal then
		fired = pcall(firesignal, signal, input, false)
	end
	return fired
end

local function resetPress()
	tracked, startPos, grab, dragCenter = nil, nil, nil, nil
	forwardedInput = nil
	dragging, cancelled, jumpHeld = false, false, false
	if clone then clone.ImageTransparency = origTransparency end
	if ring then ring.Visible = dragEnabled end
end

local function enterEdit()
	dragging = true
	jumpHeld = false
	local cur = Vector2.new(clone.Position.X.Offset, clone.Position.Y.Offset)
	grab = pos2(tracked) - cur
	dragCenter = cur
	ring.Visible = true
	clone.ImageTransparency = origTransparency
	if setActive then setActive("jump") end
	playClick()
	showToast("Drag to move, release to save", 1.5)
end

local function onBegan(input)
	if not isPointer(input) or tracked then return end
	tracked = input
	startPos = pos2(input)
	cancelled = false

	if dragEnabled then
		enterEdit() -- drag mode: touching the button moves it
		return
	end

	-- normal mode: act as the real jump button
	clone.ImageTransparency = math.max(0, origTransparency - 0.25)
	if orig and fireConnections(orig.InputBegan, input) then
		forwardedInput = input
	else
		jumpHeld = true -- fallback if the executor can't forward events
	end
end

local function finishPress()
	local wasDragging = dragging
	local center = dragCenter
	if forwardedInput and orig then
		fireConnections(orig.InputEnded, forwardedInput)
	end
	resetPress()
	if wasDragging and center then
		local gs = jumpSpace().AbsoluteSize
		settings.x = center.X / gs.X
		settings.y = center.Y / gs.Y
		saveSettings()
		showToast("Position saved ✓", 1.2)
	end
end

local function attach(btn)
	if clone then clone:Destroy() clone = nil end
	resetPress()

	-- the original may still carry OUR transparency of 1 (same object re-attached after a re-parent):
	-- never adopt 1 as the 'real' look, or the copy would stay invisible
	local t = btn.ImageTransparency
	if t >= 0.99 then
		t = (btn == orig and origTransparency and origTransparency < 0.99) and origTransparency or 0.5
	end
	orig = btn
	origTransparency = t

	-- use the same coordinate space as the original's ScreenGui
	local sg = btn:FindFirstAncestorOfClass("ScreenGui")
	if sg then jumpGui.IgnoreGuiInset = sg.IgnoreGuiInset end

	clone = btn:Clone()
	if not clone then
		clone = Instance.new("ImageButton")
		clone.BackgroundTransparency = 1
		clone.Image = btn.Image
		clone.ImageRectOffset = btn.ImageRectOffset
		clone.ImageRectSize = btn.ImageRectSize
		clone.ScaleType = btn.ScaleType
	end
	clone.Name = "CustomJumpButton"
	clone.AnchorPoint = Vector2.new(0.5, 0.5)
	clone.Active = true
	clone.Visible = true
	clone.ZIndex = 5
	clone.ImageTransparency = origTransparency

	ring = Instance.new("Frame")
	ring.BackgroundTransparency = 1
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.Size = UDim2.new(1, 12, 1, 12)
	ring.ZIndex = 6
	ring.Visible = dragEnabled
	Instance.new("UICorner", ring).CornerRadius = UDim.new(1, 0)
	local rs = Instance.new("UIStroke", ring)
	rs.Color = COLOR_HIGHLIGHT
	rs.Thickness = 3
	ring.Parent = clone

	local home = sg or jumpGui
	sink.Parent = home
	clone.Parent = home
	clone.InputBegan:Connect(onBegan)
end

onDragModeChanged = function()
	if ring then ring.Visible = dragEnabled end
end

-- finger / mouse movement
connect(UserInputService.InputChanged, function(input)
	if not tracked or not clone then return end
	local same = input == tracked
		or (tracked.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseMovement)
	if not same then return end

	local p = pos2(input)
	if dragging then
		local gs = jumpSpace().AbsoluteSize
		local half = clone.AbsoluteSize / 2
		local c = p - grab
		c = Vector2.new(
			math.clamp(c.X, half.X, math.max(half.X, gs.X - half.X)),
			math.clamp(c.Y, half.Y, math.max(half.Y, gs.Y - half.Y))
		)
		dragCenter = c
		clone.Position = UDim2.fromOffset(c.X, c.Y)
	elseif (p - startPos).Magnitude > MOVE_TOLERANCE then
		cancelled = true -- finger moved too early: not a long-press
	end
end)

connect(UserInputService.InputEnded, function(input)
	if tracked and sameInput(input, tracked) then
		finishPress()
	end
end)

-- main loop: keep our copy in sync, and hold-jump while pressed
connect(RunService.Heartbeat, function(dt)
	if not (orig and orig:IsDescendantOf(playerGui)) then
		local found = findOriginal()
		if found then
			attach(found)
		else
			if clone then clone.Visible = false end
			sink.Visible = false
			return
		end
	end

	-- keep the original invisible (it stays exactly where the game put it);
	-- if the game itself changes its transparency, remember that as the new look of our copy
	if not clone or not clone.Parent or not sink.Parent then
		attach(orig)
	end

	local gt = orig.ImageTransparency
	if gt ~= 1 then
		if gt < 0.99 then origTransparency = gt end
		orig.ImageTransparency = 1
	end
	if tracked and tracked.UserInputState ~= Enum.UserInputState.Begin
		and tracked.UserInputState ~= Enum.UserInputState.Change then
		finishPress() -- the finger is gone but we missed the release: never stay stuck
	end

	-- mirror the game's own art (pressed / unpressed sprite) onto our copy
	if clone.Image ~= orig.Image then clone.Image = orig.Image end
	if clone.ImageRectOffset ~= orig.ImageRectOffset then clone.ImageRectOffset = orig.ImageRectOffset end
	if clone.ImageRectSize ~= orig.ImageRectSize then clone.ImageRectSize = orig.ImageRectSize end
	if clone.ImageColor3 ~= orig.ImageColor3 then clone.ImageColor3 = orig.ImageColor3 end

	local base = orig.AbsoluteSize
	if base.X <= 0 or base.Y <= 0 then return end

	local vis = effectiveVisible(orig)
	clone.Visible = vis or dragging
	if lastJumpVis ~= vis then
		lastJumpVis = vis
		print("[JumpCustomizer] jump button " .. (vis and "shown" or "hidden by the game (original not visible)"))
	end
	if pressAnim ~= pressAnim then pressAnim = 1 end
	local tr = (tracked and not dragging) and math.max(0, origTransparency - 0.25) or origTransparency
	clone.ImageTransparency = 1 - (1 - tr) * (settings.opacity / 100)

	-- small shrink while pressed, so the tap is visible even if the game's sprite doesn't change
	local pressedNow = tracked ~= nil and not dragging
	pressAnim += ((pressedNow and 0.9 or 1) - pressAnim) * math.min(1, dt * 22)
	local scale = settings.size / 100 * pressAnim
	clone.Size = UDim2.fromOffset(base.X * scale, base.Y * scale)

	local center = orig.AbsolutePosition + base / 2
	local custom = settings.x ~= nil and settings.y ~= nil

	sink.Visible = vis and custom
	sink.Position = UDim2.fromOffset(center.X, center.Y)
	sink.Size = UDim2.fromOffset(base.X, base.Y)

	if not dragging then
		if custom then
			local gs = jumpSpace().AbsoluteSize
			clone.Position = UDim2.fromOffset(settings.x * gs.X, settings.y * gs.Y)
		else
			clone.Position = UDim2.fromOffset(center.X, center.Y)
		end
	end

	if jumpHeld then
		local hum = getHumanoid()
		if hum then hum.Jump = true end
	end
end)

----------------------------------------------------------------------
-- OTHER BUTTONS (Slide, Revive, Carry, ...): Pick -> Add -> Drag / Resize
-- The real game button is moved/resized directly (re-applied every frame), and an
-- invisible overlay catches your finger in Drag Mode so the button's action
-- (slide, revive...) is NOT triggered while you drag.
-- Only single buttons are accepted (never containers), so other buttons never move with it.
----------------------------------------------------------------------
local custom = settings.buttons
local bound = {}
local pickMode, pickTarget = false, nil
local pickRingUntil = 0 -- the yellow ring is only shown briefly after picking

local function mkOverlayGui(name, ignoreInset)
	local g = Instance.new("ScreenGui")
	g.Name = name
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = ignoreInset
	g.DisplayOrder = 60
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.Parent = playerGui
	table.insert(guis, g)
	return g
end
local overlayIgnore = mkOverlayGui("CustomButtonsOverlayA", true)
local overlayInset = mkOverlayGui("CustomButtonsOverlayB", false)

-- overlays must live in a ScreenGui with the same inset setting as the target
local function spaceGui(obj)
	local sg = obj:FindFirstAncestorOfClass("ScreenGui")
	if sg and sg.IgnoreGuiInset then return overlayIgnore end
	return overlayInset
end

local function isOurs(o)
	return o:IsDescendantOf(panelGui) or o:IsDescendantOf(jumpGui)
		or (clone ~= nil and (o == clone or o:IsDescendantOf(clone))) or o == sink
		or o:IsDescendantOf(overlayIgnore) or o:IsDescendantOf(overlayInset)
end

local function pathOf(obj)
	if not obj:IsDescendantOf(playerGui) or isOurs(obj) then return nil end
	local parts = {}
	local cur = obj
	while cur and cur ~= playerGui do
		table.insert(parts, 1, cur.Name)
		cur = cur.Parent
	end
	return table.concat(parts, "/")
end

local function resolve(path)
	local cur = playerGui
	for part in string.gmatch(path, "[^/]+") do
		cur = cur and cur:FindFirstChild(part)
		if not cur then return nil end
	end
	return cur
end

local function ancestorScale(obj)
	local sc = 1
	local cur = obj.Parent
	while cur and cur ~= playerGui do
		local us = cur:FindFirstChildOfClass("UIScale")
		if us then sc *= us.Scale end
		cur = cur.Parent
	end
	return math.max(sc, 0.01)
end

local LAYOUT_CLASSES = { "UIListLayout", "UIGridLayout", "UITableLayout", "UIPageLayout" }
local function isLayoutManaged(obj)
	local par = obj.Parent
	if not par then return false end
	for _, cls in ipairs(LAYOUT_CLASSES) do
		if par:FindFirstChildOfClass(cls) then return true end
	end
	return false
end

-- a valid target is ONE real button (not a frame, not a group, not something huge)
local function validTarget(obj)
	if not obj:IsA("GuiButton") then return false, "That's not a button" end
	for _, d in ipairs(obj:GetDescendants()) do
		if d:IsA("GuiButton") then return false, "That's a group of buttons" end
	end
	local cam = workspace.CurrentCamera
	if cam then
		local vp = cam.ViewportSize
		if obj.AbsoluteSize.X > vp.X * 0.4 and obj.AbsoluteSize.Y > vp.Y * 0.4 then
			return false, "Too big to be a button"
		end
	end
	return true
end

local function makeOverlay(path)
	local o = Instance.new("TextButton")
	o.BackgroundTransparency = 1
	o.Text = ""
	o.AutoButtonColor = false
	o.Active = true
	o.ZIndex = 10
	o.Visible = false
	local r = Instance.new("Frame")
	r.Size = UDim2.new(1, 0, 1, 0)
	r.BackgroundTransparency = 1
	r.ZIndex = 11
	local st = Instance.new("UIStroke", r)
	st.Color = COLOR_HIGHLIGHT
	st.Thickness = 3
	st.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	Instance.new("UICorner", r).CornerRadius = UDim.new(1, 0)
	r.Parent = o
	o.Parent = overlayIgnore
	o.InputBegan:Connect(function(input)
		if _G.__JumpCustomizerEntryBegan then _G.__JumpCustomizerEntryBegan(path, input) end
	end)
	return o
end

-- yellow frame around the button you just picked (only while the panel is open)
local pickRing = Instance.new("Frame")
pickRing.BackgroundTransparency = 1
pickRing.Visible = false
pickRing.ZIndex = 20
local pst = Instance.new("UIStroke", pickRing)
pst.Color = Color3.fromRGB(255, 210, 60)
pst.Thickness = 3
pst.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
Instance.new("UICorner", pickRing).CornerRadius = UDim.new(1, 0)
pickRing.Parent = overlayIgnore

local function opacityProps(d)
	if d:IsA("UIStroke") then return { "Transparency" } end
	if not d:IsA("GuiObject") then return nil end
	local list = { "BackgroundTransparency" }
	if d:IsA("ImageLabel") or d:IsA("ImageButton") then table.insert(list, "ImageTransparency") end
	if d:IsA("TextLabel") or d:IsA("TextButton") or d:IsA("TextBox") then table.insert(list, "TextTransparency") end
	return list
end

-- OPACITY ENGINE
-- The game always sees its OWN values. We only show the faded values while the frame is drawn:
--   PreRender (apply): read the game's real value -> draw a faded one
--   Stepped   (unfade): put the game's real value back
-- So the game never reads our faded numbers (that is what used to leave icons invisible
-- after raising opacity back to 100), and anything the game writes is picked up as the new real value.
local EPS = 0.0005

local function targetsOf(b)
	local now = os.clock()
	if not b.targets or now - (b.targetsAt or 0) > 0.25 then
		local list = { b.obj }
		for _, d in ipairs(b.obj:GetDescendants()) do list[#list + 1] = d end
		b.targets, b.targetsAt = list, now
	end
	return b.targets
end

-- put the game's real values back (only where we were the last one to write)
local function unfade(b)
	local cache = b.opCache
	if not cache then return end
	for inst, c in pairs(cache) do
		for prop, e in pairs(c) do
			if e.applied then
				e.applied = false
				pcall(function()
					if math.abs(inst[prop] - e.faded) < EPS then
						inst[prop] = e.base
					end
				end)
			end
		end
	end
end

local function applyOpacity(b, opacity)
	local f = opacity / 100
	if f >= 1 then
		unfade(b)
		b.opCache = nil
		return
	end
	local cache = b.opCache
	if not cache then
		cache = setmetatable({}, { __mode = "k" })
		b.opCache = cache
	end
	for _, inst in ipairs(targetsOf(b)) do
		local props = opacityProps(inst)
		if props then
			local c = cache[inst]
			if not c then
				c = {}
				cache[inst] = c
			end
			for _, prop in ipairs(props) do
				pcall(function()
					local cur = inst[prop]
					local e = c[prop]
					if not e then
						e = {}
						c[prop] = e
					end
					if not (e.applied and math.abs(cur - e.faded) < EPS) then
						e.base = cur -- the game's real value
					end
					local want = 1 - (1 - e.base) * f
					if math.abs(cur - want) > EPS then inst[prop] = want end
					e.faded = inst[prop]
					e.applied = true
				end)
			end
		end
	end
end

local function restoreOpacity(b)
	unfade(b)
	b.opCache = nil
	b.targets = nil
end

-- FORCE SHOW (Revive / Carry while Drag Mode is ON)
-- Makes the button and every parent visible. We remember what the GAME wanted (e.real) and
-- put that back as soon as Drag Mode is turned OFF, so the game is in control again.
local function forceShow(b)
	local rec = b.forced
	if not rec then
		rec = {}
		b.forced = rec
	end
	local cur = b.obj
	while cur and cur ~= playerGui do
		local prop
		if cur:IsA("GuiObject") then
			prop = "Visible"
		elseif cur:IsA("ScreenGui") then
			prop = "Enabled"
		end
		if prop then
			pcall(function()
				local v = cur[prop]
				local e = rec[cur]
				if not e then
					e = { prop = prop }
					rec[cur] = e
				end
				if v ~= e.set then e.real = v end -- first look, or the game wrote it itself
				if v ~= true then cur[prop] = true end
				e.set = true
			end)
		end
		cur = cur.Parent
	end
end

local function releaseForce(b)
	local rec = b.forced
	if not rec then return end
	b.forced = nil
	for inst, e in pairs(rec) do
		pcall(function()
			if e.set and e.real ~= nil and inst[e.prop] == true then inst[e.prop] = e.real end
		end)
	end
end

local function restoreBound(b)
	releaseForce(b)
	restoreOpacity(b)
	pcall(function()
		if b.obj.Parent then
			if b.baseSize then b.obj.Size = b.baseSize end
			if b.base then b.obj.Position = b.base end
		end
	end)
end

refreshBound = function()
	for path in pairs(custom) do
		local obj = resolve(path)
		local b = bound[path]
		if obj and obj:IsA("GuiObject") then
			if not b or b.obj ~= obj then
				if not validTarget(obj) then
					-- old/bad entry (e.g. a container saved earlier): drop it
					custom[path] = nil
					saveSettings()
				else
					if b and b.overlay then b.overlay:Destroy() end
					bound[path] = { obj = obj, overlay = makeOverlay(path) }
				end
			end
		end
	end
	for path, b in pairs(bound) do
		if not custom[path] then
			restoreBound(b)
			if b.overlay then b.overlay:Destroy() end
			bound[path] = nil
			if activeKey == path and setActive then setActive("jump") end
		end
	end
end

-- add the PRESETS buttons (found by path or by name) as draggable entries
applyPresets = function()
	for _, p in ipairs(PRESETS) do
		local found
		if p.path then
			found = resolve(p.path)
		elseif p.name then
			for _, d in ipairs(playerGui:GetDescendants()) do
				if d.Name == p.name and d:IsA("GuiButton") and not isOurs(d) then
					found = d
					break
				end
			end
		end
		if found and found:IsA("GuiButton") then
			local path = pathOf(found)
			if path and not custom[path] and not removedPresets[path]
				and validTarget(found) and not isLayoutManaged(found) then
				custom[path] = { dx = 0, dy = 0, scale = 100, opacity = 100 }
				saveSettings()
			end
		end
	end
end

local warned = false
local function stepEntries()
	local cam = workspace.CurrentCamera
	if not cam then return end
	local vp = cam.ViewportSize

	for path, e in pairs(custom) do
		local b = bound[path]
		if b and b.obj.Parent then
			local obj = b.obj
			if dragEnabled and forcePaths[path] then
				forceShow(b)
			elseif b.forced then
				releaseForce(b)
			end
			-- if the game itself changed position/size, adopt that as the new base
			if b.lastPos == nil or obj.Position ~= b.lastPos then b.base = obj.Position end
			if b.lastSize == nil or obj.Size ~= b.lastSize then b.baseSize = obj.Size end

			local sc = ancestorScale(obj)
			local s = (e.scale or 100) / 100
			local bs = b.baseSize
			local par = obj.Parent
			local pAbs = par:IsA("GuiBase2d") and par.AbsoluteSize or vp
			local S0x = bs.X.Scale * pAbs.X + bs.X.Offset * sc
			local S0y = bs.Y.Scale * pAbs.Y + bs.Y.Offset * sc
			local a = obj.AnchorPoint
			-- keep the button's CENTER fixed while resizing
			local cx = -(0.5 - a.X) * (s - 1) * S0x
			local cy = -(0.5 - a.Y) * (s - 1) * S0y
			local nx = math.floor((e.dx * vp.X + cx) / sc + 0.5)
			local ny = math.floor((e.dy * vp.Y + cy) / sc + 0.5)

			obj.Size = UDim2.new(
				bs.X.Scale * s, math.floor(bs.X.Offset * s + 0.5),
				bs.Y.Scale * s, math.floor(bs.Y.Offset * s + 0.5)
			)
			obj.Position = UDim2.new(
				b.base.X.Scale, b.base.X.Offset + nx,
				b.base.Y.Scale, b.base.Y.Offset + ny
			)
			b.lastPos = obj.Position
			b.lastSize = obj.Size

			if (e.opacity or 100) < 100 or b.opCache then
				applyOpacity(b, e.opacity or 100)
			end

			local ov = b.overlay
			local show = dragEnabled and (b.forced ~= nil or effectiveVisible(obj))
			ov.Visible = show
			if show then
				local g = spaceGui(obj)
				if ov.Parent ~= g then ov.Parent = g end
				ov.Position = UDim2.fromOffset(obj.AbsolutePosition.X, obj.AbsolutePosition.Y)
				ov.Size = UDim2.fromOffset(obj.AbsoluteSize.X > 0 and obj.AbsoluteSize.X or 56,
					obj.AbsoluteSize.Y > 0 and obj.AbsoluteSize.Y or 56)
				ov.Rotation = obj.AbsoluteRotation
			end
		end
	end

	if pickTarget and menuOpen and os.clock() < pickRingUntil and pickTarget:IsDescendantOf(playerGui) then
		local g = spaceGui(pickTarget)
		if pickRing.Parent ~= g then pickRing.Parent = g end
		pickRing.Position = UDim2.fromOffset(pickTarget.AbsolutePosition.X, pickTarget.AbsolutePosition.Y)
		pickRing.Size = UDim2.fromOffset(pickTarget.AbsoluteSize.X, pickTarget.AbsoluteSize.Y)
		pickRing.Visible = true
	else
		pickRing.Visible = false
	end
end

RunService:BindToRenderStep("JumpCustomizerEntries", Enum.RenderPriority.Last.Value, function()
	local ok, err = pcall(stepEntries)
	if not ok and not warned then
		warned = true
		warn("[JumpCustomizer] " .. tostring(err))
	end
end)

-- right after drawing: give the game its real transparency values back
connect(RunService.Stepped, function()
	for _, b in pairs(bound) do
		if b.opCache then unfade(b) end
	end
end)

table.insert(cleanupFns, function()
	pcall(function() RunService:UnbindFromRenderStep("JumpCustomizerEntries") end)
	for _, b in pairs(bound) do restoreBound(b) end
	_G.__JumpCustomizerEntryBegan = nil
end)

-- buttons may be re-created by the game (e.g. on respawn): re-find them regularly
local acc = 0
local presetTick = 0
connect(RunService.Heartbeat, function(dt)
	acc += dt
	if acc < 0.5 then return end
	acc = 0
	presetTick += 1
	if presetTick % 3 == 1 then applyPresets() end
	refreshBound()
end)

-- which button the size slider edits
setActive = function(key)
	if key ~= "jump" and not custom[key] then key = "jump" end
	activeKey = key
	local name = niceName(key)
	selLabel.Text = "Selected: " .. name
	if key == "jump" then
		sizeSlider.SetValue(settings.size, true)
		opacitySlider.SetValue(settings.opacity or 100, true)
	else
		sizeSlider.SetValue(custom[key].scale or 100, true)
		opacitySlider.SetValue(custom[key].opacity or 100, true)
	end
	sizeSlider.Label.Text = "Size · " .. name
	opacitySlider.Label.Text = "Opacity · " .. name
end

-- dragging an added button (Drag Mode ON)
local entryTracked, entryPath, entryStart, entryStartD

_G.__JumpCustomizerEntryBegan = function(path, input)
	if not dragEnabled or entryTracked or not isPointer(input) then return end
	local e = custom[path]
	if not e then return end
	entryTracked, entryPath = input, path
	entryStart = pos2(input)
	entryStartD = Vector2.new(e.dx, e.dy)
	setActive(path)
end

connect(UserInputService.InputChanged, function(input)
	if not entryTracked then return end
	local same = input == entryTracked
		or (entryTracked.UserInputType == Enum.UserInputType.MouseButton1
			and input.UserInputType == Enum.UserInputType.MouseMovement)
	if not same then return end
	local e = custom[entryPath]
	local cam = workspace.CurrentCamera
	if not e or not cam then return end
	local d = pos2(input) - entryStart
	local vp = cam.ViewportSize
	e.dx = math.clamp(entryStartD.X + d.X / vp.X, -1, 1)
	e.dy = math.clamp(entryStartD.Y + d.Y / vp.Y, -1, 1)
end)

connect(UserInputService.InputEnded, function(input)
	if entryTracked and sameInput(input, entryTracked) then
		entryTracked = nil
		saveSettings()
		showToast("Position saved ✓", 1.2)
	end
end)

onMenuClosed = nil

task.defer(function()
	applyPresets()
	refreshBound()
end)

_G.ToggleJumpSettings = function() toggleMenu() end

task.delay(0.6, function()
	if not (writefile and readfile) then
		showToast("No file saving in this executor: layout lasts until you leave", 3)
	elseif loadedFromFile then
		showToast("Saved layout restored ✓", 2)
	end
end)

print("[JumpCustomizer] Loaded — made by hasson · discord @illxyz")
