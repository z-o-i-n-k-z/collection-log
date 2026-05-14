-- CollectionLog_Importer_Mounts.lua
local ADDON, ns = ...

-- Minimal, Blizzard-truthful Mounts group.
-- Collectible identity: mountID (C_MountJournal)

local function EnsureCollectionsLoaded()
  if C_MountJournal and C_MountJournal.GetMountIDs and C_MountJournal.GetMountInfoByID then
    return true
  end
  pcall(LoadAddOn, "Blizzard_Collections")
  return true
end



local DENY_MOUNT_IDS = {
  [116]  = "Black Qiraji Battle Tank duplicate/hidden entry",
  [121]  = "Black Qiraji Battle Tank duplicate/hidden entry",
  [122]  = "Black Qiraji Battle Tank duplicate/hidden entry",
  [1608] = "Soar ability",
  [1952] = "Soar ability",
  [2115] = "Soar ability",
  [2716] = "Placeholder remix mount",
}

local DENY_SPELL_IDS = {
  [25863]   = "Black Qiraji Battle Tank duplicate/hidden spell",
  [26655]   = "Black Qiraji Battle Tank duplicate/hidden spell",
  [26656]   = "Black Qiraji Battle Tank duplicate/hidden spell",
  [430833]  = "Soar ability",
  [430747]  = "Soar ability",
  [441313]  = "Soar ability",
  [1254363] = "Placeholder remix mount",
}

local DENY_MOUNT_NAMES = {
  ["black qiraji battle tank"] = "Black Qiraji Battle Tank duplicate/hidden entry",
}

local function NormalizeMountName(name)
  if type(name) ~= "string" then return "" end
  return name:gsub("^%s+", ""):gsub("%s+$", "")
end

function ns.GetInvalidMountJournalReason(mountID, includeSuspicious)
  if not (C_MountJournal and C_MountJournal.GetMountInfoByID) then return nil end
  local ok, name, spellID, _, _, _, sourceType = pcall(C_MountJournal.GetMountInfoByID, mountID)
  if not ok then return "GetMountInfoByID failed" end

  name = NormalizeMountName(name)
  if DENY_MOUNT_IDS[mountID] then return DENY_MOUNT_IDS[mountID] end
  if spellID and DENY_SPELL_IDS[spellID] then return DENY_SPELL_IDS[spellID] end
  if name == "" then return "Empty mount name" end
  if name == "Soar" then return "Soar ability" end

  local lname = name:lower()
  if DENY_MOUNT_NAMES[lname] then return DENY_MOUNT_NAMES[lname] end
  if lname:find("placeholder", 1, true) or lname:find("(ph)", 1, true) then
    return "Placeholder mount"
  end

  if includeSuspicious then
    if (not spellID) or spellID <= 0 then return "Missing spellID" end
    if sourceType == -1 then return "Unknown/invalid source type" end
  end

  return nil
end

function ns.IsValidMountJournalEntry(mountID, includeSuspicious)
  return ns.GetInvalidMountJournalReason(mountID, includeSuspicious) == nil
end

function ns.GetMountJournalAuditRecord(mountID)
  if not (C_MountJournal and C_MountJournal.GetMountInfoByID) then return nil end

  local ok, name, spellID, icon, isActive, isUsable, sourceType, isFavorite, isFactionSpecific, faction, shouldHideOnChar, isCollected = pcall(C_MountJournal.GetMountInfoByID, mountID)
  if not ok then
    return {
      mountID = mountID,
      invalidReason = "GetMountInfoByID failed",
      suspiciousReasons = {},
    }
  end

  local creatureDisplayInfoID, description, sourceText, isSelfMount, mountTypeID
  if C_MountJournal.GetMountInfoExtraByID then
    local okExtra, a, b, c, d, e = pcall(C_MountJournal.GetMountInfoExtraByID, mountID)
    if okExtra then
      creatureDisplayInfoID = a
      description = b
      sourceText = c
      isSelfMount = d
      mountTypeID = e
    end
  end

  local suspiciousReasons = {}
  local function AddSuspicious(reason)
    if reason and reason ~= "" then suspiciousReasons[#suspiciousReasons + 1] = reason end
  end

  local invalidReason = ns.GetInvalidMountJournalReason and ns.GetInvalidMountJournalReason(mountID, false) or nil
  if not invalidReason then
    if (not spellID) or spellID <= 0 then AddSuspicious("Missing spellID") end
    if sourceType == -1 then AddSuspicious("Unknown/invalid source type") end
    if type(sourceText) == "string" then
      local trimmed = sourceText:gsub("^%s+", ""):gsub("%s+$", "")
      if trimmed == "" then AddSuspicious("Empty source text") end
    else
      AddSuspicious("Missing source text")
    end
    if creatureDisplayInfoID ~= nil and creatureDisplayInfoID <= 0 then
      AddSuspicious("Missing creature display")
    end
    if mountTypeID ~= nil and mountTypeID <= 0 then
      AddSuspicious("Missing/invalid mount type")
    end
  end

  return {
    mountID = mountID,
    name = NormalizeMountName(name),
    spellID = spellID,
    icon = icon,
    sourceType = sourceType,
    sourceText = sourceText,
    creatureDisplayInfoID = creatureDisplayInfoID,
    description = description,
    isSelfMount = isSelfMount,
    mountTypeID = mountTypeID,
    isCollected = isCollected,
    isFactionSpecific = isFactionSpecific,
    faction = faction,
    shouldHideOnChar = shouldHideOnChar,
    invalidReason = invalidReason,
    suspiciousReasons = suspiciousReasons,
  }
end

function ns.GetValidMountJournalIDs(includeSuspicious)
  EnsureCollectionsLoaded()
  if not (C_MountJournal and C_MountJournal.GetMountIDs) then return {} end
  local ok, ids = pcall(C_MountJournal.GetMountIDs)
  if not ok or type(ids) ~= "table" then return {} end
  local out = {}
  for _, mountID in ipairs(ids) do
    if mountID and ns.IsValidMountJournalEntry(mountID, includeSuspicious) then
      out[#out+1] = mountID
    end
  end
  return out
end

local function UpsertGeneratedGroup(group)
  if not CollectionLogDB then return end
  CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or {}
  CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}
  local list = CollectionLogDB.generatedPack.groups

  for i = #list, 1, -1 do
    if list[i] and list[i].id == group.id then
      list[i] = group
      return
    end
  end
  table.insert(list, group)

end
local function PurgeGeneratedGroupsForCategory(cat)
  CollectionLogDB = CollectionLogDB or {}
  CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or {}
  CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}
  local list = CollectionLogDB.generatedPack.groups
  for i = #list, 1, -1 do
    local g = list[i]
    if g and (g.category == cat or (cat == "Mounts" and type(g.id)=="string" and g.id:find("^mounts:"))) then
      table.remove(list, i)
    end
  end
end

local SOURCE_TYPE_NAMES = {
  [0] = "Unknown",
  [1] = "Drop",
  [2] = "Quest",
  [3] = "Vendor",
  [4] = "Profession",
  [5] = "Achievement",
  [6] = "World Event",
  [7] = "Promotion",
  [8] = "Store",
  [9] = "Trading Post",
  [10] = "PvP",
}

local MJE_MOUNT_SOURCE_BY_SPELL = {
  ["Drop"] = {
    [61294]=true,[132036]=true,[138641]=true,[138642]=true,[138643]=true,[171619]=true,[171630]=true,
    [171837]=true,[179478]=true,[215545]=true,[223018]=true,[235764]=true,[243025]=true,[243652]=true,
    [247402]=true,[253058]=true,[253106]=true,[253107]=true,[253108]=true,[253109]=true,[253660]=true,
    [253661]=true,[253662]=true,[261395]=true,[288499]=true,[300150]=true,[312765]=true,[315014]=true,
    [315427]=true,[316493]=true,[332252]=true,[334352]=true,[334433]=true,[336038]=true,[342335]=true,
    [344574]=true,[344575]=true,[344576]=true,[347250]=true,[350219]=true,[353859]=true,[353877]=true,
    [354354]=true,[368105]=true,[368128]=true,[374138]=true,[374157]=true,[374194]=true,[374196]=true,
    [374278]=true,[385266]=true,[408651]=true,[420097]=true,[424476]=true,[448979]=true,[466020]=true,
    [466021]=true,[466026]=true,[471562]=true,[1228865]=true,[1233561]=true,[1240632]=true,[1241070]=true,
    [1241076]=true,[1243597]=true,[1247596]=true,[1247597]=true,[1247598]=true,[1253927]=true,[1253938]=true,
    [1260354]=true,[1260356]=true,[1261155]=true,[1261302]=true,[1261316]=true,[1261323]=true,[1261332]=true,
    [1261334]=true,[1261351]=true,[1261360]=true,[1261576]=true,[1261583]=true,[1266700]=true,
  },
  ["Quest"] = {
    [54753]=true,[73313]=true,[75207]=true,[127154]=true,[136163]=true,[136164]=true,[138640]=true,
    [171850]=true,[213158]=true,[213163]=true,[213164]=true,[213165]=true,[215159]=true,[230987]=true,
    [259741]=true,[267270]=true,[297560]=true,[299159]=true,[300146]=true,[300147]=true,[312754]=true,
    [312759]=true,[312761]=true,[316339]=true,[316802]=true,[332455]=true,[332462]=true,[332904]=true,
    [332932]=true,[333027]=true,[334391]=true,[334406]=true,[339588]=true,[344577]=true,[352441]=true,
    [352742]=true,[353264]=true,[354358]=true,[354361]=true,[354362]=true,[360954]=true,[363701]=true,
    [368893]=true,[368896]=true,[368899]=true,[368901]=true,[369666]=true,[370620]=true,[374247]=true,
    [376873]=true,[385738]=true,[395644]=true,[407555]=true,[408313]=true,[412088]=true,[413409]=true,
    [413825]=true,[413827]=true,[417548]=true,[417552]=true,[417554]=true,[417556]=true,[425338]=true,
    [427041]=true,[430225]=true,[446052]=true,[451489]=true,[466027]=true,[466133]=true,[474086]=true,
    [1221132]=true,[1224048]=true,[1233516]=true,[1233559]=true,[1242272]=true,[1261391]=true,
  },
  ["Vendor"] = {
    [578]=true,[15780]=true,[32235]=true,[32239]=true,[32240]=true,[32242]=true,[32243]=true,[32244]=true,
    [32245]=true,[32246]=true,[32289]=true,[32290]=true,[32292]=true,[32295]=true,[32296]=true,[32297]=true,
    [33630]=true,[59791]=true,[59793]=true,[60114]=true,[60116]=true,[61229]=true,[61230]=true,[61425]=true,
    [61447]=true,[122708]=true,[127216]=true,[127220]=true,[171616]=true,[171628]=true,[171825]=true,
    [171846]=true,[213115]=true,[214791]=true,[227956]=true,[259740]=true,[266925]=true,[279474]=true,
    [288506]=true,[288587]=true,[288589]=true,[288711]=true,[288714]=true,[288735]=true,[288736]=true,
    [288740]=true,[294143]=true,[300151]=true,[300153]=true,[316340]=true,[318051]=true,[332243]=true,
    [332245]=true,[332246]=true,[332248]=true,[332456]=true,[332464]=true,[332927]=true,[333021]=true,
    [334386]=true,[334398]=true,[334403]=true,[334408]=true,[334409]=true,[340503]=true,[342667]=true,
    [349935]=true,[352926]=true,[359409]=true,[371176]=true,[373859]=true,[374098]=true,[374162]=true,
    [374204]=true,[376875]=true,[376879]=true,[376880]=true,[376910]=true,[376913]=true,[384963]=true,
    [385115]=true,[385131]=true,[385134]=true,[385262]=true,[394216]=true,[394218]=true,[394219]=true,
    [394220]=true,[408627]=true,[408653]=true,[408655]=true,[414316]=true,[414323]=true,[414324]=true,
    [414326]=true,[414327]=true,[414328]=true,[414334]=true,[423871]=true,[423873]=true,[423877]=true,
    [423891]=true,[424479]=true,[424482]=true,[426955]=true,[427043]=true,[427222]=true,[427224]=true,
    [427226]=true,[427546]=true,[427549]=true,[427724]=true,[428060]=true,[447057]=true,[447151]=true,
    [447173]=true,[447176]=true,[447185]=true,[447957]=true,[448680]=true,[448685]=true,[448689]=true,
    [448939]=true,[448978]=true,[449269]=true,[449418]=true,[451487]=true,[465999]=true,[466000]=true,
    [466002]=true,[466011]=true,[466012]=true,[466013]=true,[466016]=true,[466017]=true,[466018]=true,
    [466019]=true,[466023]=true,[466025]=true,[466028]=true,[473137]=true,[1218316]=true,[1226421]=true,
    [1233518]=true,[1233547]=true,[1243593]=true,[1251433]=true,[1251630]=true,[1253929]=true,[1261291]=true,
    [1261322]=true,[1261336]=true,[1261337]=true,[1261348]=true,[1261357]=true,[1261579]=true,[1261584]=true,
    [1261585]=true,[1268924]=true,[1268926]=true,[1270675]=true,
  },
  ["Profession"] = {
    [30174]=true,[44151]=true,[44153]=true,[55531]=true,[60424]=true,[61309]=true,[61451]=true,[64731]=true,
    [75596]=true,[84751]=true,[92155]=true,[93326]=true,[120043]=true,[121820]=true,[121836]=true,
    [121837]=true,[121838]=true,[121839]=true,[126507]=true,[126508]=true,[134359]=true,
  },
  ["Instance"] = {
    [25953]=true,[26054]=true,[26055]=true,[26056]=true,[59569]=true,[231428]=true,[346141]=true,
    [363178]=true,[413922]=true,[428068]=true,[447189]=true,[1218229]=true,[1218305]=true,[1218306]=true,
    [1218307]=true,[1242272]=true,[1263635]=true,[1265784]=true,
  },
  ["Reputation"] = {
    [458]=true,[470]=true,[472]=true,[580]=true,[6648]=true,[6653]=true,[6654]=true,[6777]=true,[6898]=true,
    [6899]=true,[8394]=true,[8395]=true,[10789]=true,[10793]=true,[10796]=true,[10799]=true,[10873]=true,
    [10969]=true,[17229]=true,[17453]=true,[17454]=true,[17462]=true,[17463]=true,[17464]=true,[17465]=true,
    [18989]=true,[18990]=true,[23219]=true,[23221]=true,[23222]=true,[23223]=true,[23225]=true,[23227]=true,
    [23228]=true,[23229]=true,[23238]=true,[23239]=true,[23240]=true,[23241]=true,[23242]=true,[23243]=true,
    [23246]=true,[23247]=true,[23248]=true,[23249]=true,[23250]=true,[23251]=true,[23252]=true,[23338]=true,
    [33660]=true,[34406]=true,[34795]=true,[34896]=true,[34897]=true,[34898]=true,[34899]=true,[35018]=true,
    [35020]=true,[35022]=true,[35025]=true,[35027]=true,[35710]=true,[35711]=true,[35712]=true,[35713]=true,
    [35714]=true,[39315]=true,[39317]=true,[39318]=true,[39319]=true,[39798]=true,[39800]=true,[39801]=true,
    [39802]=true,[39803]=true,[41513]=true,[41514]=true,[41515]=true,[41516]=true,[41517]=true,[41518]=true,
    [43927]=true,[54753]=true,[59570]=true,[59797]=true,[59799]=true,[61469]=true,[61470]=true,[63232]=true,
    [63635]=true,[63636]=true,[63637]=true,[63638]=true,[63639]=true,[63640]=true,[63641]=true,[63642]=true,
    [63643]=true,[63844]=true,[64657]=true,[64658]=true,[64659]=true,[64977]=true,[65637]=true,[65638]=true,
    [65639]=true,[65640]=true,[65641]=true,[65642]=true,[65643]=true,[65644]=true,[65645]=true,[65646]=true,
    [66087]=true,[66088]=true,[66090]=true,[66091]=true,[66846]=true,[66847]=true,[66906]=true,[67466]=true,
    [87090]=true,[87091]=true,[88741]=true,[88748]=true,[88749]=true,[92231]=true,[92232]=true,[103195]=true,
    [103196]=true,[113199]=true,[118089]=true,[120395]=true,[120822]=true,[123886]=true,[123992]=true,
    [123993]=true,[127154]=true,[127164]=true,[127174]=true,[127176]=true,[127177]=true,[127272]=true,
    [127274]=true,[127278]=true,[127286]=true,[127287]=true,[127288]=true,[127289]=true,[127290]=true,
    [127293]=true,[127295]=true,[127302]=true,[127308]=true,[127310]=true,[129918]=true,[129932]=true,
    [129934]=true,[129935]=true,[130086]=true,[130092]=true,[130137]=true,[130138]=true,[135416]=true,
    [135418]=true,[140249]=true,[140250]=true,[171625]=true,[171633]=true,[171634]=true,[171829]=true,
    [171842]=true,[183117]=true,[190690]=true,[190977]=true,[230401]=true,[233364]=true,[237287]=true,
    [239013]=true,[242305]=true,[242874]=true,[242875]=true,[242881]=true,[242882]=true,[244712]=true,
    [253004]=true,[253005]=true,[253006]=true,[253007]=true,[253008]=true,[254069]=true,[254258]=true,
    [254259]=true,[259213]=true,[260172]=true,[260173]=true,[275837]=true,[275838]=true,[275840]=true,
    [275841]=true,[275859]=true,[275866]=true,[275868]=true,[291538]=true,[292407]=true,[294038]=true,
    [299170]=true,[316276]=true,[327405]=true,[332256]=true,[332484]=true,[332923]=true,[341639]=true,
    [342334]=true,[342666]=true,[347251]=true,[347536]=true,[347810]=true,[353265]=true,[354352]=true,
    [354356]=true,[354359]=true,[359229]=true,[359276]=true,[374032]=true,[374034]=true,[374048]=true,
    [374204]=true,[376875]=true,[376880]=true,[376910]=true,[376913]=true,[408655]=true,[423873]=true,
    [423891]=true,[447057]=true,[447176]=true,[447185]=true,[447957]=true,[448680]=true,[448685]=true,
    [448689]=true,[448939]=true,[448978]=true,[449269]=true,[449418]=true,[465999]=true,[466000]=true,
    [466001]=true,[466002]=true,[466011]=true,[466012]=true,[466013]=true,[466014]=true,[466016]=true,
    [466018]=true,[466019]=true,[466022]=true,[466024]=true,[466028]=true,[473188]=true,[1223187]=true,
    [1226421]=true,[1233542]=true,[1233546]=true,[1261579]=true,[1264621]=true,[1264643]=true,[1266702]=true,
  },
  ["Achievement"] = {
    [59961]=true,[60024]=true,[60025]=true,[61996]=true,[61997]=true,[72807]=true,[72808]=true,[88331]=true,
    [88335]=true,[88990]=true,[90621]=true,[93644]=true,[97359]=true,[97560]=true,[98204]=true,[107844]=true,
    [118737]=true,[124408]=true,[127156]=true,[127161]=true,[130985]=true,[136400]=true,[142266]=true,
    [142478]=true,[148392]=true,[170347]=true,[171436]=true,[171627]=true,[171632]=true,[175700]=true,
    [179244]=true,[179245]=true,[186305]=true,[191633]=true,[193007]=true,[215558]=true,[223814]=true,
    [225765]=true,[239049]=true,[250735]=true,[253087]=true,[254260]=true,[258022]=true,[258060]=true,
    [258845]=true,[259202]=true,[263707]=true,[267274]=true,[271646]=true,[280730]=true,[282682]=true,
    [289101]=true,[290328]=true,[292419]=true,[294039]=true,[294197]=true,[295386]=true,[295387]=true,
    [296788]=true,[303767]=true,[305592]=true,[306421]=true,[306423]=true,[308250]=true,[316343]=true,
    [318052]=true,[332460]=true,[332467]=true,[332903]=true,[339956]=true,[339957]=true,[344578]=true,
    [344659]=true,[346554]=true,[351408]=true,[354355]=true,[359318]=true,[359379]=true,[359381]=true,
    [360954]=true,[363136]=true,[363297]=true,[366791]=true,[368893]=true,[368896]=true,[368899]=true,
    [368901]=true,[373967]=true,[374071]=true,[374097]=true,[374155]=true,[374172]=true,[374275]=true,
    [376898]=true,[385260]=true,[405623]=true,[408648]=true,[408649]=true,[413409]=true,[417548]=true,
    [417552]=true,[417554]=true,[417556]=true,[418078]=true,[424474]=true,[424607]=true,[439138]=true,
    [440444]=true,[447160]=true,[447190]=true,[447195]=true,[448188]=true,[448850]=true,[448934]=true,
    [449415]=true,[452779]=true,[468068]=true,[471538]=true,[472752]=true,[473472]=true,[1218314]=true,
    [1223191]=true,[1233511]=true,[1241263]=true,[1243003]=true,[1243598]=true,[1245517]=true,[1246781]=true,
    [1247591]=true,[1250578]=true,[1253924]=true,[1257058]=true,[1257081]=true,[1261296]=true,[1261298]=true,
    [1261338]=true,[1261349]=true,[1262886]=true,[1266703]=true,[1266980]=true,[1268949]=true,[1270673]=true,
  },
  ["Covenants"] = {
    [215545]=true,[312753]=true,[312754]=true,[312759]=true,[312761]=true,[312763]=true,[312776]=true,
    [312777]=true,[332243]=true,[332244]=true,[332245]=true,[332246]=true,[332247]=true,[332248]=true,
    [332455]=true,[332456]=true,[332457]=true,[332460]=true,[332462]=true,[332464]=true,[332466]=true,
    [332467]=true,[332882]=true,[332923]=true,[332927]=true,[332932]=true,[332949]=true,[333021]=true,
    [333023]=true,[334365]=true,[334366]=true,[334382]=true,[334386]=true,[334391]=true,[334398]=true,
    [334403]=true,[334406]=true,[334408]=true,[334409]=true,[336039]=true,[336041]=true,[336045]=true,
    [336064]=true,[340503]=true,[341766]=true,[341776]=true,[342667]=true,[343550]=true,[347250]=true,
    [353856]=true,[353857]=true,[353858]=true,[353859]=true,[353866]=true,[353872]=true,[353873]=true,
    [353875]=true,[353877]=true,[353880]=true,[353883]=true,[353884]=true,[353885]=true,
  },
  ["Island Expedition"] = {
    [254811]=true,[266925]=true,[278979]=true,[279466]=true,[279467]=true,[279469]=true,[288711]=true,
    [288712]=true,[288720]=true,[288721]=true,[288722]=true,
  },
  ["Garrison"] = {
    [127271]=true,[171617]=true,[171623]=true,[171624]=true,[171626]=true,[171629]=true,[171635]=true,
    [171637]=true,[171638]=true,[171826]=true,[171831]=true,[171836]=true,[171838]=true,[171839]=true,
    [171841]=true,[171843]=true,[189364]=true,
  },
  ["PVP"] = {
    [22717]=true,[22718]=true,[22719]=true,[22720]=true,[22721]=true,[22722]=true,[22723]=true,[22724]=true,
    [23509]=true,[23510]=true,[34790]=true,[35028]=true,[39316]=true,[48027]=true,[59785]=true,[59788]=true,
    [60118]=true,[60119]=true,[88741]=true,[92231]=true,[92232]=true,[100332]=true,[100333]=true,
    [146615]=true,[146622]=true,[148428]=true,[171832]=true,[171833]=true,[171834]=true,[171835]=true,
    [183889]=true,[185052]=true,[193695]=true,[204166]=true,[222202]=true,[222236]=true,[222237]=true,
    [222238]=true,[222240]=true,[222241]=true,[223341]=true,[223354]=true,[223363]=true,[223578]=true,
    [229486]=true,[229487]=true,[229512]=true,[230988]=true,[232523]=true,[232525]=true,[242896]=true,
    [242897]=true,[261433]=true,[261434]=true,[270560]=true,[272481]=true,[281044]=true,[281887]=true,
    [281888]=true,[281889]=true,[281890]=true,[327407]=true,[327408]=true,[347255]=true,[347256]=true,
    [348769]=true,[348770]=true,[349823]=true,[349824]=true,[394737]=true,[394738]=true,[409032]=true,
    [409034]=true,[424534]=true,[424535]=true,[434470]=true,[434477]=true,[447405]=true,[449325]=true,
    [466145]=true,[466146]=true,[472157]=true,[1234820]=true,[1234821]=true,[1261629]=true,[1261648]=true,
    [1262840]=true,
  },
  ["Class"] = {
    [5784]=true,[13819]=true,[23161]=true,[23214]=true,[34767]=true,[34769]=true,[48778]=true,[54729]=true,
    [66906]=true,[69820]=true,[69826]=true,[73629]=true,[73630]=true,[200175]=true,[229376]=true,
    [229377]=true,[229385]=true,[229386]=true,[229387]=true,[229388]=true,[229417]=true,[229438]=true,
    [229439]=true,[231434]=true,[231435]=true,[231442]=true,[231523]=true,[231524]=true,[231525]=true,
    [231587]=true,[231588]=true,[231589]=true,[232412]=true,[238452]=true,[238454]=true,[270562]=true,
    [270564]=true,[290608]=true,[363613]=true,[453785]=true,
  },
  ["World Event"] = {
    [43900]=true,[48025]=true,[49378]=true,[49379]=true,[62048]=true,[71342]=true,[102346]=true,[102349]=true,
    [102350]=true,[103081]=true,[127165]=true,[142910]=true,[191314]=true,[194464]=true,[201098]=true,
    [228919]=true,[239766]=true,[239767]=true,[247448]=true,[254812]=true,[294197]=true,[294568]=true,
    [294569]=true,[300154]=true,[332482]=true,[359013]=true,[359318]=true,[408654]=true,[418078]=true,
    [424082]=true,[427777]=true,[428013]=true,[432455]=true,[437162]=true,[446902]=true,[452643]=true,
    [452645]=true,[457656]=true,[463133]=true,[468353]=true,[471696]=true,[472253]=true,[472479]=true,
    [1214920]=true,[1214940]=true,[1214946]=true,[1214974]=true,[1218013]=true,[1226144]=true,[1237631]=true,
    [1237703]=true,[1245198]=true,[1247662]=true,[1261668]=true,[1261671]=true,[1261677]=true,[1261681]=true,
    [1263369]=true,[1263387]=true,[1264988]=true,
  },
  ["Shop"] = {
    [139595]=true,[142878]=true,[153489]=true,[163024]=true,[348459]=true,[372677]=true,[431360]=true,
    [440915]=true,[457485]=true,[463045]=true,[466948]=true,[466977]=true,[466980]=true,[466983]=true,
    [471440]=true,[473478]=true,[473487]=true,[1224596]=true,[1224643]=true,[1224645]=true,[1224646]=true,
    [1224647]=true,[1229670]=true,[1229672]=true,[1238816]=true,[1239204]=true,[1239240]=true,[1239372]=true,
    [1249659]=true,[1257516]=true,[1280068]=true,
  },
  ["Promotion"] = {
    [42776]=true,[42777]=true,[46197]=true,[46199]=true,[51412]=true,[58983]=true,[65917]=true,[74856]=true,
    [74918]=true,[93623]=true,[96503]=true,[97581]=true,[98727]=true,[101573]=true,[102488]=true,
    [102514]=true,[107203]=true,[107516]=true,[107517]=true,[110051]=true,[113120]=true,[124659]=true,
    [136505]=true,[142073]=true,[155741]=true,[348459]=true,[372677]=true,[388516]=true,[394209]=true,
    [416158]=true,[423869]=true,[459486]=true,[459538]=true,[1217476]=true,[1250045]=true,[1266345]=true,
    [1266866]=true,
  },
}

local MJE_MOUNT_EXPANSIONS = {
  { key=0, name="Classic", minID=0, maxID=122, extras={
    [1843]=true,
  }},
  { key=1, name="The Burning Crusade", minID=123, maxID=226, extras={
    [241]=true,[243]=true,[1761]=true,
  }},
  { key=2, name="Wrath of the Lich King", minID=227, maxID=382, extras={
    [211]=true,[212]=true,[221]=true,[1679]=true,[1762]=true,[1769]=true,[1770]=true,[1806]=true,[1832]=true,
  }},
  { key=3, name="Cataclysm", minID=383, maxID=447, extras={
    [358]=true,[373]=true,[1807]=true,[1812]=true,[2147]=true,[2260]=true,[2309]=true,[2310]=true,[2311]=true,
    [2312]=true,
  }},
  { key=4, name="Mists of Pandaria", minID=448, maxID=571, extras={
    [467]=true,[2340]=true,[2341]=true,[2342]=true,[2343]=true,[2344]=true,[2345]=true,[2346]=true,
    [2476]=true,[2477]=true,[2514]=true,[2515]=true,[2516]=true,[2517]=true,[2582]=true,[2594]=true,
  }},
  { key=5, name="Warlords of Draenor", minID=572, maxID=772, extras={
    [454]=true,[552]=true,[778]=true,[781]=true,
  }},
  { key=6, name="Legion", minID=773, maxID=991, extras={
    [476]=true,[633]=true,[656]=true,[663]=true,[763]=true,[1006]=true,[1007]=true,[1008]=true,[1009]=true,
    [1011]=true,
  }},
  { key=7, name="Battle for Azeroth", minID=993, maxID=1329, extras={
    [926]=true,[928]=true,[933]=true,[956]=true,[958]=true,[963]=true,[1346]=true,
  }},
  { key=8, name="Shadowlands", minID=1330, maxID=1576, extras={
    [803]=true,[1289]=true,[1298]=true,[1299]=true,[1302]=true,[1303]=true,[1304]=true,[1305]=true,
    [1306]=true,[1307]=true,[1309]=true,[1310]=true,[1580]=true,[1581]=true,[1584]=true,[1585]=true,
    [1587]=true,[1597]=true,[1599]=true,[1600]=true,[1602]=true,[1679]=true,
  }},
  { key=9, name="Dragonflight", minID=1577, maxID=2115, extras={
    [1469]=true,[1478]=true,[1545]=true,[1546]=true,[1553]=true,[1556]=true,[1563]=true,[2118]=true,
    [2140]=true,[2142]=true,[2143]=true,[2152]=true,[2189]=true,
  }},
  { key=10, name="The War Within", minID=2116, maxID=2732, extras={
    [1550]=true,[1792]=true,[2795]=true,[2796]=true,[2797]=true,[2798]=true,[2802]=true,[2803]=true,
    [2804]=true,[2807]=true,[2808]=true,[2815]=true,[2823]=true,[2825]=true,
  }},
  { key=11, name="Midnight", minID=2733, maxID=9999999999, extras={
    [16]=true,[1946]=true,[2161]=true,[2220]=true,[2492]=true,[2595]=true,[2607]=true,[2608]=true,[2614]=true,
    [2615]=true,[2693]=true,[2694]=true,[2708]=true,[2710]=true,[2713]=true,
  }},
}

local MJE_MOUNT_SOURCE_SORT = {
  ["Drop"] = 10,
  ["Quest"] = 20,
  ["Vendor"] = 30,
  ["Profession"] = 40,
  ["Instance"] = 50,
  ["Reputation"] = 60,
  ["Achievement"] = 70,
  ["Covenants"] = 80,
  ["Island Expedition"] = 90,
  ["Garrison"] = 100,
  ["PvP"] = 110,
  ["Class"] = 120,
  ["World Event"] = 130,
  ["Trading Post"] = 140,
  ["Shop"] = 150,
  ["Promotion"] = 160,
  ["Other"] = 900,
}

local function GetMJESourceGroup(spellID, sourceType)
  spellID = tonumber(spellID)
  if spellID then
    for name, tbl in pairs(MJE_MOUNT_SOURCE_BY_SPELL) do
      if tbl and tbl[spellID] then
        local label = (name == "PVP") and "PvP" or name
        return label, MJE_MOUNT_SOURCE_SORT[label] or 900
      end
    end
  end
  local st = tonumber(sourceType or 0)
  local fallback = {
    [1] = "Drop",
    [2] = "Quest",
    [3] = "Vendor",
    [4] = "Profession",
    [5] = "Achievement",
    [6] = "World Event",
    [7] = "Promotion",
    [8] = "Shop",
    [9] = "Trading Post",
    [10] = "PvP",
  }
  local label = fallback[st] or "Other"
  return label, MJE_MOUNT_SOURCE_SORT[label] or 900
end

local function GetMJEExpansionGroup(mountID)
  mountID = tonumber(mountID)
  if not mountID then return nil, nil end
  for _, entry in ipairs(MJE_MOUNT_EXPANSIONS) do
    if (mountID >= (entry.minID or 0) and mountID <= (entry.maxID or 0)) or (entry.extras and entry.extras[mountID]) then
      return entry.name, 1000 - tonumber(entry.key or 0)
    end
  end
  return nil, nil
end

local function GetMountManualMJEOverrides(mountID)
  mountID = tonumber(mountID)
  if not mountID or not CollectionLogDB then return nil, nil end
  local uo = CollectionLogDB.userOverrides
  uo = uo and uo.mounts or nil
  if type(uo) ~= "table" then return nil, nil end

  local sourceOverride = uo.sourcePrimary and uo.sourcePrimary[mountID] or nil
  local expansionOverride = uo.expansionPrimary and uo.expansionPrimary[mountID] or nil

  -- backward compatibility with the older single-primary override model
  local legacy = uo.primary and uo.primary[mountID] or nil
  if type(legacy) == "string" and legacy ~= "" then
    if not sourceOverride then
      for _, name in ipairs(MJE_MOUNT_SOURCE_SORT and {"Drop","Quest","Vendor","Profession","Instance","Reputation","Achievement","Covenants","Island Expedition","Garrison","PvP","Class","World Event","Trading Post","Shop","Promotion","Other"} or {}) do
        if legacy == name then
          sourceOverride = legacy
          break
        end
      end
    end
    if not expansionOverride then
      for _, entry in ipairs(MJE_MOUNT_EXPANSIONS) do
        if legacy == entry.name then
          expansionOverride = legacy
          break
        end
      end
    end
  end

  return sourceOverride, expansionOverride
end



-- Mounts sidebar order (single canonical list; no duplicates).
-- Lower sortIndex appears higher in the left panel.
local MOUNTS_SIDEBAR_ORDER = {
  ["All Mounts"] = 10,
  ["Drops (All)"] = 20,
  ["Drops (Raid)"] = 30,
  ["Drops (Dungeon)"] = 40,
  ["Drops (Open World)"] = 50,
  ["Drops (Delve)"] = 60,

  ["Achievement"] = 70,
  ["Adventures"] = 75,
  ["Quest"] = 80,
  ["Reputation"] = 90,
  ["Profession"] = 100,
  ["Class"] = 110,
  ["Faction"] = 120,
  ["Race"] = 130,
  ["PvP"] = 140,
  ["Vendor"] = 150,
  ["World Event"] = 160,

  ["Store"] = 170,
  ["Trading Post"] = 180,
  ["Promotion"] = 190,
  ["Secret"] = 200,

  ["Garrison Mission"] = 210,
  ["Covenant Feature"] = 220,
  ["Unobtainable"] = 230,
  ["Uncategorized"] = 240,
}

local function MountSidebarIndex(name)
  if type(name) ~= "string" then return 999 end
  return MOUNTS_SIDEBAR_ORDER[name] or 999
end

-- Canonicalize Mounts group labels so we only ever surface ONE version of each.
-- Any variations are merged and de-duped into the canonical bucket.
local function CanonMountGroupName(name)
  if type(name) ~= "string" then return name end
  local n = name:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")
  local l = n:lower()

  -- Exact merges / renames
  if l == "covenant" or l == "covenant feature" then return "Covenant Feature" end
  if l == "garrison" or l == "garrison mission" or l == "garrison misson" then return "Garrison Mission" end
  if l == "vendors" or l == "vendor" then return "Vendor" end

  -- Route noisy/legacy buckets into canonical homes
  if l == "world quest" or l == "world quests" then return "Quest" end

  if l == "source" or l:match("^source%s+%d+") then return "Uncategorized" end
  if l == "item" or l == "location" or l == "npc" or l == "trainer" or l == "treasure" or l == "zone" or l == "area" or l == "discovery" then
    return "Uncategorized"
  end

  -- Keep the rest as-is (with original casing)
  return n
end

local function MergeUniqueMountIDs(dst, src)
  if type(dst) ~= "table" then return end
  if type(src) ~= "table" then return end
  local set = {}
  for _, id in ipairs(dst) do set[tonumber(id)] = true end
  for _, id in ipairs(src) do
    id = tonumber(id)
    if id and not set[id] then
      table.insert(dst, id)
      set[id] = true
    end
  end
  table.sort(dst)
end

-- Add mounts to an existing Mounts group by NAME (canonical), or create it.
-- This prevents duplicate sidebar entries like Achievement/Achievement, Vendors/Vendor, etc.
local function AddToMountsGroupByName(name, mountIDs)
  if not CollectionLogDB then return end
  CollectionLogDB.generatedPack = CollectionLogDB.generatedPack or {}
  CollectionLogDB.generatedPack.groups = CollectionLogDB.generatedPack.groups or {}
  local list = CollectionLogDB.generatedPack.groups

  local canon = CanonMountGroupName(name)
  if type(canon) ~= "string" or canon == "" then return end

  local found = nil
  for _, g in ipairs(list) do
    if g and g.category == "Mounts" and type(g.name) == "string" and CanonMountGroupName(g.name) == canon then
      found = g
      break
    end
  end

  if found then
    found.name = canon
    found.sortIndex = MountSidebarIndex(canon)
    found.expansion = (canon == "All Mounts") and "Account" or "Source"
    found.mounts = found.mounts or {}
    MergeUniqueMountIDs(found.mounts, mountIDs)
    return
  end

  local gid = "mounts:canon:" .. canon:gsub("%s+", "_"):lower()
  UpsertGeneratedGroup({
    id = gid,
    name = canon,
    category = "Mounts",
    expansion = (canon == "All Mounts") and "Account" or "Source",
    mounts = mountIDs or {},
    sortIndex = MountSidebarIndex(canon),
  })
end

local function SourceTypeName(sourceType)
  local n = SOURCE_TYPE_NAMES[tonumber(sourceType or 0)]
  if n then return n end
  return ("Source %s"):format(tostring(sourceType or "?"))
end

local mountFrame

local function NotifyCollectionsUIUpdated(category)
  -- Refresh left panel + grid after a generated pack rebuild, but only if the UI exists.
  if not (ns and ns.UI and ns.UI.frame and ns.UI.frame:IsShown()) then return end
  if ns.UI.BuildGroupList then pcall(ns.UI.BuildGroupList) end
  if CollectionLogDB and CollectionLogDB.ui and CollectionLogDB.ui.activeCategory == category then
    if ns.UI.RefreshGrid then pcall(ns.UI.RefreshGrid) end
  end
end

local function EnsureMountsEventFrame()
  if mountFrame then return end
  mountFrame = CreateFrame("Frame")
  mountFrame:SetScript("OnEvent", function(self)
    local ok = ns and ns._TryBuildMountsGroups and ns._TryBuildMountsGroups()
    if ok then
      self:UnregisterAllEvents()
      NotifyCollectionsUIUpdated("Mounts")
    end
  end)
end

function ns._TryBuildMountsGroups()
  EnsureCollectionsLoaded()

  if not (C_MountJournal and C_MountJournal.GetMountIDs and C_MountJournal.GetMountInfoByID) then
    return nil
  end


  -- Purge any previously generated Mounts groups so rebuilds don't accumulate stale/duplicate groups.
  PurgeGeneratedGroupsForCategory("Mounts")


  -- Normalize Mount Journal filters so we build an account-truthful, stable mount list.
  -- Some players (or other addons) can leave the Mount Journal in a filtered state (search text, collected-only, faction-only),
  -- which can cause 0/0 totals or faction-specific mounts showing as uncollected on the opposite faction.
  local function WithAccountTruthFilters(fn)
    if not (C_MountJournal and type(C_MountJournal.GetMountIDs) == "function") then
      return fn()
    end

    local restore = {}

    local function remember(getterName, setterName, desired)
      local getter = C_MountJournal[getterName]
      local setter = C_MountJournal[setterName]
      if type(getter) == "function" and type(setter) == "function" then
        local ok, cur = pcall(getter)
        if ok then
          restore[#restore+1] = function() pcall(setter, cur) end
          pcall(setter, desired)
        end
      end
    end

    -- Collected/uncollected toggles
    remember("GetCollectedFilterSetting", "SetCollectedFilterSetting", true)
    remember("GetUncollectedFilterSetting", "SetUncollectedFilterSetting", true)

    -- Clear search text if supported
    do
      local getSearch = C_MountJournal.GetSearchString
      local setSearch = C_MountJournal.SetSearch
      if type(getSearch) == "function" and type(setSearch) == "function" then
        local ok, cur = pcall(getSearch)
        if ok and cur and cur ~= "" then
          restore[#restore+1] = function() pcall(setSearch, cur) end
          pcall(setSearch, "")
        end
      end
    end

    -- Try to include all factions if the client exposes a filter for it (name varies across builds).
    -- We only call functions if they exist; no hard dependency.
    do
      local candidates = {
        "SetAllFactionFiltering",
        "SetAllFactionFilter",
        "SetAllFactions",
        "SetIncludeOppositeFaction",
        "SetAllowOppositeFaction",
      }
      for _, fnName in ipairs(candidates) do
        local f = C_MountJournal[fnName]
        if type(f) == "function" then
          -- No reliable getter across builds, so we don't restore this one.
          pcall(f, true)
          break
        end
      end
    end

    local out = fn()

    -- Restore filters we changed
    for i = #restore, 1, -1 do
      pcall(restore[i])
    end

    return out
  end

  local mountIDs = WithAccountTruthFilters(function()
    if ns.GetValidMountJournalIDs then
      return ns.GetValidMountJournalIDs(true)
    end
    return C_MountJournal.GetMountIDs()
  end)
  if type(mountIDs) ~= "table" or #mountIDs == 0 then
    return nil
  end

  -- Debounce: if we already built recently for the same mount count, do not rebuild again.
  ns._clogMountsBuiltCount = ns._clogMountsBuiltCount or 0
  ns._clogMountsBuiltAt = ns._clogMountsBuiltAt or 0
  local now = (GetTime and GetTime()) or 0
  if ns._clogMountsBuiltCount == #mountIDs and (now - ns._clogMountsBuiltAt) < 5 then
    return true
  end


  -- Cleanup: remove legacy/noisy Mounts groups so rebuild does NOT re-surface old labels.
  -- We keep ONLY the canonical set requested for the Mounts sidebar.
  do
    local allowed = {
      ["All Mounts"] = true,
      ["Drops (All)"] = true,
      ["Drops (Raid)"] = true,
      ["Drops (Dungeon)"] = true,
      ["Drops (Open World)"] = true,
      ["Drops (Delve)"] = true,
      ["Achievement"] = true,
      ["Adventures"] = true,
      ["Quest"] = true,
      ["Reputation"] = true,
      ["Profession"] = true,
      ["Class"] = true,
      ["Faction"] = true,
      ["Race"] = true,
      ["PvP"] = true,
      ["Vendor"] = true,
      ["World Event"] = true,
      ["Store"] = true,
      ["Trading Post"] = true,
      ["Promotion"] = true,
      ["Secret"] = true,
      ["Covenant Feature"] = true,
      ["Garrison Mission"] = true,
      ["Unobtainable"] = true,
      ["Uncategorized"] = true,
    }

    if CollectionLogDB and CollectionLogDB.generatedPack and type(CollectionLogDB.generatedPack.groups) == "table" then
      local list = CollectionLogDB.generatedPack.groups
      for i = #list, 1, -1 do
        local g = list[i]
        if g and g.category == "Mounts" and type(g.name) == "string" then
          local canon = CanonMountGroupName(g.name)
          if not allowed[canon] then
            table.remove(list, i)
          else
            -- Also normalize lingering renamed buckets.
            g.name = canon
            g.sortIndex = MountSidebarIndex(canon)
            g.expansion = (g.name == "All Mounts") and "Account" or "Source"
          end
        end
      end
    end
  end

  -- Helpers
  local function NormKey(s)
    if not s or s == "" then return nil end
    s = tostring(s):lower()
    s = s:gsub("’", "'")
    s = s:gsub("[^%w%s'%-%:]", "")
    s = s:gsub("%s+", " ")
    s = s:gsub("^%s+", ""):gsub("%s+$", "")
    return s
  end

  local function GetSourceText(mountID)
    if C_MountJournal and C_MountJournal.GetMountInfoExtraByID then
      local ok, _, _, st = pcall(C_MountJournal.GetMountInfoExtraByID, mountID)
      if ok then
        -- Common pattern: returns creatureDisplayID, description, sourceText, isSelfMount, mountTypeID
        if type(st) == "string" then return st end
        -- Some clients shift positions; try to recover "sourceText" heuristically
        local a, b, c, d, e = C_MountJournal.GetMountInfoExtraByID(mountID)
        if type(c) == "string" then return c end
        if type(b) == "string" and (b:find("Drop", 1, true) or b:find("Vendor", 1, true)) then return b end
      end
    end
    return ""
  end


  local function StripColorCodes(s)
    if type(s) ~= "string" then return "" end
    -- Remove Blizzard color codes like |cFFFFD200 and |r
    s = s:gsub("|c%x%x%x%x%x%x%x%x", "")
    s = s:gsub("|r", "")
    return s
  end

local function SourceLabelFromText(st)
  st = StripColorCodes(st or "")

  -- Some sources are a bare token (no colon), e.g. "In-Game Shop".
  local bare = st:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")
  if bare ~= "" and not bare:find(":", 1, true) then
    local b = bare:lower()
    if b == "in-game shop" or b == "shop" then return "Store" end
    if b == "promotion" then return "Promotion" end
    if b == "trading post" then return "Trading Post" end
    if b == "world event" then return "World Event" end
    if b == "achievement" then return "Achievement" end
    if b == "pvp" then return "PvP" end
    if b == "quest" then return "Quest" end
    if b == "drop" then return "Drop" end
    if b == "vendor" then return "Vendor" end
    if b == "profession" then return "Profession" end
    if b == "store" then return "Store" end
  end

  -- Expect formats like "Drop: ..." or "Quest: ..."
  local label = st:match("^%s*([%a%s]+)%s*:%s*")
  if not label then return nil end
  label = label:gsub("%s+", " "):gsub("^%s+",""):gsub("%s+$","")
  if label == "" then return nil end

  -- Normalize common variants
  local l = label:lower()
  if l == "world event" then return "World Event" end
  if l == "trading post" then return "Trading Post" end
  if l == "pvp" then return "PvP" end
  if l == "in-game shop" then return "Store" end

  -- Title-case simple labels
  if l == "drop" then return "Drop" end
  if l == "quest" then return "Quest" end
  if l == "vendor" then return "Vendor" end
  if l == "profession" then return "Profession" end
  if l == "achievement" then return "Achievement" end
  if l == "promotion" then return "Promotion" end
  if l == "store" then return "Store" end
  return label
end

  local function SourceTypeLabel(mountID, sourceType)

-- 0) Optional explicit overrides pack (offline-authored; no runtime inference)
local ovPack = ns.GetMountSourceOverridesPack and ns.GetMountSourceOverridesPack() or nil
local ov = (ovPack and ovPack.map) and ovPack.map[mountID] or nil
if type(ov) == "string" and ov ~= "" then
  local l = ov:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
  -- Normalize known noisy/duplicate labels into stable buckets
  if l:find("anniversary") or l:find("30th_anniversary") or l:find("15th_anniversary") then return "Anniversary" end
  if l == "ph_quest" or l == "phquest" then return "Quest" end
  if l == "store" or l == "in_game_shop" or l == "shop" then return "Store" end
  if l == "achievement" then return "Achievement" end
  if l == "raid" then return "Raid" end
  if l == "dungeon" then return "Dungeon" end
  if l == "delve" then return "Delve" end
  if l == "open_world" or l == "openworld" then return "Open World" end
  if l == "quest" then return "Quest" end
  if l == "pvp" then return "PvP" end
  if l == "promotion" then return "Promotion" end
  if l == "trading_post" then return "Trading Post" end
  if l == "world_event" then return "World Event" end
  if l == "vendor" then return "Vendor" end
  if l == "profession" then return "Profession" end
  if l == "drop" then return "Drop" end
  return ov
end

  -- Explicit offline source override (datapack)
  local ovPack = ns.GetMountSourceOverridesPack and ns.GetMountSourceOverridesPack() or nil
  local ov = ovPack and ovPack.map and ovPack.map[mountID] or nil
  if type(ov) == "string" and ov ~= "" then
    local l = ov:lower():gsub("[^%w]+", "_"):gsub("^_+", ""):gsub("_+$", "")
    if l == "store" then return "Store" end
    if l == "achievement" then return "Achievement" end
    if l == "raid" then return "Raid" end
    if l == "dungeon" then return "Dungeon" end
    if l == "quest" then return "Quest" end
    if l == "pvp" then return "PvP" end
    if l == "promotion" then return "Promotion" end
    if l == "trading_post" then return "Trading Post" end
    if l == "world_event" then return "World Event" end
    return ov
  end

    -- Prefer Mount Journal's own source text token to avoid unstable numeric enums.
    local st = GetSourceText(mountID)
    local fromText = SourceLabelFromText(st)
    if fromText then return fromText end
    -- Fallback: numeric mapping for compatibility
    local n = SOURCE_TYPE_NAMES[tonumber(sourceType or 0)]
    if n then return n end
    return ("Source %s"):format(tostring(sourceType or "?"))
  end

  local function BuildInstanceNameSets()
    local raids = {}
    local dungeons = {}

    -- 1) Prefer our curated EJ-imported groups if present (stable naming)
    if ns and ns.Data and ns.Data.groupsByCategory then
      local r = ns.Data.groupsByCategory["Raids"]
      if type(r) == "table" then
        for _, g in ipairs(r) do
          if g and type(g.name) == "string" and g.name ~= "" then
            local k = NormKey(g.name)
            if k then raids[k] = g.name end
          end
        end
      end

      local d = ns.Data.groupsByCategory["Dungeons"]
      if type(d) == "table" then
        for _, g in ipairs(d) do
          if g and type(g.name) == "string" and g.name ~= "" then
            local k = NormKey(g.name)
            if k then dungeons[k] = g.name end
          end
        end
      end
    end

    -- 2) Fallback: build instance-name sets straight from the Encounter Journal (Blizzard truth).
    -- This prevents mis-bucketing raid/dungeon drops as "Open World" when curated raid/dungeon groups
    -- are not populated yet.
    if (not next(raids)) and (not next(dungeons)) and ns and ns.EnsureEJLoaded and ns.EnsureEJLoaded() then
      local curTier = nil
      if EJ_GetCurrentTier then pcall(function() curTier = EJ_GetCurrentTier() end) end

      local numTiers = 0
      if EJ_GetNumTiers then
        local ok, n = pcall(EJ_GetNumTiers)
        if ok and type(n) == "number" then numTiers = n end
      end
      if numTiers <= 0 then numTiers = 80 end

      for tier = 1, numTiers do
        local okTier = pcall(EJ_SelectTier, tier)
        if not okTier then break end

        for _, isRaid in ipairs({ true, false }) do
          for i = 1, 2000 do
            local okI, instanceID = pcall(EJ_GetInstanceByIndex, i, isRaid)
            if not okI or not instanceID then break end

            local name = nil
            if EJ_GetInstanceInfo then
              pcall(function() name = EJ_GetInstanceInfo(instanceID) end)
            end
            if name and name ~= "" then
              local k = NormKey(name)
              if k then
                if isRaid then raids[k] = name else dungeons[k] = name end
              end
            end
          end
        end
      end

      if curTier and EJ_SelectTier then pcall(EJ_SelectTier, curTier) end
    end

    return raids, dungeons
  end

  local function MatchOneInstance(sourceTextNorm, nameMap)
    if not sourceTextNorm or sourceTextNorm == "" then return nil, false end
    local foundKey, foundName = nil, nil
    local count = 0
    for k, original in pairs(nameMap) do
      if k and k ~= "" and sourceTextNorm:find(k, 1, true) then
        count = count + 1
        foundKey, foundName = k, original
        if count > 1 then
          return nil, true -- ambiguous
        end
      end
    end
    if count == 1 then
      return foundName, false
    end
    return nil, false
  end

  local raidNames, dungeonNames = BuildInstanceNameSets()

  -- Buckets by Blizzard sourceType (truthful, no inference).
  local buckets = {}
  local all = {}

  -- Retired/unobtainable mounts (datapack: name-based; English client).
  local unobtainable = {}

  -- Drop-derived buckets (strict; derived from Blizzard sourceText + EJ instance/encounter truth).
  local dropAll, dropRaid, dropDungeon, dropDelve, dropOpenWorld, dropUnclassified = {}, {}, {}, {}, {}, {}

  for _, mountID in ipairs(mountIDs) do
    local mountName, _, _, _, _, sourceType = C_MountJournal.GetMountInfoByID(mountID)
    table.insert(all, mountID)

    -- If this mount is in the retired/unobtainable datapack, route it exclusively to Unobtainable.
    -- (Keeps sidebar clean and matches user expectations: moved out of other buckets.)
    local lname = mountName and mountName:lower() or nil
    if ns and ns.RetiredMountNameSet and lname and ns.RetiredMountNameSet[lname] then
      table.insert(unobtainable, mountID)
    else
      local key = SourceTypeLabel(mountID, sourceType)
      buckets[key] = buckets[key] or {}
      table.insert(buckets[key], mountID)

      if key == "Drop" then -- Drop
      table.insert(dropAll, mountID)

      local st = GetSourceText(mountID)
      local stNorm = NormKey(st)

      -- 0) Offline drop categories pack (authoritative when present)
local dropPack = ns.GetMountDropCategoriesPack and ns.GetMountDropCategoriesPack() or nil

local function normCat(v)
  if type(v) ~= "string" then return nil end
  v = v:upper():gsub("[^A-Z0-9]+", "_")
  -- Collapse common variants to canonical buckets
  if v:find("RAID", 1, true) then return "RAID" end
  if v:find("DUNG", 1, true) then return "DUNGEON" end
  if v:find("DELVE", 1, true) then return "DELVE" end
  if v:find("OPEN", 1, true) or v:find("WORLD", 1, true) then return "OPEN_WORLD" end
  return v
end

local dropEntry = nil
if dropPack and dropPack.map then
  -- Support both numeric and string mountID keys
  dropEntry = dropPack.map[mountID] or dropPack.map[tostring(mountID)]
end

if type(dropEntry) == "table" then
  local cat = normCat(dropEntry.cat or dropEntry.category)
  if cat == "RAID" then
    table.insert(dropRaid, mountID)
  elseif cat == "DUNGEON" then
    table.insert(dropDungeon, mountID)
  elseif cat == "DELVE" then
    table.insert(dropDelve, mountID)
  elseif cat == "OPEN_WORLD" then
    table.insert(dropOpenWorld, mountID)
  else
    table.insert(dropUnclassified, mountID)
  end
else


      local ambiguous = false

      -- 1) Prefer direct instance-name match using our Raids/Dungeons tabs (EJ-backed names)
      local raidMatch, ambRaid = MatchOneInstance(stNorm, raidNames)
      if ambRaid then ambiguous = true end
      local dungeonMatch, ambDung = MatchOneInstance(stNorm, dungeonNames)
      if ambDung then ambiguous = true end

      if not ambiguous and raidMatch and not dungeonMatch then
        table.insert(dropRaid, mountID)
      elseif not ambiguous and dungeonMatch and not raidMatch then
        table.insert(dropDungeon, mountID)
      elseif ambiguous or (raidMatch and dungeonMatch) then
        table.insert(dropUnclassified, mountID)
      else
        -- 2) Boss -> Instance mapping via Encounter Journal (strict)
        if ns and ns.ResolveBossToInstanceStrict then
          local category, _, _ = ns.ResolveBossToInstanceStrict(st)
          if category == "AMBIGUOUS" then
            table.insert(dropUnclassified, mountID)
          elseif category == "Raids" then
            table.insert(dropRaid, mountID)
          elseif category == "Dungeons" then
            table.insert(dropDungeon, mountID)
          elseif category then
            -- Unknown category: do NOT guess. Keep unclassified until an offline pack
            -- (or a future stricter resolver) can place it correctly.
            table.insert(dropUnclassified, mountID)
          else
            -- 3) Delve keyword (derived; fallback)
            if stNorm and stNorm:find("delve", 1, true) then
              table.insert(dropDelve, mountID)
            else
              -- Don't guess "Open World" for unknown drops.
              table.insert(dropUnclassified, mountID)
            end
          end
        else
          -- No EJ mapping available; fallback
          if stNorm and stNorm:find("delve", 1, true) then
            table.insert(dropDelve, mountID)
          else
            -- Don't guess "Open World" for unknown drops.
            table.insert(dropUnclassified, mountID)
          end
        end
      end
      end
    end
    end
  end

  -- Always include a deterministic "All Mounts"
  UpsertGeneratedGroup({
    id = "mounts:all",
    name = "All Mounts",
    category = "Mounts",
    expansion = "Account",
    mounts = all,
    sortIndex = MountSidebarIndex("All Mounts"),
  })

  -- Retired/unobtainable group from datapack (exclusive; removed from other buckets above)
  if type(unobtainable) == "table" and #unobtainable > 0 then
    table.sort(unobtainable)
    UpsertGeneratedGroup({
      id = "mounts:cat:unobtainable",
      name = "Unobtainable",
      category = "Mounts",
      expansion = "Source",
      mounts = unobtainable,
      sortIndex = MountSidebarIndex("Unobtainable"),
    })
  end

  -- Create one group per source type, stable IDs.
  for name, list in pairs(buckets) do
    table.sort(list)
    local gid = "mounts:source:" .. name:gsub("%s+", "_"):lower()
    UpsertGeneratedGroup({
      id = gid,
      name = name,
      category = "Mounts",
      expansion = "Source",
      mounts = list,
      sortIndex = MountSidebarIndex(name),
    })
  end

  -- Derived "Drop" breakdowns (strict; do not replace Blizzard-native Drop bucket).
  -- Derived "Drop" breakdowns (strict; do not replace Blizzard-native Drop bucket).
  local function UpsertDrop(id, name, list, forceCreate)
    if type(list) ~= "table" then list = {} end
    if (not forceCreate) and #list == 0 then return end
    table.sort(list)
    UpsertGeneratedGroup({
      id = id,
      name = name,
      category = "Mounts",
      expansion = "Source",
      mounts = list,
      sortIndex = MountSidebarIndex(name),
    })
  end

  UpsertDrop("mounts:drop:all", "Drops (All)", dropAll, true)
  UpsertDrop("mounts:drop:raid", "Drops (Raid)", dropRaid, true)
  UpsertDrop("mounts:drop:dungeon", "Drops (Dungeon)", dropDungeon, true)
  -- Delve/Open World drops are user-facing categories.
  -- Use non-":derived" IDs so they are not suppressed by the UI.
  UpsertDrop("mounts:drop:delve", "Drops (Delve)", dropDelve, true)
  UpsertDrop("mounts:drop:openworld", "Drops (Open World)", dropOpenWorld, true)
  -- "Drops (Unclassified)" is intentionally not surfaced in the Mounts sidebar.
  -- Unclassified drops remain tracked in stats for debugging, but not shown as a group.


-- ============================================================
-- Curated plural Drops system (datapack-driven; independent of Blizzard sourceType)
-- ============================================================
do
  local dropPack = ns.GetMountDropCategoriesPack and ns.GetMountDropCategoriesPack() or nil
  if dropPack and type(dropPack.map) == "table" then
    -- Empty-pack guard
    local hasAny = false
    for _ in pairs(dropPack.map) do hasAny = true break end

    if hasAny then
      local dpAll, dpRaid, dpDungeon, dpDelve, dpOpenWorld, dpUnclassified = {}, {}, {}, {}, {}, {}
      for _, mountID in ipairs(mountIDs) do
        local dropEntry = dropPack.map[mountID]
        if type(dropEntry) == "table" then
          table.insert(dpAll, mountID)
          local cat = dropEntry.cat or dropEntry.category
          if cat == "RAID" then
            table.insert(dpRaid, mountID)
          elseif cat == "DUNGEON" then
            table.insert(dpDungeon, mountID)
          elseif cat == "DELVE" then
            table.insert(dpDelve, mountID)
          elseif cat == "OPEN_WORLD" then
            table.insert(dpOpenWorld, mountID)
          else
            table.insert(dpUnclassified, mountID)
          end
        end
      end

      local function UpsertPluralDrops(id, name, list)
        if type(list) ~= "table" then list = {} end
        table.sort(list)
        UpsertGeneratedGroup({
      id = id,
      name = name,
      category = "Mounts",
      expansion = "Source",
      mounts = list,
      sortIndex = MountSidebarIndex(name),
    })
      end

      UpsertPluralDrops("mounts:drops:all", "Drops (All)", dpAll)
      UpsertPluralDrops("mounts:drops:raid", "Drops (Raid)", dpRaid)
      UpsertPluralDrops("mounts:drops:dungeon", "Drops (Dungeon)", dpDungeon)
      UpsertPluralDrops("mounts:drops:delve", "Drops (Delve)", dpDelve)
      UpsertPluralDrops("mounts:drops:openworld", "Drops (Open World)", dpOpenWorld)
      -- Do not surface "Drops (Unclassified)" in the Mounts sidebar.
    end
  end
end


  -- Optional: Curated multi-tag groups (pack-driven).
  --
  -- If a MountTags data pack is installed and contains mountTags entries,
  -- we create additional groups under the Mounts category.
  --
  -- IMPORTANT:
  -- * This does NOT change any existing grouping when the pack is empty.
  -- * A single mount may appear in multiple tag groups.
  local mountTagsPack = ns.GetMountTagsPack and ns.GetMountTagsPack() or nil
  if mountTagsPack and type(mountTagsPack.mountTags) == "table" then
    -- Detect "empty pack" cheaply.
    local hasAny = false
    for _ in pairs(mountTagsPack.mountTags) do
      hasAny = true
      break
    end

    if hasAny then
      -- Build a quick set of valid mountIDs from the journal snapshot so we
      -- don't surface stale IDs from older packs.
      local valid = {}
      for _, mid in ipairs(mountIDs) do valid[mid] = true end

      local tagBuckets = {}
      for mid, tags in pairs(mountTagsPack.mountTags) do
        mid = tonumber(mid)
        if mid and valid[mid] and type(tags) == "table" then
          for _, tagKey in ipairs(tags) do
            if type(tagKey) == "string" and tagKey ~= "" then
              tagBuckets[tagKey] = tagBuckets[tagKey] or {}
              table.insert(tagBuckets[tagKey], mid)
            end
          end
        end
      end

      for tagKey, list in pairs(tagBuckets) do
        if type(list) == "table" and #list > 0 then
          table.sort(list)

          local display = tagKey
          local sortIndex = 100
          if type(mountTagsPack.tags) == "table" and type(mountTagsPack.tags[tagKey]) == "table" then
            local t = mountTagsPack.tags[tagKey]
            if type(t.name) == "string" and t.name ~= "" then
              display = t.name
            end
            if tonumber(t.sort) then
              sortIndex = tonumber(t.sort)
            end
          end

          -- Skip redundant structural tags that are represented by Drops subcategories.
          local dispName = display
          if dispName == "Raid" or dispName == "Dungeon" or dispName == "Open World" then
            -- represented by Drops (Raid/Dungeon/Open World)
          else
            local canon = CanonMountGroupName(dispName)
            -- Merge into canonical buckets by NAME to prevent duplicates.
            AddToMountsGroupByName(canon, list)
          end
        end
      end
    end
  end
  -- Ensure all requested Mounts sidebar categories exist at least as empty placeholders.
  -- This is grouping metadata only; it does not affect Blizzard truth / collected state.
  do
    local want = {
      { id = "mounts:cat:reputation",    name = "Reputation" },
      { id = "mounts:cat:adventures",    name = "Adventures" },
      { id = "mounts:cat:class",         name = "Class" },
      { id = "mounts:cat:faction",       name = "Faction" },
      { id = "mounts:cat:race",          name = "Race" },
      { id = "mounts:cat:covenant_feature", name = "Covenant Feature" },
      { id = "mounts:cat:garrison_mission", name = "Garrison Mission" },
      { id = "mounts:cat:unobtainable",  name = "Unobtainable" },
      { id = "mounts:cat:uncategorized", name = "Uncategorized" },
      { id = "mounts:cat:secret",        name = "Secret" },
    }

    local existingIds, existingNames = {}, {}
    if CollectionLogDB and CollectionLogDB.generatedPack and type(CollectionLogDB.generatedPack.groups) == "table" then
      for _, g in ipairs(CollectionLogDB.generatedPack.groups) do
        if g and g.id then existingIds[tostring(g.id)] = true end
        if g and g.category == "Mounts" and type(g.name) == "string" then existingNames[g.name] = true end
      end
    end

    for _, w in ipairs(want) do
      if (not existingIds[w.id]) and (not existingNames[w.name]) then
        UpsertGeneratedGroup({
          id = w.id,
          name = w.name,
          category = "Mounts",
          expansion = "Source",
          mounts = {},
          sortIndex = MountSidebarIndex(w.name),
        })
      end
    end
  end



  -- ============================================================
  -- Manual Mount grouping overrides (Primary + Extra tags)
  -- Philosophy-safe: does NOT change collected truth; only display buckets.
  -- Stored in SavedVariables under CollectionLogDB.userOverrides.mounts
  -- Apply LAST so rebuilds never overwrite user decisions.
  -- ============================================================
  do
    if CollectionLogDB then
      CollectionLogDB.userOverrides = CollectionLogDB.userOverrides or {}
      local uo = CollectionLogDB.userOverrides
      uo.mounts = uo.mounts or {}
      if not uo.mounts.primary then uo.mounts.primary = {} end
      if not uo.mounts.extra then uo.mounts.extra = {} end

      local list = (CollectionLogDB.generatedPack and CollectionLogDB.generatedPack.groups) or nil
      if type(list) == "table" then
        local function RemoveMountFromList(t, mountID)
          if type(t) ~= "table" then return end
          for i = #t, 1, -1 do
            if tonumber(t[i]) == tonumber(mountID) then
              table.remove(t, i)
            end
          end
        end

        local function RemoveMountEverywhereExcept(mountID, keepSet)
          for _, g in ipairs(list) do
            if g and g.category == "Mounts" and type(g.mounts) == "table" and type(g.name) == "string" then
              local canon = CanonMountGroupName(g.name)
              if not keepSet[canon] then
                RemoveMountFromList(g.mounts, mountID)
              end
            end
          end
        end

        -- 1) Primary overrides
        for mountID, primaryName in pairs(uo.mounts.primary) do
          mountID = tonumber(mountID)
          if mountID and type(primaryName) == "string" and primaryName ~= "" then
            local primaryCanon = CanonMountGroupName(primaryName)
            local keep = { ["All Mounts"] = true }
            keep[primaryCanon] = true

            local extras = uo.mounts.extra[mountID]
            if type(extras) == "table" then
              for tagName, enabled in pairs(extras) do
                if enabled and type(tagName) == "string" then
                  keep[CanonMountGroupName(tagName)] = true
                end
              end
            end

            RemoveMountEverywhereExcept(mountID, keep)
            AddToMountsGroupByName(primaryCanon, { mountID })
          end
        end

        -- 2) Extra tags
        for mountID, tags in pairs(uo.mounts.extra) do
          mountID = tonumber(mountID)
          if mountID and type(tags) == "table" then
            for tagName, enabled in pairs(tags) do
              if enabled and type(tagName) == "string" and tagName ~= "" then
                local canon = CanonMountGroupName(tagName)
                if canon ~= "All Mounts" and canon ~= "Drops (All)" then
                  AddToMountsGroupByName(canon, { mountID })
                end
              end
            end
          end
        end

        -- 3) Recompute Drops (All)
        local function FindGroupByCanon(canonName)
          for _, g in ipairs(list) do
            if g and g.category == "Mounts" and type(g.name) == "string" then
              if CanonMountGroupName(g.name) == canonName then
                return g
              end
            end
          end
          return nil
        end

        local gAll = FindGroupByCanon("Drops (All)")
        if gAll and type(gAll.mounts) == "table" then
          local union, set = {}, {}
          local function AddFrom(canon)
            local gg = FindGroupByCanon(canon)
            if gg and type(gg.mounts) == "table" then
              for _, mid in ipairs(gg.mounts) do
                mid = tonumber(mid)
                if mid and not set[mid] then
                  set[mid] = true
                  table.insert(union, mid)
                end
              end
            end
          end
          AddFrom("Drops (Raid)")
          AddFrom("Drops (Dungeon)")
          AddFrom("Drops (Open World)")
          AddFrom("Drops (Delve)")
          table.sort(union)
          gAll.mounts = union
        end
      end
    end
  end







  -- ============================================================
  -- FINAL Mounts group normalization + suppression (canonical sidebar)
  -- Some generators/datapacks may append raw tag/source groups directly.
  -- Normalize ALL Mounts groups into your canonical buckets every rebuild:
  --  * Merge duplicate/variant names via CanonMountGroupName
  --  * Route legacy/noisy buckets into Uncategorized (or Quest)
  --  * Suppress any Mounts groups not in the canonical allowlist
  -- This guarantees old labels cannot "come back" after a rebuild.
  -- ============================================================
  do
    if CollectionLogDB and CollectionLogDB.generatedPack and type(CollectionLogDB.generatedPack.groups) == "table" then
      local groups = CollectionLogDB.generatedPack.groups

      -- Canonical allowlist (ONLY these appear in Mounts left panel)
      local ALLOW = {
        ["All Mounts"] = true,
        ["Drops (All)"] = true,
        ["Drops (Raid)"] = true,
        ["Drops (Dungeon)"] = true,
        ["Drops (Open World)"] = true,
        ["Drops (Delve)"] = true,
        ["Achievement"] = true,
        ["Adventures"] = true,
        ["Quest"] = true,
        ["Reputation"] = true,
        ["Profession"] = true,
        ["Class"] = true,
        ["Faction"] = true,
        ["Race"] = true,
        ["PvP"] = true,
        ["Vendor"] = true,
        ["World Event"] = true,
        ["Store"] = true,
        ["Trading Post"] = true,
        ["Promotion"] = true,
        ["Secret"] = true,
        ["Covenant Feature"] = true,
        ["Garrison Mission"] = true,
        ["Unobtainable"] = true,
        ["Uncategorized"] = true,
      }

      -- Collect all mounts into canonical buckets
      local buckets = {}  -- canonName -> { mounts = {..}, meta = firstGroup }
      local function bucketFor(canon)
        if not buckets[canon] then
          buckets[canon] = { mounts = {}, meta = nil }
        end
        return buckets[canon]
      end

      for _, g in ipairs(groups) do
        if g and g.category == "Mounts" and type(g.name) == "string" and type(g.mounts) == "table" then
          local canon = CanonMountGroupName(g.name)
          -- Anything that canonicalizes to a non-allowed bucket goes to Uncategorized
          if not ALLOW[canon] then
            canon = "Uncategorized"
          end
          local b = bucketFor(canon)
          if not b.meta then
            b.meta = g
          end
          MergeUniqueMountIDs(b.mounts, g.mounts)
        end
      end

      -- Rebuild Mounts groups list in canonical order, preserving other categories
      local newGroups = {}
      for _, g in ipairs(groups) do
        if not (g and g.category == "Mounts") then
          table.insert(newGroups, g)
        end
      end

      -- Emit canonical Mounts groups in sidebar order
      local ordered = {
        "All Mounts",
        "Drops (All)",
        "Drops (Raid)",
        "Drops (Dungeon)",
        "Drops (Open World)",
        "Drops (Delve)",
        "Achievement",
        "Adventures",
        "Quest",
        "Reputation",
        "Profession",
        "Class",
        "Faction",
        "Race",
        "PvP",
        "Vendor",
        "World Event",
        "Store",
        "Trading Post",
        "Promotion",
        "Secret",
        "Garrison Mission",
        "Covenant Feature",
        "Unobtainable",
        "Uncategorized",
      }

      for _, name in ipairs(ordered) do
        local b = buckets[name]
        if b and type(b.mounts) == "table" then
          -- Always keep your canonical buckets, even if empty, so order is stable.
          local gg = b.meta or { category = "Mounts", name = name, mounts = {} }
          gg.category = "Mounts"
          gg.name = name
          gg.mounts = b.mounts
          gg.sortIndex = MountSidebarIndex(name)
          table.insert(newGroups, gg)
        else
          -- Create empty placeholder to keep UI order stable
          table.insert(newGroups, { category = "Mounts", name = name, mounts = {}, sortIndex = MountSidebarIndex(name) })
        end
      end

      CollectionLogDB.generatedPack.groups = newGroups
    end
  end
  -- Debug helper for quick verification
  ns._lastMountDropStats = {
    total = #dropAll,
    raid = #dropRaid,
    dungeon = #dropDungeon,
    delve = #dropDelve,
    openworld = #dropOpenWorld,
    unclassified = #dropUnclassified,
  }

  -- MJE-style Mount sidebar groups (curated Source + Expansion buckets)
  do
    if CollectionLogDB and CollectionLogDB.generatedPack and type(CollectionLogDB.generatedPack.groups) == "table" then
      local groups = CollectionLogDB.generatedPack.groups
      for i = #groups, 1, -1 do
        local g = groups[i]
        local gid = g and g.id and tostring(g.id) or ""
        if g and g.category == "Mounts" and gid ~= "mounts:all" and (gid:find("^mounts:mje:source:") or gid:find("^mounts:mje:exp:")) then
          table.remove(groups, i)
        end
      end

      local sourceBuckets, expBuckets = {}, {}
      for _, mountID in ipairs(mountIDs) do
        local ok, _, spellID, _, _, _, sourceType = pcall(C_MountJournal.GetMountInfoByID, mountID)
        if ok and mountID then
          local sname, sidx = GetMJESourceGroup(spellID, sourceType)
          local ename, eidx = GetMJEExpansionGroup(mountID)
          local sourceOverride, expansionOverride = GetMountManualMJEOverrides(mountID)
          if type(sourceOverride) == "string" and sourceOverride ~= "" then
            sname = sourceOverride
            sidx = MJE_MOUNT_SOURCE_SORT[sname] or 900
          end
          if type(expansionOverride) == "string" and expansionOverride ~= "" then
            ename = expansionOverride
            for _, entry in ipairs(MJE_MOUNT_EXPANSIONS) do
              if entry.name == ename then
                eidx = 1000 - tonumber(entry.key or 0)
                break
              end
            end
          end

          if sname and sname ~= "" then
            local skey = sname:lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
            local sb = sourceBuckets[skey]
            if not sb then
              sb = { id = "mounts:mje:source:" .. skey, name = sname, category = "Mounts", expansion = "Source", sortIndex = sidx or 900, mounts = {} }
              sourceBuckets[skey] = sb
            end
            table.insert(sb.mounts, mountID)
          end

          if ename and ename ~= "" then
            local ekey = ename:lower():gsub("[^a-z0-9]+", "_"):gsub("^_+", ""):gsub("_+$", "")
            local eb = expBuckets[ekey]
            if not eb then
              eb = { id = "mounts:mje:exp:" .. ekey, name = ename, category = "Mounts", expansion = ename, sortIndex = eidx or 0, mounts = {} }
              expBuckets[ekey] = eb
            end
            table.insert(eb.mounts, mountID)
          end
        end
      end

      for _, bucket in pairs(sourceBuckets) do
        if type(bucket.mounts) == "table" and #bucket.mounts > 0 then
          table.sort(bucket.mounts)
          UpsertGeneratedGroup(bucket)
        end
      end
      for _, bucket in pairs(expBuckets) do
        if type(bucket.mounts) == "table" and #bucket.mounts > 0 then
          table.sort(bucket.mounts)
          UpsertGeneratedGroup(bucket)
        end
      end
    end
  end

  if ns.RebuildGroupIndex then
    ns.RebuildGroupIndex()
  end
  ns._clogMountsBuiltCount = #mountIDs
  ns._clogMountsBuiltAt = (GetTime and GetTime()) or 0
  return true

end

function ns.EnsureMountsGroups()
  local ok = ns._TryBuildMountsGroups and ns._TryBuildMountsGroups()
  if ok then
    NotifyCollectionsUIUpdated("Mounts")
    return ok
  end

  -- If the Mount Journal isn't ready yet, wait for Blizzard to populate it.
  EnsureMountsEventFrame()
  -- Register the known mount journal update events (pcall avoids hard errors on builds missing an event).
  local function SafeReg(ev) pcall(mountFrame.RegisterEvent, mountFrame, ev) end
  SafeReg("MOUNT_JOURNAL_LIST_UPDATE")
  SafeReg("MOUNT_JOURNAL_COLLECTION_UPDATED")
  SafeReg("MOUNT_JOURNAL_USABILITY_CHANGED")
  SafeReg("NEW_MOUNT_ADDED")

  return nil
end

-- ============================================================================
-- Debug: Drop classification summary (Mount Journal)
-- Usage: /clogmountsdrop
-- ============================================================================
function ns.DebugDumpMountDrops()
  EnsureCollectionsLoaded()
  local stats = ns._lastMountDropStats
  if not stats then
    if ns.EnsureMountsGroups then pcall(ns.EnsureMountsGroups) end
    stats = ns._lastMountDropStats
  end

  local function Print(msg)
    if ns and ns.Print then ns.Print(msg) else print("|cff00ff99Collection Log|r: " .. tostring(msg)) end
  end

  if not stats then
    Print("No mount drop stats available yet. Open the Mounts tab once and try again.")
    return
  end

  Print(("Mount Drop Classification (strict): total=%d raid=%d dungeon=%d delve=%d openworld=%d unclassified=%d"):format(
    stats.total or 0, stats.raid or 0, stats.dungeon or 0, stats.delve or 0, stats.openworld or 0, stats.unclassified or 0
  ))
end

-- NOTE: Plural Drops groups are generated inside ns.EnsureMountsGroups() where we have access
-- to the current Mount Journal snapshot. We intentionally avoid generating them here.