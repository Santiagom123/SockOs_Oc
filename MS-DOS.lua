-- MS-DOS.lua: Núcleo intérprete completo con Windows primitivo
local component = require("component")
local gpu = component.gpu
local fs = require("filesystem")
local event = require("event")
local os = require("os")
local table_insert = table.insert

local M = {}

-- Variables internas
M.vars = {}
M.labels = {}
M.cotasks = {}
M.stack = {}
M.windows = {}  
M.buttons = {} 
M.icons = {}    

-- Colores predefinidos
M.colorNames = {
  BLACK=0x000000, WHITE=0xFFFFFF, RED=0xFF0000,
  GREEN=0x00FF00, BLUE=0x0000FF, YELLOW=0xFFFF00,
  CYAN=0x00FFFF, MAGENTA=0xFF00FF
}

function M.parseColor(c)
  if M.colorNames[c] then return M.colorNames[c] end
  if c:match("0x%x+") then return tonumber(c) end
  return 0xFFFFFF
end

-- Dibuja ventana en GPU
local function drawWindow(win)
    gpu.setBackground(win.bg or 0x000000)
    gpu.fill(win.x, win.y, win.w, win.h, " ")
    if win.title then
        gpu.setForeground(0xFFFFFF)
        gpu.set(win.x + 1, win.y, win.title)
    end
end

-- Dibuja botón en GPU
local function drawButton(btn)
    local win = M.windows[btn.win]
    if win then
        gpu.setBackground(btn.bg or 0xAAAAAA)
        gpu.fill(win.x + btn.x - 1, win.y + btn.y -1, btn.w, btn.h, " ")
        gpu.setForeground(btn.fg or 0x000000)
        gpu.set(win.x + btn.x, win.y + btn.y, btn.text)
    end
end

-- Dibuja icono de escritorio
local function drawIcon(icon)
    gpu.setBackground(icon.bg or 0x0000FF)
    gpu.fill(icon.x, icon.y, 5, 3, " ")
    gpu.setForeground(icon.fg or 0xFFFFFF)
    gpu.set(icon.x, icon.y, icon.text)
end

-- Evalúa expresiones con variables
local function eval(expr)
    local f,err = load("return "..expr,nil,"t",M.vars)
    if not f then error(err) end
    return f()
end

-- Ejecuta una línea de ASM/Comando
function M.execute(cmd, pc, lines)
    cmd = cmd:match("^%s*(.-)%s*$")
    if cmd == "" then return pc end

    -- BLOQUES DE CONTROL
    if cmd:match("^IF%s+(.+):") then
        local cond = cmd:match("^IF%s+(.+):")
        local res = eval(cond)
        table_insert(M.stack,{type="IF",active=res})
        return pc
    elseif cmd:match("^ENDIF") then
        table.remove(M.stack)
        return pc
    elseif cmd:match("^NUMFOR%s+(%w+),%s*(%d+)%s+RANGE%s+(%d+):") then
        local var,start,range = cmd:match("^NUMFOR%s+(%w+),%s*(%d+)%s+RANGE%s+(%d+):")
        start,range = tonumber(start), tonumber(range)
        M.vars[var]=start
        table_insert(M.stack,{type="NUMFOR",var=var,start=start,endv=range,pc=pc})
        return pc
    elseif cmd:match("^ENDNUMFOR") then
        local block = M.stack[#M.stack]
        if block and block.type=="NUMFOR" then
            M.vars[block.var]=M.vars[block.var]+1
            if M.vars[block.var]<=block.endv then
                return block.pc
            else
                table.remove(M.stack)
            end
        end
        return pc
    elseif cmd:match("^NOMFOR%s+(%w+),%s+ORDER%s+(.+):") then
        local var,path = cmd:match("^NOMFOR%s+(%w+),%s+ORDER%s+(.+):")
        local items = {}
        for f in fs.list(path) do table_insert(items,f) end
        M._nomfor={var=var,items=items,idx=1,pc=pc}
        M.vars[var]=M._nomfor.items[1]
        table_insert(M.stack,{type="NOMFOR",data=M._nomfor})
        return pc
    elseif cmd:match("^ENDNOMFOR") then
        local block = M.stack[#M.stack]
        if block and block.type=="NOMFOR" then
            block.data.idx = block.data.idx +1
            if block.data.idx<=#block.data.items then
                M.vars[block.data.var]=block.data.items[block.data.idx]
                return block.data.pc
            else
                table.remove(M.stack)
            end
        end
        return pc
    elseif cmd:match("^UNTIL%s+(.+):") then
        local cond = cmd:match("^UNTIL%s+(.+):")
        table_insert(M.stack,{type="UNTIL",cond=cond,pc=pc})
        return pc
    elseif cmd:match("^ENDUNTIL") then
        local block = M.stack[#M.stack]
        if block and block.type=="UNTIL" then
            local ok = eval(block.cond)
            if not ok then
                return block.pc
            else
                table.remove(M.stack)
            end
        end
        return pc
    end

    -- IGNORA COMANDOS DENTRO DE IF FALSE
    for i=#M.stack,1,-1 do
        local b=M.stack[i]
        if b.type=="IF" and not b.active then return pc end
    end

    -- MISC, COTASK, FS, EVENT, GPU, VAR
    -- READ INPUT
    if cmd:match("^READ INPUT") then
        io.write("> ")
        M.vars["_INPUT"] = io.read()

    -- EXEC
    elseif cmd:match("^EXEC MS%-DOS%s+(.+)") then
        local file = cmd:match("^EXEC MS%-DOS%s+(.+)")
        M.runFile(file)
    elseif cmd:match("^EXEC LUA%s+(.+)") then
        local file = cmd:match("^EXEC LUA%s+(.+)")
        os.execute("lua "..file)

    -- COTASK
    elseif cmd:match("^COTASK NEW%s+(%w+):%s*(.+)") then
        local id,c = cmd:match("^COTASK NEW%s+(%w+):%s*(.+)")
        M.cotasks[id] = coroutine.create(function() M.execute(c) end)
        coroutine.resume(M.cotasks[id])
    elseif cmd:match("^COTASK%s+KILL%s+(%w+)") then
        local id = cmd:match("^COTASK%s+KILL%s+(%w+)")
        M.cotasks[id] = nil

    -- FILE SYSTEM
    elseif cmd:match("^FS READ%s+(.+)") then
        local file = cmd:match("^FS READ%s+(.+)")
        local f = io.open(file,"r"); if f then print(f:read("*a")); f:close() end
    elseif cmd:match("^FS MV%s+(.+),%s*(.+)") then
        local src,dest = cmd:match("^FS MV%s+(.+),%s*(.+)")
        fs.rename(src,dest)
    elseif cmd:match("^FS RM%s+(.+)") then
        fs.remove(cmd:match("^FS RM%s+(.+)"))
    elseif cmd:match("^FS LIST%s+(.+)") then
        local path = cmd:match("^FS LIST%s+(.+)")
        for f in fs.list(path) do print(f) end
    elseif cmd:match("^FS WRITE INSERT%s+(.+),%s*(.+)") then
        local file,text = cmd:match("^FS WRITE INSERT%s+(.+),%s*(.+)")
        local f = io.open(file,"a"); f:write(text.."\n"); f:close()
    elseif cmd:match("^FS WRITE REPLACE%s+(.+),%s*(.+)") then
        local file,text = cmd:match("^FS WRITE REPLACE%s+(.+),%s*(.+)")
        local f = io.open(file,"w"); f:write(text.."\n"); f:close()
    elseif cmd:match("^FS LINES%s+(.+)") then
        local file = cmd:match("^FS LINES%s+(.+)")
        local f = io.open(file,"r")
        if f then for l in f:lines() do print(l) end f:close() end

    -- EVENT
    elseif cmd:match("^EVENT PULL%s+(.+)") then
        local e = cmd:match("^EVENT PULL%s+(.+)")
        M.vars["_EVENT"] = {event.pull(e)}
    elseif cmd:match("^EVENT MPULL%s+(.+)") then
        local list = cmd:match("^EVENT MPULL%s+(.+)")
        local events={}; for ev in list:gmatch("%w+") do events[ev]=true end
        M.vars["_EVENT"] = {event.pullMultiple(table.unpack(events))}

    -- GPU
    elseif cmd:match("^GPU SET%s+(%d+),%s*(%d+),%s*(.+)") then
        local x,y,text = cmd:match("^GPU SET%s+(%d+),%s*(%d+),%s*(.+)")
        gpu.set(tonumber(x),tonumber(y),text)
    elseif cmd:match("^GPU FILL FULL") then
        local w,h = gpu.getResolution(); gpu.fill(1,1,w,h," ")
    elseif cmd:match("^GPU FILL%s+(%d+),%s*(%d+),%s*(%d+),%s*(%d+),%s*(.)") then
        local x,y,w,h,c = cmd:match("^GPU FILL%s+(%d+),%s*(%d+),%s*(%d+),%s*(%d+),%s*(.)")
        gpu.fill(tonumber(x),tonumber(y),tonumber(w),tonumber(h),c)
    elseif cmd:match("^GPU FCOL%s+(.+)") then gpu.setForeground(M.parseColor(cmd:match("^GPU FCOL%s+(.+)")))
    elseif cmd:match("^GPU BCOL%s+(.+)") then gpu.setBackground(M.parseColor(cmd:match("^GPU BCOL%s+(.+)")))

    -- VAR
    elseif cmd:match("^VAR CREAT%s+(%w+)") then M.vars[cmd:match("^VAR CREAT%s+(%w+)")]=nil
    elseif cmd:match("^VAR SET%s+(%w+),%s*(.+)") then
        local v,expr = cmd:match("^VAR SET%s+(%w+),%s*(.+)"); M.vars[v]=eval(expr)
    elseif cmd:match("^VAR PARSE%s+(.+)") then M.vars["_PARSE"]=cmd:match("^VAR PARSE%s+(.+)")

    -- WINDOWS PRIMITIVO
    elseif cmd:match("^DESKTOP FILL%s+(.+)") then
        gpu.setBackground(M.parseColor(cmd:match("^DESKTOP FILL%s+(.+)")))
        local w,h=gpu.getResolution(); gpu.fill(1,1,w,h," ")
    elseif cmd:match("^WINDOW CREATE%s+(%w+),%s*(%d+),%s*(%d+),%s*(%d+),%s*(%d+),%s*(.+)") then
        local id,x,y,w,h,title=cmd:match("^WINDOW CREATE%s+(%w+),%s*(%d+),%s*(%d+),%s*(%d+),%s*(%d+),%s*(.+)")
        M.windows[id]={x=tonumber(x),y=tonumber(y),w=tonumber(w),h=tonumber(h),title=title,bg=0x000000}
        drawWindow(M.windows[id])
    elseif cmd:match("^WINDOW FILL%s+(%w+)%s+(.+)") then
        local id,c=cmd:match("^WINDOW FILL%s+(%w+)%s+(.+)"); local win=M.windows[id]
        if win then win.bg=M.parseColor(c); drawWindow(win) end
    elseif cmd:match("^WINDOW WRITE%s+(%w+),%s*(%d+),%s*(%d+),%s*(.+)") then
        local id,x,y,text=cmd:match("^WINDOW WRITE%s+(%w+),%s*(%d+),%s*(%d+),%s*(.+)")
        local win=M.windows[id]; if win then gpu.set(win.x+tonumber(x)-1,win.y+tonumber(y)-1,text) end
    elseif cmd:match("^BUTTON CREATE%s+(%w+),%s*(%w+),%s*(%d+),%s*(%d+),%s*(%d+),%s*(%d+),%s*(.+)") then
        local id,win,x,y,w,h,text=cmd:match("^BUTTON CREATE%s+(%w+),%s*(%w+),%s*(%d+),%s*(%d+),%s*(%d+),%s*(%d+),%s*(.+)")
        M.buttons[id]={win=win,x=tonumber(x),y=tonumber(y),w=tonumber(w),h=tonumber(h),text=text}; drawButton(M.buttons[id])
    elseif cmd:match("^DESKTOP ICON%s+(%w+),%s*(%d+),%s*(%d+),%s*(.+)") then
        local id,x,y,text=cmd:match("^DESKTOP ICON%s+(%w+),%s*(%d+),%s*(%d+),%s*(.+)")
        M.icons[id]={x=tonumber(x),y=tonumber(y),text=text}; drawIcon(M.icons[id])
    else
        print("Comando desconocido: "..cmd)
    end

    return pc
end

-- Ejecuta archivo completo
function M.runFile(file)
    local lines = {}
    for l in io.lines(file) do table_insert(lines,l) end
    local pc=1
    while pc<=#lines do
        local ok,err = pcall(function() pc=M.execute(lines[pc],pc,lines) end)
        if not ok and err~="EXIT" then print("Error línea "..pc..": "..err)
        elseif err=="EXIT" then break end
        pc=pc+1
    end
end

return M
