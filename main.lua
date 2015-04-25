require("request-http")
require("request-middleware")

local http = nil
local port = 1337

renoise.tool():add_menu_entry {
	name = "Main Menu:Tools:Start Server",
	invoke = function() start() end
}

renoise.tool():add_menu_entry {
	name = "Main Menu:Tools:Stop Server",
	invoke = function() stop() end
}

function setup_routing()
	http.router:use(cookie())
	http.router:use(websockets())
	
	-- cookies example
	http.router:get("/cookie", function (request, response)
		local content = ""
		
		if request.cookies["message"] ~= nil then
			content = content .. "Cookie contains: " .. request.cookies["message"] .. "<br /<"
		end
		
		content = content .. 
			"<form method=\"post\" action=\"/cookie\">" ..
			"Set cookie to: <br />" ..
			"<input type=\"text\" name=\"message\" /> <input type=\"submit\" />" ..
			"</form>"
		
		response:send_html(200, content)
		
		return true
	end)

	http.router:post("/cookie", function (request, response)
		if request.form_data["message"] ~= nil then
			response:set_cookie("message", request.form_data["message"], timestamp() + 60)
		end
		
		response:send_html(200, "Cookie set!")
		
		return true
	end)
	
	-- forms example
	http.router:get("/form", function(request, response)
		local content = 
			"<form method=\"post\" action=\"/form\" enctype=\"multipart/form-data\">" ..
			"Content to POST: <br />" ..
			"<input type=\"file\" name=\"files\" multiple /> <input type=\"submit\" />" ..
			"</form>"
		
		response:send_html(200, content)
		
		return true
	end)

	http.router:post("/form", function(request, response)
		local content = ""
		
		for filename, contents in pairs(request.form_data["files"]) do
			local file = io.open ("uploads/" .. filename, "wb")
			file:write(contents)
			file:close()
			
			content = content .. filename .. " uploaded! (check the script directory!)<br />"
		end
		
		response:send_html(200, content)
		
		return true
	end)
	
	-- websocket example
	http.router:get("/websocket", function(request, response)
		-- a basic echo server handler
		local echo_server = {
			["on_open"] =
				function(websocket)
					print(websocket.id, "connected! :)")
				end,
			["on_message"] =
				function(websocket, opcode, message)
					-- first argument is the FIN bit
					-- it indicates that this message is complete - not fragmented
					websocket:send(1, opcode, message)
				end,
			["on_close"] =
				function(websocket)
					print(websocket.id, "disconnected! :(")
				end
		}
		
		if request:websocket_requested() then
			local client = response:open_websocket(echo_server)
		else
			response:send_html(403, "WebSocket clients only.")
		end
		
		return true
	end)
	
	-- if no other routes matched, serve static content
	http.router:use(static("www", function(request, response)
		response:send_html(404, "No such file exists.")
		
		return true
	end))
end

function start()
	http = HTTPServer("0.0.0.0", port)
	setup_routing()
	http:start()
	print("Started.")

	-- open server url in the default web browser on various platforms
	-- only windows is tested, so good luck! <3
	if os.platform() == "WINDOWS" then
		os.execute("explorer http://localhost:" .. port .. "/")
	elseif os.platform() == "LINUX" then
		os.execute("xdg-open http://localhost:" .. port .. "/")
	elseif os.platform() == "MACINTOSH" then
		os.execute("open http://localhost:" .. port .. "/")
	end
end

function stop()
	http:stop()
	http = nil
	print("Stopped.")
end