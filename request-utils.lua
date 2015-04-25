-- timezone offset from UTC, in seconds
function timezone_offset()
	local utcdate	 = os.date("!*t", os.time())
	local localdate = os.date("*t", os.time())
	localdate.isdst = false -- this is the trick
	return os.difftime(os.time(localdate), os.time(utcdate))
end

-- UTC timestamp
function timestamp()
	return os.time() - timezone_offset()
end

-- URL encodes a string
function escape(str)
	str = string.gsub(str, "\n", "\r\n")
	str = string.gsub(str, "([^%w ])", function (c)
		return string.format ("%%%02X", string.byte(c))
	end)
	str = string.gsub(str, " ", "+")
	return str		
end

-- decodes a URL-encoded string
function unescape(url)
	url = url:gsub("+", " ")
	url = url:gsub("%%(%x%x)", function(x)
		return string.char(tonumber(x, 16))
	end)
	return url
end

-- decodes a POST body or GET params into a key/value table
function urldecode(body)
	local results = {}
	body:gsub("([a-zA-Z0-9%\+]+)=([^&]+)&?", function(name, value)
		results[unescape(name:gsub("+", " "))] = unescape(value:gsub("+", " "))
	end)
	return results
end

-- split path into components
function path_parts(name)
	return string.match(name, "(.-)([^\\]-([^\\%.]+))$")
end

-- checks if a file exists
function file_exists(name)
	local f = io.open(name, "r")
	if f ~= nil then
		io.close(f)
		return true
	else
		return false
	end
end