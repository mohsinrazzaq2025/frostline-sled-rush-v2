--!strict

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PlayerDataTypes = require(ReplicatedStorage.Shared.PlayerDataTypes)
local ResultTypes = require(ReplicatedStorage.Shared.ResultTypes)
local RunPhase = require(ReplicatedStorage.Shared.RunPhase)

local REMOTES_FOLDER_NAME = "FrostlineRemotes"
local RESULT_REMOTE_NAME = "RunResult"
local RESULT_ACTION_REMOTE_NAME = "ResultAction"
local STATE_REMOTE_NAME = "RunState"
local RUN_HUD_NAME = "FrostlineRunHud"
local RESULT_GUI_NAME = "FrostlineResultGui"

local DARK_NAVY = Color3.fromRGB(11, 31, 58)
local WINTER_BLUE = Color3.fromRGB(18, 59, 93)
local ICE_CYAN = Color3.fromRGB(115, 232, 255)
local SNOW_WHITE = Color3.fromRGB(245, 251, 255)
local CHRISTMAS_RED = Color3.fromRGB(217, 74, 74)
local PINE_GREEN = Color3.fromRGB(47, 166, 107)
local COIN_GOLD = Color3.fromRGB(255, 212, 90)
local STALLED_AMBER = Color3.fromRGB(244, 185, 66)
local SECONDARY_ICE = Color3.fromRGB(180, 231, 247)

local PANEL_WIDE_SIZE = Vector2.new(560, 400)
local PANEL_NARROW_SIZE = Vector2.new(360, 530)
local ENTRANCE_DURATION = 0.32
local SESSION_ONLY_WARNING = "SESSION ONLY — PROGRESS WILL NOT SAVE"

type Outcome = ResultTypes.Outcome
type Action = ResultTypes.Action
type Payload = ResultTypes.Payload

type ResultUi = {
	ScreenGui: ScreenGui,
	Backdrop: CanvasGroup,
	ResponsiveRoot: Frame,
	ResponsiveScale: UIScale,
	AnimationScale: UIScale,
	OutcomeGroup: CanvasGroup,
	OutcomeGlow: Frame,
	OutcomeBadge: Frame,
	OutcomeLabel: TextLabel,
	NewBestLabel: TextLabel,
	FinalDistanceLabel: TextLabel,
	BestDistanceLabel: TextLabel,
	CoinsEarnedLabel: TextLabel,
	TotalCoinsLabel: TextLabel,
	ModeLabel: TextLabel,
	ProcessingLabel: TextLabel,
	ButtonRow: Frame,
	ButtonLayout: UIListLayout,
	PlayAgainButton: TextButton,
	ReturnButton: TextButton,
	CoinCardStroke: UIStroke,
}

local OUTCOME_PRESENTATION: { [Outcome]: { Text: string, Color: Color3 } } = {
	[ResultTypes.Outcomes.CleanLanding] = {
		Text = "CLEAN LANDING",
		Color = PINE_GREEN,
	},
	[ResultTypes.Outcomes.Crashed] = {
		Text = "CRASHED",
		Color = CHRISTMAS_RED,
	},
	[ResultTypes.Outcomes.Stalled] = {
		Text = "STALLED",
		Color = STALLED_AMBER,
	},
}

local ResultController = {}

local started = false

local function addCorner(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function addTextConstraint(instance: TextLabel | TextButton, minimum: number, maximum: number)
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MinTextSize = minimum
	constraint.MaxTextSize = maximum
	constraint.Parent = instance
end

local function createLabel(
	parent: Instance,
	name: string,
	text: string,
	color: Color3,
	font: Enum.Font,
	minimumTextSize: number,
	maximumTextSize: number
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Font = font
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.TextWrapped = true
	label.Parent = parent
	addTextConstraint(label, minimumTextSize, maximumTextSize)
	return label
end

local function createStatCard(parent: Instance, name: string): (Frame, TextLabel, TextLabel, TextLabel, UIStroke)
	local card = Instance.new("Frame")
	card.Name = name
	card.Size = UDim2.new(0.485, 0, 1, 0)
	card.BackgroundColor3 = Color3.fromRGB(8, 37, 64)
	card.BackgroundTransparency = 0.08
	card.BorderSizePixel = 0
	card.Parent = parent
	addCorner(card, 12)

	local stroke = Instance.new("UIStroke")
	stroke.Color = ICE_CYAN
	stroke.Thickness = 1.5
	stroke.Transparency = 0.48
	stroke.Parent = card

	local title = createLabel(card, "Title", "", SECONDARY_ICE, Enum.Font.GothamBold, 10, 15)
	title.Position = UDim2.fromScale(0.07, 0.08)
	title.Size = UDim2.fromScale(0.86, 0.24)
	title.TextXAlignment = Enum.TextXAlignment.Left

	local value = createLabel(card, "Value", "", SNOW_WHITE, Enum.Font.GothamBlack, 16, 28)
	value.Position = UDim2.fromScale(0.07, 0.33)
	value.Size = UDim2.fromScale(0.86, 0.38)
	value.TextXAlignment = Enum.TextXAlignment.Left

	local detail = createLabel(card, "Detail", "", SECONDARY_ICE, Enum.Font.GothamMedium, 9, 13)
	detail.Position = UDim2.fromScale(0.07, 0.73)
	detail.Size = UDim2.fromScale(0.86, 0.18)
	detail.TextXAlignment = Enum.TextXAlignment.Left

	return card, title, value, detail, stroke
end

local function createButton(parent: Instance, name: string, text: string, color: Color3): TextButton
	local shadow = Instance.new("Frame")
	shadow.Name = name .. "Shadow"
	shadow.AnchorPoint = Vector2.new(0.5, 0.5)
	shadow.Position = UDim2.new(0.5, 0, 0.5, 4)
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.BackgroundColor3 = Color3.new(0, 0, 0)
	shadow.BackgroundTransparency = 0.58
	shadow.BorderSizePixel = 0
	shadow.Parent = parent
	addCorner(shadow, 12)

	local button = Instance.new("TextButton")
	button.Name = name
	button.AnchorPoint = Vector2.new(0.5, 0.5)
	button.Position = UDim2.fromScale(0.5, 0.5)
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundColor3 = color
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Font = Enum.Font.GothamBlack
	button.Text = text
	button.TextColor3 = SNOW_WHITE
	button.TextScaled = true
	button.Parent = parent
	addTextConstraint(button, 13, 22)
	addCorner(button, 12)

	local stroke = Instance.new("UIStroke")
	stroke.Color = SNOW_WHITE
	stroke.Thickness = 1.5
	stroke.Transparency = 0.45
	stroke.Parent = button
	return button
end

local function createResultUi(): ResultUi
	local playerGuiInstance = Players.LocalPlayer:WaitForChild("PlayerGui")
	if not playerGuiInstance:IsA("PlayerGui") then
		error("PlayerGui was not available")
	end

	local previous = playerGuiInstance:FindFirstChild(RESULT_GUI_NAME)
	if previous then
		previous:Destroy()
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = RESULT_GUI_NAME
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.DisplayOrder = 30
	screenGui.Enabled = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGuiInstance

	local backdrop = Instance.new("CanvasGroup")
	backdrop.Name = "Backdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(2, 10, 21)
	backdrop.BackgroundTransparency = 0.28
	backdrop.BorderSizePixel = 0
	backdrop.GroupTransparency = 1
	backdrop.Parent = screenGui

	local responsiveRoot = Instance.new("Frame")
	responsiveRoot.Name = "ResponsiveRoot"
	responsiveRoot.AnchorPoint = Vector2.new(0.5, 0.5)
	responsiveRoot.Position = UDim2.fromScale(0.5, 0.5)
	responsiveRoot.Size = UDim2.fromOffset(PANEL_WIDE_SIZE.X, PANEL_WIDE_SIZE.Y)
	responsiveRoot.BackgroundTransparency = 1
	responsiveRoot.BorderSizePixel = 0
	responsiveRoot.Parent = backdrop

	local rootConstraint = Instance.new("UISizeConstraint")
	rootConstraint.MinSize = Vector2.new(320, 390)
	rootConstraint.MaxSize = Vector2.new(560, 530)
	rootConstraint.Parent = responsiveRoot

	local responsiveScale = Instance.new("UIScale")
	responsiveScale.Name = "ResponsiveScale"
	responsiveScale.Scale = 1
	responsiveScale.Parent = responsiveRoot

	local animationShell = Instance.new("Frame")
	animationShell.Name = "AnimationShell"
	animationShell.AnchorPoint = Vector2.new(0.5, 0.5)
	animationShell.Position = UDim2.fromScale(0.5, 0.5)
	animationShell.Size = UDim2.fromScale(1, 1)
	animationShell.BackgroundTransparency = 1
	animationShell.BorderSizePixel = 0
	animationShell.Parent = responsiveRoot

	local animationScale = Instance.new("UIScale")
	animationScale.Name = "EntranceScale"
	animationScale.Scale = 0.96
	animationScale.Parent = animationShell

	local shadow = Instance.new("Frame")
	shadow.Name = "SoftShadow"
	shadow.Position = UDim2.fromOffset(0, 9)
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.BackgroundColor3 = Color3.new(0, 0, 0)
	shadow.BackgroundTransparency = 0.42
	shadow.BorderSizePixel = 0
	shadow.Parent = animationShell
	addCorner(shadow, 20)

	local panel = Instance.new("Frame")
	panel.Name = "ChristmasResultPanel"
	panel.Size = UDim2.fromScale(1, 1)
	panel.BackgroundColor3 = DARK_NAVY
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = false
	panel.Parent = animationShell
	addCorner(panel, 20)

	local panelGradient = Instance.new("UIGradient")
	panelGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, WINTER_BLUE),
		ColorSequenceKeypoint.new(0.62, DARK_NAVY),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(6, 22, 43)),
	})
	panelGradient.Rotation = 100
	panelGradient.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Name = "FrostStroke"
	panelStroke.Color = ICE_CYAN
	panelStroke.Thickness = 3
	panelStroke.Transparency = 0.08
	panelStroke.Parent = panel

	local candyBand = Instance.new("Frame")
	candyBand.Name = "CandyCaneAccent"
	candyBand.Position = UDim2.fromOffset(0, 17)
	candyBand.Size = UDim2.new(1, 0, 0, 7)
	candyBand.BackgroundTransparency = 1
	candyBand.ClipsDescendants = true
	candyBand.BorderSizePixel = 0
	candyBand.Parent = panel
	for index = 1, 14 do
		local segment = Instance.new("Frame")
		segment.Name = string.format("Stripe%02d", index)
		segment.Position = UDim2.fromScale((index - 1) / 14, 0)
		segment.Size = UDim2.new(1 / 14, 1, 0, 0)
		segment.BackgroundColor3 = if index % 2 == 0 then SNOW_WHITE else CHRISTMAS_RED
		segment.BorderSizePixel = 0
		segment.Parent = candyBand
	end

	local snowCap = Instance.new("Frame")
	snowCap.Name = "SnowCap"
	snowCap.Position = UDim2.fromOffset(0, -1)
	snowCap.Size = UDim2.new(1, 0, 0, 19)
	snowCap.BackgroundColor3 = SNOW_WHITE
	snowCap.BorderSizePixel = 0
	snowCap.Parent = panel
	addCorner(snowCap, 18)
	for index, position in { 0.08, 0.28, 0.51, 0.72, 0.9 } do
		local drift = Instance.new("Frame")
		drift.Name = string.format("SnowDrift%02d", index)
		drift.AnchorPoint = Vector2.new(0.5, 0.5)
		drift.Position = UDim2.fromScale(position, 0.94)
		drift.Size = UDim2.fromOffset(if index % 2 == 0 then 88 else 70, if index % 2 == 0 then 24 else 20)
		drift.BackgroundColor3 = SNOW_WHITE
		drift.BorderSizePixel = 0
		drift.Parent = snowCap
		addCorner(drift, 999)
	end

	local leftSnowflake = createLabel(panel, "LeftSnowflake", "❄", SNOW_WHITE, Enum.Font.GothamBold, 14, 24)
	leftSnowflake.Position = UDim2.fromScale(0.055, 0.065)
	leftSnowflake.Size = UDim2.fromOffset(28, 28)
	leftSnowflake.TextTransparency = 0.16
	leftSnowflake.Rotation = -12

	local rightSnowflake = createLabel(panel, "RightSnowflake", "❄", ICE_CYAN, Enum.Font.GothamBold, 14, 24)
	rightSnowflake.AnchorPoint = Vector2.new(1, 0)
	rightSnowflake.Position = UDim2.fromScale(0.945, 0.065)
	rightSnowflake.Size = UDim2.fromOffset(28, 28)
	rightSnowflake.TextTransparency = 0.18
	rightSnowflake.Rotation = 12

	local content = Instance.new("Frame")
	content.Name = "OrderedContent"
	content.Position = UDim2.fromOffset(0, 27)
	content.Size = UDim2.new(1, 0, 1, -40)
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Parent = panel

	local contentPadding = Instance.new("UIPadding")
	contentPadding.PaddingLeft = UDim.new(0, 30)
	contentPadding.PaddingRight = UDim.new(0, 30)
	contentPadding.PaddingTop = UDim.new(0, 4)
	contentPadding.PaddingBottom = UDim.new(0, 8)
	contentPadding.Parent = content

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, 5)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = content

	local title = createLabel(content, "RunCompleteTitle", "RUN COMPLETE", SNOW_WHITE, Enum.Font.GothamBlack, 22, 38)
	title.LayoutOrder = 1
	title.Size = UDim2.new(1, 0, 0, 36)
	title.TextStrokeColor3 = Color3.fromRGB(6, 24, 44)
	title.TextStrokeTransparency = 0.55

	local outcomeGroup = Instance.new("CanvasGroup")
	outcomeGroup.Name = "OutcomeBadgeRow"
	outcomeGroup.LayoutOrder = 2
	outcomeGroup.Size = UDim2.new(1, 0, 0, 32)
	outcomeGroup.BackgroundTransparency = 1
	outcomeGroup.BorderSizePixel = 0
	outcomeGroup.GroupTransparency = 1
	outcomeGroup.Parent = content

	local outcomeGlow = Instance.new("Frame")
	outcomeGlow.Name = "RestrainedGlow"
	outcomeGlow.AnchorPoint = Vector2.new(0.5, 0.5)
	outcomeGlow.Position = UDim2.fromScale(0.5, 0.5)
	outcomeGlow.Size = UDim2.fromOffset(256, 36)
	outcomeGlow.BackgroundColor3 = PINE_GREEN
	outcomeGlow.BackgroundTransparency = 0.72
	outcomeGlow.BorderSizePixel = 0
	outcomeGlow.Parent = outcomeGroup
	addCorner(outcomeGlow, 999)

	local outcomeBadge = Instance.new("Frame")
	outcomeBadge.Name = "OutcomeBadge"
	outcomeBadge.AnchorPoint = Vector2.new(0.5, 0.5)
	outcomeBadge.Position = UDim2.fromScale(0.5, 0.5)
	outcomeBadge.Size = UDim2.fromOffset(236, 30)
	outcomeBadge.BackgroundColor3 = PINE_GREEN
	outcomeBadge.BackgroundTransparency = 0.12
	outcomeBadge.BorderSizePixel = 0
	outcomeBadge.Parent = outcomeGroup
	addCorner(outcomeBadge, 999)

	local outcomeBadgeStroke = Instance.new("UIStroke")
	outcomeBadgeStroke.Color = SNOW_WHITE
	outcomeBadgeStroke.Thickness = 1.5
	outcomeBadgeStroke.Transparency = 0.46
	outcomeBadgeStroke.Parent = outcomeBadge

	local outcomeLabel = createLabel(outcomeBadge, "Outcome", "", SNOW_WHITE, Enum.Font.GothamBlack, 13, 20)
	outcomeLabel.Size = UDim2.fromScale(1, 1)

	local finalDistanceLabel = createLabel(content, "HeroDistance", "0.0m", SNOW_WHITE, Enum.Font.GothamBlack, 30, 50)
	finalDistanceLabel.LayoutOrder = 3
	finalDistanceLabel.Size = UDim2.new(1, 0, 0, 54)

	local newBestLabel = createLabel(content, "NewBestBadge", "NEW BEST!", COIN_GOLD, Enum.Font.GothamBlack, 11, 17)
	newBestLabel.LayoutOrder = 4
	newBestLabel.Size = UDim2.new(1, 0, 0, 20)
	newBestLabel.Visible = false

	local statRow = Instance.new("Frame")
	statRow.Name = "StatCards"
	statRow.LayoutOrder = 5
	statRow.Size = UDim2.new(1, 0, 0, 68)
	statRow.BackgroundTransparency = 1
	statRow.BorderSizePixel = 0
	statRow.Parent = content

	local statLayout = Instance.new("UIListLayout")
	statLayout.FillDirection = Enum.FillDirection.Horizontal
	statLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	statLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	statLayout.Padding = UDim.new(0.03, 0)
	statLayout.SortOrder = Enum.SortOrder.LayoutOrder
	statLayout.Parent = statRow

	local bestCard, bestTitle, bestDistanceLabel, bestDetail = createStatCard(statRow, "BestDistanceCard")
	bestCard.LayoutOrder = 1
	bestTitle.Text = "BEST DISTANCE"
	bestDetail.Text = "PERSONAL BEST"

	local coinCard, coinTitle, totalCoinsLabel, coinsEarnedLabel, coinCardStroke = createStatCard(statRow, "FrostCoinsCard")
	coinCard.LayoutOrder = 2
	coinTitle.Text = "FROST COINS"
	totalCoinsLabel.TextColor3 = COIN_GOLD
	coinsEarnedLabel.TextColor3 = COIN_GOLD

	local modeBadge = Instance.new("Frame")
	modeBadge.Name = "RunModeBadge"
	modeBadge.LayoutOrder = 6
	modeBadge.Size = UDim2.fromOffset(170, 24)
	modeBadge.BackgroundColor3 = Color3.fromRGB(15, 74, 103)
	modeBadge.BackgroundTransparency = 0.16
	modeBadge.BorderSizePixel = 0
	modeBadge.Parent = content
	addCorner(modeBadge, 999)

	local modeStroke = Instance.new("UIStroke")
	modeStroke.Color = ICE_CYAN
	modeStroke.Thickness = 1
	modeStroke.Transparency = 0.42
	modeStroke.Parent = modeBadge

	local modeLabel = createLabel(modeBadge, "Mode", "STANDARD RUN", SECONDARY_ICE, Enum.Font.GothamBold, 10, 15)
	modeLabel.Size = UDim2.fromScale(1, 1)

	local processingLabel = createLabel(content, "Processing", "CHOOSE YOUR NEXT RUN", SECONDARY_ICE, Enum.Font.GothamMedium, 9, 14)
	processingLabel.LayoutOrder = 7
	processingLabel.Size = UDim2.new(1, 0, 0, 17)

	local buttonRow = Instance.new("Frame")
	buttonRow.Name = "Actions"
	buttonRow.LayoutOrder = 8
	buttonRow.Size = UDim2.new(1, 0, 0, 60)
	buttonRow.BackgroundTransparency = 1
	buttonRow.BorderSizePixel = 0
	buttonRow.Parent = content

	local buttonLayout = Instance.new("UIListLayout")
	buttonLayout.FillDirection = Enum.FillDirection.Horizontal
	buttonLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	buttonLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	buttonLayout.Padding = UDim.new(0.03, 0)
	buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
	buttonLayout.Parent = buttonRow

	local playAgainContainer = Instance.new("Frame")
	playAgainContainer.Name = "PlayAgainContainer"
	playAgainContainer.LayoutOrder = 1
	playAgainContainer.Size = UDim2.new(0.485, 0, 1, -4)
	playAgainContainer.BackgroundTransparency = 1
	playAgainContainer.BorderSizePixel = 0
	playAgainContainer.Parent = buttonRow
	local playAgainButton = createButton(playAgainContainer, "PlayAgain", "PLAY AGAIN", PINE_GREEN)

	local returnContainer = Instance.new("Frame")
	returnContainer.Name = "ReturnContainer"
	returnContainer.LayoutOrder = 2
	returnContainer.Size = UDim2.new(0.485, 0, 1, -4)
	returnContainer.BackgroundTransparency = 1
	returnContainer.BorderSizePixel = 0
	returnContainer.Parent = buttonRow
	local returnButton = createButton(returnContainer, "ReturnToStart", "RETURN TO START", CHRISTMAS_RED)

	return {
		ScreenGui = screenGui,
		Backdrop = backdrop,
		ResponsiveRoot = responsiveRoot,
		ResponsiveScale = responsiveScale,
		AnimationScale = animationScale,
		OutcomeGroup = outcomeGroup,
		OutcomeGlow = outcomeGlow,
		OutcomeBadge = outcomeBadge,
		OutcomeLabel = outcomeLabel,
		NewBestLabel = newBestLabel,
		FinalDistanceLabel = finalDistanceLabel,
		BestDistanceLabel = bestDistanceLabel,
		CoinsEarnedLabel = coinsEarnedLabel,
		TotalCoinsLabel = totalCoinsLabel,
		ModeLabel = modeLabel,
		ProcessingLabel = processingLabel,
		ButtonRow = buttonRow,
		ButtonLayout = buttonLayout,
		PlayAgainButton = playAgainButton,
		ReturnButton = returnButton,
		CoinCardStroke = coinCardStroke,
	}
end

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isKnownOutcome(value: any): boolean
	return value == ResultTypes.Outcomes.CleanLanding
		or value == ResultTypes.Outcomes.Crashed
		or value == ResultTypes.Outcomes.Stalled
end

local function isKnownPersistenceStatus(value: any): boolean
	return value == PlayerDataTypes.PersistenceStatuses.Persistent
		or value == PlayerDataTypes.PersistenceStatuses.SessionOnly
end

local function parsePayload(value: any): Payload?
	if typeof(value) ~= "table"
		or value.Version ~= ResultTypes.Version
		or typeof(value.RunId) ~= "number"
		or value.RunId <= 0
		or value.RunId % 1 ~= 0
		or not isKnownOutcome(value.Outcome)
		or not isFiniteNumber(value.FinalDistanceMeters)
		or not isFiniteNumber(value.BestDistanceMeters)
		or typeof(value.FrostCoinsEarned) ~= "number"
		or value.FrostCoinsEarned % 1 ~= 0
		or typeof(value.TotalFrostCoins) ~= "number"
		or value.TotalFrostCoins % 1 ~= 0
		or typeof(value.TuckUsed) ~= "boolean"
		or typeof(value.IsNewBest) ~= "boolean"
		or not isKnownPersistenceStatus(value.PersistenceStatus)
	then
		return nil
	end

	return value :: Payload
end

function ResultController.start()
	if started then
		return
	end
	started = true

	local remoteFolder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME)
	if not remoteFolder:IsA("Folder") then
		error("FrostlineRemotes must be a Folder")
	end

	local resultRemote = remoteFolder:WaitForChild(RESULT_REMOTE_NAME)
	local resultActionRemote = remoteFolder:WaitForChild(RESULT_ACTION_REMOTE_NAME)
	local runStateRemote = remoteFolder:WaitForChild(STATE_REMOTE_NAME)
	if not resultRemote:IsA("RemoteEvent") then
		error("RunResult must be a RemoteEvent")
	elseif not resultActionRemote:IsA("RemoteEvent") then
		error("ResultAction must be a RemoteEvent")
	elseif not runStateRemote:IsA("RemoteEvent") then
		error("RunState must be a RemoteEvent")
	end

	local player = Players.LocalPlayer
	local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui
	local ui = createResultUi()
	local currentPayload: Payload? = nil
	local latestResultRunId = 0
	local latestStateRunId = 0
	local latestStatePhase: string = RunPhase.Idle
	local actionSubmitted = false
	local submittedAction: Action? = nil
	local hiddenRunHud: ScreenGui? = nil
	local runHudWasEnabled: boolean? = nil
	local runHudCaptured = false
	local viewportConnection: RBXScriptConnection? = nil
	local activeSledCameraConnection: RBXScriptConnection? = nil
	local storedCameraTarget: Instance? = nil
	local lastCameraDiagnosticRunId = 0
	local idleTraceRunId: number? = nil
	local cameraRestoreGeneration = 0
	local animationGeneration = 0
	local activeTweens: { Tween } = {}
	local controllerConnections: { RBXScriptConnection } = {}

	local function cancelTweens()
		for _, tween in activeTweens do
			tween:Cancel()
		end
		table.clear(activeTweens)
	end

	local function playTween(instance: Instance, tweenInfo: TweenInfo, properties: { [string]: any })
		local tween = TweenService:Create(instance, tweenInfo, properties)
		table.insert(activeTweens, tween)
		tween:Play()
	end

	local function updateResponsiveLayout()
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local viewport = ui.Backdrop.AbsoluteSize
		if viewport.X <= 0 or viewport.Y <= 0 then
			viewport = camera.ViewportSize
		end
		local narrow = viewport.X < 600 or viewport.X < viewport.Y * 0.9
		local baseSize = if narrow then PANEL_NARROW_SIZE else PANEL_WIDE_SIZE
		ui.ResponsiveRoot.Size = UDim2.fromOffset(baseSize.X, baseSize.Y)
		local availableWidth = math.max(1, viewport.X * 0.9)
		local availableHeight = math.max(1, viewport.Y * 0.88)
		ui.ResponsiveScale.Scale = math.min(1, availableWidth / baseSize.X, availableHeight / baseSize.Y)

		local playContainer = ui.PlayAgainButton.Parent
		local returnContainer = ui.ReturnButton.Parent
		if narrow then
			ui.ButtonRow.Size = UDim2.new(1, 0, 0, 128)
			ui.ButtonLayout.FillDirection = Enum.FillDirection.Vertical
			ui.ButtonLayout.Padding = UDim.new(0, 8)
			if playContainer and playContainer:IsA("GuiObject") then
				playContainer.Size = UDim2.new(1, 0, 0, 58)
			end
			if returnContainer and returnContainer:IsA("GuiObject") then
				returnContainer.Size = UDim2.new(1, 0, 0, 58)
			end
		else
			ui.ButtonRow.Size = UDim2.new(1, 0, 0, 60)
			ui.ButtonLayout.FillDirection = Enum.FillDirection.Horizontal
			ui.ButtonLayout.Padding = UDim.new(0.03, 0)
			if playContainer and playContainer:IsA("GuiObject") then
				playContainer.Size = UDim2.new(0.485, 0, 1, -4)
			end
			if returnContainer and returnContainer:IsA("GuiObject") then
				returnContainer.Size = UDim2.new(0.485, 0, 1, -4)
			end
		end
	end

	local function hideRunHud()
		if runHudCaptured then
			return
		end
		runHudCaptured = true
		local runHud = playerGui:FindFirstChild(RUN_HUD_NAME)
		if runHud and runHud:IsA("ScreenGui") then
			hiddenRunHud = runHud
			runHudWasEnabled = runHud.Enabled
			runHud.Enabled = false
		end
	end

	local function restoreRunHud()
		local runHud = hiddenRunHud
		local wasEnabled = runHudWasEnabled
		hiddenRunHud = nil
		runHudWasEnabled = nil
		runHudCaptured = false
		if runHud and runHud.Parent and wasEnabled ~= nil then
			runHud.Enabled = wasEnabled
		end
	end

	local function setButtonsEnabled(enabled: boolean)
		for _, button in { ui.PlayAgainButton, ui.ReturnButton } do
			button.Active = enabled
			button.AutoButtonColor = enabled
			button.BackgroundTransparency = if enabled then 0 else 0.35
		end
	end

	local function updateStatusLabel(payload: Payload, processing: boolean)
		if payload.PersistenceStatus == PlayerDataTypes.PersistenceStatuses.SessionOnly then
			ui.ProcessingLabel.Text = SESSION_ONLY_WARNING
			ui.ProcessingLabel.TextColor3 = STALLED_AMBER
		else
			ui.ProcessingLabel.Text = if processing then "PROCESSING…" else "CHOOSE YOUR NEXT RUN"
			ui.ProcessingLabel.TextColor3 = SECONDARY_ICE
		end
	end

	local function clearCameraFollowState()
		local cameraConnection = activeSledCameraConnection
		activeSledCameraConnection = nil
		storedCameraTarget = nil
		if cameraConnection then
			cameraConnection:Disconnect()
		end
	end

	local function applyNormalCamera(): boolean
		local character = player.Character
		local camera = Workspace.CurrentCamera
		if not character or not character.Parent or not camera then
			return false
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local rootInstance = character:FindFirstChild("HumanoidRootPart")
		if not humanoid or humanoid.Health <= 0 or not rootInstance or not rootInstance:IsA("BasePart") then
			return false
		end

		clearCameraFollowState()
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid
		camera.FieldOfView = GameConfig.Camera.NormalFieldOfView

		return true
	end

	local function emitIdleCameraDiagnostic(runId: number, generation: number)
		if not GameConfig.Result.LifecycleDiagnosticsEnabled or lastCameraDiagnosticRunId == runId then
			return
		end
		task.spawn(function()
			RunService.RenderStepped:Wait()
			if generation ~= cameraRestoreGeneration
				or latestStateRunId ~= runId
				or latestStatePhase ~= RunPhase.Idle
			then
				return
			end
			local character = player.Character
			local camera = Workspace.CurrentCamera
			if not character or not character.Parent or not camera then
				return
			end
			local rootInstance = character:FindFirstChild("HumanoidRootPart")
			if not rootInstance or not rootInstance:IsA("BasePart") then
				return
			end
			lastCameraDiagnosticRunId = runId
			local rootPosition = rootInstance.Position
			local cameraPosition = camera.CFrame.Position
			local cameraSubject = camera.CameraSubject
			print(
				string.format(
					"[Frostline][Lifecycle][Client] RunId=%d event=idle-camera-reset character=%s rootPosition=(%.2f,%.2f,%.2f) cameraType=%s cameraSubject=%s cameraPosition=(%.2f,%.2f,%.2f) cameraUpdaterActive=%s",
					runId,
					character:GetFullName(),
					rootPosition.X,
					rootPosition.Y,
					rootPosition.Z,
					camera.CameraType.Name,
					if cameraSubject then cameraSubject:GetFullName() else "nil",
					cameraPosition.X,
					cameraPosition.Y,
					cameraPosition.Z,
					tostring(activeSledCameraConnection ~= nil)
				)
			)
		end)
	end

	local function restoreCameraForIdle(runId: number, traceReturn: boolean)
		cameraRestoreGeneration += 1
		local generation = cameraRestoreGeneration
		clearCameraFollowState()
		if applyNormalCamera() then
			if traceReturn then
				emitIdleCameraDiagnostic(runId, generation)
			end
			return
		end

		task.spawn(function()
			for _ = 1, 8 do
				RunService.Heartbeat:Wait()
				if generation ~= cameraRestoreGeneration
					or latestStateRunId ~= runId
					or latestStatePhase ~= RunPhase.Idle
				then
					return
				end
				if applyNormalCamera() then
					if traceReturn then
						emitIdleCameraDiagnostic(runId, generation)
					end
					return
				end
			end
			warn(string.format("[Frostline] RunId=%d camera reset could not find a live character", runId))
		end)
	end

	local function hideResult()
		animationGeneration += 1
		cancelTweens()
		currentPayload = nil
		actionSubmitted = false
		submittedAction = nil
		ui.ScreenGui.Enabled = false
		ui.Backdrop.GroupTransparency = 1
		ui.OutcomeGroup.GroupTransparency = 1
		setButtonsEnabled(true)
		restoreRunHud()
	end

	local function showResult(payload: Payload)
		local presentation = OUTCOME_PRESENTATION[payload.Outcome]
		currentPayload = payload
		actionSubmitted = false
		submittedAction = nil
		idleTraceRunId = nil
		ui.OutcomeLabel.Text = presentation.Text
		ui.OutcomeGlow.BackgroundColor3 = presentation.Color
		ui.OutcomeBadge.BackgroundColor3 = presentation.Color
		ui.NewBestLabel.Visible = payload.IsNewBest
		ui.FinalDistanceLabel.Text = string.format("%.1fm", payload.FinalDistanceMeters)
		ui.BestDistanceLabel.Text = string.format("%.1fm", payload.BestDistanceMeters)
		ui.CoinsEarnedLabel.Text = string.format("+%d THIS RUN", payload.FrostCoinsEarned)
		ui.TotalCoinsLabel.Text = string.format("%d TOTAL", payload.TotalFrostCoins)
		ui.ModeLabel.Text = if payload.TuckUsed then "TUCK RUN" else "STANDARD RUN"
		updateStatusLabel(payload, false)
		setButtonsEnabled(true)
		hideRunHud()
		updateResponsiveLayout()

		animationGeneration += 1
		local generation = animationGeneration
		cancelTweens()
		ui.Backdrop.GroupTransparency = 1
		ui.AnimationScale.Scale = 0.96
		ui.OutcomeGroup.GroupTransparency = 1
		ui.CoinCardStroke.Transparency = 0.12
		ui.ScreenGui.Enabled = true
		playTween(
			ui.Backdrop,
			TweenInfo.new(ENTRANCE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ GroupTransparency = 0 }
		)
		playTween(
			ui.AnimationScale,
			TweenInfo.new(ENTRANCE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Scale = 1 }
		)

		task.delay(0.06, function()
			if generation ~= animationGeneration or currentPayload ~= payload then
				return
			end
			playTween(
				ui.OutcomeGroup,
				TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ GroupTransparency = 0 }
			)
		end)
		task.delay(0.12, function()
			if generation ~= animationGeneration or currentPayload ~= payload then
				return
			end
			playTween(
				ui.CoinCardStroke,
				TweenInfo.new(0.55, Enum.EasingStyle.Sine, Enum.EasingDirection.Out),
				{ Transparency = 0.48 }
			)
		end)
	end

	local function submitAction(action: Action)
		local payload = currentPayload
		if not payload or actionSubmitted then
			return
		end

		actionSubmitted = true
		submittedAction = action
		setButtonsEnabled(false)
		updateStatusLabel(payload, true)
		resultActionRemote:FireServer(payload.RunId, action)
	end

	table.insert(controllerConnections, ui.PlayAgainButton.Activated:Connect(function()
		submitAction(ResultTypes.Actions.PlayAgain)
	end))
	table.insert(controllerConnections, ui.ReturnButton.Activated:Connect(function()
		submitAction(ResultTypes.Actions.ReturnToStart)
	end))

	table.insert(controllerConnections, resultRemote.OnClientEvent:Connect(function(rawPayload: any)
		local payload = parsePayload(rawPayload)
		if not payload
			or payload.RunId <= latestResultRunId
			or payload.RunId < latestStateRunId
			or (payload.RunId == latestStateRunId
				and (latestStatePhase == RunPhase.Reset or latestStatePhase == RunPhase.Idle))
		then
			return
		end

		latestResultRunId = payload.RunId
		showResult(payload)
	end))

	table.insert(controllerConnections, runStateRemote.OnClientEvent:Connect(function(phase: any, _countdown: any, _speed: any, runId: any)
		if typeof(phase) ~= "string"
			or typeof(runId) ~= "number"
			or runId <= 0
			or runId % 1 ~= 0
			or runId < latestStateRunId
		then
			return
		end
		if runId > latestStateRunId then
			latestStateRunId = runId
		end
		latestStatePhase = phase

		if phase == RunPhase.Idle then
			local visiblePayload = currentPayload
			local traceReturn = visiblePayload ~= nil
				and visiblePayload.RunId == runId
				and submittedAction ~= ResultTypes.Actions.PlayAgain
			idleTraceRunId = if traceReturn then runId else nil
			restoreCameraForIdle(runId, traceReturn)
		elseif phase == RunPhase.Countdown then
			cameraRestoreGeneration += 1
			idleTraceRunId = nil
		end

		local payload = currentPayload
		if not payload or runId < payload.RunId then
			return
		end

		if runId == payload.RunId and phase == RunPhase.Reset then
			actionSubmitted = true
			setButtonsEnabled(false)
			updateStatusLabel(payload, true)
		elseif (runId == payload.RunId and phase == RunPhase.Idle)
			or runId > payload.RunId
		then
			hideResult()
		end
	end))

	local function observeCamera()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
		local camera = Workspace.CurrentCamera
		if camera then
			viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveLayout)
		end
		updateResponsiveLayout()
		if latestStateRunId > 0 and latestStatePhase == RunPhase.Idle then
			restoreCameraForIdle(latestStateRunId, idleTraceRunId == latestStateRunId)
		end
	end

	local cleanupStarted = false
	local function cleanupController()
		if cleanupStarted then
			return
		end
		cleanupStarted = true
		cameraRestoreGeneration += 1
		animationGeneration += 1
		cancelTweens()
		clearCameraFollowState()
		applyNormalCamera()
		restoreRunHud()
		if viewportConnection then
			viewportConnection:Disconnect()
			viewportConnection = nil
		end
		for _, connection in controllerConnections do
			connection:Disconnect()
		end
		table.clear(controllerConnections)
	end

	table.insert(controllerConnections, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(observeCamera))
	table.insert(controllerConnections, ui.Backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateResponsiveLayout))
	table.insert(controllerConnections, player.CharacterAdded:Connect(function(_character: Model)
		local runId = latestStateRunId
		if runId <= 0 or latestStatePhase ~= RunPhase.Idle then
			return
		end
		task.defer(function()
			if latestStateRunId == runId and latestStatePhase == RunPhase.Idle then
				restoreCameraForIdle(runId, idleTraceRunId == runId)
			end
		end)
	end))
	table.insert(controllerConnections, ui.ScreenGui.Destroying:Connect(cleanupController))
	table.insert(controllerConnections, script.Destroying:Connect(function()
		cleanupController()
		if ui.ScreenGui.Parent then
			ui.ScreenGui:Destroy()
		end
	end))
	observeCamera()

	print("[Frostline] ResultController ready")
end

return ResultController
