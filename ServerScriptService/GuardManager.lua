-- Connected Discord-GitHub
-- Discord: alexdevilish | Roblox: @alexredboyy

--[[
	Stealth AI Guard Framework
	
	Architecture Overview:
	This system utilizes Object-Oriented Programming (OOP) via Luau metatables to encapsulate 
	individual guard logic, state, and pathfinding data.
	
	The AI operates on a Finite State Machine (FSM) with three distinct states: IDLE, INVESTIGATE, and CHASE.
	Environmental awareness is handled via decoupled BindableEvents (NoiseEvent), and vision is optimized 
	by prioritizing cheap magnitude checks before expensive raycasts.
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local guardsFolder = Workspace:WaitForChild("Guards")
local NoiseEvent = Workspace:WaitForChild("NoiseEvent")

local activeGuards = {}

-- Constant configuration variables for easy tuning
local SIGHT_RANGE = 50
local IDLE_FOV = 80
local ALERT_FOV = 170
local TICK_RATE = 0.1

-- Initialize the Guard class
local Guard = {}
Guard.__index = Guard

--[[
	Constructor Method
	Initializes a new guard instance, sets up visual components (SpotLight), 
	establishes default states, and enforces server network ownership to prevent client physics exploits.
]]
function Guard.new(npc)
	local self = setmetatable({}, Guard)

	self.npc = npc
	self.head = npc:WaitForChild("Head")
	self.humanoid = npc:WaitForChild("Humanoid")
	self.hrp = npc:WaitForChild("HumanoidRootPart")

	-- Forcing network ownership to nil ensures the server handles physics, preventing movement jitter
	self.hrp:SetNetworkOwner(nil)
	self.humanoid.WalkSpeed = 8

	-- Visual representation of the guard's field of view
	self.light = Instance.new("SpotLight")
	self.light.Range = SIGHT_RANGE
	self.light.Angle = IDLE_FOV
	self.light.Brightness = 4
	self.light.Shadows = true
	self.light.Face = Enum.NormalId.Front
	self.light.Parent = self.head

	-- State Machine & Pathfinding Properties
	self.state = "IDLE"
	self.fov = IDLE_FOV
	self.canWander = npc:GetAttribute("CanWander") or false
	self.nextWander = 0
	self.originCFrame = self.hrp.CFrame
	self.isAtOrigin = true

	self.wps = {} -- Stores the computed waypoints
	self.wpIndex = 1
	self.nextPathCheck = 0
	self.targetPos = nil
	self.computingPath = false
	self.wanderPos = nil
	self.lastPos = nil
	self.investigateEnd = 0

	-- Cache RaycastParams to avoid instantiating new objects every tick
	self.rayParams = RaycastParams.new()
	self.rayParams.FilterDescendantsInstances = {self.head.Parent}
	self.rayParams.FilterType = Enum.RaycastFilterType.Exclude

	self.path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true
	})

	-- Memory management: Ensure the object destroys itself when the NPC dies
	self.deathConn = self.humanoid.Died:Connect(function()
		self:Destroy()
	end)

	return self
end

--[[
	Destructor Method
	Cleans up memory references, disconnects events, and destroys instances 
	to prevent memory leaks when an NPC is removed from the game.
]]
function Guard:Destroy()
	if self.deathConn then
		self.deathConn:Disconnect()
		self.deathConn = nil
	end

	if self.light then 
		self.light:Destroy() 
	end

	if activeGuards[self.npc] then
		activeGuards[self.npc] = nil
	end
end

--[[
	Vision Logic
	Calculates if a target is visible using a layered approach:
	1. Cheap Magnitude check (Distance)
	2. Directional Dot Product / Angle check (FOV)
	3. Expensive Raycast (Line of Sight)
]]
function Guard:CanSeeTarget(targetChar)
	local targetHrp = targetChar:FindFirstChild("HumanoidRootPart")
	if not targetHrp then return false end

	-- 1. Distance validation
	local dist = (targetHrp.Position - self.head.Position).Magnitude
	if dist > SIGHT_RANGE then return false end

	-- 2. Angle validation using dot product and arc cosine
	local dir = (targetHrp.Position - self.head.Position).Unit
	local lookVec = self.head.CFrame.LookVector
	local dot = lookVec:Dot(dir)
	local angle = math.deg(math.acos(dot))

	if angle <= (self.fov / 2) then
		-- 3. Line of sight validation
		local res = Workspace:Raycast(self.head.Position, dir * dist, self.rayParams)
		if res and res.Instance:IsDescendantOf(targetChar) then
			return true
		end
	end
	return false
end

--[[
	Pathfinding Request Logic
	Asynchronously computes a path to the destination. Throttles requests based on 
	time and target displacement to prevent exhausting the PathfindingService queue.
]]
function Guard:RequestPath(dest)
	if self.computingPath then return end

	-- Only compute if enough time has passed OR the target has moved significantly
	if os.clock() >= self.nextPathCheck or (self.targetPos and (self.targetPos - dest).Magnitude > 5) then
		self.computingPath = true
		self.targetPos = dest

		task.spawn(function()
			local ok, err = pcall(function()
				self.path:ComputeAsync(self.hrp.Position, dest)
			end)

			if ok and self.path.Status == Enum.PathStatus.Success then
				self.wps = self.path:GetWaypoints()
				self.wpIndex = 2
			else
				self.wps = {}
			end

			self.nextPathCheck = os.clock() + 0.5
			self.computingPath = false
		end)
	end
end

--[[
	Movement Logic
	Advances the humanoid to the current waypoint. Includes logic to handle jumps 
	and transition to the next waypoint once the horizontal threshold is reached.
]]
function Guard:FollowPath(fallbackDest, forceMove)
	if self.wps and #self.wps >= self.wpIndex then
		local wp = self.wps[self.wpIndex]
		self.humanoid:MoveTo(wp.Position)

		if wp.Action == Enum.PathWaypointAction.Jump then
			self.humanoid.Jump = true
		end

		-- Check distance purely on the X/Z plane to prevent height discrepancies from stalling movement
		local hDist = (self.hrp.Position * Vector3.new(1, 0, 1) - wp.Position * Vector3.new(1, 0, 1)).Magnitude
		if hDist < 3 then
			self.wpIndex = self.wpIndex + 1
		end
	elseif forceMove then
		self.humanoid:MoveTo(fallbackDest)
	end
end

--[[
	Main State Machine Update
	Evaluates environment and delegates behavior based on current FSM state.
]]
function Guard:Update(players)
	local target = nil

	-- Scan all active players
	for _, p in ipairs(players) do
		local char = p.Character
		if char and char:FindFirstChild("Humanoid") and char.Humanoid.Health > 0 then
			if self:CanSeeTarget(char) then
				target = char.HumanoidRootPart
				break 
			end
		end
	end

	if target then
		-- Target found: Transition to CHASE state
		if self.state ~= "CHASE" then
			self.state = "CHASE"
			self.humanoid.WalkSpeed = 16
			self.fov = ALERT_FOV
			self.light.Angle = ALERT_FOV
			self.light.Color = Color3.fromRGB(255, 0, 0)
			self.wps = {}
			self.isAtOrigin = false
		end

		self.lastPos = target.Position
		self:RequestPath(target.Position)
		self:FollowPath(target.Position, true)

	else
		if self.state == "CHASE" then
			-- Target lost: Transition from CHASE to INVESTIGATE
			self.state = "INVESTIGATE"
			self.humanoid.WalkSpeed = 12
			self.fov = ALERT_FOV
			self.light.Angle = ALERT_FOV
			self.light.Color = Color3.fromRGB(255, 200, 0)
			self.investigateEnd = os.clock() + 10
			self.nextWander = 0
			self.wanderPos = self.lastPos
			self.wps = {}

		elseif self.state == "INVESTIGATE" then
			-- Handle INVESTIGATE state behavior
			if os.clock() >= self.investigateEnd then
				-- Timer expired: Transition back to IDLE
				self.state = "IDLE"
				self.humanoid.WalkSpeed = 8
				self.fov = IDLE_FOV
				self.light.Angle = IDLE_FOV
				self.light.Color = Color3.fromRGB(255, 255, 255)
				self.nextWander = 0
				self.wps = {}
			else
				-- Wander locally around the last known position
				if os.clock() >= self.nextWander then
					local rx = math.random(-15, 15)
					local rz = math.random(-15, 15)
					self.wanderPos = self.lastPos + Vector3.new(rx, 0, rz)
					self.nextWander = os.clock() + math.random(2, 4)
					self.wps = {}
				end

				if self.wanderPos then
					self:RequestPath(self.wanderPos)
					self:FollowPath(self.wanderPos, false)
				end
			end

		elseif self.state == "IDLE" then
			-- Handle IDLE state behavior
			if self.canWander then
				-- Global wandering around the origin
				if os.clock() >= self.nextWander then
					local rx = math.random(-25, 25)
					local rz = math.random(-25, 25)
					self.wanderPos = self.originCFrame.Position + Vector3.new(rx, 0, rz)
					self.nextWander = os.clock() + math.random(4, 10)
					self.wps = {}
				end

				if self.wanderPos then
					self:RequestPath(self.wanderPos)
					self:FollowPath(self.wanderPos, false)
				end
			else
				-- Return to post if wandering is disabled
				local distFromOrigin = (self.hrp.Position - self.originCFrame.Position).Magnitude
				if distFromOrigin > 2 then
					self.isAtOrigin = false
					self:RequestPath(self.originCFrame.Position)
					self:FollowPath(self.originCFrame.Position, false)
				else
					if not self.isAtOrigin then
						self.isAtOrigin = true
						self.hrp.CFrame = CFrame.lookAt(self.hrp.Position, self.hrp.Position + self.originCFrame.LookVector)
					end
				end
			end
		end
	end
end

-- ==========================================
-- System Initialization & Event Management
-- ==========================================

-- Helper function to instantiate new guards safely
local function setupGuard(npc)
	activeGuards[npc] = Guard.new(npc)
end

-- Initial population of guards on script start
for _, guard in ipairs(guardsFolder:GetChildren()) do
	if guard:IsA("Model") then setupGuard(guard) end
end

-- Dynamically attach AI logic to guards spawned during runtime
guardsFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then setupGuard(child) end
end)

-- Ensure memory is cleaned up if a guard model is destroyed externally
guardsFolder.ChildRemoved:Connect(function(child)
	if activeGuards[child] then
		activeGuards[child]:Destroy()
		activeGuards[child] = nil
	end
end)

--[[
	Environmental Noise System
	Decoupled event listener. When a sound (like a thrown rock) occurs, 
	guards within the radius switch to INVESTIGATE state and move toward the sound.
]]
NoiseEvent.Event:Connect(function(noisePos, noiseRadius)
	for npc, guardInstance in pairs(activeGuards) do
		if guardInstance.state == "IDLE" or guardInstance.state == "INVESTIGATE" then
			local dist = (guardInstance.hrp.Position - noisePos).Magnitude
			if dist <= noiseRadius then
				guardInstance.state = "INVESTIGATE"
				guardInstance.humanoid.WalkSpeed = 12
				guardInstance.fov = ALERT_FOV
				guardInstance.light.Angle = ALERT_FOV
				guardInstance.light.Color = Color3.fromRGB(255, 200, 0)

				guardInstance.investigateEnd = os.clock() + 10
				guardInstance.nextWander = 0
				guardInstance.lastPos = noisePos
				guardInstance.wanderPos = noisePos
				guardInstance.wps = {}
				guardInstance.isAtOrigin = false
			end
		end
	end
end)

--[[
	Main System Loop
	Executes the FSM updates on a throttled tick rate (0.1s) to preserve server performance 
	instead of binding to Heartbeat or Stepped.
]]
while task.wait(TICK_RATE) do 
	local players = Players:GetPlayers()
	for npc, guardInstance in pairs(activeGuards) do
		guardInstance:Update(players)
	end
end
