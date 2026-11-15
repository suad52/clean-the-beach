--[[
	Signal  --  ReplicatedStorage.Modules.Signal

	Minimal, allocation-light signal. Used instead of BindableEvents because
	BindableEvents deep-copy their arguments, which would strip our live item
	records down to value-only clones and break the shared-state contract.

	Handlers are invoked via task.spawn: one throwing listener can never stop
	the others, and a yielding listener can never stall the firing frame.
]]

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false
	local handlers = self._signal._handlers
	local i = table.find(handlers, self)
	if i then
		table.remove(handlers, i)
	end
end
Connection.Destroy = Connection.Disconnect

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(fn)
	assert(type(fn) == "function", "Signal:Connect expects a function")
	local conn = setmetatable({ _fn = fn, _signal = self, Connected = true }, Connection)
	table.insert(self._handlers, conn)
	return conn
end

function Signal:Once(fn)
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		fn(...)
	end)
	return conn
end

function Signal:Wait()
	local co = coroutine.running()
	local conn
	conn = self:Connect(function(...)
		conn:Disconnect()
		task.spawn(co, ...)
	end)
	return coroutine.yield()
end

function Signal:Fire(...)
	-- Clone first: a handler that disconnects itself mid-fire must not cause
	-- the iteration to skip the sibling that shuffled into its index.
	for _, conn in table.clone(self._handlers) do
		if conn.Connected then
			task.spawn(conn._fn, ...)
		end
	end
end

function Signal:DisconnectAll()
	for _, conn in table.clone(self._handlers) do
		conn:Disconnect()
	end
end
Signal.Destroy = Signal.DisconnectAll

return Signal
