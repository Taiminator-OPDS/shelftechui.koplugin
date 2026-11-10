-- luajit verify.lua SRC OUT  (file list on stdin): stripped bytecode must match
local src, out = arg[1], arg[2]
local bad, n = 0, 0
for f in io.lines() do
    n = n + 1
    local a, ea = loadfile(src .. "/" .. f)
    local b, eb = loadfile(out .. "/" .. f)
    if not b then print("NOCOMPILE", f, eb) bad = bad + 1
    elseif not a then print("SRC NOCOMPILE", f, ea)
    elseif string.dump(a, true) ~= string.dump(b, true) then print("DIFF", f) bad = bad + 1 end
end
print(("lua files %d, failures %d"):format(n, bad))
os.exit(bad == 0 and 0 or 1)
