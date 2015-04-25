require("request-utils")

--[[
	HTTP server class
	
	will eventually be used to handle routing, for now only stores the socket and static content directory
]]--
class "HTTPServer"
	function HTTPServer:__init(host, port)
		self.host = host
		self.port = port
		
		local socket, socket_err = renoise.Socket.create_server(
			self.host,
			self.port,
			renoise.Socket.PROTOCOL_TCP
		)
		
		if (socket_err) then
			renoise.app():show_warning(
				("Failed to start the HTTP server. Error:\n%s"):format(socket_error)
			)
		else
			self.socket = socket
			self.router = HTTPRouter(self)
			self.pending = {}
			self.non_http_clients = {}
		end
	end

	function HTTPServer:start()
		self.socket:run(self)
	end

	function HTTPServer:stop()
		self.socket:stop()
		self.socket:close()
	end
	
	function HTTPServer:socket_error(message)
		renoise.app():show_warning(message)
	end
	
	function HTTPServer:socket_accepted(socket)
	
	end
	
	function HTTPServer:socket_message(socket, message)
		-- this is a unique id for our client
		local id = socket.peer_address .. ":" .. socket.peer_port
		
		-- if this client is being handled by another protocol, just pass the message along
		if self.non_http_clients[id] ~= nil then
			self.non_http_clients[id]:message(message)
			return
		end
		
		local request, response
		
		-- some requests are sent in multiple parts
		-- incomplete requests are stored in HTTPServer.pending
		if self.pending[id] == nil then
			request = HTTPRequest(message)
		else
			request = self.pending[id]
			request:add_data(message)
		end
		
		if request:ready() then
			request:process()
			
			response = HTTPResponse(socket, request)
			
			self.router:process(request, response)
			
			-- the response may switch protocols
			if response.protocol ~= "http" then
				self.non_http_clients[id] = response
			end
			
			-- in either case, the request is no longer 'pending'
			self.pending[id] = nil
		else
			self.pending[id] = request
		end
	end


--[[
	simple HTTP routing
]]--
class "HTTPRouter"
	function HTTPRouter:__init(http)
		self.http = http
		
		self.chain = {}
	end
	
	-- adds a piece of middleware to the request processing chain
	function HTTPRouter:use(...)
		local pattern, callback
		
		if type(arg[1]) == "string" then
			pattern = arg[1]
			callback = arg[2]
		elseif type(arg[1]) == "function" then
			pattern = nil
			callback = arg[1]
		end
		
		self.chain[ #self.chain + 1 ] = {
			["verb"] = nil,
			["pattern"] = pattern,
			["callback"] = callback
		}
	end
	
	-- adds a processor for GET requests
	function HTTPRouter:get(pattern, callback)
		self.chain[ #self.chain + 1 ] = {
			["verb"] = "GET",
			["pattern"] = pattern,
			["callback"] = callback
		}
	end
	
	-- adds a processor for POST requests
	function HTTPRouter:post(pattern, callback)
		self.chain[ #self.chain + 1 ] = {
			["verb"] = "POST",
			["pattern"] = pattern,
			["callback"] = callback
		}
	end
	
	-- iterates through the chain in order until one of the processors handled the response
	function HTTPRouter:process(request, response)
		for i = 1, #self.chain, 1 do
			if	(function ()
					local middleware = self.chain[i]
					
					if (middleware.verb ~= nil and middleware.verb ~= request.verb) then
						return false -- continue
					end
					
					if (middleware.pattern ~= nil and request.resource:match(middleware.pattern) == nil) then
						return false -- continue
					end
					
					local result
					
					if middleware.pattern ~= nil then
						local params = {request.resource:match(middleware.pattern)}
						result = middleware.callback(request, response, params)
					else
						result = middleware.callback(request, response)
					end
					
					if result ~= nil then
						return true -- break
					end
				end)() then break end
		end
		
		return nil
	end

--[[
	HTTP request class
	
	parses and stores requests from the client
]]--
class "HTTPRequest"
	function HTTPRequest:__init(data)
		local verb, resource, version, the_rest = data:match("([^%s]+)%s+([^%s]+)%s+([^\r\n]+)\r\n(.*)")
		local headers_blob, body = the_rest:match("(.-\r\n)\r\n(.*)")
		
		self.data = data
		self.verb = verb
		self.resource = resource
		self.version = version
		self.headers = self:parse_headers(headers_blob)
		self.body = body
	end
	
	-- if a content-length was specified and our current body size doesn't quite match up, we're not ready to process yet
	function HTTPRequest:ready()
		return self.headers["content-length"] == nil or tonumber(self.headers["content-length"]) == #self.body
	end
	
	-- called by HTTPServer when it receives more data for this request
	function HTTPRequest:add_data(data)
		self.data = self.data .. data
		self.body = self.body .. data
	end
	
	-- called by HTTPServer when the request is ready to be processed; populates form_data
	function HTTPRequest:process()
		if self.verb == "POST" then
			if self.headers["content-type"] == "application/x-www-form-urlencoded" then
				self.form_data = self:parse_form_urlencoded(self.body)
			elseif self.headers["content-type"]:sub(1, 19) == "multipart/form-data" then
				local content_type = self:parse_subvalues(self.headers["content-type"])
				self.form_data = self:parse_form_multipart(self.body, content_type["boundary"])
			end
		end
	end
	
	-- parses headers into key/value table
	function HTTPRequest:parse_headers(data)
		local headers = {}
		data:gsub("(.-)%s*:%s*(.-)\r\n", function(name, value)
			headers[name:lower()] = value
		end)
		return headers
	end
	
	-- this will parse most multi-value headers, but not all; good enough for its purpose
	function HTTPRequest:parse_subvalues(data)
		if data:find(";") ~= nil then
			local values = {}

			values["value"] = data:sub(1, data:find(";") - 1)

			data:gsub(";%s*([A-Za-z]+)%s*=%s*([^;%s]+)", function(name, value)
				local v = value:match("\"(.-)\"")
				if v ~= nil then value = v end

				values[name:lower()] = value
			end)

			return values
		else
			return {["value"] = data}
		end
	end
	
	-- called when regular ol' urlencoded form POSTs happen
	function HTTPRequest:parse_form_urlencoded(body)
		return urldecode(body)
	end
	
	-- called when newfangled fancy multipart form POSTs happen
	function HTTPRequest:parse_form_multipart(body, boundary)
		local parts = self:explode_multipart(body, boundary)
		return self:parse_multipart(parts)
	end
	
	-- explodes the multipart message into its parts
	function HTTPRequest:explode_multipart(body, boundary)
		local buffer = ""
		local current_index = 0
		local parts = {}
		
		body:gsub("(.-)\r\n", function (line)
			if line:match("%-%-" .. boundary .. "%-?%-?") ~= nil then
				if current_index == 0 then
					current_index = current_index + 1
					return
				end
				parts[current_index] = buffer
				current_index = current_index + 1
				buffer = ""
			else
				buffer = buffer .. line .. "\r\n"
			end
		end)
		
		parts[current_index] = buffer
		current_index = current_index + 1
		buffer = ""
		
		return parts
	end
	
	-- parses each part
	function HTTPRequest:parse_multipart(parts, filemode)
		local result = {}
		
		for index, part in pairs(parts) do
			local header_blob, body = part:match("(.-\r\n)\r\n(.*)")
			if header_blob ~= nil then
				local headers = self:parse_headers(header_blob)
				local disposition = self:parse_subvalues(headers["content-disposition"])
				local type = nil
				
				if headers["content-type"] ~= nil then
					type = self:parse_subvalues(headers["content-type"])
				end
				
				if filemode == nil then
					if type ~= nil then
						if result[disposition["name"]] == nil then
							result[disposition["name"]] = {}
						end
						
						if type["value"] == "multipart/mixed" then
							local files = self:parse_multipart(self:explode_multipart(body, type["boundary"]), true)
							
							for filename, body in pairs(files) do
								result[disposition["name"]][filename] = body
							end
						else
							if disposition["filename"] ~= "" then
								result[disposition["name"]][disposition["filename"]] = body:sub(1, #body - 2)
							end
						end
					else
						result[disposition["name"]] = body
					end
				else
					result[disposition["filename"]] = body:sub(1, #body - 2)
				end
			end
		end
		
		return result
	end



--[[
	HTTP response class
	
	convenient functionalities for generating and sending responses
]]--
class "HTTPResponse"
	function HTTPResponse:__init(socket, request)
		self.protocol = "http"
		self.socket = socket
		self.request = request
		
		self.headers = {}
		self.types = {}
		
		self:add_header("Server", "ReQuest")
		
		-- code types
		self:add_type("html", "text/html")
		self:add_type("htm", "text/html")
		self:add_type("xml", "application/xml")
		self:add_type("json", "application/json")
		self:add_type("css", "text/css")
		self:add_type("js", "application/javascript")
		
		-- image types
		self:add_type("ico", "image/x-icon")
		self:add_type("jpg", "image/jpeg")
		self:add_type("jpeg", "image/jpeg")
		self:add_type("gif", "image/gif")
		self:add_type("png", "image/png")
		self:add_type("svg", "image/svg+xml")
	end
	
	-- adds a type to the type registry
	function HTTPResponse:add_type(extension, imtype)
		self.types[extension] = imtype
	end
	
	-- appends a header to the list of headers we're sending with this response
	function HTTPResponse:add_header(header, value)
		self.headers[#self.headers + 1] = {
			["header"] = header,
			["value"] = value
		}
	end
	
	-- infers type from filename; this is not ideal, but it's functional
	function HTTPResponse:infer_type(file)
		local path, name, ext = path_parts(file)
		
		return self.types[ext:lower()]
	end
	
	-- tries to send a file, returns false if no such file exists
	function HTTPResponse:send_file(status, file)
		if not file_exists(file) then
			return false
		end
		
		local f = io.open(file, "rb")
		local data = f:read("*all")
		f:close()
		
		local type = self:infer_type(file)
		print("Sending " .. file .. " (type: " .. type .. ")...")
		
		self:add_header("Connection", "close")
		self:add_header("Content-type", type)
		self:add_header("Content-length", #data)
		
		self:send_http(
			status,
			data
		)
		
		return true
	end
	
	-- shorthand to send raw HTML, useful for errors and simple pages
	function HTTPResponse:send_html(status, content)
			self:add_header("Connection", "close")
			self:add_header("Content-type", "text/html")
			self:add_header("Content-length", #content)
			
			self:send_http(
				status,
				content
			)
	end
	
	-- sends raw HTTP data
	function HTTPResponse:send_http(status, body)
		local message = ""
		
		message = message .. self.request.version .. " " .. status .. " OK\r\n"
		
		for i = 1, #self.headers, 1 do
			local header = self.headers[i]
			message = message .. header["header"] .. ": " .. header["value"] .. "\r\n"
		end
		
		message = message .. "\r\n"
		message = message .. body

		self.socket:send(message)
	end
	
	-- sends raw data through the socket with no formatting
	function HTTPResponse:send_raw(data)
		self.socket:send(data)
	end