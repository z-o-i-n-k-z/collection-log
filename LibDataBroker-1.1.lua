-- LibDataBroker-1.1 (minimal)
-- Enough for launcher objects used by LibDBIcon and button bars.

local LibStub = _G.LibStub
if not LibStub then return end

-- NOTE: Bundled *minimal fallback* copy. MINOR is intentionally low so upstream libs win.
local MAJOR, MINOR = "LibDataBroker-1.1", 0
local LDB, oldminor = LibStub:NewLibrary(MAJOR, MINOR)
if not LDB then return end

LDB.dataobjects = LDB.dataobjects or {}

function LDB:NewDataObject(name, data)
  assert(type(name) == "string", "NewDataObject: name must be a string")
  assert(type(data) == "table", "NewDataObject: data must be a table")

  if self.dataobjects[name] then
    -- Overwrite/update existing object
    for k,v in pairs(data) do
      self.dataobjects[name][k] = v
    end
    return self.dataobjects[name]
  end

  data.name = name
  self.dataobjects[name] = data
  return data
end

function LDB:GetDataObjectByName(name)
  return self.dataobjects[name]
end
