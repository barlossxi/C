
if not game:IsLoaded() then
    game.Loaded:Wait()
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    repeat
        task.wait()
        LocalPlayer = Players.LocalPlayer
    until LocalPlayer
end

local Environment = (type(getgenv) == "function" and getgenv()) or _G

if type(Environment.SaveMapCleanup) == "function" then
    pcall(Environment.SaveMapCleanup)
end

local function DeepCopy(Value)
    if type(Value) ~= "table" then
        return Value
    end

    local Copy = {}
    for Key, Item in next, Value do
        Copy[Key] = DeepCopy(Item)
    end
    return Copy
end

local function MergeInto(Destination, Source)
    if type(Source) ~= "table" then
        return Destination
    end

    for Key, Value in next, Source do
        if type(Value) == "table" and type(Destination[Key]) == "table" then
            MergeInto(Destination[Key], Value)
        else
            Destination[Key] = Value
        end
    end

    return Destination
end

local DefaultConfig = {
    UI = {
        Enabled = true,
        Title = "SaveMap",
        ToggleKey = "RightShift",
        Width = 460,
        Height = 340,
        Accent = Color3.fromRGB(88, 166, 255),
    },
    Save = {
        Name = "",
        FilePath = "",
        AddTimestamp = true,
        AutoSave = false,
        AutoSaveDelay = 0.5,
        Mode = "optimized",
        Decompile = false,
        SaveBytecode = false,
        SafeMode = true,
        ShowStatus = true,
        ReadMe = true,
        AvoidFileOverwrite = true,
        BoostFPS = false,
        ShutdownWhenDone = false,
        AntiIdle = false,
        IgnoreDefaultProperties = true,
        IgnoreNotArchivable = true,
        IgnoreSpecialProperties = false,
        IgnoreSharedStrings = false,
        TreatUnionsAsParts = false,
        AlternativeWritefile = true,
        NilInstances = false,
        SaveNotCreatable = false,
        RemovePlayerCharacters = true,
        IsolatePlayers = false,
        IsolateLocalPlayer = false,
        IsolateLocalPlayerCharacter = false,
        IsolateStarterPlayer = false,
        IgnoreList = {
            "CoreGui",
            "CorePackages",
            "RobloxGui",
            Packages = false,
        },
    },
    Runtime = {
        UsePrepass = true,
        WarmDecompiler = false,
        RequestsPerMinute = 1400,
        MaxInFlight = 30,
        RequestTimeout = 20,
        ApiUrl = "https://api.lua.expert/decompile",
        Verbose = true,
        UssiPrepassURL = "https://gitlab.com/centerepic/ussiprepass/-/raw/main/main.luau",
        UssiRepoURL = "https://raw.githubusercontent.com/luau/UniversalSynSaveInstance/main/",
        UssiScript = "saveinstance",
    },
}

local Config = DeepCopy(DefaultConfig)
MergeInto(Config, Environment.SaveMapConfig)

local State = {
    Destroyed = false,
    Saving = false,
    LastPath = "",
    UiVisible = true,
}

local Ui = {
    Root = nil,
    Main = nil,
    SaveButton = nil,
    Status = nil,
    PathPreview = nil,
    NameBox = nil,
    SafeModeToggle = nil,
    DecompileToggle = nil,
    RemovePlayersToggle = nil,
    Connections = {},
}

local RunSave

local function Trim(Value)
    if type(Value) ~= "string" then
        return ""
    end
    return Value:gsub("^%s+", ""):gsub("%s+$", "")
end

local function SanitizeFileName(Value)
    Value = Trim(Value)
    Value = Value:gsub("[<>:\"/\\|%?%*]", "_")
    Value = Value:gsub("[%c]", "_")
    Value = Value:gsub("%s+$", "")
    return Value
end

local function GetPlaceLabel()
    local PlaceName = "Place"
    pcall(function()
        if game.Name and game.Name ~= "" then
            PlaceName = game.Name
        end
    end)
    return SanitizeFileName(PlaceName)
end

local function BuildFilePath()
    local CustomPath = Trim(Config.Save.FilePath)
    if CustomPath ~= "" then
        return CustomPath
    end

    local Name = SanitizeFileName(Config.Save.Name)
    if Name == "" then
        Name = "Map_" .. GetPlaceLabel()
    end

    local BaseName, ExistingExtension = Name:match("^(.*)(%.rbxlx?)$")
    if not BaseName then
        BaseName, ExistingExtension = Name:match("^(.*)(%.rbxmx?)$")
    end
    if BaseName then
        Name = BaseName
    end

    if Config.Save.AddTimestamp then
        Name = Name .. "_" .. os.date("%Y%m%d_%H%M%S")
    end

    return Name .. (ExistingExtension or "")
end

local function GetToggleKey()
    local Key = Config.UI.ToggleKey
    if typeof(Key) == "EnumItem" then
        return Key
    end

    if type(Key) == "string" then
        local Ok, EnumKey = pcall(function()
            return Enum.KeyCode[Key]
        end)
        if Ok and EnumKey then
            return EnumKey
        end
    end

    return Enum.KeyCode.RightShift
end

local function SetStatus(Text, IsError)
    if Ui.Status and Ui.Status.Parent then
        Ui.Status.Text = tostring(Text)
        Ui.Status.TextColor3 = IsError
            and Color3.fromRGB(255, 121, 121)
            or Color3.fromRGB(166, 172, 184)
    end
end

local function GetOutputPath(FilePath)
    local Extension = ".rbxlx"
    if string.find(FilePath, "%.rbxlx?$") or string.find(FilePath, "%.rbxmx?$") then
        return FilePath
    end
    return FilePath .. Extension
end

local function UpdatePathPreview()
    local Path = BuildFilePath()
    Path = GetOutputPath(Path)

    if Ui.PathPreview and Ui.PathPreview.Parent then
        Ui.PathPreview.Text = Path
    end
end

local function DisconnectUiConnections()
    for Index, Connection in next, Ui.Connections do
        pcall(function()
            Connection:Disconnect()
        end)
        Ui.Connections[Index] = nil
    end
end

local function DestroyUi()
    DisconnectUiConnections()
    if Ui.Root then
        pcall(function()
            Ui.Root:Destroy()
        end)
    end

    Ui.Root = nil
    Ui.Main = nil
    Ui.SaveButton = nil
    Ui.Status = nil
    Ui.PathPreview = nil
    Ui.NameBox = nil
    Ui.SafeModeToggle = nil
    Ui.DecompileToggle = nil
    Ui.RemovePlayersToggle = nil
end

local function GetGuiParent()
    if type(gethui) == "function" then
        local Ok, HiddenUi = pcall(gethui)
        if Ok and HiddenUi then
            return HiddenUi
        end
    end

    local CoreGui = game:GetService("CoreGui")
    if CoreGui then
        return CoreGui
    end

    return LocalPlayer:WaitForChild("PlayerGui")
end

local function NewInstance(ClassName, Properties, Parent)
    local Object = Instance.new(ClassName)
    for Property, Value in next, Properties do
        Object[Property] = Value
    end
    Object.Parent = Parent
    return Object
end

local function AddCorner(Object, Radius)
    return NewInstance("UICorner", {
        CornerRadius = UDim.new(0, Radius or 8),
    }, Object)
end

local function AddStroke(Object, Color, Transparency)
    return NewInstance("UIStroke", {
        Color = Color,
        Transparency = Transparency or 0,
        Thickness = 1,
    }, Object)
end

local function AddConnection(Connection)
    Ui.Connections[#Ui.Connections + 1] = Connection
    return Connection
end

local function MakeLabel(Parent, Text, Position, Size, TextSize, Color)
    return NewInstance("TextLabel", {
        BackgroundTransparency = 1,
        Position = Position,
        Size = Size,
        Font = Enum.Font.Gotham,
        Text = Text,
        TextColor3 = Color or Color3.fromRGB(232, 235, 242),
        TextSize = TextSize or 13,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
    }, Parent)
end

local function MakeMacDot(Parent, Color, Position)
    local Dot = NewInstance("Frame", {
        BackgroundColor3 = Color,
        BorderSizePixel = 0,
        Position = Position,
        Size = UDim2.fromOffset(12, 12),
    }, Parent)
    AddCorner(Dot, 12)
    return Dot
end

local function SetToggle(Button, Enabled, Label)
    Button.Text = Enabled and "ON" or "OFF"
    Button.TextColor3 = Enabled
        and Color3.fromRGB(214, 240, 224)
        or Color3.fromRGB(190, 195, 204)
    Button.BackgroundColor3 = Enabled
        and Color3.fromRGB(32, 104, 69)
        or Color3.fromRGB(49, 53, 62)
    Button:SetAttribute("Enabled", Enabled)
    Button:SetAttribute("Label", Label)
end

local function MakeToggle(Parent, Label, Position, Enabled, OnChanged)
    MakeLabel(
        Parent,
        Label,
        Position,
        UDim2.fromOffset(210, 28),
        13,
        Color3.fromRGB(206, 211, 221)
    )

    local Button = NewInstance("TextButton", {
        AutoButtonColor = false,
        BackgroundColor3 = Color3.fromRGB(49, 53, 62),
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Position = Position + UDim2.fromOffset(220, 1),
        Size = UDim2.fromOffset(50, 26),
        TextSize = 10,
        Text = "OFF",
    }, Parent)
    AddCorner(Button, 7)
    SetToggle(Button, Enabled, Label)

    AddConnection(Button.MouseButton1Click:Connect(function()
        local NextValue = not Button:GetAttribute("Enabled")
        SetToggle(Button, NextValue, Label)
        OnChanged(NextValue)
        UpdatePathPreview()
    end))

    return Button
end

local function CreateUi()
    DestroyUi()

    local Accent = typeof(Config.UI.Accent) == "Color3"
        and Config.UI.Accent
        or Color3.fromRGB(88, 166, 255)
    local Width = math.clamp(tonumber(Config.UI.Width) or 460, 380, 620)
    local Height = math.clamp(tonumber(Config.UI.Height) or 340, 300, 460)
    local Parent = GetGuiParent()

    Ui.Root = NewInstance("ScreenGui", {
        DisplayOrder = 2147483000,
        IgnoreGuiInset = true,
        Name = "SaveMapMacUI",
        ResetOnSpawn = false,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    }, Parent)

    Ui.Main = NewInstance("Frame", {
        AnchorPoint = Vector2.new(0.5, 0.5),
        BackgroundColor3 = Color3.fromRGB(25, 27, 32),
        BorderSizePixel = 0,
        Position = UDim2.fromScale(0.5, 0.5),
        Size = UDim2.fromOffset(Width, Height),
    }, Ui.Root)
    AddCorner(Ui.Main, 11)
    AddStroke(Ui.Main, Color3.fromRGB(74, 79, 91), 0.35)

    local Header = NewInstance("Frame", {
        BackgroundColor3 = Color3.fromRGB(31, 34, 40),
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 44),
    }, Ui.Main)
    AddCorner(Header, 11)
    NewInstance("Frame", {
        BackgroundColor3 = Color3.fromRGB(31, 34, 40),
        BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 1, -11),
        Size = UDim2.new(1, 0, 0, 11),
    }, Header)

    MakeMacDot(Header, Color3.fromRGB(255, 95, 86), UDim2.fromOffset(16, 16))
    MakeMacDot(Header, Color3.fromRGB(255, 189, 46), UDim2.fromOffset(36, 16))
    MakeMacDot(Header, Color3.fromRGB(39, 201, 63), UDim2.fromOffset(56, 16))

    MakeLabel(
        Header,
        tostring(Config.UI.Title or "SaveMap"),
        UDim2.fromOffset(84, 5),
        UDim2.new(1, -100, 0, 20),
        13,
        Color3.fromRGB(242, 244, 248)
    ).Font = Enum.Font.GothamBold
    MakeLabel(
        Header,
        "place",
        UDim2.fromOffset(84, 22),
        UDim2.new(1, -100, 0, 16),
        10,
        Color3.fromRGB(145, 151, 163)
    )

    local Content = NewInstance("Frame", {
        BackgroundTransparency = 1,
        Position = UDim2.fromOffset(20, 58),
        Size = UDim2.new(1, -40, 1, -72),
    }, Ui.Main)

    MakeLabel(
        Content,
        "Map name",
        UDim2.fromOffset(0, 0),
        UDim2.fromOffset(120, 24),
        12,
        Color3.fromRGB(157, 164, 177)
    )

    Ui.NameBox = NewInstance("TextBox", {
        BackgroundColor3 = Color3.fromRGB(38, 42, 50),
        BorderSizePixel = 0,
        ClearTextOnFocus = false,
        Font = Enum.Font.Gotham,
        PlaceholderColor3 = Color3.fromRGB(111, 118, 131),
        PlaceholderText = "Map name",
        Position = UDim2.fromOffset(0, 26),
        Size = UDim2.new(1, 0, 0, 34),
        Text = tostring(Config.Save.Name or ""),
        TextColor3 = Color3.fromRGB(235, 238, 244),
        TextSize = 13,
        TextXAlignment = Enum.TextXAlignment.Left,
    }, Content)
    AddCorner(Ui.NameBox, 7)
    AddStroke(Ui.NameBox, Color3.fromRGB(74, 81, 94), 0.35)
    NewInstance("UIPadding", {
        PaddingLeft = UDim.new(0, 11),
        PaddingRight = UDim.new(0, 11),
    }, Ui.NameBox)

    AddConnection(Ui.NameBox:GetPropertyChangedSignal("Text"):Connect(function()
        Config.Save.Name = SanitizeFileName(Ui.NameBox.Text)
        UpdatePathPreview()
    end))
    AddConnection(Ui.NameBox.FocusLost:Connect(function()
        Ui.NameBox.Text = SanitizeFileName(Ui.NameBox.Text)
        Config.Save.Name = Ui.NameBox.Text
        UpdatePathPreview()
    end))

    MakeLabel(
        Content,
        "Output",
        UDim2.fromOffset(0, 66),
        UDim2.fromOffset(120, 18),
        10,
        Color3.fromRGB(139, 146, 159)
    )
    Ui.PathPreview = MakeLabel(
        Content,
        "",
        UDim2.fromOffset(58, 66),
        UDim2.new(1, -58, 0, 18),
        10,
        Color3.fromRGB(139, 146, 159)
    )
    Ui.PathPreview.TextTruncate = Enum.TextTruncate.AtEnd

    Ui.DecompileToggle = MakeToggle(
        Content,
        "Include scripts",
        UDim2.fromOffset(0, 94),
        Config.Save.Decompile == true,
        function(Value)
            Config.Save.Decompile = Value
        end
    )
    Ui.SafeModeToggle = MakeToggle(
        Content,
        "Safe mode",
        UDim2.fromOffset(0, 126),
        Config.Save.SafeMode == true,
        function(Value)
            Config.Save.SafeMode = Value
        end
    )
    Ui.RemovePlayersToggle = MakeToggle(
        Content,
        "Remove player characters",
        UDim2.fromOffset(0, 158),
        Config.Save.RemovePlayerCharacters == true,
        function(Value)
            Config.Save.RemovePlayerCharacters = Value
        end
    )

    Ui.SaveButton = NewInstance("TextButton", {
        AutoButtonColor = false,
        BackgroundColor3 = Accent,
        BorderSizePixel = 0,
        Font = Enum.Font.GothamBold,
        Position = UDim2.new(0, 0, 1, -54),
        Size = UDim2.new(0.57, -6, 0, 38),
        Text = "Save map",
        TextColor3 = Color3.fromRGB(12, 18, 28),
        TextSize = 13,
    }, Content)
    AddCorner(Ui.SaveButton, 8)

    local HideButton = NewInstance("TextButton", {
        AutoButtonColor = false,
        BackgroundColor3 = Color3.fromRGB(49, 53, 62),
        BorderSizePixel = 0,
        Font = Enum.Font.Gotham,
        Position = UDim2.new(0.57, 2, 1, -54),
        Size = UDim2.new(0.43, -2, 0, 38),
        Text = "Hide",
        TextColor3 = Color3.fromRGB(213, 217, 225),
        TextSize = 13,
    }, Content)
    AddCorner(HideButton, 8)

    Ui.Status = MakeLabel(
        Content,
        "Ready",
        UDim2.fromOffset(0, 194),
        UDim2.new(1, 0, 0, 22),
        11,
        Color3.fromRGB(166, 172, 184)
    )
    Ui.Status.TextTruncate = Enum.TextTruncate.AtEnd

    AddConnection(Ui.SaveButton.MouseButton1Click:Connect(function()
        if Ui.NameBox then
            Config.Save.Name = SanitizeFileName(Ui.NameBox.Text)
            Ui.NameBox.Text = Config.Save.Name
        end
        RunSave()
    end))
    AddConnection(HideButton.MouseButton1Click:Connect(function()
        State.UiVisible = false
        Ui.Main.Visible = false
    end))

    local Dragging = false
    local DragStart
    local StartPosition

    AddConnection(Header.InputBegan:Connect(function(Input)
        if Input.UserInputType == Enum.UserInputType.MouseButton1
            or Input.UserInputType == Enum.UserInputType.Touch then
            Dragging = true
            DragStart = Input.Position
            StartPosition = Ui.Main.Position

            local EndConnection
            EndConnection = Input.Changed:Connect(function()
                if Input.UserInputState == Enum.UserInputState.End then
                    Dragging = false
                    EndConnection:Disconnect()
                end
            end)
            AddConnection(EndConnection)
        end
    end))
    AddConnection(UserInputService.InputChanged:Connect(function(Input)
        if not Dragging then
            return
        end
        if Input.UserInputType ~= Enum.UserInputType.MouseMovement
            and Input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end

        local Delta = Input.Position - DragStart
        Ui.Main.Position = UDim2.new(
            StartPosition.X.Scale,
            StartPosition.X.Offset + Delta.X,
            StartPosition.Y.Scale,
            StartPosition.Y.Offset + Delta.Y
        )
    end))

    UpdatePathPreview()
    SetStatus("Ready")
end

local function BuildOptions()
    local FilePath = BuildFilePath()
    local Mode = string.lower(tostring(Config.Save.Mode or "optimized"))

    if Mode ~= "full" and Mode ~= "optimized" and Mode ~= "scripts" then
        Mode = "optimized"
    end

    return {
        mode = Mode,
        FilePath = FilePath,
        Decompile = Config.Save.Decompile == true,
        SaveBytecode = Config.Save.SaveBytecode == true,
        SafeMode = Config.Save.SafeMode == true,
        ShowStatus = Config.Save.ShowStatus == true,
        ReadMe = Config.Save.ReadMe == true,
        AvoidFileOverwrite = Config.Save.AvoidFileOverwrite ~= false,
        BoostFPS = Config.Save.BoostFPS == true,
        ShutdownWhenDone = Config.Save.ShutdownWhenDone == true,
        AntiIdle = Config.Save.AntiIdle == true,
        IgnoreDefaultProperties = Config.Save.IgnoreDefaultProperties ~= false,
        IgnoreNotArchivable = Config.Save.IgnoreNotArchivable ~= false,
        IgnoreSpecialProperties = Config.Save.IgnoreSpecialProperties == true,
        IgnoreSharedStrings = Config.Save.IgnoreSharedStrings == true,
        TreatUnionsAsParts = Config.Save.TreatUnionsAsParts == true,
        AlternativeWritefile = Config.Save.AlternativeWritefile ~= false,
        NilInstances = Config.Save.NilInstances == true,
        SaveNotCreatable = Config.Save.SaveNotCreatable == true,
        SavePlayerCharacters = not (Config.Save.RemovePlayerCharacters == true),
        IsolatePlayers = Config.Save.IsolatePlayers == true,
        IsolateLocalPlayer = Config.Save.IsolateLocalPlayer == true,
        IsolateLocalPlayerCharacter = Config.Save.IsolateLocalPlayerCharacter == true,
        IsolateStarterPlayer = Config.Save.IsolateStarterPlayer == true,
        IgnoreList = Config.Save.IgnoreList,
    }, FilePath
end

local function LoadChunk(Url, ChunkName)
    local Source = game:HttpGet(Url, true)
    local Chunk, LoadError = loadstring(Source, ChunkName)
    assert(Chunk, LoadError or ("failed to load " .. ChunkName))

    local Ok, Result = pcall(Chunk)
    assert(Ok, Result)
    return Result
end

local function HasPrepassCapabilities()
    local HttpRequest = request or (http and http.request) or http_request
    return type(getscriptbytecode) == "function" and type(HttpRequest) == "function"
end

local function RunUssi(Options)
    local Runtime = Config.Runtime
    local UsePrepass = Runtime.UsePrepass ~= false and HasPrepassCapabilities()

    if Runtime.UsePrepass ~= false and not UsePrepass then
        SetStatus("Prepass unavailable; using USSI")
    end

    if UsePrepass then
        local Prepass = LoadChunk(Runtime.UssiPrepassURL, "ussiprepass")
        assert(type(Prepass) == "function", "ussiprepass did not return a function")

        local PrepassOptions = {
            RequestsPerMinute = tonumber(Runtime.RequestsPerMinute) or 1400,
            MaxInFlight = tonumber(Runtime.MaxInFlight) or 30,
            RequestTimeout = tonumber(Runtime.RequestTimeout) or 20,
            ApiUrl = Runtime.ApiUrl,
            Verbose = Runtime.Verbose ~= false,
            SkipPrepass = Runtime.WarmDecompiler ~= true,
            SkipSaveInstance = false,
            UssiRepoURL = Runtime.UssiRepoURL,
            UssiScript = Runtime.UssiScript,
        }

        return Prepass(Options, PrepassOptions)
    end

    local RepoUrl = tostring(Runtime.UssiRepoURL or "")
    if not string.match(RepoUrl, "/$") then
        RepoUrl = RepoUrl .. "/"
    end

    local ScriptName = tostring(Runtime.UssiScript or "saveinstance")
    local SaveInstance = LoadChunk(
        RepoUrl .. ScriptName .. ".luau",
        ScriptName
    )
    assert(type(SaveInstance) == "function", "saveinstance did not return a function")
    return SaveInstance(Options)
end

RunSave = function()
    if State.Destroyed or State.Saving then
        return false, "busy"
    end

    State.Saving = true
    local Options, FilePath = BuildOptions()
    State.LastPath = FilePath
    SetStatus("Saving " .. tostring(FilePath) .. "...")

    if Ui.SaveButton and Ui.SaveButton.Parent then
        Ui.SaveButton.Active = false
        Ui.SaveButton.Text = "Saving..."
    end

    local Ok, ErrorMessage = xpcall(function()
        return RunUssi(Options)
    end, function(Error)
        return debug.traceback(tostring(Error), 2)
    end)

    State.Saving = false
    if Ui.SaveButton and Ui.SaveButton.Parent then
        Ui.SaveButton.Active = true
        Ui.SaveButton.Text = "Save map"
    end

    if not Ok then
        SetStatus("Failed: " .. tostring(ErrorMessage), true)
        warn("[SaveMap] save failed:", ErrorMessage)
        return false, ErrorMessage
    end

    local OutputPath = GetOutputPath(FilePath)
    if type(isfile) == "function" then
        local FileCheckOk, Exists = pcall(isfile, OutputPath)
        if FileCheckOk and not Exists then
            SetStatus("Finished; file not found", true)
            warn("[SaveMap] USSI finished but output was not found:", OutputPath)
            return false, "output file was not found"
        end
    end

    SetStatus("Saved: " .. tostring(OutputPath))
    return true, OutputPath
end

local function ShowUi()
    if not Config.UI.Enabled then
        return
    end

    if not Ui.Root or not Ui.Root.Parent then
        CreateUi()
    end

    State.UiVisible = true
    Ui.Main.Visible = true
end

local function ToggleUi()
    if not Ui.Root or not Ui.Root.Parent then
        ShowUi()
        return
    end

    State.UiVisible = not State.UiVisible
    Ui.Main.Visible = State.UiVisible
end

local ToggleKey = GetToggleKey()
local KeyConnection = UserInputService.InputBegan:Connect(function(Input, GameProcessed)
    if GameProcessed then
        return
    end
    if Input.KeyCode == ToggleKey then
        ToggleUi()
    end
end)

local function Cleanup()
    if State.Destroyed then
        return
    end
    State.Destroyed = true
    pcall(function()
        KeyConnection:Disconnect()
    end)
    DestroyUi()
end

Environment.SaveMapConfig = Config
Environment.SaveMapRun = RunSave
Environment.SaveMapShow = ShowUi
Environment.SaveMapToggle = ToggleUi
Environment.SaveMapCleanup = Cleanup

if Config.UI.Enabled then
    CreateUi()
end

if Config.Save.AutoSave then
    task.delay(math.max(tonumber(Config.Save.AutoSaveDelay) or 0.5, 0), function()
        if not State.Destroyed then
            RunSave()
        end
    end)
end

assert(type(BuildFilePath()) == "string" and BuildFilePath() ~= "", "SaveMap file path self-check failed")
