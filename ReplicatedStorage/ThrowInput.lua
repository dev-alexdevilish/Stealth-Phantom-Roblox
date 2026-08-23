local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local player = Players.LocalPlayer
local tool = script.Parent
local throwEvent = ReplicatedStorage:WaitForChild("ThrowItemEvent")

local debounce = false

tool.Activated:Connect(function()
	if debounce then return end
	debounce = true

	local camera = workspace.CurrentCamera
	local lookVector = camera.CFrame.LookVector

	throwEvent:FireServer(lookVector, tool)

	task.wait(1)
	debounce = false
end)
