--[[
Stand-in for the ornament deck, removed with the ornaments in 1.3.1: the
shelf's page-state bookkeeping still asks it for a starting state, which is
now always empty and never deals anything.
--]]
local M = {}
function M.epoch() return 0 end
function M.generation() return 0 end
function M.levelOf() return "off" end
function M.newState() return { n = 0, shelf = 0, bnd = 0 } end
function M.copyState(st)
    local out = {}
    for k, v in pairs(st or {}) do out[k] = v end
    return out
end
function M.shuffle() end
function M.sync() end
function M.order() return {} end
function M.dealer(st) return { state = st, next = function() return nil end } end
function M.fillHooks() return nil end
return M
