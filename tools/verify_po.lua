local function parsePO(path)
    local f = io.open(path, "r")
    if not f then return nil end

    local map = {}
    local msgid, msgstr, in_id, in_str = nil, nil, false, false

    local function flush()
        if msgid and msgstr and msgid ~= "" and msgstr ~= "" then
            map[msgid] = msgstr
        end
        msgid, msgstr, in_id, in_str = nil, nil, false, false
    end

    local function unescape(s)
        return s:gsub("\\n", "\n"):gsub("\\t", "\t"):gsub('\\"', '"'):gsub("\\\\", "\\")
    end

    for raw_line in f:lines() do
        local line = raw_line:match("^%s*(.-)%s*$")
        if line:match("^#") or line == "" then
            if line == "" then flush() end
        elseif line:match('^msgid%s+"') then
            flush()
            msgid  = unescape(line:match('^msgid%s+"(.*)"') or "")
            in_id  = true; in_str = false
        elseif line:match('^msgstr%s+"') then
            msgstr = unescape(line:match('^msgstr%s+"(.*)"') or "")
            in_str = true; in_id  = false
        elseif line:match('^"') then
            local cont = unescape(line:match('^"(.*)"') or "")
            if in_id  and msgid  then msgid  = msgid  .. cont end
            if in_str and msgstr then msgstr = msgstr .. cont end
        end
    end
    flush()
    f:close()
    return map
end


local bad=0
for f in io.lines() do
  local x, y = parsePO(arg[1].."/"..f), parsePO(arg[2].."/"..f)
  local nx, ny = 0, 0
  for k,v in pairs(x) do nx=nx+1 if y[k]~=v then bad=bad+1 print("DIFF",f,k) break end end
  for k in pairs(y) do ny=ny+1 end
  if nx~=ny then bad=bad+1 print("COUNT",f,nx,ny) end
end
print("po failures", bad)
os.exit(bad==0 and 0 or 1)
