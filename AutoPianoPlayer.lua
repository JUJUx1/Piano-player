-- ╔══════════════════════════════════════════════════════════╗
-- ║  Virtual Piano Auto Player v7.1                          ║
-- ║  • Left sidebar tabs: Music | Settings | Reload          ║
-- ║  • Header: seekbar + transport always visible            ║
-- ║  • Anti-lag engine                                       ║
-- ╚══════════════════════════════════════════════════════════╝

local Players  = game:GetService("Players")
local TweenSvc = game:GetService("TweenService")
local VIM      = game:GetService("VirtualInputManager")
local HttpSvc  = game:GetService("HttpService")

-- ============================================================
-- CONFIG
-- ============================================================
local GITHUB_BASE = "https://raw.githubusercontent.com/JUJUx1/Piano-player/main"

-- ============================================================
-- HTTP
-- ============================================================
local function fetchRaw(url)
    local ok,r = pcall(function() return game:HttpGet(url) end)
    if ok and r and #r>0 then return r end
    local ok2,r2 = pcall(function() return HttpSvc:GetAsync(url,true) end)
    if ok2 and r2 then return r2 end
    return nil
end
local function fetchJSON(url)
    local r=fetchRaw(url); if not r then return nil end
    local ok,d=pcall(HttpSvc.JSONDecode,HttpSvc,r)
    return ok and d or nil
end

-- ============================================================
-- KEY MAPS
-- ============================================================
-- ── WHITE KEYS ──────────────────────────────────────────────
-- 1=C2  2=D2  3=E2  4=F2  5=G2  6=A2  7=B2
-- 8=C3  9=D3  0=E3  q=F3  w=G3  e=A3  r=B3
-- t=C4  y=D4  u=E4  i=F4  o=G4  p=A4  a=B4
-- s=C5  d=D5  f=E5  g=F5  h=G5  j=A5  k=B5
-- l=C6  z=D6  x=E6  c=F6  v=G6  b=A6  n=B6  m=C7
local keyMap = {
    ["1"]=Enum.KeyCode.One,  ["2"]=Enum.KeyCode.Two,   ["3"]=Enum.KeyCode.Three,
    ["4"]=Enum.KeyCode.Four, ["5"]=Enum.KeyCode.Five,  ["6"]=Enum.KeyCode.Six,
    ["7"]=Enum.KeyCode.Seven,["8"]=Enum.KeyCode.Eight, ["9"]=Enum.KeyCode.Nine,
    ["0"]=Enum.KeyCode.Zero,
    ["q"]=Enum.KeyCode.Q,["w"]=Enum.KeyCode.W,["e"]=Enum.KeyCode.E,["r"]=Enum.KeyCode.R,
    ["t"]=Enum.KeyCode.T,["y"]=Enum.KeyCode.Y,["u"]=Enum.KeyCode.U,["i"]=Enum.KeyCode.I,
    ["o"]=Enum.KeyCode.O,["p"]=Enum.KeyCode.P,["a"]=Enum.KeyCode.A,["s"]=Enum.KeyCode.S,
    ["d"]=Enum.KeyCode.D,["f"]=Enum.KeyCode.F,["g"]=Enum.KeyCode.G,["h"]=Enum.KeyCode.H,
    ["j"]=Enum.KeyCode.J,["k"]=Enum.KeyCode.K,["l"]=Enum.KeyCode.L,["z"]=Enum.KeyCode.Z,
    ["x"]=Enum.KeyCode.X,["c"]=Enum.KeyCode.C,["v"]=Enum.KeyCode.V,["b"]=Enum.KeyCode.B,
    ["n"]=Enum.KeyCode.N,["m"]=Enum.KeyCode.M,
}
-- ── BLACK KEYS (Shift held) ──────────────────────────────────
-- C#2=!  D#2=@  F#2=$  G#2=%  A#2=^
-- C#3=8+Shift(*)  D#3=9+Shift → but VP uses: 8shift=*? No —
-- Correct: black keys use the white key BELOW them + Shift
-- C#2=Shift+1  D#2=Shift+2  F#2=Shift+4  G#2=Shift+5  A#2=Shift+6
-- C#3=Shift+8  D#3=Shift+9  F#3=Shift+Q  G#3=Shift+W  A#3=Shift+E
-- C#4=Shift+T  D#4=Shift+Y  F#4=Shift+I  G#4=Shift+O  A#4=Shift+P
-- C#5=Shift+S  D#5=Shift+D  F#5=Shift+G  G#5=Shift+H  A#5=Shift+J
-- C#6=Shift+L  D#6=Shift+Z  F#6=Shift+C  G#6=Shift+V  A#6=Shift+B
local capsMap = {
    -- Number row black keys
    ["!"]=Enum.KeyCode.One,  ["@"]=Enum.KeyCode.Two,
    ["$"]=Enum.KeyCode.Four, ["%"]=Enum.KeyCode.Five, ["^"]=Enum.KeyCode.Six,
    -- 8,9 row black keys (C#3, D#3) — VP uses * and ( for these
    ["*"]=Enum.KeyCode.Eight,["("]=Enum.KeyCode.Nine,
    -- QWERTY row black keys
    ["Q"]=Enum.KeyCode.Q,["W"]=Enum.KeyCode.W,["E"]=Enum.KeyCode.E,
    ["T"]=Enum.KeyCode.T,["Y"]=Enum.KeyCode.Y,
    ["I"]=Enum.KeyCode.I,["O"]=Enum.KeyCode.O,["P"]=Enum.KeyCode.P,
    -- Home row black keys
    ["S"]=Enum.KeyCode.S,["D"]=Enum.KeyCode.D,
    ["G"]=Enum.KeyCode.G,["H"]=Enum.KeyCode.H,["J"]=Enum.KeyCode.J,
    ["L"]=Enum.KeyCode.L,
    -- Bottom row black keys
    ["Z"]=Enum.KeyCode.Z,
    ["C"]=Enum.KeyCode.C,["V"]=Enum.KeyCode.V,["B"]=Enum.KeyCode.B,
    ["M"]=Enum.KeyCode.M,
}

-- ============================================================
-- STATE
-- ============================================================
local songs      = {}
local isPlaying  = false
local isPaused   = false
local selIdx     = 1
local playSpeed  = 1.0
local noteGap    = 0.25
local playThread = nil
local totalMs    = 0
local elapsedMs  = 0
local antiLagOn  = true

-- ============================================================
-- COLORS
-- ============================================================
local C = {
    bg      = Color3.fromRGB(11,  11,  18),
    surface = Color3.fromRGB(17,  17,  27),
    card    = Color3.fromRGB(22,  22,  34),
    sidebar = Color3.fromRGB(14,  14,  22),
    hdr     = Color3.fromRGB(13,  13,  21),
    blue    = Color3.fromRGB(70,  118, 242),
    green   = Color3.fromRGB(38,  182, 92),
    yellow  = Color3.fromRGB(198, 150, 18),
    red     = Color3.fromRGB(182, 44,  54),
    text    = Color3.fromRGB(218, 220, 255),
    muted   = Color3.fromRGB(82,  82,  122),
    white   = Color3.fromRGB(255, 255, 255),
}
local catC = {
    Classic=Color3.fromRGB(255,185,65), Game=Color3.fromRGB(65,205,105),
    Anime=Color3.fromRGB(255,85,165),   Pop=Color3.fromRGB(85,165,255),
    Movie=Color3.fromRGB(185,115,255),  Custom=Color3.fromRGB(90,215,190),
}

-- ============================================================
-- ENGINE
-- ============================================================
local function pressKey(kc, shift)
    if shift then VIM:SendKeyEvent(true,Enum.KeyCode.LeftShift,false,game) end
    VIM:SendKeyEvent(true,kc,false,game)
    task.wait(0.03)
    VIM:SendKeyEvent(false,kc,false,game)
    if shift then VIM:SendKeyEvent(false,Enum.KeyCode.LeftShift,false,game) end
end

local function resolveKey(n)
    local up = n==n:upper() and n~=n:lower()
    if up then return capsMap[n],true end
    return keyMap[n],false
end

local function playChord(keys)
    for _,n in ipairs(keys) do
        local kc,sh = resolveKey(n)
        if kc then task.spawn(pressKey,kc,sh) end
    end
end

local function buildChordGroups(notes)
    local groups,i={},1
    while i<=#notes do
        local ch={keys={},delay=200}
        while i<=#notes do
            local n=notes[i]; i=i+1
            table.insert(ch.keys,n.k)
            if (n.d or 0)>0 then ch.delay=n.d; break end
        end
        if #ch.keys>0 then table.insert(groups,ch) end
    end
    return groups
end

local function stopSong()
    isPlaying=false; isPaused=false
    if playThread then task.cancel(playThread); playThread=nil end
    elapsedMs=0; totalMs=0
end

local function formatTime(ms)
    local s=math.floor(ms/1000)
    return string.format("%d:%02d",math.floor(s/60),s%60)
end

-- ============================================================
-- UI HELPERS
-- ============================================================
local function corner(p,r) local c=Instance.new("UICorner",p); c.CornerRadius=UDim.new(0,r or 10) end
local function newFrame(par,sz,pos,col)
    local f=Instance.new("Frame"); f.Size=sz; f.Position=pos or UDim2.new(0,0,0,0)
    f.BackgroundColor3=col or C.surface; f.BorderSizePixel=0; f.Parent=par; return f
end
local function newLbl(par,sz,pos,txt,ts,col,font,xa)
    local l=Instance.new("TextLabel"); l.Size=sz; l.Position=pos or UDim2.new(0,0,0,0)
    l.BackgroundTransparency=1; l.Text=txt; l.TextSize=ts or 12; l.TextColor3=col or C.text
    l.Font=font or Enum.Font.Gotham; l.TextXAlignment=xa or Enum.TextXAlignment.Left
    l.TextTruncate=Enum.TextTruncate.AtEnd; l.Parent=par; return l
end
local function newBtn(par,sz,pos,txt,ts,bg,tc,font)
    local b=Instance.new("TextButton"); b.Size=sz; b.Position=pos or UDim2.new(0,0,0,0)
    b.BackgroundColor3=bg or C.card; b.Text=txt; b.TextSize=ts or 13
    b.TextColor3=tc or C.white; b.Font=font or Enum.Font.GothamBold
    b.BorderSizePixel=0; b.AutoButtonColor=false; b.Parent=par; return b
end
local function ripple(b,col)
    local r=Instance.new("Frame"); r.AnchorPoint=Vector2.new(0.5,0.5)
    r.Position=UDim2.new(0.5,0,0.5,0); r.Size=UDim2.new(0,0,0,0)
    r.BackgroundColor3=col or C.white; r.BackgroundTransparency=0.8
    r.BorderSizePixel=0; r.ZIndex=b.ZIndex+2; r.Parent=b
    corner(r,999)
    TweenSvc:Create(r,TweenInfo.new(0.28,Enum.EasingStyle.Quad,Enum.EasingDirection.Out),
        {Size=UDim2.new(2.5,0,2.5,0),BackgroundTransparency=1}):Play()
    task.delay(0.28,function() if r then r:Destroy() end end)
end

-- ============================================================
-- LAYOUT CONSTANTS
-- ============================================================
--[[
  Total:  310 × 390
  Header: full width, 130px tall
  Below header:
    Sidebar: 44px wide, full remaining height
    Content: rest of width, full remaining height
]]
local WIN_W  = 200
local WIN_H  = 300
local HDR_H  = 108
local SIDE_W = 36
local BODY_H = WIN_H - HDR_H   -- 260

-- ============================================================
-- BUILD UI
-- ============================================================
local pGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local old  = pGui:FindFirstChild("AutoPianoUI"); if old then old:Destroy() end

local sg = Instance.new("ScreenGui"); sg.Name="AutoPianoUI"
sg.ResetOnSpawn=false; sg.ZIndexBehavior=Enum.ZIndexBehavior.Sibling; sg.Parent=pGui

local main = Instance.new("Frame"); main.Name="Main"
main.Size=UDim2.new(0,WIN_W,0,WIN_H); main.AnchorPoint=Vector2.new(0.5,0.5)
main.Position=UDim2.new(0.5,0,0.5,0); main.BackgroundColor3=C.bg
main.BorderSizePixel=0; main.ClipsDescendants=true; main.Parent=sg
corner(main,14)
local mainStroke=Instance.new("UIStroke",main)
mainStroke.Color=Color3.fromRGB(38,38,68); mainStroke.Thickness=1

-- Drag
local drg,dSt,wSt
main.InputBegan:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.Touch or i.UserInputType==Enum.UserInputType.MouseButton1 then
        drg=true; dSt=i.Position; wSt=main.Position end end)
main.InputChanged:Connect(function(i)
    if drg and (i.UserInputType==Enum.UserInputType.Touch or i.UserInputType==Enum.UserInputType.MouseMove) then
        local d=i.Position-dSt
        main.Position=UDim2.new(wSt.X.Scale,wSt.X.Offset+d.X,wSt.Y.Scale,wSt.Y.Offset+d.Y) end end)
main.InputEnded:Connect(function(i)
    if i.UserInputType==Enum.UserInputType.Touch or i.UserInputType==Enum.UserInputType.MouseButton1 then
        drg=false end end)

-- ╔══════════════════════════════════════════════════════════╗
-- ║  HEADER                                                  ║
-- ╚══════════════════════════════════════════════════════════╝
local hdr = newFrame(main,UDim2.new(1,0,0,HDR_H),UDim2.new(0,0,0,0),C.hdr)
corner(hdr,16)
-- fill bottom corners of header
newFrame(hdr,UDim2.new(1,0,0.4,0),UDim2.new(0,0,0.6,0),C.hdr)

-- Animated gradient line at bottom of header
local aline = newFrame(hdr,UDim2.new(1,0,0,2),UDim2.new(0,0,1,-2),C.blue)
local ag = Instance.new("UIGradient",aline)
ag.Color=ColorSequence.new({
    ColorSequenceKeypoint.new(0,   Color3.fromRGB(80,100,255)),
    ColorSequenceKeypoint.new(0.5, Color3.fromRGB(190,60,255)),
    ColorSequenceKeypoint.new(1,   Color3.fromRGB(255,60,140)),
})
task.spawn(function()
    local t=0
    while sg.Parent do t=t+0.018; ag.Offset=Vector2.new(math.sin(t)*0.35,0); task.wait(0.1) end
end)

-- Title + window buttons row
newLbl(hdr,UDim2.new(1,-66,0,16),UDim2.new(0,8,0,6),
    "🎹  Auto Piano",11,C.text,Enum.Font.GothamBold)

local function wBtn(ic,col,ox)
    local b=newBtn(hdr,UDim2.new(0,26,0,26),UDim2.new(1,ox,0,4),ic,12,col)
    corner(b,8); return b
end
local minBtn=wBtn("—",Color3.fromRGB(26,26,42),-62)
local clsBtn=wBtn("✕",Color3.fromRGB(168,36,46),-30)

local minimized=false
minBtn.MouseButton1Click:Connect(function()
    ripple(minBtn); minimized=not minimized
    TweenSvc:Create(main,TweenInfo.new(0.25,Enum.EasingStyle.Quart,Enum.EasingDirection.Out),
        {Size=minimized and UDim2.new(0,WIN_W,0,HDR_H) or UDim2.new(0,WIN_W,0,WIN_H)}):Play()
    minBtn.Text=minimized and "▲" or "—"
end)
clsBtn.MouseButton1Click:Connect(function()
    ripple(clsBtn); stopSong(); sg:Destroy()
end)

-- Now-playing song name
local hdrSong = newLbl(hdr,UDim2.new(1,-12,0,13),UDim2.new(0,8,0,25),
    "Select a song…",9,C.muted,Enum.Font.Gotham)

-- Seekbar track
local seekTrack=newFrame(hdr,UDim2.new(1,-16,0,4),UDim2.new(0,8,0,42),Color3.fromRGB(24,24,42))
corner(seekTrack,4)
local seekFill=newFrame(seekTrack,UDim2.new(0,0,1,0),UDim2.new(0,0,0,0),C.blue)
corner(seekFill,4)
local sfg=Instance.new("UIGradient",seekFill)
sfg.Color=ColorSequence.new({
    ColorSequenceKeypoint.new(0,Color3.fromRGB(70,118,242)),
    ColorSequenceKeypoint.new(1,Color3.fromRGB(200,68,242)),
})
-- Thumb dot
local sThumb=newFrame(seekFill,UDim2.new(0,10,0,10),UDim2.new(1,-5,0.5,-5),C.white)
corner(sThumb,8)
local sThStroke=Instance.new("UIStroke",sThumb)
sThStroke.Color=Color3.fromRGB(110,155,255); sThStroke.Thickness=2

-- Time labels
local tCur=newLbl(hdr,UDim2.new(0,28,0,10),UDim2.new(0,8,0,48),"0:00",8,C.muted,Enum.Font.GothamBold)
local tTot=newLbl(hdr,UDim2.new(0,28,0,10),UDim2.new(1,-36,0,48),"0:00",8,C.muted,Enum.Font.GothamBold,Enum.TextXAlignment.Right)

-- Transport controls
-- Layout: [⏮ 40][gap][▶/⏸ 58][gap][⏹ 40][gap][⏭ 40]  centered in WIN_W
local totalBW = 32+6+46+6+32+6+32  -- 160
local tX0 = math.floor((WIN_W - totalBW) / 2)
local function tBtn(ic,col,x,w)
    local b=newBtn(hdr,UDim2.new(0,w,0,34),UDim2.new(0,x,0,66),ic,13,col)
    corner(b,10); return b
end
local prevBtn = tBtn("⏮",Color3.fromRGB(22,22,38), tX0,           32)
local playBtn = tBtn("▶", C.green,                  tX0+38,        46)
local pauBtn  = tBtn("⏸", C.yellow,                 tX0+38,        46)
local stpBtn  = tBtn("⏹", C.red,                    tX0+38+52,     32)
local nextBtn = tBtn("⏭",Color3.fromRGB(22,22,38), tX0+38+52+38,  32)
pauBtn.Visible=false

-- ╔══════════════════════════════════════════════════════════╗
-- ║  BODY  (sidebar + content)                              ║
-- ╚══════════════════════════════════════════════════════════╝
local body=newFrame(main,UDim2.new(1,0,0,BODY_H),UDim2.new(0,0,0,HDR_H),C.bg)

-- ── LEFT SIDEBAR ─────────────────────────────────────────────
local sidebar=newFrame(body,UDim2.new(0,SIDE_W,1,0),UDim2.new(0,0,0,0),C.sidebar)
-- separator line on right edge of sidebar
local sep=newFrame(sidebar,UDim2.new(0,1,1,0),UDim2.new(1,-1,0,0),Color3.fromRGB(28,28,48))

-- Active indicator pill (slides vertically)
local sideIndicator=newFrame(sidebar,UDim2.new(0,3,0,28),UDim2.new(0,0,0.5,-14),C.blue)
corner(sideIndicator,2)

-- Sidebar tab button helper
local sideTabs={}
local function sideTab(icon,tooltip,yPct)
    local b=newBtn(sidebar,UDim2.new(1,0,0,36),UDim2.new(0,0,yPct,0),icon,14,C.sidebar,C.muted)
    b.TextXAlignment=Enum.TextXAlignment.Center; b.Font=Enum.Font.GothamBold
    table.insert(sideTabs,{btn=b,yPct=yPct})
    return b
end

local tabMusic    = sideTab("🎵",  "Music",    0)
local tabSettings = sideTab("⚙️",  "Settings", (BODY_H-44*2-8)/BODY_H )  -- bottom group
local tabReload   = sideTab("↻",   "Reload",   (BODY_H-44)/BODY_H)

-- Position settings+reload at bottom
tabSettings.Position=UDim2.new(0,0,1,-76)
tabReload.Position=UDim2.new(0,0,1,-36)

-- ── CONTENT AREA ─────────────────────────────────────────────
local CONT_W = WIN_W - SIDE_W
local content=newFrame(body,UDim2.new(0,CONT_W,1,0),UDim2.new(0,SIDE_W,0,0),C.bg)
content.ClipsDescendants=true

local function makePage()
    local p=newFrame(content,UDim2.new(1,0,1,0),UDim2.new(0,0,0,0),C.bg)
    p.Visible=false; return p
end

-- ============================================================
-- PAGE: MUSIC
-- ============================================================
local musicPage=makePage(); musicPage.Visible=true

-- Search
local search=Instance.new("TextBox"); search.Parent=musicPage
search.Size=UDim2.new(1,-10,0,28); search.Position=UDim2.new(0,5,0,5)
search.BackgroundColor3=C.surface; search.BorderSizePixel=0
search.Text=""; search.PlaceholderText="🔍  Search…"
search.TextColor3=C.text; search.PlaceholderColor3=C.muted
search.TextSize=10; search.Font=Enum.Font.Gotham; search.ClearTextOnFocus=false
corner(search,8)
local sPad=Instance.new("UIPadding",search)
sPad.PaddingLeft=UDim.new(0,8); sPad.PaddingRight=UDim.new(0,8)
local sStroke=Instance.new("UIStroke",search)
sStroke.Color=Color3.fromRGB(30,30,52); sStroke.Thickness=1
search.Focused:Connect(function()
    TweenSvc:Create(sStroke,TweenInfo.new(0.18),{Color=C.blue,Thickness=1.5}):Play()
end)
search.FocusLost:Connect(function()
    TweenSvc:Create(sStroke,TweenInfo.new(0.18),{Color=Color3.fromRGB(30,30,52),Thickness=1}):Play()
end)

-- Song list
local listScroll=Instance.new("ScrollingFrame"); listScroll.Parent=musicPage
listScroll.Size=UDim2.new(1,-10,0,BODY_H-40-14); listScroll.Position=UDim2.new(0,5,0,38)
listScroll.BackgroundColor3=C.surface; listScroll.BorderSizePixel=0
listScroll.ScrollBarThickness=2; listScroll.ScrollBarImageColor3=C.blue
listScroll.CanvasSize=UDim2.new(0,0,0,0); listScroll.ClipsDescendants=true
corner(listScroll,8)
local listLL=Instance.new("UIListLayout",listScroll)
listLL.Padding=UDim.new(0,3); listLL.SortOrder=Enum.SortOrder.LayoutOrder
local lPad=Instance.new("UIPadding",listScroll)
lPad.PaddingTop=UDim.new(0,4); lPad.PaddingBottom=UDim.new(0,4)
lPad.PaddingLeft=UDim.new(0,4); lPad.PaddingRight=UDim.new(0,4)

-- Status strip
local statusLbl=newLbl(musicPage,UDim2.new(1,-10,0,11),UDim2.new(0,5,1,-12),
    "⏳ Loading…",9,C.muted,Enum.Font.Gotham)

-- ============================================================
-- PAGE: SETTINGS
-- ============================================================
local settingsPage=makePage()

local function settRow(yp,title,h)
    local s=newFrame(settingsPage,UDim2.new(1,-12,0,h or 64),UDim2.new(0,6,0,yp),C.surface)
    corner(s,10)
    newLbl(s,UDim2.new(1,-12,0,16),UDim2.new(0,8,0,6),title,10,C.muted,Enum.Font.GothamBold)
    return s
end

-- Speed
local spRow=settRow(6,"⚡ Playback Speed",58)
local speeds={0.5,0.75,1.0,1.5,2.0}; local spBtns={}; local curSpIdx=3
local function refreshSpBtns()
    for i,b in ipairs(spBtns) do
        TweenSvc:Create(b,TweenInfo.new(0.14),{
            BackgroundColor3=i==curSpIdx and C.blue or Color3.fromRGB(20,20,34),
            TextColor3=i==curSpIdx and C.white or C.muted}):Play()
    end
end
local bw=math.floor((CONT_W-28)/5)-2
for i,sp in ipairs(speeds) do
    local b=newBtn(spRow,UDim2.new(0,bw,0,24),UDim2.new(0,8+(i-1)*(bw+3),0,34),
        sp.."x",9,i==curSpIdx and C.blue or Color3.fromRGB(20,20,34),
        i==curSpIdx and C.white or C.muted)
    corner(b,6); spBtns[i]=b
    b.MouseButton1Click:Connect(function()
        ripple(b,C.blue); curSpIdx=i; playSpeed=sp; refreshSpBtns()
    end)
end

-- Note gap
local ngRow=settRow(70,"🎵 Note Gap (legacy)",58)
local gaps={0.1,0.15,0.2,0.25,0.3}; local gapBtns={}; local curGapIdx=4
local function refreshGapBtns()
    for i,b in ipairs(gapBtns) do
        TweenSvc:Create(b,TweenInfo.new(0.14),{
            BackgroundColor3=i==curGapIdx and C.blue or Color3.fromRGB(20,20,34),
            TextColor3=i==curGapIdx and C.white or C.muted}):Play()
    end
end
for i,g in ipairs(gaps) do
    local b=newBtn(ngRow,UDim2.new(0,bw,0,24),UDim2.new(0,8+(i-1)*(bw+3),0,34),
        g.."s",9,i==curGapIdx and C.blue or Color3.fromRGB(20,20,34),
        i==curGapIdx and C.white or C.muted)
    corner(b,6); gapBtns[i]=b
    b.MouseButton1Click:Connect(function()
        ripple(b,C.blue); curGapIdx=i; noteGap=g; refreshGapBtns()
    end)
end

-- Anti-lag toggle
local alRow=settRow(134,"🚀 Anti-Lag Mode",44)
newLbl(alRow,UDim2.new(1,-80,0,14),UDim2.new(0,8,0,26),
    "Reduces frame drops during playback",9,C.muted,Enum.Font.Gotham)
local alBtn=newBtn(alRow,UDim2.new(0,44,0,22),UDim2.new(1,-52,0,12),
    "ON",10,C.green,C.white)
corner(alBtn,7)
alBtn.MouseButton1Click:Connect(function()
    ripple(alBtn); antiLagOn=not antiLagOn
    alBtn.Text=antiLagOn and "ON" or "OFF"
    TweenSvc:Create(alBtn,TweenInfo.new(0.14),
        {BackgroundColor3=antiLagOn and C.green or Color3.fromRGB(44,44,64)}):Play()
end)

-- About
local abRow=settRow(184,"ℹ️ About",40)
newLbl(abRow,UDim2.new(1,-12,0,24),UDim2.new(0,8,0,18),
    "v7.1 • GitHub sync • Chord engine",9,C.muted,Enum.Font.Gotham)

-- ============================================================
-- TAB SWITCHING
-- ============================================================
local activeTab=1
local pageMap={musicPage,settingsPage}

local function switchTab(n)
    if activeTab==n then return end
    activeTab=n
    for i,p in ipairs(pageMap) do p.Visible=(i==n) end
    -- Slide indicator to active tab button
    local yPositions={0, BODY_H-92, BODY_H-44}
    -- only music (0) gets the indicator at top area; settings/reload at bottom
    local targetY = n==1 and BODY_H*0.5-18 or (n==2 and BODY_H-76+8 or BODY_H-36+8)
    TweenSvc:Create(sideIndicator,TweenInfo.new(0.22,Enum.EasingStyle.Quart,Enum.EasingDirection.Out),
        {Position=UDim2.new(0,0,0,targetY)}):Play()
    -- color active tab icon
    local icons={tabMusic,tabSettings}
    for i,b in ipairs(icons) do
        TweenSvc:Create(b,TweenInfo.new(0.14),
            {TextColor3=i==n and C.blue or C.muted}):Play()
    end
end

tabMusic.MouseButton1Click:Connect(function()    ripple(tabMusic,C.blue);    switchTab(1) end)
tabSettings.MouseButton1Click:Connect(function() ripple(tabSettings,C.blue); switchTab(2) end)
tabReload.MouseButton1Click:Connect(function()
    ripple(tabReload,C.blue)
    tabReload.Text="⌛"
    task.delay(2,function() if tabReload then tabReload.Text="↻" end end)
    loadAllSongs()
end)

-- Set initial icon colors
tabMusic.TextColor3=C.blue
tabSettings.TextColor3=C.muted
tabReload.TextColor3=C.muted
sideIndicator.Position=UDim2.new(0,0,0,BODY_H*0.5-18)

-- ============================================================
-- SONG LIST BUILD
-- ============================================================
local songBtns={}
local function buildList(filter)
    for _,b in ipairs(songBtns) do b:Destroy() end; songBtns={}
    if #songs==0 then
        local e=newLbl(listScroll,UDim2.new(1,0,0,46),nil,
            "No songs — add .json to songs/",10,C.muted,Enum.Font.Gotham,Enum.TextXAlignment.Center)
        e.TextWrapped=true; table.insert(songBtns,e)
        listScroll.CanvasSize=UDim2.new(0,0,0,50); return
    end
    local f=(filter or ""):lower(); local order=0
    for i,song in ipairs(songs) do
        local match=f=="" or song.name:lower():find(f,1,true)
            or (song.category and song.category:lower():find(f,1,true))
        if match then
            order=order+1
            local sel=(i==selIdx)
            local cat=song.category or "Custom"
            local cc=catC[cat] or C.muted

            local row=newBtn(listScroll,UDim2.new(1,0,0,34),nil,"",0,
                sel and Color3.fromRGB(16,34,64) or Color3.fromRGB(16,16,26))
            row.LayoutOrder=order; corner(row,8); row.ClipsDescendants=true
            if sel then
                local st=Instance.new("UIStroke",row)
                st.Color=C.blue; st.Thickness=1.2
            end

            -- accent bar
            local bar=newFrame(row,UDim2.new(0,3,0,24),UDim2.new(0,0,0.5,-12),cc); corner(bar,2)

            -- name
            newLbl(row,UDim2.new(1,-62,0,15),UDim2.new(0,8,0,4),song.name,10,
                sel and Color3.fromRGB(210,228,255) or C.text,
                sel and Enum.Font.GothamBold or Enum.Font.Gotham)

            -- bpm
            local sub=song.bpm and ("♩"..song.bpm) or ""
            newLbl(row,UDim2.new(1,-62,0,11),UDim2.new(0,8,0,20),sub,8,C.muted,Enum.Font.Gotham)

            -- cat pill
            local cp=newLbl(row,UDim2.new(0,42,0,14),UDim2.new(1,-48,0.5,-7),
                cat,7,C.white,Enum.Font.GothamBold,Enum.TextXAlignment.Center)
            cp.BackgroundColor3=cc; cp.BackgroundTransparency=0.28
            cp.BorderSizePixel=0; corner(cp,5)

            table.insert(songBtns,row)
            row.MouseButton1Click:Connect(function()
                ripple(row,cc); selIdx=i
                hdrSong.Text=song.name
                if song.notes then
                    local t=0; for _,n in ipairs(song.notes) do t=t+(n.d or 200) end
                    tTot.Text=formatTime(t)
                else tTot.Text="—" end
                buildList(search.Text)
            end)
        end
    end
    listLL:ApplyLayout()
    listScroll.CanvasSize=UDim2.new(0,0,0,listLL.AbsoluteContentSize.Y+8)
end

search:GetPropertyChangedSignal("Text"):Connect(function() buildList(search.Text) end)

-- ============================================================
-- SEEKBAR UPDATER
-- ============================================================
task.spawn(function()
    while sg.Parent do
        if totalMs>0 then
            local pct=math.clamp(elapsedMs/totalMs,0,1)
            seekFill.Size=UDim2.new(pct,0,1,0)
            tCur.Text=formatTime(elapsedMs)
        end
        task.wait(0.1)
    end
end)

-- ============================================================
-- PLAY ENGINE
-- ============================================================
local function playSong(idx)
    stopSong()
    local song=songs[idx]; if not song then return end
    isPlaying=true; isPaused=false

    hdrSong.Text=song.name
    statusLbl.Text="▶  "..song.name; statusLbl.TextColor3=Color3.fromRGB(75,205,105)
    playBtn.Visible=false; pauBtn.Visible=true

    playThread=task.spawn(function()
        if song.notes and type(song.notes)=="table" and #song.notes>0 then
            local groups=buildChordGroups(song.notes)
            totalMs=0
            for _,g in ipairs(groups) do totalMs=totalMs+(g.delay or 200) end
            tTot.Text=formatTime(totalMs); elapsedMs=0

            for _,group in ipairs(groups) do
                while isPaused do task.wait(0.04) end
                if not isPlaying then break end
                playChord(group.keys)
                local dMs=(group.delay or 200)/playSpeed
                elapsedMs=elapsedMs+dMs
                task.wait(math.max(dMs/1000,0.04))
            end
        else
            local notes={}
            for t in (song.sheet or ""):gmatch("%S+") do
                if t~="|" then table.insert(notes,t) end end
            totalMs=#notes*(noteGap/playSpeed)*1000; elapsedMs=0
            tTot.Text=formatTime(totalMs)
            for _,note in ipairs(notes) do
                while isPaused do task.wait(0.04) end
                if not isPlaying then break end
                local kc,sh=resolveKey(note)
                if kc then task.spawn(pressKey,kc,sh) end
                local gMs=noteGap/playSpeed
                elapsedMs=elapsedMs+gMs*1000
                task.wait(math.max(gMs,0.04))
            end
        end

        isPlaying=false; elapsedMs=0; totalMs=0
        seekFill.Size=UDim2.new(0,0,1,0)
        playBtn.Visible=true; pauBtn.Visible=false
        TweenSvc:Create(playBtn,TweenInfo.new(0.15),{BackgroundColor3=C.green}):Play()
        statusLbl.Text="✓  "..song.name; statusLbl.TextColor3=C.muted
        tCur.Text="0:00"; tTot.Text="0:00"
    end)
end

-- ── Button logic ─────────────────────────────────────────────
playBtn.MouseButton1Click:Connect(function()
    ripple(playBtn,C.green)
    if #songs==0 then statusLbl.Text="⚠ No songs!"; return end
    if isPaused then
        isPaused=false; playBtn.Visible=false; pauBtn.Visible=true
        statusLbl.Text="▶  "..songs[selIdx].name; statusLbl.TextColor3=Color3.fromRGB(75,205,105)
    else playSong(selIdx) end
end)

pauBtn.MouseButton1Click:Connect(function()
    ripple(pauBtn,C.yellow)
    if isPlaying and not isPaused then
        isPaused=true; pauBtn.Visible=false; playBtn.Visible=true
        TweenSvc:Create(playBtn,TweenInfo.new(0.15),{BackgroundColor3=C.green}):Play()
        statusLbl.Text="⏸  "..songs[selIdx].name; statusLbl.TextColor3=C.yellow
    end
end)

stpBtn.MouseButton1Click:Connect(function()
    ripple(stpBtn,C.red); stopSong()
    seekFill.Size=UDim2.new(0,0,1,0)
    playBtn.Visible=true; pauBtn.Visible=false
    TweenSvc:Create(playBtn,TweenInfo.new(0.15),{BackgroundColor3=C.green}):Play()
    statusLbl.Text="⏹  Stopped"; statusLbl.TextColor3=C.muted
    tCur.Text="0:00"
end)

prevBtn.MouseButton1Click:Connect(function()
    ripple(prevBtn)
    if selIdx>1 then selIdx=selIdx-1; buildList(search.Text)
        if isPlaying then playSong(selIdx) end end
end)

nextBtn.MouseButton1Click:Connect(function()
    ripple(nextBtn)
    if selIdx<#songs then selIdx=selIdx+1; buildList(search.Text)
        if isPlaying then playSong(selIdx) end end
end)

-- ============================================================
-- LOADER
-- ============================================================
function loadAllSongs()
    songs={}; buildList("")
    statusLbl.Text="⏳ Fetching…"; statusLbl.TextColor3=C.blue
    hdrSong.Text="Loading songs…"
    task.spawn(function()
        local raw=fetchRaw(GITHUB_BASE.."/index.json")
        if not raw then
            statusLbl.Text="❌ GitHub unreachable"; statusLbl.TextColor3=C.red; return end
        local ok,index=pcall(HttpSvc.JSONDecode,HttpSvc,raw)
        if not ok or type(index)~="table" or #index==0 then
            statusLbl.Text="⚠ index.json empty"; statusLbl.TextColor3=C.yellow; return end
        local loaded=0
        for _,fn in ipairs(index) do
            local d=fetchJSON(GITHUB_BASE.."/songs/"..fn)
            if d and d.name and (d.sheet or d.notes) then
                table.insert(songs,d); loaded=loaded+1
                statusLbl.Text="⏳ "..loaded.."/"..#index
                if loaded==1 then
                    hdrSong.Text=songs[1].name
                    if songs[1].notes then
                        local t=0
                        for _,n in ipairs(songs[1].notes) do t=t+(n.d or 200) end
                        tTot.Text=formatTime(t)
                    end
                end
                buildList(search.Text)
            end
            task.wait(0.04)
        end
        if loaded>0 then
            statusLbl.Text="✓  "..loaded.." songs"
            statusLbl.TextColor3=Color3.fromRGB(75,205,105)
        else
            statusLbl.Text="❌ No songs"; statusLbl.TextColor3=C.red
        end
        buildList("")
    end)
end

loadAllSongs()
print("🎹 Auto Piano v7.1 — left sidebar ready!")
