-- ComboPathFix.lua
-- Author: Omega-Mods
-- Purpose:
--   Enable extended <combination> token to reference XMLs from other mods:
--     $moddir<OtherModName>$/path/to/file.xml
--     moddir<OtherModName>$/path/to/file.xml    (accepted without the leading '$')
-- Example:
--   <combination xmlFilename="$moddirFS25_tony10900TTRX$/tony10900TTR.xml"/>
--
-- Notes:
--   - Works both at vehicle XML load time and at store-level linking time.
--   - Adds a broad hook on Utils.getFilename so any GIANTS-side path resolution
--     that receives the extended token is transparently handled.
--   - If the target mod or file is missing, the game will log a warning; no crash.

ComboPathFix = {
    -- Set to true only when you need verbose debug output
    DEBUG = false
}

function ComboPathFix.prerequisitesPresent(specializations)
    return true
end

function ComboPathFix.registerEventListeners(vehicleType)
    SpecializationUtil.registerEventListener(vehicleType, "onPreLoad", ComboPathFix)
end

-- ==============================================================
-- Common utilities
-- ==============================================================

local function normalizeSlashes(path)
    if path == nil then return nil end
    path = path:gsub("\\", "/")
    path = path:gsub("//+", "/")
    return path
end

local function sanitizeComboPath(p)
    if p == nil then return nil end
    -- Do not touch well-formed tokens: $data/, $moddir$/ and $moddirNAME$/
    if not p:match("^%$data/") and not p:match("^%$moddir%$/") and not p:match("^%$moddir([%w_%-]+)%$/") then
        -- Remove stray dollar signs seen in malformed inputs (e.g. "moddirName$/file.xml")
        p = p:gsub("%$", "")
    end
    p = p:gsub("\\", "/")
    p = p:gsub("//+", "/")
    return p
end

local function getBasename(path)
    if not path then return nil end
    path = path:gsub("\\", "/")
    return path:match("([^/]+)$")
end

-- Strict resolver: "$moddirNAME$/..."
local function resolveModdirTokenStrict(pathWithToken)
    if not pathWithToken then return nil end
    local modName, rest = pathWithToken:match("^%$moddir([%w_%-]+)%$/(.+)$")
    if not (modName and rest) then return nil end
    local modItem = g_modManager and g_modManager:getModByName(modName) or nil
    if not (modItem and modItem.modDir and modItem.modDir ~= "") then return nil end
    local full = Utils.getFilename(rest, modItem.modDir)
    return normalizeSlashes(full)
end

-- Loose resolver: accepts both "$moddirNAME$/" and "moddirNAME$/"
local function resolveModdirTokenLoose(pathWithToken)
    if not pathWithToken then return nil end
    local modName, rest = pathWithToken:match("^%$?moddir([%w_%-]+)%$/(.+)$")
    if not (modName and rest) then return nil end
    local modItem = g_modManager and g_modManager:getModByName(modName) or nil
    if not (modItem and modItem.modDir and modItem.modDir ~= "") then return nil end
    local full = Utils.getFilename(rest, modItem.modDir)
    return normalizeSlashes(full)
end

-- ==============================================================
-- Umbrella hook on Utils.getFilename (used widely by GIANTS)
-- Resolves extended tokens *before* passing to the original function.
-- ==============================================================

local function hookUtilsGetFilename()
    if Utils and Utils.getFilename and not Utils._comboPathFix_hooked then
        local _orig = Utils.getFilename
        Utils.getFilename = function(filename, baseDir, ...)
            if type(filename) == "string" then
                local fixed = resolveModdirTokenLoose(filename)
                if fixed then
                    if ComboPathFix.DEBUG then
                        Logging.devInfo("[%s] ComboPathFix: Utils.getFilename resolved '%s' -> '%s'",
                            tostring(g_currentModName), tostring(filename), tostring(fixed))
                    end
                    return _orig(fixed, baseDir, ...)
                end
            end
            return _orig(filename, baseDir, ...)
        end
        Utils._comboPathFix_hooked = true
        Logging.info("[%s] ComboPathFix: hooked Utils.getFilename", tostring(g_currentModName))
    end
end

-- ==============================================================
-- Vehicle onPreLoad: rewrite <combination>#xmlFilename when using extended tokens
-- ==============================================================

function ComboPathFix:onPreLoad(savegame)
    local xmlFile = self.xmlFile
    if xmlFile == nil then return end

    local function safeJoin(base, tail)
        if base == nil or tail == nil then return nil end
        -- remove leading / or \ from tail
        tail = tail:gsub("^[\\/]+", "")
        return normalizeSlashes(base .. tail)
    end

    local i = 0
    while true do
        local combKey = string.format("vehicle.combinations.combination(%d)", i)
        if not xmlFile:hasProperty(combKey) then break end

        local fn = xmlFile:getString(combKey.."#xmlFilename")
        if fn ~= nil then
            local isData     = fn:match("^%$data/.+")
            local isLocalMod = fn:match("^%$moddir%$/")
            if not isData and not isLocalMod then
                -- Strict pattern: $moddirNAME$/rest
                local modName, rest = fn:match("^%$moddir([%w_%-]+)%$/(.+)$")
                if modName and rest then
                    local modItem = g_modManager and g_modManager:getModByName(modName) or nil
                    if modItem == nil then
                        Logging.warning("[%s] ComboPathFix: mod '%s' not found for combination '%s'",
                            tostring(g_currentModName), modName, fn)
                    else
                        local baseDir = modItem.modDir
                        if not (baseDir and baseDir ~= "") then
                            -- Fallback: try current mod directory just to avoid crashes
                            local tentative = Utils.getFilename(rest, g_currentModDirectory or "")
                            Logging.warning("[%s] ComboPathFix: modDir is nil for '%s'. Fallback base='%s' -> '%s'",
                                tostring(g_currentModName), modName, tostring(g_currentModDirectory), tostring(tentative))
                            if tentative and tentative ~= "" then
                                xmlFile:setString(combKey.."#xmlFilename", normalizeSlashes(tentative))
                            else
                                Logging.warning("[%s] ComboPathFix: cannot resolve '%s' (modDir nil, fallback failed)",
                                    tostring(g_currentModName), fn)
                            end
                        else
                            local newPath = safeJoin(baseDir, rest)
                            if newPath and newPath ~= "" then
                                xmlFile:setString(combKey.."#xmlFilename", newPath)
                                if ComboPathFix.DEBUG then
                                    Logging.devInfo("[%s] ComboPathFix: vehicle combination '%s' -> '%s'",
                                        tostring(g_currentModName), fn, newPath)
                                end
                            else
                                Logging.warning("[%s] ComboPathFix: join failed baseDir='%s' rest='%s' (orig='%s')",
                                    tostring(g_currentModName), tostring(baseDir), tostring(rest), fn)
                            end
                        end
                    end
                end
            end
        end

        i = i + 1
    end
end

-- ==============================================================
-- Auto-inject specialization into all vehicle types
-- (specialization must be declared in modDesc)
-- ==============================================================

local function addToAllVehicleTypes()
    local specName = "comboPathFix"
    local spec = g_specializationManager:getSpecializationByName(specName)
    if spec == nil then
        Logging.warning("[%s] ComboPathFix: specialization '%s' not found (check modDesc.xml)",
            tostring(g_currentModName), specName)
        return
    end

    local patchedCount = 0

    for typeName, typeEntry in pairs(g_vehicleTypeManager.types) do
        if typeEntry
            and typeEntry.specializationsByName
            and typeEntry.specializationsByName[specName] == nil
        then
            g_vehicleTypeManager:addSpecialization(typeName, specName)
            patchedCount = patchedCount + 1

            if ComboPathFix.DEBUG then
                Logging.devInfo("[%s] ComboPathFix: added specialization to vehicleType '%s'",
                    tostring(g_currentModName), tostring(typeName))
            end
        end
    end

    Logging.info("[%s] ComboPathFix: initialized on %d vehicleTypes",
        tostring(g_currentModName), patchedCount)
end

-- ==============================================================
-- Store helpers + pre-normalization for StoreItem combinations
-- ==============================================================

local function findStoreItemByXml(targetXml)
    targetXml = sanitizeComboPath(targetXml or "")
    if targetXml == "" then return nil end
    if not (g_storeManager and g_storeManager.items) then return nil end
    for _, it in ipairs(g_storeManager.items) do
        if it.xmlFilename and sanitizeComboPath(it.xmlFilename) == targetXml then
            return it
        end
    end
    return nil
end

local function findStoreItemByBasename(basename)
    if not basename or basename == "" then return nil end
    if not (g_storeManager and g_storeManager.items) then return nil end
    for _, it in ipairs(g_storeManager.items) do
        local fn = getBasename(it.xmlFilename or "")
        if fn == basename then
            return it
        end
    end
    return nil
end

local function resolveCombinationPath(raw)
    local abs = resolveModdirTokenStrict(raw)
    if abs then return abs end
    abs = resolveModdirTokenLoose(raw)
    if abs then return abs end
    return sanitizeComboPath(raw)
end

local function preResolveStoreCombinations()
    if not (g_storeManager and g_storeManager.items) then return end

    local patched = 0

    for _, item in ipairs(g_storeManager.items) do
        local combs = item.combinations
        if type(combs) == "table" then
            for _, comb in ipairs(combs) do
                local raw = comb.xmlFilename or comb.filename or comb.xml
                if raw and not comb._comboPathFix_done then
                    local fixed  = resolveCombinationPath(raw)
                    local target = fixed and findStoreItemByXml(fixed) or nil
                    if not target then
                        local base = getBasename(fixed or raw)
                        if base then
                            target = findStoreItemByBasename(base)
                        end
                    end

                    if fixed and fixed ~= raw then
                        comb.xmlFilename = fixed
                        if ComboPathFix.DEBUG then
                            Logging.devInfo("[%s] ComboPathFix: store combination '%s' -> '%s'",
                                tostring(g_currentModName), tostring(raw), tostring(fixed))
                        end
                    end
                    if target then
                        comb.storeItem    = target
                        comb._resolvedXml = target.xmlFilename
                    end

                    comb._comboPathFix_done = true
                    patched = patched + 1
                end
            end
        end
    end

    if ComboPathFix.DEBUG then
        Logging.devInfo("[%s] ComboPathFix: preResolveStoreCombinations patched %d combinations",
            tostring(g_currentModName), patched)
    end
end

-- ==============================================================
-- Store hook: patch resolveCombinations (if available)
-- ==============================================================

local function hookStoreResolve()
    if g_storeManager and g_storeManager.resolveCombinations and not g_storeManager._comboPathFix_hooked then
        local _orig = g_storeManager.resolveCombinations
        g_storeManager.resolveCombinations = function(self, ...)
            preResolveStoreCombinations()
            return _orig(self, ...)
        end
        g_storeManager._comboPathFix_hooked = true
        Logging.info("[%s] ComboPathFix: hooked StoreManager.resolveCombinations", tostring(g_currentModName))
    end
end

-- ==============================================================
-- Extra safety: hook XMLFile.getString for combination#xmlFilename
-- ==============================================================

local function keyLooksLikeCombinationXmlFilename(key)
    return type(key) == "string"
       and key:match("vehicle%.combinations%.combination%(%d+%)#xmlFilename") ~= nil
end

local function hookXMLGetStringForCombinations()
    if XMLFile and XMLFile.getString and not XMLFile._comboPathFix_hooked then
        local _origGetString = XMLFile.getString
        XMLFile.getString = function(self, key, defaultValue, ...)
            local v = _origGetString(self, key, defaultValue, ...)
            if v and keyLooksLikeCombinationXmlFilename(key) then
                local fixed = resolveModdirTokenLoose(v)
                if fixed and fixed ~= v then
                    if ComboPathFix.DEBUG then
                        Logging.devInfo("[%s] ComboPathFix: XMLFile.getString resolved '%s' -> '%s' for key '%s'",
                            tostring(g_currentModName), tostring(v), tostring(fixed), tostring(key))
                    end
                    return fixed
                end
            end
            return v
        end
        XMLFile._comboPathFix_hooked = true
        Logging.info("[%s] ComboPathFix: hooked XMLFile.getString for combination xmlFilename", tostring(g_currentModName))
    end
end

-- ==============================================================
-- Global listener: install hooks early and run store fallback pass
-- ==============================================================

ComboPathFixGlobal = {
    _postStoreFixPending = false,
    _postStoreFixDone    = false
}

function ComboPathFixGlobal:loadMap(name)
    -- Early/global hooks
    hookUtilsGetFilename()            -- umbrella path resolver
    hookXMLGetStringForCombinations() -- extra safety for vehicle combinations
    addToAllVehicleTypes()
    hookStoreResolve()

    -- One-shot fallback once the store items are populated
    self._postStoreFixPending = true
end

function ComboPathFixGlobal:update(dt)
    if self._postStoreFixPending and not self._postStoreFixDone then
        if g_storeManager ~= nil and type(g_storeManager.items) == "table" and #g_storeManager.items > 0 then
            preResolveStoreCombinations()
            self._postStoreFixDone    = true
            self._postStoreFixPending = false
            Logging.info("[%s] ComboPathFix: fallback post-pass on Store completed", tostring(g_currentModName))
        end
    end
end

addModEventListener(ComboPathFixGlobal)
