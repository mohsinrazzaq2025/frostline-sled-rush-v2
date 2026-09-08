--!strict

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CourseSelectionTypes = require(ReplicatedStorage.Shared.CourseSelectionTypes)
local RunPhase = require(ReplicatedStorage.Shared.RunPhase)

local REMOTES_FOLDER_NAME = "FrostlineRemotes"
local RUN_STATE_REMOTE_NAME = "RunState"
local PRESENTATION_COURSE_ATTRIBUTE = "FrostlinePresentationCourseId"
local SCREEN_GUI_NAME = "FrostlineCourseSelectionUI"
local CLASSIC_COURSE_ID = CourseSelectionTypes.CourseIds.FrozenLakeV2
local FROST_COURSE_ID = CourseSelectionTypes.CourseIds.FrostTrailV1
local UNKNOWN_PHASE = "Unknown"
local REQUEST_TIMEOUT_SECONDS = 5
local ATTRIBUTE_CONVERGENCE_TIMEOUT_SECONDS = 5
local IDLE_REVEAL_SECONDS = 0.20
local ENDPOINT_ACQUISITION_TIMEOUT_SECONDS = 5

local MODAL_BLOCK_ACTION = "FrostlineCourseSelectionModalBlock"
local MODAL_ACTIVATE_ACTION = "FrostlineCourseSelectionModalActivate"
local MODAL_CLOSE_ACTION = "FrostlineCourseSelectionModalClose"
local MODAL_ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 5

local DEEP_NAVY = Color3.fromRGB(7, 18, 34)
local DARK_NAVY = Color3.fromRGB(11, 31, 58)
local WINTER_BLUE = Color3.fromRGB(18, 59, 93)
local ICE_CYAN = Color3.fromRGB(116, 225, 250)
local PALE_ICE = Color3.fromRGB(180, 231, 247)
local SNOW_WHITE = Color3.fromRGB(245, 251, 255)
local GOLD = Color3.fromRGB(255, 212, 90)
local GREEN = Color3.fromRGB(48, 166, 108)
local RED = Color3.fromRGB(217, 74, 74)
local AMBER = Color3.fromRGB(244, 185, 66)
local DISABLED = Color3.fromRGB(48, 75, 98)

type CourseId = CourseSelectionTypes.CourseId
type Action = CourseSelectionTypes.Action
type StatusCode = CourseSelectionTypes.StatusCode

type CourseDescriptor = {
	CourseId: CourseId,
	DisplayName: string,
	Available: boolean,
}

type AcceptedState = {
	ServerSequence: number,
	SelectedCourseId: CourseId,
	CanSelect: boolean,
	RunPhase: string,
	Courses: { CourseDescriptor },
}

type ParsedResponse = AcceptedState & {
	ResponseToRequestId: string,
	ResponseClientSequence: number,
	ResponseAction: Action,
	ResponseCourseId: CourseId?,
	Ok: boolean,
	StatusCode: StatusCode,
}

type CycleKind = "Initial" | "Modal" | "Select" | "Lifecycle"

type PendingRequest = {
	RequestId: string,
	ClientSequence: number,
	Action: Action,
	CourseId: CourseId?,
	CycleKind: CycleKind,
	CycleCourseId: CourseId?,
	ReconciliationUsed: boolean,
	LifecycleGeneration: number,
	EndpointGeneration: number,
	UiGenerationAtSend: number,
	PhaseGenerationAtSend: number,
	DeadlineGeneration: number,
	TerminalResponse: ParsedResponse?,
}

type CourseCardUi = {
	Button: TextButton,
	Border: UIStroke,
	Focus: UIStroke,
	NameLabel: TextLabel,
	DescriptionLabel: TextLabel,
	FeatureLabel: TextLabel,
	ActionLabel: TextLabel,
}

type SelectorUi = {
	ScreenGui: ScreenGui,
	Launcher: TextButton,
	LauncherCourse: TextLabel,
	NewBadge: TextLabel,
	Backdrop: TextButton,
	Panel: Frame,
	TitleLabel: TextLabel,
	CloseButton: TextButton,
	StatusLabel: TextLabel,
	CardsArea: Frame,
	CardsLayout: UIListLayout,
	ClassicCard: CourseCardUi,
	FrostCard: CourseCardUi,
	FocusStrokes: { [GuiButton]: UIStroke },
}

local CourseSelectionController = {}

local localPlayer = Players.LocalPlayer
local started = false
local destroyed = false
local warningIssued = false
local sequenceWarningIssued = false
local endpointGeneration = 0
local endpointAcquisitionGeneration = 0
local lifecycleGeneration = 0
local phaseGeneration = 0
local idleRevealGeneration = 0
local requestDeadlineGeneration = 0
local uiGeneration = 0
local latestServerSequence = 0
local latestRunId = 0
local currentRunId: number? = nil
local currentPhase = UNKNOWN_PHASE
local currentPhaseRank = 0
local clientSequence = 0
local currentState: AcceptedState? = nil
local currentStateGeneration = -1
local pendingRequest: PendingRequest? = nil
local mutationDisabled = false
local modalFreshState = false
local selectorDisabled = false
local modalOpen = false
local ownsModalFocus = false
local modalActionsBound = false
local firstOpenCompleted = false
local statusMessage = ""
local statusColor = PALE_ICE
local previousSelectedObject: GuiObject? = nil
local selectionRemote: RemoteEvent? = nil
local runStateRemote: RemoteEvent? = nil
local currentPlayerGui: PlayerGui? = nil
local ui: SelectorUi? = nil
local controllerConnections: { RBXScriptConnection } = {}
local remoteConnections: { RBXScriptConnection } = {}
local uiConnections: { RBXScriptConnection } = {}
local viewportConnection: RBXScriptConnection? = nil
local endpointAcquisitionConnection: RBXScriptConnection? = nil

local renderUi: () -> ()
local closeModal: (string) -> ()
local beginRequest: (Action, CourseId?, CycleKind, CourseId?, boolean) -> boolean
local scheduleIdleReveal: (string) -> ()

local function warnOnce(message: string)
	if warningIssued then
		return
	end
	warningIssued = true
	warn(string.format("[Frostline][CourseSelection] Client unavailable: %s", message))
end

local function disconnectAll(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function isFiniteInteger(value: any, minimum: number, maximum: number): boolean
	return typeof(value) == "number"
		and value == value
		and math.abs(value) < math.huge
		and value % 1 == 0
		and value >= minimum
		and value <= maximum
end

local function isCanonicalGuid(value: any): boolean
	if typeof(value) ~= "string" or #value ~= 36 then
		return false
	end
	return string.match(
		value,
		"^[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]%-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]$"
	) ~= nil
end

local function parseCourseId(value: any): CourseId?
	if value == CLASSIC_COURSE_ID or value == FROST_COURSE_ID then
		return value :: CourseId
	end
	return nil
end

local function isKnownPhase(value: any): boolean
	return value == RunPhase.Idle
		or value == RunPhase.Countdown
		or value == RunPhase.Descent
		or value == RunPhase.Airborne
		or value == RunPhase.Landed
		or value == RunPhase.Results
		or value == RunPhase.Reset
end

local function phaseRank(phase: string): number?
	if phase == RunPhase.Countdown then
		return 1
	elseif phase == RunPhase.Descent then
		return 2
	elseif phase == RunPhase.Airborne then
		return 3
	elseif phase == RunPhase.Landed then
		return 4
	elseif phase == RunPhase.Results then
		return 5
	elseif phase == RunPhase.Reset then
		return 6
	elseif phase == RunPhase.Idle then
		return 7
	end
	return nil
end

local function hasExactKeys(value: { [any]: any }, allowed: { [string]: boolean }, expectedCount: number): boolean
	local count = 0
	for key in value do
		count += 1
		if count > expectedCount or typeof(key) ~= "string" or not allowed[key] then
			return false
		end
	end
	return count == expectedCount
end

local DESCRIPTOR_KEYS: { [string]: boolean } = table.freeze({
	CourseId = true,
	DisplayName = true,
	Available = true,
})

local GET_STATE_RESPONSE_KEYS: { [string]: boolean } = table.freeze({
	ProtocolVersion = true,
	CatalogVersion = true,
	ServerSequence = true,
	ResponseToRequestId = true,
	ResponseClientSequence = true,
	ResponseAction = true,
	Ok = true,
	StatusCode = true,
	SelectedCourseId = true,
	CanSelect = true,
	RunPhase = true,
	Courses = true,
})

local SELECT_RESPONSE_KEYS: { [string]: boolean } = table.freeze({
	ProtocolVersion = true,
	CatalogVersion = true,
	ServerSequence = true,
	ResponseToRequestId = true,
	ResponseClientSequence = true,
	ResponseAction = true,
	ResponseCourseId = true,
	Ok = true,
	StatusCode = true,
	SelectedCourseId = true,
	CanSelect = true,
	RunPhase = true,
	Courses = true,
})

local GET_STATE_FAILURES: { [string]: boolean } = table.freeze({
	InvalidRequest = true,
	UnsupportedVersion = true,
	RequestIdConflict = true,
	RequestInProgress = true,
	InternalError = true,
})

local SELECT_FAILURES: { [string]: boolean } = table.freeze({
	InvalidRequest = true,
	UnsupportedVersion = true,
	RequestIdConflict = true,
	RequestInProgress = true,
	RateLimited = true,
	Busy = true,
	CourseUnavailable = true,
	CharacterUnavailable = true,
	TeleportFailed = true,
	SafetyFallback = true,
	InternalError = true,
})

local function parseDescriptor(value: any, expectedId: CourseId, expectedName: string): CourseDescriptor?
	if typeof(value) ~= "table" or not hasExactKeys(value, DESCRIPTOR_KEYS, 3) then
		return nil
	end
	if value.CourseId ~= expectedId
		or value.DisplayName ~= expectedName
		or typeof(value.Available) ~= "boolean"
	then
		return nil
	end
	return table.freeze({
		CourseId = expectedId,
		DisplayName = expectedName,
		Available = value.Available,
	})
end

local function parseCourses(value: any): { CourseDescriptor }?
	if typeof(value) ~= "table" then
		return nil
	end
	local count = 0
	for key in value do
		count += 1
		if count > 2 or typeof(key) ~= "number" or (key ~= 1 and key ~= 2) then
			return nil
		end
	end
	if count ~= 2 then
		return nil
	end
	local classic = parseDescriptor(value[1], CLASSIC_COURSE_ID, "CLASSIC DISTANCE")
	local frost = parseDescriptor(value[2], FROST_COURSE_ID, "FROST TRAIL")
	if not classic or not frost then
		return nil
	end
	return table.freeze({ classic, frost })
end

local function parseResponse(value: any): ParsedResponse?
	if typeof(value) ~= "table" then
		return nil
	end
	local actionValue = value.ResponseAction
	local action: Action?
	local responseCourseId: CourseId? = nil
	if actionValue == CourseSelectionTypes.Actions.GetState then
		action = actionValue
		if not hasExactKeys(value, GET_STATE_RESPONSE_KEYS, 12) then
			return nil
		end
	elseif actionValue == CourseSelectionTypes.Actions.Select then
		action = actionValue
		if not hasExactKeys(value, SELECT_RESPONSE_KEYS, 13) then
			return nil
		end
		responseCourseId = parseCourseId(value.ResponseCourseId)
		if responseCourseId == nil then
			return nil
		end
	else
		return nil
	end

	if value.ProtocolVersion ~= CourseSelectionTypes.ProtocolVersion
		or value.CatalogVersion ~= CourseSelectionTypes.CatalogVersion
		or not isFiniteInteger(value.ServerSequence, 1, CourseSelectionTypes.MaximumServerSequence)
		or not isCanonicalGuid(value.ResponseToRequestId)
		or not isFiniteInteger(value.ResponseClientSequence, 1, CourseSelectionTypes.MaximumClientSequence)
		or typeof(value.Ok) ~= "boolean"
		or typeof(value.StatusCode) ~= "string"
		or typeof(value.CanSelect) ~= "boolean"
		or not isKnownPhase(value.RunPhase)
	then
		return nil
	end
	local selectedCourseId = parseCourseId(value.SelectedCourseId)
	local courses = parseCourses(value.Courses)
	if not selectedCourseId or not courses then
		return nil
	end

	local ok = value.Ok :: boolean
	local status = value.StatusCode :: string
	if action == CourseSelectionTypes.Actions.GetState then
		if (ok and status ~= CourseSelectionTypes.StatusCodes.State)
			or (not ok and not GET_STATE_FAILURES[status])
		then
			return nil
		end
	else
		local successful = status == CourseSelectionTypes.StatusCodes.Success
			or status == CourseSelectionTypes.StatusCodes.AlreadySelected
		if (ok and (not successful or selectedCourseId ~= responseCourseId))
			or (not ok and not SELECT_FAILURES[status])
		then
			return nil
		end
		if status == CourseSelectionTypes.StatusCodes.SafetyFallback
			and (ok or selectedCourseId ~= CLASSIC_COURSE_ID)
		then
			return nil
		end
	end

	return table.freeze({
		ServerSequence = value.ServerSequence,
		ResponseToRequestId = value.ResponseToRequestId,
		ResponseClientSequence = value.ResponseClientSequence,
		ResponseAction = action :: Action,
		ResponseCourseId = responseCourseId,
		Ok = ok,
		StatusCode = status :: StatusCode,
		SelectedCourseId = selectedCourseId,
		CanSelect = value.CanSelect,
		RunPhase = value.RunPhase,
		Courses = courses,
	})
end

local function findUniqueDirectChild(parent: Instance, name: string, className: string): Instance?
	local match: Instance? = nil
	for _, child in parent:GetChildren() do
		if child.Name == name then
			if not child:IsA(className) or match ~= nil then
				return nil
			end
			match = child
		end
	end
	return match
end

local function endpointsAreCurrent(): boolean
	local courseRemote = selectionRemote
	local stateRemote = runStateRemote
	if not courseRemote or not stateRemote then
		return false
	end
	local folder = courseRemote.Parent
	return folder ~= nil
		and folder:IsA("Folder")
		and folder.Name == REMOTES_FOLDER_NAME
		and folder.Parent == ReplicatedStorage
		and stateRemote.Parent == folder
		and findUniqueDirectChild(folder, CourseSelectionTypes.RemoteName, "RemoteEvent") == courseRemote
		and findUniqueDirectChild(folder, RUN_STATE_REMOTE_NAME, "RemoteEvent") == stateRemote
end

local function getPresentationCourseId(): CourseId?
	return parseCourseId(localPlayer:GetAttribute(PRESENTATION_COURSE_ATTRIBUTE))
end

local function getCourse(state: AcceptedState, courseId: CourseId): CourseDescriptor?
	for _, descriptor in state.Courses do
		if descriptor.CourseId == courseId then
			return descriptor
		end
	end
	return nil
end

local function getSafeBounds(): (Vector2, Vector2)
	local succeeded, inset = pcall(function()
		return GuiService:GetInsetArea(Enum.ScreenInsets.CoreUISafeInsets)
	end)
	if succeeded and typeof(inset) == "Rect" and inset.Max.X > inset.Min.X and inset.Max.Y > inset.Min.Y then
		return inset.Min, inset.Max
	end
	local camera = Workspace.CurrentCamera
	if camera then
		return Vector2.zero, camera.ViewportSize
	end
	return Vector2.zero, Vector2.new(1280, 720)
end

local function addCorner(parent: GuiObject, radius: UDim)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius
	corner.Parent = parent
end

local function addStroke(parent: GuiObject, color: Color3, thickness: number, transparency: number): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Transparency = transparency
	stroke.Parent = parent
	return stroke
end

local function createLabel(
	parent: Instance,
	name: string,
	text: string,
	font: Enum.Font,
	color: Color3,
	textSize: number
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.BackgroundTransparency = 1
	label.BorderSizePixel = 0
	label.Text = text
	label.Font = font
	label.TextColor3 = color
	label.TextSize = textSize
	label.Active = false
	label.Selectable = false
	label.Parent = parent
	return label
end

local function createCard(
	parent: Instance,
	name: string,
	title: string,
	description: string,
	features: string
): CourseCardUi
	local button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundColor3 = DARK_NAVY
	button.BorderSizePixel = 0
	button.Text = ""
	button.AutoButtonColor = false
	button.Selectable = true
	button.Active = true
	button.Size = UDim2.new(0.5, -8, 1, 0)
	button.Parent = parent
	addCorner(button, UDim.new(0, 16))
	local border = addStroke(button, PALE_ICE, 2, 0.35)
	local focus = addStroke(button, GOLD, 4, 0)
	focus.Enabled = false

	local titleLabel = createLabel(button, "CourseName", title, Enum.Font.GothamBlack, SNOW_WHITE, 24)
	titleLabel.Position = UDim2.fromOffset(20, 18)
	titleLabel.Size = UDim2.new(1, -40, 0, 34)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left

	local descriptionLabel = createLabel(button, "Description", description, Enum.Font.GothamMedium, PALE_ICE, 15)
	descriptionLabel.Position = UDim2.fromOffset(20, 58)
	descriptionLabel.Size = UDim2.new(1, -40, 0, 42)
	descriptionLabel.TextWrapped = true
	descriptionLabel.TextXAlignment = Enum.TextXAlignment.Left
	descriptionLabel.TextYAlignment = Enum.TextYAlignment.Top

	local featureLabel = createLabel(button, "Features", features, Enum.Font.GothamBold, ICE_CYAN, 14)
	featureLabel.Position = UDim2.fromOffset(20, 108)
	featureLabel.Size = UDim2.new(1, -40, 0, 28)
	featureLabel.TextXAlignment = Enum.TextXAlignment.Left

	local actionLabel = createLabel(button, "Action", "SELECT & TRAVEL", Enum.Font.GothamBlack, SNOW_WHITE, 16)
	actionLabel.AnchorPoint = Vector2.new(0.5, 1)
	actionLabel.Position = UDim2.new(0.5, 0, 1, -16)
	actionLabel.Size = UDim2.new(1, -32, 0, 48)
	actionLabel.BackgroundTransparency = 0
	actionLabel.BackgroundColor3 = GREEN
	actionLabel.TextXAlignment = Enum.TextXAlignment.Center
	addCorner(actionLabel, UDim.new(0, 12))

	return {
		Button = button,
		Border = border,
		Focus = focus,
		NameLabel = titleLabel,
		DescriptionLabel = descriptionLabel,
		FeatureLabel = featureLabel,
		ActionLabel = actionLabel,
	}
end

local function createUi(playerGui: PlayerGui): SelectorUi
	if playerGui:FindFirstChild(SCREEN_GUI_NAME) then
		error(SCREEN_GUI_NAME .. " already exists", 0)
	end
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = SCREEN_GUI_NAME
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.DisplayOrder = 19
	screenGui.Parent = playerGui

	local launcher = Instance.new("TextButton")
	launcher.Name = "CourseLauncher"
	launcher.AnchorPoint = Vector2.new(1, 0)
	launcher.Size = UDim2.fromOffset(164, 88)
	launcher.BackgroundColor3 = DEEP_NAVY
	launcher.BorderSizePixel = 0
	launcher.Text = ""
	launcher.AutoButtonColor = true
	launcher.Visible = false
	launcher.Active = false
	launcher.Selectable = false
	launcher.Parent = screenGui
	addCorner(launcher, UDim.new(0, 16))
	addStroke(launcher, ICE_CYAN, 2, 0)

	local launcherTitle = createLabel(launcher, "Title", "COURSE", Enum.Font.GothamBlack, SNOW_WHITE, 15)
	launcherTitle.Position = UDim2.fromOffset(10, 8)
	launcherTitle.Size = UDim2.new(1, -20, 0, 20)
	launcherTitle.TextXAlignment = Enum.TextXAlignment.Left
	local launcherCourse = createLabel(launcher, "SelectedCourse", "—", Enum.Font.GothamBold, ICE_CYAN, 13)
	launcherCourse.Position = UDim2.fromOffset(10, 32)
	launcherCourse.Size = UDim2.new(1, -20, 0, 20)
	launcherCourse.TextXAlignment = Enum.TextXAlignment.Left
	local launcherAction = createLabel(launcher, "Action", "CHANGE", Enum.Font.GothamBlack, GOLD, 12)
	launcherAction.Position = UDim2.fromOffset(10, 58)
	launcherAction.Size = UDim2.new(1, -20, 0, 18)
	launcherAction.TextXAlignment = Enum.TextXAlignment.Left
	local newBadge = createLabel(launcher, "NewBadge", "NEW COURSE", Enum.Font.GothamBlack, DEEP_NAVY, 9)
	newBadge.AnchorPoint = Vector2.new(1, 0)
	newBadge.Position = UDim2.new(1, -8, 0, 8)
	newBadge.Size = UDim2.fromOffset(69, 18)
	newBadge.BackgroundTransparency = 0
	newBadge.BackgroundColor3 = GOLD
	newBadge.TextXAlignment = Enum.TextXAlignment.Center
	addCorner(newBadge, UDim.new(1, 0))

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "ModalBackdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.new(0, 0, 0)
	backdrop.BackgroundTransparency = 0.30
	backdrop.BorderSizePixel = 0
	backdrop.Text = ""
	backdrop.Visible = false
	backdrop.Active = false
	backdrop.Selectable = false
	backdrop.Modal = false
	backdrop.ZIndex = 20
	backdrop.Parent = screenGui

	local panel = Instance.new("Frame")
	panel.Name = "CoursePanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.BackgroundColor3 = DEEP_NAVY
	panel.BorderSizePixel = 0
	panel.ZIndex = 21
	panel.Parent = backdrop
	addCorner(panel, UDim.new(0, 20))
	addStroke(panel, ICE_CYAN, 2, 0)

	local title = createLabel(panel, "Title", "CHOOSE YOUR COURSE", Enum.Font.GothamBlack, SNOW_WHITE, 28)
	title.Position = UDim2.fromOffset(24, 20)
	title.Size = UDim2.new(1, -92, 0, 42)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 22

	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -18, 0, 16)
	close.Size = UDim2.fromOffset(48, 48)
	close.BackgroundColor3 = WINTER_BLUE
	close.BorderSizePixel = 0
	close.Text = "×"
	close.Font = Enum.Font.GothamBlack
	close.TextSize = 27
	close.TextColor3 = SNOW_WHITE
	close.ZIndex = 23
	close.Parent = panel
	addCorner(close, UDim.new(1, 0))
	local closeFocus = addStroke(close, GOLD, 4, 0)
	closeFocus.Enabled = false

	local status = createLabel(panel, "Status", "", Enum.Font.GothamBold, PALE_ICE, 14)
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.new(0, 24, 1, -16)
	status.Size = UDim2.new(1, -48, 0, 32)
	status.TextXAlignment = Enum.TextXAlignment.Center
	status.TextWrapped = true
	status.ZIndex = 22

	local cardsArea = Instance.new("Frame")
	cardsArea.Name = "CourseCards"
	cardsArea.BackgroundTransparency = 1
	cardsArea.BorderSizePixel = 0
	cardsArea.Position = UDim2.fromOffset(24, 76)
	cardsArea.Size = UDim2.new(1, -48, 1, -136)
	cardsArea.ZIndex = 22
	cardsArea.Parent = panel

	local cardsLayout = Instance.new("UIListLayout")
	cardsLayout.Name = "ResponsiveLayout"
	cardsLayout.FillDirection = Enum.FillDirection.Horizontal
	cardsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	cardsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	cardsLayout.Padding = UDim.new(0, 16)
	cardsLayout.Parent = cardsArea

	local classic = createCard(
		cardsArea,
		"ClassicDistanceCard",
		"CLASSIC DISTANCE",
		"Original distance challenge",
		"QUICK • TUCK • DISTANCE"
	)
	local frost = createCard(
		cardsArea,
		"FrostTrailCard",
		"FROST TRAIL",
		"Long technical mountain run",
		"STEER • HOP • 160 COINS"
	)
	for _, descendant in cardsArea:GetDescendants() do
		if descendant:IsA("GuiObject") then
			descendant.ZIndex = math.max(descendant.ZIndex, 22)
		end
	end

	return {
		ScreenGui = screenGui,
		Launcher = launcher,
		LauncherCourse = launcherCourse,
		NewBadge = newBadge,
		Backdrop = backdrop,
		Panel = panel,
		TitleLabel = title,
		CloseButton = close,
		StatusLabel = status,
		CardsArea = cardsArea,
		CardsLayout = cardsLayout,
		ClassicCard = classic,
		FrostCard = frost,
		FocusStrokes = {
			[classic.Button] = classic.Focus,
			[frost.Button] = frost.Focus,
			[close] = closeFocus,
		},
	}
end

local function hasCurrentState(): boolean
	local state = currentState
	return state ~= nil
		and currentStateGeneration == lifecycleGeneration
		and currentPhase == RunPhase.Idle
		and state.RunPhase == RunPhase.Idle
		and getPresentationCourseId() == state.SelectedCourseId
end

local function uiIdentityIsCurrent(expectedUiGeneration: number): boolean
	if uiGeneration ~= expectedUiGeneration then
		return false
	end
	local currentUi = ui
	local playerGui = currentPlayerGui
	if currentUi == nil or playerGui == nil then
		return false
	end
	return playerGui.Parent == localPlayer
		and findUniqueDirectChild(localPlayer, "PlayerGui", "PlayerGui") == playerGui
		and currentUi.ScreenGui.Parent == playerGui
		and findUniqueDirectChild(playerGui, SCREEN_GUI_NAME, "ScreenGui") == currentUi.ScreenGui
end

local function launcherShouldBeVisible(): boolean
	local character = localPlayer.Character
	return not destroyed
		and not selectorDisabled
		and not modalOpen
		and pendingRequest == nil
		and endpointsAreCurrent()
		and character ~= nil
		and character.Parent ~= nil
		and uiIdentityIsCurrent(uiGeneration)
		and hasCurrentState()
end

local function updateFocusVisuals(currentUi: SelectorUi)
	local selected = GuiService.SelectedObject
	for button, stroke in currentUi.FocusStrokes do
		stroke.Enabled = modalOpen
			and ownsModalFocus
			and currentUi.Backdrop.Visible
			and selected == button
			and button.Active
			and button.Selectable
	end
end

local function updateNavigation(currentUi: SelectorUi)
	local classic = currentUi.ClassicCard.Button
	local frost = currentUi.FrostCard.Button
	local close = currentUi.CloseButton
	local stacked = currentUi.CardsLayout.FillDirection == Enum.FillDirection.Vertical
	classic.NextSelectionRight = frost
	classic.NextSelectionLeft = frost
	frost.NextSelectionRight = classic
	frost.NextSelectionLeft = classic
	close.NextSelectionDown = classic
	close.NextSelectionLeft = frost
	close.NextSelectionRight = classic
	classic.NextSelectionUp = close
	frost.NextSelectionUp = close
	if stacked then
		classic.NextSelectionDown = frost
		frost.NextSelectionUp = classic
		frost.NextSelectionDown = close
	else
		classic.NextSelectionDown = close
		frost.NextSelectionDown = close
	end
end

local function updateResponsiveLayout()
	local currentUi = ui
	if not currentUi then
		return
	end
	local safeMinimum, safeMaximum = getSafeBounds()
	local safeSize = safeMaximum - safeMinimum
	if safeSize.X <= 0 or safeSize.Y <= 0 then
		return
	end
	currentUi.Launcher.Position = UDim2.fromOffset(safeMaximum.X - 18, safeMinimum.Y + 114)
	local panelWidth = math.min(790, safeSize.X * 0.94)
	local panelHeight = math.min(480, safeSize.Y * 0.92)
	currentUi.Panel.Position = UDim2.fromOffset(
		safeMinimum.X + safeSize.X * 0.5,
		safeMinimum.Y + safeSize.Y * 0.5
	)
	currentUi.Panel.Size = UDim2.fromOffset(panelWidth, panelHeight)
	local stacked = panelWidth < 590 or safeSize.Y > safeSize.X
	if stacked then
		currentUi.CardsLayout.FillDirection = Enum.FillDirection.Vertical
		currentUi.CardsLayout.Padding = UDim.new(0, 10)
		currentUi.ClassicCard.Button.Size = UDim2.new(1, 0, 0.5, -5)
		currentUi.FrostCard.Button.Size = UDim2.new(1, 0, 0.5, -5)
		currentUi.ClassicCard.NameLabel.TextSize = 19
		currentUi.FrostCard.NameLabel.TextSize = 19
		currentUi.ClassicCard.DescriptionLabel.Position = UDim2.fromOffset(20, 49)
		currentUi.FrostCard.DescriptionLabel.Position = UDim2.fromOffset(20, 49)
		currentUi.ClassicCard.FeatureLabel.Position = UDim2.fromOffset(20, 82)
		currentUi.FrostCard.FeatureLabel.Position = UDim2.fromOffset(20, 82)
		currentUi.ClassicCard.ActionLabel.Size = UDim2.new(0, 170, 0, 42)
		currentUi.FrostCard.ActionLabel.Size = UDim2.new(0, 170, 0, 42)
		currentUi.ClassicCard.ActionLabel.AnchorPoint = Vector2.new(1, 1)
		currentUi.FrostCard.ActionLabel.AnchorPoint = Vector2.new(1, 1)
		currentUi.ClassicCard.ActionLabel.Position = UDim2.new(1, -14, 1, -12)
		currentUi.FrostCard.ActionLabel.Position = UDim2.new(1, -14, 1, -12)
	else
		currentUi.CardsLayout.FillDirection = Enum.FillDirection.Horizontal
		currentUi.CardsLayout.Padding = UDim.new(0, 16)
		currentUi.ClassicCard.Button.Size = UDim2.new(0.5, -8, 1, 0)
		currentUi.FrostCard.Button.Size = UDim2.new(0.5, -8, 1, 0)
		currentUi.ClassicCard.NameLabel.TextSize = 24
		currentUi.FrostCard.NameLabel.TextSize = 24
		local compact = panelHeight < 390
		currentUi.ClassicCard.DescriptionLabel.Position = UDim2.fromOffset(20, if compact then 50 else 58)
		currentUi.FrostCard.DescriptionLabel.Position = UDim2.fromOffset(20, if compact then 50 else 58)
		currentUi.ClassicCard.FeatureLabel.Position = UDim2.fromOffset(20, if compact then 87 else 108)
		currentUi.FrostCard.FeatureLabel.Position = UDim2.fromOffset(20, if compact then 87 else 108)
		currentUi.ClassicCard.ActionLabel.Size = UDim2.new(1, -32, 0, if compact then 42 else 48)
		currentUi.FrostCard.ActionLabel.Size = UDim2.new(1, -32, 0, if compact then 42 else 48)
		currentUi.ClassicCard.ActionLabel.AnchorPoint = Vector2.new(0.5, 1)
		currentUi.FrostCard.ActionLabel.AnchorPoint = Vector2.new(0.5, 1)
		currentUi.ClassicCard.ActionLabel.Position = UDim2.new(0.5, 0, 1, -16)
		currentUi.FrostCard.ActionLabel.Position = UDim2.new(0.5, 0, 1, -16)
	end
	updateNavigation(currentUi)
end

local function disconnectViewportConnection()
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
end

local function observeCurrentCamera()
	disconnectViewportConnection()
	local camera = Workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveLayout)
	end
	updateResponsiveLayout()
end

local function unbindModalActions()
	if not modalActionsBound then
		return
	end
	modalActionsBound = false
	pcall(function()
		ContextActionService:UnbindAction(MODAL_CLOSE_ACTION)
		ContextActionService:UnbindAction(MODAL_ACTIVATE_ACTION)
		ContextActionService:UnbindAction(MODAL_BLOCK_ACTION)
	end)
end

local function restorePriorFocus(currentUi: SelectorUi?)
	local selected = GuiService.SelectedObject
	if ownsModalFocus or (currentUi and selected and selected:IsDescendantOf(currentUi.ScreenGui)) then
		pcall(function()
			GuiService.SelectedObject = nil
		end)
	end
	local previous = previousSelectedObject
	previousSelectedObject = nil
	if previous
		and previous.Parent ~= nil
		and previous:IsDescendantOf(game)
		and previous.Visible
		and previous.Active
		and previous.Selectable
	then
		pcall(function()
			GuiService.SelectedObject = previous
		end)
	end
end

local function releaseModalOwnership()
	local currentUi = ui
	modalOpen = false
	modalFreshState = false
	requestDeadlineGeneration += 1
	pendingRequest = nil
	if currentUi then
		currentUi.Backdrop.Active = false
		currentUi.Backdrop.Modal = false
		currentUi.Backdrop.Visible = false
		currentUi.ScreenGui.DisplayOrder = 19
		for button in currentUi.FocusStrokes do
			button.Active = false
			button.Selectable = false
		end
	end
	unbindModalActions()
	restorePriorFocus(currentUi)
	ownsModalFocus = false
	if currentUi then
		local launcherVisible = launcherShouldBeVisible()
		currentUi.Launcher.Visible = launcherVisible
		currentUi.Launcher.Active = launcherVisible
		currentUi.Launcher.Selectable = launcherVisible
		updateFocusVisuals(currentUi)
	end
end

closeModal = function(_reason: string)
	releaseModalOwnership()
	renderUi()
end

local function setStatus(message: string, color: Color3)
	statusMessage = message
	statusColor = color
end

local function failurePresentation(status: StatusCode): (string, Color3)
	if status == CourseSelectionTypes.StatusCodes.Busy then
		return "COURSE CHANGE TEMPORARILY UNAVAILABLE", AMBER
	elseif status == CourseSelectionTypes.StatusCodes.CourseUnavailable then
		return "COURSE UNAVAILABLE", RED
	elseif status == CourseSelectionTypes.StatusCodes.CharacterUnavailable then
		return "CHARACTER NOT READY — TRY AGAIN", AMBER
	elseif status == CourseSelectionTypes.StatusCodes.TeleportFailed then
		return "TRAVEL COULD NOT BE VERIFIED — TRY AGAIN", RED
	elseif status == CourseSelectionTypes.StatusCodes.RateLimited
		or status == CourseSelectionTypes.StatusCodes.RequestInProgress
	then
		return "PLEASE WAIT...", AMBER
	elseif status == CourseSelectionTypes.StatusCodes.SafetyFallback then
		return "RETURNED TO CLASSIC FOR SAFETY", AMBER
	elseif status == CourseSelectionTypes.StatusCodes.UnsupportedVersion
		or status == CourseSelectionTypes.StatusCodes.InvalidRequest
		or status == CourseSelectionTypes.StatusCodes.RequestIdConflict
	then
		return "COURSE REQUEST REJECTED", RED
	end
	return "COURSE SERVICE UNAVAILABLE — TRY AGAIN", RED
end

renderUi = function()
	local currentUi = ui
	if not currentUi then
		return
	end
	local state = if hasCurrentState() then currentState else nil
	local launcherVisible = launcherShouldBeVisible()
	currentUi.Launcher.Visible = launcherVisible
	currentUi.Launcher.Active = launcherVisible
	currentUi.Launcher.Selectable = launcherVisible
	currentUi.NewBadge.Visible = launcherVisible and not firstOpenCompleted

	if state then
		currentUi.LauncherCourse.Text = if state.SelectedCourseId == CLASSIC_COURSE_ID
			then "CLASSIC DISTANCE"
			else "FROST TRAIL"
	else
		currentUi.LauncherCourse.Text = "—"
	end

	local showModal = modalOpen and state ~= nil and currentPhase == RunPhase.Idle
	if not showModal then
		if modalOpen or ownsModalFocus or modalActionsBound then
			releaseModalOwnership()
		end
		return
	end
	currentUi.Backdrop.Visible = true
	currentUi.Backdrop.Active = true
	currentUi.Backdrop.Modal = true
	currentUi.ScreenGui.DisplayOrder = 25
	currentUi.CloseButton.Active = true
	currentUi.CloseButton.Selectable = true
	currentUi.ClassicCard.Button.Active = true
	currentUi.ClassicCard.Button.Selectable = true
	currentUi.FrostCard.Button.Active = true
	currentUi.FrostCard.Button.Selectable = true

	local activeState = state :: AcceptedState
	for _, card in { currentUi.ClassicCard, currentUi.FrostCard } do
		local courseId: CourseId = if card == currentUi.ClassicCard then CLASSIC_COURSE_ID else FROST_COURSE_ID
		local descriptor = getCourse(activeState, courseId)
		local selected = activeState.SelectedCourseId == courseId
		local available = descriptor ~= nil and descriptor.Available
		if pendingRequest then
			card.ActionLabel.Text = "PREPARING COURSE..."
			card.ActionLabel.BackgroundColor3 = DISABLED
		elseif selected then
			card.ActionLabel.Text = "SELECTED"
			card.ActionLabel.BackgroundColor3 = WINTER_BLUE
		elseif not available then
			card.ActionLabel.Text = "UNAVAILABLE"
			card.ActionLabel.BackgroundColor3 = DISABLED
		else
			card.ActionLabel.Text = "SELECT & TRAVEL"
			card.ActionLabel.BackgroundColor3 = if modalFreshState and activeState.CanSelect and not mutationDisabled
				then GREEN
				else DISABLED
		end
		card.Border.Color = if selected then GOLD else PALE_ICE
		card.Border.Thickness = if selected then 3 else 2
	end
	currentUi.StatusLabel.Text = if pendingRequest then "PREPARING COURSE..." else statusMessage
	currentUi.StatusLabel.TextColor3 = if pendingRequest then PALE_ICE else statusColor
	updateFocusVisuals(currentUi)
end

local function attachUi(playerGui: PlayerGui)
	if destroyed or currentPlayerGui == playerGui or currentState == nil or not isKnownPhase(currentPhase) then
		return
	end
	if currentPlayerGui and currentPlayerGui ~= playerGui then
		closeModal("player-gui-replaced")
		disconnectViewportConnection()
		disconnectAll(uiConnections)
		if ui then
			ui.ScreenGui:Destroy()
		end
		ui = nil
	end
	currentPlayerGui = playerGui
	uiGeneration += 1
	local attachedGeneration = uiGeneration
	local newUi = createUi(playerGui)
	ui = newUi

	local function activateCourse(courseId: CourseId, button: TextButton)
		if destroyed
			or ui ~= newUi
			or uiGeneration ~= attachedGeneration
			or not modalOpen
			or not ownsModalFocus
			or not button.Active
			or not button.Selectable
		then
			return
		end
		pcall(function()
			GuiService.SelectedObject = button
		end)
		local state = if hasCurrentState() then currentState else nil
		if not state then
			closeModal("invalid-state")
			return
		end
		if state.SelectedCourseId == courseId then
			setStatus("ALREADY SELECTED", PALE_ICE)
			renderUi()
			return
		end
		local descriptor = getCourse(state, courseId)
		if not descriptor or not descriptor.Available then
			setStatus("COURSE UNAVAILABLE", RED)
			renderUi()
			return
		end
		if pendingRequest then
			return
		end
		if mutationDisabled or not modalFreshState or not state.CanSelect then
			setStatus("COURSE CHANGE TEMPORARILY UNAVAILABLE", AMBER)
			renderUi()
			return
		end
		modalFreshState = false
		setStatus("PREPARING COURSE...", PALE_ICE)
		beginRequest(CourseSelectionTypes.Actions.Select, courseId, "Select", courseId, false)
		renderUi()
	end

	table.insert(uiConnections, newUi.Launcher.Activated:Connect(function()
		if not launcherShouldBeVisible() or pendingRequest ~= nil then
			return
		end
		releaseModalOwnership()
		modalOpen = true
		ownsModalFocus = true
		firstOpenCompleted = true
		modalFreshState = false
		mutationDisabled = false
		statusMessage = ""
		previousSelectedObject = GuiService.SelectedObject
		local bindSucceeded, bindFailure = pcall(function()
			ContextActionService:BindActionAtPriority(
				MODAL_BLOCK_ACTION,
				function(_name: string, _state: Enum.UserInputState, _input: InputObject)
					return Enum.ContextActionResult.Sink
				end,
				false,
				MODAL_ACTION_PRIORITY,
				Enum.PlayerActions.CharacterForward,
				Enum.PlayerActions.CharacterBackward,
				Enum.PlayerActions.CharacterLeft,
				Enum.PlayerActions.CharacterRight,
				Enum.PlayerActions.CharacterJump,
				Enum.KeyCode.E,
				Enum.KeyCode.ButtonX,
				Enum.KeyCode.LeftShift,
				Enum.KeyCode.RightShift,
				Enum.KeyCode.ButtonL2
			)
			ContextActionService:BindActionAtPriority(
				MODAL_ACTIVATE_ACTION,
				function(_name: string, inputState: Enum.UserInputState, _input: InputObject)
					if inputState == Enum.UserInputState.Begin then
						local focused = GuiService.SelectedObject
						if focused == newUi.ClassicCard.Button then
							activateCourse(CLASSIC_COURSE_ID, newUi.ClassicCard.Button)
						elseif focused == newUi.FrostCard.Button then
							activateCourse(FROST_COURSE_ID, newUi.FrostCard.Button)
						elseif focused == newUi.CloseButton then
							closeModal("focused-close")
						end
					end
					return Enum.ContextActionResult.Sink
				end,
				false,
				MODAL_ACTION_PRIORITY + 1,
				Enum.KeyCode.Return,
				Enum.KeyCode.KeypadEnter,
				Enum.KeyCode.Space,
				Enum.KeyCode.ButtonA
			)
			ContextActionService:BindActionAtPriority(
				MODAL_CLOSE_ACTION,
				function(_name: string, inputState: Enum.UserInputState, _input: InputObject)
					if inputState == Enum.UserInputState.Begin then
						closeModal("escape-or-button-b")
					end
					return Enum.ContextActionResult.Sink
				end,
				false,
				MODAL_ACTION_PRIORITY + 2,
				Enum.KeyCode.Escape,
				Enum.KeyCode.ButtonB
			)
		end)
		if not bindSucceeded then
			pcall(function()
				ContextActionService:UnbindAction(MODAL_CLOSE_ACTION)
				ContextActionService:UnbindAction(MODAL_ACTIVATE_ACTION)
				ContextActionService:UnbindAction(MODAL_BLOCK_ACTION)
			end)
			closeModal("input-bind-failed")
			warnOnce("modal input protection failed: " .. tostring(bindFailure))
			return
		end
		modalActionsBound = true
		renderUi()
		pcall(function()
			GuiService.SelectedObject = newUi.ClassicCard.Button
		end)
		updateFocusVisuals(newUi)
		beginRequest(CourseSelectionTypes.Actions.GetState, nil, "Modal", nil, false)
		renderUi()
	end))

	table.insert(uiConnections, newUi.CloseButton.Activated:Connect(function()
		closeModal("close-button")
	end))
	table.insert(uiConnections, newUi.ClassicCard.Button.Activated:Connect(function()
		activateCourse(CLASSIC_COURSE_ID, newUi.ClassicCard.Button)
	end))
	table.insert(uiConnections, newUi.FrostCard.Button.Activated:Connect(function()
		activateCourse(FROST_COURSE_ID, newUi.FrostCard.Button)
	end))
	table.insert(uiConnections, newUi.Backdrop.Activated:Connect(function() end))
	table.insert(uiConnections, newUi.Backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateResponsiveLayout))
	table.insert(uiConnections, GuiService:GetPropertyChangedSignal("ViewportDisplaySize"):Connect(updateResponsiveLayout))
	table.insert(uiConnections, playerGui:GetPropertyChangedSignal("CurrentScreenOrientation"):Connect(updateResponsiveLayout))
	table.insert(uiConnections, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(observeCurrentCamera))
	table.insert(uiConnections, GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(function()
		if destroyed or ui ~= newUi or uiGeneration ~= attachedGeneration then
			return
		end
		local selected = GuiService.SelectedObject
		if modalOpen and ownsModalFocus then
			if not selected or not selected:IsDescendantOf(newUi.Backdrop) then
				pcall(function()
					GuiService.SelectedObject = newUi.ClassicCard.Button
				end)
			end
		elseif selected and selected:IsDescendantOf(newUi.Backdrop) then
			pcall(function()
				GuiService.SelectedObject = nil
			end)
		end
		updateFocusVisuals(newUi)
	end))
	table.insert(uiConnections, newUi.ScreenGui.Destroying:Connect(function()
		if ui == newUi then
			closeModal("ui-destroying")
			disconnectViewportConnection()
			ui = nil
			currentPlayerGui = nil
			uiGeneration += 1
			disconnectAll(uiConnections)
		end
	end))
	observeCurrentCamera()
	renderUi()
end

local function ensureUi()
	if ui or not currentState or not isKnownPhase(currentPhase) then
		return
	end
	local playerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		local succeeded, failureReason = pcall(attachUi, playerGui)
		if not succeeded then
			selectorDisabled = true
			currentPlayerGui = nil
			warnOnce("UI creation failed: " .. tostring(failureReason))
		end
	end
end

local function invalidateLifecycle(reason: string)
	lifecycleGeneration += 1
	idleRevealGeneration += 1
	requestDeadlineGeneration += 1
	pendingRequest = nil
	currentStateGeneration = -1
	modalFreshState = false
	mutationDisabled = false
	statusMessage = ""
	closeModal(reason)
end

local function responseMatchesPending(response: ParsedResponse, pending: PendingRequest): boolean
	return response.ResponseToRequestId == pending.RequestId
		and response.ResponseClientSequence == pending.ClientSequence
		and response.ResponseAction == pending.Action
		and response.ResponseCourseId == pending.CourseId
		and pending.LifecycleGeneration == lifecycleGeneration
		and pending.EndpointGeneration == endpointGeneration
		and pending.UiGenerationAtSend == uiGeneration
end

local function finishAcceptedResponse(response: ParsedResponse, pending: PendingRequest)
	if pendingRequest ~= pending or not responseMatchesPending(response, pending) then
		return
	end
	local successfulSelect = pending.Action == CourseSelectionTypes.Actions.Select
		and (response.StatusCode == CourseSelectionTypes.StatusCodes.Success
			or response.StatusCode == CourseSelectionTypes.StatusCodes.AlreadySelected)
	if successfulSelect then
		local character = localPlayer.Character
		if not response.Ok
			or pending.CycleKind ~= "Select"
			or pending.CourseId == nil
			or response.ResponseCourseId ~= pending.CourseId
			or response.SelectedCourseId ~= pending.CourseId
			or response.RunPhase ~= RunPhase.Idle
			or currentPhase ~= RunPhase.Idle
			or getPresentationCourseId() ~= response.SelectedCourseId
			or not endpointsAreCurrent()
			or character == nil
			or character.Parent == nil
			or not modalOpen
			or not ownsModalFocus
			or not modalActionsBound
			or not uiIdentityIsCurrent(pending.UiGenerationAtSend)
		then
			requestDeadlineGeneration += 1
			pendingRequest = nil
			mutationDisabled = true
			closeModal("selection-completion-invalid")
			return
		end
	end
	if response.RunPhase ~= currentPhase then
		if pending.Action == CourseSelectionTypes.Actions.GetState
			and pending.PhaseGenerationAtSend == phaseGeneration
		then
			currentPhase = response.RunPhase
			currentPhaseRank = phaseRank(response.RunPhase) or 0
		else
			requestDeadlineGeneration += 1
			pendingRequest = nil
			mutationDisabled = true
			closeModal("phase-mismatch")
			return
		end
	end
	requestDeadlineGeneration += 1
	pendingRequest = nil
	currentState = table.freeze({
		ServerSequence = response.ServerSequence,
		SelectedCourseId = response.SelectedCourseId,
		CanSelect = response.CanSelect,
		RunPhase = response.RunPhase,
		Courses = response.Courses,
	})
	currentStateGeneration = lifecycleGeneration
	ensureUi()
	if pending.ReconciliationUsed
		and pending.Action == CourseSelectionTypes.Actions.GetState
		and (not response.Ok or response.StatusCode ~= CourseSelectionTypes.StatusCodes.State)
	then
		mutationDisabled = true
		modalFreshState = false
		setStatus("COURSE STATE COULD NOT BE CONFIRMED", RED)
		renderUi()
		return
	end

	if pending.CycleKind == "Modal" then
		modalFreshState = response.Ok and response.StatusCode == CourseSelectionTypes.StatusCodes.State
	elseif pending.CycleKind == "Select" then
		modalFreshState = true
	end
	if response.StatusCode == CourseSelectionTypes.StatusCodes.Success
		or response.StatusCode == CourseSelectionTypes.StatusCodes.AlreadySelected
	then
		setStatus("COURSE READY", GREEN)
		renderUi()
		closeModal("selection-confirmed")
		return
	elseif response.StatusCode == CourseSelectionTypes.StatusCodes.SafetyFallback then
		modalFreshState = true
		mutationDisabled = false
		setStatus("RETURNED TO CLASSIC FOR SAFETY", AMBER)
	elseif not response.Ok then
		local message, color = failurePresentation(response.StatusCode)
		setStatus(message, color)
		modalFreshState = pending.CycleKind == "Select" and response.CanSelect
	end

	if pending.ReconciliationUsed and pending.CycleKind == "Select" then
		if pending.CycleCourseId == response.SelectedCourseId then
			renderUi()
			closeModal("selection-reconciled")
			return
		end
		setStatus("COURSE STATE REFRESHED — SELECTION NOT CONFIRMED", AMBER)
	end
	renderUi()
end

local function spendReconciliationOrFail(pending: PendingRequest, message: string)
	if pendingRequest ~= pending then
		return
	end
	requestDeadlineGeneration += 1
	pendingRequest = nil
	if not pending.ReconciliationUsed
		and not destroyed
		and pending.LifecycleGeneration == lifecycleGeneration
		and pending.EndpointGeneration == endpointGeneration
		and selectionRemote ~= nil
		and runStateRemote ~= nil
	then
		beginRequest(
			CourseSelectionTypes.Actions.GetState,
			nil,
			pending.CycleKind,
			pending.CycleCourseId,
			true
		)
		return
	end
	mutationDisabled = true
	modalFreshState = false
	setStatus(message, RED)
	renderUi()
end

local function tryCompletePendingConvergence()
	local pending = pendingRequest
	if not pending or not pending.TerminalResponse then
		return
	end
	local response = pending.TerminalResponse
	if getPresentationCourseId() == response.SelectedCourseId then
		finishAcceptedResponse(response, pending)
	end
end

beginRequest = function(
	action: Action,
	courseId: CourseId?,
	cycleKind: CycleKind,
	cycleCourseId: CourseId?,
	reconciliationUsed: boolean
): boolean
	if destroyed
		or selectorDisabled
		or pendingRequest ~= nil
		or not selectionRemote
		or not runStateRemote
		or not endpointsAreCurrent()
	then
		return false
	end
	if clientSequence >= CourseSelectionTypes.MaximumClientSequence then
		selectorDisabled = true
		mutationDisabled = true
		if not sequenceWarningIssued then
			sequenceWarningIssued = true
			warnOnce("client request sequence exhausted")
		end
		closeModal("sequence-exhausted")
		return false
	end
	clientSequence += 1
	local requestId = string.lower(HttpService:GenerateGUID(false))
	if not isCanonicalGuid(requestId) then
		mutationDisabled = true
		closeModal("guid-unavailable")
		warnOnce("canonical request ID generation failed")
		return false
	end
	requestDeadlineGeneration += 1
	local deadlineGeneration = requestDeadlineGeneration
	local pending: PendingRequest = {
		RequestId = requestId,
		ClientSequence = clientSequence,
		Action = action,
		CourseId = courseId,
		CycleKind = cycleKind,
		CycleCourseId = cycleCourseId,
		ReconciliationUsed = reconciliationUsed,
		LifecycleGeneration = lifecycleGeneration,
		EndpointGeneration = endpointGeneration,
		UiGenerationAtSend = uiGeneration,
		PhaseGenerationAtSend = phaseGeneration,
		DeadlineGeneration = deadlineGeneration,
		TerminalResponse = nil,
	}
	pendingRequest = pending
	local payload: { [string]: any } = {
		ProtocolVersion = CourseSelectionTypes.ProtocolVersion,
		RequestId = requestId,
		ClientSequence = clientSequence,
		Action = action,
	}
	if action == CourseSelectionTypes.Actions.Select then
		payload.CourseId = courseId
	end
	local fired = pcall(function()
		(selectionRemote :: RemoteEvent):FireServer(payload)
	end)
	if not fired then
		spendReconciliationOrFail(pending, "COURSE SERVICE UNAVAILABLE — TRY AGAIN")
		return false
	end
	task.delay(REQUEST_TIMEOUT_SECONDS, function()
		if destroyed
			or pendingRequest ~= pending
			or pending.DeadlineGeneration ~= deadlineGeneration
			or pending.TerminalResponse ~= nil
		then
			return
		end
		spendReconciliationOrFail(pending, "COURSE STATE COULD NOT BE CONFIRMED")
	end)
	renderUi()
	return true
end

local function acceptResponse(rawResponse: any)
	if destroyed then
		return
	end
	local response = parseResponse(rawResponse)
	local pending = pendingRequest
	if not response or not pending or not responseMatchesPending(response, pending) then
		return
	end
	if response.ServerSequence <= latestServerSequence then
		return
	end
	latestServerSequence = response.ServerSequence
	if response.StatusCode == CourseSelectionTypes.StatusCodes.RequestInProgress then
		return
	end
	pending.TerminalResponse = response
	requestDeadlineGeneration += 1
	local convergenceGeneration = requestDeadlineGeneration
	pending.DeadlineGeneration = convergenceGeneration
	if getPresentationCourseId() == response.SelectedCourseId then
		finishAcceptedResponse(response, pending)
		return
	end
	task.delay(ATTRIBUTE_CONVERGENCE_TIMEOUT_SECONDS, function()
		if destroyed
			or pendingRequest ~= pending
			or pending.DeadlineGeneration ~= convergenceGeneration
		then
			return
		end
		if getPresentationCourseId() == response.SelectedCourseId then
			tryCompletePendingConvergence()
			return
		end
		spendReconciliationOrFail(pending, "COURSE ROUTE DID NOT CONVERGE")
	end)
end

scheduleIdleReveal = function(_source: string)
	idleRevealGeneration += 1
	local revealGeneration = idleRevealGeneration
	local expectedLifecycle = lifecycleGeneration
	local expectedEndpoint = endpointGeneration
	local expectedCharacter = localPlayer.Character
	local expectedSelectionRemote = selectionRemote
	local expectedRunRemote = runStateRemote
	local expectedPresentationCourseId = getPresentationCourseId()
	task.delay(IDLE_REVEAL_SECONDS, function()
		if destroyed
			or revealGeneration ~= idleRevealGeneration
			or expectedLifecycle ~= lifecycleGeneration
			or expectedEndpoint ~= endpointGeneration
			or expectedCharacter == nil
			or localPlayer.Character ~= expectedCharacter
			or expectedCharacter.Parent == nil
			or selectionRemote ~= expectedSelectionRemote
			or runStateRemote ~= expectedRunRemote
			or not endpointsAreCurrent()
			or currentPhase ~= RunPhase.Idle
			or pendingRequest ~= nil
			or expectedPresentationCourseId == nil
			or getPresentationCourseId() ~= expectedPresentationCourseId
		then
			return
		end
		beginRequest(CourseSelectionTypes.Actions.GetState, nil, "Lifecycle", nil, false)
	end)
end

local function acceptRunState(phaseValue: any, runIdValue: any)
	if destroyed then
		return
	end
	if typeof(phaseValue) ~= "string"
		or not isFiniteInteger(runIdValue, 1, CourseSelectionTypes.MaximumServerSequence)
	then
		currentPhase = UNKNOWN_PHASE
		currentRunId = nil
		currentPhaseRank = 0
		phaseGeneration += 1
		invalidateLifecycle("invalid-run-state")
		return
	end
	local phase = phaseValue :: string
	local runId = runIdValue :: number
	local rank = phaseRank(phase)
	if not rank then
		currentPhase = UNKNOWN_PHASE
		currentRunId = nil
		currentPhaseRank = 0
		phaseGeneration += 1
		invalidateLifecycle("invalid-run-phase")
		return
	end
	if runId < latestRunId then
		return
	end
	local runChanged = currentRunId ~= runId
	if runChanged then
		latestRunId = math.max(latestRunId, runId)
		currentRunId = runId
		currentPhaseRank = 0
	elseif rank < currentPhaseRank then
		return
	end
	-- Even a same-phase authoritative record is newer than a GetState sent
	-- before it, so it must close that request's phase-establishment window.
	phaseGeneration += 1
	if not runChanged and phase == currentPhase then
		return
	end
	currentPhase = phase
	currentPhaseRank = rank
	invalidateLifecycle("run-state-changed")
	if phase == RunPhase.Idle then
		scheduleIdleReveal("run-state-idle")
	end
end

local function detachUi()
	closeModal("ui-detach")
	disconnectViewportConnection()
	disconnectAll(uiConnections)
	uiGeneration += 1
	local oldUi = ui
	ui = nil
	currentPlayerGui = nil
	if oldUi and oldUi.ScreenGui.Parent then
		oldUi.ScreenGui:Destroy()
	end
end

local function disconnectEndpointAcquisition()
	local connection = endpointAcquisitionConnection
	endpointAcquisitionConnection = nil
	if connection then
		connection:Disconnect()
	end
end

local function disableEndpoint(reason: string)
	disconnectEndpointAcquisition()
	endpointGeneration += 1
	idleRevealGeneration += 1
	requestDeadlineGeneration += 1
	pendingRequest = nil
	selectionRemote = nil
	runStateRemote = nil
	currentStateGeneration = -1
	disconnectAll(remoteConnections)
	detachUi()
	warnOnce(reason)
end

local function activateEndpoints(folder: Folder, courseRemote: RemoteEvent, runRemote: RemoteEvent): boolean
	if destroyed
		or selectorDisabled
		or selectionRemote ~= nil
		or runStateRemote ~= nil
		or findUniqueDirectChild(ReplicatedStorage, REMOTES_FOLDER_NAME, "Folder") ~= folder
		or findUniqueDirectChild(folder, CourseSelectionTypes.RemoteName, "RemoteEvent") ~= courseRemote
		or findUniqueDirectChild(folder, RUN_STATE_REMOTE_NAME, "RemoteEvent") ~= runRemote
	then
		return false
	end

	endpointAcquisitionGeneration += 1
	disconnectEndpointAcquisition()
	selectionRemote = courseRemote
	runStateRemote = runRemote
	endpointGeneration += 1
	local connectedEndpointGeneration = endpointGeneration

	-- The response listener is connected before the initial request is emitted.
	table.insert(remoteConnections, courseRemote.OnClientEvent:Connect(acceptResponse))
	-- This controller owns one independent RunState subscription.
	table.insert(remoteConnections, runRemote.OnClientEvent:Connect(function(
		phase: any,
		_countdown: any,
		_speed: any,
		runId: any
	)
		acceptRunState(phase, runId)
	end))
	local function onEndpointAncestryChanged(_instance: Instance, _parent: Instance?)
		if connectedEndpointGeneration == endpointGeneration and not endpointsAreCurrent() then
			disableEndpoint("optional endpoint was removed")
		end
	end
	table.insert(remoteConnections, courseRemote.AncestryChanged:Connect(onEndpointAncestryChanged))
	table.insert(remoteConnections, runRemote.AncestryChanged:Connect(onEndpointAncestryChanged))
	table.insert(remoteConnections, folder.AncestryChanged:Connect(onEndpointAncestryChanged))

	table.insert(controllerConnections, localPlayer:GetAttributeChangedSignal(PRESENTATION_COURSE_ATTRIBUTE):Connect(function()
		if destroyed then
			return
		end
		local pending = pendingRequest
		local presentationCourseId = getPresentationCourseId()
		local character = localPlayer.Character
		if pending and pending.TerminalResponse then
			tryCompletePendingConvergence()
		elseif pending
			and pending.Action == CourseSelectionTypes.Actions.Select
			and pending.CycleKind == "Select"
			and pending.CourseId ~= nil
			and presentationCourseId == pending.CourseId
			and pending.LifecycleGeneration == lifecycleGeneration
			and pending.EndpointGeneration == endpointGeneration
			and pending.UiGenerationAtSend == uiGeneration
			and currentPhase == RunPhase.Idle
			and modalOpen
			and ownsModalFocus
			and modalActionsBound
			and endpointsAreCurrent()
			and character ~= nil
			and character.Parent ~= nil
			and uiIdentityIsCurrent(pending.UiGenerationAtSend)
		then
			-- Course routing commits the server-owned attribute before its terminal
			-- Select response. Keep the request hidden and let that response decide.
			return
		elseif currentState and presentationCourseId ~= currentState.SelectedCourseId then
			invalidateLifecycle("presentation-course-changed")
			if currentPhase == RunPhase.Idle then
				scheduleIdleReveal("presentation-course-changed")
			end
		else
			renderUi()
		end
	end))
	table.insert(controllerConnections, localPlayer.CharacterRemoving:Connect(function(_character: Model)
		invalidateLifecycle("character-removing")
	end))
	table.insert(controllerConnections, localPlayer.CharacterAdded:Connect(function(_character: Model)
		invalidateLifecycle("character-added")
		if currentPhase == RunPhase.Idle then
			scheduleIdleReveal("character-added")
		end
	end))
	table.insert(controllerConnections, localPlayer.ChildAdded:Connect(function(child: Instance)
		if child:IsA("PlayerGui") then
			invalidateLifecycle("player-gui-added")
			if currentPlayerGui ~= nil and currentPlayerGui ~= child then
				detachUi()
			end
			if currentPhase == RunPhase.Idle then
				scheduleIdleReveal("player-gui-added")
			end
		end
	end))
	table.insert(controllerConnections, localPlayer.ChildRemoved:Connect(function(child: Instance)
		if child == currentPlayerGui then
			invalidateLifecycle("player-gui-removed")
			detachUi()
		end
	end))
	beginRequest(CourseSelectionTypes.Actions.GetState, nil, "Initial", nil, false)
	return true
end

local function tryAcquireEndpoints(acquisitionGeneration: number): boolean
	if destroyed
		or selectorDisabled
		or acquisitionGeneration ~= endpointAcquisitionGeneration
		or selectionRemote ~= nil
		or runStateRemote ~= nil
	then
		return false
	end
	local folderInstance = findUniqueDirectChild(ReplicatedStorage, REMOTES_FOLDER_NAME, "Folder")
	if not folderInstance then
		return false
	end
	local courseRemoteInstance = findUniqueDirectChild(
		folderInstance,
		CourseSelectionTypes.RemoteName,
		"RemoteEvent"
	)
	local runRemoteInstance = findUniqueDirectChild(folderInstance, RUN_STATE_REMOTE_NAME, "RemoteEvent")
	if not courseRemoteInstance or not runRemoteInstance then
		return false
	end
	return activateEndpoints(
		folderInstance :: Folder,
		courseRemoteInstance :: RemoteEvent,
		runRemoteInstance :: RemoteEvent
	)
end

local function beginEndpointAcquisition()
	endpointAcquisitionGeneration += 1
	local acquisitionGeneration = endpointAcquisitionGeneration
	endpointAcquisitionConnection = ReplicatedStorage.DescendantAdded:Connect(function(descendant: Instance)
		if descendant.Name == REMOTES_FOLDER_NAME
			or descendant.Name == CourseSelectionTypes.RemoteName
			or descendant.Name == RUN_STATE_REMOTE_NAME
		then
			tryAcquireEndpoints(acquisitionGeneration)
		end
	end)
	if tryAcquireEndpoints(acquisitionGeneration) then
		return
	end
	task.delay(ENDPOINT_ACQUISITION_TIMEOUT_SECONDS, function()
		if destroyed
			or acquisitionGeneration ~= endpointAcquisitionGeneration
			or selectionRemote ~= nil
			or runStateRemote ~= nil
		then
			return
		end
		endpointAcquisitionGeneration += 1
		disconnectEndpointAcquisition()
		selectorDisabled = true
	end)
end

function CourseSelectionController.start()
	if started then
		return
	end
	started = true
	destroyed = false
	selectorDisabled = false
	table.insert(controllerConnections, script.Destroying:Connect(CourseSelectionController.destroy))
	beginEndpointAcquisition()
end

function CourseSelectionController.destroy()
	if destroyed then
		return
	end
	destroyed = true
	endpointAcquisitionGeneration += 1
	disconnectEndpointAcquisition()
	lifecycleGeneration += 1
	endpointGeneration += 1
	idleRevealGeneration += 1
	requestDeadlineGeneration += 1
	pendingRequest = nil
	releaseModalOwnership()
	disconnectAll(remoteConnections)
	disconnectAll(controllerConnections)
	detachUi()
	selectionRemote = nil
	runStateRemote = nil
	currentState = nil
	currentStateGeneration = -1
	started = false
end

return CourseSelectionController
