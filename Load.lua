local Loader = {}

Config = Config or {}
Ex_Function = Ex_Function or {}

local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local HttpService = game:GetService("HttpService")

Loader.SaveFolder = "Emerald Hub/Kick a Lucky Block"
Loader.SaveFile = "Config.json"

function Loader:SetSaveFolder(path)
    self.SaveFolder = path
end

function Loader:SetSaveFile(name)
    self.SaveFile = name
end

local function GetPath(self)
    return self.SaveFolder, self.SaveFolder .. "/" .. self.SaveFile
end

function Loader:SaveSettings()
    local folder, file = GetPath(self)
    if not (readfile and writefile and isfile and isfolder and makefolder) then
        return warn("Executor Not Support Save System")
    end
    if not isfolder(folder) then
        makefolder(folder)
    end
    local saveData = {}
    for k, v in next, Config do
        if typeof(v) == "CFrame" then
            local x, y, z = v.Position.X, v.Position.Y, v.Position.Z
            local rx, ry, rz = v:ToOrientation()
            saveData[k] = {
                __type = "CFrame",
                X = x, Y = y, Z = z,
                RX = rx, RY = ry, RZ = rz
            }
        elseif typeof(v) == "table" then
            local t = {}
            for a, b in next, v do
                t[a] = b
            end
            saveData[k] = t
        else
            saveData[k] = v
        end
    end
    local success, encoded = pcall(function()
        return HttpService:JSONEncode(saveData)
    end)
    if success and encoded then
        if not isfile(file) or readfile(file) ~= encoded then
            writefile(file, encoded)
        end
    end
end

function Loader:LoadSettings()
    local folder, file = GetPath(self)
    if not (readfile and writefile and isfile and isfolder and makefolder) then
        return warn("Executor Not Support Save System")
    end
    if not isfolder(folder) then
        makefolder(folder)
    end
    if not isfile(file) then
        self:SaveSettings()
        return
    end
    local success, data = pcall(function()
        return HttpService:JSONDecode(readfile(file))
    end)
    if success and type(data) == "table" then
        for k, v in next, data do
            if typeof(v) == "table" and v.__type == "CFrame" then
                Config[k] = CFrame.new(v.X, v.Y, v.Z) * CFrame.Angles(v.RX, v.RY, v.RZ)
            else
                Config[k] = v
            end
        end
    end
end

function Loader:AddToggle(where, text)
    local thread
    local function Start(state)
        Config[text] = state
        if state then
            if not thread then
                thread = task.spawn(function()
                    local fn = Ex_Function[text]
                    if fn then
                        pcall(fn)
                    end
                    thread = nil
                end)
            end
        else
            if thread then
                task.cancel(thread)
                thread = nil
            end
        end
    end
    where:AddLabel(text):AddToggle({
        Default = Config[text] or false,
        Flag = text,
        Callback = Start
    })
    if Config[text] then
        Start(true)
    end
    Loader:SaveSettings()
end

function Loader:AddDropdown(where, text, data)
    Config[text] = Config[text] or (data.Multi and {} or data.Default)
    where:AddLabel(text):AddDropdown({
        Default = data.Default,
        Multi = data.Multi,
        AutoUpdate = data.AutoUpdate,
        Values = data.Values,
        Flag = text,
        Callback = function(v)
            if data.Multi then
                local selected = {}
                for name, state in pairs(v) do
                    if state then
                        table.insert(selected, name)
                    end
                end
                Config[text] = selected
            else
                Config[text] = v
            end
            if data.Callback then
                pcall(data.Callback, Config[text])
            end
            Loader:SaveSettings()
        end
    })
end

function Loader:AddTextInput(where, text, data)
    Config[text] = Config[text] or (data.Default or "")
    where:AddLabel(text):AddTextInput({
        Placeholder = data.Placeholder,
        Numeric = data.Numeric,
        Size = data.Size or 100,
        Default = Config[text],
        Flag = text,
        Callback = function(v)
            Config[text] = v
            if data.Callback then
                pcall(data.Callback, v)
            end
            Loader:SaveSettings()
        end
    })
end

function Loader:AddSlider(where, text, data)
    Config[text] = Config[text] or data.Default
    local value = Config[text]
    where:AddLabel(text):AddSlider({
        Min = data.Min,
        Max = data.Max,
        Type = data.Type,
        Nums = data.Nums,
        Size = data.Size or 100,
        Default = value,
        Flag = text,
        Callback = function(v)
            Config[text] = v
            if data.Callback then
                pcall(data.Callback, v)
            end
            Loader:SaveSettings()
        end
    })
    if data.Callback then
        pcall(data.Callback, value)
    end
end

for _, v in next, getconnections(LocalPlayer.Idled) do
    v:Disable()
end

task.spawn(function()
    while task.wait(600) do
        VirtualInputManager:SendMouseButtonEvent(0, 0, 0, true, game, 0)
        task.wait()
        VirtualInputManager:SendMouseButtonEvent(0, 0, 0, false, game, 0)
    end
end)

Loader:LoadSettings()

return Loader
