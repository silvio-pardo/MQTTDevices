-- module table
local tools = {}

-- load required stuff
local require = require

--local string = require("string") *****
local str_format = string.format
local str_byte = string.byte

--local table = require("table") *****
local tbl_concat = table.concat

--local math = require("math") *****
local math_floor = math.floor


-- Returns string encoded as HEX
function tools.hex(str)
	local res = {}
	for i = 1, #str do
		res[i] = str_format("%02X", str_byte(str, i))
	end
	return tbl_concat(res)
end

-- Integer division function
function tools.div(x, y)
	return math_floor(x / y)
end

-- table dump function
function tools.tb_dump(o)
	if type(o) == 'table' then
		local s = '{ '
		for k,v in pairs(o) do
			if type(k) ~= 'number' then k = '"'..k..'"' end
			s = s .. '['..k..'] = ' .. tools.tb_dump(v) .. ','
		end
		return s .. '} '
	else
		return tostring(o)
	end
end

-- export module table
return tools

-- vim: ts=4 sts=4 sw=4 noet ft=lua
