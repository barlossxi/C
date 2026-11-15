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
    ["Press Delay"] = 0.08,
    ["Run Cooldown"] = 1.2,
    ["Spot Distance"] = 18,
    ["Pet Id"] = 0,
    ["Auto Sell Pet"] = false,
    ["Sell Pet Ids"] = {},
    ["Sell Delay"] = 1.2,
    ["Auto Farm Pet"] = false,
    ["Farm Pet Id"] = 0,
}

getgenv().__BBTrainMaxed = getgenv().__BBTrainMaxed or {}
getgenv().__BBTrainPickTries = getgenv().__BBTrainPickTries or 0

local Gen = (getgenv().__BBTrainGen or 0) + 1
getgenv().__BBTrainGen = Gen
getgenv().__BBTrainToken = (getgenv().__BBTrainToken or 0) + 1
getgenv().__BBTrainBeat = 0

-- FUNCTIONS

local LETTERS = { "Q", "E", "R", "T" }

local function IsRunning()
    return Config["Auto Treadmill"] == true
end

local function IsTrainActive()
    local Gui = PlayerGui:FindFirstChild("BBTrainKeys")
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

local function GetTrainState()
    local State = getgenv().__BBTrainState

    if type(State) == "table" and type(rawget(State, "seq")) == "table" and type(rawget(State, "idx")) == "number" then
        return State
    end

    -- Never scan the heap while idle; only look once the minigame is actually running.
    if not IsTrainActive() then
        return nil
    end

    local Now = os.clock()

    if Now < (getgenv().__BBTrainStateNext or 0) then
        return nil
    end

    getgenv().__BBTrainStateNext = Now + 5

    local Ok, Found = pcall(filtergc, "table", { Keys = { "seq", "idx" } })

    if not Ok or type(Found) ~= "table" or #Found == 0 then
        return nil
    end

    getgenv().__BBTrainState = Found[1]

    return Found[1]
end

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

local function GetRootPart()
    local Character = LocalPlayer.Character
    return Character and Character:FindFirstChild("HumanoidRootPart")
end

local function ClosePicker()
    local Gui = PlayerGui:FindFirstChild("BBTrainPick")
    local X = Gui and FindDeep(Gui, "X", 2)

    if X then
        pcall(function()
            X.Activated:Fire()
            X.MouseButton1Click:Fire()
        end)
    end

    pcall(function()
        TrainRemote:FireServer("Stop")
    end)
end

local function PressKey(KeyCode)
    VirtualInputManager:SendKeyEvent(true, KeyCode, false, game)
    task.wait(0.04)
    VirtualInputManager:SendKeyEvent(false, KeyCode, false, game)
end

local PetRows
local PetRowsStamp = 0
local SellList = {}
local SellListStamp = 0

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

local function CollectPets()
    local Gui = PlayerGui:FindFirstChild("BBTrainPick")

    if not Gui then
        return
    end

    local List = {}

    IterateDeep(Gui, 4, function(Child)
        local Id = Child:IsA("TextButton") and Child.Name:match("^Row(%d+)$")

        if not Id then
            return
        end

        local Text = ""

        if Child:IsA("TextButton") and Child.Text ~= "" then
            Text = Child.Text
        end

        if Text == "" then
            IterateDeep(Child, 3, function(Desc)
                if Text == "" and Desc:IsA("TextLabel") and Desc.Text ~= "" then
                    Text = Desc.Text
                end
            end)
        end

        List[#List + 1] = {
            Id = tonumber(Id),
            Name = Text:match("^([^|]+)") or ("Pet " .. Id),
            Maxed = Text:find("MAX", 1, true) ~= nil,
        }
    end)

    if #List == 0 then
        return
    end

    table.sort(List, function(A, B)
        return A.Id < B.Id
    end)

    getgenv().__BBTrainPets = List

    local RowMaxed = getgenv().__BBTrainRowMaxed or {}

    local Labels = { "Auto" }
    local Signature = "Auto"

    for _, Pet in ipairs(List) do
        Pet.Name = Pet.Name:match("^%s*(.-)%s*$")
        Pet.Maxed = Pet.Maxed or RowMaxed[Pet.Id] == true

        Labels[#Labels + 1] = string.format(
            "%s (%d)%s",
            Pet.Name,
            Pet.Id,
            Pet.Maxed and " [MAX]" or ""
        )
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

    local Sig = table.concat(Signature, ",")

    -- Rebuilding a WindUI dropdown with 80+ options is heavy; skip when nothing changed.
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

local function IsRunActive()
    local Gui = PlayerGui:FindFirstChild("BBRun4")
    return Gui ~= nil and Gui.Enabled == true
end

local function IsStartBarOpen()
    local Gui = PlayerGui:FindFirstChild("BBStart3")
    return Gui ~= nil and Gui.Enabled == true
end

local function GetStartMarker()
    local Gui = PlayerGui:FindFirstChild("BBStart3")

    if not Gui then
        getgenv().__BBStartMarker = nil
        return nil
    end

    local Cached = getgenv().__BBStartMarker

    if Cached and Cached.Parent then
        return Cached
    end

    local Found

    IterateDeep(Gui, 3, function(Node)
        if not Found and Node:IsA("GuiObject") and Node.Name == "Marker" then
            Found = Node
        end
    end)

    getgenv().__BBStartMarker = Found

    return Found
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

    local Deadline = os.clock() + 2

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
    task.wait(0.3)
    VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.W, false, game)

    local Deadline = os.clock() + 3

    while os.clock() < Deadline do
        if IsStartBarOpen() or IsRunActive() then
            break
        end
        task.wait(0.08)
    end

    VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.W, false, game)
end

local function FarmStep()
    if Config["Auto Farm Pet"] ~= true then
        return 0.5
    end

    if IsRunActive() then
        PressKey(Enum.KeyCode.Space)
        return 0.18
    end

    if IsStartBarOpen() then
        local Marker = GetStartMarker()

        if Marker then
            local Y = Marker.AbsolutePosition.Y

            if Y >= 112 and Y <= 190 then
                PressKey(Enum.KeyCode.Space)
                return 0.4
            end
        end

        return 0.03
    end

    if not EnsureMounted() then
        return 2
    end

    GoToStart()

    return 1.5
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

local function OpenTrain(Spot, Prompt)
    local RootPart = GetRootPart()

    if not RootPart then
        return false
    end

    if (RootPart.Position - Spot.Position).Magnitude > Config["Spot Distance"] then
        RootPart.CFrame = CFrame.new(Spot.Position + Vector3.new(0, 2.5, 6))
        task.wait(0.35)
    end

    local Opened = os.clock()

    if not pcall(fireproximityprompt, Prompt) then
        PressKey(Enum.KeyCode.E)
    end

    local Deadline = os.clock() + 2.5

    while os.clock() < Deadline and PetRowsStamp <= Opened do
        task.wait(0.05)
    end

    if not PetRows or #PetRows == 0 or PetRowsStamp <= Opened then
        return false
    end

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
        return false
    end

    TrainRemote:FireServer("Pick", Pick)
    getgenv().__BBTrainLastPick = Pick

    local StartDeadline = os.clock() + 2

    while os.clock() < StartDeadline and not IsTrainActive() do
        task.wait(0.05)
    end

    if IsTrainActive() then
        getgenv().__BBTrainPickTries = 0
        return true
    end

    getgenv().__BBTrainPickTries = (getgenv().__BBTrainPickTries or 0) + 1

    return false
end

local function Step()
    if not IsRunning() then
        return 0.5
    end

    local State = GetTrainState()

    if State and IsTrainActive() then
        local Seq = rawget(State, "seq")
        local Index = rawget(State, "idx")
        local Key = Seq[Index] and LETTERS[Seq[Index]]

        if Key then
            PressKey(Enum.KeyCode[Key])
            return Config["Press Delay"]
        end

        return 0.1
    end

    local PickGui = PlayerGui:FindFirstChild("BBTrainPick")
    local HasRows = false

    if PickGui and PickGui.Enabled then
        IterateDeep(PickGui, 3, function(Child)
            if not HasRows and Child:IsA("TextButton") and Child.Name:match("^Row%d+$") then
                HasRows = true
            end
        end)
    end

    if HasRows then
        ClosePicker()
        return 1
    end

    local Spot = GetTrainSpot()
    local Prompt = GetTrainPrompt(Spot)

    if not (Spot and Prompt and Prompt.Enabled) then
        return 0.5
    end

    if Prompt.ActionText ~= "Train" then
        return 0.5
    end

    local Now = os.clock()

    -- Opening the picker makes the game build all pet rows (heavy). Never reopen it in a tight loop.
    if Now < (getgenv().__BBOpenNext or 0) then
        return 1
    end

    if OpenTrain(Spot, Prompt) then
        return Config["Run Cooldown"]
    end

    if (getgenv().__BBTrainAllMaxed or 0) > os.clock() - 180 then
        return 90
    end

    getgenv().__BBOpenNext = os.clock() + 4

    return 4
end

-- LOOPS

local function Worker(Token)
    while getgenv().__BBTrainToken == Token and IsRunning() do
        getgenv().__BBTrainBeat = os.clock()

        local Ok, Delay = pcall(Step)

        if type(Delay) ~= "number" then
            Delay = 0.5
        end

        local Deadline = os.clock() + (Ok and Delay or 0.5)
        local ActiveToken = getgenv().__BBTrainToken

        while getgenv().__BBTrainToken == ActiveToken do
            getgenv().__BBTrainBeat = os.clock()

            local Remaining = Deadline - os.clock()

            if Remaining <= 0 then
                break
            end

            task.wait(math.min(Remaining, 0.2))
        end
    end
end

task.spawn(function()
    while task.wait(1) do
        if getgenv().__BBTrainGen ~= Gen then
            return
        end

        if IsRunning() and os.clock() - (getgenv().__BBTrainBeat or 0) > 5 then
            local Token = (getgenv().__BBTrainToken or 0) + 1
            getgenv().__BBTrainToken = Token
            getgenv().__BBTrainBeat = os.clock()
            task.spawn(Worker, Token)
        end
    end
end)

task.spawn(function()
    while getgenv().__BBTrainGen == Gen do
        local Delay = 0.5

        if getgenv().__BBSellDirty then
            getgenv().__BBSellDirty = nil
            task.spawn(function()
                pcall(RefreshSellDropdown)
            end)
        end

        if Config["Auto Sell Pet"] == true then
            local Ok, Value = pcall(SellTick)
            Delay = (Ok and type(Value) == "number") and Value or 1
        end

        task.wait(Delay)
    end
end)

task.spawn(function()
    while task.wait(0.1) do
        if getgenv().__BBTrainGen ~= Gen then
            return
        end

        pcall(function()
            if Config["Auto Farm Pet"] == true then
                FarmStep()
            end
        end)
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

    local Tab = Window:Tab({ Title = "Treadmill", Icon = "dumbbell" })

    Tab:Section({ Title = "Auto Treadmill" })

    Tab:Toggle({
        Title = "Auto Treadmill",
        Desc = "เปิดมินิเกมและกดปุ่มวิ่งอัตโนมัติ",
        Icon = "play",
        Type = "Checkbox",
        Value = Config["Auto Treadmill"],
        Callback = function(State)
            Config["Auto Treadmill"] = State
            getgenv().__BBTrainBeat = 0

            if State then
                Config["Auto Farm Pet"] = false
            end
        end,
    })

    Tab:Slider({
        Title = "Press Delay",
        Desc = "ระยะห่างระหว่างการกดแต่ละครั้ง (วินาที)",
        Step = 0.01,
        Value = {
            Min = 0.04,
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
                getgenv().__BBTrainPetLabel = nil
                return
            end

            Config["Pet Id"] = tonumber(string.match(Option, "%((%d+)%)")) or 0
            getgenv().__BBTrainPetLabel = Option
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
        Desc = "ขี่ pet ไปเส้นสตาร์ท กด SPACE อัตโนมัติ แล้ววิ่งเก็บเงินวนซ้ำ",
        Icon = "zap",
        Type = "Checkbox",
        Value = Config["Auto Farm Pet"],
        Callback = function(State)
            Config["Auto Farm Pet"] = State

            if State then
                Config["Auto Treadmill"] = false
                getgenv().__BBTrainBeat = os.clock()

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
        Desc = "เลือก pet ที่จะขี่ออกวิ่ง",
        Values = FarmLabels,
        Value = FarmSelected,
        AllowNone = false,
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
