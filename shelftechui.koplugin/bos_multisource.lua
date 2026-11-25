--[[
A chip with books from several places at once: the Home library, folders,
the Kindle's own library (Kindle Virtual Library), Favorites, Recent... in one
shelf, sorted and filtered together as the chip says.

It's a Home source (lib/bookshelf_sources, list mode) called "stui_multi".
Pick it in the chip editor: Source → More → Several sources. A shelf of it
stores what it combines as source.parts, each the source a chip of its own
would have:

  { kind = "library" }                     the Home library, all of it
  { kind = "folder_flat", id = "/path" }   one folder and everything under it
  { kind = "kindle" }                      the Kindle Virtual Library
  { kind = "favorites" }, { kind = "recent" }, and any other registered source
  that lists its books (the Kobo library, say)

How the books are gathered (M.books): each part is asked as a chip of its own
would be: a registered source through Sources.list, a built-in one through
Repo.getBySource (light records: covers are drawn only for the page on screen,
by M.cover). A book that two parts both hold (a folder inside the library, say)
is kept once, from the first part that has it. Kindle books keep their own
source, so opening one goes through the Kindle's own way of opening books; the
others are plain files on the device (source_kind = false: no source claims
them), opened and edited like any other.

  M.register()         once, at start (main.lua)
  M.SOURCE             "stui_multi"
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local M = { SOURCE = "stui_multi" }

local function Sources() return require("lib/bookshelf_sources") end

-- The built-in places a part can be, in the picker's order.
local BUILTIN = {
    { kind = "library", label = function() return _("Home library") end },
    { kind = "favorites", label = function() return _("Favorites") end },
    { kind = "recent", label = function() return _("Recently read") end },
}

local function partKey(p)
    return tostring(p.kind) .. "|" .. tostring(p.id or "")
end

--- A part's name: "Home library", "Kindle Virtual Library", "Folder: Books".
function M.partLabel(p)
    for _i, b in ipairs(BUILTIN) do if b.kind == p.kind then return b.label() end end
    if p.kind == "folder_flat" or p.kind == "folder" then
        return T(_("Folder: %1"), (tostring(p.id or ""):gsub("/+$", ""):match("([^/]+)$") or p.id or "/"))
    end
    return Sources().label(p.kind) or p.kind
end

-- Every registered source that lists its books, can be used here, and isn't
-- this one or a remote/Hardcover one.
local function otherListSources()
    local out = {}
    local S = Sources()
    for _i, id in ipairs(S.ids()) do
        local spec = S.get(id)
        if id ~= M.SOURCE and spec and spec.list and not spec.remote_prefix and S.isAvailable(id) then
            out[#out + 1] = id
        end
    end
    return out
end

local function copy(b)
    local c = {}
    for k, v in pairs(b) do c[k] = v end
    return c
end

-- One part's books, as fresh tables.
local function partBooks(part)
    local S = Sources()
    if S.get(part.kind) then
        -- (a registered source: its records keep their own source_kind)
        return S.list(part.kind, part) or {}
    end
    local Repo = require("lib/bookshelf_book_repository")
    local ok, books = pcall(Repo.getBySource, part, nil, nil, 0, 1000000, { light_only = true })
    if not ok then
        logger.warn("ShelfTechUI: several sources:", M.partLabel(part), books)
        return {}
    end
    local out = {}
    for _i, b in ipairs(type(books) == "table" and books or {}) do
        if type(b) == "table" and type(b.filepath) == "string" and not b.is_folder
                and not b.filepath:match("^%a+://") then
            local c = copy(b)
            -- (a file on the device: no source claims it, so it's opened,
            -- edited and covered like any other book)
            c.source_kind = false
            c._stui_local = true
            out[#out + 1] = c
        end
    end
    return out
end

--- Every book of a shelf of several sources, each once.
function M.books(source)
    local out, seen = {}, {}
    for _i, part in ipairs(type(source) == "table" and type(source.parts) == "table" and source.parts or {}) do
        if type(part) == "table" and part.kind and part.kind ~= M.SOURCE then
            for _j, b in ipairs(partBooks(part)) do
                local key = b.filepath or (b.title or "") .. "\0" .. tostring(b.authors or b.author or "")
                if not seen[key] then
                    seen[key] = true
                    out[#out + 1] = b
                end
            end
        end
    end
    return out
end

--- The cover of a book on the page on screen. A file on the device: its
--- cover from KOReader's cover cache (the shelf frees it after painting).
--- A Kindle book draws its own (cover_image_path).
function M.cover(rec)
    if not (rec and rec._stui_local and type(rec.filepath) == "string") then return nil end
    local okB, BIM = pcall(require, "bookinfomanager")
    if not (okB and BIM and BIM.getBookInfo) then return nil end
    local ok, info = pcall(BIM.getBookInfo, BIM, rec.filepath, true)
    if ok and type(info) == "table" and info.cover_bb then
        return info.cover_bb, info.cover_w, info.cover_h
    end
    return nil
end

-- The picker: tick the places to combine, add folders, Done.
local function pickParts(draft, done)
    local ButtonDialog = require("ui/widget/buttondialog")
    local S = Sources()
    local parts = {}
    for _i, p in ipairs(type(draft.source) == "table" and type(draft.source.parts) == "table" and draft.source.parts or {}) do
        parts[#parts + 1] = copy(p)
    end
    local dlg
    local function has(p)
        for i, q in ipairs(parts) do if partKey(q) == partKey(p) then return i end end
    end
    local function show()
        local rows = {}
        local function toggleRow(p)
            local on = has(p) ~= nil
            rows[#rows + 1] = { { text = (on and "\u{2713} " or "    ") .. M.partLabel(p), align = "left", callback = function()
                local i = has(p)
                if i then table.remove(parts, i) else parts[#parts + 1] = p end
                UIManager:close(dlg)
                show()
            end } }
        end
        for _i, b in ipairs(BUILTIN) do toggleRow({ kind = b.kind }) end
        for _i, id in ipairs(otherListSources()) do toggleRow({ kind = id }) end
        -- folders chosen so far (tap one to leave it out)
        for _i, p in ipairs(parts) do
            if p.kind == "folder_flat" then toggleRow(p) end
        end
        rows[#rows + 1] = { { text = _("Add a folder…"), align = "left", callback = function()
            UIManager:close(dlg)
            local home = G_reader_settings:readSetting("home_dir") or "/"
            require("bos_folders").choose(home, function(path)
                if path and not has({ kind = "folder_flat", id = path }) then
                    parts[#parts + 1] = { kind = "folder_flat", id = path }
                end
                show()
            end, _("A folder for this shelf"))
        end } }
        rows[#rows + 1] = {
            { text = _("Cancel"), callback = function() UIManager:close(dlg) done(false) end },
            { text = _("Done"), enabled = #parts > 0, callback = function()
                UIManager:close(dlg)
                draft.source = { kind = M.SOURCE, parts = parts }
                done()
            end },
        }
        dlg = ButtonDialog:new{
            title = #parts == 0 and _("Books from these places, in one shelf:")
                or T(_("Books from %1 places, in one shelf:"), #parts),
            title_align = "left",
            buttons = rows,
        }
        UIManager:show(dlg)
    end
    show()
end

--- The shelf's places, in a word: "Kindle Virtual Library + Home library".
function M.describe(source)
    local names = {}
    for _i, p in ipairs(type(source) == "table" and type(source.parts) == "table" and source.parts or {}) do
        names[#names + 1] = M.partLabel(p)
    end
    return table.concat(names, " + ")
end

function M.register()
    local okS, S = pcall(Sources)
    if not okS or S.get(M.SOURCE) then return end
    local ok, err = S.register(M.SOURCE, {
        api = 1,
        label = function() return _("Several sources") end,
        available = function() return true end,
        list = function(source) return M.books(source) end,
        cover = function(rec) return M.cover(rec) end,
        pick = function(draft, done) pickParts(draft, done) end,
        sort_default = { { key = "title", reverse = false } },
        -- (claims nothing: its books belong to the places they came from)
        owns = function() return false end,
    })
    if not ok then logger.warn("ShelfTechUI: several sources not registered:", err) end
end

return M
