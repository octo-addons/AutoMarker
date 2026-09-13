-- || Made by and for Weird Vibes of Turtle WoW || --
-- || octo-addons fork: name-based auto marking, info panel, 1.12 client fixes || --
_G = _G or getfenv(0)
AutoMarkerLocale = AutoMarkerLocale or {}
-- Unknown locale keys fall back to the key itself so new strings never error.
setmetatable(AutoMarkerLocale, { __index = function(_, key) return key end })
local L = AutoMarkerLocale
BINDING_HEADER_AUTOMARK = L["|cff22CC00 - AutoMark Bindings -"];
BINDING_NAME_MOUSEOVERKEY = L["Keys to hold to activate mouseover mark"];
BINDING_NAME_RUNKEY = L["Mark mouseover or target"];
BINDING_NAME_NEXTKEY =L["Mark next group based on default order"];
BINDING_NAME_CLEARKEY = L["Clear all current marks"];
BINDING_NAME_AUTOSCANKEY = L["Auto-mark nearby hostiles now"];


-- Utility -------------------

local color = {
  white = "|cffffffff",
  red = "|cffff0000",
  green = "|cff00ff00",
  blue = "|cff0000ff",
  yellow = "|cffffff00",
  cyan = "|cff00ffff",
  magenta = "|cffff00ff",
  grey = "|cff808080",
  orange = "|cffff8000",
  purple = "|cffff00ff"}

local function c(text, color)
  return color..text.."|r"
end

local super_ver = SUPERWOW_VERSION and tonumber(SUPERWOW_VERSION)
local np_major, np_minor, np_patch
if GetNampowerVersion then
  np_major, np_minor, np_patch = GetNampowerVersion()
end
local use_nampower = np_major and (np_major > 2 or (np_major == 2 and np_minor >= 39))
local use_superwow = not use_nampower and SetAutoloot
-- SuperWoW presence regardless of nampower: needed for local (solo) marks.
local has_superwow = (SUPERWOW_VERSION or SetAutoloot) and true or false
local has_unitxp = pcall(UnitXP, "nop", "nop")
local has_classicapi = type(UnitDistanceSquared) == "function"
local sync_prefix = "AutoMarker"

if not use_superwow and not use_nampower then
  StaticPopupDialogs["NO_SUPERWOW_AUTOLOOT"] = {
    text = (c("AutoMarker",color.yellow)..c(" requires SuperWoW 1.4+ or nampower 2.39+ to operate.",color.red)),
    button1 = TEXT(OKAY),
    timeout = 0,
    whileDead = 1,
    hideOnEscape = 1,
    showAlert = 1,
  }

  StaticPopup_Show("NO_SUPERWOW_AUTOLOOT")
  return
end

-- localise global fucntions to reduce function lookup cpu use
local GetPlayerBuff = GetPlayerBuff
local GetPlayerBuffID = GetPlayerBuffID
local UnitExists = UnitExists
local UnitName = UnitName
local UnitIsDead = UnitIsDead
local UnitHealth = UnitHealth
local SetRaidTarget = SetRaidTarget
local GetRaidTargetIndex = GetRaidTargetIndex
local GetRealZoneText = GetRealZoneText
local IsShiftKeyDown = IsShiftKeyDown
local IsControlKeyDown = IsControlKeyDown
local IsAltKeyDown = IsAltKeyDown
local UnitAffectingCombat = UnitAffectingCombat
local sfind = string.find
-- local sgfind = string.gfind -- overkill
local ssub = string.sub
local tinsert = table.insert
local tsort = table.sort
local tremove = table.remove
local pairs = pairs
local ipairs = ipairs
local next = next
local SendAddonMessage = SendAddonMessage
local GetNumPartyMembers = GetNumPartyMembers
local GetNumRaidMembers = GetNumRaidMembers
local CheckInteractDistance = CheckInteractDistance
local chat_add_msg = DEFAULT_CHAT_FRAME.AddMessage

local function auto_print(msg)
  if DEFAULT_CHAT_FRAME then chat_add_msg(DEFAULT_CHAT_FRAME,msg) end
end

local function elem(t,item)
  for _,k in t do
    if item == k then
      return true
    end
  end
  return false
end

local function tsize(t)
  local c = 0
  for _ in pairs(t) do c = c + 1 end
  return c
end

local function sortTableByKey(tbl)
  local sortedKeys = {}
  for key in pairs(tbl) do
      tinsert(sortedKeys, key)
  end
  tsort(sortedKeys)

  local sortedTable = {}
  for _, key in ipairs(sortedKeys) do
      sortedTable[key] = tbl[key]
  end
  return sortedTable
end

--[[[
This lines up the mob tables and the update table and picks out what's newer:
Say we have
  ["spider_anubrekhan"] = {
    ["0x101"] = 6, -- spider 1
    ["0x102"] = 7, -- spider 2
    ["0x10"] = 8, -- anub
  },
And
  update = {
    ["0x105"] = 6, -- spider 1
    ["0x106"] = 7, -- spider 2
  },
We get
  updated = {
    ["0x105"] = 6, -- spider 1
    ["0x106"] = 7, -- spider 2
    ["0x10"] = 8, -- anub
  },
--]]
local function sortAndReplaceKeys(defaultTable, updateTable, reverse)
  local keys = {}
  for key in pairs(defaultTable) do
      tinsert(keys, key)
  end

  local comp = function (a,b)
    if reverse then
        return a < b
    else
        return a > b
    end
  end

  tsort(keys, comp)

  local values = {}
  for _, value in pairs(updateTable) do
      tinsert(values, value)
  end
  tsort(values, comp)

  local updatedTable = {}
  local i = 1

  for _, key in ipairs(keys) do
      if values[i] then
          updatedTable[values[i]] = defaultTable[key]
          i = i + 1
      else
          updatedTable[key] = defaultTable[key]
      end
  end

  return updatedTable
end

-- Addon ---------------------

-- /// Util functions /// --

local function PostHookFunction(original,hook)
  return function(a1,a2,a3,a4,a5,a6,a7,a8,a9,a10)
    original(a1,a2,a3,a4,a5,a6,a7,a8,a9,a10)
    hook(a1,a2,a3,a4,a5,a6,a7,a8,a9,a10)
  end
end

local function InGroup()
  return (GetNumPartyMembers() + GetNumRaidMembers() > 0)
end

local function PlayerCanRaidMark()
  return InGroup() and (IsRaidOfficer() or IsPartyLeader())
end

-- You may mark when you're a lead, assist, or you're doing soloplay
local function PlayerCanMark()
  return PlayerCanRaidMark() or not InGroup()
end

-- Marks placed by this addon, keyed by guid. RAID_TARGET_UPDATE compares the
-- live marks against this table to tell marks set by people from our own.
local addonPlaced = {}

-- returns false if the mark was solo
local warned_lead = false
local function MarkUnit(unit,mark)
  local _, placedGuid = UnitExists(unit)
  if placedGuid then
    if mark and mark > 0 then
      addonPlaced[placedGuid] = mark
    else
      addonPlaced[placedGuid] = nil
    end
  end
  if PlayerCanRaidMark() then
    SetRaidTarget(unit,mark)
    return true
  elseif has_superwow then
    if InGroup() and not warned_lead then
      DEFAULT_CHAT_FRAME:AddMessage(c(L["Warning:"],color.red)..L[" a mark set while not a leader/assistant is not visible to others"])
      warned_lead = true
    end
    SetRaidTarget(unit,mark,1)
  end
  return false
end

local function MarkPack(pack)
  for guid,mark in pairs(pack) do
    if UnitExists(guid) then
      MarkUnit(guid,mark)
    end
  end
end

function AutoMarker_ClearMarks()
  local markfunc = InGroup() and
    SetRaidTarget or
    function (t,m) SetRaidTarget(t,m,1) end
  for i=1,8 do
    if UnitExists("mark"..i) then markfunc("mark"..i,0) end
  end
end

function AutoMarker_MarkName(name)
  local sortedCache = {}
  for guid,name in pairs(AutoMarkerDB.unitCache) do
    tinsert(sortedCache, { guid = guid, name = name })
  end

  local function sortUnitsByInteractDistance(units)
    tsort(units, function(a, b)
        local aInRange = CheckInteractDistance(a.guid,4)
        local bInRange = CheckInteractDistance(b.guid,4)
        if aInRange and not bInRange then
            return true
        elseif not aInRange and bInRange then
            return false
        else
            return false -- Maintain original order if both are the same
        end
    end)
  end
  sortUnitsByInteractDistance(sortedCache)

  -- clear far marks to help prio close
  for i=1,8 do
    local _,m = UnitExists("mark"..i)
    if m and not CheckInteractDistance(m,4) then
      MarkUnit(m,0)
    end
  end

  local hit = false
  for _, data in ipairs(sortedCache) do
    if not UnitExists(data.guid) then
      AutoMarkerDB.unitCache[data.guid] = nil
    elseif not UnitIsDead(data.guid) and string.lower(UnitName(data.guid)) == string.lower(name) then
      hit = true
      for i=8,1,-1 do
        local _,m = UnitExists("mark"..i)
        if m and UnitExists(m) and not UnitIsDead(m) then
          -- mark is used on already
        else
          MarkUnit(data.guid,i)
          break
        end
      end
    end
  end
  if not hit then
    auto_print(name .. L[" wasn't found nearby!"])
  end
end

function AutoMarker_MarkGuidPattern(guidPattern)
  local sortedCache = {}
  local cacheSize = 0
  for guid,name in pairs(AutoMarkerDB.unitCache) do
    cacheSize = cacheSize + 1
    if sfind(guid, "^" .. guidPattern) then
      tinsert(sortedCache, { guid = guid, name = name })
    end
  end
  auto_print("cache: " .. cacheSize .. " | matches: " .. getn(sortedCache) .. " | pattern: " .. guidPattern)

  tsort(sortedCache, function(a, b)
    if has_unitxp then
      local aDist = UnitXP("distanceBetween", "player", a.guid) or 999
      local bDist = UnitXP("distanceBetween", "player", b.guid) or 999
      return aDist < bDist
    else
      local aInRange = CheckInteractDistance(a.guid, 4)
      local bInRange = CheckInteractDistance(b.guid, 4)
      if aInRange and not bInRange then return true end
      return false
    end
  end)

  local hit = false
  for _, data in ipairs(sortedCache) do
    if not UnitExists(data.guid) then
      AutoMarkerDB.unitCache[data.guid] = nil
    elseif not UnitIsDead(data.guid) then
      hit = true
      for i=8,1,-1 do
        local _,m = UnitExists("mark"..i)
        if m and UnitExists(m) and not UnitIsDead(m) then
          -- mark is used already
        else
          MarkUnit(data.guid,i)
          break
        end
      end
    end
  end
  if not hit then
    auto_print(guidPattern .. L[" wasn't found nearby!"])
  end
end

-- /// Allow marking solo as well /// --

local function AM_UnitPopup_HideButtons()
  local dropdownMenu = _G[UIDROPDOWNMENU_INIT_MENU];

  -- Turtle's FrameXML keys UnitPopupShown by menu level; stock 1.12 does not.
  local shown = UnitPopupShown
  if type(shown[UIDROPDOWNMENU_MENU_LEVEL]) == "table" then
    shown = shown[UIDROPDOWNMENU_MENU_LEVEL]
  end
  for index, value in ipairs(UnitPopupMenus[dropdownMenu.which]) do
    if ( strsub(value, 1, 12)  == "RAID_TARGET_" ) then
      shown[index] = 1;
    end
  end
end
UnitPopup_HideButtons = PostHookFunction(UnitPopup_HideButtons,AM_UnitPopup_HideButtons)

local function AM_UnitPopup_OnClick()
  local dropdownFrame = getglobal(UIDROPDOWNMENU_INIT_MENU);
  local button = this.value;
  local unit = dropdownFrame.unit;

  if ( strsub(button, 1, 12) == "RAID_TARGET_" and button ~= "RAID_TARGET_ICON" ) then
    local raidTargetIndex = strsub(button, 13);
    if ( raidTargetIndex == "NONE" ) then
      raidTargetIndex = 0;
    end
    MarkUnit(unit, tonumber(raidTargetIndex))
    -- chosen by a person through the menu: let the learner see it as manual
    local _, menuGuid = UnitExists(unit)
    if menuGuid then addonPlaced[menuGuid] = nil end
  end
  PlaySound("UChatScrollButton");
end
UnitPopup_OnClick = PostHookFunction(UnitPopup_OnClick,AM_UnitPopup_OnClick)

------------------------------

local raidMarks = { L["Unmarked"], L["Star"], L["Circle"], L["Diamond"], L["Triangle"], L["Moon"], L["Square"], L["Cross"], L["Skull"] }

local defaultSettings = {
  enabled = true,
  debug = false,
  -- auto mode (name-based marking, no pack data needed)
  auto = true,
  autoRadius = 40,
  pullRadius = 30,
  autoInterval = 1.0,
  autoSort = "health",       -- "health" or "class"
  autoRequireCombat = true,
  autoLos = false,
  autoSkipTapped = true,
  autoInstanceOnly = false,
  -- learning from marks set by people
  autoLearn = true,          -- remember name -> mark
  autoRecord = "instance",   -- record spawn -> mark into packs: "off", "instance", "always"
}

local sweep_on = false
local sweepPackName = nil
local currentPackName = nil
local currentNpcsToMark = {}
local last_pack_marked = nil
local elapsed = 0
local core_delay = 3
local core_delay_elapsed = 0
local aggro_tracker = {}

local solinus_prio = { L["Sanctum Supressor"], L["Sanctum Dragonkin"], L["Sanctum Wyrmkin"], L["Sanctum Scalebane"] }

local autoMarker = CreateFrame("Frame","AutoMarkerFrame")

local function guidToPack(id, zone)
  if not currentNpcsToMark or not currentNpcsToMark[zone] then
    return
  end
  -- scan for the id, but, we also want to prioritise custom markings
  local rPackName,rPack
  for packName, packInfo in pairs(currentNpcsToMark[zone] or {}) do
    for guid, _ in pairs(packInfo) do
      if guid == id then
        rPackName = packName
        rPack = currentNpcsToMark[zone][packName]
        break
      end
    end
  end
  for packName, packInfo in pairs(AutoMarkerDB.customNpcsToMark[zone] or {}) do
    for guid, _ in pairs(packInfo) do
      if guid == id then
        rPackName = packName
        rPack = AutoMarkerDB.customNpcsToMark[zone][packName]
        break
      end
    end
  end
  return rPackName,rPack
end

function AutoMarker_MarkGroup()
  local _, mouseoverGuid = UnitExists("mouseover")
  local _, targetGuid = UnitExists("target")
  targetGuid = mouseoverGuid or targetGuid
  if targetGuid and not UnitIsDead(targetGuid) and PlayerCanMark() then
    local pack, packMobs = guidToPack(targetGuid, GetRealZoneText())
    if packMobs then
      MarkPack(packMobs)
      last_pack_marked = pack
    elseif AutoMarkerDB.settings.auto then
      -- not in any pack: fall back to name-based marking around this mob
      AutoMarker_AutoPull(targetGuid)
    end
  end
end

function AutoMarker_MarkNextGroup()
  local zone = GetRealZoneText()

  for i, pack in ipairs(orderedPacks) do
    if pack.instance == zone then
      if not last_pack_marked or pack.packName == last_pack_marked then
        local nextPack = orderedPacks[i + (last_pack_marked and 1 or 0)]
        if nextPack and nextPack.instance == zone then
          auto_print(L["Marking: "] .. nextPack.packName)
          MarkPack(currentNpcsToMark[zone][nextPack.packName])
          last_pack_marked = nextPack.packName
          break
        end
      end
    end
  end
end

-- this should not spit out the result, only true or false whether it suceeded, maybe a 2nd return value of what the error was
local function AddToPack(guid,force_add,pack)
  local the_pack = pack or currentPackName
  local force = force_add or false
  if not guid then
    return false,"no_guid"
  end
  if not the_pack then
    return false,"no_pack_name"
  end

  local unitName, raidmark = UnitName(guid), GetRaidTargetIndex(guid) or 0
  local zoneName = GetRealZoneText()

  local mob_pack_name = guidToPack(guid, zoneName)
  if mob_pack_name and not force then
    return false,"mob_in_pack"
  end

  AutoMarkerDB.customNpcsToMark[zoneName] = AutoMarkerDB.customNpcsToMark[zoneName] or {}
  AutoMarkerDB.customNpcsToMark[zoneName][the_pack] = AutoMarkerDB.customNpcsToMark[zoneName][the_pack] or {}

  -- update the live table too
  currentNpcsToMark[zoneName] = currentNpcsToMark[zoneName] or {}
  currentNpcsToMark[zoneName][the_pack] = currentNpcsToMark[zoneName][the_pack] or {}

  local existing_mark = AutoMarkerDB.customNpcsToMark[zoneName][the_pack][guid]
  local same = existing_mark and (existing_mark == raidmark)
  if not same then
    auto_print((existing_mark and L["Updating "] or L["Adding "]) .. unitName .. "(" .. guid .. L[") in pack: "] .. the_pack .. L[" with new mark: "] .. raidMarks[raidmark + 1] .. L[" in zone: "] .. zoneName)
    AutoMarkerDB.customNpcsToMark[zoneName][the_pack][guid] = raidmark
    currentNpcsToMark[zoneName][the_pack][guid] = raidmark
    AutoMarker_InvalidatePackIndex()
  end
  return true, nil
end

local function OnMouseover()
  if AutoMarkerDB.settings.enabled and IsShiftKeyDown() and (IsControlKeyDown() or IsAltKeyDown()) then
    AutoMarker_MarkGroup()
  end
end

-- Certain bosses have script spawned adds, so their id's are not consistent, this mechanism is to assign them marks.
local temporary_mobs = {
  [L["Deathknight Understudy"]] = {
    minCount = 4,
    pack = "military_razuvious",
    raid = L["Naxxramas"],
    queue = {},
  },
  ["Kodiak"] = {
    minCount = 1,
    pack = "rotgrowl",
    raid = L["Timbermaw Hold"],
    queue = {},
  },
  [L["Crypt Guard"]] = {
    minCount = 2,
    pack = "spider_anubrekhan",
    raid = L["Naxxramas"],
    queue = {},
  },
  ["Faerlina Add"] = {
    minCount = 6,
    pack = "spider_faerlina",
    raid = L["Naxxramas"],
    queue = {},
  },
  ["Domo Add"] = {
    minCount = 8,
    pack = "domo",
    raid = L["Molten Core"],
    queue = {},
    reverse = true, -- adds have lower id than boss
  },
  [L["The Prophet Skeram"]] = {
    minCount = 3,
    pack = "skeram",
    raid = L["Ahn'Qiraj"],
    live_mark = true, -- do the mobs change in combat
    queue = {},
  },
  [L["High Priestess Arlokk"]] = {
    minCount = 1,
    pack = "arlokk",
    raid = L["Zul'Gurub"],
    live_mark = true, -- do the mobs change in combat
    queue = {},
  },
  ["Gnarlmoon Owl"] = {
    minCount = 4,
    pack = "gnarlmoon_owls",
    raid = L["Tower of Karazhan"],
    live_mark = true, -- do the mobs change in combat
    queue = {},
    reverse = true,
  },
  ["Manascale Ley-Seeker"] = {
    minCount = 4,
    pack = "incantagos_seekers",
    raid = L["Tower of Karazhan"],
    queue = {},
    reverse = true,
  },
  ["Fragment of Rupturan"] = {
    minCount = 3,
    pack = "rupturan_fragments",
    raid = L["The Rock of Desolation"],
    live_mark = true,
    queue = {},
  },
  ["Crumbling Exile"] = {
    minCount = 4,
    pack = "rupturan_exile",
    raid = L["The Rock of Desolation"],
    live_mark = false,
    queue = {},
    reverse = true,
  },
  ["Hellfire Doomguard"] = {
    minCount = 2,
    pack = "mephistroth",
    raid = L["The Rock of Desolation"],
    live_mark = true,
    queue = {},
    -- reverse = true,
  },
  ["Onyxian Hatcher"] = {
    minCount = 2,
    pack = "onyxia_hatchers",
    raid = L["Onyxia's Lair"],
    live_mark = true,
    queue = {},
  },
  ["Withermaw Illuminator"] = {
    minCount = 2,
    pack = "chieftain_illuminators",
    raid = L["Timbermaw Hold"],
    queue = {},
  },
  ["Withermaw Shadowkeeper"] = {
    minCount = 2,
    pack = "chieftain_shadowkeepers",
    raid = L["Timbermaw Hold"],
    live_mark = true,
    queue = {},
  },
  ["Withermaw Corrupter"] = {
    minCount = 2,
    pack = "ursol_corrupters",
    raid = L["Timbermaw Hold"],
    queue = {},
    reverse = true,
  },
  ["Buru Egg"] = {
    minCount = 6,
    pack = "buru_eggs",
    raid = L["Ruins of Ahn'Qiraj"],
    live_mark = false, -- a different mechanism will handle live buru eggs
    queue = {},
  },
}

-- Order them and assign them ordered source marks
local function UpdateTemporaryMobs()
  for mob, config in pairs(temporary_mobs) do
    if GetRealZoneText() == config.raid and tsize(config.queue) >= config.minCount then
      -- Defensive: ensure default tables exist
      -- This was possibly causing wierd marking issues on skeram for people will broken/odd groups
      if not defaultNpcsToMark[config.raid] then
        config.queue = {}
        AutoMarkerDB.checkTemporaryMobs = false
        return
      end
      local defaultPack = defaultNpcsToMark[config.raid][config.pack]
      if not defaultPack then
        config.queue = {}
        AutoMarkerDB.checkTemporaryMobs = false
        return
      end

      -- Defensive: ensure current tables exist
      currentNpcsToMark[config.raid] = currentNpcsToMark[config.raid] or {}

      currentNpcsToMark[config.raid][config.pack] =
        sortAndReplaceKeys(defaultPack, config.queue, config.reverse)
      AutoMarker_InvalidatePackIndex()

      if config.live_mark then
        local updatedPack = currentNpcsToMark[config.raid][config.pack]
        if updatedPack then
          MarkPack(updatedPack)
        end
      end
      config.queue = {}
      AutoMarkerDB.checkTemporaryMobs = false
    end
  end
end

-- make it obvious what is the high hp hound
local function UpdateCorehound()
  if not next(AutoMarkerDB.temp_values.corehounds) or GetRealZoneText() ~= L["Molten Core"] then
    AutoMarkerDB.checkCoreHounds = false
    AutoMarkerDB.temp_values.corehounds = {}
    return
  end

  -- skip marking hounds if we marked a boss for pull
  if not UnitIsDead("mark8") and UnitName("mark8") ~= L["Core Hound"] then return end

  local t = {}
  for guid, _ in pairs(AutoMarkerDB.temp_values.corehounds) do
    if not UnitExists(guid) then
      AutoMarkerDB.temp_values.corehounds[guid] = nil
    elseif UnitAffectingCombat(guid) then
      tinsert(t, guid)
    end
  end
  -- if hp are the same, e.g. fight start, use lexigraphical sorting to keep mark stable
  tsort(t, function(a, b)
    if UnitHealth(a) == UnitHealth(b) then
      return a < b
    else
      return UnitHealth(a) > UnitHealth(b)
    end
  end)
  if t[1] and not GetRaidTargetIndex(t[1]) then
    MarkUnit(t[1], 8)
    SendAddonMessage(sync_prefix, "COREHOUND_MARKED", "RAID")
  end
end

-- keep close soliders visible using any spare marks
local function UpdateSoldiers()
  if not next(AutoMarkerDB.temp_values.soldiers) or GetRealZoneText() ~= L["The Upper Necropolis"] then
    AutoMarkerDB.checkSoliders = false
    AutoMarkerDB.temp_values.soldiers = {}
    return
  end

  for guid, _ in pairs(AutoMarkerDB.temp_values.soldiers) do
    if not UnitExists(guid) then
      AutoMarkerDB.temp_values.soldiers[guid] = nil
    elseif not GetRaidTargetIndex(guid) and UnitAffectingCombat(guid) and CheckInteractDistance(guid,4) then
      autoMarker:ApplyNextMark(guid)
    end
  end
end

local function UpdateKeepers()
  if not next(AutoMarkerDB.temp_values.keepers) or GetRealZoneText() ~= L["Blackrock Depths"] then
    AutoMarkerDB.checkKeepers = false
    AutoMarkerDB.temp_values.keepers = {}
    return
  end

  if GetSubZoneText() == L["The Lyceum"] then
    for guid, _ in pairs(AutoMarkerDB.temp_values.keepers) do
      if not UnitExists(guid) then
        AutoMarkerDB.temp_values.keepers[guid] = nil
      elseif not GetRaidTargetIndex(guid) then
        autoMarker:ApplyNextMark(guid)
      end
    end
  end
end

local function UpdateProtectors()
  if not next(AutoMarkerDB.temp_values.protectors) or GetRealZoneText() ~= L["Dire Maul"] then
    AutoMarkerDB.checkProtectors = false
    AutoMarkerDB.temp_values.protectors = {}
    return
  end

  if GetSubZoneText() == L["Capital Gardens"] then
    for guid, _ in pairs(AutoMarkerDB.temp_values.protectors) do
      if not UnitExists(guid) then
        AutoMarkerDB.temp_values.protectors[guid] = nil
      elseif not GetRaidTargetIndex(guid) then
        autoMarker:ApplyNextMark(guid) -- this might need a proper temp mob entry, depends if they all load at once
      end
    end
  end
end

-- /// Auto mode: name-based marking, no pack data required /// --
--
-- Packs are keyed by server-specific spawn GUIDs, so on any server other than
-- the one they were recorded on they never match. Auto mode instead marks
-- nearby hostile mobs by name priority (healers and casters first), filling
-- only marks that are currently free. A pack mark always wins over an auto
-- mark, and a mark sitting on a living mob is never moved.

local defaultAutoPrio = {
  "priest", "shaman", "healer", "mystic", "acolyte", "witch doctor", "mender",
  "cleric", "mage", "warlock", "sorcer", "conjurer", "caster", "geomancer",
  "summoner", "necromancer", "wizard", "oracle", "seer", "shadowcaster",
  "spellbinder",
}
local defaultAutoIgnore = { "totem" }
local classWeight = { worldboss = 0, rareelite = 1, elite = 2, rare = 3, normal = 4 }

local auto = {
  in_combat = false,
  next_scan = 0,          -- GetTime() gate; 0 forces a scan on the next tick
  owner = {},             -- [mark] = guid we last put that mark on
  owner_guid = {},        -- [guid] = mark
  seen = {},              -- [mark] = guid seen carrying it (marks set by people)
  cands = {},             -- reused candidate records
  free = {},              -- reused free-mark list
  last_pull_guid = nil,
  last_pull_time = 0,
  idle_warned = false,
  pack_index = nil,       -- [guid] = mark for pack_index_zone
  pack_index_zone = nil,
  pack_index_dirty = true,
}

local function CopyList(src)
  local t = {}
  for i, v in ipairs(src) do t[i] = v end
  return t
end

function AutoMarker_InitAutoLists()
  if type(AutoMarkerDB.autoPrio) ~= "table" then
    AutoMarkerDB.autoPrio = CopyList(defaultAutoPrio)
  end
  if type(AutoMarkerDB.autoIgnore) ~= "table" then
    AutoMarkerDB.autoIgnore = CopyList(defaultAutoIgnore)
  end
  for i, v in ipairs(AutoMarkerDB.autoPrio) do AutoMarkerDB.autoPrio[i] = string.lower(v) end
  for i, v in ipairs(AutoMarkerDB.autoIgnore) do AutoMarkerDB.autoIgnore[i] = string.lower(v) end
  if type(AutoMarkerDB.learned) ~= "table" then AutoMarkerDB.learned = {} end
end

local function IsMobGuid(guid)
  return type(guid) == "string" and ssub(guid, 3, 3) == "F"
end

-- Yards between a ("player" or guid) and b (guid), or nil when unknown.
local function DistanceBetween(a, b)
  if has_unitxp then
    local ok, d = pcall(UnitXP, "distanceBetween", a, b)
    if ok and tonumber(d) then return tonumber(d) end
  end
  if a == "player" and has_classicapi then
    local ok, d2, checked = pcall(UnitDistanceSquared, b)
    if ok and checked and tonumber(d2) and d2 >= 0 then return math.sqrt(d2) end
  end
  if type(UnitPosition) == "function" then
    local ok1, ax, ay, az = pcall(UnitPosition, a)
    local ok2, bx, by, bz = pcall(UnitPosition, b)
    if ok1 and ok2 and tonumber(ax) and tonumber(bx) then
      local dx = ax - bx
      local dy = ay - by
      local dz = (tonumber(az) or 0) - (tonumber(bz) or 0)
      return math.sqrt(dx * dx + dy * dy + dz * dz)
    end
  end
  return nil
end

-- Returns inRange, distance. Falls back to interact distance (~28 yd) when
-- no distance source exists and the anchor is the player.
local function WithinRadius(a, b, r)
  local d = DistanceBetween(a, b)
  if d then return d <= r, d end
  if a == "player" then return CheckInteractDistance(b, 4) and true or false, nil end
  return false, nil
end

-- UnitHealthMax reports a percentage for non-party units in 1.12; nampower's
-- unit field gives the real value.
local function UnitMaxHP(guid)
  if type(GetUnitField) == "function" then
    local ok, v = pcall(GetUnitField, guid, "maxHealth")
    if ok and tonumber(v) and tonumber(v) > 0 then return tonumber(v) end
  end
  return UnitHealthMax(guid) or 0
end

local function MatchList(lname, list)
  for i, pat in ipairs(list) do
    if sfind(lname, pat) then return i end
  end
  return nil
end

-- Returns canMark, reason.
local function AutoCanMarkReason()
  if not AutoMarkerDB.settings.enabled then return false, "addon disabled" end
  if not AutoMarkerDB.settings.auto then return false, "auto mode off" end
  if InGroup() then
    if PlayerCanRaidMark() then return true, "leader/assist" end
    return false, "idle: not leader/assist"
  end
  if not has_superwow then return false, "solo marking needs SuperWoW" end
  return true, "solo (local marks)"
end

local function AutoCanMark()
  local ok, reason = AutoCanMarkReason()
  if not ok then
    if reason == "idle: not leader/assist" and not auto.idle_warned then
      auto_print(c("AutoMarker", color.yellow) .. ": auto mode is idle because you are not leader or assistant.")
      auto.idle_warned = true
    end
    return false
  end
  if AutoMarkerDB.settings.autoInstanceOnly and type(IsInInstance) == "function"
    and not IsInInstance() then
    return false
  end
  return true
end

-- Reverse index guid -> pack mark for the current zone (guidToPack is too
-- slow to call per unit per second).
local function BuildPackIndex(zone)
  local index = {}
  for _, pack in pairs(currentNpcsToMark[zone] or {}) do
    for guid, m in pairs(pack) do index[guid] = m end
  end
  for _, pack in pairs((AutoMarkerDB.customNpcsToMark or {})[zone] or {}) do
    for guid, m in pairs(pack) do index[guid] = m end
  end
  auto.pack_index = index
  auto.pack_index_zone = zone
  auto.pack_index_dirty = false
end

local function PackMarkFor(guid, zone)
  if auto.pack_index_dirty or auto.pack_index_zone ~= zone or not auto.pack_index then
    BuildPackIndex(zone)
  end
  return auto.pack_index[guid]
end

function AutoMarker_InvalidatePackIndex()
  auto.pack_index_dirty = true
end

-- Fills freeList with free mark indexes, Skull first. A mark is busy when the
-- markN unit resolves to a living unit, or the unit we/someone last saw
-- carrying it is alive and still carries it.
local function CollectFreeMarks(freeList)
  local n = 0
  for i = 8, 1, -1 do
    local _, m = UnitExists("mark" .. i)
    local busy = m and UnitExists(m) and not UnitIsDead(m)
    if not busy then
      local g = auto.owner[i] or auto.seen[i]
      busy = g and UnitExists(g) and not UnitIsDead(g) and GetRaidTargetIndex(g) == i
    end
    if not busy then
      n = n + 1
      freeList[n] = i
    end
  end
  local total = table.getn(freeList)
  for k = n + 1, total do freeList[k] = nil end
  return n
end

-- Collects unmarked hostile mobs around anchor into out; cheapest checks first.
local function CollectCandidates(anchor, radius, requireCombat, out)
  local zone = GetRealZoneText()
  local s = AutoMarkerDB.settings
  local cache = AutoMarkerDB.unitCache
  local n = 0
  for guid, name in pairs(cache) do
    if not IsMobGuid(guid) or not UnitExists(guid) then
      cache[guid] = nil
    else
      local mark = GetRaidTargetIndex(guid)
      if mark then
        auto.seen[mark] = guid
      elseif not UnitIsDead(guid)
        and UnitCanAttack("player", guid)
        and (guid == anchor or not requireCombat or UnitAffectingCombat(guid))
        and not UnitPlayerControlled(guid)
        and not UnitIsPlayer(guid) then
        local ctype = UnitCreatureType(guid)
        if ctype ~= "Critter" and ctype ~= "Totem"
          and not (s.autoSkipTapped and UnitIsTapped(guid) and not UnitIsTappedByPlayer(guid)) then
          local lname = string.lower(name or UnitName(guid) or "")
          if not MatchList(lname, AutoMarkerDB.autoIgnore) then
            local inRange, dist = true, 0
            if guid ~= anchor then
              inRange, dist = WithinRadius(anchor, guid, radius)
            end
            if inRange and (guid == anchor or not s.autoLos or not has_unitxp
              or UnitXP("inSight", "player", guid)) then
              n = n + 1
              local rec = out[n]
              if not rec then
                rec = {}
                out[n] = rec
              end
              rec.guid = guid
              rec.name = lname
              rec.dist = dist or 0
              rec.rank = MatchList(lname, AutoMarkerDB.autoPrio) or 999
              rec.cw = classWeight[UnitClassification(guid) or "normal"] or 4
              rec.hp = UnitMaxHP(guid)
              local lvl = UnitLevel(guid) or 0
              if lvl < 0 then lvl = 999 end
              rec.lvl = lvl
              rec.pack_mark = PackMarkFor(guid, zone)
              rec.done = nil
              if n >= 40 then break end
            end
          end
        end
      end
    end
  end
  local total = table.getn(out)
  for k = n + 1, total do out[k] = nil end
  return n
end

-- Strict total order: priority, then health/class, level, distance, guid.
local function CandidateLess(a, b)
  if a.rank ~= b.rank then return a.rank < b.rank end
  if AutoMarkerDB.settings.autoSort == "class" then
    if a.cw ~= b.cw then return a.cw < b.cw end
    if a.hp ~= b.hp then return a.hp > b.hp end
  else
    if a.hp ~= b.hp then return a.hp > b.hp end
    if a.cw ~= b.cw then return a.cw < b.cw end
  end
  if a.lvl ~= b.lvl then return a.lvl > b.lvl end
  if a.dist ~= b.dist then return a.dist < b.dist end
  return a.guid < b.guid
end

local function AssignMark(guid, i)
  -- local marks are not unique server-side: clear the previous carrier first
  if not PlayerCanRaidMark() then
    local old = auto.owner[i]
    if old and old ~= guid and UnitExists(old) then MarkUnit(old, 0) end
  end
  MarkUnit(guid, i)
  local prev = auto.owner_guid[guid]
  if prev and auto.owner[prev] == guid then auto.owner[prev] = nil end
  auto.owner[i] = guid
  auto.owner_guid[guid] = i
  if AutoMarkerDB.settings.debug then
    auto_print("auto: " .. raidMarks[i + 1] .. " -> " .. (UnitName(guid) or guid))
  end
end

-- Core: fills free marks around anchor. Returns the number of marks placed.
local function AutoAssign(anchor, radius, requireCombat)
  local free = auto.free
  local nfree = CollectFreeMarks(free)
  if nfree == 0 then return 0 end
  local cands = auto.cands
  local n = CollectCandidates(anchor, radius, requireCombat, cands)
  if n == 0 then return 0 end

  local placed = 0
  -- pass 1: pack members get their pack mark when it is free
  for k = 1, n do
    local r = cands[k]
    if r.pack_mark and r.pack_mark > 0 then
      for f = 1, table.getn(free) do
        if free[f] == r.pack_mark then
          AssignMark(r.guid, r.pack_mark)
          tremove(free, f)
          r.done = true
          placed = placed + 1
          break
        end
      end
    end
  end
  -- pass 1b: names learned from marks people set get their usual mark
  if AutoMarkerDB.settings.autoLearn then
    for k = 1, n do
      local r = cands[k]
      if not r.done then
        local lm = AutoMarkerDB.learned[r.name]
        if lm and lm > 0 then
          for f = 1, table.getn(free) do
            if free[f] == lm then
              AssignMark(r.guid, lm)
              tremove(free, f)
              r.done = true
              placed = placed + 1
              break
            end
          end
        end
      end
    end
  end
  -- pass 2: everyone else by priority, Skull downward
  tsort(cands, CandidateLess)
  local f = 1
  for k = 1, n do
    local r = cands[k]
    if not r.done then
      if not free[f] then break end
      AssignMark(r.guid, free[f])
      f = f + 1
      placed = placed + 1
    end
  end
  for k = 1, n do cands[k].done = nil end
  return placed
end

-- In-combat filler. force = scan now regardless of combat state.
function AutoMarker_AutoScan(force)
  if not AutoMarkerDB or not AutoMarkerDB.settings then return end
  if not force and not auto.in_combat then return end
  if not AutoCanMark() then
    if force then
      local _, reason = AutoCanMarkReason()
      auto_print("AutoMarker: auto scan skipped (" .. reason .. ").")
    end
    return
  end
  auto.next_scan = GetTime() + (AutoMarkerDB.settings.autoInterval or 1)
  local placed = AutoAssign("player", AutoMarkerDB.settings.autoRadius,
    AutoMarkerDB.settings.autoRequireCombat and not force)
  if force then
    auto_print("AutoMarker: auto scan placed " .. placed .. " mark(s).")
  end
end

-- Pull pre-mark: the anchor mob and hostiles within pullRadius of it.
function AutoMarker_AutoPull(anchorGuid)
  if not anchorGuid or not AutoCanMark() then return end
  local now = GetTime()
  if anchorGuid == auto.last_pull_guid and now - auto.last_pull_time < 1.0 then return end
  auto.last_pull_guid = anchorGuid
  auto.last_pull_time = now
  AutoAssign(anchorGuid, AutoMarkerDB.settings.pullRadius, false)
end

function AutoMarker_OnUnitDied(guid)
  local i = auto.owner_guid[guid]
  if i then
    if auto.owner[i] == guid then auto.owner[i] = nil end
    auto.owner_guid[guid] = nil
    if auto.in_combat then auto.next_scan = 0 end
  end
end

function AutoMarker_SetCombat(inCombat)
  auto.in_combat = inCombat and true or false
  if inCombat then
    auto.next_scan = 0
  else
    auto.seen = {}
  end
end

function AutoMarker_ResetAutoState()
  auto.owner = {}
  auto.owner_guid = {}
  auto.seen = {}
  auto.pack_index_dirty = true
  for guid in pairs(addonPlaced) do addonPlaced[guid] = nil end
end

-- /// Learning from marks set by people /// --

local recordGroup = { name = nil, zone = nil, time = 0, anchor = nil }

local function SanitizePackName(name)
  local n = string.lower(name or "")
  n = string.gsub(n, "[^%w]+", "_")
  n = string.gsub(n, "^_+", "")
  n = string.gsub(n, "_+$", "")
  if n == "" then n = "pack" end
  return n
end

-- Records guid with its current mark into a custom pack for this zone. Marks
-- set within 30 s and pullRadius of each other land in the same pack.
local function RecordIntoPack(guid, name)
  local zone = GetRealZoneText()
  local now = GetTime()
  local packName = recordGroup.name
  local reuse = packName and recordGroup.zone == zone and (now - recordGroup.time) < 30
  if reuse and recordGroup.anchor and recordGroup.anchor ~= guid then
    local d = DistanceBetween(recordGroup.anchor, guid)
    if d and d > AutoMarkerDB.settings.pullRadius then reuse = false end
  end
  local existing = guidToPack(guid, zone)
  if existing then
    packName = existing
    reuse = true
  end
  if not reuse then
    local base = SanitizePackName(name)
    local custom = AutoMarkerDB.customNpcsToMark[zone] or {}
    local defaults = currentNpcsToMark[zone] or {}
    packName = base
    local n = 1
    while custom[packName] or defaults[packName] do
      n = n + 1
      packName = base .. "_" .. n
    end
    recordGroup.anchor = guid
  end
  recordGroup.name = packName
  recordGroup.zone = zone
  recordGroup.time = now
  AddToPack(guid, true, packName)
end

local function NoteManualMark(guid, mark)
  local s = AutoMarkerDB.settings
  local name = UnitName(guid)
  if not name or mark <= 0 then return end
  if s.autoLearn then
    local lname = string.lower(name)
    if AutoMarkerDB.learned[lname] ~= mark then
      AutoMarkerDB.learned[lname] = mark
      if s.debug then auto_print("learned: " .. name .. " -> " .. raidMarks[mark + 1]) end
    end
  end
  local rec = s.autoRecord
  local inInstance = type(IsInInstance) == "function" and IsInInstance()
  if rec == "always" or (rec == "instance" and inInstance) then
    RecordIntoPack(guid, name)
  end
end

-- Fired by the client whenever any raid target changes. Marks that differ
-- from what this addon placed were set by a person.
function AutoMarker_OnRaidTargetUpdate()
  if not has_superwow or not AutoMarkerDB or not AutoMarkerDB.settings then return end
  local s = AutoMarkerDB.settings
  if not s.autoLearn and s.autoRecord == "off" then return end
  for i = 1, 8 do
    local _, guid = UnitExists("mark" .. i)
    if guid and IsMobGuid(guid) and addonPlaced[guid] ~= i then
      addonPlaced[guid] = i
      NoteManualMark(guid, i)
    end
  end
end

-- Sorted array of { name = , mark = } for the panel and /am learned.
function AutoMarker_LearnedList()
  local list = {}
  for name, mark in pairs(AutoMarkerDB.learned or {}) do
    tinsert(list, { name = name, mark = mark })
  end
  tsort(list, function(a, b)
    if a.mark ~= b.mark then return a.mark > b.mark end
    return a.name < b.name
  end)
  return list
end

function AutoMarker_LearnedRemove(name)
  name = string.lower(name or "")
  if AutoMarkerDB.learned[name] == nil then return false, "not learned" end
  AutoMarkerDB.learned[name] = nil
  return true
end

function AutoMarker_LearnedReset()
  AutoMarkerDB.learned = {}
  return true
end

-- Custom (recorded) packs in the current zone: array of { name = , count = }.
function AutoMarker_ZonePacks()
  local zone = GetRealZoneText()
  local list = {}
  for packName, pack in pairs((AutoMarkerDB.customNpcsToMark or {})[zone] or {}) do
    local count = 0
    for _ in pairs(pack) do count = count + 1 end
    tinsert(list, { name = packName, count = count })
  end
  tsort(list, function(a, b) return a.name < b.name end)
  return list
end

function AutoMarker_DeletePack(packName)
  local zone = GetRealZoneText()
  local custom = (AutoMarkerDB.customNpcsToMark or {})[zone]
  if not custom or not custom[packName] then return false, "no such pack" end
  custom[packName] = nil
  if currentNpcsToMark[zone] then
    currentNpcsToMark[zone][packName] = defaultNpcsToMark[zone] and defaultNpcsToMark[zone][packName] or nil
  end
  if recordGroup.name == packName then recordGroup.name = nil end
  AutoMarker_InvalidatePackIndex()
  return true
end

-- /// Public API used by the info panel and slash commands /// --

function AutoMarker_GetStatus()
  if not AutoMarkerDB or not AutoMarkerDB.settings then return nil end
  local ok, reason = AutoCanMarkReason()
  local cacheSize = 0
  for _ in pairs(AutoMarkerDB.unitCache or {}) do cacheSize = cacheSize + 1 end
  local zone = GetRealZoneText()
  local zonePacks = currentNpcsToMark[zone]
  return {
    enabled = AutoMarkerDB.settings.enabled,
    auto = AutoMarkerDB.settings.auto,
    canMark = ok,
    reason = reason,
    zone = zone,
    zoneHasPacks = (zonePacks ~= nil and next(zonePacks) ~= nil),
    freeMarks = CollectFreeMarks(auto.free),
    cacheSize = cacheSize,
    inCombat = auto.in_combat,
    superwow = has_superwow,
    superwowVersion = SUPERWOW_VERSION,
    nampower = use_nampower and true or false,
    nampowerVersion = np_major and (np_major .. "." .. (np_minor or 0) .. "." .. (np_patch or 0)) or nil,
    unitxp = has_unitxp and true or false,
    classicapi = has_classicapi,
  }
end

local settingLimits = {
  autoRadius = { 5, 100 },
  pullRadius = { 5, 100 },
  autoInterval = { 0.25, 10 },
}

-- Returns true when the value was accepted.
function AutoMarker_SetSetting(key, value)
  if not AutoMarkerDB or not AutoMarkerDB.settings then return false end
  if defaultSettings[key] == nil then return false end
  if type(defaultSettings[key]) == "boolean" then
    AutoMarkerDB.settings[key] = value and true or false
  elseif type(defaultSettings[key]) == "number" then
    value = tonumber(value)
    if not value then return false end
    local limit = settingLimits[key]
    if limit then
      if value < limit[1] then value = limit[1] end
      if value > limit[2] then value = limit[2] end
    end
    AutoMarkerDB.settings[key] = value
  else
    if key == "autoSort" and value ~= "health" and value ~= "class" then return false end
    if key == "autoRecord" and value ~= "off" and value ~= "instance" and value ~= "always" then return false end
    AutoMarkerDB.settings[key] = value
  end
  if key == "auto" then auto.idle_warned = false end
  return true
end

local function AutoListFor(which)
  if which == "ignore" then return AutoMarkerDB.autoIgnore end
  return AutoMarkerDB.autoPrio
end

function AutoMarker_PrioList(which)
  return AutoListFor(which)
end

local function FindInList(list, pattern)
  for i, v in ipairs(list) do
    if v == pattern then return i end
  end
  return nil
end

-- Returns true, or false and an error text.
function AutoMarker_PrioAdd(which, pattern)
  pattern = string.lower(pattern or "")
  pattern = string.gsub(pattern, "^%s+", "")
  pattern = string.gsub(pattern, "%s+$", "")
  if pattern == "" then return false, "empty pattern" end
  local ok = pcall(sfind, "", pattern)
  if not ok then return false, "invalid pattern" end
  local list = AutoListFor(which)
  if FindInList(list, pattern) then return false, "already in list" end
  tinsert(list, pattern)
  return true
end

function AutoMarker_PrioRemove(which, pattern)
  local list = AutoListFor(which)
  local i = FindInList(list, string.lower(pattern or ""))
  if not i then return false, "not in list" end
  tremove(list, i)
  return true
end

function AutoMarker_PrioTop(which, pattern)
  local list = AutoListFor(which)
  pattern = string.lower(pattern or "")
  local i = FindInList(list, pattern)
  if not i then return false, "not in list" end
  tremove(list, i)
  tinsert(list, 1, pattern)
  return true
end

function AutoMarker_PrioReset(which)
  if which == "ignore" then
    AutoMarkerDB.autoIgnore = CopyList(defaultAutoIgnore)
  else
    AutoMarkerDB.autoPrio = CopyList(defaultAutoPrio)
  end
  return true
end

function AutoMarker_PrintStatus()
  local st = AutoMarker_GetStatus()
  if not st then return end
  local function onoff(v) return v and c("on", color.green) or c("off", color.red) end
  auto_print(c("AutoMarker status", color.yellow))
  auto_print("  addon " .. onoff(st.enabled) .. ", auto mode " .. onoff(st.auto)
    .. ", can mark: " .. (st.canMark and c("yes", color.green) or c("no", color.red))
    .. " (" .. st.reason .. ")")
  auto_print("  zone: " .. tostring(st.zone) .. (st.zoneHasPacks and " (has pack data)" or " (no pack data)")
    .. ", free marks: " .. st.freeMarks .. ", cached mobs: " .. st.cacheSize)
  auto_print("  radius " .. AutoMarkerDB.settings.autoRadius .. " yd, pull radius "
    .. AutoMarkerDB.settings.pullRadius .. " yd, sort " .. AutoMarkerDB.settings.autoSort
    .. ", require combat " .. onoff(AutoMarkerDB.settings.autoRequireCombat)
    .. ", line of sight " .. onoff(AutoMarkerDB.settings.autoLos))
  auto_print("  SuperWoW " .. (st.superwow and c("yes", color.green) .. " " .. tostring(st.superwowVersion or "") or c("no", color.red))
    .. ", Nampower " .. (st.nampower and c("yes", color.green) .. " " .. tostring(st.nampowerVersion or "") or c("no", color.red))
    .. ", UnitXP " .. (st.unitxp and c("yes", color.green) or c("no", color.red))
    .. ", ClassicAPI " .. (st.classicapi and c("yes", color.green) or c("no", color.red)))
end

local function AMUpdate()
  elapsed = elapsed + arg1
  core_delay_elapsed = core_delay_elapsed + arg1
  if elapsed > 0.25 then
    elapsed = 0

    if AutoMarkerDB.settings.auto and auto.in_combat and GetTime() >= auto.next_scan then
      AutoMarker_AutoScan()
    end

    if AutoMarkerDB.checkCoreHounds and core_delay_elapsed > core_delay then
      core_delay_elapsed = 0
      UpdateCorehound()
    end
    if AutoMarkerDB.checkSoliders then UpdateSoldiers() end
    if AutoMarkerDB.checkKeepers then UpdateKeepers() end
    if AutoMarkerDB.checkProtectors then UpdateProtectors() end
    if AutoMarkerDB.checkTemporaryMobs then UpdateTemporaryMobs() end
  end
end
autoMarker:SetScript("OnUpdate", AMUpdate)

-- EVENTS ----------------------

autoMarker:RegisterEvent("ADDON_LOADED")
autoMarker:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
autoMarker:RegisterEvent("PLAYER_REGEN_DISABLED")
autoMarker:RegisterEvent("PLAYER_ENTERING_WORLD")
autoMarker:RegisterEvent("PLAYER_REGEN_ENABLED")
autoMarker:RegisterEvent("ZONE_CHANGED_NEW_AREA")
autoMarker:RegisterEvent("CHAT_MSG_ADDON") -- slow corehound mark swap
autoMarker:RegisterEvent(use_nampower and "UNIT_MODEL_CHANGED_GUID" or "UNIT_MODEL_CHANGED")
autoMarker:RegisterEvent("UNIT_DIED") -- nampower; inert on clients without it
autoMarker:RegisterEvent("RAID_TARGET_UPDATE")

autoMarker.TriggerEvent = function (self,event,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10)
  if autoMarker[event] then
    autoMarker[event](autoMarker,a1,a2,a3,a4,a5,a6,a7,a8,a9,a10)
  end
end

-- initial loading
autoMarker:SetScript("OnEvent", function ()
  if event == "ADDON_LOADED" and arg1 == "AutoMarker" then
    autoMarker:Initialize()
    autoMarker:SetScript("OnEvent", function ()
      if AutoMarkerDB.settings.enabled and autoMarker[event]then
        autoMarker[event](autoMarker,arg1,arg2,arg3,arg4,arg5,arg6,arg7,arg8,arg9,arg10)
      end
    end)
  end
end)

-- Event handlers
function autoMarker:Initialize()
  -- init vars
  if not AutoMarkerDB then AutoMarkerDB = {} end
  if not AutoMarkerDB.customNpcsToMark then AutoMarkerDB.customNpcsToMark = {} end
  if not AutoMarkerDB.temp_values then
    AutoMarkerDB.temp_values = {
      buru_egg_queue = {},
      corehounds = {},
      soldiers = {},
      keepers = {},
      protectors = {},
      solnius_adds = { count = 0 },
    }
  end
  if not AutoMarkerDB.unitCache then AutoMarkerDB.unitCache = {} end

  if not AutoMarkerDB.started_solnius then AutoMarkerDB.started_solnius = false end
  if not AutoMarkerDB.started_queen then AutoMarkerDB.started_queen = false end
  if not AutoMarkerDB.started_medivh then AutoMarkerDB.started_medivh = false end
  if not AutoMarkerDB.checkCoreHounds then AutoMarkerDB.checkCoreHounds = false end
  if not AutoMarkerDB.checkSoliders then AutoMarkerDB.checkSoliders = false end
  if not AutoMarkerDB.checkKeepers then AutoMarkerDB.checkKeepers = false end
  if not AutoMarkerDB.checkProtectors then AutoMarkerDB.checkProtectors = false end
  if not AutoMarkerDB.checkTemporaryMobs then AutoMarkerDB.checkTemporaryMobs = false end

  -- clear unit cache
  -- TODO: do this on logout instead?
  for guid, _ in pairs(AutoMarkerDB.unitCache) do
    if not UnitExists(guid) then
      AutoMarkerDB.unitCache[guid] = nil
    end
  end

  -- init settings
  -- Copy defaults into a fresh table and keep saved values, including
  -- saved `false`, which the old `saved or default` migration lost.
  local source = AutoMarkerDB.settings or settings or {}
  local s = {}
  for k,v in pairs(defaultSettings) do
    if source[k] == nil then
      s[k] = v
    else
      s[k] = source[k]
    end
  end
  AutoMarkerDB.settings = s
  AutoMarker_InitAutoLists()

  -- load defaults
  for raid_name,packs in pairs(defaultNpcsToMark) do
    if not currentNpcsToMark[raid_name] then currentNpcsToMark[raid_name] = {} end
    for pack_name,pack in pairs(packs) do
      if not currentNpcsToMark[raid_name][pack_name] then
        currentNpcsToMark[raid_name][pack_name] = defaultNpcsToMark[raid_name][pack_name]
      end
    end
  end
  -- over-write with customs
  for raid_name,packs in pairs(AutoMarkerDB.customNpcsToMark) do
    if not currentNpcsToMark[raid_name] then currentNpcsToMark[raid_name] = {} end
    for pack_name,pack in pairs(packs) do
      currentNpcsToMark[raid_name][pack_name] = AutoMarkerDB.customNpcsToMark[raid_name][pack_name]
    end
  end

  -- migrate old customs
  if customNpcsToMark and next(customNpcsToMark) then
    for raid_name,packs in pairs(customNpcsToMark) do
      if not AutoMarkerDB.customNpcsToMark[raid_name] then AutoMarkerDB.customNpcsToMark[raid_name] = {} end
      for pack_name,pack in pairs(packs) do
        AutoMarkerDB.customNpcsToMark[raid_name][pack_name] = customNpcsToMark[raid_name][pack_name]
      end
    end
  end
  auto_print(c(L["AutoMarker loaded!"],color.yellow)..L[" Type "]..c("/am",color.green)..L[" to see commands."])
end

local function ClearTemps()
  -- print("clearin")
  for _,config in pairs(temporary_mobs) do
    for _,guid in pairs(config.queue) do
      if UnitAffectingCombat(guid) then -- will this work or is it too early? does it need to work?
        config.queue = {}
        break
      end
    end
  end

  AutoMarkerDB.temp_values = {
    buru_egg_queue = {},
    corehounds = {},
    soldiers = {},
    keepers = {},
    protectors = {},
    solnius_adds = {},
    solnius_adds = { count = 0 },
  }

  AutoMarkerDB.started_solnius = false
  AutoMarkerDB.started_queen = false
  AutoMarkerDB.started_medivh = false
  -- AutoMarkerDB.checkCoreHounds = false
  -- AutoMarkerDB.checkSoliders = false
  -- AutoMarkerDB.checkKeepers = false
  -- AutoMarkerDB.checkProtectors = false
  -- AutoMarkerDB.checkTemporaryMobs = false
end

function autoMarker:UPDATE_MOUSEOVER_UNIT()
  OnMouseover()
  local _,guid = UnitExists("mouseover")
  if AutoMarkerDB.settings.debug then
    auto_print(guid .. " " .. UnitName(guid))
  end
  if sweep_on then
      AddToPack(guid,true,sweepPackName)
  end
end

function autoMarker:CHAT_MSG_MONSTER_YELL(msg,from)
  if from == L["Echo of Medivh"] and sfind(msg, L["^My patience has come to an end."]) then
    AutoMarkerDB.started_medivh = true
  end
  if from == L["Queen"] then
    AutoMarkerDB.started_queen = true
  end
end

function autoMarker:RAW_COMBATLOG(event, msg)
  if AutoMarkerDB.started_medivh and
  (event == "CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE" or
   event == "CHAT_MSG_SPELL_PERIODIC_FRIENDLYPLAYER_DAMAGE" or
   event == "CHAT_MSG_SPELL_PERIODIC_PARTY_DAMAGE") then
    if sfind(msg, L["Shadow damage from (.-)'s Corruption of Medivh%.$"]) then
      autoMarker.corruption_damage = GetTime()
    end
    return
  end

  if AutoMarkerDB.started_queen and
  (event == "CHAT_MSG_AURA_GONE_SELF" or
   event == "CHAT_MSG_AURA_GONE_PARTY" or
   event == "CHAT_MSG_AURA_GONE_OTHER") then
    local _,_,unit = sfind(msg, L["Dark Subservience fades from (.-).$"])
    if unit then
      -- clear mark from that unit
      MarkUnit(unit,autoMarker.old_queen_mark or 0)
      autoMarker.old_queen_mark = nil
    end
    return
  end
end

--[[
/run AutoMarkerFrame:CHAT_MSG_MONSTER_YELL("More uninvited guests? I have no time for intrusions.","Echo of Medivh")
/run AutoMarkerFrame:RAW_COMBATLOG("CHAT_MSG_SPELL_PERIODIC_SELF_DAMAGE","You take 800 Shadow damage from player's Corruption of Medivh.")
/run AutoMarkerFrame:UNIT_CASTEVENT("player","player","CAST", 52674,0)

/run AutoMarkerFrame:CHAT_MSG_MONSTER_YELL("","Queen")
/run AutoMarkerFrame:UNIT_CASTEVENT("player","player","CAST", 41647,0)
/run AutoMarkerFrame:RAW_COMBATLOG("CHAT_MSG_AURA_GONE_SELF","Dark Subservience fades from player.")

--]]

-- buru egg death tracking now handled via UNIT_FLAGS

-- todo, separate this into zones and load only each zone
local patterns = {
  flamewaker_healer           = "^0xF130002D8F27",
  flamewaker_elite            = "^0xF130002D9027",
  gnarlmoon_owl_blue          = "^0xF13000EA5E27",
  gnarlmoon_owl_red           = "^0xF13000EA5D27",
  incantagos_seekers          = "^0xF13000EA5527",
  incantagos_affinity_mana    = "^0xF13000EA4E27",
  incantagos_affinity_black   = "^0xF13000EA4F27",
  incantagos_affinity_blue    = "^0xF13000EA5027",
  incantagos_affinity_green   = "^0xF13000EA5127",
  incantagos_affinity_red     = "^0xF13000EA5227",
  incantagos_affinity_crystal = "^0xF13000EA5327",
  sanv_riftstalker            = "^0xF13000EA4827",
  sanv_netherwalker           = "^0xF13000EA4A27",
  rupturan_fragment           = "^0xF13000EA3527",
  rupturan_exile              = "^0xF13000EA3807",
  mephistroth_doomguards      = "^0xF130016C9827",
  onyxia_hatchers             = "^0xF13000C3E027",
  chieftain_illuminators      = "^0xF13000F5DE27",
  chieftain_shadowkeepers     = "^0xF13000F5DF27",
  rupturan_dirt_mound         = "^0xF13000EA3427",
  naxx_plague_gargs           = "^0xF130003F2801",
  buru_eggs                   = "^0xF130003C9A27",
  ursol_corrupters            = "^0xF13000732827",
  rotgrowl_kodiak             = "^0xF13000F5D927",
}

-- start with skull unless reversed
function autoMarker:ApplyNextMark(guid,reverse)
  local start,stop,step = 8,1,-1
  if reverse then start,stop,step = 1,8,1 end

  for i=start,stop,step do
    -- the "mark" unitid isn't performant, avoid using multiple times
    local _,m = UnitExists("mark"..i)
    if not (UnitExists(m) and not UnitIsDead(m)) then
      -- if mark isn't active, use it
      MarkUnit(guid,i)
      break
    end
  end
end

local function TryPatterns(guid,...)
  for i = 1, arg.n do
    if sfind(guid, arg[i]) then return true end
  end
end

-- nampower _GUID event wrappers
function autoMarker:UNIT_MODEL_CHANGED_GUID(guid)
  self:UNIT_MODEL_CHANGED(guid)
end

function autoMarker:UNIT_FLAGS_GUID(guid)
  self:UNIT_FLAGS(guid)
end

-- Workhorse, detects when a unit model is loaded in the client.
-- Units can technically be checked for exsitence before this but this event lets us do it on the fly.
function autoMarker:UNIT_MODEL_CHANGED(guid,debug_id,debug_name)
  -- Certain mobs are script spawned so their IDs need to be fetched

  local name = UnitName(guid)
  local zone = GetRealZoneText()

  if AutoMarkerDB.settings.debug then
    _,guid = UnitExists(debug_id or guid)
    name = debug_name or UnitName(guid)
    auto_print(guid .. " " .. name)
  end

  -- player unit models change _often_, exit early if it's not a mob guid
  if ssub(guid,3,3) ~= "F" then return end -- use IsPlayer(guid) ?

  -- store found mob guid: used by `/am markname` and by auto mode scans
  AutoMarkerDB.unitCache[guid] = name

  if zone == L["Tower of Karazhan"] or zone == L["The Rock of Desolation"] then

    if TryPatterns(guid,patterns.gnarlmoon_owl_blue,patterns.gnarlmoon_owl_red) then
      name = "Gnarlmoon Owl"

    elseif TryPatterns(guid,patterns.rupturan_fragment) then
      name = "Fragment of Rupturan"

    elseif TryPatterns(guid, patterns.rupturan_exile) then
      name = "Crumbling Exile"

    elseif TryPatterns(guid,patterns.rupturan_dirt_mound) then
      MarkUnit(guid,4)
      return

    elseif TryPatterns(guid, patterns.mephistroth_doomguards) then
      name = "Hellfire Doomguard"

    elseif TryPatterns(guid, patterns.incantagos_seekers) then
      name = "Manascale Ley-Seeker"
    -- mid-fight ley-seekers have a different guid base of 0xF14

    -- incantagos affinity - detect by guid pattern
    elseif not GetRaidTargetIndex(guid) and TryPatterns(guid,
        patterns.incantagos_affinity_mana, patterns.incantagos_affinity_black,
        patterns.incantagos_affinity_blue, patterns.incantagos_affinity_green,
        patterns.incantagos_affinity_red, patterns.incantagos_affinity_crystal) then
      MarkUnit(guid,8)
      return

    -- sanv stalkers
    elseif not GetRaidTargetIndex(guid) and TryPatterns(guid, patterns.sanv_riftstalker) then
      self:ApplyNextMark(guid) -- might have similar issue to owls if 2 spawn at once
      return
    elseif not GetRaidTargetIndex(guid) and TryPatterns(guid, patterns.sanv_netherwalker) then
      self:ApplyNextMark(guid,true) -- reverse, to hopefully leave skull/x for stalkers
      return
    end

  elseif zone == L["Timbermaw Hold"] then
    if TryPatterns(guid, patterns.chieftain_illuminators) then
      name = "Withermaw Illuminator"
    elseif TryPatterns(guid, patterns.ursol_corrupters) then
      name = "Withermaw Corrupter"
    elseif TryPatterns(guid, patterns.chieftain_shadowkeepers) then
      name = "Withermaw Shadowkeeper"
    elseif TryPatterns(guid, patterns.rotgrowl_kodiak) then
      name = "Kodiak"
    end

  elseif zone == L["Onyxia's Lair"] then
    if TryPatterns(guid, patterns.onyxia_hatchers) then
      name = "Onyxian Hatcher"
    end

  elseif zone == L["Naxxramas"] or zone == L["The Upper Necropolis"] then
    if name == L["Naxxramas Follower"] or name == L["Naxxramas Worshipper"] then
      name = "Faerlina Add"
    elseif name == L["Soldier of the Frozen Wastes"] then
      AutoMarkerDB.temp_values.soldiers[guid] = true
      AutoMarkerDB.checkSoliders = true
      return
    end
    -- ignore patrol garg
    if TryPatterns(guid,patterns.naxx_plague_gargs) and guid ~= "0xF130003F2801581E" then
      -- register for unit flag changes here, mark on flag change for these gargs
    end

  elseif zone == L["Blackrock Depths"] or zone == L["The Lyceum"] then
    if name == L["Shadowforge Flame Keeper"] then
      AutoMarkerDB.temp_values.keepers[guid] = true
      AutoMarkerDB.checkKeepers = true
      return
    end

  elseif zone == L["Dire Maul"] or zone == L["Capital Gardens"] then
    if name == L["Ironbark Protector"] then
      AutoMarkerDB.temp_values.protectors[guid] = true
      AutoMarkerDB.checkProtectors = true
      return
    end

  elseif zone == L["Ahn'Qiraj"] then
    -- fangkriss adds
    if name == L["Spawn of Fankriss"] and not GetRaidTargetIndex(guid) then
      self:ApplyNextMark(guid)
      return
    end

  elseif zone == L["Ruins of Ahn'Qiraj"] and TryPatterns(guid, patterns.buru_eggs) then
    name = "Buru Egg"
    -- buru eggs respawn throughout the fight but we want them marked still
    if AutoMarkerDB.temp_values.buru_egg_queue then
      local next_egg_mark = tremove(AutoMarkerDB.temp_values.buru_egg_queue,1)
      if next_egg_mark then
        MarkUnit(guid, next_egg_mark)
      end
      return
    end

  elseif zone == L["Emerald Sanctum"] then
    -- Solnius adds
    -- did solnius go dragonform
    if name == L["Solnius"] and UnitAffectingCombat(guid) then
      -- print("started")
      AutoMarkerDB.started_solnius = true
    end
    if AutoMarkerDB.started_solnius and elem(solinus_prio,name) then
      AutoMarkerDB.temp_values.solnius_adds[name] = AutoMarkerDB.temp_values.solnius_adds[name] or {}
      tinsert(AutoMarkerDB.temp_values.solnius_adds[name], guid)
      AutoMarkerDB.temp_values.solnius_adds.count = (AutoMarkerDB.temp_values.solnius_adds.count or 0) + 1

      if AutoMarkerDB.temp_values.solnius_adds.count >= 3 then
        -- check each entry by prio and assign marks
        local ix = 1
        for _,mobtype in ipairs(solinus_prio) do
          for _,guid in ipairs(AutoMarkerDB.temp_values.solnius_adds[mobtype] or {}) do
            local mark_id = 9-ix
            MarkUnit(guid,mark_id)
            ix = ix + 1
          end
        end
        ClearTemps()
      end
      return
    end

  elseif zone == L["Molten Core"] then
    if TryPatterns(guid, patterns.flamewaker_healer, patterns.flamewaker_elite) then
    -- if name == L["Flamewaker Healer"] or name == L["Flamewaker Elite"] then
      name = "Domo Add"
    elseif name == L["Core Hound"] then
      AutoMarkerDB.temp_values.corehounds[guid] = true
      AutoMarkerDB.checkCoreHounds = true
      return
    end

  elseif zone == L["Blackwing Lair"] and name == L["Lord Victor Nefarius"] then
    MarkUnit(guid,2)
    return
  end

  if temporary_mobs[name] then
    -- key by id in case you leave the area and come back, which would otherwise add the same mob twice
    temporary_mobs[name].queue[guid] = guid
    AutoMarkerDB.checkTemporaryMobs = true
    return
  end

end

-- clear solnius etc
function autoMarker:PLAYER_REGEN_ENABLED()
  -- As far as I know fd/vanish won't trigger this while the raid is still fighting.
  -- Combat ended, reset relevant model queues
  AutoMarker_SetCombat(false)
  ClearTemps()
end

function autoMarker:PLAYER_ENTERING_WORLD()
  self:ZONE_CHANGED_NEW_AREA()
  ClearTemps()
end

function autoMarker:PLAYER_REGEN_DISABLED()
  -- Combat started: auto mode scans on the next tick
  AutoMarker_SetCombat(true)
end

function autoMarker:UNIT_DIED(guid)
  AutoMarker_OnUnitDied(guid)
end

function autoMarker:RAID_TARGET_UPDATE()
  AutoMarker_OnRaidTargetUpdate()
end

function autoMarker:ZONE_CHANGED_NEW_AREA()
  local zone = GetRealZoneText()
  AutoMarkerDB.zone = zone
  AutoMarker_ResetAutoState()
  if zone == L["Blackrock Spire"] and IsInInstance() and UnitExists("0xF13000290D104DD6") then
    UIErrorsFrame:AddMessage(L["Jed is in the instance!"],0,1,0)
  elseif zone == L["Naxxramas"] or zone == L["Ruins of Ahn'Qiraj"] then
    autoMarker:RegisterEvent(use_nampower and "UNIT_FLAGS_GUID" or "UNIT_FLAGS")
  end
end

-- scan for unit flag changes (aggro, death, etc.)
function autoMarker:UNIT_FLAGS(guid)
  if string.sub(guid, 3, 3) ~= "F" then return end -- only track mob guids

  -- naxx: gargoyle aggroed for the first time
  if UnitAffectingCombat(guid) and UnitCanAttack("player", guid) and not aggro_tracker[guid] and TryPatterns(guid, patterns.naxx_plague_gargs) then
    aggro_tracker[guid] = true
    local pack, packMobs = guidToPack(guid, GetRealZoneText())
    MarkPack(packMobs or {})
    return
  end

  -- aq20: buru egg died, store its mark for re-application on respawn
  if UnitIsDead(guid) and TryPatterns(guid, patterns.buru_eggs) then
    local mark = GetRaidTargetIndex(guid)
    if mark then
      if not AutoMarkerDB.temp_values.buru_egg_queue then AutoMarkerDB.temp_values.buru_egg_queue = {} end
      tinsert(AutoMarkerDB.temp_values.buru_egg_queue, mark)
    end
    return
  end
end

function autoMarker:CHAT_MSG_ADDON(prefix,msg,channel,sender)
  if prefix ~= sync_prefix then return end
  if channel ~= "RAID" and channel ~= "PARTY" then return end

  -- reset the delay if someone else already updated the mark
  if msg == "COREHOUND_MARKED" and sender ~= UnitName("player") then
    core_delay_elapsed = -1 -- you are no longer in control of the timing
  end
end
--------------------------------

local function handleCommands(msg, editbox)
  local args = {}
  for word in string.gfind(msg, '%S+') do
    if word ~= "" then
      tinsert(args, word)
    end
  end

  local command, packName = args[1], args[2]
  local force_add = command == "forceadd"
  local zoneName = GetRealZoneText()
  local function getGuid()
    local _, guid = UnitExists("target")
    return guid
  end

  -- Disable sweep if another command is used after sweep is enabled
  if sweep_on then
    sweep_on = false
    auto_print(L["Sweep mode [ "] .. c(L["off"], color.red) .. " ]")
    return
  end

  if command == "enabled" then
    AutoMarkerDB.settings.enabled = not AutoMarkerDB.settings.enabled
    auto_print(L["AutoMarker is now ["] ..
        (AutoMarkerDB.settings.enabled and c(L["enabled"], color.green) or c(L["disabled"], color.red)) .. "]")
  elseif command == "set" or command == "s" then
    if not packName then
      auto_print(L["You must provide a pack name as well when using set."])
      return
    end
    currentPackName = packName
    auto_print(L["Packname set to: "] .. c(currentPackName, color.orange))
  elseif command == "get" or command == "g" then
    auto_print(L["Current packname set to: "] .. c(currentPackName or L["none"], color.orange))
    local guid = getGuid()
    if guid then
      local packName,pack = guidToPack(guid, zoneName)
      if packName then
        local mark = pack[guid]+1
        auto_print(format(L["Mob %s (%s) is %s in pack: %s"],guid,UnitName(guid),raidMarks[mark],c(packName,color.orange)))
      else
        auto_print(format(L["Mob %s (%s) is not in any pack."],guid,UnitName(guid)))
      end
    end
  elseif command == "clear" or command == "c" then
    if currentPackName then
      if AutoMarkerDB.customNpcsToMark[zoneName] then
        AutoMarkerDB.customNpcsToMark[zoneName][currentPackName] = nil
        AutoMarker_InvalidatePackIndex()
        auto_print(L["Mobs in "] .. currentPackName .. L[" have been cleared."])
      end
    else
      auto_print(L["A packname isn't currently set."])
    end
  elseif command == "remove" or command == "r" then
    local guid = getGuid()
    if not guid then
      auto_print(L["Must target a mob to remove it from its pack."])
      return
    end
    local packName = guidToPack(guid, zoneName)
    if not packName then
      auto_print(L["Mob not in any pack."])
      return
    end
    auto_print(L["Removing mob "] .. UnitName(guid) .. L[" from pack: "] .. c(packName, color.orange))
    AutoMarkerDB.customNpcsToMark[zoneName][packName][guid] = nil
    AutoMarker_InvalidatePackIndex()
  elseif command == "add" or command == "a" or force_add then
    local guid = getGuid()
    local success, err = AddToPack(guid, force_add, packName)
    if not success then
      if err == "no_guid" then
        auto_print(L["You must target a mob."])
      elseif err == "no_pack_name" then
        auto_print(L["You must provide a pack name to add the mob to."])
      elseif err == "mob_in_pack" then
        auto_print(L["The mob is already in a pack. Use "] .. c("/am forceadd", color.yellow) .. L[" to override."])
      end
    end
  elseif command == "sweep" then
    local targetPackName = packName or currentPackName
    if not targetPackName then
      auto_print(L["Provide the pack name to this command as well or set one using "] .. c("/am set", color.yellow))
      return
    end
    sweep_on = true
    sweepPackName = targetPackName
    auto_print(L["Sweep mode [ "] .. c(L["on"], color.green) .. L[" ] sweep your mouse over enemies to add them to pack: "] .. c(sweepPackName, color
        .orange))
  elseif command == "clearmarks" then
    AutoMarker_ClearMarks()
  elseif command == "next" then
    AutoMarker_MarkNextGroup()
  elseif command == "mark" then
    AutoMarker_MarkGroup()
  elseif command == "markname" then
    if not packName then
      -- no name given, try to mark by target's guid pattern
      local _, guid = UnitExists("target")
      if guid then
        local guidPattern = ssub(guid, 1, 12)
        auto_print("target guid: " .. guid .. " | pattern: " .. guidPattern .. " | cache size: " .. getn(AutoMarkerDB.unitCache))
        AutoMarker_MarkGuidPattern(guidPattern)
      else
        auto_print(L["You must provide a name as well when using markname."])
      end
      return
    end
    tremove(args,1)
    AutoMarker_MarkName(table.concat(args, " "))
  elseif command == "debug" then
    AutoMarkerDB.settings.debug = not AutoMarkerDB.settings.debug
    auto_print(L["Debug mode set to: "] .. (AutoMarkerDB.settings.debug and c(L["on"], color.green) or c(L["off"], color.red)))

  -- /// auto mode commands /// --
  elseif command == "auto" then
    local sub = packName and string.lower(packName)
    if sub == "status" then
      AutoMarker_PrintStatus()
      return
    elseif sub == "on" then
      AutoMarker_SetSetting("auto", true)
    elseif sub == "off" then
      AutoMarker_SetSetting("auto", false)
    else
      AutoMarker_SetSetting("auto", not AutoMarkerDB.settings.auto)
    end
    auto_print("Auto mode [ " .. (AutoMarkerDB.settings.auto and c("on", color.green) or c("off", color.red)) .. " ]")
  elseif command == "autoscan" then
    AutoMarker_AutoScan(true)
  elseif command == "radius" or command == "pullradius" then
    local key = command == "radius" and "autoRadius" or "pullRadius"
    if not tonumber(packName) then
      auto_print("Current " .. command .. ": " .. AutoMarkerDB.settings[key] .. " yards. Use /am " .. command .. " <5-100>.")
      return
    end
    AutoMarker_SetSetting(key, packName)
    auto_print(command .. " set to " .. AutoMarkerDB.settings[key] .. " yards.")
  elseif command == "prio" or command == "ignore" then
    local which = command
    local sub = packName and string.lower(packName)
    local pattern = table.concat(args, " ", 3)
    local ok, err
    if sub == "add" then
      ok, err = AutoMarker_PrioAdd(which, pattern)
      if ok then auto_print("Added '" .. string.lower(pattern) .. "' to the " .. which .. " list.") end
    elseif sub == "remove" then
      ok, err = AutoMarker_PrioRemove(which, pattern)
      if ok then auto_print("Removed '" .. string.lower(pattern) .. "' from the " .. which .. " list.") end
    elseif sub == "top" then
      ok, err = AutoMarker_PrioTop(which, pattern)
      if ok then auto_print("'" .. string.lower(pattern) .. "' is now first in the " .. which .. " list.") end
    elseif sub == "reset" then
      AutoMarker_PrioReset(which)
      ok = true
      auto_print("The " .. which .. " list was reset to defaults.")
    else
      ok = true
      local list = AutoMarker_PrioList(which)
      auto_print(c(which == "ignore" and "Never mark (name patterns):" or "Mark priority (first = Skull):", color.yellow))
      if table.getn(list) == 0 then
        auto_print("  (empty)")
      else
        for i, v in ipairs(list) do auto_print("  " .. i .. ". " .. v) end
      end
      auto_print("Use /am " .. which .. " add||remove||top <pattern>, /am " .. which .. " reset")
    end
    if not ok then auto_print("AutoMarker: " .. tostring(err) .. ".") end
  elseif command == "autosort" then
    local sub = packName and string.lower(packName)
    if sub ~= "health" and sub ~= "class" then
      auto_print("Current sort: " .. AutoMarkerDB.settings.autoSort .. ". Use /am autosort health||class.")
      return
    end
    AutoMarker_SetSetting("autoSort", sub)
    auto_print("Unmatched mobs are now ordered by " .. sub .. ".")
  elseif command == "autocombat" or command == "autolos" or command == "autotapped" or command == "autoinstance" then
    local keys = { autocombat = "autoRequireCombat", autolos = "autoLos",
      autotapped = "autoSkipTapped", autoinstance = "autoInstanceOnly" }
    local key = keys[command]
    local sub = packName and string.lower(packName)
    local value
    if sub == "on" then value = true elseif sub == "off" then value = false else value = not AutoMarkerDB.settings[key] end
    AutoMarker_SetSetting(key, value)
    auto_print(command .. " [ " .. (AutoMarkerDB.settings[key] and c("on", color.green) or c("off", color.red)) .. " ]")
  elseif command == "learn" then
    local sub = packName and string.lower(packName)
    local value
    if sub == "on" then value = true elseif sub == "off" then value = false else value = not AutoMarkerDB.settings.autoLearn end
    AutoMarker_SetSetting("autoLearn", value)
    auto_print("Learning names from marks you set [ " .. (AutoMarkerDB.settings.autoLearn and c("on", color.green) or c("off", color.red)) .. " ]")
  elseif command == "learned" then
    local sub = packName and string.lower(packName)
    if sub == "remove" then
      local name = table.concat(args, " ", 3)
      local ok, err = AutoMarker_LearnedRemove(name)
      auto_print(ok and ("Forgot '" .. string.lower(name) .. "'.") or ("AutoMarker: " .. tostring(err) .. "."))
    elseif sub == "reset" then
      AutoMarker_LearnedReset()
      auto_print("All learned names were forgotten.")
    else
      local list = AutoMarker_LearnedList()
      auto_print(c("Learned names (from marks people set):", color.yellow))
      if table.getn(list) == 0 then
        auto_print("  (none yet)")
      else
        for _, entry in ipairs(list) do
          auto_print("  " .. entry.name .. " -> " .. raidMarks[entry.mark + 1])
        end
      end
      auto_print("Use /am learned remove <name>, /am learned reset, /am learn on||off")
    end
  elseif command == "record" then
    local sub = packName and string.lower(packName)
    if sub ~= "off" and sub ~= "instance" and sub ~= "always" then
      auto_print("Auto-record is '" .. AutoMarkerDB.settings.autoRecord .. "'. Use /am record off||instance||always.")
      return
    end
    AutoMarker_SetSetting("autoRecord", sub)
    auto_print("Auto-record of marks you set into packs: " .. c(sub, color.green))
  elseif command == "packs" then
    local sub = packName and string.lower(packName)
    if sub == "delete" then
      local name = table.concat(args, " ", 3)
      local ok, err = AutoMarker_DeletePack(name)
      auto_print(ok and ("Deleted pack '" .. name .. "'.") or ("AutoMarker: " .. tostring(err) .. "."))
    else
      local list = AutoMarker_ZonePacks()
      auto_print(c("Recorded packs in " .. GetRealZoneText() .. ":", color.yellow))
      if table.getn(list) == 0 then
        auto_print("  (none)")
      else
        for _, entry in ipairs(list) do
          auto_print("  " .. entry.name .. " (" .. entry.count .. " mobs)")
        end
      end
      auto_print("Use /am packs delete <name>")
    end
  elseif command == "ui" or command == "options" or command == "config" then
    if AutoMarker_ToggleUI then AutoMarker_ToggleUI() end
  else
      auto_print(L["Commands:"])
      auto_print("/am " .. c("e", color.green) .. L["nable - enabled or disable addon."])
      auto_print("/am " .. c("s", color.green) .. L["et <packname> - Set the current pack name."])
      auto_print("/am " .. c("g", color.green) .. L["et - Get the current pack name and information about the targeted mob."])
      auto_print("/am " .. c("c", color.green) .. L["lear - Clear all mobs in the current pack."])
      auto_print("/am " .. c("sweep", color.green) ..L[" [packname] - Toggle sweep mode to add mobs to a specified pack. If no pack name is provided, use the current pack name."])
      auto_print("/am " .. c("a", color.green) ..L["dd [packname] - Add the targeted mob to a specified pack. If no pack name is provided, use the current pack name."])
      auto_print("/am " .. c("r", color.green) .. L["emove - Remove the targeted mob from its current pack."])
      auto_print(L["/am clearmarks - Remove all active marks."])
      auto_print(L["/am next - Mark next pack."])
      auto_print(L["/am mark - Mark pack of current target or mouseover."])
      auto_print(L["/am markname - Mark all units of a given name."])
      auto_print(c("Auto mode (name-based, works on any server):", color.yellow))
      auto_print("/am " .. c("auto", color.green) .. " [on||off||status] - Toggle automatic name-based marking.")
      auto_print("/am " .. c("autoscan", color.green) .. " - Mark nearby hostiles now, even out of combat.")
      auto_print("/am " .. c("radius", color.green) .. " <yd> / " .. c("pullradius", color.green) .. " <yd> - Scan ranges (default 40 / 30).")
      auto_print("/am " .. c("prio", color.green) .. " [add||remove||top||reset] <pattern> - Name priority list (first = Skull).")
      auto_print("/am " .. c("ignore", color.green) .. " [add||remove||reset] <pattern> - Names never marked.")
      auto_print("/am " .. c("autosort", color.green) .. " health||class, " .. c("autocombat", color.green) .. ", " .. c("autolos", color.green) .. ", " .. c("autotapped", color.green) .. ", " .. c("autoinstance", color.green))
      auto_print(c("Learning from marks you set by hand:", color.yellow))
      auto_print("/am " .. c("learn", color.green) .. " [on||off] - Remember which mark each mob name gets.")
      auto_print("/am " .. c("learned", color.green) .. " [remove <name>||reset] - Show or edit learned names.")
      auto_print("/am " .. c("record", color.green) .. " off||instance||always - Save marks you set into packs for this zone.")
      auto_print("/am " .. c("packs", color.green) .. " [delete <name>] - Recorded packs in this zone.")
      auto_print("/am " .. c("ui", color.green) .. " - Open the info panel (also on the minimap button).")

      auto_print(L["/am debug - Toggle debug mode."])
  end
end

SLASH_AUTOMARKER1 = "/automarker";
SLASH_AUTOMARKER2 = "/am";
SlashCmdList["AUTOMARKER"] = handleCommands
