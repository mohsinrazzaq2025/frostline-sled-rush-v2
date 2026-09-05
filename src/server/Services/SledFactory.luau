--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local PHYSICS = GameConfig.Physics
local PALETTE = GameConfig.Palette

export type SledId = "FrostlineClassic" | "FrostRunner"

local CLASSIC_RED = Color3.fromRGB(148, 22, 39)
local CLASSIC_RED_DARK = Color3.fromRGB(112, 16, 31)
local CLASSIC_CREAM = Color3.fromRGB(250, 237, 207)
local CLASSIC_CYAN = Color3.fromRGB(105, 226, 255)
local CLASSIC_SLED_ID: SledId = "FrostlineClassic"
local FROST_RUNNER_SLED_ID: SledId = "FrostRunner"
local FROST_RUNNER_BODY = Color3.fromRGB(18, 52, 78)
local FROST_RUNNER_SECONDARY = Color3.fromRGB(72, 210, 235)
local FROST_RUNNER_RUNNER = Color3.fromRGB(190, 235, 245)
local FROST_RUNNER_SEAT = Color3.fromRGB(20, 29, 42)
local FROST_RUNNER_TRIM = Color3.fromRGB(90, 225, 255)

local LEGACY_VISUAL_PART_NAMES = {
	"RedDeck",
	"GoldLeftRunner",
	"GoldRightRunner",
	"GoldLeftRunnerSupport",
	"GoldRightRunnerSupport",
	"RedFrontLip",
	"GoldFrontTrim",
	"RedBackrest",
	"GoldBackrestTrim",
}

local SledFactory = {}

export type Sled = {
	Model: Model,
	Root: Part,
	DriverSeat: Seat,
}

type CosmeticAppearance = {
	PartName: string,
	Color: Color3,
	Material: Enum.Material,
}

local FROST_RUNNER_APPEARANCE: { CosmeticAppearance } = {
	{
		PartName = "ClassicBodyFloor",
		Color = FROST_RUNNER_BODY,
		Material = Enum.Material.SmoothPlastic,
	},
	{
		PartName = "ClassicLeftBodySide",
		Color = FROST_RUNNER_BODY,
		Material = Enum.Material.SmoothPlastic,
	},
	{
		PartName = "ClassicRightBodySide",
		Color = FROST_RUNNER_BODY,
		Material = Enum.Material.SmoothPlastic,
	},
	{
		PartName = "ClassicLeftNoseCheek",
		Color = FROST_RUNNER_BODY,
		Material = Enum.Material.SmoothPlastic,
	},
	{
		PartName = "ClassicRightNoseCheek",
		Color = FROST_RUNNER_BODY,
		Material = Enum.Material.SmoothPlastic,
	},
	{
		PartName = "ClassicFrontApron",
		Color = FROST_RUNNER_BODY,
		Material = Enum.Material.SmoothPlastic,
	},
	{
		PartName = "ClassicRearLowerSlat",
		Color = FROST_RUNNER_BODY,
		Material = Enum.Material.SmoothPlastic,
	},
	{
		PartName = "ClassicRearUpperSlat",
		Color = FROST_RUNNER_BODY,
		Material = Enum.Material.SmoothPlastic,
	},
	{
		PartName = "ClassicRearLeftPost",
		Color = FROST_RUNNER_SECONDARY,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicRearRightPost",
		Color = FROST_RUNNER_SECONDARY,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicLeftFrontRunnerSupport",
		Color = FROST_RUNNER_SECONDARY,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicLeftRearRunnerSupport",
		Color = FROST_RUNNER_SECONDARY,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicRightFrontRunnerSupport",
		Color = FROST_RUNNER_SECONDARY,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicRightRearRunnerSupport",
		Color = FROST_RUNNER_SECONDARY,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicLeftRunnerRail",
		Color = FROST_RUNNER_RUNNER,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicLeftRunnerUpturn",
		Color = FROST_RUNNER_RUNNER,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicLeftRunnerCurl",
		Color = FROST_RUNNER_RUNNER,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicRightRunnerRail",
		Color = FROST_RUNNER_RUNNER,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicRightRunnerUpturn",
		Color = FROST_RUNNER_RUNNER,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicRightRunnerCurl",
		Color = FROST_RUNNER_RUNNER,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "ClassicLeftFrostTrim",
		Color = FROST_RUNNER_TRIM,
		Material = Enum.Material.SmoothPlastic,
	},
	{
		PartName = "ClassicRightFrostTrim",
		Color = FROST_RUNNER_TRIM,
		Material = Enum.Material.SmoothPlastic,
	},
	{
		PartName = "ClassicFrontGoldTrim",
		Color = FROST_RUNNER_TRIM,
		Material = Enum.Material.Metal,
	},
	{
		PartName = "FrostlineBadge",
		Color = FROST_RUNNER_TRIM,
		Material = Enum.Material.SmoothPlastic,
	},
}
table.freeze(FROST_RUNNER_APPEARANCE)

local function normalizeSledId(value: string?): SledId
	if typeof(value) == "string" and value == FROST_RUNNER_SLED_ID then
		return FROST_RUNNER_SLED_ID
	end
	return CLASSIC_SLED_ID
end

local function weldToRoot(root: Part, part: BasePart)
	local weld = Instance.new("WeldConstraint")
	weld.Name = string.format("%sWeld", part.Name)
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
end

local function configureVisualPart(
	part: BasePart,
	model: Model,
	root: Part,
	name: string,
	size: Vector3,
	localCFrame: CFrame,
	color: Color3,
	material: Enum.Material
)
	part.Name = name
	part.Size = size
	part.CFrame = root.CFrame * localCFrame
	part.Anchored = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.CastShadow = true
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	weldToRoot(root, part)
end

local function createVisualPart(
	model: Model,
	root: Part,
	name: string,
	size: Vector3,
	localCFrame: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	configureVisualPart(part, model, root, name, size, localCFrame, color, material)
	return part
end

local function createWedgePart(
	model: Model,
	root: Part,
	name: string,
	size: Vector3,
	localCFrame: CFrame,
	color: Color3,
	material: Enum.Material
): WedgePart
	local part = Instance.new("WedgePart")
	configureVisualPart(part, model, root, name, size, localCFrame, color, material)
	return part
end

local function createCylinderBetween(
	model: Model,
	root: Part,
	name: string,
	localStart: Vector3,
	localEnd: Vector3,
	diameter: number,
	color: Color3,
	material: Enum.Material
): Part
	local offset = localEnd - localStart
	local length = offset.Magnitude
	local midpoint = (localStart + localEnd) * 0.5
	local cylinder = Instance.new("Part")
	cylinder.Shape = Enum.PartType.Cylinder
	configureVisualPart(
		cylinder,
		model,
		root,
		name,
		Vector3.new(length, diameter, diameter),
		CFrame.lookAt(midpoint, localEnd) * CFrame.Angles(0, math.rad(90), 0),
		color,
		material
	)
	return cylinder
end

local function createFrostlineBadge(badge: Part)
	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Name = "FrostlineBadgeFace"
	surfaceGui.Face = Enum.NormalId.Back
	surfaceGui.CanvasSize = Vector2.new(320, 84)
	surfaceGui.AlwaysOnTop = false
	surfaceGui.Parent = badge

	local label = Instance.new("TextLabel")
	label.Name = "Wordmark"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.Text = "FROSTLINE"
	label.TextColor3 = Color3.fromRGB(8, 48, 72)
	label.TextScaled = true
	label.TextStrokeColor3 = Color3.fromRGB(239, 252, 255)
	label.TextStrokeTransparency = 0.55
	label.Parent = surfaceGui
end

local function createClassicVisualShell(model: Model, root: Part): Model
	local shell = Instance.new("Model")
	shell.Name = "FrostlineClassicVisual"
	shell.Parent = model

	createVisualPart(
		shell,
		root,
		"ClassicBodyFloor",
		Vector3.new(5.85, 0.5, 7.2),
		CFrame.new(0, 1.02, 0.35),
		CLASSIC_RED,
		Enum.Material.SmoothPlastic
	)

	for _, side in { -1, 1 } do
		local sideName = if side == -1 then "Left" else "Right"
		createWedgePart(
			shell,
			root,
			string.format("Classic%sBodySide", sideName),
			Vector3.new(0.62, 1.45, 6.65),
			CFrame.new(side * 2.72, 1.58, 0.45),
			CLASSIC_RED,
			Enum.Material.SmoothPlastic
		)
		createWedgePart(
			shell,
			root,
			string.format("Classic%sNoseCheek", sideName),
			Vector3.new(0.5, 1.05, 2.25),
			CFrame.new(side * 2.34, 1.4, -3.32) * CFrame.Angles(0, math.rad(side * 18), 0),
			CLASSIC_RED_DARK,
			Enum.Material.SmoothPlastic
		)
	end

	createVisualPart(
		shell,
		root,
		"ClassicFrontApron",
		Vector3.new(4.25, 1, 0.42),
		CFrame.new(0, 1.38, -4.37) * CFrame.Angles(math.rad(10), 0, 0),
		CLASSIC_RED,
		Enum.Material.SmoothPlastic
	)

	for _, side in { -1, 1 } do
		local sideName = if side == -1 then "Left" else "Right"
		createVisualPart(
			shell,
			root,
			string.format("ClassicRear%sPost", sideName),
			Vector3.new(0.32, 1.55, 0.32),
			CFrame.new(side * 2.28, 2.55, 3.55) * CFrame.Angles(math.rad(7), 0, 0),
			PALETTE.Gold,
			Enum.Material.Metal
		)
	end

	createVisualPart(
		shell,
		root,
		"ClassicRearLowerSlat",
		Vector3.new(4.65, 0.3, 0.3),
		CFrame.new(0, 2.15, 3.55) * CFrame.Angles(math.rad(7), 0, 0),
		CLASSIC_RED,
		Enum.Material.SmoothPlastic
	)
	createVisualPart(
		shell,
		root,
		"ClassicRearUpperSlat",
		Vector3.new(4.9, 0.42, 0.34),
		CFrame.new(0, 3.15, 3.55) * CFrame.Angles(math.rad(7), 0, 0),
		CLASSIC_RED,
		Enum.Material.SmoothPlastic
	)

	for _, side in { -1, 1 } do
		local sideName = if side == -1 then "Left" else "Right"
		createVisualPart(
			shell,
			root,
			string.format("Classic%sRunnerRail", sideName),
			Vector3.new(0.48, 0.4, 10.2),
			CFrame.new(side * 2.58, -0.52, 0.28),
			PALETTE.Gold,
			Enum.Material.Metal
		)
		createCylinderBetween(
			shell,
			root,
			string.format("Classic%sRunnerUpturn", sideName),
			Vector3.new(side * 2.58, -0.5, -4.72),
			Vector3.new(side * 2.58, 0.75, -5.75),
			0.46,
			PALETTE.Gold,
			Enum.Material.Metal
		)
		createCylinderBetween(
			shell,
			root,
			string.format("Classic%sRunnerCurl", sideName),
			Vector3.new(side * 2.58, 0.75, -5.75),
			Vector3.new(side * 2.58, 1.34, -5.42),
			0.46,
			PALETTE.Gold,
			Enum.Material.Metal
		)
		createVisualPart(
			shell,
			root,
			string.format("Classic%sFrontRunnerSupport", sideName),
			Vector3.new(0.4, 1.3, 0.4),
			CFrame.new(side * 2.58, 0.18, -2.15) * CFrame.Angles(math.rad(-8), 0, 0),
			PALETTE.Gold,
			Enum.Material.Metal
		)
		createVisualPart(
			shell,
			root,
			string.format("Classic%sRearRunnerSupport", sideName),
			Vector3.new(0.4, 1.3, 0.4),
			CFrame.new(side * 2.58, 0.18, 2.35) * CFrame.Angles(math.rad(8), 0, 0),
			PALETTE.Gold,
			Enum.Material.Metal
		)
		createVisualPart(
			shell,
			root,
			string.format("Classic%sFrostTrim", sideName),
			Vector3.new(0.18, 0.18, 6.15),
			CFrame.new(side * 2.72, 2.02, 0.52) * CFrame.Angles(math.rad(-7), 0, 0),
			CLASSIC_CREAM,
			Enum.Material.SmoothPlastic
		)
	end

	createVisualPart(
		shell,
		root,
		"ClassicFrontGoldTrim",
		Vector3.new(4.35, 0.2, 0.2),
		CFrame.new(0, 1.95, -4.58) * CFrame.Angles(math.rad(10), 0, 0),
		PALETTE.Gold,
		Enum.Material.Metal
	)
	local badge = createVisualPart(
		shell,
		root,
		"FrostlineBadge",
		Vector3.new(2, 0.52, 0.12),
		CFrame.new(0, 1.25, 4.02),
		CLASSIC_CYAN,
		Enum.Material.SmoothPlastic
	)
	createFrostlineBadge(badge)
	return shell
end

local function applyFrostRunnerAppearance(shell: Model, driverSeat: Seat)
	for _, appearance in FROST_RUNNER_APPEARANCE do
		local instance = shell:FindFirstChild(appearance.PartName)
		if not instance or not instance:IsA("BasePart") then
			error(string.format("Frost Runner cosmetic part unavailable: %s", appearance.PartName))
		end
		instance.Color = appearance.Color
		instance.Material = appearance.Material
	end

	driverSeat.Color = FROST_RUNNER_SEAT
	driverSeat.Material = Enum.Material.SmoothPlastic
end

function SledFactory.create(spawnCFrame: CFrame, equippedSledId: string?): Sled
	local sledId = normalizeSledId(equippedSledId)
	local model = Instance.new("Model")
	model.Name = "ChristmasSled"
	model:SetAttribute("SledId", sledId)

	-- All physical mass and collision live in this low body. Everything visible is welded and massless.
	local root = Instance.new("Part")
	root.Name = "SledRoot"
	root.Size = Vector3.new(5.6, 0.8, 8.6)
	root.CFrame = spawnCFrame
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = true
	root.CanTouch = true
	root.CanQuery = true
	root.Massless = false
	root.CastShadow = false
	root.CustomPhysicalProperties = PhysicalProperties.new(
		PHYSICS.SledRootDensity,
		PHYSICS.SledRootFriction,
		PHYSICS.SledRootElasticity,
		PHYSICS.SledRootFrictionWeight,
		PHYSICS.SledRootElasticityWeight
	)
	root.Parent = model

	createVisualPart(
		model,
		root,
		"RedDeck",
		Vector3.new(7, 0.55, 9.5),
		CFrame.new(0, 1.05, 0),
		PALETTE.Red,
		Enum.Material.SmoothPlastic
	)

	for _, side in ipairs({ -1, 1 }) do
		local sideName = if side == -1 then "Left" else "Right"
		createVisualPart(
			model,
			root,
			string.format("Gold%sRunner", sideName),
			Vector3.new(0.48, 0.55, 12),
			CFrame.new(side * 2.65, -0.42, 0.45),
			PALETTE.Gold,
			Enum.Material.Metal
		)
		createVisualPart(
			model,
			root,
			string.format("Gold%sRunnerSupport", sideName),
			Vector3.new(0.38, 1.35, 0.38),
			CFrame.new(side * 2.65, 0.2, -2.6),
			PALETTE.Gold,
			Enum.Material.Metal
		)
	end

	createVisualPart(
		model,
		root,
		"RedFrontLip",
		Vector3.new(7, 1.9, 0.6),
		CFrame.new(0, 1.75, -4.65) * CFrame.Angles(math.rad(24), 0, 0),
		PALETTE.Red,
		Enum.Material.SmoothPlastic
	)
	createVisualPart(
		model,
		root,
		"GoldFrontTrim",
		Vector3.new(7.25, 0.24, 0.28),
		CFrame.new(0, 2.65, -4.83) * CFrame.Angles(math.rad(24), 0, 0),
		PALETTE.Gold,
		Enum.Material.Metal
	)
	createVisualPart(
		model,
		root,
		"RedBackrest",
		Vector3.new(6.5, 3.2, 0.55),
		CFrame.new(0, 2.65, 4.15) * CFrame.Angles(math.rad(8), 0, 0),
		PALETTE.Red,
		Enum.Material.SmoothPlastic
	)
	createVisualPart(
		model,
		root,
		"GoldBackrestTrim",
		Vector3.new(6.8, 0.28, 0.7),
		CFrame.new(0, 4.18, 3.94) * CFrame.Angles(math.rad(8), 0, 0),
		PALETTE.Gold,
		Enum.Material.Metal
	)

	local driverSeat = Instance.new("Seat")
	configureVisualPart(
		driverSeat,
		model,
		root,
		"DriverSeat",
		Vector3.new(4.6, 0.65, 3.5),
		CFrame.new(0, 1.65, 1.2),
		Color3.fromRGB(132, 24, 36),
		Enum.Material.SmoothPlastic
	)
	driverSeat.Disabled = false

	-- Keep the original renderer parts and welds unchanged for compatibility, but
	-- make only their old box-like appearance invisible beneath the new shell.
	for _, partName in LEGACY_VISUAL_PART_NAMES do
		local legacyPart = model:FindFirstChild(partName)
		if legacyPart and legacyPart:IsA("BasePart") then
			legacyPart.Transparency = 1
		end
	end
	local shell = createClassicVisualShell(model, root)
	if sledId == FROST_RUNNER_SLED_ID then
		applyFrostRunnerAppearance(shell, driverSeat)
	end

	model.PrimaryPart = root
	return {
		Model = model,
		Root = root,
		DriverSeat = driverSeat,
	}
end

return SledFactory
