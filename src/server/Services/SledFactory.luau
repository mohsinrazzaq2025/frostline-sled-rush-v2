--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local PHYSICS = GameConfig.Physics
local PALETTE = GameConfig.Palette

local SledFactory = {}

export type Sled = {
	Model: Model,
	Root: Part,
	DriverSeat: Seat,
}

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

function SledFactory.create(spawnCFrame: CFrame): Sled
	local model = Instance.new("Model")
	model.Name = "ChristmasSled"

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

	model.PrimaryPart = root
	return {
		Model = model,
		Root = root,
		DriverSeat = driverSeat,
	}
end

return SledFactory
