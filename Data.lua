local Loader = {}

local DEFAULTS = {
    Config = nil,
    ExFunction = nil,
    ExportGlobals = true,
    AntiAfk = true,
    AutoLoadConfig = true,
    AutoSaveConfig = true,
    ConfigFolder = nil,
    DefaultConfigName = "Default",
    SelectedConfig = nil,
}

local State = {
    Ready = false,
    Config = {},
    ExFunction = {},
    Threads = {},
    Controls = {},
    ConfigFolder = nil,
    DefaultConfigName = "Default",
    SelectedConfig = "Default",
    SelectionFile = "__selected_config.json",
    AutoSaveConfig = true,
    SaveQueue = 0,
    SaveQueued = false,
    LoadingConfig = false,
}

local function Merge(defaults, options)
    local result = {}

    for key, value in pairs(defaults) do
        result[key] = value
    end

    for key, value in pairs(options or {}) do
        result[key] = value
    end

    return result
end

local function SafeCall(callback, ...)
    if callback then
        local ok, err = pcall(callback, ...)
        if not ok then
            warn("[Loader] Callback error:", err)
        end
    end
end

function Loader:LoadTranslations(localPath, fallback)
    local compiler = loadstring or load
    fallback = typeof(fallback) == "table" and fallback or {}

    if type(compiler) ~= "function" then
        return fallback
    end

    if type(readfile) ~= "function" or type(isfile) ~= "function" or not isfile(localPath) then
        return fallback
    end

    local chunk, compileError = compiler(readfile(localPath))
    if not chunk then
        warn("[Loader] Translation compile error:", tostring(compileError))
        return fallback
    end

    local ok, result = pcall(chunk)
    if not ok then
        warn("[Loader] Translation runtime error:", tostring(result))
        return fallback
    end

    if typeof(result) ~= "table" then
        warn("[Loader] Translation file must return a table")
        return fallback
    end

    return result
end

function Loader.NormalizeLanguage(value)
    return string.upper(tostring(value or "EN")) == "TH" and "TH" or "EN"
end

function Loader.ApplyControlLocalization(control, name, description)
    if control and name and control.SetText then
        control:SetText(name)
    end

    if control and description ~= nil and control.SetDescription then
        control:SetDescription(description)
    end
end

function Loader:BindNeverLose(NeverLose)
    local function SnapshotTextLabels()
        local labels = {}

        for _, instance in next, NeverLose.ScreenGui:GetDescendants() do
            if instance:IsA("TextLabel") then
                labels[instance] = true
            end
        end

        return labels
    end

    local function FindCreatedTextLabel(snapshot, targetText)
        for _, instance in next, NeverLose.ScreenGui:GetDescendants() do
            if instance:IsA("TextLabel") and not snapshot[instance] and instance.Text == targetText then
                return instance
            end
        end
    end

    local function FindRegistryEntry(label, targetText)
        for index = #(NeverLose.NameRegisitry or {}), 1, -1 do
            local entry = NeverLose.NameRegisitry[index]
            if entry and entry.Idx == targetText and label:IsDescendantOf(entry.Root) then
                return entry
            end
        end
    end

    local function AttachTextSetter(control, label, initialText)
        if not control or not label then
            return control
        end

        local query = FindRegistryEntry(label, initialText)
        local originalSetText = control.SetText
        local originalSetDescription = control.SetDescription

        control.SetText = function(_, value)
            value = tostring(value)

            if originalSetText then
                originalSetText(control, value)
            else
                label.Text = value
            end

            if query then
                query.Idx = value
            end
        end

        if originalSetDescription then
            control.SetDescription = function(_, value)
                originalSetDescription(control, value)

                if query then
                    local nameValue = tostring(label.Text or "")
                    local descriptionValue = value and tostring(value) or ""
                    query.Idx = descriptionValue ~= "" and (nameValue .. " " .. descriptionValue) or nameValue
                end
            end
        end

        return control
    end

    local function CreateNamedControl(targetText, createFn)
        local snapshot = SnapshotTextLabels()
        local control = createFn()
        local label = FindCreatedTextLabel(snapshot, targetText)

        return AttachTextSetter(control, label, targetText), label
    end

    local function CaptureNamedLabels(targets, createFn)
        local snapshot = SnapshotTextLabels()
        local result = createFn()
        local labels = {}

        for _, instance in next, NeverLose.ScreenGui:GetDescendants() do
            if instance:IsA("TextLabel") and not snapshot[instance] and targets[instance.Text] and not labels[instance.Text] then
                labels[instance.Text] = instance
            end
        end

        return result, labels
    end

    return {
        AttachTextSetter = AttachTextSetter,
        CreateNamedControl = CreateNamedControl,
        CaptureNamedLabels = CaptureNamedLabels,
    }
end

local function AttachLabelSetter(control, label)
    if not control or not label or not label.SetText then
        return control
    end

    control.Label = label
    control.SetText = function(_, value)
        label:SetText(value)
    end

    if label.SetDescription then
        control.SetDescription = function(_, value)
            label:SetDescription(value)
        end
    end

    return control
end

local function ToArray(value)
    local selected = {}

    if typeof(value) ~= "table" then
        if value ~= nil then
            table.insert(selected, value)
        end

        return selected
    end

    for optionName, isSelected in pairs(value) do
        if isSelected == true then
            table.insert(selected, optionName)
        elseif typeof(optionName) == "number" and isSelected ~= nil then
            table.insert(selected, isSelected)
        end
    end

    return selected
end

local function ToDropdownDefault(value, values)
    local default = {}
    local selected = ToArray(value)

    for _, option in ipairs(values or {}) do
        default[option] = table.find(selected, option) ~= nil
    end

    return default
end

local function FileSystemSupported()
    return readfile and writefile and isfile and isfolder and makefolder
end

local function NormalizePath(path)
    local normalized = tostring(path or ""):gsub("\\", "/")
    normalized = normalized:gsub("/+$", "")
    return normalized
end

local function JoinPath(...)
    local parts = {}

    for _, part in ipairs({ ... }) do
        part = NormalizePath(part)
        if part ~= "" then
            table.insert(parts, part)
        end
    end

    return table.concat(parts, "/")
end

local function EnsureFolder(path)
    if not FileSystemSupported() then
        return false
    end

    path = NormalizePath(path)
    if path == "" then
        return false
    end

    local current = ""
    for folder in string.gmatch(path, "[^/]+") do
        current = current == "" and folder or (current .. "/" .. folder)

        if not isfolder(current) then
            local ok = pcall(makefolder, current)
            if not ok then
                return false
            end
        end
    end

    return true
end

local function SanitizeConfigName(configName)
    configName = tostring(configName or State.DefaultConfigName or "Default")
    configName = configName:gsub("[/\\]", ""):sub(1, 48)

    if configName == "" or configName == State.SelectionFile or (configName .. ".json") == State.SelectionFile then
        configName = State.DefaultConfigName or "Default"
    end

    return configName
end

local function GetHttpService()
    return State.Service and State.Service.HttpService or game:GetService("HttpService")
end

local function GetConfigPath(configName)
    return JoinPath(State.ConfigFolder, SanitizeConfigName(configName) .. ".json")
end

local function GetSelectionPath()
    return JoinPath(State.ConfigFolder, State.SelectionFile)
end

local function EncodeValue(value)
    local valueType = typeof(value)

    if valueType == "Color3" then
        return {
            __type = "Color3",
            R = value.R,
            G = value.G,
            B = value.B,
        }
    end

    if valueType == "CFrame" then
        local rx, ry, rz = value:ToOrientation()
        return {
            __type = "CFrame",
            X = value.Position.X,
            Y = value.Position.Y,
            Z = value.Position.Z,
            RX = rx,
            RY = ry,
            RZ = rz,
        }
    end

    if valueType == "table" then
        local encoded = {}

        for key, item in pairs(value) do
            if typeof(key) == "string" or typeof(key) == "number" then
                encoded[key] = EncodeValue(item)
            end
        end

        return encoded
    end

    if valueType == "string" or valueType == "number" or valueType == "boolean" then
        return value
    end

    return nil
end

local function DecodeValue(value)
    if typeof(value) ~= "table" then
        return value
    end

    if value.__type == "Color3" then
        return Color3.new(tonumber(value.R) or 0, tonumber(value.G) or 0, tonumber(value.B) or 0)
    end

    if value.__type == "CFrame" then
        return CFrame.new(tonumber(value.X) or 0, tonumber(value.Y) or 0, tonumber(value.Z) or 0)
            * CFrame.Angles(tonumber(value.RX) or 0, tonumber(value.RY) or 0, tonumber(value.RZ) or 0)
    end

    local decoded = {}
    for key, item in pairs(value) do
        decoded[key] = DecodeValue(item)
    end

    return decoded
end

local function GetSaveData()
    local data = {}

    for key, value in pairs(State.Config) do
        data[key] = EncodeValue(value)
    end

    return data
end

local function ApplySaveData(data)
    if typeof(data) ~= "table" then
        return false
    end

    for key, value in pairs(data) do
        State.Config[key] = DecodeValue(value)
    end

    return true
end

local function ReadUserSelections()
    if not FileSystemSupported() or not EnsureFolder(State.ConfigFolder) then
        return {}
    end

    local path = GetSelectionPath()
    if not isfile(path) then
        return {}
    end

    local ok, data = pcall(function()
        return GetHttpService():JSONDecode(readfile(path))
    end)

    if ok and typeof(data) == "table" then
        return data
    end

    return {}
end

local function SaveSelectedConfigForUser()
    if not FileSystemSupported() or not EnsureFolder(State.ConfigFolder) then
        return false
    end

    local selections = ReadUserSelections()
    local userId = tostring(State.Service.Players.LocalPlayer.UserId)
    selections[userId] = State.SelectedConfig

    local ok, encoded = pcall(function()
        return GetHttpService():JSONEncode(selections)
    end)

    if ok and encoded then
        writefile(GetSelectionPath(), encoded)
        return true
    end

    return false
end

local function GetSelectedConfigForUser()
    local selections = ReadUserSelections()
    local userId = tostring(State.Service.Players.LocalPlayer.UserId)
    return selections[userId]
end

local function SaveConfigNow()
    if not State.AutoSaveConfig or not FileSystemSupported() or not EnsureFolder(State.ConfigFolder) then
        return false
    end

    local ok, encoded = pcall(function()
        return GetHttpService():JSONEncode(GetSaveData())
    end)

    if not ok or not encoded then
        return false
    end

    local path = GetConfigPath(State.SelectedConfig)
    if not isfile(path) or readfile(path) ~= encoded then
        writefile(path, encoded)
    end

    SaveSelectedConfigForUser()
    return true
end

local function QueueSaveConfig()
    if State.LoadingConfig or not State.AutoSaveConfig or State.SaveQueued then
        return
    end

    State.SaveQueued = true
    State.SaveQueue = State.SaveQueue + 1
    local queueId = State.SaveQueue

    task.delay(0.35, function()
        State.SaveQueued = false
        if State.SaveQueue == queueId then
            SaveConfigNow()
        end
    end)
end

local function LoadConfigData(configName)
    if not FileSystemSupported() or not EnsureFolder(State.ConfigFolder) then
        warn("[Loader] Executor does not support config files")
        return false
    end

    configName = SanitizeConfigName(configName)
    State.SelectedConfig = configName
    SaveSelectedConfigForUser()

    local path = GetConfigPath(configName)
    if not isfile(path) then
        return false
    end

    local ok, data = pcall(function()
        return GetHttpService():JSONDecode(readfile(path))
    end)

    if not ok or typeof(data) ~= "table" then
        warn("[Loader] Failed to load config:", configName)
        return false
    end

    State.LoadingConfig = true
    ApplySaveData(data)
    State.LoadingConfig = false

    return true
end

local function ApplyConfigToControls()
    State.LoadingConfig = true

    for flagName, value in pairs(State.Config) do
        local control = State.Controls[flagName]
        if control and control.SetValue then
            SafeCall(function()
                control:SetValue(value)
            end)
        end
    end

    State.LoadingConfig = false
    QueueSaveConfig()
end

local function EnsureReady()
    if State.Ready then
        return
    end

    repeat task.wait() until game:IsLoaded()
        and game:GetService("Players").LocalPlayer
        and game:GetService("Players").LocalPlayer.Character
        and game:GetService("Players").LocalPlayer:FindFirstChild("PlayerGui")

    State.Service = setmetatable({}, {
        __index = function(_, key)
            local service = game:GetService(key)
            return cloneref and cloneref(service) or service
        end
    })

    State.Ready = true
end

local function StartLoop(flagName)
    local fn = State.ExFunction[flagName]
    if not fn or State.Threads[flagName] then
        return
    end

    State.Threads[flagName] = task.spawn(function()
        local ok, err = pcall(fn)
        if not ok then
            warn(flagName .. " Error:", err)
        end

        State.Threads[flagName] = nil
    end)
end

local function StopLoop(flagName)
    local thread = State.Threads[flagName]
    if not thread then
        return
    end

    task.cancel(thread)
    State.Threads[flagName] = nil
end

function Loader:Init(options)
    EnsureReady()

    local config = Merge(DEFAULTS, options)

    State.Config = config.Config or State.Config or {}
    State.ExFunction = config.ExFunction or State.ExFunction or {}
    State.AntiAfk = config.AntiAfk
    State.ConfigFolder = config.ConfigFolder or State.ConfigFolder or ("ZaHub/" .. tostring(game.GameId) .. "/Loader")
    State.DefaultConfigName = SanitizeConfigName(config.DefaultConfigName or State.DefaultConfigName)
    State.SelectedConfig = SanitizeConfigName(config.SelectedConfig or GetSelectedConfigForUser() or State.DefaultConfigName)
    State.AutoSaveConfig = config.AutoSaveConfig ~= false

    if config.AutoLoadConfig ~= false then
        LoadConfigData(State.SelectedConfig)
    end

    if State.AntiAfk and not State.AntiAfkThread then
        State.AntiAfkThread = task.spawn(function()
            local VirtualInputManager = State.Service.VirtualInputManager

            while task.wait(120) do
                pcall(function()
                    VirtualInputManager:SendMouseButtonEvent(500, 500, 0, true, game, 0)
                    task.wait(0.1)
                    VirtualInputManager:SendMouseButtonEvent(500, 500, 0, false, game, 0)
                end)
            end
        end)
    end

    if config.ExportGlobals then
        getgenv().Service = State.Service
        getgenv().Players = State.Service.Players
        getgenv().LocalPlayer = State.Service.Players.LocalPlayer
        getgenv().Workspace = State.Service.Workspace
        getgenv().HttpService = State.Service.HttpService
        getgenv().ReplicatedStorage = State.Service.ReplicatedStorage
        getgenv().RunService = State.Service.RunService
        getgenv().VirtualUser = State.Service.VirtualUser
        getgenv().VirtualInputManager = State.Service.VirtualInputManager
        getgenv().UserInputService = State.Service.UserInputService
        getgenv().TeleportService = State.Service.TeleportService
        getgenv().GuiService = State.Service.GuiService
        getgenv().TweenService = State.Service.TweenService
        getgenv().Camera = State.Service.Workspace.CurrentCamera
        getgenv().Config = State.Config
        getgenv().Ex_Function = State.ExFunction
        getgenv().AddToggle = function(...)
            return Loader:AddToggle(...)
        end
        getgenv().AddSlider = function(...)
            return Loader:AddSlider(...)
        end
        getgenv().AddDropdown = function(...)
            return Loader:AddDropdown(...)
        end
        getgenv().AddTextbox = function(...)
            return Loader:AddTextbox(...)
        end
        getgenv().AddKeybind = function(...)
            return Loader:AddKeybind(...)
        end
        getgenv().SaveLoaderConfig = function(...)
            return Loader:SaveConfig(...)
        end
        getgenv().LoadLoaderConfig = function(...)
            return Loader:LoadConfig(...)
        end
        getgenv().GetLoaderConfigs = function(...)
            return Loader:GetConfigList(...)
        end
    end

    return Loader
end

function Loader:GetConfig()
    return State.Config
end

function Loader:GetSelectedConfig()
    return State.SelectedConfig
end

function Loader:GetConfigList()
    local configs = {
        State.DefaultConfigName,
    }
    local seen = {
        [State.DefaultConfigName] = true,
    }

    if not FileSystemSupported() or not EnsureFolder(State.ConfigFolder) or not listfiles then
        return configs
    end

    for _, path in ipairs(listfiles(State.ConfigFolder)) do
        local fileName = NormalizePath(path):match("[^/]+$")

        if fileName and fileName ~= State.SelectionFile and fileName:sub(-5) == ".json" then
            local configName = fileName:sub(1, -6)
            if not seen[configName] then
                seen[configName] = true
                table.insert(configs, configName)
            end
        end
    end

    table.sort(configs)
    return configs
end

function Loader:SaveConfig(configName)
    if configName then
        State.SelectedConfig = SanitizeConfigName(configName)
    end

    return SaveConfigNow()
end

function Loader:LoadConfig(configName)
    local loaded = LoadConfigData(configName or State.SelectedConfig)
    ApplyConfigToControls()
    return loaded
end

function Loader:DeleteConfig(configName)
    configName = SanitizeConfigName(configName or State.SelectedConfig)

    if configName == State.DefaultConfigName or not FileSystemSupported() or not delfile then
        return false
    end

    local path = GetConfigPath(configName)
    if isfile(path) then
        delfile(path)
    end

    State.SelectedConfig = State.DefaultConfigName
    SaveSelectedConfigForUser()
    LoadConfigData(State.SelectedConfig)
    ApplyConfigToControls()

    return true
end

function Loader:AddConfigControls(where, logger)
    local selectedName = State.SelectedConfig
    local createName = ""

    SaveConfigNow()

    local dropdownLabel = where:AddLabel("Select Save")
    local dropdown = dropdownLabel:AddDropdown({
        Values = Loader:GetConfigList(),
        Default = selectedName,
        Flag = "__Loader Selected Save",
        Callback = function(value)
            selectedName = SanitizeConfigName(value)
            Loader:LoadConfig(selectedName)

            if logger then
                logger.new("folder", "Loaded " .. selectedName, 3.5)
            end
        end,
    })
    AttachLabelSetter(dropdown, dropdownLabel)

    local function RefreshSaveDropdown(nextSelected)
        nextSelected = SanitizeConfigName(nextSelected or State.SelectedConfig)
        dropdown:SetValues(Loader:GetConfigList())
        dropdown:SetValue(nextSelected)

        task.defer(function()
            dropdown:SetValues(Loader:GetConfigList())
            dropdown:SetValue(nextSelected)
        end)
    end

    local nameInputLabel = where:AddLabel("Config Name")
    local nameInput = nameInputLabel:AddTextInput({
        Placeholder = "Config Name",
        Default = "",
        Size = 100,
        Callback = function(value)
            createName = SanitizeConfigName(value)
        end,
    })
    AttachLabelSetter(nameInput, nameInputLabel)

    local createButton = where:AddButton({
        Name = "Create Config",
        Callback = function()
            local rawName = tostring(nameInput:GetValue() or createName or "")
            if rawName:gsub("%s+", "") == "" then
                if logger then
                    logger.new("triangle-alert", "Enter config name", 3.5)
                end

                return
            end

            createName = SanitizeConfigName(rawName)
            selectedName = createName
            Loader:SaveConfig(selectedName)
            RefreshSaveDropdown(selectedName)
            nameInput:SetValue("")

            if logger then
                logger.new("folder-plus", "Created " .. selectedName, 3.5)
            end
        end,
    })

    local deleteButton = where:AddButton({
        Name = "Delete Config",
        Callback = function()
            selectedName = SanitizeConfigName(dropdown:GetValue() or selectedName)

            if not Loader:DeleteConfig(selectedName) then
                if logger then
                    logger.new("trash-2", "Cannot delete " .. selectedName, 3.5)
                end

                return
            end

            RefreshSaveDropdown(State.SelectedConfig)

            if logger then
                logger.new("trash-2", "Deleted " .. selectedName, 3.5)
            end
        end,
    })

    return {
        Dropdown = dropdown,
        NameInput = nameInput,
        CreateButton = createButton,
        DeleteButton = deleteButton,
    }
end

function Loader:GetService()
    EnsureReady()
    return State.Service
end

function Loader:AddToggle(where, text, callback)
    local data = typeof(callback) == "table" and callback or {
        Callback = callback,
    }

    local function OnChanged(state)
        State.Config[text] = state
        SafeCall(data.Callback, state)

        if state then
            StartLoop(text)
        else
            StopLoop(text)
        end

        QueueSaveConfig()
    end

    local defaultValue = State.Config[text]
    if defaultValue == nil then
        defaultValue = data.Default or false
    end

    local label = where:AddLabel(text, {
        Description = data.Description,
    })
    local toggle = label:AddToggle({
        Default = defaultValue,
        Flag = text,
        Callback = OnChanged,
    })
    AttachLabelSetter(toggle, label)

    State.Controls[text] = toggle
    State.Config[text] = toggle:GetValue()

    if State.Config[text] then
        StartLoop(text)
    end

    QueueSaveConfig()

    return toggle
end

function Loader:AddSlider(where, text, data)
    data = data or {}

    local value = State.Config[text]
    if value == nil then
        value = data.Default
    end

    local label = where:AddLabel(text, {
        Description = data.Description,
    })
    local slider = label:AddSlider({
        Min = data.Min or 1,
        Max = data.Max or 100,
        Type = data.Type or "",
        Rounding = data.Rounding or 0,
        Nums = data.Nums or {},
        Size = data.Size or 100,
        Default = value,
        Flag = text,
        Callback = function(v)
            State.Config[text] = v
            SafeCall(data.Callback, v)
            QueueSaveConfig()
        end,
    })
    AttachLabelSetter(slider, label)

    State.Controls[text] = slider
    State.Config[text] = slider:GetValue()
    SafeCall(data.Callback, State.Config[text])
    QueueSaveConfig()

    return slider
end

function Loader:AddDropdown(where, text, data)
    data = data or {}

    local default
    if data.Multi then
        default = ToDropdownDefault(State.Config[text] or data.Default, data.Values)
    else
        default = State.Config[text]
        if default == nil then
            default = data.Default
        end
    end

    local label = where:AddLabel(text, {
        Description = data.Description,
    })
    local dropdown = label:AddDropdown({
        Default = default,
        Multi = data.Multi,
        AutoUpdate = data.AutoUpdate,
        Values = data.Values or {},
        Size = data.Size or 100,
        Flag = text,
        Callback = function(v)
            local value = data.Multi and ToArray(v) or v

            State.Config[text] = value
            SafeCall(data.Callback, value)
            QueueSaveConfig()
        end,
    })
    AttachLabelSetter(dropdown, label)

    State.Controls[text] = dropdown
    State.Config[text] = data.Multi and ToArray(dropdown:GetValue()) or dropdown:GetValue()
    SafeCall(data.Callback, State.Config[text])
    QueueSaveConfig()

    return dropdown
end

function Loader:AddTextbox(where, text, data)
    data = data or {}

    local value = State.Config[text]
    if value == nil then
        value = data.Default
    end

    local label = where:AddLabel(text, {
        Description = data.Description,
    })
    local textbox = label:AddTextInput({
        Placeholder = data.Placeholder,
        Numeric = data.Numeric,
        Size = data.Size or 100,
        Default = value,
        Flag = text,
        Callback = function(v)
            State.Config[text] = v
            SafeCall(data.Callback, v)
            QueueSaveConfig()
        end,
    })
    AttachLabelSetter(textbox, label)

    State.Controls[text] = textbox
    State.Config[text] = textbox:GetValue()
    SafeCall(data.Callback, State.Config[text])
    QueueSaveConfig()

    return textbox
end

function Loader:AddKeybind(where, text, data)
    data = data or {}

    local value = State.Config[text]
    if value == nil then
        value = data.Default
    end

    local label = where:AddLabel(text, {
        Description = data.Description,
    })
    local keybind = label:AddKeybind({
        Default = value,
        Flag = text,
        Callback = function(v)
            State.Config[text] = v
            SafeCall(data.Callback, v)
            QueueSaveConfig()
        end,
    })
    AttachLabelSetter(keybind, label)

    State.Controls[text] = keybind
    State.Config[text] = keybind:GetValue()
    SafeCall(data.Callback, State.Config[text])
    QueueSaveConfig()

    return keybind
end

return Loader
