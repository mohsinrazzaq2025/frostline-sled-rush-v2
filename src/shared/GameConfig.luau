--!strict

local GameConfig = {
	World = {
		FolderName = "FrostlineWorld",
		TrackWidth = 48,
		TrackThickness = 2.5,
		BankWidth = 12,
		BankThickness = 2,
		BankAngleDegrees = 28,
		RailHeight = 4.5,
		SamplesPerCurve = 5,

		-- Surface-center control points. The run travels toward positive Z.
		-- The final two points form a deliberately long launch ramp.
		PathPoints = {
			Vector3.new(0, 126, -250),
			Vector3.new(0, 124, -225),
			Vector3.new(0, 116, -185),
			Vector3.new(0, 100, -135),
			Vector3.new(0, 79, -75),
			Vector3.new(0, 57, -5),
			Vector3.new(0, 41, 70),
			Vector3.new(0, 29, 145),
			Vector3.new(0, 24, 215),
			Vector3.new(0, 32, 275),
			Vector3.new(0, 52, 330),
		},

		LakeCenter = Vector3.new(0, -1.5, 690),
		LakeSize = Vector3.new(280, 3, 720),
	},

	Palette = {
		Snow = Color3.fromRGB(231, 242, 250),
		Ice = Color3.fromRGB(150, 218, 242),
		IceDeep = Color3.fromRGB(72, 154, 202),
		Red = Color3.fromRGB(188, 38, 51),
		White = Color3.fromRGB(250, 251, 252),
		Gold = Color3.fromRGB(244, 190, 70),
		PineDark = Color3.fromRGB(24, 91, 72),
		PineLight = Color3.fromRGB(40, 130, 92),
		Wood = Color3.fromRGB(91, 58, 42),
	},
}

return table.freeze(GameConfig)
