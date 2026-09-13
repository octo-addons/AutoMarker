-- AutoMarker info panel and minimap button (octo-addons fork).
-- 1.12 client, Lua 5.0: no "#", no "%", no string.match.

local panel = nil
local tabs = {}
local pages = {}
local activePage = "status"
local refreshElapsed = 0

local COLOR_TITLE = { 1, 0.82, 0 }
local COLOR_TEXT = { 0.9, 0.9, 0.9 }
local COLOR_DIM = { 0.6, 0.6, 0.6 }

local function Print(message)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffff00AutoMarker:|r " .. tostring(message))
end

local function Ready()
  return AutoMarkerDB and AutoMarkerDB.settings and AutoMarker_GetStatus
end

local function YesNo(v)
  return v and "|cff00ff00yes|r" or "|cffff0000no|r"
end

local function OnOff(v)
  return v and "|cff00ff00on|r" or "|cffff0000off|r"
end

-- ---------------------------------------------------------------------------
-- Widget helpers
-- ---------------------------------------------------------------------------

local widgetSerial = 0
local function NextName(prefix)
  widgetSerial = widgetSerial + 1
  return "AutoMarkerUI" .. prefix .. widgetSerial
end

local function MakeLabel(parent, text, x, y, template, width)
  local fs = parent:CreateFontString(nil, "ARTWORK", template or "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  fs:SetJustifyH("LEFT")
  if width then fs:SetWidth(width) end
  fs:SetText(text or "")
  return fs
end

local function MakeButton(parent, text, width, height, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetWidth(width)
  b:SetHeight(height or 20)
  b:SetText(text)
  b:SetScript("OnClick", onClick)
  return b
end

local function MakeCheck(parent, label, x, y, tooltip, onClick)
  local name = NextName("Check")
  local check = CreateFrame("CheckButton", name, parent, "UICheckButtonTemplate")
  check:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  check:SetWidth(22)
  check:SetHeight(22)
  getglobal(name .. "Text"):SetText(label)
  check.tooltip = tooltip
  check:SetScript("OnClick", onClick)
  check:SetScript("OnEnter", function()
    if this.tooltip then
      GameTooltip:SetOwner(this, "ANCHOR_RIGHT")
      GameTooltip:SetText(this.tooltip, 1, 1, 1, 1, true)
      GameTooltip:Show()
    end
  end)
  check:SetScript("OnLeave", function() GameTooltip:Hide() end)
  return check
end

local function MakeSlider(parent, label, x, y, minV, maxV, step, onChange)
  local name = NextName("Slider")
  local slider = CreateFrame("Slider", name, parent, "OptionsSliderTemplate")
  slider:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  slider:SetWidth(150)
  slider:SetHeight(16)
  slider:SetMinMaxValues(minV, maxV)
  slider:SetValueStep(step)
  getglobal(name .. "Low"):SetText(minV)
  getglobal(name .. "High"):SetText(maxV)
  slider.label = getglobal(name .. "Text")
  slider.labelText = label
  slider.suppress = false
  slider:SetScript("OnValueChanged", function()
    local v = math.floor(this:GetValue() + 0.5)
    this.label:SetText(this.labelText .. ": " .. v)
    if not this.suppress then onChange(v) end
  end)
  return slider
end

local function SetSliderValue(slider, v)
  slider.suppress = true
  slider:SetValue(v)
  slider.suppress = false
  slider.label:SetText(slider.labelText .. ": " .. v)
end

local function MakeEditBox(parent, x, y, width)
  local name = NextName("Edit")
  local edit = CreateFrame("EditBox", name, parent, "InputBoxTemplate")
  edit:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
  edit:SetWidth(width)
  edit:SetHeight(20)
  edit:SetAutoFocus(false)
  edit:SetScript("OnEscapePressed", function() this:ClearFocus() end)
  return edit
end

-- ---------------------------------------------------------------------------
-- Page: status and settings
-- ---------------------------------------------------------------------------

local RefreshAll

local function BuildStatusPage(page)
  page.lines = {}
  local y = -4
  for i = 1, 6 do
    page.lines[i] = MakeLabel(page, "", 8, y, "GameFontHighlightSmall", 330)
    y = y - 14
  end

  y = y - 6
  MakeLabel(page, "Settings", 8, y, "GameFontNormal")
  y = y - 18

  page.checks = {}
  local checks = {
    { key = "enabled", label = "AutoMarker enabled", tip = "Master switch for the whole addon." },
    { key = "auto", label = "Auto mode (name-based marking)", tip = "Mark nearby hostiles by name priority. Works on any server." },
    { key = "autoRequireCombat", label = "In combat: only mobs already fighting", tip = "When on, the combat filler only marks mobs that are in combat. Pull pre-marking ignores this." },
    { key = "autoLos", label = "Require line of sight (UnitXP)", tip = "Skip mobs you cannot see. Needs UnitXP_SP3." },
    { key = "autoSkipTapped", label = "Skip mobs tapped by others", tip = "Do not mark mobs another group is fighting." },
    { key = "autoInstanceOnly", label = "Only inside instances", tip = "Auto mode stays idle in the open world." },
  }
  for _, def in ipairs(checks) do
    local check = MakeCheck(page, def.label, 8, y, def.tip, function()
      AutoMarker_SetSetting(this.key, this:GetChecked() and true or false)
      RefreshAll()
    end)
    check.key = def.key
    page.checks[def.key] = check
    y = y - 22
  end

  y = y - 10
  page.radius = MakeSlider(page, "Combat scan radius (yd)", 20, y, 5, 100, 5, function(v)
    AutoMarker_SetSetting("autoRadius", v)
  end)
  page.pullRadius = MakeSlider(page, "Pull radius (yd)", 190, y, 5, 100, 5, function(v)
    AutoMarker_SetSetting("pullRadius", v)
  end)
  y = y - 34

  MakeLabel(page, "Order unmatched mobs by:", 8, y - 4, "GameFontHighlightSmall")
  page.sortButton = MakeButton(page, "Health", 80, 20, function()
    local current = AutoMarkerDB.settings.autoSort
    AutoMarker_SetSetting("autoSort", current == "health" and "class" or "health")
    RefreshAll()
  end)
  page.sortButton:SetPoint("TOPLEFT", page, "TOPLEFT", 150, y)
  y = y - 26

  local scan = MakeButton(page, "Mark nearby now", 120, 20, function() AutoMarker_AutoScan(true) end)
  scan:SetPoint("TOPLEFT", page, "TOPLEFT", 8, y)
  local clear = MakeButton(page, "Clear marks", 100, 20, function() AutoMarker_ClearMarks() end)
  clear:SetPoint("LEFT", scan, "RIGHT", 6, 0)
end

local function RefreshStatusPage(page)
  local st = AutoMarker_GetStatus()
  if not st then return end
  local s = AutoMarkerDB.settings
  page.lines[1]:SetText("Addon " .. OnOff(st.enabled) .. "   Auto mode " .. OnOff(st.auto)
    .. "   Can mark: " .. YesNo(st.canMark) .. " |cffaaaaaa(" .. st.reason .. ")|r")
  page.lines[2]:SetText("Zone: " .. tostring(st.zone)
    .. (st.zoneHasPacks and " |cff00ff00(pack data)|r" or " |cffaaaaaa(no pack data)|r"))
  page.lines[3]:SetText("Free marks: " .. st.freeMarks .. "   Cached mobs: " .. st.cacheSize
    .. "   In combat: " .. YesNo(st.inCombat))
  page.lines[4]:SetText("SuperWoW " .. YesNo(st.superwow) .. " " .. tostring(st.superwowVersion or "")
    .. "   Nampower " .. YesNo(st.nampower) .. " " .. tostring(st.nampowerVersion or ""))
  page.lines[5]:SetText("UnitXP " .. YesNo(st.unitxp) .. "   ClassicAPI " .. YesNo(st.classicapi)
    .. "   Distance: " .. ((st.unitxp or st.classicapi) and "exact yards" or "~28 yd fallback"))
  page.lines[6]:SetText("|cffaaaaaaThe shipped packs come from another server; auto mode is what marks on OctoWoW.|r")

  for key, check in pairs(page.checks) do
    check:SetChecked(s[key] and 1 or nil)
  end
  SetSliderValue(page.radius, s.autoRadius)
  SetSliderValue(page.pullRadius, s.pullRadius)
  page.sortButton:SetText(s.autoSort == "class" and "Class" or "Health")
end

-- ---------------------------------------------------------------------------
-- Page: priority and ignore lists
-- ---------------------------------------------------------------------------

local LIST_ROWS = 10

local function BuildListPage(page)
  page.which = "prio"
  page.offset = 0

  page.prioTab = MakeButton(page, "Priority", 90, 20, function()
    page.which = "prio"
    page.offset = 0
    RefreshAll()
  end)
  page.prioTab:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -4)
  page.ignoreTab = MakeButton(page, "Never mark", 90, 20, function()
    page.which = "ignore"
    page.offset = 0
    RefreshAll()
  end)
  page.ignoreTab:SetPoint("LEFT", page.prioTab, "RIGHT", 4, 0)

  page.hint = MakeLabel(page, "", 8, -30, "GameFontHighlightSmall", 330)

  page.edit = MakeEditBox(page, 14, -48, 180)
  local function AddPattern()
    local text = page.edit:GetText() or ""
    local ok, err = AutoMarker_PrioAdd(page.which, text)
    if ok then
      page.edit:SetText("")
      page.edit:ClearFocus()
    else
      Print(tostring(err) .. ".")
    end
    RefreshAll()
  end
  page.edit:SetScript("OnEnterPressed", AddPattern)
  local add = MakeButton(page, "Add", 50, 20, AddPattern)
  add:SetPoint("LEFT", page.edit, "RIGHT", 6, 0)
  local reset = MakeButton(page, "Reset", 60, 20, function()
    AutoMarker_PrioReset(page.which)
    RefreshAll()
  end)
  reset:SetPoint("LEFT", add, "RIGHT", 6, 0)

  page.rows = {}
  local y = -76
  for i = 1, LIST_ROWS do
    local row = {}
    row.index = MakeLabel(page, "", 10, y - 3, "GameFontHighlightSmall", 24)
    row.text = MakeLabel(page, "", 36, y - 3, "GameFontHighlightSmall", 200)
    row.top = MakeButton(page, "Top", 40, 18, function()
      if this.pattern then
        AutoMarker_PrioTop(page.which, this.pattern)
        RefreshAll()
      end
    end)
    row.top:SetPoint("TOPLEFT", page, "TOPLEFT", 244, y)
    row.remove = MakeButton(page, "x", 22, 18, function()
      if this.pattern then
        AutoMarker_PrioRemove(page.which, this.pattern)
        RefreshAll()
      end
    end)
    row.remove:SetPoint("LEFT", row.top, "RIGHT", 4, 0)
    page.rows[i] = row
    y = y - 20
  end

  page.up = MakeButton(page, "Up", 40, 18, function()
    page.offset = math.max(0, page.offset - LIST_ROWS)
    RefreshAll()
  end)
  page.up:SetPoint("TOPLEFT", page, "TOPLEFT", 244, y - 4)
  page.down = MakeButton(page, "Down", 46, 18, function()
    page.offset = page.offset + LIST_ROWS
    RefreshAll()
  end)
  page.down:SetPoint("LEFT", page.up, "RIGHT", 4, 0)
  page.pageLabel = MakeLabel(page, "", 10, y - 7, "GameFontHighlightSmall", 200)
end

local function RefreshListPage(page)
  local list = AutoMarker_PrioList(page.which) or {}
  local count = table.getn(list)
  if page.offset >= count then page.offset = math.max(0, count - LIST_ROWS) end
  if page.which == "prio" then
    page.hint:SetText("First match gets Skull, the next Cross, and so on down the list.")
  else
    page.hint:SetText("Mobs matching any of these patterns are never marked.")
  end
  for i = 1, LIST_ROWS do
    local row = page.rows[i]
    local idx = page.offset + i
    local pattern = list[idx]
    row.top.pattern = pattern
    row.remove.pattern = pattern
    if pattern then
      row.index:SetText(idx .. ".")
      row.text:SetText(pattern)
      row.top:Show()
      row.remove:Show()
      if page.which == "ignore" or idx == 1 then row.top:Hide() end
    else
      row.index:SetText("")
      row.text:SetText("")
      row.top:Hide()
      row.remove:Hide()
    end
  end
  local first = count > 0 and (page.offset + 1) or 0
  local last = math.min(count, page.offset + LIST_ROWS)
  page.pageLabel:SetText(first .. "-" .. last .. " of " .. count)
  if page.offset > 0 then page.up:Show() else page.up:Hide() end
  if page.offset + LIST_ROWS < count then page.down:Show() else page.down:Hide() end
end

-- ---------------------------------------------------------------------------
-- Page: learned names and recorded packs
-- ---------------------------------------------------------------------------

local LEARNED_ROWS = 8
local PACK_ROWS = 5
local markNames = { "Unmarked", "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }
local recordLabels = { off = "Off", instance = "In instances", always = "Everywhere" }
local recordOrder = { off = "instance", instance = "always", always = "off" }

local function BuildLearnedPage(page)
  page.learnedOffset = 0

  MakeLabel(page, "Marks you set by hand are remembered two ways:", 8, -4, "GameFontHighlightSmall", 330)

  page.learnCheck = MakeCheck(page, "Learn name -> mark (used by auto mode everywhere)", 8, -18,
    "When you put a mark on a mob by hand, auto mode gives that mark to mobs with the same name from then on.",
    function()
      AutoMarker_SetSetting("autoLearn", this:GetChecked() and true or false)
      RefreshAll()
    end)

  MakeLabel(page, "Record marks into packs for this zone:", 12, -46, "GameFontHighlightSmall")
  page.recordButton = MakeButton(page, "In instances", 100, 20, function()
    local current = AutoMarkerDB.settings.autoRecord or "instance"
    AutoMarker_SetSetting("autoRecord", recordOrder[current] or "instance")
    RefreshAll()
  end)
  page.recordButton:SetPoint("TOPLEFT", page, "TOPLEFT", 220, -42)

  MakeLabel(page, "Learned names", 8, -70, "GameFontNormal")
  page.learnedRows = {}
  local y = -86
  for i = 1, LEARNED_ROWS do
    local row = {}
    row.text = MakeLabel(page, "", 12, y - 3, "GameFontHighlightSmall", 250)
    row.remove = MakeButton(page, "x", 22, 18, function()
      if this.name then
        AutoMarker_LearnedRemove(this.name)
        RefreshAll()
      end
    end)
    row.remove:SetPoint("TOPLEFT", page, "TOPLEFT", 296, y)
    page.learnedRows[i] = row
    y = y - 18
  end
  page.learnedUp = MakeButton(page, "Up", 40, 18, function()
    page.learnedOffset = math.max(0, page.learnedOffset - LEARNED_ROWS)
    RefreshAll()
  end)
  page.learnedUp:SetPoint("TOPLEFT", page, "TOPLEFT", 200, y - 2)
  page.learnedDown = MakeButton(page, "Down", 46, 18, function()
    page.learnedOffset = page.learnedOffset + LEARNED_ROWS
    RefreshAll()
  end)
  page.learnedDown:SetPoint("LEFT", page.learnedUp, "RIGHT", 4, 0)
  page.learnedReset = MakeButton(page, "Forget all", 70, 18, function()
    AutoMarker_LearnedReset()
    RefreshAll()
  end)
  page.learnedReset:SetPoint("TOPLEFT", page, "TOPLEFT", 12, y - 2)
  page.learnedCount = MakeLabel(page, "", 90, y - 6, "GameFontHighlightSmall", 100)
  y = y - 26

  page.packTitle = MakeLabel(page, "Recorded packs in this zone", 8, y, "GameFontNormal", 330)
  y = y - 16
  page.packRows = {}
  for i = 1, PACK_ROWS do
    local row = {}
    row.text = MakeLabel(page, "", 12, y - 3, "GameFontHighlightSmall", 230)
    row.delete = MakeButton(page, "Delete", 56, 18, function()
      if this.name then
        AutoMarker_DeletePack(this.name)
        RefreshAll()
      end
    end)
    row.delete:SetPoint("TOPLEFT", page, "TOPLEFT", 262, y)
    page.packRows[i] = row
    y = y - 18
  end
  page.packHint = MakeLabel(page, "Shift+Ctrl mouseover any mob of a recorded pack to mark the whole pack again.",
    12, y - 2, "GameFontHighlightSmall", 320)
end

local function RefreshLearnedPage(page)
  local s = AutoMarkerDB.settings
  page.learnCheck:SetChecked(s.autoLearn and 1 or nil)
  page.recordButton:SetText(recordLabels[s.autoRecord or "instance"] or "In instances")

  local list = AutoMarker_LearnedList()
  local count = table.getn(list)
  if page.learnedOffset >= count then page.learnedOffset = math.max(0, count - LEARNED_ROWS) end
  for i = 1, LEARNED_ROWS do
    local row = page.learnedRows[i]
    local entry = list[page.learnedOffset + i]
    row.remove.name = entry and entry.name or nil
    if entry then
      row.text:SetText(entry.name .. "  |cffaaaaaa->|r  " .. (markNames[entry.mark + 1] or entry.mark))
      row.remove:Show()
    else
      row.text:SetText(i == 1 and "|cffaaaaaa(nothing learned yet)|r" or "")
      row.remove:Hide()
    end
  end
  page.learnedCount:SetText(count .. " learned")
  if page.learnedOffset > 0 then page.learnedUp:Show() else page.learnedUp:Hide() end
  if page.learnedOffset + LEARNED_ROWS < count then page.learnedDown:Show() else page.learnedDown:Hide() end

  local packs = AutoMarker_ZonePacks()
  page.packTitle:SetText("Recorded packs in " .. tostring(GetRealZoneText()))
  for i = 1, PACK_ROWS do
    local row = page.packRows[i]
    local entry = packs[i]
    row.delete.name = entry and entry.name or nil
    if entry then
      row.text:SetText(entry.name .. "  |cffaaaaaa(" .. entry.count .. " mobs)|r")
      row.delete:Show()
    else
      row.text:SetText(i == 1 and "|cffaaaaaa(none recorded here)|r" or "")
      row.delete:Hide()
    end
  end
  if table.getn(packs) > PACK_ROWS then
    page.packHint:SetText("Showing " .. PACK_ROWS .. " of " .. table.getn(packs) .. " packs. Use /am packs for the full list.")
  else
    page.packHint:SetText("Shift+Ctrl mouseover any mob of a recorded pack to mark the whole pack again.")
  end
end

-- ---------------------------------------------------------------------------
-- Page: macros and keys
-- ---------------------------------------------------------------------------

local macroDefs = {
  { name = "AM Mark",  body = "/am mark",      desc = "Mark the pack of your target or mouseover (auto mode if no pack)" },
  { name = "AM Next",  body = "/am next",      desc = "Mark the next pack in the zone's default order" },
  { name = "AM Clear", body = "/am clearmarks", desc = "Remove all raid marks" },
  { name = "AM Scan",  body = "/am autoscan",  desc = "Auto-mark nearby hostiles now" },
  { name = "AM Auto",  body = "/am auto",      desc = "Toggle auto mode on/off" },
  { name = "AM Panel", body = "/am ui",        desc = "Open this panel" },
}

local bindingDefs = {
  { key = "RUNKEY", label = "Mark mouseover/target" },
  { key = "NEXTKEY", label = "Mark next pack" },
  { key = "CLEARKEY", label = "Clear all marks" },
  { key = "AUTOSCANKEY", label = "Auto-mark nearby now" },
}

local MACRO_ICON = 1

local function FindMacroIndex(name)
  local numGlobal, numPerChar = GetNumMacros()
  numGlobal = numGlobal or 0
  numPerChar = numPerChar or 0
  for i = 1, numGlobal do
    local macroName = GetMacroInfo(i)
    if macroName == name then return i end
  end
  for i = 19, 18 + numPerChar do
    local macroName = GetMacroInfo(i)
    if macroName == name then return i end
  end
  return nil
end

local function CreateOrUpdateMacro(def)
  if MacroFrame and MacroFrame:IsVisible() then
    Print("Close the macro window first, then press Create again.")
    return
  end
  local index = FindMacroIndex(def.name)
  if index then
    EditMacro(index, def.name, MACRO_ICON, def.body, 1)
    Print("Updated macro '" .. def.name .. "'. Drag it from the macro window to an action bar.")
    return
  end
  local numGlobal, numPerChar = GetNumMacros()
  if (numPerChar or 0) >= 18 then
    Print("This character already has 18 macros. Delete one, or copy the text and paste it into an existing macro.")
    return
  end
  CreateMacro(def.name, MACRO_ICON, def.body, 1)
  Print("Created macro '" .. def.name .. "'. Open the macro window (/macro) and drag it to an action bar.")
end

local function BuildMacroPage(page)
  MakeLabel(page, "Click a text box and press Ctrl+C to copy, or press Create to add it to this character's macros.",
    8, -4, "GameFontHighlightSmall", 330)

  local y = -34
  page.macroBoxes = {}
  for _, def in ipairs(macroDefs) do
    local box = MakeEditBox(page, 14, y, 120)
    box:SetText(def.body)
    box.body = def.body
    box:SetScript("OnEditFocusGained", function() this:HighlightText() end)
    box:SetScript("OnTextChanged", function()
      if this:GetText() ~= this.body then this:SetText(this.body) end
    end)
    local create = MakeButton(page, "Create", 56, 20, function() CreateOrUpdateMacro(this.def) end)
    create.def = def
    create:SetPoint("LEFT", box, "RIGHT", 6, 0)
    local desc = MakeLabel(page, def.desc, 206, y - 4, "GameFontHighlightSmall", 140)
    desc:SetJustifyV("TOP")
    y = y - 26
  end

  y = y - 8
  MakeLabel(page, "Key bindings", 8, y, "GameFontNormal")
  y = y - 18
  page.bindingLabels = {}
  for i, def in ipairs(bindingDefs) do
    page.bindingLabels[i] = MakeLabel(page, "", 12, y, "GameFontHighlightSmall", 330)
    y = y - 14
  end
  y = y - 4
  local bind = MakeButton(page, "Open key bindings", 130, 20, function()
    if KeyBindingFrame_LoadUI then KeyBindingFrame_LoadUI() end
    if KeyBindingFrame then ShowUIPanel(KeyBindingFrame) end
  end)
  bind:SetPoint("TOPLEFT", page, "TOPLEFT", 8, y)
  MakeLabel(page, "Look under the AutoMark header.", 146, y - 4, "GameFontHighlightSmall", 180)
end

local function RefreshMacroPage(page)
  for i, def in ipairs(bindingDefs) do
    local key1, key2 = GetBindingKey(def.key)
    local keys = key1 and (key2 and (key1 .. ", " .. key2) or key1) or "|cffaaaaaanot bound|r"
    page.bindingLabels[i]:SetText(def.label .. ": " .. keys)
  end
end

-- ---------------------------------------------------------------------------
-- Page: help
-- ---------------------------------------------------------------------------

-- "||" renders as a single "|"; a bare "|" starts an escape code.
local helpLines = {
  "|cffffff00Marking|r",
  "Shift+Ctrl (or Alt) + mouseover: mark the mob's pack, or auto-mark around it.",
  "/am mark - same for your target or mouseover.",
  "/am next - mark the next pack in this zone's default order.",
  "/am clearmarks - remove all marks.",
  "/am markname <name> - mark every nearby mob with that name.",
  " ",
  "|cffffff00Auto mode|r",
  "/am auto [on||off||status]  -  /am autoscan",
  "/am radius <yd>  -  /am pullradius <yd>  -  /am autosort health||class",
  "/am prio add||remove||top||reset <pattern>",
  "/am ignore add||remove||reset <pattern>",
  "/am autocombat, /am autolos, /am autotapped, /am autoinstance",
  " ",
  "|cffffff00Learning from your own marks|r",
  "Marks you set by hand are learned by name (/am learn) and, inside",
  "instances, recorded into packs for that zone (/am record).",
  "See the Learned tab.",
  " ",
  "|cffffff00Own packs, by hand|r",
  "/am set <pack>, then target a mob and /am add, or /am sweep and",
  "mouse over mobs. /am get shows the pack of your target.",
  " ",
  "|cffffff00Notes|r",
  "Only a leader or assistant places marks others can see.",
  "Solo, marks are local. The shipped packs come from another",
  "server and do nothing on OctoWoW.",
}

local function BuildHelpPage(page)
  -- Chain each line under the previous one so wrapped lines never overlap.
  local previous = nil
  for _, line in ipairs(helpLines) do
    local fs = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    fs:SetWidth(330)
    fs:SetText(line)
    if previous then
      fs:SetPoint("TOPLEFT", previous, "BOTTOMLEFT", 0, -2)
    else
      fs:SetPoint("TOPLEFT", page, "TOPLEFT", 8, -4)
    end
    previous = fs
  end
end

-- ---------------------------------------------------------------------------
-- Panel
-- ---------------------------------------------------------------------------

local function ShowPage(key)
  activePage = key
  for name, page in pairs(pages) do
    if name == key then page:Show() else page:Hide() end
  end
  for name, tab in pairs(tabs) do
    if name == key then tab:Disable() else tab:Enable() end
  end
  RefreshAll()
end

local function CreatePanel()
  if panel then return end
  panel = CreateFrame("Frame", "AutoMarkerPanel", UIParent)
  panel:SetWidth(360)
  panel:SetHeight(480)
  panel:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
  panel:SetFrameStrata("DIALOG")
  panel:SetMovable(true)
  panel:EnableMouse(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function() this:StartMoving() end)
  panel:SetScript("OnDragStop", function() this:StopMovingOrSizing() end)
  panel:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
    tile = true, tileSize = 32, edgeSize = 32,
    insets = { left = 11, right = 12, top = 12, bottom = 11 },
  })
  panel:Hide()
  tinsert(UISpecialFrames, "AutoMarkerPanel")

  local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOP", panel, "TOP", 0, -16)
  title:SetText("AutoMarker")

  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -6, -6)

  local tabDefs = {
    { key = "status", label = "Status", width = 62 },
    { key = "lists", label = "Priority", width = 62 },
    { key = "learned", label = "Learned", width = 66 },
    { key = "macros", label = "Macros", width = 62 },
    { key = "help", label = "Help", width = 52 },
  }
  local x = 14
  for _, def in ipairs(tabDefs) do
    local tab = MakeButton(panel, def.label, def.width, 20, function()
      ShowPage(this.key)
    end)
    tab.key = def.key
    tab:SetPoint("TOPLEFT", panel, "TOPLEFT", x, -40)
    tabs[def.key] = tab
    x = x + tab:GetWidth() + 4
  end

  for _, def in ipairs(tabDefs) do
    local page = CreateFrame("Frame", nil, panel)
    page:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -66)
    page:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -8, 12)
    page:Hide()
    pages[def.key] = page
  end

  BuildStatusPage(pages.status)
  BuildListPage(pages.lists)
  BuildLearnedPage(pages.learned)
  BuildMacroPage(pages.macros)
  BuildHelpPage(pages.help)

  panel:SetScript("OnUpdate", function()
    refreshElapsed = refreshElapsed + arg1
    if refreshElapsed > 0.5 then
      refreshElapsed = 0
      if activePage == "status" then RefreshStatusPage(pages.status) end
    end
  end)
end

RefreshAll = function()
  if not panel or not panel:IsVisible() or not Ready() then return end
  RefreshStatusPage(pages.status)
  RefreshListPage(pages.lists)
  RefreshLearnedPage(pages.learned)
  RefreshMacroPage(pages.macros)
  if AutoMarker_UpdateMinimapIcon then AutoMarker_UpdateMinimapIcon() end
end

function AutoMarker_ToggleUI()
  if not Ready() then
    Print("not loaded yet.")
    return
  end
  CreatePanel()
  if panel:IsVisible() then
    panel:Hide()
  else
    panel:Show()
    ShowPage(activePage)
  end
end

-- ---------------------------------------------------------------------------
-- Minimap button
-- ---------------------------------------------------------------------------

local button = CreateFrame("Button", "AutoMarkerMinimapButton", Minimap)
button:SetWidth(31)
button:SetHeight(31)
button:SetFrameStrata("MEDIUM")
button:SetFrameLevel(8)
button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
button:RegisterForDrag("LeftButton")

local overlay = button:CreateTexture(nil, "OVERLAY")
overlay:SetWidth(53)
overlay:SetHeight(53)
overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
overlay:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)

local icon = button:CreateTexture(nil, "BACKGROUND")
icon:SetWidth(18)
icon:SetHeight(18)
-- 1.12 keeps all eight raid icons in one 4x4 texture; use the skull cell.
icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcons")
icon:SetTexCoord(0.75, 1, 0.25, 0.5)
icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -5)

function AutoMarker_UpdateMinimapIcon()
  if AutoMarkerDB and AutoMarkerDB.settings and AutoMarkerDB.settings.enabled
    and AutoMarkerDB.settings.auto then
    icon:SetVertexColor(1, 1, 1)
  else
    icon:SetVertexColor(0.4, 0.4, 0.4)
  end
end

local function PositionButton()
  local angle = math.rad((AutoMarkerDB and AutoMarkerDB.minimapAngle) or 160)
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * 80, math.sin(angle) * 80)
end

local function DragUpdate()
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  cx = cx / scale
  cy = cy / scale
  AutoMarkerDB.minimapAngle = math.deg(math.atan2(cy - my, cx - mx))
  PositionButton()
end

button:SetScript("OnDragStart", function() this:SetScript("OnUpdate", DragUpdate) end)
button:SetScript("OnDragStop", function() this:SetScript("OnUpdate", nil) end)
button:SetScript("OnClick", function()
  if not Ready() then return end
  if arg1 == "RightButton" then
    AutoMarker_SetSetting("auto", not AutoMarkerDB.settings.auto)
    Print("auto mode " .. (AutoMarkerDB.settings.auto and "on." or "off."))
    AutoMarker_UpdateMinimapIcon()
    RefreshAll()
  else
    AutoMarker_ToggleUI()
  end
end)
button:SetScript("OnEnter", function()
  GameTooltip:SetOwner(this, "ANCHOR_LEFT")
  GameTooltip:SetText("AutoMarker")
  if Ready() then
    local st = AutoMarker_GetStatus()
    GameTooltip:AddLine("Auto mode: " .. (st.auto and "on" or "off"), 1, 1, 1)
    GameTooltip:AddLine("Can mark: " .. (st.canMark and "yes" or "no") .. " (" .. st.reason .. ")", 1, 1, 1)
  end
  GameTooltip:AddLine("Left-click: info panel", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Right-click: toggle auto mode", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Drag: move button", 0.8, 0.8, 0.8)
  GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

local setup = CreateFrame("Frame")
setup:RegisterEvent("PLAYER_LOGIN")
setup:SetScript("OnEvent", function()
  if type(AutoMarkerDB) ~= "table" then AutoMarkerDB = {} end
  PositionButton()
  AutoMarker_UpdateMinimapIcon()
end)
