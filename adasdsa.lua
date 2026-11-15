-- LOAD MAP

if not game:IsLoaded() then
    game.Loaded:Wait()
end

local cloneref = cloneref or function(instance)
    return instance
end

-- SERVICES

local Players = cloneref(game:GetService("Players"))
local ReplicatedStorage = cloneref(game:GetService("ReplicatedStorage"))
local GuiService = cloneref(game:GetService("GuiService"))
local VirtualInputManager = cloneref(game:GetService("VirtualInputManager"))

local LocalPlayer = Players.LocalPlayer or Players.PlayerAdded:Wait()
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local BB = ReplicatedStorage:WaitForChild("BB")
local Ride = BB:WaitForChild("Ride")
local TrainRemote = Ride:WaitForChild("TrainRemote")
local Pets = BB:WaitForChild("Pets")
local PetsRemote = Pets:WaitForChild("PetsRemote")

-- CONFIG

Config = Config or {
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

local Gen = (getgenv().__BBGen or 0) + 1
getgenv().__BBGen = Gen

getgenv().__BBTrainMaxed = getgenv().__BBTrainMaxed or {}
getgenv().__BBTrainPickTries = getgenv().__BBTrainPickTries or 0

-- FUNCTIONS

local LETTERS = { "Q", "E", "R", "T" }
local KEYCODES = { Enum.KeyCode.Q, Enum.KeyCode.E, Enum.KeyCode.R, Enum.KeyCode.T }

local function IsRunning()
    return Config["Auto Treadmill"] == true
end

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

-- Bounded GetChildren walk (GetDescendants is never used)
local function IterateDeep(Parent, MaxDepth, Callback)
    local Queue = { Parent }
    local Depth = { [Parent] = 0 }
    local Head = 1

    while Head <= #Queue do
        local Node = Queue[Head]
        Head = Head + 1

        local Current = Depth[Node] or 0

        if Current < MaxDepth then
            for _, Child in ipairs(Node:GetChildren()) do
                Depth[Child] = Current + 1
                Queue[#Queue + 1] = Child
                Callback(Child)
            end
        end
    end
end

local function FindDeep(Parent, Name, MaxDepth)
    local Found

    IterateDeep(Parent, MaxDepth, function(Node)
        if not Found and Node.Name == Name then
            Found = Node
        end
    end)

    return Found
end

local function GetRootPart()
    local Character = LocalPlayer.Character
    return Character and Character:FindFirstChild("HumanoidRootPart")
end

-- Non-blocking key send: key down now, key up on the next frame.
local function PressKey(KeyCode)
    VirtualInputManager:SendKeyEvent(true, KeyCode, false, game)

    task.delay(0.02, function()
        pcall(function()
            VirtualInputManager:SendKeyEvent(false, KeyCode, false, game)
        end)
    end)
end

-- Connection based GUI click (primary), signal fire as fallback.
local function GetConnect(Target)
    local Clicked = false
    local Events = { "Activated", "MouseButton1Down", "MouseButton1Click", "MouseButton1Up" }

    for _, EventName in next, Events do
        pcall(function()
            for _, Connection in next, getconnections(Target[EventName]) do
                pcall(function()
                    if type(Connection.Function) ~= "function" then
                        return
                    end

                    Connection.Function()
                    Clicked = true
                end)
            end
        end)
    end

    return Clicked
end

local function ClosePicker()
    local Gui = PlayerGui:FindFirstChild("BBTrainPick")
    local X = Gui and FindDeep(Gui, "X", 2)

    if X then
        if not GetConnect(X) then
            pcall(function()
                X.Activated:Fire()
            end)
            pcall(function()
                X.MouseButton1Click:Fire()
            end)
        end
    end

    pcall(function()
        TrainRemote:FireServer("Stop")
    end)
end

-- TRAIN STATE (read from the game's own minigame table, cached)

local function GetTrainState(Force)
    local State = getgenv().__BBTrainState

    if type(State) == "table" and type(rawget(State, "seq")) == "table" and type(rawget(State, "idx")) == "number" then
        return State
    end

    if not Force and not IsTrainActive() then
        return nil
    end

    local Now = os.clock()

    if Now < (getgenv().__BBStateNext or 0) then
        return nil
    end

    getgenv().__BBStateNext = Now + 2

    local Ok, Found = pcall(filtergc, "table", { Keys = { "seq", "idx", "keyLit" } })

    if not Ok or type(Found) ~= "table" or #Found == 0 then
        return nil
    end

    getgenv().__BBTrainState = Found[1]
    getgenv().__BBPressFn = nil

    return Found[1]
end

-- The game ships its own press handler; calling it removes input latency entirely.
local function GetPressFn()
    local Cached = getgenv().__BBPressFn

    if type(Cached) == "function" then
        return Cached
    end

    local State = getgenv().__BBTrainState

    if type(State) ~= "table" then
        return nil
    end

    local Now = os.clock()

    if Now < (getgenv().__BBPressScanNext or 0) then
        return nil
    end

    -- Scanning the whole heap is expensive; never retry on every frame.
    getgenv().__BBPressScanNext = Now + 3

    local GetUpvalues = getupvalues or (debug and debug.getupvalues)

    if type(GetUpvalues) ~= "function" then
        return nil
    end

    local Ok, Functions = pcall(getgc, true)

    if not Ok or type(Functions) ~= "table" then
        return nil
    end

    for _, Object in ipairs(Functions) do
        if type(Object) == "function" then
            local OkUp, Upvalues = pcall(GetUpvalues, Object)

            if OkUp then
                local Matched

                for _, Value in next, Upvalues do
                    if Value == State then
                        Matched = true
                        break
                    end
                end

                if Matched then
                    local OkName, Name = pcall(debug.info, Object, "n")

                    if OkName and Name == "press" then
                        getgenv().__BBPressFn = Object
                        return Object
                    end
                end
            end
        end
    end

    return nil
end

-- START BAR GEOMETRY (perfect zone is the top band of the tube)
local StartParts

local function GetStartParts()
    local Gui = PlayerGui:FindFirstChild("BBStart3")

    if not Gui then
        StartParts = nil
        return nil
    end

    if StartParts and StartParts.Gui == Gui and StartParts.Marker.Parent then
        return StartParts
    end

    local Marker, Zone, Inner

    IterateDeep(Gui, 4, function(Node)
        if not Marker and Node.Name == "Marker" then
            Marker = Node
        elseif not Zone and Node.Name == "Bonus" then
            Zone = Node
        elseif not Inner and Node.Name == "In" then
            Inner = Node
        end
    end)

    if not (Marker and Inner) then
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

local function PetPrice(Pet)
    return tonumber(Pet.price) or 0
end

local function CanSellPet(Pet)
    local State = Pet.st

    if State == "ride" or State == "held" then
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
local SellList = {}
local SellListStamp = 0

PetsRemote.OnClientEvent:Connect(function(Tag, Data)
    if Tag == "List" and type(Data) == "table" and type(Data.pets) == "table" then
        SellList = Data.pets
        SellListStamp = os.clock()
        getgenv().__BBSellPets = Data.pets
        getgenv().__BBSellDirty = true
    end
end)

TrainRemote.OnClientEvent:Connect(function(Tag, Data)
    if Tag == "Pick" and type(Data) == "table" and type(Data.rows) == "table" then
        PetRows = Data.rows
        PetRowsStamp = os.clock()
    elseif Tag == "PickNo" and Data == "max" and getgenv().__BBTrainLastPick then
        local Maxed = getgenv().__BBTrainMaxed or {}
        Maxed[getgenv().__BBTrainLastPick] = true
        getgenv().__BBTrainMaxed = Maxed
        getgenv().__BBTrainPickTries = (getgenv().__BBTrainPickTries or 0) + 1
    end
end)

local function PetIdOf(Row)
    return type(Row) == "table" and Row[1] or Row
end

local function IsMaxedRow(Row)
    return type(Row) == "table" and Row[3] == true
end

local function SelectPet(Rows)
    local Maxed = getgenv().__BBTrainMaxed or {}
    local Tries = getgenv().__BBTrainPickTries or 0
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

    if not Pick then
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
    local Cooldown = getgenv().__BBSellCooldown or {}

    for _, Pet in ipairs(SellList) do
        if Selected[Pet.id] and CanSellPet(Pet) and (Cooldown[Pet.id] or 0) < Now then
            return Pet
        end
    end

    return nil
end

local function SellTick()
    if Config["Auto Sell Pet"] ~= true then
        return 1
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

    -- The game pushes "List" whenever the bag changes, so only ask once when empty.
    if #SellList == 0 then
        if os.clock() - SellListStamp > 5 then
            pcall(function()
                PetsRemote:FireServer("List")
            end)
            SellListStamp = os.clock()
        end
        return 1
    end

    local Pet = SellPick()

    if not Pet then
        return 2
    end

    local Cooldown = getgenv().__BBSellCooldown or {}
    Cooldown[Pet.id] = os.clock() + 4
    getgenv().__BBSellCooldown = Cooldown

    pcall(function()
        PetsRemote:FireServer("Sell", Pet.id)
    end)

    return Config["Sell Delay"]
end

local function RefreshSellDropdown()
    local Dropdown = getgenv().__BBSellDropdown
    local Farm = getgenv().__BBFarmDropdown

    if not (Dropdown or Farm) then
        return
    end

    table.sort(SellList, function(A, B)
        return PetPrice(A) < PetPrice(B)
    end)

    local Labels = {}
    local Signature = {}

    for _, Pet in ipairs(SellList) do
        Labels[#Labels + 1] = SellLabel(Pet)
        Signature[#Signature + 1] = Pet.id .. ":" .. PetPrice(Pet)
    end

    local Sig = tostring(getgenv().__BBUIGen or 0) .. "|" .. table.concat(Signature, ",")

    -- A freshly built dropdown object starts empty, so the signature carries
    -- the UI generation; otherwise a re-exec would skip the very first fill.
    if getgenv().__BBSellSig == Sig then
        return
    end

    getgenv().__BBSellSig = Sig

    if Dropdown then
        local Selected = SelectedSellIds()
        local SelectedLabels = {}

        for Index, Pet in ipairs(SellList) do
            if Selected[Pet.id] then
                SelectedLabels[#SelectedLabels + 1] = Labels[Index]
            end
        end

        pcall(function()
            Dropdown:Refresh(Labels)

            if #SelectedLabels > 0 then
                Dropdown:Select(SelectedLabels)
            end
        end)
    end

    if Farm then
        local FarmLabels = { "Auto (แรงสุด)" }
        local FarmSelected = "Auto (แรงสุด)"

        for _, Pet in ipairs(SellList) do
            local Label = SellLabel(Pet)
            FarmLabels[#FarmLabels + 1] = Label

            if Pet.id == Config["Farm Pet Id"] then
                FarmSelected = Label
            end
        end

        pcall(function()
            Farm:Refresh(FarmLabels)
            Farm:Select(FarmSelected)
        end)
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

local function EnsureMounted()
    local Want = FarmPetId()

    if not Want then
        return false
    end

    if LocalPlayer:GetAttribute("BBRidingId") == Want then
        return true
    end

    pcall(function()
        PetsRemote:FireServer("Ride", Want)
    end)

    local Deadline = os.clock() + 1.5

    while os.clock() < Deadline do
        if LocalPlayer:GetAttribute("BBRidingId") == Want then
            return true
        end
        task.wait(0.1)
    end

    return LocalPlayer:GetAttribute("BBRidingId") == Want
end

local function GoToStart()
    local RootPart = GetRootPart()

    if not RootPart then
        return
    end

    RootPart.CFrame = CFrame.lookAt(Vector3.new(0, 16, 55), Vector3.new(0, 16, 70))
    task.wait(0.2)
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.W, false, game)

    local Deadline = os.clock() + 2

    while os.clock() < Deadline do
        if IsStartBarOpen() or IsRunActive() then
            break
        end
        task.wait(0.05)
    end

    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.W, false, game)
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

    getgenv().__BBTrainPets = List

    local Labels = { "Auto" }
    local Signature = "Auto"

    for _, Pet in ipairs(List) do
        Labels[#Labels + 1] = string.format("%s (%d)%s", Pet.Name, Pet.Id, Pet.Maxed and " [MAX]" or "")
        Signature = Signature .. "|" .. Pet.Id .. (Pet.Maxed and "M" or "")
    end

    local Dropdown = getgenv().__BBTrainDropdown

    if Dropdown and getgenv().__BBTrainPetsSignature ~= Signature then
        getgenv().__BBTrainPetsSignature = Signature

        local Selected = "Auto"

        for Index, Pet in ipairs(List) do
            if Pet.Id == Config["Pet Id"] then
                Selected = Labels[Index + 1]
                break
            end
        end

        pcall(function()
            Dropdown:Refresh(Labels)
            Dropdown:Select(Selected)
        end)
    end
end

-- PRESS ENGINE (frame cadence, zero input latency when the internal handler is found)

local LastIdx = -1
local StallCount = 0
local LastFallbackAt = 0

local function TrainPressStep()
    if not IsTrainActive() then
        LastIdx = -1
        StallCount = 0
        return
    end

    local State = GetTrainState()

    if not State or State.maxed or State.rush or State.on ~= true then
        return
    end

    local Seq = rawget(State, "seq")
    local Idx = rawget(State, "idx")
    local Key = Seq[Idx]

    if not Key then
        return
    end

    if Idx ~= LastIdx then
        LastIdx = Idx
        StallCount = 0
    else
        StallCount = StallCount + 1
    end

    -- If the index never moves the cached table is stale: drop it and re-read.
    if StallCount >= 120 then
        StallCount = 0
        LastIdx = -1
        getgenv().__BBTrainState = nil
        getgenv().__BBPressFn = nil
        return
    end

    local Press = GetPressFn()

    if Press then
        pcall(Press, Key)
        return
    end

    local KeyCode = KEYCODES[Key]
    local Now = os.clock()

    if KeyCode and Now - LastFallbackAt >= Config["Press Delay"] then
        LastFallbackAt = Now
        PressKey(KeyCode)
    end
end

-- TRAIN OPEN / PICK STATE MACHINE (never blocks the frame loop)

local TrainPhase = nil
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

local function TrainManageStep()
    if IsTrainActive() then
        TrainPhase = nil
        return
    end

    local Now = os.clock()

    if TrainPhase == "rows" then
        if PetRowsStamp > TrainOpenedAt and PetRows and #PetRows > 0 then
            local RowMaxed = {}

            for _, Row in ipairs(PetRows) do
                local PetId = PetIdOf(Row)

                if PetId and IsMaxedRow(Row) then
                    RowMaxed[PetId] = true
                end
            end

            getgenv().__BBTrainRowMaxed = RowMaxed

            task.spawn(function()
                pcall(BuildTrainPets, PetRows)
            end)

            local Pick = SelectPet(PetRows)

            if not Pick then
                getgenv().__BBTrainAllMaxed = os.clock()
                ClosePicker()
                TrainPhase = nil
                NextOpenAt = os.clock() + 120
                return
            end

            TrainRemote:FireServer("Pick", Pick)
            getgenv().__BBTrainLastPick = Pick
            TrainPhase = "start"
            TrainPhaseAt = os.clock()
            return
        end

        if Now - TrainOpenedAt > 3 then
            ClosePicker()
            TrainPhase = nil
            NextOpenAt = os.clock() + 4
        end

        return
    end

    if TrainPhase == "start" then
        if IsTrainActive() then
            getgenv().__BBTrainPickTries = 0
            getgenv().__BBTrainAllMaxed = nil
            TrainPhase = nil
            NextOpenAt = os.clock() + Config["Run Cooldown"]
            return
        end

        if Now - TrainPhaseAt > 2 then
            getgenv().__BBTrainPickTries = (getgenv().__BBTrainPickTries or 0) + 1
            TrainPhase = nil
            NextOpenAt = os.clock() + 1.5
        end

        return
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

    if (RootPart.Position - Spot.Position).Magnitude > Config["Spot Distance"] then
        RootPart.CFrame = CFrame.new(Spot.Position + Vector3.new(0, 2.5, 6))
        task.wait(0.3)
    end

    TrainOpenedAt = os.clock()

    if not pcall(fireproximityprompt, Prompt) then
        PressKey(Enum.KeyCode.E)
    end

    TrainPhase = "rows"
end

-- FARM (ride to start, then press exactly on the perfect band)

local NextTravelAt = 0
local LastRunPressAt = 0

local function StartBarStep()
    local Parts = GetStartParts()

    if not Parts then
        return false
    end

    local Marker = Parts.Marker
    local Zone = Parts.Zone
    local Inner = Parts.Inner

    if not (Marker and Marker.Parent and Inner and Inner.Parent) then
        return false
    end

    local Top = Inner.AbsolutePosition.Y
    local Height = Inner.AbsoluteSize.Y

    if Height <= 0 then
        return false
    end

    local MarkerY = Marker.AbsolutePosition.Y + Marker.AbsoluteSize.Y * 0.5
    local Progress = 1 - (MarkerY - Top) / Height

    -- A new sweep starts at the bottom: re-arm without relying on the GUI
    -- being disabled in between runs (that is why round 2 used to skip).
    if Progress < 0.15 or (Parts.LastProgress and Progress < Parts.LastProgress - 0.25) then
        Parts.Pressed = false
    end

    Parts.LastProgress = Progress

    if Parts.Pressed then
        return false
    end

    local Perfect = false

    -- Primary: the drawn "Bonus" band is the perfect zone, so crossing its
    -- lower edge means the bar is already inside PERFECT.
    if Zone and Zone.Parent and Zone.AbsoluteSize.Y > 0 then
        Perfect = MarkerY <= Zone.AbsolutePosition.Y + Zone.AbsoluteSize.Y
    end

    -- Fallback: derive progress from the bar body when the band is missing.
    if not Perfect then
        Perfect = Progress >= 0.75
    end

    if Perfect then
        Parts.Pressed = true
        PressKey(Enum.KeyCode.Space)
        return true
    end

    return false
end

local function FarmStep()
    if Config["Auto Farm Pet"] ~= true then
        return
    end

    if IsRunActive() then
        local Now = os.clock()

        if Now - LastRunPressAt >= 0.18 then
            LastRunPressAt = Now
            PressKey(Enum.KeyCode.Space)
        end

        return
    end

    if IsStartBarOpen() then
        StartBarStep()
        return
    end

    if StartParts then
        StartParts.Pressed = false
        StartParts.LastProgress = nil
    end

    local Now = os.clock()

    if Now < NextTravelAt then
        return
    end

    if not EnsureMounted() then
        NextTravelAt = Now + 2
        return
    end

    GoToStart()
    NextTravelAt = os.clock() + 1.2
end

-- WARM UP (resolve the minigame table + handler before the first run)

task.spawn(function()
    pcall(function()
        if GetTrainState(true) then
            GetPressFn()
        end
    end)
end)

-- LOOPS

local NextSellAt = 0

task.spawn(function()
    while getgenv().__BBGen == Gen do
        local Ok = pcall(function()
            if IsRunning() then
                TrainPressStep()
                TrainManageStep()
            end

            if Config["Auto Farm Pet"] == true then
                FarmStep()
            end

            if os.clock() >= NextSellAt then
                if getgenv().__BBSellDirty then
                    getgenv().__BBSellDirty = nil
                    task.spawn(function()
                        pcall(RefreshSellDropdown)
                    end)
                end

                if Config["Auto Sell Pet"] == true then
                    local OkSell, Value = pcall(SellTick)
                    NextSellAt = os.clock() + ((OkSell and type(Value) == "number") and Value or 1)
                else
                    NextSellAt = os.clock() + 0.6
                end
            end
        end)

        if Ok then
            task.wait(0.03)
        else
            task.wait(0.1)
        end
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

    if getgenv().__BBTrainWindow then
        pcall(function()
            getgenv().__BBTrainWindow:Destroy()
        end)
        getgenv().__BBTrainWindow = nil
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

    getgenv().__BBTrainWindow = Window

    -- New dropdown objects: invalidate cached dropdown signatures.
    getgenv().__BBUIGen = (getgenv().__BBUIGen or 0) + 1
    getgenv().__BBSellSig = nil
    getgenv().__BBTrainPetsSignature = nil

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

                task.spawn(function()
                    pcall(function()
                        if GetTrainState(true) then
                            GetPressFn()
                        end
                    end)
                end)
            end
        end,
    })

    Tab:Slider({
        Title = "Press Delay",
        Desc = "ใช้เฉพาะตอนระบบกดภายในหาไม่เจอ (วินาที)",
        Step = 0.01,
        Value = {
            Min = 0.02,
            Max = 0.25,
            Default = Config["Press Delay"],
        },
        Callback = function(Value)
            Config["Press Delay"] = Value
        end,
    })

    local Labels = { "Auto" }

    for _, Pet in ipairs(getgenv().__BBTrainPets or {}) do
        Labels[#Labels + 1] = string.format("%s (%d)%s", Pet.Name, Pet.Id, Pet.Maxed and " [MAX]" or "")
    end

    local SelectedLabel = "Auto"

    if Config["Pet Id"] > 0 then
        for _, Pet in ipairs(getgenv().__BBTrainPets or {}) do
            if Pet.Id == Config["Pet Id"] then
                SelectedLabel = string.format("%s (%d)%s", Pet.Name, Pet.Id, Pet.Maxed and " [MAX]" or "")
                break
            end
        end
    end

    local Dropdown = Tab:Dropdown({
        Title = "Pet ที่ใช้วิ่ง",
        Desc = "เลือก pet ที่จะให้วิ่ง treadmill ทุกรอบ",
        Values = Labels,
        Value = SelectedLabel,
        AllowNone = false,
        Callback = function(Option)
            if Option == "Auto" then
                Config["Pet Id"] = 0
                return
            end

            Config["Pet Id"] = tonumber(string.match(Option, "%((%d+)%)")) or 0
        end,
    })

    getgenv().__BBTrainDropdown = Dropdown

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
            getgenv().__BBSellCooldown = {}

            if State then
                pcall(function()
                    PetsRemote:FireServer("List")
                end)
            end
        end,
    })

    local SellLabels = {}
    local SellSelected = {}

    for _, Pet in ipairs(SellList) do
        SellLabels[#SellLabels + 1] = SellLabel(Pet)

        if SelectedSellIds()[Pet.id] then
            SellSelected[#SellSelected + 1] = SellLabel(Pet)
        end
    end

    local SellDropdown = SellTab:Dropdown({
        Title = "Pet ที่จะขาย",
        Desc = "เลือกได้หลายตัว ราคาคือราคาที่ขายได้จริง",
        Values = SellLabels,
        Value = SellSelected,
        Multi = true,
        AllowNone = true,
        Callback = function(Option)
            local Picked = {}
            local List = type(Option) == "table" and Option or { Option }

            for _, Label in ipairs(List) do
                local Id = tonumber(string.match(Label, "%((%d+)%)"))

                if Id then
                    Picked[Id] = true
                end
            end

            Config["Sell Pet Ids"] = Picked
        end,
    })

    getgenv().__BBSellDropdown = SellDropdown

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

                pcall(function()
                    PetsRemote:FireServer("List")
                end)
            end
        end,
    })

    local FarmLabels = { "Auto (แรงสุด)" }
    local FarmSelected = "Auto (แรงสุด)"

    for _, Pet in ipairs(SellList) do
        local Label = SellLabel(Pet)
        FarmLabels[#FarmLabels + 1] = Label

        if Pet.id == Config["Farm Pet Id"] then
            FarmSelected = Label
        end
    end

    local FarmDropdown = FarmTab:Dropdown({
        Title = "Pet ที่ใช้ฟาร์ม",
        Desc = "เลือก pet ที่จะขี่ออกวิ่ง (พิมพ์ค้นหาได้)",
        Values = FarmLabels,
        Value = FarmSelected,
        AllowNone = false,
        MenuWidth = 220,
        SearchBarEnabled = true,
        Callback = function(Option)
            if Option == "Auto (แรงสุด)" then
                Config["Farm Pet Id"] = 0
                return
            end

            Config["Farm Pet Id"] = tonumber(string.match(Option, "%((%d+)%)")) or 0
        end,
    })

    getgenv().__BBFarmDropdown = FarmDropdown

    getgenv().__BBSellDirty = true

    pcall(function()
        PetsRemote:FireServer("List")
    end)

    pcall(function()
        Window:SelectTab(1)
    end)
end)
