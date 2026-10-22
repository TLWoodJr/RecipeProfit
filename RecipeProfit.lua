-- RecipeProfit: reagent cost / crafted price / profit on recipe tooltips.
--
-- Prices come through LibCraftProfit-1.0 (shared with ProfessionProfit):
-- Auctionator's vendor and AH prices first, gaps filled by the Scan button's
-- searches, and reagents walked through their full listings when scanned.

local ADDON = ...
local Lib = LibStub("LibCraftProfit-1.0")
local money = Lib.Money

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
local RequestLoadItemDataByID = (C_Item and C_Item.RequestLoadItemDataByID) or function() end
local RECIPE_CLASS = (Enum and Enum.ItemClass and Enum.ItemClass.Recipe) or 9

local db
local debugLines = false

local function msg(text)
  DEFAULT_CHAT_FRAME:AddMessage("|cffffd100RecipeProfit:|r " .. text)
end

local function clean(text)
  if type(text) ~= "string" then return nil end
  text = text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("\194\160", " ")
  return (text:match("^%s*(.-)%s*$"))
end

local function key(name)
  return clean(name):lower()
end

------------------------------------------------------------------------------
-- Item names <-> IDs
------------------------------------------------------------------------------

local pendingNames = {}

local function isRecipe(itemID)
  if not itemID or not GetItemInfoInstant then return false end
  local classID = select(6, GetItemInfoInstant(itemID))
  return classID == RECIPE_CLASS
end

-- The AH can report a recipe under its crafted item's name ("Rugged Leather
-- Pants" for "Pattern: Rugged Leather Pants"). Never map a prefix-less name
-- to a recipe, or the product would be priced as the pattern.
local function badMapping(itemID, name)
  return isRecipe(itemID) and not name:find(":", 1, true)
end

local function rememberName(itemID, name)
  if itemID and name and name ~= "" and not badMapping(itemID, name) then
    db.names[key(name)] = itemID
    pendingNames[itemID] = nil
    return true
  end
end

local function learnName(itemID)
  local name = GetItemInfo(itemID)
  if not rememberName(itemID, name) then
    pendingNames[itemID] = true
    RequestLoadItemDataByID(itemID)
  end
end

local function idForName(name)
  if not name or name == "" then return nil end
  local id = db.names[key(name)]
  if id and badMapping(id, name) then db.names[key(name)] = nil; id = nil end
  if id then return id end
  id = GetItemInfoInstant and GetItemInfoInstant(name)
  if type(id) ~= "number" then
    local _, link = GetItemInfo(name)
    id = link and tonumber(link:match("item:(%d+)"))
  end
  if id and badMapping(id, name) then return nil end
  if id then rememberName(id, name) end
  return id
end

------------------------------------------------------------------------------
-- Recipe tooltip parsing
------------------------------------------------------------------------------

local REQUIRES = ((ITEM_REQ_SKILL or "Requires %s"):match("^(.-)%%s")) or "Requires "
local REQ_LEVEL = ((ITEM_MIN_LEVEL or "Requires Level %d"):match("^(.-)%%d")) or "Requires Level "
local USE = ITEM_SPELL_TRIGGER_ONUSE or "Use:"
local SELL_PRICE = SELL_PRICE or "Sell Price"
local PROFESSIONS = {}
for _, name in ipairs({ "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Herbalism",
  "Leatherworking", "Mining", "Skinning", "Tailoring", "Cooking", "First Aid", "Fishing",
  "Jewelcrafting", "Inscription", "Lockpicking", "Poisons", "Armorsmith", "Weaponsmith",
  "Master Axesmith", "Master Hammersmith", "Master Swordsmith", "Gnomish Engineer",
  "Goblin Engineer", "Dragonscale Leatherworking", "Elemental Leatherworking",
  "Tribal Leatherworking", "Mooncloth Tailoring", "Shadoweave Tailoring", "Spellfire Tailoring" }) do
  PROFESSIONS[name:lower()] = true
end
local RECIPE_PREFIXES = { "Recipe", "Pattern", "Plans", "Schematic", "Formula", "Manual", "Design", "Technique" }

local function startsWith(text, prefix)
  return text:sub(1, #prefix) == prefix
end

local function stripPrefix(recipeName)
  for _, prefix in ipairs(RECIPE_PREFIXES) do
    local rest = recipeName:match("^" .. prefix .. ":%s*(.+)$")
    if rest then return rest end
  end
  return recipeName:match("^[^:]+:%s*(.+)$")
end

-- "Linen Cloth (2), Coarse Thread" -> { {name="Linen Cloth", count=2}, {name="Coarse Thread", count=1} }
local function parseReagents(text)
  local list = {}
  for part in (text .. ","):gmatch("%s*(.-)%s*,") do
    if part ~= "" then
      local name, count = part:match("^(.-)%s*%((%d+)%)$")
      list[#list + 1] = { name = name or part, count = tonumber(count) or 1 }
    end
  end
  return list
end

-- lines: array of plain strings (first = recipe name)
local function parseRecipe(lines)
  local recipeName = lines[1]
  if not recipeName then return nil end

  -- The crafted item can have its own "Use:" line (e.g. Heavy Leather Ball),
  -- so the recipe's "Use: Teaches ..." line is the last Use: line in the
  -- Forever layout, but may be the first in the classic layout.
  local firstUse, lastUse
  for i = 2, #lines do
    if startsWith(lines[i], USE) then
      firstUse = firstUse or i
      lastUse = i
    end
  end
  if not firstUse then return nil end

  local function isSkillLine(line)
    if not startsWith(line, REQUIRES) then return false end
    local what = line:sub(#REQUIRES + 1)
    what = what:match("^(.-)%s*%(%d+%)$") or what
    return PROFESSIONS[what:lower()] ~= nil
  end
  local function isReagentText(line)
    return line ~= "" and not startsWith(line, USE) and not startsWith(line, REQUIRES)
      and not startsWith(line, SELL_PRICE)
  end

  -- WoW Forever layout: after the last Use: line comes
  -- "Light Leather (5), Coarse Thread (5)" then "Requires Leatherworking (30)".
  local reagentLine, useIndex
  for i = lastUse + 1, #lines do
    if isSkillLine(lines[i]) then
      for j = i - 1, lastUse + 1, -1 do
        if lines[j] ~= "" then
          if isReagentText(lines[j]) then reagentLine, useIndex = lines[j], lastUse end
          break
        end
      end
      break
    end
  end

  -- Classic layout: the last "Requires X (n), Y" line after the first Use:
  -- that isn't a level / reputation / profession-skill requirement.
  if not reagentLine then
    for i = #lines, firstUse + 1, -1 do
      local line = lines[i]
      if startsWith(line, REQUIRES) and not startsWith(line, REQ_LEVEL) and not line:find(" %- ")
          and not isSkillLine(line) then
        reagentLine, useIndex = line:sub(#REQUIRES + 1), firstUse
        break
      end
    end
  end

  -- Last resort: first plain line after the last Use: line.
  if not reagentLine then
    for i = lastUse + 1, #lines do
      if lines[i] ~= "" then
        if isReagentText(lines[i]) then reagentLine, useIndex = lines[i], lastUse end
        break
      end
    end
  end
  if not reagentLine then return nil end

  -- Product candidates: recipe name without its "Pattern:" prefix, the line
  -- under the recipe name (Forever shows the crafted item there), and the
  -- first line after Use: (classic embedded item).
  local afterUse
  for i = useIndex + 1, #lines do
    if lines[i] ~= "" then
      if lines[i] ~= reagentLine and not startsWith(lines[i], REQUIRES) then afterUse = lines[i] end
      break
    end
  end
  local stripped = stripPrefix(recipeName)

  return {
    name = recipeName,
    candidates = { stripped, lines[2] ~= "" and lines[2] or nil, afterUse },
    productName = stripped or afterUse,
    reagents = parseReagents(reagentLine),
    incomplete = reagentLine:find(RETRIEVING_ITEM_INFO or "Retrieving item information", 1, true) ~= nil,
  }
end

local function resolveProduct(recipe)
  for _, candidate in ipairs(recipe.candidates) do
    local id = candidate and idForName(candidate)
    if id and not isRecipe(id) then return id, candidate end
  end
end

local function linesFromData(data)
  if not data or not data.lines then return nil end
  local out = {}
  for i, line in ipairs(data.lines) do
    if line.leftText == nil and line.args and TooltipUtil and TooltipUtil.SurfaceArgs then
      TooltipUtil.SurfaceArgs(line)
    end
    out[i] = clean(line.leftText) or ""
  end
  return out
end

local function linesFromFrame(tooltip)
  local name = tooltip:GetName()
  if not name then return nil end
  local out = {}
  for i = 1, tooltip:NumLines() do
    local fs = _G[name .. "TextLeft" .. i]
    out[i] = clean(fs and fs:GetText()) or ""
  end
  return out
end

local scanTip
local function linesForItemID(itemID)
  if C_TooltipInfo and C_TooltipInfo.GetItemByID then
    return linesFromData(C_TooltipInfo.GetItemByID(itemID))
  end
  scanTip = scanTip or CreateFrame("GameTooltip", "RecipeProfitScanTip", nil, "GameTooltipTemplate")
  scanTip:SetOwner(WorldFrame, "ANCHOR_NONE")
  scanTip:SetHyperlink("item:" .. itemID)
  return linesFromFrame(scanTip)
end

------------------------------------------------------------------------------
-- Tooltip output
------------------------------------------------------------------------------

local GREY, WHITE = { 0.65, 0.65, 0.65 }, { 1, 1, 1 }

local RED, DIM = "|cffff6666", "|cffa0a0a0"

local scan -- a scan in progress (below): { loadTries, force, phase, done, total }

-- Our own search answered for the item today (even "none listed").
local function checkedToday(itemID)
  local book = Lib.Book(itemID)
  return book and date("%Y%m%d", book.t) == date("%Y%m%d")
end

-- An item with no price anywhere (vendor, Auctionator, our searches) that
-- a scan hasn't already looked for today. Items nobody lists stay
-- unpriced, so a scan today settles them.
local function priceMissing(itemID)
  return itemID ~= nil and not (Lib.VendorPrice(itemID) or Lib.SellPrice(itemID)) and not checkedToday(itemID)
end

local function needsPricing(recipe)
  for _, reagent in ipairs(recipe.reagents) do
    if priceMissing(reagent.id) then return true end
  end
  return priceMissing(recipe.productID)
end

local function addRecipeInfo(tooltip, parsed)
  tooltip:AddLine(" ")
  tooltip:AddLine("Recipe Profit", 1, 0.82, 0)

  local productID, productName = resolveProduct(parsed)
  local recipe = { made = 1, productID = productID, reagents = {} }
  for _, reagent in ipairs(parsed.reagents) do
    recipe.reagents[#recipe.reagents + 1] = { id = idForName(reagent.name), name = reagent.name, count = reagent.count }
  end
  Lib.Evaluate(recipe)

  for _, reagent in ipairs(recipe.reagents) do
    local left = "  " .. reagent.count .. "x " .. reagent.name
    if reagent.price then
      local right = money(reagent.price * reagent.count)
      if reagent.count > 1 then right = right .. " " .. DIM .. "(" .. money(reagent.price) .. " ea)|r" end
      if reagent.src == "vendor" then right = right .. " " .. DIM .. "vendor|r" end
      if reagent.stale then right = right .. " " .. RED .. Lib.StaleText(reagent.stale) .. "|r" end
      if reagent.undercut then right = right .. " |cffff9933!|r" end
      tooltip:AddDoubleLine(left, right, 0.85, 0.85, 0.85, 1, 1, 1)
      if reagent.undercut then
        local u = reagent.undercut
        tooltip:AddLine(("    |cffff9933! undercut: %d listed from %s, most at %s|r"):format(u.below, money(u.cheapest), money(u.market)))
      end
    else
      tooltip:AddDoubleLine(left, "no price", 0.85, 0.85, 0.85, 1, 0.4, 0.4)
    end
  end

  local costText = money(recipe.cost)
  if recipe.missing > 0 then costText = costText .. " " .. RED .. "+" .. recipe.missing .. " unpriced|r" end
  tooltip:AddDoubleLine("Reagent cost", costText, 1, 1, 1, 1, 1, 1)

  if not productID and (parsed.productName or ""):match("^Enchant ") then
    tooltip:AddDoubleLine("Crafts", "enchant (not sold on AH)", 1, 1, 1, unpack(GREY))
  elseif not productID then
    tooltip:AddDoubleLine("Crafts", (parsed.productName or "?") .. " (unknown item)", 1, 1, 1, unpack(GREY))
  elseif not recipe.sell then
    tooltip:AddDoubleLine("Sells for (" .. productName .. ")", "no AH price", 1, 1, 1, 1, 0.4, 0.4)
  else
    local sellText = money(recipe.sell)
    if recipe.productStale then sellText = sellText .. " " .. RED .. Lib.StaleText(recipe.productStale) .. "|r" end
    tooltip:AddDoubleLine("Sells for", sellText, 1, 1, 1, unpack(WHITE))
    tooltip:AddDoubleLine("After " .. math.floor(Lib.AH_CUT * 100 + 0.5) .. "% AH cut", money(recipe.sell * (1 - Lib.AH_CUT)),
      0.85, 0.85, 0.85, unpack(WHITE))
    local r, g = recipe.profit >= 0 and 0.2 or 1, recipe.profit >= 0 and 1 or 0.3
    local label = recipe.missing > 0 and "Profit (incomplete)" or recipe.incomplete and "Profit (old prices)" or "Profit"
    tooltip:AddDoubleLine(label, money(recipe.displayProfit), 1, 1, 1, r, g, 0.2)
  end
  if scan then
    tooltip:AddLine("Scanning prices...", 0.6, 0.6, 0.6, true)
  elseif needsPricing(recipe) then
    tooltip:AddLine("Some prices are missing: search for this recipe at the AH and click Scan.", 0.6, 0.6, 0.6, true)
  end
end

------------------------------------------------------------------------------
-- Recipe sources
--   * ForeverDungeonJournal (if installed): dungeon boss / rare / trash drops
--     and quest rewards.
--   * Learned while playing: vendors you open, mobs you loot, quest rewards
--     you're offered. Saved account-wide in RecipeProfitDB.sources.
------------------------------------------------------------------------------

local journalIndex -- itemID -> list of "Drop: ..." / "Quest: ..." strings

local function buildJournalIndex()
  local fdj = _G.ForeverDungeonJournal_NS
  if not (fdj and type(fdj.DB) == "table") then return end -- not loaded (yet)
  journalIndex = {}
  local function add(itemID, text)
    if not itemID then return end
    journalIndex[itemID] = journalIndex[itemID] or {}
    table.insert(journalIndex[itemID], text)
  end
  for dungeon, data in pairs(fdj.DB) do
    if type(data) == "table" then
      for _, boss in ipairs(data.bosses or {}) do
        local kind = boss.trash and "Trash drop" or boss.rare and "Rare drop" or "Boss drop"
        local who = boss.trash and dungeon or ((boss.name or "?") .. ", " .. dungeon)
        for _, item in ipairs(boss.loot or {}) do
          local extra = boss.trash and item[5] and (" (" .. item[5] .. ")") or ""
          add(item[1], ("%s: %s%s"):format(kind, who, extra))
        end
      end
      for _, quest in ipairs(data.quests or {}) do
        for _, item in ipairs(quest.rewardItems or {}) do
          local where = quest.pickup and (" - " .. quest.pickup) or ""
          add(item[1], ("Quest: %s (lvl %s, %s)%s"):format(quest.name or "?", tostring(quest.level or "?"),
            quest.faction or "Both", where))
        end
      end
    end
  end
end

local function sourceDB(itemID)
  db.sources = db.sources or {}
  db.sources[itemID] = db.sources[itemID] or {}
  return db.sources[itemID]
end

local function zoneText()
  local zone = GetRealZoneText and GetRealZoneText() or GetZoneText()
  local sub = GetSubZoneText and GetSubZoneText() or ""
  if sub ~= "" and sub ~= zone then return sub .. ", " .. zone end
  return zone or "?"
end

local function recordVendorRecipes()
  local npc = UnitName("npc")
  if not npc or not GetMerchantNumItems then return end
  local getInfo = GetMerchantItemInfo or function(i)
    local info = C_MerchantFrame.GetItemInfo(i)
    if info then return info.name, info.texture, info.price, info.stackCount, info.numAvailable end
  end
  local where = zoneText()
  for i = 1, GetMerchantNumItems() do
    local itemID = GetMerchantItemID and GetMerchantItemID(i)
    if itemID and isRecipe(itemID) then
      local _, _, price, _, numAvailable = getInfo(i)
      local src = sourceDB(itemID)
      src.vendors = src.vendors or {}
      src.vendors[npc] = { zone = where, price = price, limited = numAvailable and numAvailable >= 0, t = time() }
    end
  end
end

local function recordLootRecipes()
  if not GetNumLootItems then return end
  local who
  if UnitExists("target") and UnitIsDead("target") then who = UnitName("target") end
  local where = zoneText()
  for i = 1, GetNumLootItems() do
    local link = GetLootSlotLink(i)
    local itemID = link and tonumber(link:match("item:(%d+)"))
    if itemID and isRecipe(itemID) then
      local src = sourceDB(itemID)
      src.drops = src.drops or {}
      src.drops[(who or "loot") .. "|" .. where] = { mob = who, zone = where, t = time() }
    end
  end
end

local function recordQuestRecipes()
  if not GetQuestItemLink then return end
  local title = GetTitleText and GetTitleText()
  local giver = UnitName("npc")
  for _, kind in ipairs({ "choice", "reward" }) do
    local count = kind == "choice" and (GetNumQuestChoices and GetNumQuestChoices() or 0)
      or (GetNumQuestRewards and GetNumQuestRewards() or 0)
    for i = 1, count do
      local link = GetQuestItemLink(kind, i)
      local itemID = link and tonumber(link:match("item:(%d+)"))
      if itemID and isRecipe(itemID) and title then
        local src = sourceDB(itemID)
        src.quests = src.quests or {}
        src.quests[title] = { giver = giver, zone = zoneText(), t = time() }
      end
    end
  end
end

-- Lines describing where a recipe comes from (empty if unknown).
local function recipeSources(itemID)
  if not journalIndex then buildJournalIndex() end
  local lines = {}
  local src = db.sources and db.sources[itemID]
  if src then
    for npc, v in pairs(src.vendors or {}) do
      lines[#lines + 1] = ("Vendor: %s, %s - %s%s"):format(npc, v.zone or "?", v.price and money(v.price) or "?",
        v.limited and " |cffffd100(limited stock)|r" or "")
    end
    for title, q in pairs(src.quests or {}) do
      lines[#lines + 1] = ("Quest: %s%s"):format(title, q.giver and (" - " .. q.giver .. ", " .. (q.zone or "?")) or "")
    end
  end
  for _, text in ipairs(journalIndex and journalIndex[itemID] or {}) do lines[#lines + 1] = text end
  if src then
    for _, d in pairs(src.drops or {}) do
      lines[#lines + 1] = ("Looted: %s%s"):format(d.mob or "container/object", d.zone and (", " .. d.zone) or "")
    end
  end
  return lines
end

local function addSourceInfo(tooltip, itemID)
  local lines = recipeSources(itemID)
  tooltip:AddLine(" ")
  if #lines == 0 then
    tooltip:AddLine("Source: unknown yet", 0.6, 0.6, 0.6)
    tooltip:AddLine("Vendors you visit and drops you loot are remembered.", 0.5, 0.5, 0.5, true)
    return
  end
  tooltip:AddLine("Source", 1, 0.82, 0)
  for i, text in ipairs(lines) do
    if i > 6 then
      tooltip:AddLine(("  +%d more"):format(#lines - 6), 0.6, 0.6, 0.6)
      break
    end
    tooltip:AddLine("  " .. text, 0.85, 0.85, 0.85, true)
  end
end

local function onTooltipItem(tooltip, data)
  if not db or not tooltip or (tooltip.IsForbidden and tooltip:IsForbidden()) then return end
  if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
  if tooltip.__recipeProfitDone then return end

  local itemID = data and data.id
  if not itemID and tooltip.GetItem then
    local _, link = tooltip:GetItem()
    itemID = link and tonumber(link:match("item:(%d+)"))
  end
  local name = tooltip.GetItem and tooltip:GetItem()
  if itemID and name then rememberName(itemID, name) end
  if not isRecipe(itemID) then return end

  local lines = (data and linesFromData(data)) or linesFromFrame(tooltip)
  if not lines then return end
  if debugLines then
    msg("tooltip lines for item " .. itemID .. ":")
    for i, line in ipairs(lines) do print(i, line) end
  end
  local recipe = parseRecipe(lines)
  tooltip.__recipeProfitDone = true
  if recipe and #recipe.reagents > 0 then addRecipeInfo(tooltip, recipe) end
  addSourceInfo(tooltip, itemID)
  tooltip:Show()
end

local function hookTooltips()
  -- OnTooltipCleared rather than a hook on ClearLines: Blizzard's tooltip
  -- data handler calls ClearLines inside securecallfunction, and wrapping
  -- that method got "attempt to call a nil value" errors on Forever.
  for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
    tip:HookScript("OnTooltipCleared", function(self) self.__recipeProfitDone = nil end)
  end
  if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, onTooltipItem)
  else
    for _, tip in ipairs({ GameTooltip, ItemRefTooltip }) do
      tip:HookScript("OnTooltipSetItem", function(self) onTooltipItem(self) end)
    end
  end
end

------------------------------------------------------------------------------
-- Item names from AH results, so tooltip reagent names map to item IDs.
------------------------------------------------------------------------------

local function learnBrowseNames(results)
  for _, entry in ipairs(results or {}) do
    local itemID = entry.itemKey and entry.itemKey.itemID
    local info = itemID and C_AuctionHouse.GetItemKeyInfo(entry.itemKey)
    if info and info.itemName then rememberName(itemID, info.itemName) end
  end
end

------------------------------------------------------------------------------
-- Scanning: the bar under the results list says when the recipes on screen
-- are missing prices; its Scan button loads all of the results, then
-- prices every reagent and crafted item those recipes use through
-- LibCraftProfit (see startPricing), with the progress on the bar.
------------------------------------------------------------------------------

local bar
local startScan, stopScan -- defined below; the bar's button calls them

local function createBar()
  if bar or not AuctionHouseFrame then return end
  -- Under the results list, in the space right of your gold, with the
  -- Scan / Stop button at its right. Parented to the results so it only
  -- shows on the Browse tab, and hidden unless the results hold recipes or
  -- a scan is running.
  local results = AuctionHouseFrame.BrowseResultsFrame or AuctionHouseFrame
  local money = AuctionHouseFrame.MoneyFrameBorder

  local button = CreateFrame("Button", "RecipeProfitScanButton", results, "UIPanelButtonTemplate")
  button:SetSize(70, 20)
  if money then
    button:SetPoint("RIGHT", results, "RIGHT", -4, 0)
    button:SetPoint("TOP", money, "TOP", 0, 0)
  else
    button:SetPoint("BOTTOMRIGHT", AuctionHouseFrame, "BOTTOMRIGHT", -8, 8)
  end
  button:SetScript("OnClick", function()
    -- With every price known, a scan only makes sense as a full one.
    if scan then stopScan() else startScan(IsShiftKeyDown() or bar.allKnown) end
  end)
  button:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if scan then
      GameTooltip:AddLine("Stop scanning")
    elseif bar.allKnown then
      GameTooltip:AddLine("Full scan")
      GameTooltip:AddLine("Search the AH again for the reagents and crafted items of every recipe in these results, for current prices.", 1, 1, 1, true)
    else
      GameTooltip:AddLine("Scan")
      GameTooltip:AddLine("Search the AH for the reagents and crafted items of every recipe in these results. Items already priced today are skipped.", 1, 1, 1, true)
      GameTooltip:AddLine("Shift-click to search everything again.", 0.7, 0.7, 0.7, true)
    end
    GameTooltip:Show()
  end)
  button:SetScript("OnLeave", GameTooltip_Hide)

  bar = CreateFrame("StatusBar", "RecipeProfitScanBar", results)
  bar:SetHeight(14)
  if money then
    bar:SetPoint("LEFT", money, "RIGHT", 12, 0)
  else
    bar:SetPoint("BOTTOMLEFT", AuctionHouseFrame, "BOTTOMLEFT", 200, 10)
  end
  bar:SetPoint("RIGHT", button, "LEFT", -6, 0)
  bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  bar:SetStatusBarColor(0.85, 0.65, 0.1)
  local bg = bar:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0, 0, 0, 0.6)
  bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  bar.text:SetPoint("CENTER")
  bar.button = button
  button:SetText("Scan")
  bar:Hide()
  button:Hide()
end

local function updateBar()
  createBar()
  if not (bar and scan) then return end
  if scan.total then
    bar:SetMinMaxValues(0, math.max(scan.total, 1))
    bar:SetValue(scan.done)
    local label = scan.phase == "books" and "Checking reagent listings" or "Pricing recipes"
    bar.text:SetText(("%s %d/%d"):format(label, scan.done, scan.total))
  else
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    bar.text:SetText(("Loading recipes (%d)"):format(#(C_AuctionHouse.GetBrowseResults() or {})))
  end
  bar.button:SetText("Stop")
  bar.allKnown = nil
  bar:Show()
  bar.button:Show()
end

-- The bar between scans: text, full when filled. No text hides the bar
-- and its button.
local function showStatus(text, filled)
  if not bar then return end
  bar.allKnown = nil
  bar:SetShown(text ~= nil)
  bar.button:SetShown(text ~= nil)
  if not text then return end
  bar:SetMinMaxValues(0, 1)
  bar:SetValue(filled and 1 or 0)
  bar.text:SetText(text)
  bar.button:SetText("Scan")
end

local function finishScan(text, filled)
  scan = nil
  showStatus(text, filled)
end

-- Reagents and crafted items of every recipe in the browse results:
-- { { id, name, reagent = true | nil }, ... }, recipes (with reagents),
-- pending (item data still loading).
local function buildItems()
  local items, seen, recipes, pending = {}, {}, 0, 0
  local function add(name, reagent)
    if not name then return end
    local item = seen[key(name)]
    if not item then
      item = { id = idForName(name), name = name }
      seen[key(name)] = item
      items[#items + 1] = item
    end
    item.reagent = item.reagent or reagent
  end
  for _, entry in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
    local itemID = entry.itemKey and entry.itemKey.itemID
    if isRecipe(itemID) then
      -- Pending: the item's data hasn't loaded yet. A loaded recipe with no
      -- reagents (a skill book, say) isn't a craft: skipped.
      local lines = GetItemInfo(itemID) and linesForItemID(itemID)
      local recipe = lines and parseRecipe(lines)
      if not lines or not lines[1] or lines[1] == "" or (recipe and recipe.incomplete) then
        pending = pending + 1
        RequestLoadItemDataByID(itemID)
      elseif recipe and #recipe.reagents > 0 then
        recipes = recipes + 1
        for _, reagent in ipairs(recipe.reagents) do add(reagent.name, true) end
        local _, productName = resolveProduct(recipe)
        if not (recipe.productName or ""):match("^Enchant ") or productName then
          add(productName or recipe.productName)
        end
      end
    end
  end
  return items, recipes, pending
end

-- Puts the player's search back on screen after the quick pass replaced it.
local lastQuery, restoring
local function restoreSearch()
  if not (lastQuery and AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    C_Timer.After(0.25, restoreSearch)
    return
  end
  restoring = true
  C_AuctionHouse.SendBrowseQuery(lastQuery)
end

-- Three phases: a quick pass prices every reagent and crafted item (25 per
-- search, but it takes over the results list), the player's search is put
-- back, then an order book pass reads every listing of each reagent (for
-- buying several and undercuts) in the background. Items already done
-- today are skipped, unless forced.
local function startPricing(retries)
  local mine = scan
  if not mine then return end
  local items, recipes, pending = buildItems()
  -- Item data for some recipes may still be loading; give it a moment.
  if pending > 0 and (retries or 0) < 4 then
    C_Timer.After(0.75, function() if scan == mine then startPricing((retries or 0) + 1) end end)
    return
  end
  if recipes == 0 then finishScan("No recipes in these results"); return end

  -- Skipped unless forced: for the quick pass, items Auctionator or our
  -- searches priced today; for the order books, reagents with a full book
  -- from today.
  local today = date("%Y%m%d")
  local function bookToday(id, full)
    local book = Lib.Book(id)
    return book and date("%Y%m%d", book.t) == today and not (full and book.quote)
  end
  local quickIDs, bookIDs = {}, {}
  for _, item in ipairs(items) do
    if item.id and (mine.force or not (bookToday(item.id) or Lib.PriceAge(item.id) == 0)) then
      quickIDs[#quickIDs + 1] = item.id
    end
    if item.id and item.reagent and (mine.force or not bookToday(item.id, true)) then bookIDs[#bookIDs + 1] = item.id end
  end
  local function progress(phase)
    return function(n, total)
      if scan ~= mine then return end
      mine.phase, mine.done, mine.total = phase, n, total
      updateBar()
    end
  end
  local function stopped(why, n, total)
    if mine.replaced or why == "closed" then
      finishScan() -- a newer search took over, or the AH closed
    else
      finishScan(("Stopped at %d/%d"):format(n, total))
    end
  end

  local function runBooks()
    local count, reason = Lib.ScanBooks(bookIDs, {
      onProgress = progress("books"),
      onDone = function(why, n, total)
        if scan ~= mine then return end
        if why == "done" then
          finishScan(("Recipes priced (%d items)"):format(#items), true)
        else
          stopped(why, n, total)
        end
      end,
    })
    if not count then
      finishScan(reason) -- e.g. ProfessionProfit's scan is running
    elseif count == 0 then
      finishScan(#quickIDs > 0 and ("Recipes priced (%d items)"):format(#items) or "Recipes already priced today", true)
    else
      progress("books")(0, count)
    end
  end

  local count, reason = Lib.QuickScan(quickIDs, {
    onProgress = progress("quick"),
    onDone = function(why, n, total)
      if scan ~= mine then return end
      if not mine.replaced then restoreSearch() end
      if why == "done" then
        runBooks()
      else
        stopped(why, n, total)
      end
    end,
  })
  if not count then
    finishScan(reason)
  elseif count == 0 then
    runBooks()
  else
    progress("quick")(0, count)
  end
end

-- The AH only sends the first page of browse results until you scroll; keep
-- requesting more until all of them are loaded.
local function loadAllResults()
  local mine = scan
  if not mine then return end
  if not AuctionHouseFrame:IsShown() then finishScan(); return end
  updateBar()
  if C_AuctionHouse.HasFullBrowseResults() or mine.loadTries > 60 then
    startPricing()
    return
  end
  local wait = 0.5
  if C_AuctionHouse.IsThrottledMessageSystemReady and not C_AuctionHouse.IsThrottledMessageSystemReady() then
    wait = 0.25
  else
    mine.loadTries = mine.loadTries + 1
    C_AuctionHouse.RequestMoreBrowseResults()
  end
  C_Timer.After(wait, function() if scan == mine then loadAllResults() end end)
end

-- Prices the recipes in the current results; force: search items priced
-- today too. Replaces a scan already running.
-- Cancels our quick or order book pass (never ProfessionProfit's scan);
-- its onDone ends the scan. Returns false when neither is running.
local function cancelPass()
  if not scan then return false end
  if scan.phase == "quick" then Lib.CancelQuickScan(); return true end
  if scan.phase == "books" then Lib.CancelBookScan(); return true end
  return false
end

startScan = function(force)
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return false end
  if scan then
    scan.replaced = true
    if not cancelPass() then finishScan() end
  end
  scan = { loadTries = 0, force = force }
  loadAllResults()
  return true
end

stopScan = function()
  if not cancelPass() then finishScan("Stopped") end
end

-- Remember the player's search, to put it back after the quick pass. A
-- search of theirs during the quick pass ends it (its results would be
-- overwritten). Auctionator's full scan (an empty search with no category)
-- is left alone.
if C_AuctionHouse and C_AuctionHouse.SendBrowseQuery then
  hooksecurefunc(C_AuctionHouse, "SendBrowseQuery", function(query)
    if restoring then restoring = false; return end -- ours, putting the search back
    local everything = type(query) == "table" and (query.searchString or "") == ""
      and not (query.itemClassFilters and query.itemClassFilters[1])
    if everything then return end
    lastQuery = query
    if scan and scan.phase == "quick" then
      scan.replaced = true
      Lib.CancelQuickScan()
    end
  end)
end

-- Between scans, the bar says whether the recipes on screen are missing
-- prices (and so need a Scan); with no recipes on screen it's hidden.
local checkToken = 0
local function checkResults(retries)
  if scan or not bar then return end
  local items, recipes, pending = buildItems()
  -- Some recipes' item data is still loading: count again shortly, for up
  -- to 3 seconds; after that, go by the recipes that did load.
  local waiting = pending > 0 and (retries or 0) < 10
  if waiting then
    local token = checkToken
    C_Timer.After(0.3, function() if token == checkToken then checkResults((retries or 0) + 1) end end)
  end
  if recipes == 0 and not waiting then showStatus(); return end
  local missing = 0
  for _, item in ipairs(items) do
    if priceMissing(item.id) then missing = missing + 1 end
  end
  if missing > 0 then
    showStatus(("%d price%s missing: click Scan"):format(missing, missing == 1 and "" or "s"))
  elseif waiting then
    showStatus("Checking prices...")
  else
    showStatus(("Prices known for %d recipe%s"):format(recipes, recipes == 1 and "" or "s"), true)
    bar.allKnown = true
  end
end

-- Show or hide the bar as soon as results arrive (a cheap look for any
-- recipe), then count missing prices once this batch of results settles.
local function onBrowseResults()
  if scan then return end
  createBar()
  if not bar then return end
  local hasRecipes = false
  for _, entry in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
    if isRecipe(entry.itemKey and entry.itemKey.itemID) then hasRecipes = true; break end
  end
  if not hasRecipes then
    showStatus()
  elseif not bar:IsShown() then
    showStatus("Checking prices...")
  end
  checkToken = checkToken + 1
  local token = checkToken
  C_Timer.After(0.1, function() if token == checkToken then checkResults() end end)
end

------------------------------------------------------------------------------
-- Events & slash command
------------------------------------------------------------------------------

local frame = CreateFrame("Frame")
for _, event in ipairs({ "ADDON_LOADED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "MERCHANT_SHOW", "LOOT_OPENED",
  "QUEST_DETAIL", "QUEST_COMPLETE", "GET_ITEM_INFO_RECEIVED", "ITEM_KEY_ITEM_INFO_RECEIVED" }) do
  pcall(frame.RegisterEvent, frame, event)
end

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name == ADDON then
      RecipeProfitDB = RecipeProfitDB or {}
      db = RecipeProfitDB
      db.names = db.names or {}
      db.orderBooks = db.orderBooks or {}
      Lib.SetBookStore(db.orderBooks)
      -- Prices now live in Auctionator; drop what older versions saved.
      db.prices, db.vendor, db.missing = nil, nil, nil
      hookTooltips()
    elseif name == "Blizzard_AuctionHouseUI" then
      createBar()
    end
  elseif not db then
    return
  elseif event == "AUCTION_HOUSE_SHOW" then
    createBar()
  elseif event == "AUCTION_HOUSE_CLOSED" then
    finishScan()
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
    learnBrowseNames(C_AuctionHouse.GetBrowseResults())
    onBrowseResults()
  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    learnBrowseNames(...)
    onBrowseResults()
  elseif event == "LOOT_OPENED" then
    recordLootRecipes()
  elseif event == "QUEST_DETAIL" or event == "QUEST_COMPLETE" then
    recordQuestRecipes()
  elseif event == "MERCHANT_SHOW" then
    recordVendorRecipes()
  elseif event == "GET_ITEM_INFO_RECEIVED" or event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
    local itemID = ...
    if pendingNames[itemID] then rememberName(itemID, GetItemInfo(itemID)) end
  end
end)

SLASH_RECIPEPROFIT1 = "/rprofit"
SLASH_RECIPEPROFIT2 = "/rp"
SlashCmdList.RECIPEPROFIT = function(input)
  local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if cmd == "scan" then
    if not startScan(true) then msg("Open the auction house first.") end
  elseif cmd == "debug" then
    debugLines = not debugLines
    msg("debug " .. (debugLines and "on: hover a recipe to print its tooltip lines" or "off"))
  elseif cmd == "price" and rest ~= "" then
    local id = idForName(rest)
    if not id then msg("Unknown item: " .. rest); return end
    local p, src = Lib.BuyPrice(id)
    local s = Lib.AHPrice(id)
    msg(("%s (id %d): buy %s [%s], AH %s"):format(rest, id, p and money(p) or "none", src or "-", s and money(s) or "none"))
  elseif cmd == "reset" then
    wipe(db.names)
    msg("Saved item names cleared.")
  else
    msg("commands:")
    print("  /rp scan - search the AH for every recipe in the current results, even items priced today")
    print("  /rp price <item name> - show the price used for an item")
    print("  /rp debug - print raw recipe tooltip lines (for troubleshooting)")
    print("  /rp reset - clear saved item names")
  end
end
