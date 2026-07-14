local RunService = game:GetService("RunService")

local Optimizer = {}
Optimizer.__index = Optimizer

type source = ((...any) -> ...any) | thread | RBXScriptConnection | Instance | { [any]: any }

type obj = {
	tag: string?,
	source: source,
	disconnect: () -> (),
}

export type Optimizer = typeof(setmetatable(
	{} :: {
		objects: { obj },
	},
	Optimizer
	))

local function createDisconnectFn(source: source): (() -> ())?
	if typeof(source) == "function" then
		return source :: () -> ()
	elseif typeof(source) == "RBXScriptConnection" then
		return function()
			if (source :: RBXScriptConnection).Connected then
				(source :: RBXScriptConnection):Disconnect()
			end
		end
	elseif typeof(source) == "thread" then
		return function()
			if coroutine.status(source :: thread) ~= "dead" then
				task.cancel(source :: thread)
			end
		end
	elseif typeof(source) == "Instance" then
		return function()
			(source :: Instance):Destroy()
		end
	elseif typeof(source) == "table" then
		local sourceTable = source :: any
		if typeof(sourceTable.Destroy) == "function" then
			return function() sourceTable:Destroy() end
		elseif typeof(sourceTable.Disconnect) == "function" then
			return function() sourceTable:Disconnect() end
		elseif typeof(sourceTable.Clean) == "function" then -- Поддержка Maid
			return function() sourceTable:Clean() end
		end
	end
	return nil
end

function Optimizer.new(): Optimizer
	return setmetatable({
		objects = {},
	}, Optimizer) :: Optimizer
end

--[=[
	Tracks an object, connection, or thread in the manager for subsequent cleanup.
	@param tag string?
	@param source any
	@return any
]=]
function Optimizer.Add(self: Optimizer, tag: string?, source: any): any
	if not self.objects then
		return source
	end

	local disconnectFn = createDisconnectFn(source)
	if not disconnectFn then
		return source
	end

	local newObj: obj = {
		tag = tag,
		source = source,
		disconnect = disconnectFn
	}

	table.insert(self.objects, newObj)
	return source
end

--[=[
	Finds and returns the first tracked object matching the specified tag.
	@param tag string
	@return any?
]=]
function Optimizer.Get(self: Optimizer, tag: string): any?
	if not self.objects then return nil end

	for _, object in ipairs(self.objects) do
		if object.tag == tag then
			return object.source
		end
	end

	return nil
end

--[=[
	Executes a callback function once after a specified delay and tracks the generated thread.
	@param tag string?
	@param seconds number
	@param callback (...any) -> ()
	@return thread
]=]
function Optimizer.Delay(
	self: Optimizer,
	tag: string?,
	seconds: number,
	callback: (...any) -> ()
): thread
	local thread: thread

	local function wrapper()
		callback()
	end

	thread = task.delay(seconds, wrapper)
	self:Add(tag, thread)

	return thread
end

--[=[
    WARNING: NOT RECOMMENDED USE 0 OR < 0 SECONDS WILL CRASH THE GAME.   
	Spawns an infinite loop that runs a callback function every N seconds.
	The loop is wrapped in a pcall to prevent execution crashes.
	@param tag string?
	@param seconds number
	@param callback (...any) -> ()
	@return thread
]=]
function Optimizer.Interval(
	self: Optimizer,
	tag: string?,
	seconds: number,
	callback: (...any) -> ()
): thread
	local thread: thread
	
	if seconds <= 0 then
		warn(
			`Failed to create interval '{tag}': seconds must be greater than 0.`,
			`seconds: {seconds}`,
			`traceback: {debug.traceback()}`
		)
		return nil
	end

	thread = task.spawn(function()
		while true do
			task.wait(seconds)

			local success, err = pcall(callback)
			if not success then
				warn(
					`Something went wrong while running interval '{tag or "nil"}'. \n`,
					`error message: {err} \n`,
					`traceback: {debug.traceback(thread)}`
				)
			end
		end
	end)

	self:Add(tag, thread)

	return thread
end

--[=[
	Executes a block of code safely as a single transaction.
	If an error occurs inside the callback, all resources created during this batch 
	under the specified temporary tag will be automatically rolled back and cleaned up.
	@param tag string?
	@param callback (optimizer: Optimizer) -> ()
]=]
function Optimizer.Batch(self: Optimizer, tag: string? | ((optimizer: Optimizer) -> ()), callback: ((optimizer: Optimizer) -> ())?)
	if not self.objects then return end

	local realTag: string?
	local realCallback: (optimizer: Optimizer) -> ()

	if typeof(tag) == "function" then
		realCallback = tag
		realTag = nil
	else
		realTag = tag
		realCallback = callback :: (optimizer: Optimizer) -> ()
	end

	if not realCallback then return end

	local batchAllocations = {}
	local isAborted = false

	local batchProxy = setmetatable({}, {
		__index = function(_, key)
			if key == "Add" then
				return function(_, innerTag, source)
					if isAborted then 
						return source 
					end

					if #batchAllocations >= 5 then
						isAborted = true
						error(
							`Transaction aborted in Batch. \n` ..
								`RENDER LIMIT REACHED \n` ..
								`traceback: {debug.traceback()}`
						)
					end

					local addedSource = self:Add(innerTag or realTag, source)

					if self.objects and #self.objects > 0 then
						local lastObj = self.objects[#self.objects]
						table.insert(batchAllocations, lastObj)
					end

					return addedSource
				end
			elseif key == "CleanUp" then
				return function()
					for i = #batchAllocations, 1, -1 do
						local trackedObj = batchAllocations[i]

						if trackedObj.disconnect then
							pcall(trackedObj.disconnect)
						end

						if self.objects then
							local globalIndex = table.find(self.objects, trackedObj)
							if globalIndex then
								table.remove(self.objects, globalIndex)
							end
						end
						batchAllocations[i] = nil
					end
				end
			end

			return (self :: any)[key]
		end
	})

	local success, err = pcall(realCallback, batchProxy)

	if not success then
		batchProxy:CleanUp()
		
		error(
			`Transaction failed inside Batch '{realTag or "anonymous"}'. Rolling back local allocations! \n` ..
			`error message: {err} \n` ..
			`traceback: {debug.traceback()}`,
			2
		)
	end
end

--[=[
	Connects a function to RunService.Heartbeat and safely tracks the RBXScriptConnection.
	@param tag string?
	@param callback (dt: number) -> ()
	@return () -> ()
]=]
function Optimizer.BindToHeartbeat(
	self: Optimizer,
	tag: string?,
	callback: (dt: number) -> ()
): () -> ()
	local conn: RBXScriptConnection?

	local function disconnect()
		if conn then
			conn:Disconnect()
			conn = nil
		end
	end

	conn = RunService.Heartbeat:Connect(callback)

	self:Add(tag, conn)

	return disconnect
end

--[=[
    Removes and cleans up a specific tracked object by its reference.
    @param source any
    @return boolean
]=]
function Optimizer.Remove(self: Optimizer, source: any): boolean
	if not self.objects then return false end

	for i = #self.objects, 1, -1 do
		local object = self.objects[i]

		if object.source == source then
			if object.disconnect then
				local success, err = pcall(object.disconnect)
				if not success then
					warn(
						`Something went wrong while running remove on object '{object.tag or "nil"}'. \n`,
						`error message: {err} \n`,
						`traceback: {debug.traceback()}`
					)
				end
			end

			table.remove(self.objects, i)
			return true
		end
	end

	return false
end

--[=[
	Locates an object by its tag, cleans it up safely, and removes it from the internal tracker array.
	@param tag string
	@return boolean
]=]
function Optimizer.RemoveByTag(self: Optimizer, tag: string): boolean
	if not self.objects then return false end

	for i = #self.objects, 1, -1 do
		local object = self.objects[i]

		if object.tag == tag then
			if object.disconnect then
				local success, err = pcall(object.disconnect)
				if not success then
					warn(
						`Something went wrong while running remove by tag '{tag}'. \n`,
						`error message: {err} \n`,
						`traceback: {debug.traceback()}`
					)
				end
			end

			table.remove(self.objects, i)
			return true
		end
	end

	return false
end

--[=[
	Cleans up (disconnects, destroys, or cancels) all tracked resources.
	The Optimizer instance remains valid and empty, fully open for reuse.
]=]
function Optimizer.CleanUp(self: Optimizer)
	if not self.objects then return end

	for i = #self.objects, 1, -1 do
		local object = self.objects[i]

		if object.disconnect then
			local success, err = pcall(object.disconnect)
			if not success then
				warn(
					`Something went wrong while running CleanUp on object '{object.tag or "nil"}'. \n`,
					`error message: {err} \n`,
					`traceback: {debug.traceback()}`
				)
			end
		end

		self.objects[i] = nil
	end

	table.clear(self.objects)
end

--[=[
	Completely dismantles the manager. Cleans up all objects, destroys array links, and wipes the metatable.
	The object is corrupted and cannot be used after invoking this method.
]=]
function Optimizer.Destroy(self: Optimizer)
	if not self.objects then 
		return 
	end

	self:CleanUp()

	self.objects = nil

	setmetatable(self, nil)
end

return Optimizer
