# ReQuest
ReQuest is a complete HTTP server written in Lua (with LuaBind). It's intended to extend the GUI capabilities of [Renoise](http://www.renoise.com/), but it should work in other contexts as well with minimal modifications.

## Features
 * Full HTTP Routing, with support for parameterized URLs.
 * Full, automated URL-encoded and multipart/form-data parsing.
 * Support for arbitrary middleware.
 * Full middleware-based support for WebSockets.
 * Full support for cookies via middleware.
 * Clean, well-documented API.

## Examples
### Getting Started
    -- contains all the basic HTTP stuff
    require("request-http")

    -- takes a host and port as arguments
    local server = HTTPServer("localhost", 80)

    -- add a basic index page
    server.router:get("/", function(request, response)
    	response:send_html(200, "Hello, world!")

    	-- let the router know the chain ended here; we already sent a response
    	return true
    end)

    -- start the server
    server:start()

    -- stop the server (once you're done)
    server:stop()

### Parameterized Routing
    -- see Lua patterns for more information
    server.router:get("/(.*)", function(request, response, params)
    	response:send_html(200, "The URL is: /" .. params[1])

    	return true
    end)

### Forms
    -- this is our form
    server.router:get("/form", function(request, response)
    	local content =
    		"<form method=\"post\" action=\"/form\">" ..
    		"Content to POST: <br />" ..
    		"<input type=\"text\" name=\"message\" /> <input type=\"submit\" />" ..
    		"</form>"

    	response:send_html(200, content)

    	return true
    end)

    -- and this is our processor for it
    server.router:post("/form", function(request, response)
    	if request.form_data["message"] ~= nil then
    		response:send_html(200, "You sent: " .. request.form_data["message"])
    	end

    	return true
    end)

### File Forms
    -- this is our form
    server.router:get("/form", function(request, response)
    	local content =
    		"<form method=\"post\" action=\"/form\" enctype=\"multipart/form-data\" >" ..
    		"Content to POST: <br />" ..
    		"<input type=\"file\" name=\"files\" multiple /> <input type=\"submit\" />" ..
    		"</form>"

    	response:send_html(200, content)

    	return true
    end)

    -- and this is our processor for it
    server.router:post("/form", function(request, response)
    	local content = ""

    	for filename, contents in pairs(request.form_data["files"]) do
    		local file = io.open ("uploads/" .. filename, "wb")
    		file:write(contents)
    		file:close()

    		content = content .. filename .. " uploaded!<br />"
    	end

    	response:send_html(200, content)

    	return true
    end)

### Middleware

#### Custom
    server.router:use(function (request, response)
    	print(request.resource)

    	-- note: it doesn't return true, as it only does some processing
    end)

    -- a pattern can also be specified
    server.router:use("/", function (request, response)
    	print(request.resource)
    end)

### Packaged Middleware
#### Basics
    -- middleware is contained in the request-middleware module
    require("request-middleware")

#### Static Files
    -- serves static files from a specific directory
    -- should probably be added LAST in the routing chain
    -- in case a matching file is not found, a callback should be specified

    function file_not_found(request, response)
    	response:send_html(404, "No such file exists.")

    	return true
    end

    server.router:use(static("www", file_not_found))

#### Cookies
    -- contains UTC timestamp() function useful for cookies
    require("request-utils")

    -- parses and stores cookies in a newly-created request.cookies table
    -- also adds response:set_cookie(name, content, expiry)
    server.router:use(cookies())

    server.router:get("/cookie", function (request, response)
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

    server.router:post("/cookie", function (request, response)
    	if request.form_data["message"] ~= nil then
    		response:set_cookie("message", request.form_data["message"], timestamp() + 60)
    	end

    	response:send_html(200, "Cookie set!")

    	return true
    end)

#### WebSockets
    -- adds request:websocket_requested()
    -- also adds response:open_websocket(handler) which returns a WebSocketClient instance
    -- see request-websocket-utils for more info on WebSocketClient
    server.router:use(websockets())

    server.router:get("/websocket", function(request, response)
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
    end
