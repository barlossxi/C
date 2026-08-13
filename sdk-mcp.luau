-- Public loader for GitHub/CDN distribution.
-- Configure getgenv().Config before loading this file.
local Global = getgenv()
local Config = type(Global.Config) == "table" and Global.Config or {}
local BridgeURL = tostring(Config.BridgeUrl or Global.BridgeURL or Global.bridgeurl or "localhost:16384")
BridgeURL = BridgeURL:gsub("^https?://", ""):gsub("/+$", "")

Global.BridgeURL = BridgeURL
Global.bridgeurl = BridgeURL
Global.MCP_ScriptMappingWorkers = tonumber(Config.MaxInFlight) or Global.MCP_ScriptMappingWorkers or 24
Global.MCP_RequestTimeoutSeconds = tonumber(Config.RequestTimeout) or Global.MCP_RequestTimeoutSeconds or 20
Global.MCP_RequestsPerMinute = tonumber(Config.RequestsPerMinute) or Global.MCP_RequestsPerMinute or 1350
Global.MCP_UseLuaExpert = Config.UseLuaExpert ~= false
Global.MCP_Verbose = Config.Verbose == true
if type(Config.ApiUrl) == "string" and Config.ApiUrl ~= "" then
    Global.MCP_LuaExpertApiUrl = Config.ApiUrl
end

local function loadConnector()
    local response = game:HttpGet("http://" .. BridgeURL .. "/script.luau")
    local chunk, compileError = loadstring(response)
    if not chunk then error(compileError) end
    return chunk()
end

if Global.MCP_Loaded ~= true then
    local loaded, result = pcall(loadConnector)
    if not loaded then
        Global.MCP_Loaded = nil
        error("Roblox MCP connector failed to load: " .. tostring(result))
    end
end

return true
