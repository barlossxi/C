local Loader = {}

local DEFAULTS = {
    Config = nil,
    ExFunction = nil,
    ExportGlobals = true,
    AntiAfk = true,
}

local State = {
    Ready = false,
    Config = {},
    ExFunction = {},
    Threads = {},
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
    end

    return Loader
end

function Loader:GetConfig()
    return State.Config
end

function Loader:GetService()
    EnsureReady()
    return State.Service
end

function Loader:AddToggle(where, text, callback)
    local function OnChanged(state)
        State.Config[text] = state
        SafeCall(callback, state)

        if state then
            StartLoop(text)
        else
            StopLoop(text)
        end
    end

    local toggle = where:AddLabel(text):AddToggle({
        Default = State.Config[text] or false,
        Flag = text,
        Callback = OnChanged,
    })

    State.Config[text] = toggle:GetValue()

    if State.Config[text] then
        StartLoop(text)
    end

    return toggle
end

function Loader:AddSlider(where, text, data)
    data = data or {}

    local value = State.Config[text]
    if value == nil then
        value = data.Default
    end

    local slider = where:AddLabel(text):AddSlider({
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
        end,
    })

    State.Config[text] = slider:GetValue()
    SafeCall(data.Callback, State.Config[text])

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

    local dropdown = where:AddLabel(text):AddDropdown({
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
        end,
    })

    State.Config[text] = data.Multi and ToArray(dropdown:GetValue()) or dropdown:GetValue()
    SafeCall(data.Callback, State.Config[text])

    return dropdown
end

function Loader:AddTextbox(where, text, data)
    data = data or {}

    local value = State.Config[text]
    if value == nil then
        value = data.Default
    end

    local textbox = where:AddLabel(text):AddTextInput({
        Placeholder = data.Placeholder,
        Numeric = data.Numeric,
        Size = data.Size or 100,
        Default = value,
        Flag = text,
        Callback = function(v)
            State.Config[text] = v
            SafeCall(data.Callback, v)
        end,
    })

    State.Config[text] = textbox:GetValue()
    SafeCall(data.Callback, State.Config[text])

    return textbox
end

function Loader:AddKeybind(where, text, data)
    data = data or {}

    local value = State.Config[text]
    if value == nil then
        value = data.Default
    end

    local keybind = where:AddLabel(text):AddKeybind({
        Default = value,
        Flag = text,
        Callback = function(v)
            State.Config[text] = v
            SafeCall(data.Callback, v)
        end,
    })

    State.Config[text] = keybind:GetValue()
    SafeCall(data.Callback, State.Config[text])

    return keybind
end

return Loader
