local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local throwEvent = ReplicatedStorage:WaitForChild("ThrowItemEvent")

throwEvent.OnServerEvent:Connect(function(player, lookVector, tool)
	if typeof(lookVector) ~= "Vector3" then return end
	if not tool or tool.Parent ~= player.Character then return end

	local character = player.Character
	if not character or not character:FindFirstChild("Head") then return end

	local handle = tool:FindFirstChild("Handle")
	if not handle then return end

	local throwOrigin = character.Head.Position

	local projectile = handle:Clone()
	projectile.Name = "ThrownItem"

	for _, child in ipairs(projectile:GetChildren()) do
		if child:IsA("JointInstance") or child:IsA("Weld") or child:IsA("WeldConstraint") then
			child:Destroy()
		end
	end

	projectile.CFrame = CFrame.lookAt(throwOrigin + (lookVector * 3), throwOrigin + (lookVector * 10))
	projectile.CanCollide = false 
	projectile.Anchored = false

	projectile.Parent = workspace

	projectile:SetNetworkOwner(player)

	projectile.AssemblyLinearVelocity = (lookVector * 80) + Vector3.new(0, 15, 0)
	projectile.AssemblyAngularVelocity = Vector3.new(math.random(-20, 20), math.random(-20, 20), math.random(-20, 20))

	tool:Destroy()

	Debris:AddItem(projectile, 120)

	task.delay(0.1, function()
		if projectile and projectile.Parent then
			projectile.CanCollide = true
		end
	end)

	local hasCollided = false
	local canBePickedUp = false

	local connection
	connection = projectile.Touched:Connect(function(hit)
		if not canBePickedUp then
			if not hit:IsDescendantOf(character) and not hasCollided then
				hasCollided = true

				local NoiseEvent = workspace:FindFirstChild("NoiseEvent")
				if NoiseEvent then
					NoiseEvent:Fire(projectile.Position, 45)
				end

				task.delay(1.5, function()
					if projectile and projectile.Parent then
						projectile.Anchored = true
						canBePickedUp = true
					end
				end)
			end
		else
			local hitChar = hit.Parent
			local humanoid = hitChar:FindFirstChild("Humanoid")
			if humanoid then
				local hitPlayer = game.Players:GetPlayerFromCharacter(hitChar)
				if hitPlayer then
					local backpack = hitPlayer:FindFirstChild("Backpack")
					if backpack then
						connection:Disconnect()

						local newTool = Instance.new("Tool")
						newTool.Name = "Rock"

						local newHandle = projectile:Clone()
						newHandle.Name = "Handle"
						newHandle.Anchored = false
						newHandle.CanCollide = false
						newHandle.Transparency = 0
						for _, c in ipairs(newHandle:GetChildren()) do
							if not c:IsA("SpecialMesh") and not c:IsA("CylinderMesh") and not c:IsA("BlockMesh") then
								c:Destroy()
							end
						end
						newHandle.Parent = newTool

						local scriptTemplate = ReplicatedStorage:FindFirstChild("ThrowInput")
						if scriptTemplate then
							scriptTemplate:Clone().Parent = newTool
						end

						newTool.Parent = backpack
						projectile:Destroy()
					end
				end
			end
		end
	end)
end)
