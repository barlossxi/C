repeat task.wait() until game:IsLoaded()

getgenv().HorstConfig = {
    ["EnableLog"] = true, -- ปรับเป็น true ถ้าอยากให้มันเช็คของ 
    ["Whitescreen"] = false,
    ["EnableAddFriends"] = false, -- แอดเพื่อนให้เอง ทุกๆ 1นาที
    ["LockFps"] = {
        ["EnableLockFps"] = false,
        ["LockFpsAmount"] = 30 
    }
}
loadstring(game:HttpGet("https://raw.githubusercontent.com/HorstSpaceX/last_update/main/on_loaded.lua"))()

local Service = setmetatable({}, {
    __index = function(_, k)
        return cloneref(game:GetService(k))
    end
})

local RunService = Service.RunService
local Players = Service.Players
local LocalPlayer = Players.LocalPlayer
local Players = Service.Players
local LocalPlayer = Players.LocalPlayer
local Workspace = Service.Workspace
local HttpService = Service.HttpService
local ReplicatedStorage = Service.ReplicatedStorage
local RunService = Service.RunService
local VirtualUser = Service.VirtualUser
local VirtualInputManager = Service.VirtualInputManager
local UserInputService = Service.UserInputService
local TeleportService = Service.TeleportService
local GuiService = Service.GuiService
local TweenService = Service.TweenService
local Camera = Workspace.CurrentCamera

Config = Config or {
    ["Select Lock Race"] = {"Night Knight","Stellar Ambassador"} -- Human, Tree Spirit, Elf, Werewolf, Eater, Undead, Ice Crystal, Fiendish Demon
}

local UtilsSystem = require(game.ReplicatedFirst.AllSideCode.UtilsSystem)
local CfgFind = UtilsSystem.CfgFind
local TranslationHelper = UtilsSystem.TranslationHelper
local EnumMgr = UtilsSystem.EnumMgr
local GetData = UtilsSystem.GetData
local PlayerData = UtilsSystem.PlayerData

local codeConf = CfgFind.GetCfgByName("codeConf")
for ID, Data in pairs(codeConf) do
    if Data.endTime > tick() then
        ReplicatedStorage.Msg.RemoteFunction.RemoteFunction:InvokeServer(
            "\xE5\x85\x91\xE6\x8D\xA2\xE7\xA0\x81",
            Data.code
        )
    end 
end 

task.wait(10)

task.spawn(function()
    while task.wait() do
        pcall(function()
            local Spins = GetData.GetItemCountByID(game.Players.LocalPlayer,EnumMgr.ItemID.RaceRoll)
            local cfg = CfgFind.GetHumanRaceCfg(LocalPlayer.HumanRace.Value)
            if cfg then
                local name = UtilsSystem.TranslationHelper.translateByKey(cfg.ZhName)
                if not table.find(Config["Select Lock Race"], name) then
                    if Spins > 0 then 
                        ReplicatedStorage.Msg.RemoteFunction.RemoteFunction:InvokeServer("Roll\xE7\xA7\x8D\xE6\x97\x8F")
                        task.wait(0.1)
                    end 
                    _G.Horst_SetDescription("⚔️ Race " .. name .. " : ♻️ Spin " .. Spins .. " : Not Done 🔴")
                else 
                    _G.Horst_SetDescription("⚔️ Race " .. name .. " : ♻️ Spin " .. Spins .. " : Done 🟢")
                end
            end
        end)
    end
end)

