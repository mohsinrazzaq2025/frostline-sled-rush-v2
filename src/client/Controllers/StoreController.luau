--!strict

local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RunPhase = require(ReplicatedStorage.Shared.RunPhase)
local StoreTypes = require(ReplicatedStorage.Shared.StoreTypes)

local REMOTES_FOLDER_NAME = "FrostlineRemotes"
local STORE_REQUEST_REMOTE_NAME = "StoreRequest"
local STORE_STATE_REMOTE_NAME = "StoreState"
local RUN_STATE_REMOTE_NAME = "RunState"
local STORE_GUI_NAME = "FrostlineStoreUI"
local STORE_MODAL_BLOCK_ACTION = "FrostlineStoreModalBlock"
local STORE_MODAL_CLOSE_ACTION = "FrostlineStoreModalClose"
local MODAL_ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 3
local REMOTE_ACQUISITION_TIMEOUT_SECONDS = 8
local CLASSIC_SLED_ID = "FrostlineClassic"
local RUNNER_SLED_ID = "FrostRunner"

local DARK_NAVY = Color3.fromRGB(11, 31, 58)
local DEEP_NAVY = Color3.fromRGB(6, 22, 43)
local WINTER_BLUE = Color3.fromRGB(18, 59, 93)
local ICE_CYAN = Color3.fromRGB(115, 232, 255)
local SECONDARY_ICE = Color3.fromRGB(180, 231, 247)
local SNOW_WHITE = Color3.fromRGB(245, 251, 255)
local COIN_GOLD = Color3.fromRGB(255, 212, 90)
local PINE_GREEN = Color3.fromRGB(47, 166, 107)
local CHRISTMAS_RED = Color3.fromRGB(217, 74, 74)
local WARNING_AMBER = Color3.fromRGB(244, 185, 66)
local DISABLED_BLUE = Color3.fromRGB(47, 74, 96)

type StoreAction = StoreTypes.Action
type StoreStatusCode = StoreTypes.StatusCode
type StoreState = StoreTypes.StoreState
type CatalogEntry = StoreTypes.CatalogEntry

type CardUi = {
	Button: TextButton,
	BrowseStroke: UIStroke,
	NameLabel: TextLabel,
	StateLabel: TextLabel,
	DetailLabel: TextLabel,
}

type StoreUi = {
	ScreenGui: ScreenGui,
	LauncherRoot: Frame,
	LauncherScale: UIScale,
	Launcher: TextButton,
	LauncherEquipped: TextLabel,
	LauncherBalance: TextLabel,
	Backdrop: TextButton,
	Panel: Frame,
	SnowCap: CanvasGroup,
	TitleLabel: TextLabel,
	BalanceLabel: TextLabel,
	CloseButton: TextButton,
	SectionLabel: TextLabel,
	CardsArea: Frame,
	CardsLayout: UIListLayout,
	ClassicCard: CardUi,
	RunnerCard: CardUi,
	DetailsFrame: Frame,
	SelectedNameLabel: TextLabel,
	SelectedDescriptionLabel: TextLabel,
	StatusLabel: TextLabel,
	ActionArea: Frame,
	PrimaryButton: TextButton,
	ConfirmationFrame: Frame,
	ConfirmationLabel: TextLabel,
	ConfirmButton: TextButton,
	CancelButton: TextButton,
	ModalButtons: { TextButton },
	FocusStrokes: { [GuiButton]: UIStroke },
	SelectionImages: { Frame },
}

type RequestContext = {
	RequestId: string,
	Action: StoreAction,
	SledId: string?,
	ExpectedRevision: number?,
	LifecycleGeneration: number,
	RemoteGeneration: number,
	UiGeneration: number,
}

type BrowseSelectionSource = "Startup" | "FreshOpen" | "Pointer" | "Focus" | "CatalogFallback"

local StoreController = {}

local localPlayer = Players.LocalPlayer
local started = false
local destroyed = false
local warningIssued = false
local lifecycleGeneration = 0
local remoteGeneration = 0
local uiGeneration = 0
local latestRunId = 0
local currentRunId: number? = nil
local currentPhase: string = RunPhase.Idle
local currentPhaseRank = 0
local currentPlayerGui: PlayerGui? = nil
local ui: StoreUi? = nil
local storeRequestRemote: RemoteEvent? = nil
local storeStateRemote: RemoteEvent? = nil
local runStateRemote: RemoteEvent? = nil
local currentState: StoreState? = nil
local currentStateGeneration = -1
local latestServerSequence = -1
local selectedSledId = CLASSIC_SLED_ID
local modalOpen = false
local modalFocusGeneration = 0
local activeModalFocusGeneration: number? = nil
local storeOwnsFocus = false
local confirmationRevision: number? = nil
local pendingRefreshId: string? = nil
local pendingMutation: RequestContext? = nil
local freshnessRequired = true
local statusMessage = ""
local statusColor = SECONDARY_ICE
local requestContexts: { [string]: RequestContext } = {}
local requestOrder: { string } = {}
local controllerConnections: { RBXScriptConnection } = {}
local remoteConnections: { RBXScriptConnection } = {}
local uiConnections: { RBXScriptConnection } = {}
local viewportConnection: RBXScriptConnection? = nil
local modalActionsBound = false

local renderUi: () -> ()
local requestStateRefresh: (string) -> ()
local closeModal: (string) -> ()
local releaseModalOwnership: (string) -> ()
local selectSled: (string, BrowseSelectionSource) -> boolean

local function addCorner(parent: Instance, radius: number)
	local corner = Instance.new("UICorner")
	corner.Name = "RoundedCorner"
	corner.CornerRadius = UDim.new(0, radius)
	corner.Parent = parent
end

local function addRoundedFocusStyle(
	button: TextButton,
	radius: number,
	focusStrokes: { [GuiButton]: UIStroke },
	selectionImages: { Frame }
)
	-- A transparent per-control override suppresses Roblox's square default
	-- selection adornment. The enabled border stroke below follows the same
	-- UICorner as its button and is driven by the current SelectedObject.
	local selectionImage = Instance.new("Frame")
	selectionImage.Name = "NativeSelectionSuppressor"
	selectionImage.BackgroundTransparency = 1
	selectionImage.BorderSizePixel = 0
	selectionImage.Size = UDim2.fromScale(1, 1)
	selectionImage.Active = false
	selectionImage.Selectable = false
	button.SelectionImageObject = selectionImage
	table.insert(selectionImages, selectionImage)

	local focusStroke = Instance.new("UIStroke")
	focusStroke.Name = "RoundedFocusStroke"
	focusStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	focusStroke.Color = SNOW_WHITE
	focusStroke.Thickness = 2.5
	focusStroke.Transparency = 0.04
	focusStroke.Enabled = false
	focusStroke.Parent = button
	focusStrokes[button] = focusStroke

	-- The target owns the matching rounded shape; keep this assertion local to
	-- deterministic construction rather than adding runtime repair work.
	local corner = button:FindFirstChild("RoundedCorner")
	if not corner or not corner:IsA("UICorner") or corner.CornerRadius ~= UDim.new(0, radius) then
		error(string.format("Store focus target %s is missing its rounded corner", button.Name))
	end
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

local function createButton(parent: Instance, name: string, text: string, color: Color3): TextButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundColor3 = color
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Font = Enum.Font.GothamBlack
	button.Text = text
	button.TextColor3 = SNOW_WHITE
	button.TextScaled = true
	button.TextWrapped = true
	button.Active = false
	button.Selectable = false
	button.Parent = parent
	addTextConstraint(button, 11, 20)
	addCorner(button, 11)

	local stroke = Instance.new("UIStroke")
	stroke.Color = SNOW_WHITE
	stroke.Thickness = 1.5
	stroke.Transparency = 0.48
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = button
	return button
end

local function createCard(parent: Instance, name: string, entry: CatalogEntry): CardUi
	local button = Instance.new("TextButton")
	button.Name = name
	button.BackgroundColor3 = Color3.fromRGB(9, 42, 70)
	button.BackgroundTransparency = 0.04
	button.BorderSizePixel = 0
	button.AutoButtonColor = true
	button.Text = ""
	button.Active = false
	button.Selectable = false
	button.Parent = parent
	addCorner(button, 13)

	local stroke = Instance.new("UIStroke")
	stroke.Name = "BrowseSelectionStroke"
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Color = ICE_CYAN
	stroke.Thickness = 1.5
	stroke.Transparency = 0.5
	stroke.Parent = button

	local nameLabel = createLabel(button, "SledName", entry.DisplayName, SNOW_WHITE, Enum.Font.GothamBlack, 12, 20)
	nameLabel.Position = UDim2.new(0, 14, 0, 9)
	nameLabel.Size = UDim2.new(1, -28, 0.30, 0)
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left

	local stateLabel = createLabel(button, "OwnershipState", "", COIN_GOLD, Enum.Font.GothamBold, 10, 16)
	stateLabel.Position = UDim2.new(0, 14, 0.38, 0)
	stateLabel.Size = UDim2.new(1, -28, 0.24, 0)
	stateLabel.TextXAlignment = Enum.TextXAlignment.Left

	local detailLabel = createLabel(button, "Handling", "CLASSIC HANDLING", SECONDARY_ICE, Enum.Font.GothamMedium, 9, 14)
	detailLabel.Position = UDim2.new(0, 14, 0.69, 0)
	detailLabel.Size = UDim2.new(1, -28, 0.19, 0)
	detailLabel.TextXAlignment = Enum.TextXAlignment.Left

	return {
		Button = button,
		BrowseStroke = stroke,
		NameLabel = nameLabel,
		StateLabel = stateLabel,
		DetailLabel = detailLabel,
	}
end

local function createIconPiece(
	parent: GuiObject,
	name: string,
	position: UDim2,
	size: UDim2,
	color: Color3,
	radius: number
): Frame
	local piece = Instance.new("Frame")
	piece.Name = name
	piece.Position = position
	piece.Size = size
	piece.BackgroundColor3 = color
	piece.BorderSizePixel = 0
	piece.Active = false
	piece.Selectable = false
	piece.Parent = parent
	addCorner(piece, radius)
	return piece
end

local function createLauncherSledIcon(parent: GuiObject): Frame
	local icon = Instance.new("Frame")
	icon.Name = "EquippedSledIcon"
	icon.Size = UDim2.fromOffset(20, 16)
	icon.BackgroundTransparency = 1
	icon.BorderSizePixel = 0
	icon.Active = false
	icon.Selectable = false
	icon.Parent = parent

	createIconPiece(icon, "SledBody", UDim2.fromOffset(2, 3), UDim2.fromOffset(13, 5), SNOW_WHITE, 2)
	createIconPiece(icon, "RearSupport", UDim2.fromOffset(4, 8), UDim2.fromOffset(2, 4), SECONDARY_ICE, 1)
	createIconPiece(icon, "FrontSupport", UDim2.fromOffset(12, 8), UDim2.fromOffset(2, 4), SECONDARY_ICE, 1)
	createIconPiece(icon, "Runner", UDim2.fromOffset(1, 12), UDim2.fromOffset(17, 2), Color3.fromRGB(116, 225, 250), 1)
	createIconPiece(icon, "FrontCurl", UDim2.fromOffset(16, 7), UDim2.fromOffset(3, 6), Color3.fromRGB(116, 225, 250), 2)
	return icon
end

local function createLauncherCoinIcon(parent: GuiObject): Frame
	local coin = Instance.new("Frame")
	coin.Name = "FrostCoinIcon"
	coin.Size = UDim2.fromOffset(16, 16)
	coin.BackgroundColor3 = SNOW_WHITE
	coin.BorderSizePixel = 0
	coin.Active = false
	coin.Selectable = false
	coin.Parent = parent

	local coinCorner = Instance.new("UICorner")
	coinCorner.Name = "RoundedCorner"
	coinCorner.CornerRadius = UDim.new(1, 0)
	coinCorner.Parent = coin

	local coinGradient = Instance.new("UIGradient")
	coinGradient.Name = "IcyCoinGradient"
	coinGradient.Color = ColorSequence.new(SNOW_WHITE, Color3.fromRGB(116, 225, 250))
	coinGradient.Rotation = 90
	coinGradient.Parent = coin

	local coinStroke = Instance.new("UIStroke")
	coinStroke.Name = "IceStroke"
	coinStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	coinStroke.Color = Color3.fromRGB(109, 218, 240)
	coinStroke.Thickness = 1
	coinStroke.Transparency = 0.05
	coinStroke.Parent = coin

	for index, rotation in { 0, 45, 90, 135 } do
		local ray = createIconPiece(
			coin,
			string.format("FrostRay%02d", index),
			UDim2.fromScale(0.5, 0.5),
			UDim2.fromOffset(1, 8),
			Color3.fromRGB(45, 175, 208),
			1
		)
		ray.AnchorPoint = Vector2.new(0.5, 0.5)
		ray.Rotation = rotation
	end
	return coin
end

local function getCatalogEntry(sledId: string): CatalogEntry?
	if sledId == CLASSIC_SLED_ID then
		return GameConfig.Store.Catalog.FrostlineClassic
	elseif sledId == RUNNER_SLED_ID then
		return GameConfig.Store.Catalog.FrostRunner
	end
	return nil
end

local function validateCatalog()
	local classic = getCatalogEntry(CLASSIC_SLED_ID)
	local runner = getCatalogEntry(RUNNER_SLED_ID)
	if not classic
		or classic.SledId ~= CLASSIC_SLED_ID
		or classic.Price ~= 0
		or classic.ForSale
		or not runner
		or runner.SledId ~= RUNNER_SLED_ID
		or runner.Price ~= 250
		or not runner.ForSale
	then
		error("Frostline Store catalog is invalid")
	end
end

local function createStoreUi(playerGui: PlayerGui): StoreUi
	local previous = playerGui:FindFirstChild(STORE_GUI_NAME)
	if previous then
		previous:Destroy()
	end

	local classicEntry = getCatalogEntry(CLASSIC_SLED_ID) :: CatalogEntry
	local runnerEntry = getCatalogEntry(RUNNER_SLED_ID) :: CatalogEntry

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = STORE_GUI_NAME
	screenGui.ResetOnSpawn = false
	-- Match GetInsetArea's CoreUISafeInsets-relative coordinate space so the
	-- launcher and modal remain below the top bar and inside device-safe bounds.
	screenGui.IgnoreGuiInset = false
	screenGui.DisplayOrder = 20
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	local launcherRoot = Instance.new("Frame")
	launcherRoot.Name = "StoreLauncherRoot"
	launcherRoot.AnchorPoint = Vector2.new(1, 0)
	launcherRoot.Size = UDim2.fromOffset(164, 82)
	launcherRoot.BackgroundTransparency = 1
	launcherRoot.BorderSizePixel = 0
	launcherRoot.Active = false
	launcherRoot.Selectable = false
	launcherRoot.ClipsDescendants = false
	launcherRoot.Visible = false
	launcherRoot.ZIndex = 1
	launcherRoot.Parent = screenGui
	local launcherScale = Instance.new("UIScale")
	launcherScale.Name = "ResponsiveScale"
	launcherScale.Scale = 1
	launcherScale.Parent = launcherRoot

	local launcher = Instance.new("TextButton")
	launcher.Name = "StoreLauncher"
	launcher.Position = UDim2.fromOffset(0, 0)
	launcher.Size = UDim2.fromScale(1, 1)
	launcher.BackgroundColor3 = Color3.fromRGB(7, 14, 24)
	launcher.BackgroundTransparency = 0.04
	launcher.BorderSizePixel = 0
	launcher.AutoButtonColor = true
	launcher.Text = ""
	launcher.Active = false
	launcher.Selectable = false
	launcher.SelectionOrder = 1
	launcher.ZIndex = 1
	launcher.Parent = launcherRoot
	addCorner(launcher, 16)

	local launcherStroke = Instance.new("UIStroke")
	launcherStroke.Color = Color3.fromRGB(116, 225, 250)
	launcherStroke.Thickness = 2
	launcherStroke.Transparency = 0.12
	launcherStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	launcherStroke.Parent = launcher

	local launcherSnowCap = Instance.new("CanvasGroup")
	launcherSnowCap.Name = "SnowCapOverlay"
	launcherSnowCap.Position = UDim2.fromOffset(0, 0)
	launcherSnowCap.Size = UDim2.fromScale(1, 1)
	launcherSnowCap.BackgroundTransparency = 1
	launcherSnowCap.BorderSizePixel = 0
	launcherSnowCap.Active = false
	launcherSnowCap.Selectable = false
	launcherSnowCap.ClipsDescendants = true
	launcherSnowCap.ZIndex = 2
	launcherSnowCap.Parent = launcherRoot
	addCorner(launcherSnowCap, 16)

	for index, positionX in { 11, 49, 87, 125 } do
		local scallop = createIconPiece(
			launcherSnowCap,
			string.format("SnowScallop%02d", index),
			UDim2.fromOffset(positionX, 6),
			UDim2.fromOffset(28, 10),
			SNOW_WHITE,
			5
		)
		scallop.ZIndex = 2
	end
	local launcherSnowStrip = Instance.new("Frame")
	launcherSnowStrip.Name = "SnowStrip"
	launcherSnowStrip.Position = UDim2.fromOffset(0, 0)
	launcherSnowStrip.Size = UDim2.new(1, 0, 0, 10)
	launcherSnowStrip.BackgroundColor3 = SNOW_WHITE
	launcherSnowStrip.BorderSizePixel = 0
	launcherSnowStrip.Active = false
	launcherSnowStrip.Selectable = false
	launcherSnowStrip.ZIndex = 3
	launcherSnowStrip.Parent = launcherSnowCap
	addCorner(launcherSnowStrip, 5)

	local launcherTitle = createLabel(launcherRoot, "Title", "SLEDS", SNOW_WHITE, Enum.Font.GothamBlack, 13, 19)
	launcherTitle.Position = UDim2.new(0, 10, 0, 20)
	launcherTitle.Size = UDim2.new(1, -20, 0, 20)
	launcherTitle.Active = false
	launcherTitle.Selectable = false
	launcherTitle.ZIndex = 4

	local sledIcon = createLauncherSledIcon(launcherRoot)
	sledIcon.Position = UDim2.fromOffset(10, 42)
	sledIcon.ZIndex = 4

	local launcherEquipped = createLabel(
		launcherRoot,
		"EquippedSled",
		"EQUIPPED: —",
		Color3.fromRGB(116, 225, 250),
		Enum.Font.GothamBold,
		8,
		12
	)
	launcherEquipped.Position = UDim2.new(0, 34, 0, 40)
	launcherEquipped.Size = UDim2.new(1, -42, 0, 19)
	launcherEquipped.TextXAlignment = Enum.TextXAlignment.Left
	launcherEquipped.Active = false
	launcherEquipped.Selectable = false
	launcherEquipped.ZIndex = 4

	local coinIcon = createLauncherCoinIcon(launcherRoot)
	coinIcon.Position = UDim2.fromOffset(12, 65)
	coinIcon.ZIndex = 4

	local launcherBalance = createLabel(launcherRoot, "Balance", "— FROST COINS", COIN_GOLD, Enum.Font.GothamBold, 8, 12)
	launcherBalance.Position = UDim2.new(0, 34, 0, 63)
	launcherBalance.Size = UDim2.new(1, -42, 0, 19)
	launcherBalance.TextXAlignment = Enum.TextXAlignment.Left
	launcherBalance.Active = false
	launcherBalance.Selectable = false
	launcherBalance.ZIndex = 4
	addCorner(launcherBalance, 10)

	local backdrop = Instance.new("TextButton")
	backdrop.Name = "ModalBackdrop"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(2, 10, 21)
	backdrop.BackgroundTransparency = 0.22
	backdrop.BorderSizePixel = 0
	backdrop.AutoButtonColor = false
	backdrop.Text = ""
	backdrop.Active = false
	backdrop.Modal = false
	backdrop.Selectable = false
	backdrop.Visible = false
	backdrop.ZIndex = 5
	backdrop.Parent = screenGui

	local panel = Instance.new("Frame")
	panel.Name = "ChristmasStorePanel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Size = UDim2.fromOffset(760, 500)
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = false
	panel.ZIndex = 6
	panel.Parent = backdrop

	local panelSurface = Instance.new("Frame")
	panelSurface.Name = "PanelSurface"
	panelSurface.Position = UDim2.fromOffset(0, 0)
	panelSurface.Size = UDim2.fromScale(1, 1)
	panelSurface.BackgroundColor3 = DARK_NAVY
	panelSurface.BorderSizePixel = 0
	panelSurface.Active = false
	panelSurface.Selectable = false
	panelSurface.ClipsDescendants = false
	panelSurface.ZIndex = 6
	panelSurface.Parent = panel
	addCorner(panelSurface, 21)

	local panelGradient = Instance.new("UIGradient")
	panelGradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, WINTER_BLUE),
		ColorSequenceKeypoint.new(0.62, DARK_NAVY),
		ColorSequenceKeypoint.new(1, DEEP_NAVY),
	})
	panelGradient.Rotation = 102
	panelGradient.Parent = panelSurface

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Name = "FrostStroke"
	panelStroke.Color = ICE_CYAN
	panelStroke.Thickness = 3
	panelStroke.Transparency = 0.08
	panelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	panelStroke.Parent = panelSurface

	local snowCap = Instance.new("CanvasGroup")
	snowCap.Name = "SnowCapOverlay"
	snowCap.Position = UDim2.fromOffset(0, 0)
	snowCap.Size = UDim2.fromScale(1, 1)
	snowCap.BackgroundTransparency = 1
	snowCap.BorderSizePixel = 0
	snowCap.Active = false
	snowCap.Selectable = false
	snowCap.ClipsDescendants = true
	snowCap.ZIndex = 7
	snowCap.Parent = panel
	addCorner(snowCap, 21)
	for index = 1, 4 do
		local positionX = 0.08 + (index - 1) * 0.2433333333
		local drift = Instance.new("Frame")
		drift.Name = string.format("SnowScallop%02d", index)
		drift.AnchorPoint = Vector2.zero
		drift.Position = UDim2.new(positionX, 0, 0, 14)
		drift.Size = UDim2.new(0.11, 0, 0, 15)
		drift.BackgroundColor3 = SNOW_WHITE
		drift.BorderSizePixel = 0
		drift.Active = false
		drift.Selectable = false
		drift.ZIndex = 7
		drift.Parent = snowCap
		addCorner(drift, 8)
	end

	local snowStrip = Instance.new("Frame")
	snowStrip.Name = "SnowStrip"
	snowStrip.Position = UDim2.fromOffset(0, 0)
	snowStrip.Size = UDim2.new(1, 0, 0, 20)
	snowStrip.BackgroundColor3 = SNOW_WHITE
	snowStrip.BorderSizePixel = 0
	snowStrip.Active = false
	snowStrip.Selectable = false
	snowStrip.ZIndex = 8
	snowStrip.Parent = snowCap
	addCorner(snowStrip, 9)

	local titleLabel = createLabel(panel, "Title", "SLED STORE", SNOW_WHITE, Enum.Font.GothamBlack, 20, 32)
	titleLabel.Position = UDim2.fromOffset(24, 22)
	titleLabel.Size = UDim2.new(0.52, 0, 0, 40)
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.ZIndex = 9

	local balanceLabel = createLabel(panel, "FrostCoinBalance", "LOADING PROGRESS...", COIN_GOLD, Enum.Font.GothamBold, 11, 18)
	balanceLabel.AnchorPoint = Vector2.new(1, 0)
	balanceLabel.Position = UDim2.new(1, -77, 0, 25)
	balanceLabel.Size = UDim2.new(0.35, 0, 0, 34)
	balanceLabel.TextXAlignment = Enum.TextXAlignment.Right
	balanceLabel.ZIndex = 9
	addCorner(balanceLabel, 11)

	local closeButton = createButton(panel, "Close", "X", CHRISTMAS_RED)
	closeButton.AnchorPoint = Vector2.new(1, 0)
	closeButton.Position = UDim2.new(1, -18, 0, 18)
	closeButton.Size = UDim2.fromOffset(48, 48)
	closeButton.SelectionOrder = 2
	closeButton.ZIndex = 10
	addTextConstraint(closeButton, 16, 24)

	local sectionLabel = createLabel(
		panel,
		"CombinedStoreInventory",
		"STORE  •  OWNED INVENTORY",
		ICE_CYAN,
		Enum.Font.GothamBold,
		10,
		15
	)
	sectionLabel.TextXAlignment = Enum.TextXAlignment.Left
	sectionLabel.ZIndex = 7
	addCorner(sectionLabel, 11)

	local cardsArea = Instance.new("Frame")
	cardsArea.Name = "SledCards"
	cardsArea.BackgroundTransparency = 1
	cardsArea.BorderSizePixel = 0
	cardsArea.ZIndex = 7
	cardsArea.Parent = panel

	local cardsLayout = Instance.new("UIListLayout")
	cardsLayout.FillDirection = Enum.FillDirection.Horizontal
	cardsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	cardsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	cardsLayout.Padding = UDim.new(0, 10)
	cardsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	cardsLayout.Parent = cardsArea

	local classicCard = createCard(cardsArea, "FrostlineClassicCard", classicEntry)
	classicCard.Button.LayoutOrder = 1
	classicCard.Button.SelectionOrder = 3
	local runnerCard = createCard(cardsArea, "FrostRunnerCard", runnerEntry)
	runnerCard.Button.LayoutOrder = 2
	runnerCard.Button.SelectionOrder = 4

	local detailsFrame = Instance.new("Frame")
	detailsFrame.Name = "SelectedSledDetails"
	detailsFrame.BackgroundColor3 = Color3.fromRGB(8, 37, 64)
	detailsFrame.BackgroundTransparency = 0.06
	detailsFrame.BorderSizePixel = 0
	detailsFrame.ZIndex = 7
	detailsFrame.Parent = panel
	addCorner(detailsFrame, 12)

	local detailsStroke = Instance.new("UIStroke")
	detailsStroke.Color = ICE_CYAN
	detailsStroke.Thickness = 1.3
	detailsStroke.Transparency = 0.55
	detailsStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	detailsStroke.Parent = detailsFrame

	local selectedNameLabel = createLabel(detailsFrame, "SelectedName", "", SNOW_WHITE, Enum.Font.GothamBlack, 12, 20)
	selectedNameLabel.Position = UDim2.new(0, 14, 0, 7)
	selectedNameLabel.Size = UDim2.new(1, -28, 0.31, 0)
	selectedNameLabel.TextXAlignment = Enum.TextXAlignment.Left
	selectedNameLabel.ZIndex = 8

	local selectedDescriptionLabel = createLabel(
		detailsFrame,
		"SelectedDescription",
		"",
		SECONDARY_ICE,
		Enum.Font.GothamMedium,
		9,
		15
	)
	selectedDescriptionLabel.Position = UDim2.new(0, 14, 0.38, 0)
	selectedDescriptionLabel.Size = UDim2.new(1, -28, 0.52, 0)
	selectedDescriptionLabel.TextXAlignment = Enum.TextXAlignment.Left
	selectedDescriptionLabel.TextYAlignment = Enum.TextYAlignment.Top
	selectedDescriptionLabel.ZIndex = 8

	local statusLabel = createLabel(panel, "StoreStatus", "", SECONDARY_ICE, Enum.Font.GothamBold, 10, 15)
	statusLabel.ZIndex = 7
	addCorner(statusLabel, 11)

	local actionArea = Instance.new("Frame")
	actionArea.Name = "FixedActionArea"
	actionArea.BackgroundTransparency = 1
	actionArea.BorderSizePixel = 0
	actionArea.ZIndex = 7
	actionArea.Parent = panel
	addCorner(actionArea, 12)

	local primaryButton = createButton(actionArea, "PrimaryAction", "", PINE_GREEN)
	primaryButton.Size = UDim2.fromScale(1, 1)
	primaryButton.SelectionOrder = 5
	primaryButton.ZIndex = 8

	local confirmationFrame = Instance.new("Frame")
	confirmationFrame.Name = "PurchaseConfirmation"
	confirmationFrame.Size = UDim2.fromScale(1, 1)
	confirmationFrame.BackgroundColor3 = Color3.fromRGB(8, 37, 64)
	confirmationFrame.BackgroundTransparency = 0.03
	confirmationFrame.BorderSizePixel = 0
	confirmationFrame.Visible = false
	confirmationFrame.ZIndex = 8
	confirmationFrame.Parent = actionArea
	addCorner(confirmationFrame, 11)

	local confirmationLabel = createLabel(
		confirmationFrame,
		"ConfirmationDetails",
		"",
		SNOW_WHITE,
		Enum.Font.GothamBold,
		9,
		14
	)
	confirmationLabel.Position = UDim2.new(0, 10, 0, 5)
	confirmationLabel.Size = UDim2.new(0.48, -10, 1, -10)
	confirmationLabel.TextXAlignment = Enum.TextXAlignment.Left
	confirmationLabel.ZIndex = 9

	local confirmButton = createButton(confirmationFrame, "ConfirmPurchase", "CONFIRM 250", PINE_GREEN)
	confirmButton.Position = UDim2.new(0.49, 0, 0, 4)
	confirmButton.Size = UDim2.new(0.25, -4, 1, -8)
	confirmButton.SelectionOrder = 6
	confirmButton.ZIndex = 9

	local cancelButton = createButton(confirmationFrame, "CancelPurchase", "CANCEL", CHRISTMAS_RED)
	cancelButton.Position = UDim2.new(0.75, 4, 0, 4)
	cancelButton.Size = UDim2.new(0.25, -8, 1, -8)
	cancelButton.SelectionOrder = 7
	cancelButton.ZIndex = 9

	local focusStrokes: { [GuiButton]: UIStroke } = {}
	local selectionImages: { Frame } = {}
	addRoundedFocusStyle(launcher, 16, focusStrokes, selectionImages)
	addRoundedFocusStyle(closeButton, 11, focusStrokes, selectionImages)
	addRoundedFocusStyle(classicCard.Button, 13, focusStrokes, selectionImages)
	addRoundedFocusStyle(runnerCard.Button, 13, focusStrokes, selectionImages)
	addRoundedFocusStyle(primaryButton, 11, focusStrokes, selectionImages)
	addRoundedFocusStyle(confirmButton, 11, focusStrokes, selectionImages)
	addRoundedFocusStyle(cancelButton, 11, focusStrokes, selectionImages)
	local modalButtons: { TextButton } = {
		closeButton,
		classicCard.Button,
		runnerCard.Button,
		primaryButton,
		confirmButton,
		cancelButton,
	}

	return {
		ScreenGui = screenGui,
		LauncherRoot = launcherRoot,
		LauncherScale = launcherScale,
		Launcher = launcher,
		LauncherEquipped = launcherEquipped,
		LauncherBalance = launcherBalance,
		Backdrop = backdrop,
		Panel = panel,
		SnowCap = snowCap,
		TitleLabel = titleLabel,
		BalanceLabel = balanceLabel,
		CloseButton = closeButton,
		SectionLabel = sectionLabel,
		CardsArea = cardsArea,
		CardsLayout = cardsLayout,
		ClassicCard = classicCard,
		RunnerCard = runnerCard,
		DetailsFrame = detailsFrame,
		SelectedNameLabel = selectedNameLabel,
		SelectedDescriptionLabel = selectedDescriptionLabel,
		StatusLabel = statusLabel,
		ActionArea = actionArea,
		PrimaryButton = primaryButton,
		ConfirmationFrame = confirmationFrame,
		ConfirmationLabel = confirmationLabel,
		ConfirmButton = confirmButton,
		CancelButton = cancelButton,
		ModalButtons = modalButtons,
		FocusStrokes = focusStrokes,
		SelectionImages = selectionImages,
	}
end

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isSafeNonnegativeInteger(value: any): boolean
	return typeof(value) == "number"
		and isFiniteNumber(value)
		and value >= 0
		and value % 1 == 0
		and value <= 9007199254740991
end

local function isValidRunId(value: any): boolean
	return isSafeNonnegativeInteger(value) and value > 0
end

local function isGuid(value: any): boolean
	return typeof(value) == "string"
		and #value == 36
		and string.match(
			value,
			"^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"
		) ~= nil
end

local function isKnownAction(value: any): boolean
	return value == StoreTypes.Actions.GetState
		or value == StoreTypes.Actions.Purchase
		or value == StoreTypes.Actions.Equip
end

local function isKnownStatus(value: any): boolean
	local codes = StoreTypes.StatusCodes
	return value == codes.State
		or value == codes.InvalidRequest
		or value == codes.UnsupportedVersion
		or value == codes.RequestIdConflict
		or value == codes.RequestInProgress
		or value == codes.RateLimited
		or value == codes.ProfileLoading
		or value == codes.PersistenceUnavailable
		or value == codes.StoreUnavailable
		or value == codes.UnknownSled
		or value == codes.NotForSale
		or value == codes.StateChanged
		or value == codes.InsufficientFunds
		or value == codes.NotOwned
		or value == codes.Busy
		or value == codes.SavePending
		or value == codes.InternalError
		or value == codes.AlreadyOwned
		or value == codes.AlreadyEquipped
		or value == codes.Success
end

local function isKnownPersistenceState(value: any): boolean
	local states = StoreTypes.PersistenceStates
	return value == states.Persistent
		or value == states.Loading
		or value == states.SessionOnly
		or value == states.Releasing
		or value == states.SavePending
end

local function parseStoreState(value: any): StoreState?
	if typeof(value) ~= "table"
		or value.ProtocolVersion ~= StoreTypes.ProtocolVersion
		or value.CatalogVersion ~= GameConfig.Store.CatalogVersion
		or not isSafeNonnegativeInteger(value.ServerSequence)
		or not isSafeNonnegativeInteger(value.DataRevision)
		or not isGuid(value.ResponseToRequestId)
		or not isKnownAction(value.ResponseAction)
		or typeof(value.Ok) ~= "boolean"
		or not isKnownStatus(value.StatusCode)
		or typeof(value.CanBrowse) ~= "boolean"
		or typeof(value.CanTransact) ~= "boolean"
		or not isKnownPersistenceState(value.PersistenceState)
		or not isSafeNonnegativeInteger(value.FrostCoins)
		or typeof(value.OwnedSleds) ~= "table"
		or value.OwnedSleds[CLASSIC_SLED_ID] ~= true
	then
		return nil
	end

	local responseAction = value.ResponseAction :: StoreAction
	local responseSledId = value.ResponseSledId
	if responseAction == StoreTypes.Actions.GetState then
		if responseSledId ~= nil then
			return nil
		end
	elseif typeof(responseSledId) ~= "string" or not getCatalogEntry(responseSledId) then
		return nil
	end

	local runnerOwnership = value.OwnedSleds[RUNNER_SLED_ID]
	if runnerOwnership ~= nil and runnerOwnership ~= true then
		return nil
	end
	local ownedSleds: { [string]: boolean } = {
		[CLASSIC_SLED_ID] = true,
	}
	if runnerOwnership == true then
		ownedSleds[RUNNER_SLED_ID] = true
	end

	local equippedSledId = value.EquippedSledId
	if typeof(equippedSledId) ~= "string"
		or not getCatalogEntry(equippedSledId)
		or ownedSleds[equippedSledId] ~= true
	then
		return nil
	end

	local parsed: StoreState = {
		ProtocolVersion = value.ProtocolVersion,
		CatalogVersion = value.CatalogVersion,
		ServerSequence = value.ServerSequence,
		DataRevision = value.DataRevision,
		ResponseToRequestId = value.ResponseToRequestId,
		ResponseAction = responseAction,
		ResponseSledId = responseSledId,
		Ok = value.Ok,
		StatusCode = value.StatusCode,
		CanBrowse = value.CanBrowse,
		CanTransact = value.CanTransact,
		PersistenceState = value.PersistenceState,
		FrostCoins = value.FrostCoins,
		OwnedSleds = table.freeze(ownedSleds),
		EquippedSledId = equippedSledId,
	}
	return table.freeze(parsed)
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

local function warnOnce(message: string)
	if warningIssued then
		return
	end
	warningIssued = true
	warn(string.format("[Frostline] Store unavailable: %s", message))
end

local function disconnectConnections(connections: { RBXScriptConnection })
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

local function setButtonEnabled(button: TextButton, enabled: boolean)
	button.Active = enabled
	button.Selectable = enabled
	button.AutoButtonColor = enabled
	button.BackgroundTransparency = if enabled then 0 else 0.34
end

local function getSafeBounds(): (Vector2, Vector2)
	local succeeded, insetArea = pcall(function()
		return GuiService:GetInsetArea(Enum.ScreenInsets.CoreUISafeInsets)
	end)
	if succeeded and typeof(insetArea) == "Rect" and insetArea.Max.X > insetArea.Min.X and insetArea.Max.Y > insetArea.Min.Y then
		return insetArea.Min, insetArea.Max
	end
	local camera = Workspace.CurrentCamera
	if camera then
		return Vector2.zero, camera.ViewportSize
	end
	return Vector2.zero, Vector2.new(1280, 720)
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

	local camera = Workspace.CurrentCamera
	local viewportSize = if camera then camera.ViewportSize else safeSize
	currentUi.LauncherScale.Scale = if viewportSize.Y > viewportSize.X then 0.70 else 1
	currentUi.LauncherRoot.Position = UDim2.fromOffset(safeMaximum.X - 18, safeMinimum.Y + 18)
	local panelWidth = math.min(760, safeSize.X * 0.94)
	local panelHeight = math.min(500, safeSize.Y * 0.94)
	currentUi.Panel.Position = UDim2.fromOffset(
		safeMinimum.X + safeSize.X * 0.5,
		safeMinimum.Y + safeSize.Y * 0.5
	)
	currentUi.Panel.Size = UDim2.fromOffset(panelWidth, panelHeight)

	local stacked = panelWidth < 560
	local compact = panelHeight < 430
	local sidePadding = if compact then 14 else 22
	local headerTop = if compact then 37 else 35
	local headerHeight = if compact then 34 else 45
	currentUi.TitleLabel.Position = UDim2.fromOffset(sidePadding, headerTop)
	currentUi.TitleLabel.Size = UDim2.new(0.48, 0, 0, headerHeight)
	currentUi.BalanceLabel.Position = UDim2.new(1, -(sidePadding + 54), 0, headerTop + 2)
	currentUi.BalanceLabel.Size = UDim2.new(0.38, 0, 0, headerHeight - 3)
	currentUi.CloseButton.Position = UDim2.new(1, -sidePadding, 0, math.max(12, headerTop - 2))
	currentUi.CloseButton.Size = UDim2.fromOffset(48, 48)

	local sectionY = headerTop + headerHeight + (if compact then 1 else 5)
	currentUi.SectionLabel.Position = UDim2.fromOffset(sidePadding, sectionY)
	currentUi.SectionLabel.Size = UDim2.new(1, -sidePadding * 2, 0, 20)

	local actionHeight = if compact then 56 else 62
	local actionBottom = if compact then 12 else 19
	currentUi.ActionArea.Position = UDim2.new(0, sidePadding, 1, -(actionBottom + actionHeight))
	currentUi.ActionArea.Size = UDim2.new(1, -sidePadding * 2, 0, actionHeight)
	local statusHeight = if compact then 28 else 32
	local statusBottom = actionBottom + actionHeight + 5
	currentUi.StatusLabel.Position = UDim2.new(0, sidePadding, 1, -(statusBottom + statusHeight))
	currentUi.StatusLabel.Size = UDim2.new(1, -sidePadding * 2, 0, statusHeight)

	local cardsY = sectionY + 22
	local availableContentBottom = panelHeight - statusBottom - statusHeight - 7
	local detailsHeight = if compact then 48 else 86
	local detailsY: number
	if stacked then
		local cardsHeight = math.max(120, math.min(194, (availableContentBottom - cardsY) * 0.61))
		currentUi.CardsArea.Position = UDim2.fromOffset(sidePadding, cardsY)
		currentUi.CardsArea.Size = UDim2.new(1, -sidePadding * 2, 0, cardsHeight)
		currentUi.CardsLayout.FillDirection = Enum.FillDirection.Vertical
		currentUi.CardsLayout.Padding = UDim.new(0, 8)
		currentUi.ClassicCard.Button.Size = UDim2.new(1, 0, 0.5, -4)
		currentUi.RunnerCard.Button.Size = UDim2.new(1, 0, 0.5, -4)
		detailsY = cardsY + cardsHeight + 7
		detailsHeight = math.max(54, availableContentBottom - detailsY)
	else
		local cardsHeight = if compact
			then math.max(58, math.min(72, (availableContentBottom - cardsY) * 0.56))
			else 132
		currentUi.CardsArea.Position = UDim2.fromOffset(sidePadding, cardsY)
		currentUi.CardsArea.Size = UDim2.new(1, -sidePadding * 2, 0, cardsHeight)
		currentUi.CardsLayout.FillDirection = Enum.FillDirection.Horizontal
		currentUi.CardsLayout.Padding = UDim.new(0, 10)
		currentUi.ClassicCard.Button.Size = UDim2.new(0.5, -5, 1, 0)
		currentUi.RunnerCard.Button.Size = UDim2.new(0.5, -5, 1, 0)
		detailsY = cardsY + cardsHeight + (if compact then 6 else 8)
		detailsHeight = math.max(if compact then 40 else 52, math.min(detailsHeight, availableContentBottom - detailsY))
	end
	currentUi.DetailsFrame.Position = UDim2.fromOffset(sidePadding, detailsY)
	currentUi.DetailsFrame.Size = UDim2.new(1, -sidePadding * 2, 0, detailsHeight)
end

local function cardForSledId(currentUi: StoreUi, sledId: string): CardUi
	return if sledId == RUNNER_SLED_ID then currentUi.RunnerCard else currentUi.ClassicCard
end

local function hasCurrentStateForLifecycle(): boolean
	return currentState ~= nil
		and currentStateGeneration == lifecycleGeneration
		and currentPhase == RunPhase.Idle
end

local function launcherShouldBeVisible(): boolean
	local state = currentState
	return not destroyed
		and not modalOpen
		and hasCurrentStateForLifecycle()
		and not freshnessRequired
		and state ~= nil
		and state.CanBrowse
end

local function isEffectivelyVisible(guiObject: GuiObject, root: Instance): boolean
	local current: Instance? = guiObject
	while current and current ~= root do
		if current:IsA("GuiObject") and not current.Visible then
			return false
		end
		current = current.Parent
	end
	return current == root
end

local function preferredModalSelection(currentUi: StoreUi): GuiButton
	local selectedCard = cardForSledId(currentUi, selectedSledId).Button
	if selectedCard.Active and selectedCard.Selectable and isEffectivelyVisible(selectedCard, currentUi.Backdrop) then
		return selectedCard
	end
	return currentUi.CloseButton
end

local function disableFocusVisuals(currentUi: StoreUi)
	for _, stroke in currentUi.FocusStrokes do
		stroke.Enabled = false
	end
end

local function updateFocusVisuals(currentUi: StoreUi)
	local selected = GuiService.SelectedObject
	for button, stroke in currentUi.FocusStrokes do
		stroke.Enabled = selected == button
			and button.Parent ~= nil
			and button.Active
			and button.Selectable
			and currentUi.ScreenGui.Enabled
			and isEffectivelyVisible(button, currentUi.ScreenGui)
	end
end

local function setModalControlsHidden(currentUi: StoreUi)
	for _, button in currentUi.ModalButtons do
		button.Active = false
		button.Selectable = false
	end
	currentUi.Backdrop.Active = false
	currentUi.Backdrop.Modal = false
	currentUi.Backdrop.Selectable = false
	disableFocusVisuals(currentUi)
end

local function setModalControlsOpenBase(currentUi: StoreUi)
	currentUi.Backdrop.Active = true
	currentUi.Backdrop.Modal = true
	currentUi.Backdrop.Selectable = false
	currentUi.CloseButton.Active = true
	currentUi.CloseButton.Selectable = true
	currentUi.ClassicCard.Button.Active = true
	currentUi.ClassicCard.Button.Selectable = true
	currentUi.RunnerCard.Button.Active = true
	currentUi.RunnerCard.Button.Selectable = true
end

local function isCurrentModalFocusTarget(
	currentUi: StoreUi,
	target: GuiButton,
	focusGeneration: number
): boolean
	return not destroyed
		and modalOpen
		and storeOwnsFocus
		and activeModalFocusGeneration == focusGeneration
		and ui == currentUi
		and currentUi.ScreenGui.Parent ~= nil
		and currentUi.ScreenGui.Enabled
		and currentPhase == RunPhase.Idle
		and hasCurrentStateForLifecycle()
		and currentUi.Backdrop.Visible
		and currentUi.Backdrop.Active
		and currentUi.Backdrop.Modal
		and target.Parent ~= nil
		and target:IsDescendantOf(currentUi.Backdrop)
		and target.Visible
		and target.Active
		and target.Selectable
		and isEffectivelyVisible(target, currentUi.Backdrop)
end

local function claimModalFocus(currentUi: StoreUi, target: GuiButton, focusGeneration: number): boolean
	if not isCurrentModalFocusTarget(currentUi, target, focusGeneration) then
		return false
	end
	local succeeded = pcall(function()
		GuiService.SelectedObject = target
	end)
	if succeeded then
		updateFocusVisuals(currentUi)
	end
	return succeeded
end

local function updateNavigation(currentUi: StoreUi)
	local classic = currentUi.ClassicCard.Button
	local runner = currentUi.RunnerCard.Button
	local close = currentUi.CloseButton
	local primary = currentUi.PrimaryButton
	local confirm = currentUi.ConfirmButton
	local cancel = currentUi.CancelButton

	local stacked = currentUi.CardsLayout.FillDirection == Enum.FillDirection.Vertical
	close.NextSelectionDown = classic
	close.NextSelectionLeft = if stacked then classic else runner
	close.NextSelectionRight = classic
	classic.NextSelectionUp = close
	classic.NextSelectionLeft = runner
	classic.NextSelectionRight = runner
	runner.NextSelectionLeft = classic
	runner.NextSelectionRight = classic
	if stacked then
		classic.NextSelectionDown = runner
		runner.NextSelectionUp = classic
	else
		runner.NextSelectionUp = close
	end

	if currentUi.ConfirmationFrame.Visible then
		if not stacked then
			classic.NextSelectionDown = confirm
		end
		runner.NextSelectionDown = cancel
		confirm.NextSelectionUp = if stacked then runner else classic
		cancel.NextSelectionUp = runner
		confirm.NextSelectionRight = cancel
		cancel.NextSelectionLeft = confirm
		confirm.NextSelectionDown = close
		cancel.NextSelectionDown = close
	else
		if not stacked then
			classic.NextSelectionDown = primary
		end
		runner.NextSelectionDown = primary
		primary.NextSelectionUp = if stacked
			then runner
			else cardForSledId(currentUi, selectedSledId).Button
		primary.NextSelectionDown = close
	end
end

local function statusPresentation(code: StoreStatusCode, action: StoreAction): (string, Color3)
	local codes = StoreTypes.StatusCodes
	if code == codes.State then
		return "", SECONDARY_ICE
	elseif code == codes.Success then
		return if action == StoreTypes.Actions.Purchase then "PURCHASE SAVED" else "EQUIPPED FOR NEXT RUN", PINE_GREEN
	elseif code == codes.AlreadyOwned then
		return "ALREADY OWNED — NO COINS CHARGED", SECONDARY_ICE
	elseif code == codes.AlreadyEquipped then
		return "ALREADY EQUIPPED", SECONDARY_ICE
	elseif code == codes.InsufficientFunds then
		return "NOT ENOUGH FROST COINS", WARNING_AMBER
	elseif code == codes.NotOwned then
		return "SLED NOT OWNED", WARNING_AMBER
	elseif code == codes.StateChanged then
		return "STORE UPDATED — REVIEW THE LATEST STATE", WARNING_AMBER
	elseif code == codes.SavePending then
		return "SAVING... PURCHASES AND RUNS ARE TEMPORARILY LOCKED", WARNING_AMBER
	elseif code == codes.ProfileLoading then
		return "LOADING PROGRESS...", SECONDARY_ICE
	elseif code == codes.PersistenceUnavailable then
		return "STORE UNAVAILABLE — PROGRESS WILL NOT SAVE", CHRISTMAS_RED
	elseif code == codes.StoreUnavailable or code == codes.Busy then
		return "STORE TEMPORARILY UNAVAILABLE", WARNING_AMBER
	elseif code == codes.RateLimited or code == codes.RequestInProgress then
		return "PLEASE WAIT...", WARNING_AMBER
	elseif code == codes.UnknownSled or code == codes.NotForSale then
		return "ITEM UNAVAILABLE", CHRISTMAS_RED
	elseif code == codes.InvalidRequest or code == codes.UnsupportedVersion or code == codes.RequestIdConflict then
		return "STORE REQUEST REJECTED", CHRISTMAS_RED
	end
	return "STORE ERROR — TRY AGAIN LATER", CHRISTMAS_RED
end

renderUi = function()
	local currentUi = ui
	if not currentUi then
		return
	end
	local state = currentState
	local usableState = if hasCurrentStateForLifecycle() then state else nil

	local launcherVisible = launcherShouldBeVisible()
	if not launcherVisible and GuiService.SelectedObject == currentUi.Launcher then
		-- Release while the launcher is still visible so Roblox cannot transfer
		-- its disappearing selection to a control outside the Store.
		releaseModalOwnership("launcher-hidden")
	end
	currentUi.Launcher.Visible = launcherVisible
	currentUi.LauncherRoot.Visible = launcherVisible
	currentUi.Launcher.Selectable = launcherVisible
	currentUi.Launcher.Active = launcherVisible
	local backdropVisible = modalOpen and usableState ~= nil and usableState.CanBrowse

	local launcherEquippedText = "EQUIPPED: —"
	local launcherBalanceText = "— FROST COINS"
	if usableState then
		if usableState.EquippedSledId == CLASSIC_SLED_ID then
			launcherEquippedText = "EQUIPPED: CLASSIC"
		elseif usableState.EquippedSledId == RUNNER_SLED_ID then
			launcherEquippedText = "EQUIPPED: RUNNER"
		end
		launcherBalanceText = string.format("%d FROST COINS", usableState.FrostCoins)
		currentUi.BalanceLabel.Text = string.format("%d FROST COINS", usableState.FrostCoins)
	else
		currentUi.BalanceLabel.Text = "LOADING PROGRESS..."
	end
	currentUi.LauncherEquipped.Text = launcherEquippedText
	currentUi.LauncherBalance.Text = launcherBalanceText
	if not backdropVisible then
		if modalOpen or storeOwnsFocus or modalActionsBound then
			releaseModalOwnership("render-hidden")
		else
			setModalControlsHidden(currentUi)
			currentUi.Backdrop.Visible = false
		end
		updateFocusVisuals(currentUi)
		return
	end
	currentUi.Backdrop.Visible = true
	setModalControlsOpenBase(currentUi)

	local activeState = usableState :: StoreState
	local classicOwned = activeState.OwnedSleds[CLASSIC_SLED_ID] == true
	local runnerOwned = activeState.OwnedSleds[RUNNER_SLED_ID] == true
	currentUi.ClassicCard.StateLabel.Text = if activeState.EquippedSledId == CLASSIC_SLED_ID
		then "OWNED • EQUIPPED"
		elseif classicOwned then "OWNED • EQUIP AVAILABLE" else "UNAVAILABLE"
	currentUi.RunnerCard.StateLabel.Text = if activeState.EquippedSledId == RUNNER_SLED_ID
		then "OWNED • EQUIPPED"
		elseif runnerOwned then "OWNED • EQUIP AVAILABLE" else "250 FROST COINS"

	currentUi.ClassicCard.BrowseStroke.Thickness = if selectedSledId == CLASSIC_SLED_ID then 3 else 1.5
	currentUi.ClassicCard.BrowseStroke.Transparency = if selectedSledId == CLASSIC_SLED_ID then 0.05 else 0.5
	currentUi.RunnerCard.BrowseStroke.Thickness = if selectedSledId == RUNNER_SLED_ID then 3 else 1.5
	currentUi.RunnerCard.BrowseStroke.Transparency = if selectedSledId == RUNNER_SLED_ID then 0.05 else 0.5

	local entry = getCatalogEntry(selectedSledId) or getCatalogEntry(CLASSIC_SLED_ID) :: CatalogEntry
	currentUi.SelectedNameLabel.Text = entry.DisplayName
	currentUi.SelectedDescriptionLabel.Text = entry.Description

	local persistence = activeState.PersistenceState
	local persistent = persistence == StoreTypes.PersistenceStates.Persistent
	local sessionOnly = persistence == StoreTypes.PersistenceStates.SessionOnly
	local savePending = persistence == StoreTypes.PersistenceStates.SavePending
	local mutationPending = pendingMutation ~= nil
	local refreshPending = pendingRefreshId ~= nil or freshnessRequired
	local canTransact = activeState.CanTransact
		and persistent
		and not mutationPending
		and not refreshPending

	if sessionOnly then
		currentUi.StatusLabel.Text = "STORE UNAVAILABLE — PROGRESS WILL NOT SAVE"
		currentUi.StatusLabel.TextColor3 = CHRISTMAS_RED
	elseif savePending then
		currentUi.StatusLabel.Text = "SAVING..."
		currentUi.StatusLabel.TextColor3 = WARNING_AMBER
	elseif pendingMutation then
		currentUi.StatusLabel.Text = if pendingMutation.Action == StoreTypes.Actions.Purchase
			then "PURCHASING..."
			else "EQUIPPING..."
		currentUi.StatusLabel.TextColor3 = SECONDARY_ICE
	elseif pendingRefreshId then
		currentUi.StatusLabel.Text = "REFRESHING AUTHORITATIVE STORE STATE..."
		currentUi.StatusLabel.TextColor3 = SECONDARY_ICE
	else
		currentUi.StatusLabel.Text = statusMessage
		currentUi.StatusLabel.TextColor3 = statusColor
	end

	if confirmationRevision ~= nil
		and (selectedSledId ~= RUNNER_SLED_ID
			or runnerOwned
			or confirmationRevision ~= activeState.DataRevision
			or not canTransact)
	then
		confirmationRevision = nil
	end

	local confirmationOpen = confirmationRevision ~= nil
	currentUi.ConfirmationFrame.Visible = confirmationOpen
	currentUi.PrimaryButton.Visible = not confirmationOpen
	if confirmationOpen then
		setButtonEnabled(currentUi.PrimaryButton, false)
		local afterBalance = activeState.FrostCoins - entry.Price
		currentUi.ConfirmationLabel.Text = string.format(
			"%s\nPRICE: %d   BALANCE: %d → %d",
			entry.DisplayName,
			entry.Price,
			activeState.FrostCoins,
			math.max(0, afterBalance)
		)
		setButtonEnabled(currentUi.ConfirmButton, canTransact)
		setButtonEnabled(currentUi.CancelButton, true)
	else
		setButtonEnabled(currentUi.ConfirmButton, false)
		setButtonEnabled(currentUi.CancelButton, false)
	end
	if not confirmationOpen and pendingMutation then
		currentUi.PrimaryButton.Text = if pendingMutation.Action == StoreTypes.Actions.Purchase
			then "PURCHASING..."
			else "EQUIPPING..."
		currentUi.PrimaryButton.BackgroundColor3 = DISABLED_BLUE
		setButtonEnabled(currentUi.PrimaryButton, false)
	elseif not confirmationOpen and savePending then
		currentUi.PrimaryButton.Text = "SAVING..."
		currentUi.PrimaryButton.BackgroundColor3 = DISABLED_BLUE
		setButtonEnabled(currentUi.PrimaryButton, false)
	elseif not confirmationOpen and sessionOnly then
		currentUi.PrimaryButton.Text = "STORE UNAVAILABLE"
		currentUi.PrimaryButton.BackgroundColor3 = DISABLED_BLUE
		setButtonEnabled(currentUi.PrimaryButton, false)
	elseif not confirmationOpen and pendingRefreshId then
		currentUi.PrimaryButton.Text = "REFRESHING..."
		currentUi.PrimaryButton.BackgroundColor3 = DISABLED_BLUE
		setButtonEnabled(currentUi.PrimaryButton, false)
	elseif not confirmationOpen and freshnessRequired then
		currentUi.PrimaryButton.Text = "REFRESH STORE"
		currentUi.PrimaryButton.BackgroundColor3 = WINTER_BLUE
		setButtonEnabled(currentUi.PrimaryButton, true)
	elseif not confirmationOpen then
		local owned = activeState.OwnedSleds[selectedSledId] == true
		if activeState.EquippedSledId == selectedSledId then
			currentUi.PrimaryButton.Text = "EQUIPPED"
			currentUi.PrimaryButton.BackgroundColor3 = DISABLED_BLUE
			setButtonEnabled(currentUi.PrimaryButton, false)
		elseif owned then
			currentUi.PrimaryButton.Text = "EQUIP"
			currentUi.PrimaryButton.BackgroundColor3 = PINE_GREEN
			setButtonEnabled(currentUi.PrimaryButton, canTransact)
		elseif selectedSledId == RUNNER_SLED_ID and entry.ForSale then
			local shortfall = math.max(0, entry.Price - activeState.FrostCoins)
			if shortfall > 0 then
				currentUi.PrimaryButton.Text = string.format("NEED %d MORE", shortfall)
				currentUi.PrimaryButton.BackgroundColor3 = DISABLED_BLUE
				setButtonEnabled(currentUi.PrimaryButton, false)
			else
				currentUi.PrimaryButton.Text = string.format("BUY — %d FROST COINS", entry.Price)
				currentUi.PrimaryButton.BackgroundColor3 = PINE_GREEN
				setButtonEnabled(currentUi.PrimaryButton, canTransact)
			end
		else
			currentUi.PrimaryButton.Text = "UNAVAILABLE"
			currentUi.PrimaryButton.BackgroundColor3 = DISABLED_BLUE
			setButtonEnabled(currentUi.PrimaryButton, false)
		end
	end
	updateNavigation(currentUi)
	local selected = GuiService.SelectedObject
	local focusGeneration = activeModalFocusGeneration
	if focusGeneration ~= nil
		and (not selected
			or not selected:IsDescendantOf(currentUi.Backdrop)
			or not isEffectivelyVisible(selected, currentUi.Backdrop)
			or not selected.Active
			or not selected.Selectable)
	then
		claimModalFocus(currentUi, preferredModalSelection(currentUi), focusGeneration)
	else
		updateFocusVisuals(currentUi)
	end
end

local function unbindModalActions()
	if not modalActionsBound then
		return
	end
	modalActionsBound = false
	pcall(function()
		ContextActionService:UnbindAction(STORE_MODAL_CLOSE_ACTION)
		ContextActionService:UnbindAction(STORE_MODAL_BLOCK_ACTION)
	end)
end

local function modalBlockAction(
	_actionName: string,
	_inputState: Enum.UserInputState,
	_inputObject: InputObject
): Enum.ContextActionResult
	return Enum.ContextActionResult.Sink
end

local function modalCloseAction(
	_actionName: string,
	inputState: Enum.UserInputState,
	_inputObject: InputObject
): Enum.ContextActionResult
	if inputState == Enum.UserInputState.Begin then
		closeModal("escape-or-button-b")
	end
	return Enum.ContextActionResult.Sink
end

local function bindModalActions(): boolean
	if modalActionsBound then
		return true
	end
	local succeeded, failureReason = pcall(function()
		ContextActionService:BindActionAtPriority(
			STORE_MODAL_BLOCK_ACTION,
			modalBlockAction,
			false,
			MODAL_ACTION_PRIORITY,
			Enum.PlayerActions.CharacterForward,
			Enum.PlayerActions.CharacterBackward,
			Enum.PlayerActions.CharacterLeft,
			Enum.PlayerActions.CharacterRight,
			Enum.PlayerActions.CharacterJump,
			Enum.KeyCode.E,
			Enum.KeyCode.LeftShift,
			Enum.KeyCode.RightShift,
			Enum.KeyCode.ButtonL2
		)
		ContextActionService:BindActionAtPriority(
			STORE_MODAL_CLOSE_ACTION,
			modalCloseAction,
			false,
			MODAL_ACTION_PRIORITY + 1,
			Enum.KeyCode.Escape,
			Enum.KeyCode.ButtonB
		)
	end)
	if not succeeded then
		pcall(function()
			ContextActionService:UnbindAction(STORE_MODAL_CLOSE_ACTION)
			ContextActionService:UnbindAction(STORE_MODAL_BLOCK_ACTION)
		end)
		warnOnce("modal input protection failed: " .. tostring(failureReason))
		return false
	end
	modalActionsBound = true
	return true
end

releaseModalOwnership = function(_reason: string)
	-- Invalidate focus work first, even when the modal is already hidden.
	modalFocusGeneration += 1
	activeModalFocusGeneration = nil
	modalOpen = false
	confirmationRevision = nil

	local currentUi = ui
	if currentUi then
		-- Hidden controls stop participating in navigation before focus or
		-- visibility changes can make Roblox choose another GUI automatically.
		setModalControlsHidden(currentUi)
		currentUi.Backdrop.Active = false
		currentUi.Backdrop.Modal = false
	end

	local selected = GuiService.SelectedObject
	local selectedStoreObject = currentUi ~= nil
		and selected ~= nil
		and selected:IsDescendantOf(currentUi.ScreenGui)
	-- While this generation owns focus, clear even an object outside the Store:
	-- Roblox may already have transferred selection to TUCK/HUD during teardown.
	if storeOwnsFocus or selectedStoreObject then
		pcall(function()
			GuiService.SelectedObject = nil
		end)
	end

	unbindModalActions()
	if currentUi then
		currentUi.Backdrop.Visible = false
		disableFocusVisuals(currentUi)
	end
	storeOwnsFocus = false
end

closeModal = function(reason: string)
	releaseModalOwnership(reason)
	renderUi()
end

local function openModal()
	local currentUi = ui
	local state = currentState
	if not currentUi or not state or not launcherShouldBeVisible() then
		return
	end
	releaseModalOwnership("fresh-open")
	modalFocusGeneration += 1
	local focusGeneration = modalFocusGeneration
	activeModalFocusGeneration = focusGeneration
	storeOwnsFocus = true
	modalOpen = true
	confirmationRevision = nil
	statusMessage = ""
	statusColor = SECONDARY_ICE
	if not bindModalActions() then
		closeModal("modal-bind-failed")
		return
	end
	local freshSelection = if getCatalogEntry(state.EquippedSledId)
		then state.EquippedSledId
		else CLASSIC_SLED_ID
	if not selectSled(freshSelection, "FreshOpen") then
		closeModal("fresh-selection-failed")
		return
	end
	claimModalFocus(currentUi, preferredModalSelection(currentUi), focusGeneration)
	requestStateRefresh("open")
end

local function pruneRequestContexts()
	if #requestOrder > 40 then
		local oldest = table.remove(requestOrder, 1)
		if oldest ~= pendingRefreshId and (not pendingMutation or pendingMutation.RequestId ~= oldest) then
			requestContexts[oldest] = nil
		end
	end
end

local function clearMatchingPending(context: RequestContext)
	if pendingRefreshId == context.RequestId then
		pendingRefreshId = nil
	end
	if pendingMutation
		and pendingMutation.RequestId == context.RequestId
		and pendingMutation.Action == context.Action
		and pendingMutation.SledId == context.SledId
	then
		pendingMutation = nil
	end
end

local function beginRequest(action: StoreAction, sledId: string?, expectedRevision: number?): RequestContext?
	local remote = storeRequestRemote
	if destroyed or not remote or not remote.Parent or localPlayer.Parent ~= Players then
		return nil
	end
	local requestId = HttpService:GenerateGUID(false)
	local context: RequestContext = {
		RequestId = requestId,
		Action = action,
		SledId = sledId,
		ExpectedRevision = expectedRevision,
		LifecycleGeneration = lifecycleGeneration,
		RemoteGeneration = remoteGeneration,
		UiGeneration = uiGeneration,
	}
	requestContexts[requestId] = context
	table.insert(requestOrder, requestId)
	pruneRequestContexts()
	if action == StoreTypes.Actions.GetState then
		pendingRefreshId = requestId
	else
		pendingMutation = context
	end

	local request: StoreTypes.Request = {
		ProtocolVersion = StoreTypes.ProtocolVersion,
		RequestId = requestId,
		Action = action,
		SledId = sledId,
		ExpectedRevision = expectedRevision,
	}
	local sent = pcall(function()
		remote:FireServer(request)
	end)
	if not sent then
		requestContexts[requestId] = nil
		clearMatchingPending(context)
		freshnessRequired = true
		statusMessage = "STORE CONNECTION UNAVAILABLE"
		statusColor = CHRISTMAS_RED
		renderUi()
		return nil
	end

	local timeoutSeconds = GameConfig.Store.PendingTimeoutSeconds
	task.delay(timeoutSeconds, function()
		if requestContexts[requestId] ~= context then
			return
		end
		-- A bounded server load or verified persistence attempt may outlive
		-- this UI timeout. Keep the bounded context so its eventual response
		-- can reconcile state without polling, rollback, or a retry chain.
		clearMatchingPending(context)
		if destroyed
			or context.LifecycleGeneration ~= lifecycleGeneration
			or context.RemoteGeneration ~= remoteGeneration
			or context.UiGeneration ~= uiGeneration
		then
			return
		end
		freshnessRequired = true
		statusMessage = "REQUEST TIMED OUT — REFRESH STORE"
		statusColor = WARNING_AMBER
		if context.Action ~= StoreTypes.Actions.GetState then
			requestStateRefresh("mutation-timeout")
		end
		renderUi()
	end)
	renderUi()
	return context
end

requestStateRefresh = function(_reason: string)
	if destroyed
		or currentPhase ~= RunPhase.Idle
		or pendingRefreshId ~= nil
		or not storeRequestRemote
	then
		return
	end
	beginRequest(StoreTypes.Actions.GetState, nil, nil)
end

selectSled = function(sledId: string, source: BrowseSelectionSource): boolean
	if not getCatalogEntry(sledId) then
		return false
	end
	if (source == "Pointer" or source == "Focus") and not modalOpen then
		return false
	end
	local changed = selectedSledId ~= sledId
	selectedSledId = sledId
	if changed then
		confirmationRevision = nil
		statusMessage = ""
		statusColor = SECONDARY_ICE
	end
	renderUi()
	return true
end

local function activatePrimaryAction()
	local state = currentState
	if not modalOpen or not state or not hasCurrentStateForLifecycle() or pendingMutation then
		return
	end
	if freshnessRequired or pendingRefreshId then
		requestStateRefresh("manual")
		return
	end
	if not state.CanTransact or state.PersistenceState ~= StoreTypes.PersistenceStates.Persistent then
		return
	end
	if state.EquippedSledId == selectedSledId then
		return
	end
	if state.OwnedSleds[selectedSledId] == true then
		beginRequest(StoreTypes.Actions.Equip, selectedSledId, state.DataRevision)
		return
	end

	local entry = getCatalogEntry(selectedSledId)
	if selectedSledId == RUNNER_SLED_ID
		and entry
		and entry.ForSale
		and state.FrostCoins >= entry.Price
	then
		confirmationRevision = state.DataRevision
		statusMessage = "CONFIRM THIS PERMANENT COSMETIC PURCHASE"
		statusColor = SECONDARY_ICE
		renderUi()
		local currentUi = ui
		local focusGeneration = activeModalFocusGeneration
		if currentUi and focusGeneration ~= nil then
			claimModalFocus(currentUi, currentUi.CancelButton, focusGeneration)
		end
	end
end

local function confirmPurchase()
	local state = currentState
	local revision = confirmationRevision
	if not modalOpen
		or not state
		or not hasCurrentStateForLifecycle()
		or not state.CanTransact
		or state.PersistenceState ~= StoreTypes.PersistenceStates.Persistent
		or pendingMutation
		or pendingRefreshId
		or revision == nil
		or revision ~= state.DataRevision
		or selectedSledId ~= RUNNER_SLED_ID
	then
		confirmationRevision = nil
		renderUi()
		return
	end
	confirmationRevision = nil
	beginRequest(StoreTypes.Actions.Purchase, RUNNER_SLED_ID, revision)
end

local function cancelConfirmation()
	if confirmationRevision == nil then
		return
	end
	confirmationRevision = nil
	statusMessage = "PURCHASE CANCELLED — NO COINS CHARGED"
	statusColor = SECONDARY_ICE
	renderUi()
	local currentUi = ui
	local focusGeneration = activeModalFocusGeneration
	if currentUi and focusGeneration ~= nil then
		claimModalFocus(currentUi, currentUi.PrimaryButton, focusGeneration)
	end
end

local function disconnectViewportConnection()
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
end

local function destroySelectionImages(currentUi: StoreUi)
	for button in currentUi.FocusStrokes do
		pcall(function()
			button.SelectionImageObject = nil
		end)
	end
	for _, selectionImage in currentUi.SelectionImages do
		selectionImage:Destroy()
	end
	table.clear(currentUi.SelectionImages)
end

local function observeCurrentCamera()
	disconnectViewportConnection()
	local camera = Workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateResponsiveLayout)
	end
	updateResponsiveLayout()
end

local function detachUi()
	releaseModalOwnership("ui-detach")
	disconnectViewportConnection()
	disconnectConnections(uiConnections)
	uiGeneration += 1
	local oldUi = ui
	ui = nil
	currentPlayerGui = nil
	if oldUi then
		destroySelectionImages(oldUi)
		if oldUi.ScreenGui.Parent then
			oldUi.ScreenGui:Destroy()
		end
	end
end

local function attachUi(playerGui: PlayerGui)
	if destroyed or currentPlayerGui == playerGui then
		return
	end
	detachUi()
	currentPlayerGui = playerGui
	uiGeneration += 1
	local newUi = createStoreUi(playerGui)
	ui = newUi
	local attachedUiGeneration = uiGeneration
	local function activateSledCard(sledId: string, cardButton: TextButton)
		local focusGeneration = activeModalFocusGeneration
		if focusGeneration == nil
			or ui ~= newUi
			or uiGeneration ~= attachedUiGeneration
			or not isCurrentModalFocusTarget(newUi, cardButton, focusGeneration)
		then
			return
		end
		if selectSled(sledId, "Pointer") then
			claimModalFocus(newUi, cardButton, focusGeneration)
		end
	end

	table.insert(uiConnections, newUi.Launcher.Activated:Connect(openModal))
	table.insert(uiConnections, newUi.CloseButton.Activated:Connect(function()
		closeModal("close-button")
	end))
	table.insert(uiConnections, newUi.ClassicCard.Button.Activated:Connect(function()
		activateSledCard(CLASSIC_SLED_ID, newUi.ClassicCard.Button)
	end))
	table.insert(uiConnections, newUi.RunnerCard.Button.Activated:Connect(function()
		activateSledCard(RUNNER_SLED_ID, newUi.RunnerCard.Button)
	end))
	table.insert(uiConnections, newUi.PrimaryButton.Activated:Connect(activatePrimaryAction))
	table.insert(uiConnections, newUi.ConfirmButton.Activated:Connect(confirmPurchase))
	table.insert(uiConnections, newUi.CancelButton.Activated:Connect(cancelConfirmation))
	table.insert(uiConnections, newUi.Backdrop.Activated:Connect(function() end))
	table.insert(uiConnections, newUi.Backdrop:GetPropertyChangedSignal("AbsoluteSize"):Connect(updateResponsiveLayout))
	table.insert(uiConnections, GuiService:GetPropertyChangedSignal("ViewportDisplaySize"):Connect(updateResponsiveLayout))
	table.insert(uiConnections, playerGui:GetPropertyChangedSignal("CurrentScreenOrientation"):Connect(updateResponsiveLayout))
	table.insert(uiConnections, Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(observeCurrentCamera))
	table.insert(uiConnections, GuiService:GetPropertyChangedSignal("SelectedObject"):Connect(function()
		if destroyed or ui ~= newUi or uiGeneration ~= attachedUiGeneration then
			return
		end
		local selected = GuiService.SelectedObject
		updateFocusVisuals(newUi)
		if not modalOpen then
			local hiddenModalSelection = selected ~= nil and selected:IsDescendantOf(newUi.Backdrop)
			local unavailableLauncherSelection = currentPhase ~= RunPhase.Idle and selected == newUi.Launcher
			if hiddenModalSelection or unavailableLauncherSelection then
				releaseModalOwnership("closed-store-selection")
			end
			return
		end

		local focusGeneration = activeModalFocusGeneration
		if focusGeneration == nil or not storeOwnsFocus then
			return
		elseif selected == newUi.ClassicCard.Button then
			selectSled(CLASSIC_SLED_ID, "Focus")
		elseif selected == newUi.RunnerCard.Button then
			selectSled(RUNNER_SLED_ID, "Focus")
		elseif not selected
			or not selected:IsDescendantOf(newUi.Backdrop)
			or not isEffectivelyVisible(selected, newUi.Backdrop)
			or not selected.Active
			or not selected.Selectable
		then
			claimModalFocus(newUi, preferredModalSelection(newUi), focusGeneration)
		end
	end))
	table.insert(uiConnections, newUi.ScreenGui.Destroying:Connect(function()
		if ui == newUi then
			releaseModalOwnership("screen-gui-destroying")
			disconnectViewportConnection()
			destroySelectionImages(newUi)
			ui = nil
			currentPlayerGui = nil
			uiGeneration += 1
			disconnectConnections(uiConnections)
		end
	end))
	observeCurrentCamera()
	renderUi()
end

local function invalidateClientLifecycle()
	lifecycleGeneration += 1
	currentStateGeneration = -1
	freshnessRequired = true
	confirmationRevision = nil
	pendingRefreshId = nil
	pendingMutation = nil
	statusMessage = ""
	closeModal("lifecycle-invalidated")
end

local function acceptRunState(phaseValue: any, runIdValue: any)
	if destroyed then
		return
	end
	if typeof(phaseValue) ~= "string" or not isValidRunId(runIdValue) then
		currentRunId = nil
		currentPhase = ""
		currentPhaseRank = 0
		invalidateClientLifecycle()
		return
	end
	local phase = phaseValue :: string
	local runId = runIdValue :: number
	local rank = phaseRank(phase)
	if not rank then
		currentRunId = nil
		currentPhase = ""
		currentPhaseRank = 0
		invalidateClientLifecycle()
		return
	end
	if runId < latestRunId then
		return
	end

	local runChanged = currentRunId ~= runId
	if runChanged then
		latestRunId = runId
		currentRunId = runId
		currentPhaseRank = 0
	elseif rank < currentPhaseRank then
		return
	elseif phase == currentPhase then
		return
	end

	currentPhase = phase
	currentPhaseRank = rank
	invalidateClientLifecycle()
	if phase == RunPhase.Idle then
		requestStateRefresh("idle")
	end
end

local function responseMatchesContext(state: StoreState, context: RequestContext): boolean
	return state.ResponseAction == context.Action
		and state.ResponseSledId == context.SledId
		and context.LifecycleGeneration == lifecycleGeneration
		and context.RemoteGeneration == remoteGeneration
		and context.UiGeneration == uiGeneration
end

local function acceptStoreState(rawState: any)
	local state = parseStoreState(rawState)
	if not state then
		return
	end
	local context = requestContexts[state.ResponseToRequestId]
	if not context then
		return
	end
	if state.ResponseAction ~= context.Action or state.ResponseSledId ~= context.SledId then
		return
	end
	local requestStillPending = state.StatusCode == StoreTypes.StatusCodes.RequestInProgress
	if not requestStillPending then
		requestContexts[state.ResponseToRequestId] = nil
		clearMatchingPending(context)
	end

	if not responseMatchesContext(state, context)
		or currentPhase ~= RunPhase.Idle
		or localPlayer.Parent ~= Players
	then
		renderUi()
		return
	end
	if state.ServerSequence < latestServerSequence then
		freshnessRequired = true
		requestStateRefresh("stale-response")
		renderUi()
		return
	end

	latestServerSequence = state.ServerSequence
	currentState = state
	currentStateGeneration = lifecycleGeneration
	freshnessRequired = false
	statusMessage, statusColor = statusPresentation(state.StatusCode, state.ResponseAction)
	if state.PersistenceState == StoreTypes.PersistenceStates.SavePending then
		freshnessRequired = false
	end
	if not state.CanBrowse and modalOpen then
		closeModal("authoritative-store-unavailable")
		return
	end
	if not getCatalogEntry(selectedSledId) then
		local fallback = if getCatalogEntry(state.EquippedSledId)
			then state.EquippedSledId
			else CLASSIC_SLED_ID
		selectSled(fallback, "CatalogFallback")
		return
	end
	renderUi()
end

local function disconnectRemotes()
	disconnectConnections(remoteConnections)
	storeRequestRemote = nil
	storeStateRemote = nil
	runStateRemote = nil
	remoteGeneration += 1
	latestServerSequence = -1
	invalidateClientLifecycle()
end

local function connectRemotes(requestRemote: RemoteEvent, stateRemote: RemoteEvent, stateOfRunRemote: RemoteEvent)
	if destroyed then
		return
	end
	disconnectRemotes()
	storeRequestRemote = requestRemote
	storeStateRemote = stateRemote
	runStateRemote = stateOfRunRemote
	local generation = remoteGeneration

	-- StoreState is deliberately connected before the first request is sent.
	table.insert(remoteConnections, stateRemote.OnClientEvent:Connect(acceptStoreState))
	-- StoreController owns exactly one independent RunState subscription.
	table.insert(remoteConnections, stateOfRunRemote.OnClientEvent:Connect(function(
		phase: any,
		_countdown: any,
		_speed: any,
		runId: any
	)
		acceptRunState(phase, runId)
	end))
	local function onRemoteAncestryChanged(_instance: Instance, parent: Instance?)
		if parent == nil and generation == remoteGeneration then
			disconnectRemotes()
		end
	end
	table.insert(remoteConnections, requestRemote.AncestryChanged:Connect(onRemoteAncestryChanged))
	table.insert(remoteConnections, stateRemote.AncestryChanged:Connect(onRemoteAncestryChanged))
	table.insert(remoteConnections, stateOfRunRemote.AncestryChanged:Connect(onRemoteAncestryChanged))
	requestStateRefresh("initial")
end

local function remainingTime(deadline: number): number
	return math.max(0, deadline - os.clock())
end

local function findOrWaitForChild(parent: Instance, name: string, deadline: number): Instance?
	local existing = parent:FindFirstChild(name)
	if existing then
		return existing
	end
	local remaining = remainingTime(deadline)
	if remaining <= 0 then
		return nil
	end
	return parent:WaitForChild(name, remaining)
end

local function acquireDependencies(acquisitionGeneration: number)
	local deadline = os.clock() + REMOTE_ACQUISITION_TIMEOUT_SECONDS
	local playerGuiInstance = localPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGuiInstance then
		local found = findOrWaitForChild(localPlayer, "PlayerGui", deadline)
		if found and found:IsA("PlayerGui") then
			playerGuiInstance = found
		end
	end
	if destroyed or acquisitionGeneration ~= remoteGeneration then
		return
	end
	if playerGuiInstance then
		attachUi(playerGuiInstance)
	end

	local folderInstance = findOrWaitForChild(ReplicatedStorage, REMOTES_FOLDER_NAME, deadline)
	if destroyed or acquisitionGeneration ~= remoteGeneration then
		return
	end
	if not folderInstance or not folderInstance:IsA("Folder") then
		warnOnce("FrostlineRemotes was not available")
		return
	end
	local requestInstance = findOrWaitForChild(folderInstance, STORE_REQUEST_REMOTE_NAME, deadline)
	local stateInstance = findOrWaitForChild(folderInstance, STORE_STATE_REMOTE_NAME, deadline)
	local runStateInstance = findOrWaitForChild(folderInstance, RUN_STATE_REMOTE_NAME, deadline)
	if destroyed or acquisitionGeneration ~= remoteGeneration then
		return
	end
	if not requestInstance or not requestInstance:IsA("RemoteEvent")
		or not stateInstance or not stateInstance:IsA("RemoteEvent")
		or not runStateInstance or not runStateInstance:IsA("RemoteEvent")
	then
		warnOnce("Store remotes were unavailable or had the wrong class")
		return
	end
	connectRemotes(requestInstance, stateInstance, runStateInstance)
end

function StoreController.start()
	if started then
		return
	end
	validateCatalog()
	started = true
	destroyed = false
	warningIssued = false
	lifecycleGeneration = 0
	remoteGeneration = 1
	uiGeneration = 0
	latestRunId = 0
	currentRunId = nil
	currentPhase = RunPhase.Idle
	currentPhaseRank = 0
	currentState = nil
	currentStateGeneration = -1
	latestServerSequence = -1
	modalOpen = false
	modalFocusGeneration = 0
	activeModalFocusGeneration = nil
	storeOwnsFocus = false
	confirmationRevision = nil
	pendingRefreshId = nil
	pendingMutation = nil
	freshnessRequired = true
	statusMessage = ""
	statusColor = SECONDARY_ICE
	table.clear(requestContexts)
	table.clear(requestOrder)
	selectSled(CLASSIC_SLED_ID, "Startup")

	local immediatePlayerGui = localPlayer:FindFirstChildOfClass("PlayerGui")
	if immediatePlayerGui then
		attachUi(immediatePlayerGui)
	end

	table.insert(controllerConnections, localPlayer.ChildAdded:Connect(function(child: Instance)
		if child:IsA("PlayerGui") then
			invalidateClientLifecycle()
			attachUi(child)
			if currentPhase == RunPhase.Idle and storeRequestRemote then
				requestStateRefresh("player-gui")
			end
		end
	end))
	table.insert(controllerConnections, localPlayer.ChildRemoved:Connect(function(child: Instance)
		if child == currentPlayerGui then
			invalidateClientLifecycle()
			detachUi()
		end
	end))
	table.insert(controllerConnections, localPlayer.CharacterRemoving:Connect(function(_character: Model)
		invalidateClientLifecycle()
	end))
	table.insert(controllerConnections, localPlayer.CharacterAdded:Connect(function(_character: Model)
		invalidateClientLifecycle()
		if currentPhase == RunPhase.Idle and storeRequestRemote then
			requestStateRefresh("character")
		end
	end))
	table.insert(controllerConnections, script.Destroying:Connect(StoreController.destroy))

	local acquisitionGeneration = remoteGeneration
	task.defer(function()
		local succeeded, failureReason = pcall(acquireDependencies, acquisitionGeneration)
		if not succeeded and not destroyed then
			warnOnce(tostring(failureReason))
		end
	end)
end

function StoreController.destroy()
	if destroyed then
		return
	end
	destroyed = true
	lifecycleGeneration += 1
	remoteGeneration += 1
	releaseModalOwnership("controller-destroy")
	disconnectConnections(remoteConnections)
	disconnectConnections(controllerConnections)
	detachUi()
	table.clear(requestContexts)
	table.clear(requestOrder)
	storeRequestRemote = nil
	storeStateRemote = nil
	runStateRemote = nil
	currentState = nil
	pendingRefreshId = nil
	pendingMutation = nil
	started = false
end

return StoreController
