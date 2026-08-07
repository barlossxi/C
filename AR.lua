local Loader = {}

local Global = (type(getgenv) == "function" and getgenv()) or _G
local StateKey = "__LegacyUiLoader"
local PreviousState = Global[StateKey]
if PreviousState and type(PreviousState.Unload) == "function" then
    pcall(PreviousState.Unload)
end

local State = {
    Library = nil,
    Services = nil,
    Config = {},
    Defaults = {},
    ExFunction = {},
    Controls = {},
    Threads = {},
    ConfigFolder = nil,
    DefaultConfigName = "Default",
    SelectedConfig = "Default",
    SelectionFile = "__selected_config.json",
    AutoSaveConfig = true,
    LoadingConfig = false,
    SaveQueued = false,
    SaveVersion = 0,
    Unloaded = false,
}
Global[StateKey] = State

local function valueType(value)
    return typeof and typeof(value) or type(value)
end

local function shallowCopy(source)
    local copy = {}
    for key, value in next, source or {} do
        copy[key] = value
    end
    return copy
end

local function merge(defaults, options)
    local result = shallowCopy(defaults)
    for key, value in next, options or {} do
        result[key] = value
    end
    return result
end

local function safeCall(callback, ...)
    if type(callback) ~= "function" then
        return true
    end

    local ok, result = pcall(callback, ...)
    if not ok then
        warn("[Legacy Loader] Callback error: " .. tostring(result))
    end

    return ok, result
end

local function hasFileSystem()
    return type(readfile) == "function"
        and type(writefile) == "function"
        and type(isfile) == "function"
        and type(isfolder) == "function"
        and type(makefolder) == "function"
end

local function normalizePath(path)
    local normalized = tostring(path or ""):gsub("\\", "/")
    return normalized:gsub("/+$", "")
end

local function joinPath(...)
    local parts = {}
    for _, part in next, { ... } do
        part = normalizePath(part)
        if part ~= "" then
            parts[#parts + 1] = part
        end
    end

    return table.concat(parts, "/")
end

local function ensureFolder(path)
    if not hasFileSystem() then
        return false
    end

    local current = ""
    for folder in string.gmatch(normalizePath(path), "[^/]+") do
        current = current == "" and folder or current .. "/" .. folder
        if not isfolder(current) then
            local ok = pcall(makefolder, current)
            if not ok then
                return false
            end
        end
    end

    return current ~= ""
end

local function sanitizeConfigName(name)
    name = tostring(name or State.DefaultConfigName):gsub("[/\\]", "")
    name = name:gsub("[:%*%?\"<>|]", ""):sub(1, 48)

    if name == "" or name == State.SelectionFile then
        return State.DefaultConfigName
    end

    return name
end

local function getHttpService()
    return State.Services and State.Services.HttpService or game:GetService("HttpService")
end

local function getUserId()
    local players = State.Services and State.Services.Players
    local player = players and players.LocalPlayer
    return tostring(player and player.UserId or 0)
end

local function encodeValue(value, seen)
    local kind = valueType(value)

    if kind == "Color3" then
        return {
            __type = "Color3",
            R = value.R,
            G = value.G,
            B = value.B,
        }
    end

    if kind == "Vector3" then
        return {
            __type = "Vector3",
            X = value.X,
            Y = value.Y,
            Z = value.Z,
        }
    end

    if kind == "CFrame" then
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

    if kind == "EnumItem" then
        return {
            __type = "EnumItem",
            Value = tostring(value),
        }
    end

    if kind == "table" then
        seen = seen or {}
        if seen[value] then
            return nil
        end

        seen[value] = true
        local encoded = {}
        for key, item in next, value do
            if type(key) == "string" or type(key) == "number" then
                local encodedItem = encodeValue(item, seen)
                if encodedItem ~= nil then
                    encoded[key] = encodedItem
                end
            end
        end
        seen[value] = nil
        return encoded
    end

    if kind == "string" or kind == "number" or kind == "boolean" then
        return value
    end

    return nil
end

local function decodeValue(value)
    if type(value) ~= "table" then
        return value
    end

    if value.__type == "Color3" then
        return Color3.new(tonumber(value.R) or 0, tonumber(value.G) or 0, tonumber(value.B) or 0)
    end

    if value.__type == "Vector3" then
        return Vector3.new(tonumber(value.X) or 0, tonumber(value.Y) or 0, tonumber(value.Z) or 0)
    end

    if value.__type == "CFrame" then
        return CFrame.new(tonumber(value.X) or 0, tonumber(value.Y) or 0, tonumber(value.Z) or 0)
            * CFrame.Angles(tonumber(value.RX) or 0, tonumber(value.RY) or 0, tonumber(value.RZ) or 0)
    end

    if value.__type == "EnumItem" then
        local enumName, itemName = tostring(value.Value):match("^Enum%.([^.]+)%.(.+)$")
        local enum = enumName and Enum[enumName]
        return enum and enum[itemName] or value.Value
    end

    local decoded = {}
    for key, item in next, value do
        decoded[key] = decodeValue(item)
    end
    return decoded
end

local function copyConfig(source)
    return decodeValue(encodeValue(source) or {})
end

local function replaceConfig(source)
    for key in next, State.Config do
        State.Config[key] = nil
    end

    for key, value in next, source or {} do
        State.Config[key] = decodeValue(value)
    end
end

local function getConfigPath(name)
    return joinPath(State.ConfigFolder, sanitizeConfigName(name) .. ".json")
end

local function getSelectionPath()
    return joinPath(State.ConfigFolder, State.SelectionFile)
end

local function readJson(path)
    if not hasFileSystem() or not isfile(path) then
        return nil
    end

    local ok, decoded = pcall(function()
        return getHttpService():JSONDecode(readfile(path))
    end)

    return ok and type(decoded) == "table" and decoded or nil
end

local function writeJson(path, data)
    if not hasFileSystem() then
        return false
    end

    local ok, encoded = pcall(function()
        return getHttpService():JSONEncode(data)
    end)

    if not ok then
        return false
    end

    local written = pcall(writefile, path, encoded)
    return written
end

local function getSelectedConfigs()
    return readJson(getSelectionPath()) or {}
end

local function saveSelectedConfig()
    if not ensureFolder(State.ConfigFolder) then
        return false
    end

    local selected = getSelectedConfigs()
    selected[getUserId()] = State.SelectedConfig
    return writeJson(getSelectionPath(), selected)
end

local function readSelectedConfig()
    return getSelectedConfigs()[getUserId()]
end

local function loadConfigData(name)
    if not ensureFolder(State.ConfigFolder) then
        return false
    end

    name = sanitizeConfigName(name)
    State.SelectedConfig = name
    saveSelectedConfig()

    local data = readJson(getConfigPath(name))
    if not data then
        return false
    end

    replaceConfig(State.Defaults)
    for key, value in next, data do
        State.Config[key] = decodeValue(value)
    end
    return true
end

local function saveConfigData(name)
    if not ensureFolder(State.ConfigFolder) then
        return false
    end

    State.SelectedConfig = sanitizeConfigName(name or State.SelectedConfig)
    local saved = writeJson(getConfigPath(State.SelectedConfig), encodeValue(State.Config) or {})
    if saved then
        saveSelectedConfig()
    end

    return saved
end

local function notify(title, message)
    if State.Library and type(State.Library.Notification) == "function" then
        pcall(function()
            State.Library:Notification(title, message, 3)
        end)
    end
end

local function stopLoop(flag)
    local thread = State.Threads[flag]
    if thread then
        pcall(task.cancel, thread)
        State.Threads[flag] = nil
    end
end

local function startLoop(flag)
    if State.Threads[flag] or State.Config[flag] ~= true then
        return
    end

    local callback = State.ExFunction[flag]
    if type(callback) ~= "function" then
        return
    end

    State.Threads[flag] = task.spawn(function()
        local ok, result = pcall(callback)
        if not ok then
            warn("[Legacy Loader] ExFunction " .. tostring(flag) .. " failed: " .. tostring(result))
        end
        State.Threads[flag] = nil
    end)
end

local function queueSave()
    if State.LoadingConfig or not State.AutoSaveConfig or State.SaveQueued then
        return
    end

    State.SaveQueued = true
    State.SaveVersion = State.SaveVersion + 1
    local version = State.SaveVersion

    task.delay(0.35, function()
        State.SaveQueued = false
        if not State.Unloaded and version == State.SaveVersion then
            saveConfigData()
        end
    end)
end

local function getControlValue(flag, default)
    local value = State.Config[flag]
    if value == nil then
        value = default
        State.Config[flag] = value
    end

    return value
end

local function registerControl(flag, control, apply)
    State.Controls[flag] = {
        Control = control,
        Apply = apply,
    }

    return control
end

local function applyControls()
    State.LoadingConfig = true

    for flag, record in next, State.Controls do
        local value = State.Config[flag]
        if value ~= nil and record.Apply then
            safeCall(record.Apply, value)
        end
    end

    State.LoadingConfig = false
end

local function controlData(text, data)
    local result = {}

    if type(text) == "table" then
        result = shallowCopy(text)
    else
        result.Name = text
    end

    for key, value in next, data or {} do
        result[key] = value
    end

    result.Name = result.Name or result.name or "Control"
    result.Flag = result.Flag or result.flag or result.Id or result.id or result.Name
    return result
end

local function onValueChanged(flag, value, callback, isToggle)
    State.Config[flag] = value
    safeCall(callback, value)

    if isToggle then
        if value == true then
            startLoop(flag)
        else
            stopLoop(flag)
        end
    end

    queueSave()
end

local function normalizeKey(key)
    if type(key) == "table" then
        key = key.Key
    end

    if valueType(key) == "EnumItem" then
        return tostring(key)
    end

    key = tostring(key or "Enum.KeyCode.Z")
    if key:sub(1, 5) == "Enum." then
        return key
    end

    if key == "M1B" then
        return "Enum.UserInputType.MouseButton1"
    end
    if key == "M2B" then
        return "Enum.UserInputType.MouseButton2"
    end

    return "Enum.KeyCode." .. key
end

function Loader:Init(options)
    options = merge({
        Library = nil,
        Config = {},
        ExFunction = {},
        ExportGlobals = true,
        AutoLoadConfig = true,
        AutoSaveConfig = true,
        ConfigFolder = "LegacyUI/" .. tostring(game.GameId) .. "/Configs",
        DefaultConfigName = "Default",
        SelectedConfig = nil,
    }, options)

    State.Library = options.Library or State.Library
    State.Services = State.Services or setmetatable({}, {
        __index = function(_, name)
            return game:GetService(name)
        end,
    })
    State.Config = options.Config or State.Config
    State.ExFunction = options.ExFunction or State.ExFunction
    State.ConfigFolder = normalizePath(options.ConfigFolder)
    State.DefaultConfigName = sanitizeConfigName(options.DefaultConfigName)
    State.SelectedConfig = sanitizeConfigName(options.SelectedConfig or readSelectedConfig() or State.DefaultConfigName)
    State.AutoSaveConfig = options.AutoSaveConfig ~= false
    State.Defaults = copyConfig(State.Config)
    State.Unloaded = false

    if options.AutoLoadConfig ~= false then
        loadConfigData(State.SelectedConfig)
    end

    if options.ExportGlobals ~= false then
        Global.Service = State.Services
        Global.Config = State.Config
        Global.Ex_Function = State.ExFunction
        Global.ExFunction = State.ExFunction
        Global.AddToggle = function(...)
            return Loader:AddToggle(...)
        end
        Global.AddSlider = function(...)
            return Loader:AddSlider(...)
        end
        Global.AddDropdown = function(...)
            return Loader:AddDropdown(...)
        end
        Global.AddTextbox = function(...)
            return Loader:AddTextbox(...)
        end
        Global.AddColorPicker = function(...)
            return Loader:AddColorPicker(...)
        end
        Global.AddKeybind = function(...)
            return Loader:AddKeybind(...)
        end
        Global.AddMenuKeybind = function(...)
            return Loader:AddMenuKeybind(...)
        end
    end

    return self
end

function Loader:GetService()
    return State.Services
end

function Loader:GetConfig()
    return State.Config
end

function Loader:GetSelectedConfig()
    return State.SelectedConfig
end

function Loader:GetConfigList()
    local configs = { State.DefaultConfigName }
    local seen = { [State.DefaultConfigName] = true }

    if not ensureFolder(State.ConfigFolder) or type(listfiles) ~= "function" then
        return configs
    end

    for _, path in next, listfiles(State.ConfigFolder) do
        local fileName = normalizePath(path):match("([^/]+)$")
        if fileName and fileName ~= State.SelectionFile and fileName:sub(-5) == ".json" then
            local name = fileName:sub(1, -6)
            if not seen[name] then
                seen[name] = true
                configs[#configs + 1] = name
            end
        end
    end

    table.sort(configs)
    return configs
end

function Loader:SaveConfig(name)
    return saveConfigData(name)
end

function Loader:LoadConfig(name)
    local loaded = loadConfigData(name or State.SelectedConfig)
    if loaded then
        applyControls()
    end

    return loaded
end

function Loader:DeleteConfig(name)
    name = sanitizeConfigName(name or State.SelectedConfig)
    if name == State.DefaultConfigName or not hasFileSystem() or type(delfile) ~= "function" then
        return false
    end

    local path = getConfigPath(name)
    if isfile(path) then
        pcall(delfile, path)
    end

    State.SelectedConfig = State.DefaultConfigName
    if not loadConfigData(State.SelectedConfig) then
        replaceConfig(State.Defaults)
    end
    applyControls()
    saveSelectedConfig()
    return true
end

function Loader:SetValue(flag, value)
    local record = State.Controls[flag]
    if record and record.Apply then
        record.Apply(value)
        return true
    end

    State.Config[flag] = value
    return false
end

function Loader:AddToggle(section, text, data)
    data = controlData(text, data)
    local flag = data.Flag
    local value = getControlValue(flag, data.Default == true)
    local initializing = true
    local control = section:Toggle({
        Name = data.Name,
        Flag = flag,
        Default = false,
        Callback = function(nextValue)
            if not initializing then
                onValueChanged(flag, nextValue == true, data.Callback, true)
            end
        end,
    })

    initializing = false
    control:Set(value == true)
    return registerControl(flag, control, function(nextValue)
        control:Set(nextValue == true)
    end)
end

function Loader:AddSlider(section, text, data)
    data = controlData(text, data)
    local flag = data.Flag
    local minimum = tonumber(data.Min or data.min) or 0
    local maximum = tonumber(data.Max or data.max) or 100
    local decimals = tonumber(data.Decimals or data.decimals) or 1
    local value = getControlValue(flag, tonumber(data.Default or data.default) or minimum)
    local initializing = true
    local control = section:Slider({
        Name = data.Name,
        Flag = flag,
        Min = minimum,
        Max = maximum,
        Default = minimum,
        Suffix = data.Suffix or data.suffix or "",
        Decimals = decimals,
        Callback = function(nextValue)
            if not initializing then
                onValueChanged(flag, nextValue, data.Callback, false)
            end
        end,
    })

    initializing = false
    control:Set(tonumber(value) or minimum)
    return registerControl(flag, control, function(nextValue)
        control:Set(tonumber(nextValue) or minimum)
    end)
end

function Loader:AddDropdown(section, text, data)
    data = controlData(text, data)
    local flag = data.Flag
    local items = data.Items or data.items or data.Values or data.values or {}
    local multi = data.Multi == true or data.multi == true
    local fallback = multi and (data.Default or data.default or {}) or (data.Default or data.default)
    local value = getControlValue(flag, fallback)
    local initializing = true
    local control = section:Dropdown({
        Name = data.Name,
        Flag = flag,
        Items = items,
        Multi = multi,
        MaxSize = data.MaxSize or data.maxsize or 75,
        Default = nil,
        Callback = function(nextValue)
            if not initializing then
                onValueChanged(flag, nextValue, data.Callback, false)
            end
        end,
    })

    initializing = false
    if value ~= nil and (not multi or type(value) == "table") then
        control:Set(value)
    end

    return registerControl(flag, control, function(nextValue)
        if nextValue ~= nil and (not multi or type(nextValue) == "table") then
            control:Set(nextValue)
        end
    end)
end

function Loader:AddTextbox(section, text, data)
    data = controlData(text, data)
    local flag = data.Flag
    local value = getControlValue(flag, data.Default or data.default or "")
    local numeric = data.Numeric == true or data.numeric == true
    local initializing = true
    local control = section:Textbox({
        Name = data.Name,
        Flag = flag,
        Placeholder = data.Placeholder or data.placeholder or "",
        Default = "",
        Callback = function(nextValue)
            if initializing then
                return
            end

            if numeric then
                nextValue = tonumber(nextValue)
                if not nextValue then
                    return
                end
            end
            onValueChanged(flag, nextValue, data.Callback, false)
        end,
    })

    initializing = false
    control:Set(tostring(value))
    return registerControl(flag, control, function(nextValue)
        control:Set(tostring(nextValue))
    end)
end

function Loader:AddColorPicker(section, text, data)
    data = controlData(text, data)
    local flag = data.Flag
    local alphaFlag = data.AlphaFlag or flag .. "Alpha"
    local color = getControlValue(flag, data.Default or data.default or Color3.new(1, 1, 1))
    local alpha = getControlValue(alphaFlag, tonumber(data.Alpha or data.alpha) or 0)
    local initializing = true
    local label = section:Label(data.Name, data.Alignment or data.alignment or "Left")
    local control = label:Colorpicker({
        Name = data.Name,
        Flag = flag,
        Default = Color3.new(1, 1, 1),
        Alpha = 0,
        Callback = function(nextColor, nextAlpha)
            if initializing then
                return
            end

            State.Config[flag] = nextColor
            State.Config[alphaFlag] = nextAlpha or 0
            safeCall(data.Callback, nextColor, nextAlpha or 0)
            queueSave()
        end,
    })

    initializing = false
    control:Set(color, alpha)
    return registerControl(flag, control, function(nextColor)
        control:Set(nextColor, State.Config[alphaFlag] or 0)
    end)
end

function Loader:AddColorpicker(...)
    return self:AddColorPicker(...)
end

local function addKeybind(section, text, data, isMenuKeybind)
    data = controlData(text, data)
    local flag = data.Flag
    local defaultValue = data.Default or data.default
    local fallback = {
        Key = normalizeKey(type(defaultValue) == "table" and defaultValue.Key or defaultValue or Enum.KeyCode.Z),
        Mode = data.Mode or data.mode or (type(defaultValue) == "table" and defaultValue.Mode) or "Toggle",
    }
    local value = getControlValue(flag, fallback)
    if type(value) ~= "table" then
        value = fallback
    end

    local initializing = true
    local control
    control = section:Keybind({
        Name = data.Name,
        Flag = flag,
        Default = nil,
        Mode = value.Mode or fallback.Mode,
        Callback = function(toggled)
            if initializing or not control then
                return
            end

            local nextValue = {
                Key = normalizeKey(control.Key),
                Mode = control.Mode or "Toggle",
                Toggled = toggled == true,
            }
            State.Config[flag] = nextValue

            if isMenuKeybind and State.Library then
                State.Library.MenuKeybind = nextValue.Key
            end

            safeCall(data.Callback, toggled == true, nextValue)
            queueSave()
        end,
    })

    initializing = false
    control:Set({
        Key = normalizeKey(value.Key or fallback.Key),
        Mode = value.Mode or fallback.Mode,
    })

    if isMenuKeybind and State.Library then
        State.Library.MenuKeybind = control.Key
    end

    return registerControl(flag, control, function(nextValue)
        nextValue = type(nextValue) == "table" and nextValue or fallback
        control:Set({
            Key = normalizeKey(nextValue.Key or fallback.Key),
            Mode = nextValue.Mode or fallback.Mode,
        })
    end)
end

function Loader:AddKeybind(section, text, data)
    return addKeybind(section, text, data, false)
end

function Loader:AddMenuKeybind(section, text, data)
    return addKeybind(section, text, data, true)
end

function Loader:AddButton(section, data)
    return section:Button(data or {})
end

function Loader:AddConfigControls(section)
    local updatingSelection = false
    local requestedName = ""
    local dropdown

    local function refreshList()
        local configs = Loader:GetConfigList()
        updatingSelection = true
        dropdown:Refresh(configs)
        dropdown:Set(State.SelectedConfig)
        updatingSelection = false
    end

    dropdown = section:Dropdown({
        Name = "Select Config",
        Flag = "__LoaderSelectedConfig",
        Items = Loader:GetConfigList(),
        Default = nil,
        Callback = function(name)
            if updatingSelection then
                return
            end

            if Loader:LoadConfig(name) then
                notify("Config", "Loaded " .. State.SelectedConfig)
            end
        end,
    })
    refreshList()

    local nameInput = section:Textbox({
        Name = "Config Name",
        Flag = "__LoaderConfigName",
        Placeholder = "Enter config name",
        Default = "",
        Callback = function(value)
            requestedName = tostring(value or "")
        end,
    })

    local createButton = section:Button({
        Name = "Create Config",
        Callback = function()
            local name = sanitizeConfigName(nameInput:Get() ~= "" and nameInput:Get() or requestedName)
            if name == State.DefaultConfigName and requestedName:gsub("%s+", "") == "" then
                notify("Config", "Enter a config name")
                return
            end

            if Loader:SaveConfig(name) then
                requestedName = ""
                nameInput:Set("")
                refreshList()
                notify("Config", "Created " .. name)
            end
        end,
    })

    local saveButton = section:Button({
        Name = "Save Config",
        Callback = function()
            if Loader:SaveConfig() then
                notify("Config", "Saved " .. State.SelectedConfig)
            end
        end,
    })

    local deleteButton = section:Button({
        Name = "Delete Config",
        Callback = function()
            local name = State.SelectedConfig
            if Loader:DeleteConfig(name) then
                refreshList()
                notify("Config", "Deleted " .. name)
            else
                notify("Config", "Default config cannot be deleted")
            end
        end,
    })

    return {
        Dropdown = dropdown,
        NameInput = nameInput,
        CreateButton = createButton,
        SaveButton = saveButton,
        DeleteButton = deleteButton,
    }
end

function Loader:Unload()
    if State.Unloaded then
        return
    end

    State.Unloaded = true
    for flag in next, State.Threads do
        stopLoop(flag)
    end

    State.Controls = {}
    if Global[StateKey] == State then
        Global[StateKey] = nil
    end
end

Loader.State = State
return Loader
