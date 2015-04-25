require("request-utils")
require("request-websocket-utils")

-- basic cookie handling middleware
-- adds a 'cookies' field (a table with key/value pairs) to the request instance
-- also adds a 'set_cookie' method to the response instance
function cookie ()
	local callback = function (request, response)
		if request.cookies == nil then
			request.cookies = {}
		end
		
		-- would throw an exception if the field is nil, so create it
		if request.headers["cookie"] == nil then
			request.headers["cookie"] = ""
		end
		
		-- magically parses cookies, ooo magic regex
		request.headers["cookie"]:gsub("%s?([^=]+)=([^;]+);?", function(name, value)
			request["cookies"][unescape(name)] = unescape(value)
		end)
		
		-- expiry is a timestamp, from e.g. os.time()
		response.set_cookie = function (self, name, value, expiry)
			if expiry ~= nil then
				local as_date = os.date("%a, %d %b %Y %H:%M:%S GMT", expiry)
				response:add_header("Set-Cookie", escape(name) .. "=" .. escape(value) .. "; Expires=" .. as_date)
			else
				response:add_header("Set-Cookie", escape(name) .. "=" .. escape(value))
			end
		end
	end
	
	return callback
end

-- static file middleware
-- you probably want to add this LAST in the routing chain
-- it looks up files in the root directory and sends them if they exist
-- calls noSuchFile(request, response) handler if no such file exists; use for a 404
function static (root, no_such_file)
	local callback = function (request, response)
		if request.resource == "/" then
			-- look for index.* using the registered types
			for ext, mime in pairs(response.types) do
				if file_exists(root .. "/index." .. ext) then
					response:send_file(200, root .. "/index." .. ext)
					return true
				end
			end
		else
			if file_exists(root .. request.resource) then
				response:send_file(200, root .. request.resource)
				
				return true
			else
				no_such_file(request, response)
			end
		end
	end
	
	return callback
end

-- websocket middleware
-- adds websocket_requested() and open_websocket() functions to the request and response instances respectively
function websockets()
	local callback = function(request, response)
		-- detects whether or not a protocol switch was requested
		request.websocket_requested = function (self)
			return request.headers["upgrade"] ~= nil and request.headers["upgrade"] == "websocket"
		end
		
		-- opens the websocket
		response.open_websocket = function (self, handlers)
			local handshake = websocket_handshake(request.headers["sec-websocket-key"])
			
			local data = "HTTP/1.1 101 Switching Protocols\r\n" ..
				"Upgrade: websocket\r\n" ..
				"Connection: Upgrade\r\n" ..
				"Sec-WebSocket-Accept: " .. handshake .. "\r\n"
			
			
			for i = 1, #response.headers, 1 do
				local header = self.headers[i]
				data = data .. header["header"] .. ": " .. header["value"] .. "\r\n"
			end
			
			data = data .. "\r\n"
			
			response:send_raw(data)
			
			-- create a WebSocketClient instance
			response.websocket = WebSocketClient(response.socket, handlers)
			
			response.websocket.handlers.on_open(response.websocket)
			
			-- let the HTTPServer know we switched protocols
			response.protocol = "websocket"
			
			-- add a custom handler to receive future messages
			response.message = function(self, message)
				response.websocket:process(message)
			end
			
			-- return the WebSocketClient
			return response.websocket
		end
	end
	
	return callback
end