Stealth Phantom - Guard AI System
Play Stealth Phantom

Here is a server-side stealth AI I scripted, heavily inspired by MGSV (the GOAT of stealth games).

It uses a state machine to handle Idle, Investigate, and Chase behaviors. Guards have a vision cone (using dot product + raycasting) and can pathfind around obstacles. I also hooked up a BindableEvent so they can hear and investigate environmental noises within a certain radius. Network ownership is locked to the server so players can't fling them around.

Here's the core script:

```lua
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local guardsFolder = Workspace:WaitForChild("Guards")
local NoiseEvent = Workspace:WaitForChild("NoiseEvent")

local activeGuards = {}

local SIGHT_RANGE = 50
local IDLE_FOV = 80
local ALERT_FOV = 170
local TICK_RATE = 0.1

local Guard = {}
Guard.__index = Guard

function Guard.new(npc)
	local self = setmetatable({}, Guard)

	self.npc = npc
	self.head = npc:WaitForChild("Head")
	self.humanoid = npc:WaitForChild("Humanoid")
	self.hrp = npc:WaitForChild("HumanoidRootPart")

	self.hrp:SetNetworkOwner(nil) -- lock physics to server
	self.humanoid.WalkSpeed = 8

	self.light = Instance.new("SpotLight")
	self.light.Range = SIGHT_RANGE
	self.light.Angle = IDLE_FOV
	self.light.Brightness = 4
	self.light.Shadows = true
	self.light.Face = Enum.NormalId.Front
	self.light.Parent = self.head

	self.state = "IDLE"
	self.fov = IDLE_FOV
	self.canWander = npc:GetAttribute("CanWander") or false
	self.nextWander = 0
	self.originCFrame = self.hrp.CFrame
	self.isAtOrigin = true

	self.wps = {}
	self.wpIndex = 1
	self.nextPathCheck = 0
	self.targetPos = nil
	self.computingPath = false
	self.wanderPos = nil
	self.lastPos = nil
	self.investigateEnd = 0

	self.rayParams = RaycastParams.new()
	self.rayParams.FilterDescendantsInstances = {self.head.Parent}
	self.rayParams.FilterType = Enum.RaycastFilterType.Exclude

	-- navmesh agent params
	self.path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true
	})

	self.deathConn = self.humanoid.Died:Connect(function()
		self:Destroy()
	end)

	return self
end

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

function Guard:CanSeeTarget(targetChar)
	local targetHrp = targetChar:FindFirstChild("HumanoidRootPart")
	if not targetHrp then return false end

	local dist = (targetHrp.Position - self.head.Position).Magnitude
	if dist > SIGHT_RANGE then return false end

	local dir = (targetHrp.Position - self.head.Position).Unit
	local lookVec = self.head.CFrame.LookVector
	local dot = lookVec:Dot(dir)
	local angle = math.deg(math.acos(dot))

	-- fov + line of sight check
	if angle <= (self.fov / 2) then
		local res = Workspace:Raycast(self.head.Position, dir * dist, self.rayParams)
		if res and res.Instance:IsDescendantOf(targetChar) then
			return true
		end
	end
	return false
end

function Guard:RequestPath(dest)
	if self.computingPath then return end

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
				self.wps = {} -- clear on fail
			end

			self.nextPathCheck = os.clock() + 0.5
			self.computingPath = false
		end)
	end
end

function Guard:FollowPath(fallbackDest, forceMove)
	if self.wps and #self.wps >= self.wpIndex then
		local wp = self.wps[self.wpIndex]
		self.humanoid:MoveTo(wp.Position)

		if wp.Action == Enum.PathWaypointAction.Jump then
			self.humanoid.Jump = true
		end

		local hDist = (self.hrp.Position * Vector3.new(1, 0, 1) - wp.Position * Vector3.new(1, 0, 1)).Magnitude
		if hDist < 3 then
			self.wpIndex = self.wpIndex + 1
		end
	elseif forceMove then
		self.humanoid:MoveTo(fallbackDest)
	end
end

function Guard:Update(players)
	local target = nil

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
			-- check last known location
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
			if os.clock() >= self.investigateEnd then
				self.state = "IDLE"
				self.humanoid.WalkSpeed = 8
				self.fov = IDLE_FOV
				self.light.Angle = IDLE_FOV
				self.light.Color = Color3.fromRGB(255, 255, 255)
				self.nextWander = 0
				self.wps = {}
			else
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
			if self.canWander then
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

local function setupGuard(npc)
	activeGuards[npc] = Guard.new(npc)
end

for _, guard in ipairs(guardsFolder:GetChildren()) do
	if guard:IsA("Model") then setupGuard(guard) end
end

guardsFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then setupGuard(child) end
end)

guardsFolder.ChildRemoved:Connect(function(child)
	if activeGuards[child] then
		activeGuards[child]:Destroy()
		activeGuards[child] = nil
	end
end)

-- audio detection
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

while task.wait(TICK_RATE) do 
	local players = Players:GetPlayers()
	for npc, guardInstance in pairs(activeGuards) do
		guardInstance:Update(players)
	end
end
