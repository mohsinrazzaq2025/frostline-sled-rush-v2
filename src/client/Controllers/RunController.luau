--!strict

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local RunPhase = require(ReplicatedStorage.Shared.RunPhase)

local ACTION_NAME = "FrostlineTuck"
local JUMP_BLOCK_ACTION_NAME = "FrostlineRunJumpBlock"
local JUMP_BLOCK_PRIORITY = Enum.ContextActionPriority.High.Value + 1
local REMOTES_FOLDER_NAME = "FrostlineRemotes"
local TUCK_REMOTE_NAME = "TuckIntent"
local STATE_REMOTE_NAME = "RunState"
local TUCK_DEFAULT_COLOR = Color3.fromRGB(244, 190, 70)
local TUCK_READY_COLOR = Color3.fromRGB(64, 224, 200)
local TUCK_ACTIVE_COLOR = Color3.fromRGB(104, 255, 138)
local TUCK_FLIGHT_COLOR = Color3.fromRGB(150, 218, 242)
local PHASE_DEFAULT_COLOR = Color3.fromRGB(250, 251, 252)
local MISSED_LAUNCH_COLOR = Color3.fromRGB(230, 91, 53)
local MISSED_LAUNCH_DETAIL_COLOR = Color3.fromRGB(255, 184, 82)
local MISSED_LAUNCH_OUTCOME = "missed-launch"
local MINIMUM_TOUCH_BUTTON_GAP = 16
local TOUCH_LAYOUT_RETRY_DELAY = 0.25
local TOUCH_LAYOUT_RETRY_COUNT = 20

type Hud = {
	ScreenGui: ScreenGui,
	CountdownLabel: TextLabel,
	PhaseLabel: TextLabel,
	SpeedLabel: TextLabel,
	TuckLabel: TextLabel,
}

type HeldInputs = {
	LeftShift: boolean,
	RightShift: boolean,
	GamepadL2: boolean,
	Mobile: boolean,
}

local RunController = {}

local started = false

local function addTextSizeConstraint(label: TextLabel, minimum: number, maximum: number)
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MinTextSize = minimum
	constraint.MaxTextSize = maximum
	constraint.Parent = label
end

local function createHud(defaultTuckInstruction: string): Hud
	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui")
	if not playerGui:IsA("PlayerGui") then
		error("PlayerGui was not available")
	end

	local previous = playerGui:FindFirstChild("FrostlineRunHud")
	if previous then
		previous:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "FrostlineRunHud"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.DisplayOrder = 10
	screenGui.Parent = playerGui

	local statusPanel = Instance.new("Frame")
	statusPanel.Name = "StatusPanel"
	statusPanel.Size = UDim2.fromScale(0.28, 0.135)
	statusPanel.Position = UDim2.fromScale(0.025, 0.045)
	statusPanel.BackgroundColor3 = Color3.fromRGB(16, 31, 52)
	statusPanel.BackgroundTransparency = 0.12
	statusPanel.BorderSizePixel = 0
	statusPanel.Parent = screenGui

	local panelConstraint = Instance.new("UISizeConstraint")
	panelConstraint.MinSize = Vector2.new(210, 92)
	panelConstraint.MaxSize = Vector2.new(430, 165)
	panelConstraint.Parent = statusPanel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.08, 0)
	corner.Parent = statusPanel

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(244, 190, 70)
	stroke.Thickness = 2
	stroke.Transparency = 0.18
	stroke.Parent = statusPanel

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.09, 0)
	padding.PaddingBottom = UDim.new(0.09, 0)
	padding.PaddingLeft = UDim.new(0.07, 0)
	padding.PaddingRight = UDim.new(0.07, 0)
	padding.Parent = statusPanel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0.035, 0)
	layout.Parent = statusPanel

	local phaseLabel = Instance.new("TextLabel")
	phaseLabel.Name = "Phase"
	phaseLabel.Size = UDim2.fromScale(1, 0.28)
	phaseLabel.BackgroundTransparency = 1
	phaseLabel.Font = Enum.Font.GothamBold
	phaseLabel.Text = "Phase: Idle"
	phaseLabel.TextColor3 = Color3.fromRGB(250, 251, 252)
	phaseLabel.TextScaled = true
	phaseLabel.TextXAlignment = Enum.TextXAlignment.Left
	phaseLabel.Parent = statusPanel
	addTextSizeConstraint(phaseLabel, 13, 26)

	local speedLabel = Instance.new("TextLabel")
	speedLabel.Name = "Speed"
	speedLabel.Size = UDim2.fromScale(1, 0.28)
	speedLabel.BackgroundTransparency = 1
	speedLabel.Font = Enum.Font.GothamBlack
	speedLabel.Text = "Speed: 0 studs/s"
	speedLabel.TextColor3 = Color3.fromRGB(150, 218, 242)
	speedLabel.TextScaled = true
	speedLabel.TextXAlignment = Enum.TextXAlignment.Left
	speedLabel.Parent = statusPanel
	addTextSizeConstraint(speedLabel, 13, 28)

	local instructionLabel = Instance.new("TextLabel")
	instructionLabel.Name = "TuckInstruction"
	instructionLabel.Size = UDim2.fromScale(1, 0.28)
	instructionLabel.BackgroundTransparency = 1
	instructionLabel.Font = Enum.Font.GothamMedium
	instructionLabel.Text = defaultTuckInstruction
	instructionLabel.TextColor3 = TUCK_DEFAULT_COLOR
	instructionLabel.TextScaled = true
	instructionLabel.TextXAlignment = Enum.TextXAlignment.Left
	instructionLabel.Parent = statusPanel
	addTextSizeConstraint(instructionLabel, 12, 23)

	local countdownLabel = Instance.new("TextLabel")
	countdownLabel.Name = "Countdown"
	countdownLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	countdownLabel.Size = UDim2.fromScale(0.24, 0.2)
	countdownLabel.Position = UDim2.fromScale(0.5, 0.3)
	countdownLabel.BackgroundTransparency = 1
	countdownLabel.Font = Enum.Font.GothamBlack
	countdownLabel.Text = ""
	countdownLabel.TextColor3 = Color3.fromRGB(250, 251, 252)
	countdownLabel.TextStrokeColor3 = Color3.fromRGB(188, 38, 51)
	countdownLabel.TextStrokeTransparency = 0.08
	countdownLabel.TextScaled = true
	countdownLabel.Visible = false
	countdownLabel.Parent = screenGui
	addTextSizeConstraint(countdownLabel, 42, 118)

	return {
		ScreenGui = screenGui,
		CountdownLabel = countdownLabel,
		PhaseLabel = phaseLabel,
		SpeedLabel = speedLabel,
		TuckLabel = instructionLabel,
	}
end

local function findDefaultJumpButton(playerGui: PlayerGui): GuiObject?
	local touchGui = playerGui:FindFirstChild("TouchGui")
	if not touchGui then
		return nil
	end

	local jumpButton = touchGui:FindFirstChild("JumpButton", true)
	if jumpButton and jumpButton:IsA("GuiObject") then
		return jumpButton
	end

	return nil
end

local function findJumpButton(playerGui: PlayerGui): GuiObject?
	local jumpButton = findDefaultJumpButton(playerGui)
	if jumpButton and jumpButton.AbsoluteSize.Magnitude > 0 then
		return jumpButton
	end

	return nil
end

local function shouldBlockJump(phase: string): boolean
	return phase == RunPhase.Countdown
		or phase == RunPhase.Descent
		or phase == RunPhase.Airborne
		or phase == RunPhase.Landed
		or phase == RunPhase.Results
end

local function getSafeBounds(): (Vector2, Vector2)
	local succeeded, insetArea = pcall(function()
		return GuiService:GetInsetArea(Enum.ScreenInsets.DeviceSafeInsets)
	end)
	if succeeded and typeof(insetArea) == "Rect" then
		return insetArea.Min, insetArea.Max
	end

	local camera = Workspace.CurrentCamera
	if camera then
		return Vector2.zero, camera.ViewportSize
	end

	return Vector2.zero, Vector2.zero
end
local function clampButtonTopLeft(
	topLeft: Vector2,
	buttonSize: Vector2,
	safeMinimum: Vector2,
	safeMaximum: Vector2
): Vector2
	local maximumX = math.max(safeMinimum.X, safeMaximum.X - buttonSize.X)
	local maximumY = math.max(safeMinimum.Y, safeMaximum.Y - buttonSize.Y)
	return Vector2.new(
		math.clamp(topLeft.X, safeMinimum.X, maximumX),
		math.clamp(topLeft.Y, safeMinimum.Y, maximumY)
	)
end

local function setAbsoluteButtonPosition(button: GuiObject, topLeft: Vector2): boolean
	local parent = button.Parent
	if not parent or not parent:IsA("GuiObject") then
		return false
	end

	local parentSize = parent.AbsoluteSize
	if parentSize.X <= 0 or parentSize.Y <= 0 then
		return false
	end

	local buttonSize = button.AbsoluteSize
	local anchorPoint = button.AnchorPoint
	local absoluteAnchor = Vector2.new(
		topLeft.X + buttonSize.X * anchorPoint.X,
		topLeft.Y + buttonSize.Y * anchorPoint.Y
	)
	local localAnchor = absoluteAnchor - parent.AbsolutePosition
	ContextActionService:SetPosition(
		ACTION_NAME,
		UDim2.fromScale(localAnchor.X / parentSize.X, localAnchor.Y / parentSize.Y)
	)
	return true
end

local function setupTouchButtonLayout()
	local playerGuiInstance = Players.LocalPlayer:WaitForChild("PlayerGui")
	if not playerGuiInstance:IsA("PlayerGui") then
		return
	end
	local playerGui = playerGuiInstance

	local observedJumpButton: GuiObject? = nil
	local jumpConnections: { RBXScriptConnection } = {}
	local observedTuckButton: GuiObject? = nil
	local tuckConnections: { RBXScriptConnection } = {}
	local cameraConnection: RBXScriptConnection? = nil
	local layoutGeneration = 0
	local requestLayout: () -> ()

	local function clearJumpConnections()
		for _, connection in jumpConnections do
			connection:Disconnect()
		end
		table.clear(jumpConnections)
	end

	local function clearTuckConnections()
		for _, connection in tuckConnections do
			connection:Disconnect()
		end
		table.clear(tuckConnections)
	end

	local function observeJumpButton(jumpButton: GuiObject?)
		if observedJumpButton == jumpButton then
			return
		end

		clearJumpConnections()
		observedJumpButton = jumpButton
		if not jumpButton then
			return
		end

		table.insert(jumpConnections, jumpButton:GetPropertyChangedSignal("AbsolutePosition"):Connect(requestLayout))
		table.insert(jumpConnections, jumpButton:GetPropertyChangedSignal("AbsoluteSize"):Connect(requestLayout))
		table.insert(jumpConnections, jumpButton:GetPropertyChangedSignal("Visible"):Connect(requestLayout))
		table.insert(jumpConnections, jumpButton.AncestryChanged:Connect(requestLayout))
	end

	local function observeTuckButton(tuckButton: GuiObject?)
		if observedTuckButton == tuckButton then
			return
		end

		clearTuckConnections()
		observedTuckButton = tuckButton
		if not tuckButton then
			return
		end

		table.insert(tuckConnections, tuckButton:GetPropertyChangedSignal("AbsoluteSize"):Connect(requestLayout))
		table.insert(tuckConnections, tuckButton.AncestryChanged:Connect(requestLayout))
		local parent = tuckButton.Parent
		if parent and parent:IsA("GuiObject") then
			table.insert(tuckConnections, parent:GetPropertyChangedSignal("AbsolutePosition"):Connect(requestLayout))
			table.insert(tuckConnections, parent:GetPropertyChangedSignal("AbsoluteSize"):Connect(requestLayout))
		end
	end

	local function applyLayout(): boolean
		local tuckButtonInstance = ContextActionService:GetButton(ACTION_NAME)
		if not tuckButtonInstance or not tuckButtonInstance:IsA("GuiObject") then
			observeTuckButton(nil)
			return false
		end
		local tuckButton = tuckButtonInstance
		observeTuckButton(tuckButton)
		local tuckSize = tuckButton.AbsoluteSize
		if tuckSize.X <= 0 or tuckSize.Y <= 0 then
			return false
		end

		local parent = tuckButton.Parent
		if not parent or not parent:IsA("GuiObject") then
			return false
		end
		local safeMinimum, safeMaximum = getSafeBounds()
		if safeMaximum.X <= safeMinimum.X or safeMaximum.Y <= safeMinimum.Y then
			return false
		end
		local jumpButton = findJumpButton(playerGui)
		observeJumpButton(jumpButton)

		local desiredTopLeft: Vector2
		if jumpButton then
			local jumpPosition = jumpButton.AbsolutePosition
			local jumpSize = jumpButton.AbsoluteSize
			local leftOfJump = Vector2.new(
				jumpPosition.X - MINIMUM_TOUCH_BUTTON_GAP - tuckSize.X,
				jumpPosition.Y + (jumpSize.Y - tuckSize.Y) * 0.5
			)
			if leftOfJump.X >= safeMinimum.X then
				desiredTopLeft = leftOfJump
			else
				-- Extremely narrow safe areas cannot fit another button to Jump's left.
				-- Prefer a separated position directly above it instead of overlapping.
				local aboveJump = Vector2.new(
					jumpPosition.X + (jumpSize.X - tuckSize.X) * 0.5,
					jumpPosition.Y - MINIMUM_TOUCH_BUTTON_GAP - tuckSize.Y
				)
				desiredTopLeft = if aboveJump.Y >= safeMinimum.Y
					then aboveJump
					else Vector2.new(
						(safeMinimum.X + safeMaximum.X - tuckSize.X) * 0.5,
						(safeMinimum.Y + safeMaximum.Y - tuckSize.Y) * 0.5
					)
			end
		else
			-- Screen center is a conservative temporary location away from the
			-- lower-right area where Roblox creates Jump.
			desiredTopLeft = Vector2.new(
				(safeMinimum.X + safeMaximum.X - tuckSize.X) * 0.5,
				(safeMinimum.Y + safeMaximum.Y - tuckSize.Y) * 0.5
			)
		end

		local clampedTopLeft = clampButtonTopLeft(desiredTopLeft, tuckSize, safeMinimum, safeMaximum)
		return setAbsoluteButtonPosition(tuckButton, clampedTopLeft) and jumpButton ~= nil
	end

	local function attemptLayout(generation: number, retriesRemaining: number)
		task.defer(function()
			if generation ~= layoutGeneration then
				return
			end

			local positionedBesideJump = applyLayout()
			if not positionedBesideJump and retriesRemaining > 0 then
				task.delay(TOUCH_LAYOUT_RETRY_DELAY, function()
					attemptLayout(generation, retriesRemaining - 1)
				end)
			end
		end)
	end

	requestLayout = function()
		layoutGeneration += 1
		attemptLayout(layoutGeneration, TOUCH_LAYOUT_RETRY_COUNT)
	end

	local function observeCurrentCamera()
		if cameraConnection then
			cameraConnection:Disconnect()
			cameraConnection = nil
		end

		local camera = Workspace.CurrentCamera
		if camera then
			cameraConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(requestLayout)
		end
		requestLayout()
	end

	playerGui.DescendantAdded:Connect(function(descendant: Instance)
		if descendant.Name == "JumpButton"
			or descendant.Name == "ContextActionGui"
			or descendant.Name == ACTION_NAME
		then
			requestLayout()
		end
	end)
	playerGui:GetPropertyChangedSignal("CurrentScreenOrientation"):Connect(requestLayout)
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(observeCurrentCamera)
	GuiService:GetPropertyChangedSignal("ViewportDisplaySize"):Connect(requestLayout)
	observeCurrentCamera()
end

function RunController.start()
	if started then
		return
	end
	started = true

	local remoteFolder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME)
	if not remoteFolder:IsA("Folder") then
		error("FrostlineRemotes must be a Folder")
	end

	local tuckRemote = remoteFolder:WaitForChild(TUCK_REMOTE_NAME)
	local runStateRemote = remoteFolder:WaitForChild(STATE_REMOTE_NAME)
	if not tuckRemote:IsA("RemoteEvent") then
		error("TuckIntent must be a RemoteEvent")
	end
	if not runStateRemote:IsA("RemoteEvent") then
		error("RunState must be a RemoteEvent")
	end

	local usesMobileTuckInstructions = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	local defaultTuckInstruction = if usesMobileTuckInstructions then "Hold TUCK to Tuck" else "Hold Shift to Tuck"
	local prepareTuckInstruction = if usesMobileTuckInstructions
		then "Hold TUCK to prepare"
		else "Hold Shift to prepare Tuck"
	local hud = createHud(defaultTuckInstruction)
	local heldInputs: HeldInputs = {
		LeftShift = false,
		RightShift = false,
		GamepadL2 = false,
		Mobile = false,
	}
	local tuckHeld = false
	local currentPhase: string = RunPhase.Idle
	local currentRunId: number? = nil
	local latestRunId = 0
	local lastSentRunId: number? = nil
	local lastSentIntent: boolean? = nil
	local serverTuckQueued = false
	local serverTucking = false
	local currentOutcome: string? = nil
	local player = Players.LocalPlayer
	local playerGuiInstance = hud.ScreenGui.Parent
	if not playerGuiInstance or not playerGuiInstance:IsA("PlayerGui") then
		error("FrostlineRunHud must be parented to PlayerGui")
	end
	local playerGui = playerGuiInstance
	local jumpBlockActive = false
	local jumpActionBound = false
	local jumpBlockDestroyed = false
	local jumpBlockSuppressedRunId: number? = nil
	local blockedHumanoid: Humanoid? = nil
	local previousJumpingEnabled: boolean? = nil
	local jumpVisibilityBaseline: boolean? = nil
	local jumpButtonRestoreVisibility: { [GuiObject]: boolean } = {}
	local jumpButtonVisibilityConnections: { [GuiObject]: RBXScriptConnection } = {}
	local jumpLifecycleConnections: { RBXScriptConnection } = {}

	local function clearPendingJump()
		local humanoid = blockedHumanoid
		if humanoid then
			pcall(function()
				humanoid.Jump = false
			end)
		end
	end

	local function restoreBlockedHumanoid()
		local humanoid = blockedHumanoid
		local jumpingWasEnabled = previousJumpingEnabled
		blockedHumanoid = nil
		previousJumpingEnabled = nil

		if humanoid and jumpingWasEnabled ~= nil then
			pcall(function()
				humanoid.Jump = false
			end)
			pcall(function()
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, jumpingWasEnabled)
			end)
		end
	end

	local function blockCurrentHumanoid()
		local character = player.Character
		if not character then
			error("active run character is unavailable")
		end

		local humanoidInstance = character:FindFirstChildOfClass("Humanoid")
		if not humanoidInstance then
			error("active run Humanoid is unavailable")
		end
		local humanoid = humanoidInstance

		if blockedHumanoid ~= humanoid then
			restoreBlockedHumanoid()
			previousJumpingEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping)
			blockedHumanoid = humanoid
		end

		humanoid.Jump = false
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
		humanoid.Jump = false
	end

	local function hideJumpButton(jumpButton: GuiObject, captureBaseline: boolean)
		if jumpButtonVisibilityConnections[jumpButton] == nil then
			if captureBaseline then
				jumpVisibilityBaseline = jumpButton.Visible
			end
			if jumpVisibilityBaseline ~= nil then
				jumpButtonRestoreVisibility[jumpButton] = jumpVisibilityBaseline
			end
			jumpButtonVisibilityConnections[jumpButton] = jumpButton
				:GetPropertyChangedSignal("Visible")
				:Connect(function()
					if jumpBlockActive and jumpButton.Parent and jumpButton.Visible then
						jumpButton.Visible = false
					end
				end)
		end

		jumpButton.Visible = false
	end

	local function hideCurrentJumpButton(captureBaseline: boolean)
		local jumpButton = findDefaultJumpButton(playerGui)
		if jumpButton then
			hideJumpButton(jumpButton, captureBaseline)
		end
	end

	local function restoreJumpButtons()
		for _, connection in jumpButtonVisibilityConnections do
			connection:Disconnect()
		end
		table.clear(jumpButtonVisibilityConnections)

		for jumpButton, wasVisible in jumpButtonRestoreVisibility do
			pcall(function()
				jumpButton.Visible = wasVisible
			end)
		end
		table.clear(jumpButtonRestoreVisibility)
		jumpVisibilityBaseline = nil
	end

	local function handleBlockedJump(
		_actionName: string,
		_inputState: Enum.UserInputState,
		_inputObject: InputObject
	): Enum.ContextActionResult
		clearPendingJump()
		return Enum.ContextActionResult.Sink
	end

	local function deactivateJumpBlock()
		clearPendingJump()
		jumpBlockActive = false
		if jumpActionBound then
			jumpActionBound = false
			pcall(function()
				ContextActionService:UnbindAction(JUMP_BLOCK_ACTION_NAME)
			end)
		end
		restoreBlockedHumanoid()
		restoreJumpButtons()
	end

	local function activateJumpBlock(): boolean
		if jumpBlockDestroyed then
			return false
		end
		if jumpBlockActive then
			clearPendingJump()
			hideCurrentJumpButton(false)
			return true
		end

		jumpBlockActive = true
		local succeeded, failureReason = pcall(function()
			ContextActionService:BindActionAtPriority(
				JUMP_BLOCK_ACTION_NAME,
				handleBlockedJump,
				false,
				JUMP_BLOCK_PRIORITY,
				Enum.PlayerActions.CharacterJump,
				Enum.KeyCode.Space,
				Enum.KeyCode.ButtonA
			)
			jumpActionBound = true
			hideCurrentJumpButton(true)
			blockCurrentHumanoid()
		end)
		if not succeeded then
			deactivateJumpBlock()
			warn(string.format("[Frostline] Jump blocker failed: %s", tostring(failureReason)))
			return false
		end

		return true
	end

	local function cancelJumpBlockForCurrentRun()
		jumpBlockSuppressedRunId = currentRunId
		deactivateJumpBlock()
	end

	local function updateJumpBlockForPhase(runId: number)
		if jumpBlockSuppressedRunId ~= nil and jumpBlockSuppressedRunId ~= runId then
			jumpBlockSuppressedRunId = nil
		end

		if shouldBlockJump(currentPhase) and jumpBlockSuppressedRunId ~= runId then
			if not activateJumpBlock() then
				jumpBlockSuppressedRunId = runId
			end
		else
			deactivateJumpBlock()
			if currentPhase == RunPhase.Idle then
				jumpBlockSuppressedRunId = nil
			end
		end
	end

	local function destroyJumpBlocker()
		if jumpBlockDestroyed then
			return
		end
		jumpBlockDestroyed = true
		deactivateJumpBlock()

		for _, connection in jumpLifecycleConnections do
			connection:Disconnect()
		end
		table.clear(jumpLifecycleConnections)
	end

	table.insert(jumpLifecycleConnections, UserInputService.JumpRequest:Connect(function()
		if jumpBlockActive then
			clearPendingJump()
		end
	end))
	table.insert(jumpLifecycleConnections, playerGui.DescendantAdded:Connect(function(descendant: Instance)
		local touchGui = playerGui:FindFirstChild("TouchGui")
		if jumpBlockActive
			and not jumpBlockDestroyed
			and descendant.Name == "JumpButton"
			and descendant:IsA("GuiObject")
			and touchGui
			and descendant:IsDescendantOf(touchGui)
		then
			hideJumpButton(descendant, false)
		end
	end))
	table.insert(jumpLifecycleConnections, player.CharacterRemoving:Connect(function(_character: Model)
		if jumpBlockActive then
			cancelJumpBlockForCurrentRun()
		end
	end))
	table.insert(jumpLifecycleConnections, player.CharacterAdded:Connect(function(_character: Model)
		if jumpBlockActive then
			cancelJumpBlockForCurrentRun()
		end
	end))
	table.insert(jumpLifecycleConnections, hud.ScreenGui.Destroying:Connect(destroyJumpBlocker))
	table.insert(jumpLifecycleConnections, script.Destroying:Connect(destroyJumpBlocker))

	local function isShowingMissedLaunch(): boolean
		return currentOutcome == MISSED_LAUNCH_OUTCOME and currentPhase ~= RunPhase.Idle
	end

	local function updatePhaseFeedback()
		hud.PhaseLabel.TextColor3 = PHASE_DEFAULT_COLOR
		hud.PhaseLabel.Font = Enum.Font.GothamBold
		if isShowingMissedLaunch() then
			hud.PhaseLabel.Text = "MISSED LAUNCH"
			hud.PhaseLabel.TextColor3 = MISSED_LAUNCH_COLOR
			hud.PhaseLabel.Font = Enum.Font.GothamBlack
		elseif currentPhase == RunPhase.Landed then
			hud.PhaseLabel.Text = "LANDED! • Slowing down…"
		elseif currentPhase == RunPhase.Results or currentPhase == RunPhase.Reset then
			hud.PhaseLabel.Text = "RUN COMPLETE"
		else
			hud.PhaseLabel.Text = string.format("Phase: %s", currentPhase)
		end
	end

	local function updateTuckFeedback()
		if isShowingMissedLaunch() then
			hud.TuckLabel.Text = "Run ended — resetting"
			hud.TuckLabel.TextColor3 = MISSED_LAUNCH_DETAIL_COLOR
			hud.TuckLabel.Font = Enum.Font.GothamBold
		elseif currentPhase == RunPhase.Countdown then
			if tuckHeld then
				hud.TuckLabel.Text = "TUCK READY — activates at GO"
				hud.TuckLabel.TextColor3 = TUCK_READY_COLOR
				hud.TuckLabel.Font = Enum.Font.GothamBlack
			else
				hud.TuckLabel.Text = prepareTuckInstruction
				hud.TuckLabel.TextColor3 = TUCK_DEFAULT_COLOR
				hud.TuckLabel.Font = Enum.Font.GothamMedium
			end
		elseif currentPhase == RunPhase.Descent then
			if tuckHeld and serverTucking then
				hud.TuckLabel.Text = "TUCK ACTIVE"
				hud.TuckLabel.TextColor3 = TUCK_ACTIVE_COLOR
				hud.TuckLabel.Font = Enum.Font.GothamBlack
			else
				hud.TuckLabel.Text = defaultTuckInstruction
				hud.TuckLabel.TextColor3 = TUCK_DEFAULT_COLOR
				hud.TuckLabel.Font = Enum.Font.GothamMedium
			end
		elseif currentPhase == RunPhase.Airborne then
			hud.TuckLabel.Text = "BALLISTIC FLIGHT"
			hud.TuckLabel.TextColor3 = TUCK_FLIGHT_COLOR
			hud.TuckLabel.Font = Enum.Font.GothamBold
		else
			hud.TuckLabel.Text = defaultTuckInstruction
			hud.TuckLabel.TextColor3 = TUCK_DEFAULT_COLOR
			hud.TuckLabel.Font = Enum.Font.GothamMedium
		end
	end

	local function sendTuckIntent(forceSend: boolean)
		local runId = currentRunId
		if runId == nil
			or (currentPhase ~= RunPhase.Countdown and currentPhase ~= RunPhase.Descent)
		then
			return
		end
		if not forceSend and lastSentRunId == runId and lastSentIntent == tuckHeld then
			return
		end

		lastSentRunId = runId
		lastSentIntent = tuckHeld
		tuckRemote:FireServer(runId, tuckHeld)
	end

	local function refreshTuckHeld(sendIntent: boolean)
		local held = heldInputs.LeftShift
			or heldInputs.RightShift
			or heldInputs.GamepadL2
			or heldInputs.Mobile
		if held == tuckHeld then
			return
		end

		tuckHeld = held
		updateTuckFeedback()
		if sendIntent then
			sendTuckIntent(false)
		end
	end

	local function isAnyGamepadL2Held(): boolean
		for _, gamepad in UserInputService:GetConnectedGamepads() do
			if UserInputService:IsGamepadButtonDown(gamepad, Enum.KeyCode.ButtonL2) then
				return true
			end
		end
		return false
	end

	local function synchronizeHeldInputs()
		heldInputs.LeftShift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
		heldInputs.RightShift = UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		heldInputs.GamepadL2 = isAnyGamepadL2Held()
		-- Mobile is event-driven because UserInputService cannot query the CAS touch button.
		refreshTuckHeld(false)
	end

	local function handleTuckAction(
		_actionName: string,
		inputState: Enum.UserInputState,
		inputObject: InputObject
	): Enum.ContextActionResult
		local held: boolean? = nil
		if inputState == Enum.UserInputState.Begin then
			held = true
		elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
			held = false
		end

		if held ~= nil then
			if inputObject.KeyCode == Enum.KeyCode.LeftShift then
				heldInputs.LeftShift = held
			elseif inputObject.KeyCode == Enum.KeyCode.RightShift then
				heldInputs.RightShift = held
			elseif inputObject.KeyCode == Enum.KeyCode.ButtonL2 then
				heldInputs.GamepadL2 = held
			elseif inputObject.UserInputType == Enum.UserInputType.Touch then
				heldInputs.Mobile = held
			end
			refreshTuckHeld(true)
		end

		return Enum.ContextActionResult.Sink
	end

	ContextActionService:BindAction(
		ACTION_NAME,
		handleTuckAction,
		true,
		Enum.KeyCode.LeftShift,
		Enum.KeyCode.RightShift,
		Enum.KeyCode.ButtonL2
	)
	ContextActionService:SetTitle(ACTION_NAME, "TUCK")
	if UserInputService.TouchEnabled then
		setupTouchButtonLayout()
	end

	runStateRemote.OnClientEvent:Connect(function(
		phase: any,
		countdown: any,
		speed: any,
		runId: any,
		tuckQueued: any,
		tucking: any,
		outcome: any
	)
		if typeof(phase) ~= "string"
			or typeof(runId) ~= "number"
			or runId % 1 ~= 0
		then
			return
		end
		if runId < latestRunId then
			return
		end

		local previousPhase = currentPhase
		local runChanged = currentRunId ~= runId
		if runId > latestRunId then
			latestRunId = runId
		end
		if runChanged then
			currentRunId = runId
			lastSentRunId = nil
			lastSentIntent = nil
		end

		currentPhase = phase
		updateJumpBlockForPhase(runId)
		serverTuckQueued = if typeof(tuckQueued) == "boolean" then tuckQueued else false
		serverTucking = if typeof(tucking) == "boolean" then tucking else false
		currentOutcome = if phase ~= RunPhase.Idle
			and typeof(outcome) == "string"
			and outcome == MISSED_LAUNCH_OUTCOME
			then MISSED_LAUNCH_OUTCOME
			else nil

		updatePhaseFeedback()
		if typeof(speed) == "number" then
			hud.SpeedLabel.Text = string.format("Speed: %.0f studs/s", math.max(0, speed))
		end

		if phase == RunPhase.Countdown and typeof(countdown) == "number" then
			hud.CountdownLabel.Text = tostring(math.clamp(math.round(countdown), 1, 3))
			hud.CountdownLabel.Visible = true
		else
			hud.CountdownLabel.Visible = false
		end

		local enteredCountdown = phase == RunPhase.Countdown
			and (runChanged or previousPhase ~= RunPhase.Countdown)
		if enteredCountdown then
			synchronizeHeldInputs()
			sendTuckIntent(true)
		elseif phase == RunPhase.Countdown and tuckHeld ~= serverTuckQueued then
			sendTuckIntent(true)
		elseif phase == RunPhase.Descent and tuckHeld ~= (serverTuckQueued or serverTucking) then
			sendTuckIntent(true)
		elseif phase == RunPhase.Idle then
			lastSentRunId = nil
			lastSentIntent = nil
		end
		updateTuckFeedback()
	end)

	print("[Frostline] RunController ready")
end

return RunController
