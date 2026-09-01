--!strict

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local RunPhase = require(ReplicatedStorage.Shared.RunPhase)

local ACTION_NAME = "FrostlineTuck"
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

local function createHud(): Hud
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
	instructionLabel.Text = "Hold Shift to Tuck"
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

	local hud = createHud()
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
				hud.TuckLabel.Text = "Hold Shift to prepare Tuck"
				hud.TuckLabel.TextColor3 = TUCK_DEFAULT_COLOR
				hud.TuckLabel.Font = Enum.Font.GothamMedium
			end
		elseif currentPhase == RunPhase.Descent then
			if tuckHeld and serverTucking then
				hud.TuckLabel.Text = "TUCK ACTIVE"
				hud.TuckLabel.TextColor3 = TUCK_ACTIVE_COLOR
				hud.TuckLabel.Font = Enum.Font.GothamBlack
			else
				hud.TuckLabel.Text = "Hold Shift to Tuck"
				hud.TuckLabel.TextColor3 = TUCK_DEFAULT_COLOR
				hud.TuckLabel.Font = Enum.Font.GothamMedium
			end
		elseif currentPhase == RunPhase.Airborne then
			hud.TuckLabel.Text = "BALLISTIC FLIGHT"
			hud.TuckLabel.TextColor3 = TUCK_FLIGHT_COLOR
			hud.TuckLabel.Font = Enum.Font.GothamBold
		else
			hud.TuckLabel.Text = "Hold Shift to Tuck"
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
	ContextActionService:SetPosition(ACTION_NAME, UDim2.fromScale(0.84, 0.76))

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
