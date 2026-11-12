--[[
  MM2 FARM — загрузчик (кладётся в AutoExec)

  Что делает: при каждом заходе в игру скачивает свежую версию скрипта
  с GitHub и запускает её. Ссылка на raw кэшируется CDN ~5 минут,
  поэтому добавляем ?v=<unix time> — иначе можно подхватить старую версию.

  Своя версия в скрипте сама снимает прошлый экземпляр, так что
  повторный запуск не создаёт второй HUD.
]]

local URL = "https://raw.githubusercontent.com/D1abloF1/mm2-farm/main/MM2Farm.lua"

local function bust(url)
	local sep = url:find("?", 1, true) and "&" or "?"
	return url .. sep .. "v=" .. tostring(math.floor(os.time()))
end

local function httpGet(url)
	local ok, body = pcall(function()
		return game:HttpGet(url)
	end)
	if ok and type(body) == "string" then return body end
	local ok2, body2 = pcall(function()
		return game:GetService("HttpService"):GetAsync(url)
	end)
	if ok2 and type(body2) == "string" then return body2 end
	return nil
end

local code = httpGet(bust(URL))
if type(code) ~= "string" or #code < 500 then
	warn("[MM2Farm] загрузчик: не удалось скачать скрипт (проверь ссылку/интернет)")
	return
end

local chunk, compileErr = loadstring(code)
if not chunk then
	warn("[MM2Farm] загрузчик: не компилируется — " .. tostring(compileErr))
	return
end

local ok, runErr = pcall(chunk)
if not ok then
	warn("[MM2Farm] загрузчик: ошибка при запуске — " .. tostring(runErr))
end
