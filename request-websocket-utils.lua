local sha1 = require("sha1")
require("base64")
require("bit")

-- prints a string as hex, was useful for debugging
function hex(str)
	local result = ""
	for i=1, #str, 1 do
		result = result .. string.format("%X ", str:byte(i))
	end
	return result
end

-- breaks a string into individual bytes
function bytes(str)
	local result = {}
	for i=1, #str, 1 do
		result[i]=str:byte(i)
	end
	return result
end

-- returns an integer that can be used to mask the bits passed as argument
local bits = function (...)
	local n = 0
	for i=1,arg.n,1 do
		n = n + 2^arg[i]
	end
	return n
end

-- performs a websocket handshake
function websocket_handshake(key)
	key = key .. "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	key = sha1.binary(key)
	return to_base64(key)
end

-- decrypts an xor encrypted message using the given key, repeated
function decode_xor(buffer, key)
	local n = 1
	local result = ""
	while n < #buffer + 1 do
		result = result .. string.char(bit.bxor(buffer:byte(n), key[1 + ((n - 1) % #key)]))
		n = n + 1
	end
	return result
end

-- checks if the websocket frame specified by a table of bytes is complete
function websocket_frame_complete(bytes)
	local b = 2
	local header_size = 2
	local mask, payload
	
	mask = bit.rshift(bit.band(bytes[b], bits(7)), 7)
	payload = bit.band(bytes[b], bits(0, 1, 2, 3, 4, 5, 6))
	
	b = b + 1
	
	if payload == 126 then
		payload = 0
		
		for i = 1, 0, -1 do
			payload = bit.bor(payload, bit.lshift(bytes[b], 8 * i))
			b = b + 1
		end
		
		header_size = header_size + 2
	elseif payload == 127 then
		payload = 0
		
		for i = 7, 0, -1 do
			payload = bit.bor(payload, bit.lshift(bytes[b], 8 * i))
			b = b + 1
		end
		
		header_size = header_size + 8
	end
	
	if mask == 1 then
		b = b + 4
		header_size = header_size + 4
	end
	
	return #bytes == payload + header_size
end

-- decodes a websocket message from a table of bytes
function websocket_decode(bytes)
	local b = 1
	
	local fin, opcode, mask, payload, key, message
	
	fin = bit.rshift(bit.band(bytes[b], bits(7)), 7)
	opcode = bit.band(bytes[b], bits(0, 1, 2, 3))
	
	b = b + 1
	
	mask = bit.rshift(bit.band(bytes[b], bits(7)), 7)
	payload = bit.band(bytes[b], bits(0, 1, 2, 3, 4, 5, 6))
	
	b = b + 1
	
	if payload == 126 then
		payload = 0
		
		for i = 1, 0, -1 do
			payload = bit.bor(payload, bit.lshift(bytes[b], 8 * i))
			b = b + 1
		end
	elseif payload == 127 then
		payload = 0
		
		for i = 7, 0, -1 do
			payload = bit.bor(payload, bit.lshift(bytes[b], 8 * i))
			b = b + 1
		end
	end
	
	key = {}
	
	if mask == 1 then
		for i = 1, 4, 1 do
			key[#key + 1] = bytes[b]
			b = b + 1
		end
	end
	
	message = ""
	
	local at = 0
	
	while at < payload do
		message = message .. string.char(bytes[b + at])
		at = at + 1
	end
	
	if mask == 1 then
		message = decode_xor(message, key)
	end
	
	return fin, opcode, mask, payload, message
end

-- encodes a message in a websocket frame for sending
function websocket_encode(fin, opcode, body)
	local b = 1
	
	local bytes = {}
	
	bytes[b] = bit.lshift(fin, 7)
	bytes[b] = bit.bor(bytes[b], opcode)
	
	b = b + 1
	
	local size = #body
	
	if size <= 125 then
		bytes[b] = size
		b = b + 1
	elseif size <= 65535 then
		bytes[b] = 126
		b = b + 1
		bytes[b] = bit.band(bit.rshift(size, 8), 0xFF)
		b = b + 1
		bytes[b] = bit.band(size, 0xFF)
		b = b + 1
	elseif size > 65536 then
		bytes[b] = 127
		b = b + 1
		for i = 7, 1, -1 do
			bytes[b] = bit.band(bit.rshift(size, i * 8), 0xFF)
			b = b + 1
		end
	end
	
	for i = 1, #body, 1 do
		bytes[b] = body:byte(i)
		b = b + 1
	end
	
	local buffer = ""
	for i = 1, b - 1, 1 do
		buffer = buffer .. string.char(bytes[i])
	end
	
	return buffer
end

--[[
	a simple interface for websockets
]]--
class "WebSocketClient"
	function WebSocketClient:__init(socket, handlers)
		self.socket = socket
		self.id = self.socket.peer_address .. ":" .. self.socket.peer_port
		
		self.opcode = 0
		self.buffer = ""
		
		self.handlers = handlers
		
		self.socket_buffer = ""
	end
	
	function WebSocketClient:process(message)
		-- we can't assume the message is complete, sadly
		self.socket_buffer = self.socket_buffer .. message
		
		if not websocket_frame_complete(bytes(self.socket_buffer)) then
			return
		end
		
		local fin, opcode, mask, payload, message = 
			websocket_decode(bytes(self.socket_buffer))
		
		self.socket_buffer = ""
		
		if fin == 1 then
			if opcode ~= 0 then
				self.opcode = opcode
			end
			
			self.buffer = self.buffer .. message
			
			-- respond to pings with a pong
			if self.opcode == 9 then
				self:send(1, 10, message)
				
				self.buffer = ""
				self.opcode = 0
				
				return
			end
			
			-- respond to close requests
			if self.opcode == 8 then
				if self.handlers.on_close ~= nil then
					self.handlers.on_close(self)
				end
				
				self.buffer = ""
				self.opcode = 0
				
				return
			end
			
			if self.handlers.on_message ~= nil then
				self.handlers.on_message(self, self.opcode, self.buffer)
			end
			
			self.buffer = ""
			self.opcode = 0
		else
			if opcode ~= 0 then
				self.opcode = opcode
			end
			
			self.buffer = self.buffer .. message
		end
	end
	
	function WebSocketClient:send(fin, opcode, message)
		local encoded = websocket_encode(fin, opcode, message)
		
		local success, socket_error = self.socket:send(encoded)
		
		if not success then
			renoise.app():show_warning(socket_error)
		end
	end