-- Localization table. English is the default language: a missing translation
-- simply shows the English text used as the key.
local _, ns = ...
ns.L = setmetatable({}, { __index = function(_, key) return key end })
