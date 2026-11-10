-- Glimpse scanner: finds reference-worthy images inside a book.
--
-- Pure Lua (5.1/LuaJIT compatible), no KOReader requires, so it can be
-- unit-tested headlessly (see builder/). Two source formats:
--   EPUB  the caller injects `read_file(archive_path) -> string|nil`; the
--         scan parses the container/OPF/HTML and reads image files by path.
--   FB2   a single XML file passed in whole; images are base64 <binary>
--         blocks the scan decodes itself. The viewer reads bytes back with
--         M.fb2_read_binary(fb2, id).
--
-- Pipeline:
--   M.scan(read_file)          -> { images = {...}, spine_count, opf_path }
--   M.scan_fb2(fb2_text)       -> { images = {...}, spine_count, format }
--   M.filter(images, level)    -> included_list, stats
--
-- Each image record:
--   path         archive path (URL-decoded, normalized)
--   spine_index  1-based index of the FIRST spine document referencing it
--   order        running number of first appearance (stable sort key)
--   files_count  number of distinct spine documents referencing it
--   total_count  total number of <img>/<image> occurrences
--   width/height pixel dimensions parsed from the file header (may be nil)
--   format       "png"|"jpeg"|"gif"|"webp"|"bmp"|"svg"|nil
--   bytes        file size in the archive
--   caption      best human caption (figcaption > title attr > alt) or nil
--   alt, title_attr, classes, in_figure, attr_width, attr_height
--   is_cover     flagged as the book cover by the OPF
--   is_svg_doc   the image IS a whole SVG spine document

local M = {}



M.VERSION = 5



local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function collapse_ws(s)
    return (s:gsub("%s+", " "))
end

local function url_decode(s)
    return (s:gsub("%%(%x%x)", function(h)
        return string.char(tonumber(h, 16))
    end))
end

local function xml_unescape(s)
    s = s:gsub("&#x(%x+);", function(h)
        local n = tonumber(h, 16)
        return (n and n < 128) and string.char(n) or ""
    end)
    s = s:gsub("&#(%d+);", function(d)
        local n = tonumber(d)
        return (n and n < 128) and string.char(n) or ""
    end)
    s = s:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
    s = s:gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&nbsp;", " ")
    return s
end



local function resolve_path(base_dir, href)
    local path = href
    if not path:match("^/") and base_dir ~= "" then
        path = base_dir .. "/" .. path
    end
    path = path:gsub("^/+", "")
    local parts = {}
    for seg in path:gmatch("[^/]+") do
        if seg == ".." then
            if #parts > 0 then table.remove(parts) end
        elseif seg ~= "." then
            parts[#parts + 1] = seg
        end
    end
    return table.concat(parts, "/")
end

local function dir_of(path)
    return path:match("^(.*)/[^/]*$") or ""
end



local function attr(tag, name)
    local pat = {}
    for c in name:gmatch(".") do
        if c:match("%a") then
            pat[#pat + 1] = "[" .. c:lower() .. c:upper() .. "]"
        else
            pat[#pat + 1] = c:gsub("(%W)", "%%%1")
        end
    end
    local n = table.concat(pat)
    local v = tag:match(n .. '%s*=%s*"([^"]*)"')
          or tag:match(n .. "%s*=%s*'([^']*)'")
          or tag:match(n .. "%s*=%s*([^%s>\"']+)")
    if v then return xml_unescape(v) end
end


local function px(v)
    if not v then return nil end
    local n = v:match("^%s*(%d+%.?%d*)%s*[pP]?[xX]?%s*$")
    n = n and tonumber(n)
    if n and n > 0 then return math.floor(n + 0.5) end
end



local function be16(s, i)
    local a, b = s:byte(i, i + 1)
    if not b then return nil end
    return a * 256 + b
end

local function le16(s, i)
    local a, b = s:byte(i, i + 1)
    if not b then return nil end
    return b * 256 + a
end

local function be32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return ((a * 256 + b) * 256 + c) * 256 + d
end

local function le24(s, i)
    local a, b, c = s:byte(i, i + 2)
    if not c then return nil end
    return (c * 256 + b) * 256 + a
end

local function le32(s, i)
    local a, b, c, d = s:byte(i, i + 3)
    if not d then return nil end
    return ((d * 256 + c) * 256 + b) * 256 + a
end



local B64_DEC = {}
do
    local a = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    for i = 1, #a do B64_DEC[a:byte(i)] = i - 1 end
end



function M.b64decode(s)
    if type(s) ~= "string" then return "" end
    local dec = B64_DEC
    local byte, char, concat = string.byte, string.char, table.concat
    local floor = math.floor
    local out, op = {}, 0
    local chunk, cp = {}, 0
    local acc, nbits = 0, 0
    for k = 1, #s do
        local c = byte(s, k)
        if c == 61 then break end
        local v = dec[c]
        if v then
            acc = acc * 64 + v
            nbits = nbits + 6
            if nbits >= 8 then
                nbits = nbits - 8
                local shift = 2 ^ nbits
                cp = cp + 1
                chunk[cp] = char(floor(acc / shift) % 256)
                acc = acc % shift
                if cp >= 8192 then
                    op = op + 1
                    out[op] = concat(chunk, "", 1, cp)
                    cp = 0
                end
            end
        end
    end
    if cp > 0 then op = op + 1; out[op] = concat(chunk, "", 1, cp) end
    return concat(out, "", 1, op)
end


local function fb2_binary_body(fb2, id)
    for tag, body in fb2:gmatch("<[bB]inary(.-)>(.-)</[bB]inary>") do
        if attr(tag, "id") == id then return body end
    end
    return nil
end



function M.fb2_read_binary(fb2, id)
    local body = fb2_binary_body(fb2, id)
    if not body then return nil end
    return M.b64decode(body)
end



local function dims_png(d)
    if #d < 24 or d:sub(1, 8) ~= "\137PNG\r\n\26\n" then return nil end
    if d:sub(13, 16) ~= "IHDR" then return nil end
    return be32(d, 17), be32(d, 21)
end

local function dims_gif(d)
    if #d < 10 or (d:sub(1, 6) ~= "GIF87a" and d:sub(1, 6) ~= "GIF89a") then
        return nil
    end
    return le16(d, 7), le16(d, 9)
end

local function dims_jpeg(d)
    if #d < 4 or d:byte(1) ~= 0xFF or d:byte(2) ~= 0xD8 then return nil end
    local i = 3
    while i + 3 <= #d do
        if d:byte(i) ~= 0xFF then return nil end

        while d:byte(i + 1) == 0xFF and i + 1 < #d do i = i + 1 end
        local marker = d:byte(i + 1)
        if not marker then return nil end
        if marker == 0xD8 or marker == 0x01
           or (marker >= 0xD0 and marker <= 0xD7) then
            i = i + 2
        elseif marker == 0xD9 or marker == 0xDA then
            return nil
        else
            local len = be16(d, i + 2)
            if not len or len < 2 then return nil end

            if marker >= 0xC0 and marker <= 0xCF
               and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                local h, w = be16(d, i + 5), be16(d, i + 7)
                if w and h then return w, h end
                return nil
            end
            i = i + 2 + len
        end
    end
    return nil
end

local function dims_webp(d)
    if #d < 30 or d:sub(1, 4) ~= "RIFF" or d:sub(9, 12) ~= "WEBP" then
        return nil
    end
    local fourcc = d:sub(13, 16)
    if fourcc == "VP8X" then
        local w, h = le24(d, 25), le24(d, 28)
        if w and h then return w + 1, h + 1 end
    elseif fourcc == "VP8 " then
        if d:byte(24) == 0x9D and d:byte(25) == 0x01 and d:byte(26) == 0x2A then
            local w, h = le16(d, 27), le16(d, 29)
            if w and h then return w % 16384, h % 16384 end
        end
    elseif fourcc == "VP8L" then
        if d:byte(21) == 0x2F then
            local b0, b1, b2, b3 = d:byte(22, 25)
            if b3 then
                local w = b0 + (b1 % 64) * 256 + 1
                local h = math.floor(b1 / 64) + b2 * 4 + (b3 % 16) * 1024 + 1
                return w, h
            end
        end
    end
    return nil
end

local function dims_bmp(d)
    if #d < 26 or d:sub(1, 2) ~= "BM" then return nil end
    local w, h = le32(d, 19), le32(d, 23)
    if w and h and w > 0 then return w, math.abs(h) end
end

local function svg_len(v)
    if not v then return nil end
    local n, unit = v:match("^%s*(%d+%.?%d*)%s*(%a*)%s*$")
    n = n and tonumber(n)
    if not n or n <= 0 then return nil end
    if unit == "" or unit == "px" then return math.floor(n + 0.5) end
    if unit == "pt" then return math.floor(n * 96 / 72 + 0.5) end
    if unit == "in" then return math.floor(n * 96 + 0.5) end
    if unit == "cm" then return math.floor(n * 96 / 2.54 + 0.5) end
    if unit == "mm" then return math.floor(n * 9.6 / 2.54 + 0.5) end
    return nil
end

local function dims_svg(d)
    local head = d:sub(1, 4096)
    local lower = head:lower()
    local s = lower:find("<svg")
    if not s then return nil end
    local e = lower:find(">", s, true)
    local tag = head:sub(s, e or #head)
    local w = svg_len(attr(tag, "width"))
    local h = svg_len(attr(tag, "height"))
    if w and h then return w, h end
    local vb = attr(tag, "viewBox") or attr(tag, "viewbox")
    if vb then
        local _, _, vw, vh = vb:match("([%d%.%-]+)[%s,]+([%d%.%-]+)[%s,]+([%d%.%-]+)[%s,]+([%d%.%-]+)")
        vw, vh = tonumber(vw), tonumber(vh)
        if vw and vh and vw > 0 and vh > 0 then
            return math.floor(vw + 0.5), math.floor(vh + 0.5)
        end
    end
    return nil
end


function M.get_image_dimensions(data)
    if type(data) ~= "string" or #data == 0 then return nil, nil, nil end
    local w, h
    w, h = dims_png(data)  if w then return w, h, "png" end
    w, h = dims_jpeg(data) if w then return w, h, "jpeg" end
    w, h = dims_gif(data)  if w then return w, h, "gif" end
    w, h = dims_webp(data) if w then return w, h, "webp" end
    w, h = dims_bmp(data)  if w then return w, h, "bmp" end
    w, h = dims_svg(data)
    if data:sub(1, 512):lower():find("<svg") or (w and h) then
        return w, h, "svg"
    end
    return nil, nil, nil
end





local function strip_ns(xml)
    return (xml:gsub("<(%/?)[%w_%-]+:", "<%1"))
end

function M.parse_container(xml)
    if not xml then return nil end
    xml = strip_ns(xml)

    for tag in xml:gmatch("<[rR][oO][oO][tT][fF][iI][lL][eE][^>]*>") do
        local p = attr(tag, "full-path")
        if p and p ~= "" then return resolve_path("", p) end
    end
    return nil
end


function M.parse_opf(xml, opf_dir)
    xml = strip_ns(xml)
    local items = {}
    for tag in xml:gmatch("<[iI][tT][eE][mM][%s/][^>]*>") do
        local id = attr(tag, "id")
        local href = attr(tag, "href")
        if id and href then
            items[id] = {
                href = href,
                media = (attr(tag, "media-type") or ""):lower(),
                properties = (attr(tag, "properties") or ""):lower(),
            }
        end
    end

    local cover_path

    for _, it in pairs(items) do
        if it.properties:find("cover%-image") then
            cover_path = resolve_path(opf_dir, url_decode(it.href))
            break
        end
    end

    if not cover_path then
        for tag in xml:gmatch("<[mM][eE][tT][aA][%s/][^>]*>") do
            local name = attr(tag, "name")
            if name and name:lower() == "cover" then
                local it = items[attr(tag, "content") or ""]
                if it then
                    cover_path = resolve_path(opf_dir, url_decode(it.href))
                end
                break
            end
        end
    end

    local spine = {}
    local spine_block = xml:match("<[sS][pP][iI][nN][eE][%s>].-</[sS][pP][iI][nN][eE]%s*>")
                     or xml
    for tag in spine_block:gmatch("<[iI][tT][eE][mM][rR][eE][fF][%s/][^>]*>") do
        local it = items[attr(tag, "idref") or ""]
        if it then
            spine[#spine + 1] = {
                path = resolve_path(opf_dir, url_decode(it.href)),
                raw_path = resolve_path(opf_dir, it.href),
                media = it.media,
            }
        end
    end



    local guide = {}
    local guide_block = xml:match("<[gG][uU][iI][dD][eE][%s>].-</[gG][uU][iI][dD][eE]%s*>")
    if guide_block then
        for tag in guide_block:gmatch("<[rR][eE][fF][eE][rR][eE][nN][cC][eE][%s/][^>]*>") do
            local href = attr(tag, "href")
            local rtype = attr(tag, "type")
            if href and rtype then
                local p = resolve_path(opf_dir,
                    url_decode((href:gsub("#.*$", ""):gsub("%?.*$", ""))))
                guide[p] = rtype:lower()
            end
        end
    end

    return { spine = spine, cover_path = cover_path, guide = guide }
end



local function is_html_media(media, path)
    if media:find("html") or media:find("xml%+xhtml") then return true end
    return path:lower():match("%.x?html?$") ~= nil
end

local function is_svg_media(media, path)
    return media:find("svg") ~= nil or path:lower():match("%.svg$") ~= nil
end


local function find_figures(lower, html)
    local figures = {}
    local init = 1
    while true do
        local s = lower:find("<figure%f[%W]", init)
        if not s then break end
        local e = lower:find("</figure%s*>", s)
        if not e then break end
        local block_l = lower:sub(s, e)
        local caption
        local cs, _, p1 = block_l:find("<figcaption[^>]*>()")
        if cs then
            local p2 = block_l:find("</figcaption", p1)
            if p2 then
                local raw = html:sub(s + p1 - 1, s + p2 - 2)
                caption = trim(collapse_ws(xml_unescape(raw:gsub("<[^>]->", " "))))
                if caption == "" then caption = nil end
            end
        end
        figures[#figures + 1] = { s = s, e = e, caption = caption }
        init = e + 1
    end
    return figures
end



function M.meaningful_text(s)
    if type(s) ~= "string" then return nil end
    s = trim(collapse_ws(s))
    if #s < 4 then return nil end
    local l = s:lower():gsub("^%p+", ""):gsub("%p+$", "")
    if l:match("^%S+%.%w%w%w?%w?$") then return nil end
    if l:match("^images?%s*%d*$") or l:match("^img[%s_%-%d]*$") then return nil end
    if l:match("^photos?%s*%d*$") or l:match("^pictures?%s*%d*$") then return nil end
    if l:match("^picture%s*%d*$") or l:match("^illustration%s*%d*$") then return nil end
    if l:match("^cover") then return nil end
    if l:match("^%d+$") then return nil end
    return s
end





function M.decorative_caption(s)
    if type(s) ~= "string" then return false end
    local l = trim(collapse_ws(s)):lower()
    l = l:gsub("\226\128\153", "'")



    if l:match("%f[%a]novel%f[%A]") and l:find(" by ", 1, true) then
        return true
    end


    if l:match("%f[%a]logo%f[%A]") or l:find("back ad", 1, true)
       or l:match("%f[%a]advertisement%f[%A]") or l:match("%f[%a]advert%f[%A]") then
        return true
    end


    for _, pub in ipairs({
        "penguin", "random house", "harpercollins", "harper collins",
        "macmillan", "hachette", "simon & schuster", "simon and schuster",
        "bloomsbury", "scholastic", "knopf", "doubleday", "scribner",
        "picador", "tor books", "tor publishing", "del rey", "st%. martin",
        "little, brown", "houghton", "w%. w%. norton", "faber", "berkley",
        "bantam", "ballantine", "redhook", "red tower", "grand central",
        "gallery books", "atria", "riverhead", "putnam", "dutton",
        "sourcebooks", "entangled publishing",
    }) do
        if l:match("^" .. pub .. "%f[%W]") then return true end
    end
    return (l:match("^chapter%f[%W]") or l:match("^part%f[%W]")
        or l:match("^book%s+%w+$") or l:match("^a note%f[%W]")
        or l:match("^prologue") or l:match("^epilogue") or l:match("^interlude")
        or l:match("^introduction") or l:match("^foreword") or l:match("^preface")
        or l:match("^afterword") or l:match("^appendix") or l:match("^acknowledg")
        or l:match("^contents") or l:match("^table of contents")
        or l:match("^dedication") or l:match("^epigraph")
        or l:match("^author.?s note")
        or l:match("^book title") or l:match("^title page")
        or l:match("^half.?title") or l:match("^also by%f[%W]")
        or l:match("^by the same author")) and true or false
end







function M.decorative_name(path)
    local base = (path:match("[^/]+$") or path):lower()
    return (base:match("%f[%a]author%f[%A]") or base:match("%f[%a]logo%f[%A]")
        or base:match("%f[%a]publisher") or base:match("%f[%a]colophon")
        or base:match("%f[%a]copyright") or base:match("half.?title")
        or base:match("title.?page") or base:match("%f[%a]title%d*%.%w+$")
        or base:match("%f[%a]backad") or base:match("%f[%a]newsletter")
        or base:match("%f[%a]signup") or base:match("%f[%a]endpaper")
        or base:match("%f[%a]tp%f[%A]") or base:match("%f[%a]cvi%f[%A]")
        or base:match("%f[%a]cop%f[%A]") or base:match("%f[%a]adc%f[%A]")
        or base:match("%f[%a]ata%f[%A]")) and true or false
end




function M.figure_name(path)
    local base = (path:match("[^/]+$") or path):lower()
    return (base:match("^f%d+%-%d+%.") or base:match("^f%d+[a-z]?%.")
        or base:match("^fig%d") or base:match("^figure")
        or base:match("%f[%a]fig%d+%f[%A]")) and true or false
end











function M.reference_name(path)
    local base = (path:match("[^/]+$") or path):lower()
    return (base:match("%f[%a]maps?%f[%A]")
        or base:match("family.?tree") or base:match("%f[%a]familytree")
        or base:match("%f[%a]genealog") or base:match("%f[%a]pedigree")
        or base:match("%f[%a]cladogram") or base:match("%f[%a]phylogen")
        or base:match("%f[%a]tree%f[%A]") or base:match("%f[%a]diagram")
        or base:match("%f[%a]charts?%f[%A]") or base:match("%f[%a]timeline")
        or base:match("%f[%a]schematic") or base:match("floor.?plan")
        or base:match("%f[%a]blueprint")) and true or false
end







function M.weak_caption(s)
    if type(s) ~= "string" then return true end
    if M.decorative_caption(s) then return true end
    local l = trim(collapse_ws(s)):lower()
    local words = 0
    for _ in l:gmatch("%S+") do words = words + 1 end
    return words <= 8 and l:match("%s+by%s+%a") ~= nil
end






local CHROME_ROLES = {
    ["cover"] = true, ["title-page"] = true, ["titlepage"] = true,
    ["half-title-page"] = true, ["halftitlepage"] = true,
    ["copyright-page"] = true, ["copyright"] = true, ["imprint"] = true,
    ["colophon"] = true, ["dedication"] = true, ["epigraph"] = true,
    ["acknowledgements"] = true, ["acknowledgments"] = true,
    ["toc"] = true, ["index"] = true,
}

function M.chrome_role(role)
    return role ~= nil and CHROME_ROLES[role] or false
end


function M.epub_type_role(html)
    local head = html:sub(1, 8192):lower()
    for v in head:gmatch("epub:type%s*=%s*[\"']([^\"']*)[\"']") do
        for role in v:gmatch("[%w%-]+") do
            if CHROME_ROLES[role] then return role end
        end
    end
    return nil
end





local VOID_TAGS = {
    img = true, image = true, br = true, hr = true, meta = true, link = true,
    input = true, area = true, base = true, col = true, embed = true,
    param = true, source = true, track = true, wbr = true,
}











local function element_path_map(html)
    local paths = {}
    local stack = {}
    local body_depth = nil
    local n = #html
    local pos = 1
    while pos <= n do
        local s = html:find("<", pos, true)
        if not s then break end
        local c = html:sub(s + 1, s + 1)
        if c == "/" then
            local e = html:find(">", s + 1, true) or n
            local name = html:sub(s + 2, e - 1):match("^%s*([%w:_%-]+)")
            name = name and name:lower()
            if name then
                for i = #stack, 1, -1 do
                    if stack[i].tag == name then
                        for _ = i, #stack do table.remove(stack) end
                        if body_depth and body_depth > #stack then
                            body_depth = nil
                        end
                        break
                    end
                end
            end
            pos = e + 1
        elseif c:match("%a") then
            local e = html:find(">", s + 1, true) or n
            local tagtext = html:sub(s, e)
            local name = tagtext:match("^<%s*([%w:_%-]+)")
            name = name and name:lower()
            if name then
                local parent = stack[#stack]
                local index = 1
                if parent then
                    parent.counts[name] = (parent.counts[name] or 0) + 1
                    index = parent.counts[name]
                end
                if (name == "img" or name == "image") and body_depth then
                    local parts = {}
                    for i = body_depth + 1, #stack do
                        parts[#parts + 1] =
                            stack[i].tag .. "[" .. stack[i].index .. "]"
                    end
                    parts[#parts + 1] = name .. "[" .. index .. "]"
                    paths[s] = table.concat(parts, "/")
                end
                if not (VOID_TAGS[name] or tagtext:match("/%s*>$")) then
                    stack[#stack + 1] = { tag = name, index = index, counts = {} }
                    if name == "body" and not body_depth then
                        body_depth = #stack
                    end
                end
            end
            pos = e + 1
        else
            pos = s + 1
        end
    end
    return paths
end

function M.extract_images(html)

    html = html:gsub("<!%-%-.-%-%->", "")
    local lower = html:lower()
    local figures = find_figures(lower, html)
    local paths = element_path_map(html)
    local out = {}

    local function fig_at(pos)
        for i = 1, #figures do
            local f = figures[i]
            if pos >= f.s and pos <= f.e then return f end
        end
    end

    local function add(tag, pos, src)
        if not src or src == "" then return end
        if src:match("^data:") or src:match("^%a+://") then return end
        local f = fig_at(pos)
        out[#out + 1] = {
            src = src,
            alt = attr(tag, "alt"),
            title = attr(tag, "title"),
            class = attr(tag, "class"),
            attr_w = px(attr(tag, "width")),
            attr_h = px(attr(tag, "height")),
            figcaption = f and f.caption or nil,
            in_figure = f ~= nil,
            node_path = paths[pos],
        }
    end

    local init = 1
    while true do
        local s = lower:find("<img%f[%W]", init)
        if not s then break end
        local e = lower:find(">", s, true) or #lower
        local tag = html:sub(s, e)
        add(tag, s, attr(tag, "src") or attr(tag, "srcset"))
        init = e + 1
    end

    init = 1
    while true do
        local s = lower:find("<image%f[%W]", init)
        if not s then break end
        local e = lower:find(">", s, true) or #lower
        local tag = html:sub(s, e)
        add(tag, s, attr(tag, "xlink:href") or attr(tag, "href"))
        init = e + 1
    end

    return out
end





function M.scan(read_file)
    local function read_any(a, b)
        local d = read_file(a)
        if d and #d > 0 then return d end
        if b and b ~= a then
            d = read_file(b)
            if d and #d > 0 then return d end
        end
        return nil
    end

    local container = read_file("META-INF/container.xml")
    if not container then
        return nil, "no_container"
    end
    local opf_path = M.parse_container(container)
    if not opf_path then
        return nil, "no_opf"
    end
    local opf = read_any(opf_path, url_decode(opf_path))
    if not opf then
        return nil, "no_opf"
    end
    local book = M.parse_opf(opf, dir_of(opf_path))

    local by_path = {}
    local list = {}
    local order = 0

    local function record(dec_path, raw_path, spine_index, occ)
        local rec = by_path[dec_path]
        if not rec then
            order = order + 1
            rec = {
                path = dec_path,
                raw_path = raw_path,
                spine_index = spine_index,


                node_path = occ and occ.node_path,
                order = order,
                files_count = 0,
                total_count = 0,
                _files = {},
            }
            by_path[dec_path] = rec
            list[#list + 1] = rec
        end
        rec.total_count = rec.total_count + 1
        if not rec._files[spine_index] then
            rec._files[spine_index] = true
            rec.files_count = rec.files_count + 1
        end
        if occ then

            rec.alt = rec.alt or M.meaningful_text(occ.alt)
            rec.title_attr = rec.title_attr or M.meaningful_text(occ.title)
            rec.classes = rec.classes or occ.class
            rec.figcaption = rec.figcaption or occ.figcaption
            rec.in_figure = rec.in_figure or occ.in_figure or false
            if occ.attr_w and occ.attr_h and not rec.attr_width then
                rec.attr_width, rec.attr_height = occ.attr_w, occ.attr_h
            end
        end
    end

    for i, item in ipairs(book.spine) do
        if is_html_media(item.media, item.path) then
            local html = read_any(item.path, item.raw_path)
            if html then


                local doc_role = book.guide and book.guide[item.path]
                if not M.chrome_role(doc_role) then
                    doc_role = M.epub_type_role(html)
                end
                local base = dir_of(item.path)
                for _, occ in ipairs(M.extract_images(html)) do
                    local href = occ.src:gsub("#.*$", ""):gsub("%?.*$", "")
                    local raw = resolve_path(base, href)
                    local dec = resolve_path(base, url_decode(href))
                    record(dec, raw, i, occ)
                    local rec = by_path[dec]
                    if not rec.doc_path then
                        rec.doc_path = item.path
                        rec.doc_role = doc_role
                    end
                end
            end
        elseif is_svg_media(item.media, item.path) then

            local rec_path = item.path
            record(rec_path, item.raw_path, i, nil)
            by_path[rec_path].is_svg_doc = true
        end
    end



    if book.cover_path and not by_path[book.cover_path] then
        order = order + 1
        local rec = {
            path = book.cover_path,
            raw_path = book.cover_path,
            spine_index = 0,
            order = order,
            files_count = 0,
            total_count = 0,
            _files = {},
        }
        by_path[book.cover_path] = rec
        list[#list + 1] = rec
    end


    for _, rec in ipairs(list) do
        local data = read_any(rec.path, rec.raw_path)
        if data then
            rec.bytes = #data
            local w, h, fmt = M.get_image_dimensions(data)
            rec.width, rec.height, rec.format = w, h, fmt
        end
        if book.cover_path and rec.path == book.cover_path then
            rec.is_cover = true
        end
        rec.caption = rec.figcaption or rec.title_attr or rec.alt
        rec._files = nil
    end

    table.sort(list, function(a, b)
        if a.spine_index ~= b.spine_index then
            return a.spine_index < b.spine_index
        end
        return a.order < b.order
    end)

    return {
        version = M.VERSION,
        images = list,
        spine_count = #book.spine,
        opf_path = opf_path,
        cover_path = book.cover_path,
    }
end













local function fb2_href(tag)
    local h = attr(tag, "l:href") or attr(tag, "xlink:href")
        or attr(tag, "href") or attr(tag, "src")
    if h then return (h:gsub("^#", "")) end
end

function M.scan_fb2(fb2)
    if type(fb2) ~= "string" or #fb2 == 0 then return nil, "empty" end



    local bins = {}
    for tag, body in fb2:gmatch("<[bB]inary(.-)>(.-)</[bB]inary>") do
        local id = attr(tag, "id")
        if id then bins[id] = { ctype = attr(tag, "content-type"), body = body } end
    end


    local cover_id
    local cov = fb2:match("<[cC]overpage>(.-)</[cC]overpage>")
    if cov then
        local itag = cov:match("<[iI]mage(.-)/?>")
        if itag then cover_id = fb2_href(itag) end
    end








    local body = fb2:match("<[bB]ody[^>]*>(.-)</[bB]ody>") or fb2
    local list, by_id, order, chapter, depth = {}, {}, 0, 0, 0

    local function record(id, chap, token)
        local rec = by_id[id]
        if not rec then
            order = order + 1
            rec = {
                path = id, raw_path = id,
                spine_index = chap > 0 and chap or 1,
                order = order, files_count = 0, total_count = 0, _files = {},
            }
            by_id[id] = rec
            list[#list + 1] = rec
        end
        rec.total_count = rec.total_count + 1
        if not rec._files[chap] then
            rec._files[chap] = true
            rec.files_count = rec.files_count + 1
        end
        rec.title_attr = rec.title_attr or M.meaningful_text(attr(token, "title"))
        rec.alt = rec.alt or M.meaningful_text(attr(token, "alt"))
    end

    for token in body:gmatch("<[^>]->") do
        if token:match("^<%s*/%s*[sS][eE][cC][tT][iI][oO][nN]%s*>") then
            if depth > 0 then depth = depth - 1 end
        elseif token:match("^<%s*[sS][eE][cC][tT][iI][oO][nN][%s>/]") then
            if depth == 0 then chapter = chapter + 1 end
            if not token:match("/%s*>$") then depth = depth + 1 end
        elseif token:match("^<%s*[iI][mM][aA][gG][eE][%s/>]")
            or token:match("^<%s*[iI][mM][gG][%s/>]") then
            local id = fb2_href(token)
            if id and bins[id] then record(id, chapter, token) end
        end
    end



    if cover_id and bins[cover_id] and not by_id[cover_id] then
        order = order + 1
        list[#list + 1] = {
            path = cover_id, raw_path = cover_id, spine_index = 0,
            order = order, files_count = 0, total_count = 0, _files = {},
        }
    end


    for _, rec in ipairs(list) do
        local bin = bins[rec.path]
        if bin then
            local data = M.b64decode(bin.body)
            if data and #data > 0 then
                rec.bytes = #data
                local w, h, fmt = M.get_image_dimensions(data)
                rec.width, rec.height = w, h
                rec.format = fmt or (bin.ctype and bin.ctype:match("image/([%w]+)"))
            end
        end
        if rec.path == cover_id then rec.is_cover = true end
        rec.caption = rec.title_attr or rec.alt
        rec._files = nil
    end

    table.sort(list, function(a, b)
        if a.spine_index ~= b.spine_index then
            return a.spine_index < b.spine_index
        end
        return a.order < b.order
    end)

    return {
        version = M.VERSION,
        images = list,
        spine_count = chapter > 0 and chapter or 1,
        cover_path = cover_id,
        format = "fb2",
    }
end












function M.scan_mobi(read_file, cover_size)
    if type(read_file) ~= "function" then return nil, "no_reader" end
    local list = {}
    local n, order, misses, cover_id = 0, 0, 0, nil
    while true do
        n = n + 1
        if n > 4096 then break end
        local name = "mobi_image_" .. n
        local data = read_file(name)
        if data and #data > 0 then
            misses = 0
            order = order + 1
            local w, h, fmt = M.get_image_dimensions(data)
            local rec = {
                path = name, raw_path = name,
                spine_index = 1, order = order,
                files_count = 1, total_count = 1,
                bytes = #data, width = w, height = h, format = fmt,
            }
            if cover_size and not cover_id and #data == cover_size then
                rec.is_cover = true
                cover_id = name
            end
            list[#list + 1] = rec
        else
            misses = misses + 1
            if misses >= 3 then break end
        end
    end
    return {
        version = M.VERSION,
        images = list,
        spine_count = 1,
        cover_path = cover_id,
        format = "mobi",
    }
end



M.LEVELS = {
    strict   = { short = 350, long = 600, area = 250000, ratio = 3.0 },
    balanced = { short = 200, long = 350, area = 100000, ratio = 4.5 },
    relaxed  = { short = 120, long = 200, area = 40000,  ratio = 6.0 },
}
M.CAPTION_RELIEF = 0.5
M.RATIO_RELIEF = 1.5
M.MAX_SPINE_FILES = 2
M.MIN_SERIES = 4

M.FRONTMATTER_SPINE = 3









M.REF_RICH_MIN = 8
M.REF_RELIEF = 0.75
M.REF_RATIO_RELIEF = 1.2






function M.filter(images, level)
    local function new_stats()
        return { total = #images, included = 0, reasons = {},
                 excluded = { cover = 0, repeated = 0, series = 0,
                              decorative = 0, frontmatter = 0, small = 0,
                              aspect = 0, nosize = 0 } }
    end
    if level == "all" then
        local out, stats = {}, new_stats()
        for _, img in ipairs(images) do
            out[#out + 1] = img
            stats.reasons[img.path] = "keep"
        end
        stats.included = #out
        return out, stats
    end








    local dim_groups = {}
    for _, img in ipairs(images) do
        if img.width and img.height then
            local k = img.width .. "x" .. img.height
            local g = dim_groups[k]
            if not g then
                g = { n = 0, caps = {} }
                dim_groups[k] = g
            end
            g.n = g.n + 1
            local c = ""
            if img.caption and not M.decorative_caption(img.caption) then
                c = trim(collapse_ws(img.caption)):lower()



                if c:match("^[ivxlcdm]+[%s%.:]") or c:match("^%d+[%s%.:]") then
                    c = ""
                end
            end
            if g.caps[c] then g.dup = true end
            g.caps[c] = (g.caps[c] or 0) + 1
        end
    end





    local t = M.LEVELS[level] or M.LEVELS.balanced
    local function classify(ref_rich)
    local stats = new_stats()
    local out = {}
    for _, img in ipairs(images) do
        local reason


        local decorative = M.decorative_caption(img.caption)
        local captioned = ((img.caption ~= nil or img.in_figure) and not decorative)
            or M.figure_name(img.path) or M.reference_name(img.path)
        if img.is_cover then
            reason = "cover"
        elseif img.files_count > M.MAX_SPINE_FILES then
            reason = "repeated"
        else
            if img.width and img.height then
                local g = dim_groups[img.width .. "x" .. img.height]
                if g and g.n >= M.MIN_SERIES and g.dup then
                    reason = "series"
                end



                if not reason and not captioned
                   and img.spine_index <= M.FRONTMATTER_SPINE then
                    local r = img.width / img.height
                    if r >= 0.5 and r <= 0.9 then
                        reason = "frontmatter"
                    end
                end
            end






            if not reason then
                if decorative
                   or (M.weak_caption(img.caption)
                       and (M.decorative_name(img.path)
                            or (img.doc_path and M.decorative_name(img.doc_path))
                            or M.chrome_role(img.doc_role))) then
                    reason = "decorative"
                end
            end
            if not reason then



                local w, h = img.width, img.height
                if img.attr_width and img.attr_height then
                    if not (w and h) or img.attr_width * img.attr_height < w * h then
                        w, h = img.attr_width, img.attr_height
                    end
                end
                if not (w and h) then
                    if not (captioned and level ~= "strict") then
                        reason = "nosize"
                    end
                else
                    local long, short = math.max(w, h), math.min(w, h)


                    local relief, ratio_relief
                    if captioned then
                        relief, ratio_relief = M.CAPTION_RELIEF, M.RATIO_RELIEF
                    elseif ref_rich then
                        relief, ratio_relief = M.REF_RELIEF, M.REF_RATIO_RELIEF
                    else
                        relief, ratio_relief = 1, 1
                    end
                    local max_ratio = t.ratio * ratio_relief
                    if short > 0 and long / short > max_ratio then
                        reason = "aspect"
                    elseif short < t.short * relief
                        or long < t.long * relief
                        or w * h < t.area * relief * relief then
                        reason = "small"
                    end
                end
            end
        end
        if reason then
            stats.excluded[reason] = stats.excluded[reason] + 1
        else
            out[#out + 1] = img
        end
        stats.reasons[img.path] = reason or "keep"
    end
    stats.included = #out
    return out, stats
    end

    local out, stats = classify(false)






    if level == "balanced" and stats.included >= M.REF_RICH_MIN then
        out, stats = classify(true)
        stats.reference_rich = true
    end
    return out, stats
end

return M
