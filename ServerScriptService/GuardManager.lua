local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local PathfindingService = game:GetService("PathfindingService")

local guardsFolder = Workspace:WaitForChild("Guards")

local SIGHT_RANGE = 50
local IDLE_FOV = 80
local ALERT_FOV = 170
local TICK_RATE = 0.1

local activeGuards = {}

local NoiseEvent = Instance.new("BindableEvent")
NoiseEvent.Name = "NoiseEvent"
NoiseEvent.Parent = Workspace

local function setupGuard(npc)
	local head = npc:WaitForChild("Head")
	local humanoid = npc:WaitForChild("Humanoid")
	local rootPart = npc:WaitForChild("HumanoidRootPart")

	rootPart:SetNetworkOwner(nil)
	humanoid.WalkSpeed = 8

	local fovLight = Instance.new("SpotLight")
	fovLight.Range = SIGHT_RANGE
	fovLight.Angle = IDLE_FOV
	fovLight.Brightness = 4
	fovLight.Shadows = true
	fovLight.Face = Enum.NormalId.Front
	fovLight.Parent = head

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.new(0, 50, 0, 50)
	billboard.StudsOffset = Vector3.new(0, 2.5, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = head

	local statusIcon = Instance.new("TextLabel")
	statusIcon.Size = UDim2.new(1, 0, 1, 0)
	statusIcon.BackgroundTransparency = 1
	statusIcon.TextScaled = true
	statusIcon.Font = Enum.Font.FredokaOne
	statusIcon.Text = "?"
	statusIcon.TextColor3 = Color3.fromRGB(200, 200, 200)
	statusIcon.Parent = billboard

	local canWander = npc:GetAttribute("CanWander") or false

	activeGuards[npc] = {
		head = head,
		humanoid = humanoid,
		rootPart = rootPart,
		light = fovLight,
		icon = statusIcon,
		currentState = "IDLE",
		currentFov = IDLE_FOV,
		canWander = canWander,
		nextWanderTick = 0,
		originCFrame = rootPart.CFrame,
		waypoints = {},
		currentWaypointIndex = 1,
		nextPathTick = 0,
		targetPosition = nil,
		isComputingPath = false,
		wanderTarget = nil,
		lastKnownPosition = nil,
		investigateEndTime = 0
	}
end

for _, guard in ipairs(guardsFolder:GetChildren()) do
	if guard:IsA("Model") then
		setupGuard(guard)
	end
end

local function canSeeTarget(guardData, targetChar)
	local targetRoot = targetChar:FindFirstChild("HumanoidRootPart")
	if not targetRoot then return false end

	local head = guardData.head

	local distance = (targetRoot.Position - head.Position).Magnitude
	if distance > SIGHT_RANGE then return false end

	local directionToTarget = (targetRoot.Position - head.Position).Unit
	local lookVector = head.CFrame.LookVector

	local dotProduct = lookVector:Dot(directionToTarget)
	local angle = math.deg(math.acos(dotProduct))

	if angle <= (guardData.currentFov / 2) then
		local raycastParams = RaycastParams.new()
		raycastParams.FilterDescendantsInstances = {head.Parent}
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude

		local rayResult = Workspace:Raycast(head.Position, directionToTarget * distance, raycastParams)

		if rayResult and rayResult.Instance:IsDescendantOf(targetChar) then
			return true
		end
	end

	return false
end

local function requestPath(guardData, destination)
	if guardData.isComputingPath then return end

	if tick() >= guardData.nextPathTick or (guardData.targetPosition and (guardData.targetPosition - destination).Magnitude > 5) then
		guardData.isComputingPath = true
		guardData.targetPosition = destination

		task.spawn(function()
			local path = PathfindingService:CreatePath({
				AgentRadius = 2,
				AgentHeight = 5,
				AgentCanJump = true
			})

			local success, err = pcall(function()
				path:ComputeAsync(guardData.rootPart.Position, destination)
			end)

			if success and path.Status == Enum.PathStatus.Success then
				guardData.waypoints = path:GetWaypoints()
				guardData.currentWaypointIndex = 2
			else
				guardData.waypoints = {}
			end

			guardData.nextPathTick = tick() + 0.5
			guardData.isComputingPath = false
		end)
	end
end

local function followPath(guardData, fallbackDestination)
	if guardData.waypoints and #guardData.waypoints >= guardData.currentWaypointIndex then
		local wp = guardData.waypoints[guardData.currentWaypointIndex]

		guardData.humanoid:MoveTo(wp.Position)

		if wp.Action == Enum.PathWaypointAction.Jump then
			guardData.humanoid.Jump = true
		end

		local horizontalDistance = (guardData.rootPart.Position * Vector3.new(1, 0, 1) - wp.Position * Vector3.new(1, 0, 1)).Magnitude
		if horizontalDistance < 3 then
			guardData.currentWaypointIndex = guardData.currentWaypointIndex + 1
		end
	else
		guardData.humanoid:MoveTo(fallbackDestination)
	end
end

NoiseEvent.Event:Connect(function(noisePosition, noiseRadius)
	for npc, guardData in pairs(activeGuards) do
		if guardData.currentState == "IDLE" or guardData.currentState == "INVESTIGATE" then
			local distance = (guardData.rootPart.Position - noisePosition).Magnitude
			if distance <= noiseRadius then
				guardData.currentState = "INVESTIGATE"
				guardData.humanoid.WalkSpeed = 12
				guardData.currentFov = ALERT_FOV
				guardData.light.Angle = ALERT_FOV
				guardData.light.Color = Color3.fromRGB(255, 200, 0)
				guardData.icon.Text = "?"
				guardData.icon.TextColor3 = Color3.fromRGB(255, 200, 0)

				guardData.investigateEndTime = tick() + 10
				guardData.nextWanderTick = 0
				guardData.lastKnownPosition = noisePosition
				guardData.wanderTarget = noisePosition
				guardData.waypoints = {}
			end
		end
	end
end)

while task.wait(TICK_RATE) do 
	local players = Players:GetPlayers()

	for npc, guardData in pairs(activeGuards) do
		local foundTarget = nil

		for _, player in ipairs(players) do
			local char = player.Character
			if char and char:FindFirstChild("Humanoid") and char.Humanoid.Health > 0 then
				if canSeeTarget(guardData, char) then
					foundTarget = char.HumanoidRootPart
					break 
				end
			end
		end

		if foundTarget then
			if guardData.currentState ~= "CHASE" then
				guardData.currentState = "CHASE"
				guardData.humanoid.WalkSpeed = 16
				guardData.currentFov = ALERT_FOV
				guardData.light.Angle = ALERT_FOV
				guardData.light.Color = Color3.fromRGB(255, 0, 0)
				guardData.icon.Text = "!"
				guardData.icon.TextColor3 = Color3.fromRGB(255, 0, 0)
				guardData.waypoints = {}
			end

			guardData.lastKnownPosition = foundTarget.Position
			requestPath(guardData, foundTarget.Position)
			followPath(guardData, foundTarget.Position)

		else
			if guardData.currentState == "CHASE" then
				guardData.currentState = "INVESTIGATE"
				guardData.humanoid.WalkSpeed = 12
				guardData.currentFov = ALERT_FOV
				guardData.light.Angle = ALERT_FOV
				guardData.light.Color = Color3.fromRGB(255, 200, 0)
				guardData.icon.Text = "?"
				guardData.icon.TextColor3 = Color3.fromRGB(255, 200, 0)
				guardData.investigateEndTime = tick() + 10
				guardData.nextWanderTick = 0
				guardData.wanderTarget = guardData.lastKnownPosition
				guardData.waypoints = {}

			elseif guardData.currentState == "INVESTIGATE" then
				if tick() >= guardData.investigateEndTime then
					guardData.currentState = "IDLE"
					guardData.humanoid.WalkSpeed = 8
					guardData.currentFov = IDLE_FOV
					guardData.light.Angle = IDLE_FOV
					guardData.light.Color = Color3.fromRGB(255, 255, 255)
					guardData.icon.Text = "?"
					guardData.icon.TextColor3 = Color3.fromRGB(200, 200, 200)
					guardData.nextWanderTick = 0
					guardData.waypoints = {}
				else
					if tick() >= guardData.nextWanderTick then
						local randomX = math.random(-15, 15)
						local randomZ = math.random(-15, 15)
						guardData.wanderTarget = guardData.lastKnownPosition + Vector3.new(randomX, 0, randomZ)
						guardData.nextWanderTick = tick() + math.random(2, 4)
						guardData.waypoints = {}
					end

					if guardData.wanderTarget then
						requestPath(guardData, guardData.wanderTarget)
						followPath(guardData, guardData.wanderTarget)
					end
				end

			elseif guardData.currentState == "IDLE" then
				if guardData.canWander then
					if tick() >= guardData.nextWanderTick then
						local randomX = math.random(-25, 25)
						local randomZ = math.random(-25, 25)
						guardData.wanderTarget = guardData.originCFrame.Position + Vector3.new(randomX, 0, randomZ)
						guardData.nextWanderTick = tick() + math.random(4, 10)
						guardData.waypoints = {}
					end

					if guardData.wanderTarget then
						requestPath(guardData, guardData.wanderTarget)
						followPath(guardData, guardData.wanderTarget)
					end
				else
					local distFromOrigin = (guardData.rootPart.Position - guardData.originCFrame.Position).Magnitude
					if distFromOrigin > 2 then
						requestPath(guardData, guardData.originCFrame.Position)
						followPath(guardData, guardData.originCFrame.Position)
					else
						local targetCFrame = CFrame.new(guardData.rootPart.Position) * guardData.originCFrame.Rotation
						guardData.rootPart.CFrame = guardData.rootPart.CFrame:Lerp(targetCFrame, 0.2)
					end
				end
			end
		end
	end
end
