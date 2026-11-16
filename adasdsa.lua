-- LOAD MAP

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local cloneref = cloneref or function(Instance)
    return Instance
end

-- SERVICES

local Players = cloneref(game:GetService("Players"))
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))
local VirtualInputManager = cloneref(game:GetService("VirtualInputManager"))
local RunService = cloneref(game:GetService("RunService"))

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
local BB = ReplicatedStorage:WaitForChild("BB")
local Ride = BB:WaitForChild("Ride")
local TrainRemote = Ride:WaitForChild("TrainRemote")
local Pets = BB:WaitForChild("Pets")
local PetsRemote = Pets:WaitForChild("PetsRemote")

-- CONFIG

local Env = getgenv()
local Config = Env.Config or {
    ["Auto Treadmill"] = false,
    ["Press Delay"] = 0.04,
    ["Run Cooldown"] = 1.2,
    ["Spot Distance"] = 18,
    ["Pet Id"] = 0,
    ["Auto Sell Pet"] = false,
    ["Sell Pet Ids"] = {},
    ["Sell Delay"] = 1.2,
    ["Auto Farm Pet"] = false,
    ["Farm Pet Id"] = 0,
}
Env.Config = Config

local Gen = (Env.__BBGen or 0) + 1
Env.__BBGen = Gen
Env.__BBTrainMaxed = Env.__BBTrainMaxed or {}
Env.__BBTrainPickTries = Env.__BBTrainPickTries or 0

-- DISCONNECT PREVIOUS RUNTIME

local OldStep = Env.__BBStepConn
if OldStep then
    pcall(function()
        OldStep:Disconnect()
    end)
end

local OldConns = Env.__BBConns or Env.__BBConnections
if type(OldConns) == "table" then
    for _, Conn in ipairs(OldConns) do
        pcall(function()
            Conn:Disconnect()
        end)
    end
end

local Conns = {}
Env.__BBConns = Conns
Env.__BBConnections = Conns

-- HELPERS

local KEYCODES = { Enum.KeyCode.Q, Enum.KeyCode.E, Enum.KeyCode.R, Enum.KeyCode.T }
local KeyUpPending = {}

local function IsTrainActive()
    local Gui = PlayerGui:FindFirstChild("BBTrainKeys")
    return Gui ~= nil and Gui.Enabled == true
end

local function IsRunActive()
    local Gui = PlayerGui:FindFirstChild("BBRun4")
    return Gui ~= nil and Gui.Enabled == true
end

local function IsStartBarOpen()
    local Gui = PlayerGui:FindFirstChild("BBStart3")
    return Gui ~= nil and Gui.Enabled == true
end

local function GetRootPart()
    local Character = LocalPlayer.Character
    return Character and Character:FindFirstChild("HumanoidRootPart")
end

local function ReleaseKey(KeyCode)
    KeyUpPending[KeyCode] = nil
    pcall(VirtualInputManager.SendKeyEvent, VirtualInputManager, false, KeyCode, false, game)
end

local function PressKey(KeyCode)
    pcall(VirtualInputManager.SendKeyEvent, VirtualInputManager, true, KeyCode, false, game)

    if KeyUpPending[KeyCode] then
        return
    end

    KeyUpPending[KeyCode] = true
    task.delay(0.02, ReleaseKey, KeyCode)
end

local function GetConnect(Target)
    local Clicked = false
    local Events = { "Activated", "MouseButton1Down", "MouseButton1Click", "MouseButton1Up" }

    for _, EventName in next, Events do
        local Ok, Connections = pcall(getconnections, Target[EventName])
        if Ok and type(Connections) == "table" then
            for _, Connection in next, Connections do
                if type(Connection.Function) == "function" then
                    local Fired = pcall(Connection.Function)
                    Clicked = Clicked or Fired
                end
            end
        end
    end

    return Clicked
end

local function ClosePicker()
    local Gui = PlayerGui:FindFirstChild("BBTrainPick")
    local X = Gui and Gui:FindFirstChild("X", true)

    if X then
        if not GetConnect(X) then
            pcall(function() X.Activated:Fire() end)
            pcall(function() X.MouseButton1Click:Fire() end)
        end
    end

    pcall(TrainRemote.FireServer, TrainRemote, "Stop")
end

-- TRAIN RUNTIME: module API stays cached for this client session.

local function ResolveTrain()
    local Cached = Env.__BBTrainRuntime
    if type(Cached) == "table" and type(rawget(Cached, "press")) == "function" then
        return Cached.press, Cached.state
    end

    local Client = ReplicatedStorage:FindFirstChild("BB")
        and ReplicatedStorage.BB:FindFirstChild("Ride")
        and ReplicatedStorage.BB.Ride:FindFirstChild("Client")
    local Module = Client and Client:FindFirstChild("TrainKeys")
    if not Module then
        return nil
    end

    local Ok, TrainKeys = pcall(require, Module)
    if not Ok or type(TrainKeys) ~= "table" then
        return nil
    end

    local State
    local OkUp, Ups = pcall(getupvalues, TrainKeys.pressing)
    if OkUp and type(Ups) == "table" then
        for _, Value in next, Ups do
            if type(Value) == "table" and rawget(Value, "seq") ~= nil and rawget(Value, "idx") ~= nil then
                State = Value
                break
            end
        end
    end
    if not State then
        return nil
    end

    local Press
    local Start = TrainKeys.start
    local OkDirect, StartUps = pcall(getupvalues, Start)
    if OkDirect and type(StartUps) == "table" then
        local Candidate = StartUps[11]
        if type(Candidate) == "function" then
            local OkName, Name = pcall(debug.info, Candidate, "n")
            if OkName and Name == "press" then
                Press = Candidate
            end
        end

        if not Press then
            for _, Value in next, StartUps do
                if type(Value) == "function" then
                    local OkName, Name = pcall(debug.info, Value, "n")
                    if OkName and Name == "press" then
                        Press = Value
                        break
                    end
                end
            end
        end
    end

    if not Press and type(filtergc) == "function" then
        local OkFilter, Found = pcall(filtergc, "function", { Name = "press", Constants = { "maxed", "rush" } }, true)
        if OkFilter and type(Found) == "function" then
            Press = Found
        end
    end

    Env.__BBTrainRuntime = { press = Press, state = State }
    return Press, State
end

-- START BAR PARTS

local StartParts
local function GetStartParts()
    local Gui = PlayerGui:FindFirstChild("BBStart3")
    if not Gui then
        StartParts = nil
        return nil
    end

    if StartParts and StartParts.Gui == Gui
        and StartParts.Marker.Parent == Gui
        and StartParts.Inner.Parent ~= nil
        and (not StartParts.Zone or StartParts.Zone.Parent ~= nil) then
        return StartParts
    end

    local Marker = Gui:FindFirstChild("Marker", true)
    local Zone = Gui:FindFirstChild("Bonus", true)
    local Inner = Gui:FindFirstChild("In", true)
    if not (Marker and Inner) then
        StartParts = nil
        return nil
    end

    StartParts = {
        Gui = Gui,
        Marker = Marker,
        Zone = Zone,
        Inner = Inner,
        Pressed = false,
    }
    return StartParts
end

-- PET LIST AND SELLING

local function PetPrice(Pet)
    return tonumber(Pet.price) or 0
end

local function CanSellPet(Pet)
    if Pet.st == "ride" or Pet.st == "held" then
        return false
    end
    return Pet.id ~= LocalPlayer:GetAttribute("BBRidingId")
end

local function SellLabel(Pet)
    local Name = tostring(Pet.name or Pet.sp or "Pet")
    local Mut = tostring(Pet.mut or "")
    if Mut ~= "" then
        Name = Mut .. " " .. Name
    end
    return string.format("%s (%d) · $%d", Name, Pet.id, PetPrice(Pet))
end

local PetRows
local PetRowsStamp = 0
local SellList = type(Env.__BBSellPets) == "table" and Env.__BBSellPets or {}
local SellListStamp = 0

local function OnPetsEvent(Tag, Data)
    if Tag == "List" and type(Data) == "table" and type(Data.pets) == "table" then
        SellList = Data.pets
        SellListStamp = os.clock()
        Env.__BBSellPets = Data.pets
        Env.__BBSellDirty = true
    end
end

local function OnTrainEvent(Tag, Data)
    if Tag == "Pick" and type(Data) == "table" and type(Data.rows) == "table" then
        PetRows = Data.rows
        PetRowsStamp = os.clock()
    elseif Tag == "PickNo" and Data == "max" and Env.__BBTrainLastPick then
        local Maxed = Env.__BBTrainMaxed or {}
        Maxed[Env.__BBTrainLastPick] = true
        Env.__BBTrainMaxed = Maxed
        Env.__BBTrainPickTries = (Env.__BBTrainPickTries or 0) + 1
    end
end

Conns[#Conns + 1] = PetsRemote.OnClientEvent:Connect(OnPetsEvent)
Conns[#Conns + 1] = TrainRemote.OnClientEvent:Connect(OnTrainEvent)

local function PetIdOf(Row)
    return type(Row) == "table" and Row[1] or Row
end

local function IsMaxedRow(Row)
    return type(Row) == "table" and Row[3] == true
end

local function SelectPet(Rows)
    local Maxed = Env.__BBTrainMaxed or {}
    local Tries = Env.__BBTrainPickTries or 0
    local Pick
    local Chosen = Config["Pet Id"] or 0

    local function Usable(Row)
        local PetId = PetIdOf(Row)
        return PetId ~= nil and not Maxed[PetId] and not IsMaxedRow(Row)
    end

    if Chosen > 0 then
        for _, Row in ipairs(Rows) do
            if PetIdOf(Row) == Chosen and Usable(Row) then
                Pick = Chosen
                break
            end
        end
    end

    if not Pick and Tries == 0 and Chosen == 0 then
        local LastUsed = LocalPlayer:GetAttribute("BBRidingId")
        for _, Row in ipairs(Rows) do
            if PetIdOf(Row) == LastUsed and Usable(Row) then
                Pick = LastUsed
                break
            end
        end
    end

    if not Pick and #Rows > 0 then
        for Offset = 0, #Rows - 1 do
            local Row = Rows[((Tries + Offset) % #Rows) + 1]
            if Usable(Row) then
                Pick = PetIdOf(Row)
                break
            end
        end
    end
    return Pick
end

local function SelectedSellIds()
    local Selected = Config["Sell Pet Ids"]
    if type(Selected) ~= "table" then
        Selected = {}
        Config["Sell Pet Ids"] = Selected
    end
    return Selected
end

local function SellPick()
    local Selected = SelectedSellIds()
    local Now = os.clock()
    local Cooldown = Env.__BBSellCooldown or {}
    for _, Pet in ipairs(SellList) do
        if Selected[Pet.id] and CanSellPet(Pet) and (Cooldown[Pet.id] or 0) < Now then
            return Pet
        end
    end
    return nil
end

local function SellStep(Now)
    if Config["Auto Sell Pet"] ~= true then
        return 0.6
    end

    local Selected = SelectedSellIds()
    local HasSelected = false
    for _ in pairs(Selected) do
        HasSelected = true
        break
    end
    if not HasSelected then
        return 1.5
    end

    if #SellList == 0 then
        if Now - SellListStamp > 5 then
            pcall(PetsRemote.FireServer, PetsRemote, "List")
            SellListStamp = Now
        end
        return 1
    end

    local Pet = SellPick()
    if not Pet then
        return 2
    end

    local Cooldown = Env.__BBSellCooldown or {}
    Cooldown[Pet.id] = Now + 4
    Env.__BBSellCooldown = Cooldown
    pcall(PetsRemote.FireServer, PetsRemote, "Sell", Pet.id)
    return tonumber(Config["Sell Delay"]) or 1.2
end

local function RefreshSellDropdown()
    local SellPicker = Env.__BBSellDropdown
    local FarmPicker = Env.__BBFarmDropdown
    if not (SellPicker or FarmPicker) then
        return
    end

    local Sorted = table.clone(SellList)
    table.sort(Sorted, function(A, B)
        return PetPrice(A) < PetPrice(B)
    end)

    local Data = {}
    local Signature = {}
    for _, Pet in ipairs(Sorted) do
        local Label = SellLabel(Pet)
        Data[#Data + 1] = { label = Label, id = Pet.id }
        Signature[#Signature + 1] = Pet.id .. ":" .. PetPrice(Pet)
    end

    local Sig = tostring(Env.__BBUIGen or 0) .. "|" .. table.concat(Signature, ",")
    if Env.__BBSellSig == Sig then
        return
    end
    Env.__BBSellSig = Sig

    local FarmData = { { label = "Auto (แรงสุด)", id = 0 } }
    for _, Item in ipairs(Data) do
        FarmData[#FarmData + 1] = Item
    end

    if SellPicker then
        SellPicker.Data = Data
        SellPicker.Selected = SelectedSellIds()
        if SellPicker.Opened then
            SellPicker.Render()
        end
    end
    if FarmPicker then
        FarmPicker.Data = FarmData
        FarmPicker.Selected = { [Config["Farm Pet Id"] or 0] = true }
        if FarmPicker.Opened then
            FarmPicker.Render()
        end
    end
end

local function FarmPetId()
    local Chosen = Config["Farm Pet Id"] or 0
    if Chosen > 0 then
        return Chosen
    end

    local Best, BestRate = nil, -1
    for _, Pet in ipairs(SellList) do
        local Rate = tonumber(Pet.rate) or 0
        if Rate > BestRate then
            Best, BestRate = Pet.id, Rate
        end
    end
    return Best
end

-- TRAVEL AND FARM STATE

local MountWant
local MountAt = 0
local TravelPhase
local TravelAt = 0
local TravelDeadline = 0
local NextTravelAt = 0
local LastRunPressAt = 0
local LastSpaceAt = 0

local function EnsureMounted(Now)
    local Want = FarmPetId()
    if not Want then
        return false
    end
    if LocalPlayer:GetAttribute("BBRidingId") == Want then
        MountWant = nil
        return true
    end
    if MountWant ~= Want or Now - MountAt > 1.5 then
        MountWant = Want
        MountAt = Now
        pcall(PetsRemote.FireServer, PetsRemote, "Ride", Want)
    end
    return false
end

local function StartTravel(Now)
    local RootPart = GetRootPart()
    if not RootPart then
        return false
    end
    RootPart.CFrame = CFrame.lookAt(Vector3.new(0, 16, 55), Vector3.new(0, 16, 70))
    TravelPhase = "wait"
    TravelAt = Now + 0.2
    TravelDeadline = Now + 2.2
    return true
end

local function TravelStep(Now)
    if TravelPhase == nil then
        return false
    end

    if TravelPhase == "wait" then
        if Now < TravelAt then
            return true
        end
        TravelPhase = "walk"
        pcall(VirtualInputManager.SendKeyEvent, VirtualInputManager, true, Enum.KeyCode.W, false, game)
    end

    if IsStartBarOpen() or IsRunActive() or Now > TravelDeadline then
        TravelPhase = nil
        ReleaseKey(Enum.KeyCode.W)
        return false
    end
    return true
end

local function BuildTrainPets(Rows)
    if type(Rows) ~= "table" then
        return
    end

    local NameById = {}
    for _, Pet in ipairs(SellList) do
        NameById[Pet.id] = tostring(Pet.name or Pet.sp or ("Pet " .. tostring(Pet.id)))
    end

    local List = {}
    for _, Row in ipairs(Rows) do
        local Id = PetIdOf(Row)
        if Id then
            List[#List + 1] = {
                Id = Id,
                Name = NameById[Id] or ("Pet " .. tostring(Id)),
                Maxed = IsMaxedRow(Row),
            }
        end
    end
    if #List == 0 then
        return
    end

    table.sort(List, function(A, B)
        return A.Id < B.Id
    end)
    Env.__BBTrainPets = List

    local Labels = { "Auto" }
    local Signature = "Auto"
    for _, Pet in ipairs(List) do
        Labels[#Labels + 1] = string.format("%s (%d)%s", Pet.Name, Pet.Id, Pet.Maxed and " [MAX]" or "")
        Signature = Signature .. "|" .. Pet.Id .. (Pet.Maxed and "M" or "")
    end

    local Picker = Env.__BBTrainDropdown
    if Picker and Env.__BBTrainPetsSignature ~= Signature then
        Env.__BBTrainPetsSignature = Signature
        local Data = { { label = "Auto", id = 0 } }
        for _, Pet in ipairs(List) do
            Data[#Data + 1] = {
                label = string.format("%s (%d)%s", Pet.Name, Pet.Id, Pet.Maxed and " [MAX]" or ""),
                id = Pet.Id,
            }
        end
        Picker.Data = Data
        Picker.Selected = { [Config["Pet Id"] or 0] = true }
        if Picker.Opened then
            Picker.Render()
        end
    end
end

-- TRAIN INPUT AND MANAGEMENT

local Press, TrainState
local LastFallbackAt = 0
local LastTrainIdx

local function TrainPressStep(Now)
    if not IsTrainActive() then
        LastTrainIdx = nil
        return
    end

    if not TrainState then
        return
    end

    local State = TrainState
    if State.maxed or State.rush or State.on ~= true then
        LastTrainIdx = nil
        return
    end

    local Seq = rawget(State, "seq")
    local Idx = rawget(State, "idx")
    local Key = Seq and Seq[Idx]
    if not Key then
        LastTrainIdx = Idx
        return
    end

    if Press then
        if LastTrainIdx ~= Idx then
            LastTrainIdx = Idx
            pcall(Press, Key)
        end
        return
    end

    if Now - LastFallbackAt >= (tonumber(Config["Press Delay"]) or 0.04) then
        local KeyCode = KEYCODES[Key]
        if KeyCode then
            LastFallbackAt = Now
            PressKey(KeyCode)
        end
    end
end

local TrainPhase
local TrainPhaseAt = 0
local TrainOpenedAt = 0
local NextOpenAt = 0

local function GetTrainSpot()
    local Plot = LocalPlayer:GetAttribute("BBPlot")
    if type(Plot) ~= "number" then
        return nil
    end
    local Map = workspace:FindFirstChild("Map")
    local Markers = Map and Map:FindFirstChild("Markers")
    local Plots = Markers and Markers:FindFirstChild("Plots")
    local PlotFolder = Plots and Plots:FindFirstChild("Plot" .. Plot)
    return PlotFolder and PlotFolder:FindFirstChild("TrainerSpot")
end

local function GetTrainPrompt(Spot)
    local Holder = Spot and Spot:FindFirstChild("BBTrainPrompt")
    return Holder and Holder:FindFirstChildOfClass("ProximityPrompt")
end

local function TrainManageStep(Now)
    if IsTrainActive() then
        TrainPhase = nil
        return
    end

    if TrainPhase == "rows" then
        if PetRowsStamp > TrainOpenedAt and PetRows and #PetRows > 0 then
            local RowMaxed = {}
            for _, Row in ipairs(PetRows) do
                local PetId = PetIdOf(Row)
                if PetId and IsMaxedRow(Row) then
                    RowMaxed[PetId] = true
                end
            end
            Env.__BBTrainRowMaxed = RowMaxed
            task.spawn(BuildTrainPets, PetRows)

            local Pick = SelectPet(PetRows)
            if not Pick then
                Env.__BBTrainAllMaxed = Now
                ClosePicker()
                TrainPhase = nil
                NextOpenAt = Now + 120
                return
            end

            pcall(TrainRemote.FireServer, TrainRemote, "Pick", Pick)
            Env.__BBTrainLastPick = Pick
            TrainPhase = "start"
            TrainPhaseAt = Now
            return
        end
        if Now - TrainOpenedAt > 3 then
            ClosePicker()
            TrainPhase = nil
            NextOpenAt = Now + 4
        end
        return
    end

    if TrainPhase == "start" then
        if IsTrainActive() then
            Env.__BBTrainPickTries = 0
            Env.__BBTrainAllMaxed = nil
            TrainPhase = nil
            NextOpenAt = Now + (tonumber(Config["Run Cooldown"]) or 1.2)
            return
        end
        if Now - TrainPhaseAt > 2 then
            Env.__BBTrainPickTries = (Env.__BBTrainPickTries or 0) + 1
            TrainPhase = nil
            NextOpenAt = Now + 1.5
        end
        return
    end

    if TrainPhase == "move" then
        if Now - TrainPhaseAt < 0.3 then
            return
        end
        TrainPhase = nil
    end
    if Now < NextOpenAt then
        return
    end

    local Spot = GetTrainSpot()
    local Prompt = GetTrainPrompt(Spot)
    if not (Spot and Prompt and Prompt.Enabled and Prompt.ActionText == "Train") then
        NextOpenAt = Now + 0.6
        return
    end

    local RootPart = GetRootPart()
    if not RootPart then
        NextOpenAt = Now + 1
        return
    end

    if (RootPart.Position - Spot.Position).Magnitude > (tonumber(Config["Spot Distance"]) or 18) then
        RootPart.CFrame = CFrame.new(Spot.Position + Vector3.new(0, 2.5, 6))
        TrainPhase = "move"
        TrainPhaseAt = Now
        return
    end

    TrainOpenedAt = Now
    local OkPrompt = pcall(fireproximityprompt, Prompt)
    if not OkPrompt then
        PressKey(Enum.KeyCode.E)
    end
    TrainPhase = "rows"
end

-- FARM BAR

local function StartBarStep(Now)
    local Parts = GetStartParts()
    if not Parts then
        return false
    end

    local Marker = Parts.Marker
    local Zone = Parts.Zone
    local Inner = Parts.Inner
    if not (Marker.Parent and Inner.Parent) then
        StartParts = nil
        return false
    end

    local Top = Inner.AbsolutePosition.Y
    local Height = Inner.AbsoluteSize.Y
    if Height <= 0 then
        return false
    end

    local MarkerY = Marker.AbsolutePosition.Y + Marker.AbsoluteSize.Y * 0.5
    local Progress = 1 - (MarkerY - Top) / Height
    if Progress < 0.15 or (Parts.LastProgress and Progress < Parts.LastProgress - 0.25) then
        Parts.Pressed = false
    end
    Parts.LastProgress = Progress

    if Parts.Pressed or Now - LastSpaceAt < 0.18 then
        return false
    end

    local Perfect = false
    if Zone and Zone.Parent and Zone.AbsoluteSize.Y > 0 then
        Perfect = MarkerY <= Zone.AbsolutePosition.Y + Zone.AbsoluteSize.Y
    end
    if not Perfect then
        Perfect = Progress >= 0.75
    end
    if Perfect then
        Parts.Pressed = true
        LastSpaceAt = Now
        PressKey(Enum.KeyCode.Space)
        return true
    end
    return false
end

local function FarmStep(Now)
    if IsRunActive() then
        if Now - LastRunPressAt >= 0.18 then
            LastRunPressAt = Now
            PressKey(Enum.KeyCode.Space)
        end
        return
    end

    if TravelStep(Now) then
        return
    end
    if IsStartBarOpen() then
        StartBarStep(Now)
        return
    end

    if StartParts then
        StartParts.Pressed = false
        StartParts.LastProgress = nil
    end
    if Now < NextTravelAt then
        return
    end
    if not EnsureMounted(Now) then
        NextTravelAt = Now + 2
        return
    end
    if StartTravel(Now) then
        NextTravelAt = Now + 1.2
    end
end

-- HEARTBEAT DRIVER

local NextManageAt = 0
local NextSellAt = 0
local NextUiAt = 0

local function StepOnce(Now)
    if Config["Auto Treadmill"] == true then
        TrainPressStep(Now)
        if Now >= NextManageAt then
            NextManageAt = Now + 0.25
            TrainManageStep(Now)
        end
    end

    if Config["Auto Farm Pet"] == true then
        FarmStep(Now)
    end

    if Now >= NextSellAt then
        NextSellAt = Now + SellStep(Now)
    end

    if Env.__BBSellDirty and Now >= NextUiAt then
        Env.__BBSellDirty = nil
        NextUiAt = Now + 0.5
        task.spawn(RefreshSellDropdown)
    end
end

local function OnHeartbeat()
    if Env.__BBGen ~= Gen then
        local Conn = Env.__BBStepConn
        if Conn then
            Conn:Disconnect()
        end
        return
    end

    local Ok, Err = pcall(StepOnce, os.clock())
    if not Ok then
        Env.__BBLastStepError = tostring(Err)
    end
end

local StepConn = RunService.Heartbeat:Connect(OnHeartbeat)
Env.__BBStepConn = StepConn

-- WARM UP TRAIN STATE

task.spawn(function()
    if Env.__BBGen ~= Gen then
        return
    end
    local Ok, FoundPress, FoundState = pcall(ResolveTrain)
    if Ok and Env.__BBGen == Gen then
        Press, TrainState = FoundPress, FoundState
    end
end)

-- UI

task.spawn(function()
    local Ok, WindUI = pcall(function()
        return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
    end)
    if not (Ok and WindUI) then
        return
    end

    if Env.__BBTrainWindow then
        pcall(function()
            Env.__BBTrainWindow:Destroy()
        end)
        Env.__BBTrainWindow = nil
    end

    local Hui = gethui and gethui()
    if Hui then
        for _, Gui in ipairs(Hui:GetChildren()) do
            if Gui.Name == "WindUI" and Gui:IsA("ScreenGui") then
                for _, Child in ipairs(Gui:GetChildren()) do
                    if Child.Name == "Frame" then
                        pcall(function()
                            Child:Destroy()
                        end)
                    end
                end
            end
        end
    end

    local Window = WindUI:CreateWindow({
        Title = "Ride Far With Pets",
        Icon = "paw-print",
        Author = "kanha",
        Folder = "RideFarWithPets",
        Size = UDim2.fromOffset(520, 460),
        ToggleKey = Enum.KeyCode.RightShift,
    })
    Env.__BBTrainWindow = Window

    Env.__BBUIGen = (Env.__BBUIGen or 0) + 1
    Env.__BBSellSig = nil
    Env.__BBTrainPetsSignature = nil

    local Tab = Window:Tab({ Title = "Treadmill", Icon = "dumbbell" })
    Tab:Section({ Title = "Auto Treadmill" })
    Tab:Toggle({
        Title = "Auto Treadmill",
        Desc = "เปิดมินิเกมและกดปุ่มวิ่งอัตโนมัติ (ตรงปุ่ม 100%)",
        Icon = "play",
        Type = "Checkbox",
        Value = Config["Auto Treadmill"],
        Callback = function(State)
            Config["Auto Treadmill"] = State
            if State then
                Config["Auto Farm Pet"] = false
            end
        end,
    })
    Tab:Slider({
        Title = "Press Delay",
        Desc = "ใช้เฉพาะตอนระบบกดภายในหาไม่เจอ (วินาที)",
        Step = 0.01,
        Value = { Min = 0.02, Max = 0.25, Default = Config["Press Delay"] },
        Callback = function(Value)
            Config["Press Delay"] = Value
        end,
    })

    -- WindUI hands back a tab object, not an Instance: resolve it to the tab frame.
    local function ResolveParent(Target)
        if typeof(Target) == "Instance" then
            return Target
        end
        if type(Target) == "table" then
            return Target.ContainerFrame or Target.Parent
        end
        return nil
    end

    -- Re-exec: drop the previous overlay so stale pickers cannot pile up.
    if Env.__BBPickerGui then
        pcall(function()
            Env.__BBPickerGui:Destroy()
        end)
        Env.__BBPickerGui = nil
    end

    local PickerGui = Instance.new("ScreenGui")
    PickerGui.Name = "BBPickers"
    PickerGui.ResetOnSpawn = false
    PickerGui.IgnoreGuiInset = true
    PickerGui.DisplayOrder = 999
    PickerGui.Parent = (gethui and gethui()) or PlayerGui
    Env.__BBPickerGui = PickerGui

    local function CreatePicker(Target, Multi, InitialData, OnSelect, Title)
        local Parent = ResolveParent(Target)
        if not Parent then
            return nil
        end

        local Root = Instance.new("Frame")
        Root.Name = "BBPicker"
        Root.Size = UDim2.fromOffset(240, 260)
        Root.AnchorPoint = Vector2.new(0.5, 0.5)
        Root.Position = UDim2.fromScale(0.5, 0.5)
        Root.BackgroundColor3 = Color3.fromRGB(28, 28, 32)
        Root.BorderSizePixel = 0
        Root.Visible = false
        Root.ZIndex = 50
        -- Lives on its own ScreenGui so the tab's list layout cannot move it.
        Root.Parent = PickerGui

        local Search = Instance.new("TextBox")
        Search.Name = "Search"
        Search.Size = UDim2.new(1, -8, 0, 26)
        Search.Position = UDim2.fromOffset(4, 4)
        Search.BackgroundColor3 = Color3.fromRGB(40, 40, 46)
        Search.Text = ""
        Search.PlaceholderText = "ค้นหา..."
        Search.TextSize = 13
        Search.ClearTextOnFocus = false
        Search.ZIndex = 51
        Search.Parent = Root

        local Scroll = Instance.new("ScrollingFrame")
        Scroll.Name = "List"
        Scroll.Position = UDim2.fromOffset(4, 34)
        Scroll.Size = UDim2.new(1, -8, 1, -38)
        Scroll.CanvasSize = UDim2.new()
        Scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
        Scroll.ScrollBarThickness = 4
        Scroll.BackgroundTransparency = 1
        Scroll.ZIndex = 51
        Scroll.Parent = Root

        local Layout = Instance.new("UIListLayout")
        Layout.Padding = UDim.new(0, 2)
        Layout.Parent = Scroll

        local Picker = {
            Root = Root,
            Search = Search,
            Scroll = Scroll,
            Layout = Layout,
            Multi = Multi,
            Rows = {},
            Data = InitialData or {},
            Selected = {},
            Opened = false,
            Built = false,
        }

        local function Paint()
            for Index, Item in ipairs(Picker.Data) do
                local Row = Picker.Rows[Index]
                if Row then
                    Row.Text = Item.label
                    Row.Visible = true
                    Row.BackgroundColor3 = Picker.Selected[Item.id]
                        and Color3.fromRGB(54, 112, 76)
                        or Color3.fromRGB(43, 43, 49)
                end
            end
            for Index = #Picker.Data + 1, #Picker.Rows do
                Picker.Rows[Index].Visible = false
            end
        end

        local function BuildRows()
            if Picker.Built then
                Paint()
                return
            end
            Picker.Built = true
            while #Picker.Rows < #Picker.Data do
                local Index = #Picker.Rows + 1
                local Row = Instance.new("TextButton")
                Row.Name = "Row" .. Index
                Row.Size = UDim2.new(1, -4, 0, 24)
                Row.BackgroundColor3 = Color3.fromRGB(43, 43, 49)
                Row.BorderSizePixel = 0
                Row.TextColor3 = Color3.fromRGB(240, 240, 240)
                Row.TextSize = 13
                Row.TextXAlignment = Enum.TextXAlignment.Left
                Row.AutoButtonColor = false
                Row.Visible = false
                Row.ZIndex = 52
                Row.Parent = Scroll
                Picker.Rows[Index] = Row
                Row.Activated:Connect(function()
                    local Item = Picker.Data[Index]
                    if not Item then
                        return
                    end
                    if Picker.Multi then
                        Picker.Selected[Item.id] = not Picker.Selected[Item.id] or nil
                    else
                        Picker.Selected = { [Item.id] = true }
                    end
                    OnSelect(Item, Picker.Selected)
                    Paint()
                end)
            end
            Paint()
        end

        local function ApplyFilter()
            local Query = Search.Text:lower()
            for Index, Item in ipairs(Picker.Data) do
                local Row = Picker.Rows[Index]
                if Row then
                    Row.Visible = Query == "" or string.find(Item.label:lower(), Query, 1, true) ~= nil
                end
            end
        end

        Picker.Render = function()
            if Picker.Opened then
                BuildRows()
                ApplyFilter()
            end
        end
        Search:GetPropertyChangedSignal("Text"):Connect(ApplyFilter)
        Picker.SetData = function(Data, Selected)
            Picker.Data = Data
            Picker.Selected = Selected or Picker.Selected
            Picker.Render()
        end

        local function Toggle()
            if Picker.Opened then
                Picker.Opened = false
                Root.Visible = false
                return
            end
            for _, Other in ipairs(Env.__BBPickers or {}) do
                Other.Opened = false
                Other.Root.Visible = false
            end
            Picker.Opened = true
            Root.Visible = true
            BuildRows()
        end

        Picker.Toggle = Toggle

        -- A native WindUI button keeps the trigger inline with the tab's other elements.
        local Inline = false
        if type(Target) == "table" and type(Target.Button) == "function" then
            Inline = pcall(function()
                Target:Button({
                    Title = Title or "เลือก...",
                    Callback = Toggle,
                })
            end)
        end

        if not Inline then
            local OpenButton = Instance.new("TextButton")
            OpenButton.Name = "OpenPicker"
            OpenButton.Size = UDim2.new(1, -8, 0, 30)
            OpenButton.BackgroundColor3 = Color3.fromRGB(40, 40, 46)
            OpenButton.BorderSizePixel = 0
            OpenButton.TextColor3 = Color3.fromRGB(240, 240, 240)
            OpenButton.TextSize = 13
            OpenButton.Text = Title or "เลือก..."
            OpenButton.ZIndex = 2
            OpenButton.Parent = Parent
            OpenButton.Activated:Connect(Toggle)
        end

        Env.__BBPickers = Env.__BBPickers or {}
        Env.__BBPickers[#Env.__BBPickers + 1] = Picker
        return Picker
    end

    Env.__BBPickers = {}
    local TrainPicker = CreatePicker(Tab, false, {}, function(Item)
        Config["Pet Id"] = Item.id
    end, "เลือก Pet ที่ใช้วิ่ง")
    if TrainPicker then
        TrainPicker.Data = { { label = "Auto", id = 0 } }
        TrainPicker.Selected = { [Config["Pet Id"] or 0] = true }
        Env.__BBTrainDropdown = TrainPicker
    end

    local SellTab = Window:Tab({ Title = "Sell", Icon = "coins" })
    SellTab:Section({ Title = "Auto Sell Pet" })
    SellTab:Toggle({
        Title = "Auto Sell Pet",
        Desc = "ขาย pet ที่เลือกอัตโนมัติเมื่อเจอในกระเป๋า",
        Icon = "coins",
        Type = "Checkbox",
        Value = Config["Auto Sell Pet"],
        Callback = function(State)
            Config["Auto Sell Pet"] = State
            Env.__BBSellCooldown = {}
            if State then
                pcall(PetsRemote.FireServer, PetsRemote, "List")
            end
        end,
    })

    local SellPicker = CreatePicker(SellTab, true, {}, function(_, Selected)
        Config["Sell Pet Ids"] = table.clone(Selected)
    end, "เลือก Pet ที่จะขาย")
    if SellPicker then
        SellPicker.Selected = SelectedSellIds()
        Env.__BBSellDropdown = SellPicker
    end

    local FarmTab = Window:Tab({ Title = "Farm", Icon = "zap" })
    FarmTab:Section({ Title = "Auto Farm Pet" })
    FarmTab:Toggle({
        Title = "Auto Farm Pet",
        Desc = "ขี่ pet ไปเส้นสตาร์ท กด SPACE ตรงจุด PERFECT แล้ววิ่งเก็บเงินวนซ้ำ",
        Icon = "zap",
        Type = "Checkbox",
        Value = Config["Auto Farm Pet"],
        Callback = function(State)
            Config["Auto Farm Pet"] = State
            if State then
                Config["Auto Treadmill"] = false
                NextTravelAt = 0
                pcall(PetsRemote.FireServer, PetsRemote, "List")
            end
        end,
    })

    local FarmPicker = CreatePicker(FarmTab, false, { { label = "Auto (แรงสุด)", id = 0 } }, function(Item)
        Config["Farm Pet Id"] = Item.id
    end, "เลือก Pet ที่ใช้ฟาร์ม")
    if FarmPicker then
        FarmPicker.Selected = { [Config["Farm Pet Id"] or 0] = true }
        Env.__BBFarmDropdown = FarmPicker
    end

    -- New dropdowns invalidate signatures so the next refresh fills them.
    Env.__BBUIGen = (Env.__BBUIGen or 0) + 1
    Env.__BBSellSig = nil
    Env.__BBTrainPetsSignature = nil
    Env.__BBSellDirty = true
    pcall(PetsRemote.FireServer, PetsRemote, "List")
    pcall(function()
        Window:SelectTab(1)
    end)
end)
