--[[  Fly / NoClip / GodMode (LinearVelocity + AlignOrientation)
     - Engine baru (tanpa BodyGyro/BodyVelocity utk gerak)
     - CoreGui ON by default
     - Print aman: dibungkus log(), default MUTE (kecuali di Studio)
     - Toggle log: tekan M
]]

-- ====== SERVICES ======
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CoreGui = game:GetService("CoreGui")
local HttpService = game:GetService("HttpService")

local Player = Players.LocalPlayer
local Character = Player.Character or Player.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")

-- ====== CONFIG ======
local USE_COREGUI = true
local SAVE_PREFS  = false
local CFG_NAME    = "flycfg.json"

local ACCEL = 28
local DAMP  = 14
local SPEED_MIN, SPEED_MAX = 1, 200

-- ====== LOG AMAN ======
local LOG_ENABLED = RunService:IsStudio() -- di Studio: ON, live: OFF
local function log(...) if LOG_ENABLED then print(...) end end

-- ====== STATE ======
local Flying = false
local NoClipping = false
local GodMode = false
local Speed = 60
local NetworkMethod = "Linear" -- "Linear" | "CFrame" | "Humanoid"

-- New engine instances
local Align, LinVel, Attach -- AlignOrientation, LinearVelocity, Attachment
local curVel = Vector3.zero

-- Legacy refs (biar kode lama tetap jalan mulus)
local BodyGyro, BodyVelocity = nil, nil -- mapped ke Align/LinVel

-- Cleanup trackers
local conns, temps = {}, {}
local function trackConn(c) table.insert(conns, c); return c end
local function trackTemp(i) table.insert(temps, i); return i end
local function DisconnectAll()
  for i=#conns,1,-1 do local c=conns[i]; if c and c.Connected then c:Disconnect() end; conns[i]=nil end
  for i=#temps,1,-1 do local o=temps[i]; if o and o.Destroy then o:Destroy() end; temps[i]=nil end
end

-- ====== PREFS (opsional) ======
local speedLabel
local function SetSpeed(s)
  Speed = math.clamp(math.floor(s), SPEED_MIN, SPEED_MAX)
  if speedLabel then speedLabel.Text = ("✈️ Speed: %d"):format(Speed) end
end
local function SavePrefs()
  if not SAVE_PREFS or not writefile then return end
  local ok, enc = pcall(function() return HttpService:JSONEncode({Speed=Speed, Method=NetworkMethod}) end)
  if ok then writefile(CFG_NAME, enc) end
end
local function LoadPrefs()
  if not SAVE_PREFS or not (readfile and isfile and isfile(CFG_NAME)) then return end
  local ok, data = pcall(function() return HttpService:JSONDecode(readfile(CFG_NAME)) end)
  if ok and data then SetSpeed(data.Speed or Speed); NetworkMethod = data.Method or NetworkMethod end
end

-- ====== HELPERS ======
local function SnapToGround(maxDist)
  maxDist = maxDist or 200
  if not HumanoidRootPart then return end
  local params = RaycastParams.new()
  params.FilterType = Enum.RaycastFilterType.Blacklist
  params.FilterDescendantsInstances = {Character}
  local r = workspace:Raycast(HumanoidRootPart.Position, Vector3.new(0,-maxDist,0), params)
  if r then HumanoidRootPart.CFrame = CFrame.new(r.Position + Vector3.new(0,5,0)) end
end

-- ====== GODMODE ======
local OriginalMaxHealth = nil
local HealthConnection, HeartbeatConnection, StateConnection

local function StartGodMode()
  if not Humanoid then return end
  if not OriginalMaxHealth then OriginalMaxHealth = Humanoid.MaxHealth end
  Humanoid.MaxHealth = 9e9
  Humanoid.Health = Humanoid.MaxHealth

  if HealthConnection then HealthConnection:Disconnect() end
  HealthConnection = trackConn(Humanoid.HealthChanged:Connect(function()
    if GodMode and Humanoid then Humanoid.Health = Humanoid.MaxHealth end
  end))

  if StateConnection then StateConnection:Disconnect() end
  StateConnection = trackConn(Humanoid.StateChanged:Connect(function(_, new)
    if GodMode and new == Enum.HumanoidStateType.Dead then
      Humanoid:ChangeState(Enum.HumanoidStateType.Running)
      Humanoid.Health = Humanoid.MaxHealth
    end
  end))

  -- NOTE: Fall protection masih pakai BodyVelocity kecil (cukup aman utk test)
  if HeartbeatConnection then HeartbeatConnection:Disconnect() end
  HeartbeatConnection = trackConn(RunService.Heartbeat:Connect(function()
    if not (GodMode and HumanoidRootPart) then return end
    if HumanoidRootPart.AssemblyLinearVelocity.Y < -60 then
      local bv = HumanoidRootPart:FindFirstChild("FallProtection")
      if not bv then
        bv = trackTemp(Instance.new("BodyVelocity"))
        bv.Name = "FallProtection"
        bv.MaxForce = Vector3.new(0, math.huge, 0)
        bv.Velocity = Vector3.new(0, -25, 0)
        bv.Parent = HumanoidRootPart
        game:GetService("Debris"):AddItem(bv, 1)
      end
    end
  end))

  log("🛡️ GodMode ON")
end

local function StopGodMode()
  if OriginalMaxHealth and Humanoid then
    Humanoid.MaxHealth = OriginalMaxHealth
    Humanoid.Health = OriginalMaxHealth
  end
  if HealthConnection then HealthConnection:Disconnect(); HealthConnection=nil end
  if HeartbeatConnection then HeartbeatConnection:Disconnect(); HeartbeatConnection=nil end
  if StateConnection then StateConnection:Disconnect(); StateConnection=nil end
  local fp = HumanoidRootPart and HumanoidRootPart:FindFirstChild("FallProtection")
  if fp then fp:Destroy() end
  GodMode = false
  log("🩸 GodMode OFF")
end

-- ====== FLY (ENGINE BARU) ======
local function EnsureAttachments()
  if not Attach or not Attach.Parent then
    Attach = trackTemp(Instance.new("Attachment"))
    Attach.Name = "Fly_Attachment"
    Attach.Parent = HumanoidRootPart
  end
end

local function StartFlying_Linear()
  EnsureAttachments()
  if not LinVel then
    LinVel = trackTemp(Instance.new("LinearVelocity"))
    LinVel.Attachment0 = Attach
    LinVel.MaxForce = math.huge
    LinVel.VectorVelocity = Vector3.zero
    LinVel.Parent = HumanoidRootPart
  end
  if not Align then
    Align = trackTemp(Instance.new("AlignOrientation"))
    Align.Mode = Enum.OrientationAlignmentMode.OneAttachment
    Align.Attachment0 = Attach
    Align.MaxTorque = math.huge
    Align.Responsiveness = 50
    Align.Parent = HumanoidRootPart
  end
  -- Map legacy refs:
  BodyVelocity, BodyGyro = LinVel, Align
end

local function StartFlying_CFrame()
  if Humanoid then Humanoid.PlatformStand = true end
end

local function StartFlying_Humanoid()
  -- Hybrid: tetap pakai LinearVelocity utk dorong halus, tapi orient biar Humanoid
  EnsureAttachments()
  if not LinVel then
    LinVel = trackTemp(Instance.new("LinearVelocity"))
    LinVel.Attachment0 = Attach
    LinVel.MaxForce = math.huge
    LinVel.VectorVelocity = Vector3.zero
    LinVel.Parent = HumanoidRootPart
  end
  if Humanoid then Humanoid.PlatformStand = true end
  BodyVelocity = LinVel
end

local function StartFlying()
  if NetworkMethod == "Linear" then
    StartFlying_Linear()
  elseif NetworkMethod == "CFrame" then
    StartFlying_CFrame()
  elseif NetworkMethod == "Humanoid" then
    StartFlying_Humanoid()
  end
end

local function StopFlying()
  if Align then Align:Destroy(); Align=nil end
  if LinVel then LinVel:Destroy(); LinVel=nil end
  if Attach then Attach:Destroy(); Attach=nil end
  BodyGyro, BodyVelocity = nil, nil
  if Humanoid then
    Humanoid.PlatformStand = false
    Humanoid:ChangeState(Enum.HumanoidStateType.Running)
  end
  SnapToGround(200)
end

-- ====== NOCLIP ======
local OriginalCanCollide = {}
local function StartNoClip()
  if not Character then return end
  for _, part in ipairs(Character:GetChildren()) do
    if part:IsA("BasePart") then
      OriginalCanCollide[part] = part.CanCollide
      part.CanCollide = false
    end
  end
  NoClipping = true
end
local function StopNoClip()
  if not Character then return end
  for _, part in ipairs(Character:GetChildren()) do
    if part:IsA("BasePart") and OriginalCanCollide[part] ~= nil then
      part.CanCollide = OriginalCanCollide[part]
    end
  end
  table.clear(OriginalCanCollide)
  NoClipping = false
end
local function MaintainNoClip()
  if not (NoClipping and Character) then return end
  for _, part in ipairs(Character:GetChildren()) do
    if part:IsA("BasePart") then part.CanCollide = false end
  end
end

-- ====== SETTERS (sinkron UI) ======
local MainUI, MainFrame, noclipButton, godButton
local GuiVisible = true

local function SetNoClip(on)
  if on == NoClipping then return end
  if on then StartNoClip() else StopNoClip() end
  if noclipButton then
    noclipButton.Text = on and "✅ NoClip: ON" or "🚫 NoClip: OFF"
    TweenService:Create(noclipButton, TweenInfo.new(0.2), {
      BackgroundColor3 = on and Color3.fromRGB(0,150,50) or Color3.fromRGB(70,70,70)
    }):Play()
  end
  log(on and "🚫 NoClip: ON" or "🚫 NoClip: OFF")
end

local function SetGod(on)
  if on == GodMode then return end
  GodMode = on
  if on then StartGodMode() else StopGodMode() end
  if godButton then
    godButton.Text = on and "🛡️ GodMode: ON" or "🛡️ GodMode: OFF"
    TweenService:Create(godButton, TweenInfo.new(0.2), {
      BackgroundColor3 = on and Color3.fromRGB(0,150,255) or Color3.fromRGB(70,70,70)
    }):Play()
  end
end

local function SetFly(on)
  if on == Flying then return end
  Flying = on
  if on then StartFlying() else StopFlying() end
  log(on and "🚀 Flying: ON" or "🚀 Flying: OFF")
end

-- ====== GUI ======
local function toggleGUI()
  GuiVisible = not GuiVisible
  if not MainFrame then return end
  local pos = GuiVisible and UDim2.new(0.02,0,0.15,0) or UDim2.new(-0.5,0,0.15,0)
  TweenService:Create(MainFrame, TweenInfo.new(0.3, Enum.EasingStyle.Quart, Enum.EasingDirection.Out), {Position=pos}):Play()
end

local function buildMainGUI()
  if MainUI then MainUI:Destroy() end
  MainUI = Instance.new("ScreenGui")
  MainUI.Name = "FlyControlUI"
  MainUI.ResetOnSpawn = false
  if USE_COREGUI then MainUI.Parent = CoreGui else MainUI.Parent = Player:WaitForChild("PlayerGui") end

  MainFrame = Instance.new("Frame")
  MainFrame.Size = UDim2.new(0,320,0,320)
  MainFrame.Position = UDim2.new(0.02,0,0.15,0)
  MainFrame.BackgroundColor3 = Color3.fromRGB(25,25,25)
  MainFrame.BackgroundTransparency = 0.1
  MainFrame.BorderSizePixel = 0
  MainFrame.Parent = MainUI
  local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0,8); corner.Parent = MainFrame

  local title = Instance.new("TextLabel")
  title.Size = UDim2.new(1,0,0,35)
  title.BackgroundColor3 = Color3.fromRGB(35,35,35)
  title.Text = "🚀 Fly/NoClip/God (LinearVelocity)"
  title.TextColor3 = Color3.fromRGB(0,255,150)
  title.Font = Enum.Font.GothamBold
  title.TextSize = 13
  title.Parent = MainFrame
  local tCorner = Instance.new("UICorner"); tCorner.CornerRadius = UDim.new(0,8); tCorner.Parent = title

  -- drag
  local dragging, dragStart, startPos = false, nil, nil
  title.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
      dragging = true; dragStart = input.Position; startPos = MainFrame.Position
    end
  end)
  title.InputChanged:Connect(function(input)
    if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
      local delta = input.Position - dragStart
      MainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X, startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
  end)
  title.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then dragging = false end
  end)

  -- method
  local methodSection = Instance.new("Frame")
  methodSection.Size = UDim2.new(1,-10,0,60)
  methodSection.Position = UDim2.new(0,5,0,45)
  methodSection.BackgroundColor3 = Color3.fromRGB(35,35,35)
  methodSection.BackgroundTransparency = 0.3
  methodSection.BorderSizePixel = 0
  methodSection.Parent = MainFrame

  local methodLabel = Instance.new("TextLabel")
  methodLabel.Size = UDim2.new(1,0,0,20)
  methodLabel.Position = UDim2.new(0,0,0,5)
  methodLabel.BackgroundTransparency = 1
  methodLabel.Text = "🌐 Method"
  methodLabel.TextColor3 = Color3.new(1,1,1)
  methodLabel.Font = Enum.Font.Gotham
  methodLabel.TextSize = 11
  methodLabel.Parent = methodSection

  local methodButtons = Instance.new("Frame")
  methodButtons.Size = UDim2.new(1,-10,0,30)
  methodButtons.Position = UDim2.new(0,5,0,25)
  methodButtons.BackgroundTransparency = 1
  methodButtons.Parent = methodSection
  local layout = Instance.new("UIListLayout")
  layout.FillDirection = Enum.FillDirection.Horizontal
  layout.Padding = UDim.new(0,3)
  layout.Parent = methodButtons

  local methods = {
    {name="Linear",   method="Linear",   color=Color3.fromRGB(0,150,50)},
    {name="CFrame",   method="CFrame",   color=Color3.fromRGB(255,150,0)},
    {name="Humanoid", method="Humanoid", color=Color3.fromRGB(255,50,50)},
  }
  local methodBtns = {}
  for _, m in ipairs(methods) do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0.33,-2,1,0)
    btn.BackgroundColor3 = (m.method==NetworkMethod) and m.color or Color3.fromRGB(60,60,60)
    btn.Text = m.name; btn.TextColor3 = Color3.new(1,1,1); btn.Font = Enum.Font.Gotham; btn.TextSize = 9; btn.BorderSizePixel = 0
    btn.Parent = methodButtons
    local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(0,4); bc.Parent = btn
    methodBtns[m.method] = {button=btn, color=m.color}
    btn.MouseButton1Click:Connect(function()
      for _,d in pairs(methodBtns) do d.button.BackgroundColor3 = Color3.fromRGB(60,60,60) end
      btn.BackgroundColor3 = m.color
      NetworkMethod = m.method
      SavePrefs()
      if Flying then SetFly(false); task.wait(); SetFly(true) end
    end)
  end

  -- speed
  local speedSection = Instance.new("Frame")
  speedSection.Size = UDim2.new(1,-10,0,80)
  speedSection.Position = UDim2.new(0,5,0,110)
  speedSection.BackgroundColor3 = Color3.fromRGB(35,35,35)
  speedSection.BackgroundTransparency = 0.3
  speedSection.BorderSizePixel = 0
  speedSection.Parent = MainFrame

  speedLabel = Instance.new("TextLabel")
  speedLabel.Size = UDim2.new(1,0,0,25)
  speedLabel.Position = UDim2.new(0,0,0,5)
  speedLabel.BackgroundTransparency = 1
  speedLabel.Text = ("✈️ Speed: %d"):format(Speed)
  speedLabel.TextColor3 = Color3.new(1,1,1)
  speedLabel.Font = Enum.Font.Gotham
  speedLabel.TextSize = 12
  speedLabel.Parent = speedSection

  local sliderBg = Instance.new("Frame")
  sliderBg.Size = UDim2.new(1,-20,0,20)
  sliderBg.Position = UDim2.new(0,10,0,30)
  sliderBg.BackgroundColor3 = Color3.fromRGB(50,50,50)
  sliderBg.BorderSizePixel = 0
  sliderBg.Parent = speedSection
  local sCorner = Instance.new("UICorner"); sCorner.CornerRadius = UDim.new(0,10); sCorner.Parent = sliderBg

  local slider = Instance.new("Frame")
  slider.Size = UDim2.new(Speed/100,0,1,0)
  slider.BackgroundColor3 = Color3.fromRGB(0,150,255)
  slider.BorderSizePixel = 0
  slider.Parent = sliderBg
  local sliderCorner = Instance.new("UICorner"); sliderCorner.CornerRadius = UDim.new(0,10); sliderCorner.Parent = slider

  local knob = Instance.new("TextButton")
  knob.Size = UDim2.new(0,20,0,20)
  knob.Position = UDim2.new(Speed/100,-10,0,0)
  knob.BackgroundColor3 = Color3.new(1,1,1)
  knob.Text = ""
  knob.BorderSizePixel = 0
  knob.Parent = sliderBg
  local knobCorner = Instance.new("UICorner"); knobCorner.CornerRadius = UDim.new(1,0); knobCorner.Parent = knob

  local draggingSlider = false
  knob.MouseButton1Down:Connect(function() draggingSlider = true end)
  UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then draggingSlider=false; SavePrefs() end
  end)
  UserInputService.InputChanged:Connect(function(input)
    if draggingSlider and input.UserInputType == Enum.UserInputType.MouseMovement then
      local mouse = Players.LocalPlayer:GetMouse()
      local relX = mouse.X - sliderBg.AbsolutePosition.X
      local pct  = math.clamp(relX / sliderBg.AbsoluteSize.X, 0, 1)
      SetSpeed(pct * 100)
      slider.Size = UDim2.new(pct,0,1,0)
      knob.Position = UDim2.new(pct,-10,0,0)
    end
  end)

  -- NoClip
  local noclipSection = Instance.new("Frame")
  noclipSection.Size = UDim2.new(1,-10,0,60)
  noclipSection.Position = UDim2.new(0,5,0,195)
  noclipSection.BackgroundColor3 = Color3.fromRGB(35,35,35)
  noclipSection.BackgroundTransparency = 0.3
  noclipSection.BorderSizePixel = 0
  noclipSection.Parent = MainFrame

  noclipButton = Instance.new("TextButton")
  noclipButton.Size = UDim2.new(1,-20,0,35)
  noclipButton.Position = UDim2.new(0,10,0,10)
  noclipButton.BackgroundColor3 = Color3.fromRGB(70,70,70)
  noclipButton.TextColor3 = Color3.new(1,1,1)
  noclipButton.Text = "🚫 NoClip: OFF"
  noclipButton.Font = Enum.Font.GothamBold
  noclipButton.TextSize = 12
  noclipButton.BorderSizePixel = 0
  noclipButton.Parent = noclipSection
  local ncCorner = Instance.new("UICorner"); ncCorner.CornerRadius = UDim.new(0,6); ncCorner.Parent = noclipButton
  noclipButton.MouseButton1Click:Connect(function() SetNoClip(not NoClipping) end)

  -- GodMode
  local godSection = Instance.new("Frame")
  godSection.Size = UDim2.new(1,-10,0,60)
  godSection.Position = UDim2.new(0,5,0,260)
  godSection.BackgroundColor3 = Color3.fromRGB(35,35,35)
  godSection.BackgroundTransparency = 0.3
  godSection.BorderSizePixel = 0
  godSection.Parent = MainFrame

  godButton = Instance.new("TextButton")
  godButton.Size = UDim2.new(1,-20,0,35)
  godButton.Position = UDim2.new(0,10,0,10)
  godButton.BackgroundColor3 = Color3.fromRGB(70,70,70)
  godButton.TextColor3 = Color3.new(1,1,1)
  godButton.Text = "🛡️ GodMode: OFF"
  godButton.Font = Enum.Font.GothamBold
  godButton.TextSize = 12
  godButton.BorderSizePixel = 0
  godButton.Parent = godSection
  local gdCorner = Instance.new("UICorner"); gdCorner.CornerRadius = UDim.new(0,6); gdCorner.Parent = godButton
  godButton.MouseButton1Click:Connect(function() SetGod(not GodMode) end)
end

-- ====== INPUT ======
local lastTP = 0
trackConn(UserInputService.InputBegan:Connect(function(input, gpe)
  if gpe then return end
  if input.KeyCode == Enum.KeyCode.F then
    SetFly(not Flying)
  elseif input.KeyCode == Enum.KeyCode.N then
    SetNoClip(not NoClipping)
  elseif input.KeyCode == Enum.KeyCode.H then
    SetGod(not GodMode)
  elseif input.KeyCode == Enum.KeyCode.G then
    toggleGUI()
  elseif input.KeyCode == Enum.KeyCode.M then
    LOG_ENABLED = not LOG_ENABLED
  elseif input.KeyCode == Enum.KeyCode.T then
    local now = tick()
    if now - lastTP > 0.2 then
      lastTP = now
      local mouse = Players.LocalPlayer:GetMouse()
      if mouse.Hit and HumanoidRootPart then
        HumanoidRootPart.CFrame = CFrame.new(mouse.Hit.Position + Vector3.new(0,5,0))
        log("📍 Teleported.")
      end
    end
  end
end))

-- ====== MOVEMENT LOOP (inertia + engine baru) ======
trackConn(RunService.RenderStepped:Connect(function(dt)
  if not Character or not Character.Parent or not HumanoidRootPart or not HumanoidRootPart:IsDescendantOf(Character) then
    return
  end

  if Flying then
    local cam = workspace.CurrentCamera
    local move = Vector3.zero
    if UserInputService:IsKeyDown(Enum.KeyCode.W) then move += cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.S) then move -= cam.CFrame.LookVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.A) then move -= cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.D) then move += cam.CFrame.RightVector end
    if UserInputService:IsKeyDown(Enum.KeyCode.Space) then move += Vector3.yAxis end
    if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then move -= Vector3.yAxis end

    local target = (move.Magnitude > 0) and move.Unit * Speed or Vector3.zero
    local toTarget = target - curVel
    curVel = curVel + toTarget * math.clamp(ACCEL * dt, 0, 1)

    if NetworkMethod == "Linear" then
      if LinVel and Align then
        LinVel.VectorVelocity = curVel
        Align.CFrame = cam.CFrame
      end
    elseif NetworkMethod == "CFrame" then
      if move.Magnitude > 0 then
        local newPos = HumanoidRootPart.Position + curVel * dt
        local cfTarget = CFrame.new(newPos, newPos + cam.CFrame.LookVector)
        local alpha = 1 - math.exp(-DAMP * dt)
        HumanoidRootPart.CFrame = HumanoidRootPart.CFrame:Lerp(cfTarget, alpha)
      end
    elseif NetworkMethod == "Humanoid" then
      if LinVel then LinVel.VectorVelocity = curVel end
      if move.Magnitude > 0 then
        HumanoidRootPart.CFrame = CFrame.new(HumanoidRootPart.Position, HumanoidRootPart.Position + cam.CFrame.LookVector)
      end
    end
  else
    curVel = Vector3.zero
  end

  MaintainNoClip()
end))

-- ====== RESPAWN ======
trackConn(Player.CharacterAdded:Connect(function(newChar)
  DisconnectAll()
  Character = newChar
  Humanoid = Character:WaitForChild("Humanoid")
  HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")

  Flying = false; NoClipping = false; GodMode = false
  curVel = Vector3.zero
  if Align then Align:Destroy(); Align=nil end
  if LinVel then LinVel:Destroy(); LinVel=nil end
  if Attach then Attach:Destroy(); Attach=nil end
  log("🔄 Respawn: state reset")
end))

-- ====== INIT ======
LoadPrefs()
buildMainGUI()
log("🚀 Controls: F=Fly, N=NoClip, H=God, G=GUI, T=Teleport, M=Toggle Log | Method: "..NetworkMethod)
