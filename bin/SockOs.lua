-- SockOs.lua: ejecuta SockOS_desk.asm usando MS-DOS.lua
local MS = require("MS-DOS")

-- Ruta al archivo del escritorio
local desk = "/SockOS/SockOS_desk.asm"

-- Ejecuta el escritorio
MS.runFile(desk)
