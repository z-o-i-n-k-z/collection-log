-- LibStub (minimal)
-- This is a small, compatible implementation of LibStub.

local LIBSTUB_MAJOR, LIBSTUB_MINOR = "LibStub", 2

local LibStub = _G[LIBSTUB_MAJOR]

if not LibStub or (LibStub.minor or 0) < LIBSTUB_MINOR then
  LibStub = LibStub or {}
  _G[LIBSTUB_MAJOR] = LibStub
  LibStub.minor = LIBSTUB_MINOR

  LibStub.libs = LibStub.libs or {}
  LibStub.minors = LibStub.minors or {}

  function LibStub:NewLibrary(major, minor)
    assert(type(major) == "string", "NewLibrary: major must be a string")
    assert(type(minor) == "number", "NewLibrary: minor must be a number")

    local oldminor = self.minors[major]
    if oldminor and oldminor >= minor then
      return nil
    end

    self.minors[major] = minor
    self.libs[major] = self.libs[major] or {}
    return self.libs[major], oldminor
  end

  function LibStub:GetLibrary(major, silent)
    if self.libs[major] then
      return self.libs[major]
    end
    if silent then return nil end
    error("LibStub: library \"" .. tostring(major) .. "\" not found", 2)
  end

  setmetatable(LibStub, {
    __call = function(self, major, silent)
      return self:GetLibrary(major, silent)
    end,
  })
end
