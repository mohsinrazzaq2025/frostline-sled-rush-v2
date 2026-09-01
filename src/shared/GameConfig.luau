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

		-- Course distances are measured from LaunchEdge along positive world Z.
		StudsPerMeter = 1.25,
		LandingMarkedDistanceMeters = 1500,
		LandingRunoffDistanceMeters = 300,
		LandingWidth = 280,
		LandingThickness = 3,
		LandingTopY = 0,
		LandingSegmentOverlap = 0.25,
	},

	-- High surface weights make the authored track and lake properties dominate the
	-- low-weight sled runner properties without changing physics after touchdown.
	Physics = {
		TrackDensity = 0.72,
		TrackFriction = 0.035,
		TrackElasticity = 0.02,
		TrackFrictionWeight = 100,
		TrackElasticityWeight = 1,

		FrozenLakeDensity = 0.75,
		FrozenLakeFriction = 0.08,
		FrozenLakeElasticity = 0.01,
		FrozenLakeFrictionWeight = 100,
		FrozenLakeElasticityWeight = 1,

		SledRootDensity = 1.1,
		SledRootFriction = 0.035,
		SledRootElasticity = 0.04,
		SledRootFrictionWeight = 1,
		SledRootElasticityWeight = 1,
	},

	Run = {
		StartPromptHoldDuration = 2.0,
		CountdownDuration = 3,
		InitialPushSpeed = 20,
		TuckAcceleration = 22,
		AntiStallSpeed = 26,
		AntiStallAcceleration = 7,
		StabilityYawResponse = 900,
		StabilityRollResponse = 1100,
		StabilityAngularDamping = 550,
		StabilityRayDistance = 5,
		MaximumStabilityTorque = 2400,
		RampFreedomStartZ = 215,
		-- A stop is physical only after both measured speeds stay below these
		-- thresholds for the entire confirmation interval.
		LandingStopHorizontalSpeed = 0.5,
		LandingStopAngularSpeed = 0.5,
		LandingStopConfirmationDuration = 1.0,
		ResultsPauseDuration = 1.5,
		MaximumRunDuration = 45,
		SafetyBounds = {
			MaximumLateralDistance = 600,
			MinimumY = -150,
		},
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
