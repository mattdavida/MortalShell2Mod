--[[
  Shared player / UObject helpers.

  UEHelpers.GetPlayerController() does FindAllOf every call — cache it.
  Feature modules (Toggles, Combat, Unlocks) require this instead of
  copying Log / IsValid / GetPlayerController.
]]

local UEHelpers = require("UEHelpers.UEHelpers")

local M = {}

local cachedPC = nil
local cachedPawn = nil
local objectAddressOk = true

function M.Log(msg)
    print("[MortalShell2] " .. tostring(msg))
end

function M.IsValid(obj)
    return obj ~= nil and type(obj.IsValid) == "function" and obj:IsValid()
end

function M.Invalidate()
    cachedPC = nil
    cachedPawn = nil
end

---@param obj UObject|nil
---@return integer|nil
function M.ObjectAddress(obj)
    if not objectAddressOk or obj == nil then
        return nil
    end
    local ok, addr = pcall(function()
        return obj:GetAddress()
    end)
    if not ok then
        objectAddressOk = false
        return nil
    end
    return addr
end

---@return APlayerController|nil
function M.GetPlayerController()
    if cachedPC ~= nil and M.IsValid(cachedPC) then
        return cachedPC
    end
    cachedPC = nil
    cachedPawn = nil
    local pc = UEHelpers.GetPlayerController()
    if M.IsValid(pc) then
        cachedPC = pc
        return pc
    end
    return nil
end

---@return APawn|nil
function M.GetPlayerPawn()
    local pc = M.GetPlayerController()
    if not pc then
        cachedPawn = nil
        return nil
    end
    local pawn = pc.Pawn
    if M.IsValid(pawn) then
        cachedPawn = pawn
        return pawn
    end
    cachedPawn = nil
    return nil
end

---@return APawn|nil
function M.PeekCachedPawn()
    if cachedPawn ~= nil and M.IsValid(cachedPawn) then
        return cachedPawn
    end
    return M.GetPlayerPawn()
end

---@param obj UObject|nil
---@return string|nil
function M.ObjectFullName(obj)
    if not M.IsValid(obj) then
        return nil
    end
    local name = nil
    pcall(function()
        name = obj:GetFullName()
    end)
    if type(name) == "string" and name ~= "" then
        return name
    end
    return nil
end

---@param obj UObject|nil
---@return boolean
function M.IsDefaultObject(obj)
    if not M.IsValid(obj) then
        return false
    end
    if EObjectFlags ~= nil then
        local banned = EObjectFlags.RF_ClassDefaultObject
        if EObjectFlags.RF_ArchetypeObject then
            banned = banned + EObjectFlags.RF_ArchetypeObject
        end
        local ok, has = pcall(function()
            return obj:HasAnyFlags(banned)
        end)
        if ok and has then
            return true
        end
    end
    local name = M.ObjectFullName(obj)
    return type(name) == "string" and name:find("Default__", 1, true) ~= nil
end

---@param a UObject|nil
---@param b UObject|nil
---@return boolean
function M.SameObject(a, b)
    if a == nil or b == nil then
        return false
    end
    if a == b then
        return true
    end
    local addrA = M.ObjectAddress(a)
    if addrA == nil then
        return false
    end
    return addrA == M.ObjectAddress(b)
end

---@param param any
---@return any
function M.UnwrapParam(param)
    if param == nil then
        return nil
    end
    if type(param) == "userdata" and type(param.get) == "function" then
        local ok, val = pcall(function()
            return param:get()
        end)
        if ok then
            return val
        end
    end
    return param
end

---@param obj UObject
---@param field string
---@return any
function M.ReadField(obj, field)
    local ok, val = pcall(function()
        return obj[field]
    end)
    if ok then
        return val
    end
    return nil
end

---@param obj UObject
---@param field string
---@param value any
function M.WriteField(obj, field, value)
    pcall(function()
        obj[field] = value
    end)
end

---@param arr any
---@param fn fun(item: any)
function M.ForEachArrayItem(arr, fn)
    if arr == nil then
        return
    end
    local n = 0
    pcall(function()
        n = #arr
    end)
    if n > 0 then
        for i = 1, n do
            local ok, item = pcall(function()
                return arr[i]
            end)
            if ok then
                fn(item)
            end
        end
        return
    end
    pcall(function()
        for _, item in ipairs(arr) do
            fn(item)
        end
    end)
end

---@param className string
---@return UObject|nil
function M.FindCdo(className)
    local obj = FindFirstOf(className)
    if M.IsValid(obj) then
        return obj
    end
    return nil
end

---@param pc APlayerController|nil
---@return USpartaHealthComponent|nil
function M.GetHealthComponent(pc)
    pc = pc or M.GetPlayerController()
    if not pc then
        return nil
    end
    local pawn = pc.Pawn
    if not M.IsValid(pawn) then
        return nil
    end
    local hc = pawn.HealthComponent
    if M.IsValid(hc) then
        return hc
    end
    return nil
end

---@param obj UObject
---@param name string
---@param call fun(obj: UObject)
---@return boolean
function M.SafeCall(obj, name, call)
    local ok, err = pcall(call, obj)
    if ok then
        M.Log("Called " .. name)
        return true
    end
    M.Log("Failed " .. name .. " — " .. tostring(err))
    return false
end

---@param name string
---@param call fun(pc: APlayerController)
---@return boolean
function M.CallOnPlayerController(name, call)
    local pc = M.GetPlayerController()
    if not pc then
        M.Log("Skipped: no player controller (load into a world first)")
        return false
    end
    return M.SafeCall(pc, name, call)
end

return M
