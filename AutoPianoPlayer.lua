-- ╔══════════════════════════════════════════════════════╗
-- ║  Virtual Piano Auto Player v5.1                      ║
-- ║  Loads songs DIRECTLY from GitHub raw URLs           ║
-- ║  (No Render server call — fixes HTTP block error)    ║
-- ╚══════════════════════════════════════════════════════╝

local VIM          = game:GetService("VirtualInputManager")
local Players      = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local HttpService  = game:GetService("HttpService")

-- ============================================================
-- ★  CONFIG  ★
-- Your GitHub RAW base URL — this is always allowed by executors
-- Format: https://raw.githubusercontent.com/USERNAME/REPO/main
-- ============================================================

local GITHUB_BASE = "https://raw.githubusercontent.com/JUJUx1/Piano-player/main"

-- ============================================================
-- KEY MAPS
-- ============================================================

local keyMap = {
    ["1"]=Enum.KeyCode.One,   ["2"]=Enum.KeyCode.Two,   ["3"]=Enum.KeyCode.Three,
    ["4"]=Enum.KeyCode.Four,  ["5"]=Enum.KeyCode.Five,  ["6"]=Enum.KeyCode.Six,
    ["7"]=Enum.KeyCode.Seven, ["8"]=Enum.KeyCode.Eight, ["9"]=Enum.KeyCode.Nine,
    ["0"]=Enum.KeyCode.Zero,
    ["q"]=Enum.KeyCode.Q,["w"]=Enum.KeyCode.W,["e"]=Enum.KeyCode.E,["r"]=Enum.KeyCode.R,
    ["t"]=Enum.KeyCode.T,["y"]=Enum.KeyCode.Y,["u"]=Enum.KeyCode.U,["i"]=Enum.KeyCode.I,
    ["o"]=Enum.KeyCode.O,["p"]=Enum.KeyCode.P,["a"]=Enum.KeyCode.A,["s"]=Enum.KeyCode.S,
    ["d"]=Enum.KeyCode.D,["f"]=Enum.KeyCode.F,["g"]=Enum.KeyCode.G,["h"]=Enum.KeyCode.H,
    ["j"]=Enum.KeyCode.J,["k"]=Enum.KeyCode.K,["l"]=Enum.KeyCode.L,["z"]=Enum.KeyCode.Z,
    ["x"]=Enum.KeyCode.X,["c"]=Enum.KeyCode.C,["v"]=Enum.KeyCode.V,["b"]=Enum.KeyCode.B,
    ["n"]=Enum.KeyCode.N,["m"]=Enum.KeyCode.M,
}
local capsMap = {
    ["Q"]=Enum.KeyCode.Q,["W"]=Enum.KeyCode.W,["E"]=Enum.KeyCode.E,["R"]=Enum.KeyCode.R,
    ["T"]=Enum.KeyCode.T,["Y"]=Enum.KeyCode.Y,["U"]=Enum.KeyCode.U,["I"]=Enum.KeyCode.I,
    ["O"]=Enum.KeyCode.O,["P"]=Enum.KeyCode.P,["S"]=Enum.KeyCode.S,["D"]=Enum.KeyCode.D,
    ["G"]=Enum.KeyCode.G,["H"]=Enum.KeyCode.H,["J"]=Enum.KeyCode.J,["L"]=Enum.KeyCode.L,
    ["Z"]=Enum.KeyCode.Z,["C"]=Enum.KeyCode.C,["V"]=Enum.KeyCode.V,["B"]=Enum.KeyCode.B,
    ["N"]=Enum.KeyCode.N,["M"]=Enum.KeyCode.M,
}

-- ============================================================
-- STATE
-- ============================================================

local songs         = {}
local isPlaying     = false
local isPaused      = false
local selectedIndex = 1
local playSpeed     = 1.0
local playThread    = nil
local noteGap       = 0.25

-- ============================================================
-- ENGINE
-- ============================================================

local function pressKey(kc, shift)
    if shift then VIM:SendKeyEvent(true, Enum.KeyCode.LeftShift, false, game) end
    VIM:SendKeyEvent(true, kc, false, game)
    task.wait(0.05)
    VIM:SendKeyEvent(false, kc, false, game)
    if shift then VIM:SendKeyEvent(false, Enum.KeyCode.LeftShift, false, game) end
end

local function parseSheet(s)
    local n = {}
    for t in s:gmatch("%S+") do if t ~= "|" then table.insert(n, t) end end
    return n
end

local function stopSong()
    isPlaying = false; isPaused = false
    if playThread then task.cancel(playThread); playThread = nil end
end

local function playSong(idx, sLbl)
    stopSong()
    local song = songs[idx]
    if not song then return end
    isPlaying = true; isPaused = false
    playThread = task.spawn(function()
        if sLbl then sLbl.Text = "▶  " .. song.name end
        for _, note in ipairs(parseSheet(song.sheet)) do
            while isPaused do task.wait(0.1) end
            if not isPlaying then break end
            local up = note == note:upper() and note ~= note:lower()
            if up then
                local kc = capsMap[note]; if kc then pressKey(kc, true) end
            else
                local kc = keyMap[note]; if kc then pressKey(kc, false) end
            end
            task.wait(noteGap / playSpeed)
        end
        isPlaying = false
        if sLbl then sLbl.Text = "✓  Done: " .. song.name end
    end)
end

-- ============================================================
-- BUILD UI
-- ============================================================

local player    = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local old = playerGui:FindFirstChild("AutoPianoUI")
if old then old:Destroy() end

local sg = Instance.new("ScreenGui")
sg.Name = "AutoPianoUI"; sg.ResetOnSpawn = false
sg.ZIndexBehavior = Enum.ZIndexBehavior.Sibling; sg.Parent = playerGui

-- Main frame
local main = Instance.new("Frame")
main.Size = UDim2.new(0, 280, 0, 440)
main.Position = UDim2.new(0.5, -140, 0.5, -220)
main.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
main.BorderSizePixel = 0; main.ClipsDescendants = true; main.Parent = sg
Instance.new("UICorner", main).CornerRadius = UDim.new(0, 14)

-- Drag
local drg, ds, sp2
main.InputBegan:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.Touch or
       i.UserInputType == Enum.UserInputType.MouseButton1 then
        drg = true; ds = i.Position; sp2 = main.Position
    end
end)
main.InputChanged:Connect(function(i)
    if drg and (i.UserInputType == Enum.UserInputType.Touch or
       i.UserInputType == Enum.UserInputType.MouseMove) then
        local d = i.Position - ds
        main.Position = UDim2.new(sp2.X.Scale, sp2.X.Offset + d.X,
                                   sp2.Y.Scale, sp2.Y.Offset + d.Y)
    end
end)
main.InputEnded:Connect(function(i)
    if i.UserInputType == Enum.UserInputType.Touch or
       i.UserInputType == Enum.UserInputType.MouseButton1 then drg = false end
end)

-- Header
local hdr = Instance.new("Frame")
hdr.Size = UDim2.new(1, 0, 0, 42)
hdr.BackgroundColor3 = Color3.fromRGB(18, 18, 30)
hdr.BorderSizePixel = 0; hdr.Parent = main
Instance.new("UICorner", hdr).CornerRadius = UDim.new(0, 14)
-- fix bottom corners of header
local hf = Instance.new("Frame")
hf.Size = UDim2.new(1, 0, 0.5, 0); hf.Position = UDim2.new(0, 0, 0.5, 0)
hf.BackgroundColor3 = Color3.fromRGB(18, 18, 30); hf.BorderSizePixel = 0; hf.Parent = hdr

-- Accent line under header
local al = Instance.new("Frame")
al.Size = UDim2.new(1, 0, 0, 2); al.Position = UDim2.new(0, 0, 1, -2)
al.BackgroundColor3 = Color3.fromRGB(70, 130, 255); al.BorderSizePixel = 0; al.Parent = hdr
local ag = Instance.new("UIGradient", al)
ag.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0,   Color3.fromRGB(60, 100, 255)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(160, 70, 255)),
    ColorSequenceKeypoint.new(1,   Color3.fromRGB(255, 70, 160)),
})

-- Title
local ttl = Instance.new("TextLabel")
ttl.Size = UDim2.new(1, -85, 1, 0); ttl.Position = UDim2.new(0, 11, 0, 0)
ttl.BackgroundTransparency = 1; ttl.Text = "🎹 Auto Piano"
ttl.TextColor3 = Color3.fromRGB(255, 255, 255); ttl.TextSize = 13
ttl.Font = Enum.Font.GothamBold; ttl.TextXAlignment = Enum.TextXAlignment.Left; ttl.Parent = hdr

-- Header buttons
local function hB(txt, col, rx)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 26, 0, 26); b.Position = UDim2.new(1, rx, 0.5, -13)
    b.BackgroundColor3 = col; b.Text = txt; b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.TextSize = 10; b.Font = Enum.Font.GothamBold; b.BorderSizePixel = 0; b.Parent = hdr
    Instance.new("UICorner", b).CornerRadius = UDim.new(1, 0); return b
end
local minB = hB("—", Color3.fromRGB(40, 40, 58), -66)
local clsB = hB("✕", Color3.fromRGB(180, 40, 40), -34)
local minimized = false
minB.MouseButton1Click:Connect(function()
    minimized = not minimized
    TweenService:Create(main, TweenInfo.new(0.25, Enum.EasingStyle.Quart),
        {Size = minimized and UDim2.new(0, 280, 0, 42) or UDim2.new(0, 280, 0, 440)}):Play()
    minB.Text = minimized and "▲" or "—"
end)
clsB.MouseButton1Click:Connect(function() sg:Destroy() end)

-- Status bar
local sb = Instance.new("Frame")
sb.Size = UDim2.new(1, -18, 0, 22); sb.Position = UDim2.new(0, 9, 0, 48)
sb.BackgroundColor3 = Color3.fromRGB(20, 20, 34); sb.BorderSizePixel = 0; sb.Parent = main
Instance.new("UICorner", sb).CornerRadius = UDim.new(0, 6)
local statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(1, -12, 1, 0); statusLbl.Position = UDim2.new(0, 6, 0, 0)
statusLbl.BackgroundTransparency = 1; statusLbl.Text = "⏳ Loading songs from GitHub..."
statusLbl.TextColor3 = Color3.fromRGB(90, 180, 255); statusLbl.TextSize = 10
statusLbl.Font = Enum.Font.Gotham; statusLbl.TextXAlignment = Enum.TextXAlignment.Left
statusLbl.TextTruncate = Enum.TextTruncate.AtEnd; statusLbl.Parent = sb

-- Speed row
local spRow = Instance.new("Frame")
spRow.Size = UDim2.new(1, -18, 0, 24); spRow.Position = UDim2.new(0, 9, 0, 77)
spRow.BackgroundTransparency = 1; spRow.Parent = main
local spL = Instance.new("TextLabel")
spL.Size = UDim2.new(0, 48, 1, 0); spL.BackgroundTransparency = 1
spL.Text = "Speed:"; spL.TextColor3 = Color3.fromRGB(120, 120, 150); spL.TextSize = 10
spL.Font = Enum.Font.GothamBold; spL.TextXAlignment = Enum.TextXAlignment.Left; spL.Parent = spRow
local sps = {0.5, 0.75, 1.0, 1.5, 2.0}; local spIdx = 3; local spBs = {}
for i, sp in ipairs(sps) do
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, 36, 0, 20); b.Position = UDim2.new(0, 46 + (i-1)*40, 0.5, -10)
    b.BackgroundColor3 = (i == spIdx) and Color3.fromRGB(65, 125, 235) or Color3.fromRGB(25, 25, 40)
    b.Text = sp .. "x"; b.TextColor3 = Color3.fromRGB(255, 255, 255); b.TextSize = 9
    b.Font = Enum.Font.GothamBold; b.BorderSizePixel = 0; b.Name = "SP"..i; b.Parent = spRow
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 5); spBs[i] = b
    b.MouseButton1Click:Connect(function()
        spIdx = i; playSpeed = sp
        for j, x in ipairs(spBs) do
            x.BackgroundColor3 = (j == i) and Color3.fromRGB(65, 125, 235) or Color3.fromRGB(25, 25, 40)
        end
    end)
end

-- Control buttons
local cRow = Instance.new("Frame")
cRow.Size = UDim2.new(1, -18, 0, 32); cRow.Position = UDim2.new(0, 9, 0, 108)
cRow.BackgroundTransparency = 1; cRow.Parent = main
local function cB(txt, col, xp, w)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0, w, 0, 30); b.Position = UDim2.new(0, xp, 0, 0)
    b.BackgroundColor3 = col; b.Text = txt; b.TextColor3 = Color3.fromRGB(255, 255, 255)
    b.TextSize = 11; b.Font = Enum.Font.GothamBold; b.BorderSizePixel = 0; b.Parent = cRow
    Instance.new("UICorner", b).CornerRadius = UDim.new(0, 7); return b
end
local playBtn = cB("▶ Play",  Color3.fromRGB(30, 160, 65),   0,  78)
local pauBtn  = cB("⏸ Pause", Color3.fromRGB(190, 140, 10),  84, 78)
local stpBtn  = cB("⏹ Stop",  Color3.fromRGB(175, 40, 40),  168, 78)

playBtn.MouseButton1Click:Connect(function()
    if #songs == 0 then statusLbl.Text = "⚠ No songs loaded!"; return end
    if isPaused then
        isPaused = false; statusLbl.Text = "▶  " .. songs[selectedIndex].name
    else
        playSong(selectedIndex, statusLbl)
    end
end)
pauBtn.MouseButton1Click:Connect(function()
    if isPlaying then
        isPaused = not isPaused
        statusLbl.Text = isPaused
            and ("⏸  " .. songs[selectedIndex].name)
            or  ("▶  " .. songs[selectedIndex].name)
    end
end)
stpBtn.MouseButton1Click:Connect(function()
    stopSong(); statusLbl.Text = "⏹  Stopped"
end)

-- Search box
local srch = Instance.new("TextBox")
srch.Size = UDim2.new(1, -18, 0, 26); srch.Position = UDim2.new(0, 9, 0, 147)
srch.BackgroundColor3 = Color3.fromRGB(20, 20, 32); srch.Text = ""
srch.PlaceholderText = "🔍 Search songs..."; srch.TextColor3 = Color3.fromRGB(255, 255, 255)
srch.PlaceholderColor3 = Color3.fromRGB(75, 75, 95); srch.TextSize = 10; srch.Font = Enum.Font.Gotham
srch.BorderSizePixel = 0; srch.ClearTextOnFocus = false; srch.Parent = main
Instance.new("UICorner", srch).CornerRadius = UDim.new(0, 7)
local spad = Instance.new("UIPadding", srch); spad.PaddingLeft = UDim.new(0, 8)

-- Song list
local lf = Instance.new("ScrollingFrame")
lf.Size = UDim2.new(1, -18, 0, 208); lf.Position = UDim2.new(0, 9, 0, 180)
lf.BackgroundColor3 = Color3.fromRGB(16, 16, 26); lf.BorderSizePixel = 0
lf.ScrollBarThickness = 3; lf.ScrollBarImageColor3 = Color3.fromRGB(65, 125, 235)
lf.CanvasSize = UDim2.new(0, 0, 0, 0); lf.ClipsDescendants = true; lf.Parent = main
Instance.new("UICorner", lf).CornerRadius = UDim.new(0, 10)
local ll = Instance.new("UIListLayout", lf)
ll.Padding = UDim.new(0, 3); ll.SortOrder = Enum.SortOrder.LayoutOrder
local lpad = Instance.new("UIPadding", lf)
lpad.PaddingTop = UDim.new(0, 4); lpad.PaddingBottom = UDim.new(0, 4)
lpad.PaddingLeft = UDim.new(0, 4); lpad.PaddingRight = UDim.new(0, 4)

-- Reload button
local rlBtn = Instance.new("TextButton")
rlBtn.Size = UDim2.new(1, -18, 0, 20); rlBtn.Position = UDim2.new(0, 9, 0, 398)
rlBtn.BackgroundColor3 = Color3.fromRGB(20, 20, 34)
rlBtn.Text = "↻  Reload songs from GitHub"
rlBtn.TextColor3 = Color3.fromRGB(65, 125, 235); rlBtn.TextSize = 10
rlBtn.Font = Enum.Font.GothamBold; rlBtn.BorderSizePixel = 0; rlBtn.Parent = main
Instance.new("UICorner", rlBtn).CornerRadius = UDim.new(0, 6)

-- Category colors
local catC = {
    Classic = Color3.fromRGB(255, 185, 65),
    Game    = Color3.fromRGB(65, 205, 105),
    Anime   = Color3.fromRGB(255, 85, 165),
    Pop     = Color3.fromRGB(85, 165, 255),
    Movie   = Color3.fromRGB(185, 115, 255),
    Custom  = Color3.fromRGB(90, 215, 190),
}

local sBtns = {}
local function buildList(filter)
    for _, b in pairs(sBtns) do b:Destroy() end
    sBtns = {}
    if #songs == 0 then
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1, 0, 0, 50)
        lbl.BackgroundTransparency = 1
        lbl.Text = "No songs found.\nAdd .json files to songs/ on GitHub"
        lbl.TextColor3 = Color3.fromRGB(80, 80, 100); lbl.TextSize = 11
        lbl.Font = Enum.Font.Gotham; lbl.TextWrapped = true; lbl.Parent = lf
        table.insert(sBtns, lbl)
        lf.CanvasSize = UDim2.new(0, 0, 0, 54); return
    end
    local order = 0
    for i, song in ipairs(songs) do
        local f = filter or ""
        if f == "" or song.name:lower():find(f:lower(), 1, true)
                   or (song.category and song.category:lower():find(f:lower(), 1, true)) then
            order = order + 1
            local row = Instance.new("TextButton")
            row.Size = UDim2.new(1, 0, 0, 32); row.LayoutOrder = order
            row.BackgroundColor3 = (i == selectedIndex)
                and Color3.fromRGB(28, 48, 76) or Color3.fromRGB(20, 20, 32)
            row.BorderSizePixel = 0; row.AutoButtonColor = false; row.Parent = lf
            Instance.new("UICorner", row).CornerRadius = UDim.new(0, 7)
            if i == selectedIndex then
                local s = Instance.new("UIStroke", row)
                s.Color = Color3.fromRGB(65, 125, 235); s.Thickness = 1
            end
            local cat = song.category or "Custom"
            local dot = Instance.new("Frame")
            dot.Size = UDim2.new(0, 6, 0, 6); dot.Position = UDim2.new(0, 7, 0.5, -3)
            dot.BackgroundColor3 = catC[cat] or Color3.fromRGB(150, 150, 150)
            dot.BorderSizePixel = 0; dot.Parent = row
            Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
            local nl = Instance.new("TextLabel")
            nl.Size = UDim2.new(1, -62, 1, 0); nl.Position = UDim2.new(0, 19, 0, 0)
            nl.BackgroundTransparency = 1; nl.Text = song.name
            nl.TextColor3 = (i == selectedIndex)
                and Color3.fromRGB(215, 230, 255) or Color3.fromRGB(160, 160, 195)
            nl.TextSize = 11
            nl.Font = (i == selectedIndex) and Enum.Font.GothamBold or Enum.Font.Gotham
            nl.TextXAlignment = Enum.TextXAlignment.Left
            nl.TextTruncate = Enum.TextTruncate.AtEnd; nl.Parent = row
            local ct = Instance.new("TextLabel")
            ct.Size = UDim2.new(0, 44, 0, 15); ct.Position = UDim2.new(1, -49, 0.5, -7.5)
            ct.BackgroundColor3 = catC[cat] or Color3.fromRGB(45, 45, 65)
            ct.BackgroundTransparency = 0.5; ct.Text = cat
            ct.TextColor3 = Color3.fromRGB(255, 255, 255); ct.TextSize = 8
            ct.Font = Enum.Font.GothamBold; ct.Parent = row
            Instance.new("UICorner", ct).CornerRadius = UDim.new(0, 4)
            table.insert(sBtns, row)
            row.MouseButton1Click:Connect(function()
                selectedIndex = i
                statusLbl.Text = "►  " .. song.name .. "  — press Play"
                buildList(srch.Text)
            end)
        end
    end
    ll:ApplyLayout()
    lf.CanvasSize = UDim2.new(0, 0, 0, ll.AbsoluteContentSize.Y + 8)
end

srch:GetPropertyChangedSignal("Text"):Connect(function() buildList(srch.Text) end)

-- ============================================================
-- GITHUB LOADER
-- raw.githubusercontent.com is whitelisted by all executors
-- ============================================================

local function fetchJSON(url)
    local ok, res = pcall(HttpService.GetAsync, HttpService, url, true)
    if not ok then return nil, tostring(res) end
    local ok2, data = pcall(HttpService.JSONDecode, HttpService, res)
    if not ok2 then return nil, tostring(data) end
    return data, nil
end

local function loadAllSongs()
    songs = {}
    buildList("")
    statusLbl.Text = "⏳ Fetching index.json..."

    task.spawn(function()
        -- Step 1: fetch index.json
        local index, err = fetchJSON(GITHUB_BASE .. "/index.json")
        if not index then
            statusLbl.Text = "❌ index.json error: " .. (err or "unknown")
            warn("index.json fetch failed: " .. tostring(err))
            return
        end
        if type(index) ~= "table" or #index == 0 then
            statusLbl.Text = "⚠ index.json is empty — add songs to GitHub!"
            return
        end

        statusLbl.Text = "⏳ Loading " .. #index .. " songs..."
        local loaded = 0
        local failed = 0

        -- Step 2: fetch each individual song file
        for _, filename in ipairs(index) do
            local url  = GITHUB_BASE .. "/songs/" .. filename
            local song, serr = fetchJSON(url)
            if song and song.name and song.sheet then
                table.insert(songs, song)
                loaded = loaded + 1
                statusLbl.Text = "⏳ " .. loaded .. "/" .. #index .. " loaded..."
                buildList(srch.Text)
            else
                failed = failed + 1
                warn("⚠ Skipped " .. filename .. ": " .. tostring(serr or "missing fields"))
            end
            task.wait(0.04)
        end

        if loaded == 0 then
            statusLbl.Text = "❌ 0 songs loaded — check your songs/ folder"
        elseif failed > 0 then
            statusLbl.Text = "✓ " .. loaded .. " songs (" .. failed .. " failed)"
        else
            statusLbl.Text = "✓ " .. loaded .. " songs ready!"
        end
        buildList("")
        print("🎹 Auto Piano: " .. loaded .. " songs loaded from GitHub")
    end)
end

rlBtn.MouseButton1Click:Connect(loadAllSongs)

-- ============================================================
-- START — load songs immediately, no server call needed
-- ============================================================
loadAllSongs()

print("🎹 Auto Piano v5.1 loaded! Songs loading from GitHub...")
