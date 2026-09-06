--!strict

type SledCatalogEntry = {
	SledId: string,
	DisplayName: string,
	Price: number,
	ForSale: boolean,
	Description: string,
}

local knownSledIds: { [string]: boolean } = {
	FrostlineClassic = true,
	FrostRunner = true,
}
table.freeze(knownSledIds)

local sledCatalog: { [string]: SledCatalogEntry } = {
	FrostlineClassic = table.freeze({
		SledId = "FrostlineClassic",
		DisplayName = "FROSTLINE CLASSIC",
		Price = 0,
		ForSale = false,
		Description = "THE ORIGINAL CHRISTMAS SLED. CLASSIC HANDLING.",
	}),
	FrostRunner = table.freeze({
		SledId = "FrostRunner",
		DisplayName = "FROST RUNNER",
		Price = 250,
		ForSale = true,
		Description = "ARCTIC STYLE. CLASSIC HANDLING.\nA premium cosmetic sled with the same fair performance.",
	}),
}
table.freeze(sledCatalog)

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
		RampExitRollGuardEnabled = true,
		RampExitMaxRollRateRadiansPerSecond = math.rad(30),
		RampExitPitchGuardEnabled = true,
		RampExitMaxPitchRateRadiansPerSecond = math.rad(30),
		LaunchStabilityDiagnosticsEnabled = false,
		-- A stop is physical only after both measured speeds stay below these
		-- thresholds for the entire confirmation interval.
		LandingStopHorizontalSpeed = 0.5,
		LandingStopAngularSpeed = 0.5,
		LandingStopConfirmationDuration = 1.0,
		MaximumRunDuration = 45,
		SafetyBounds = {
			MaximumLateralDistance = 600,
			MinimumY = -150,
		},
	},

	Result = {
		CoinsPerDistanceStep = 1,
		DistanceStepMeters = 50,
		CleanLandingBonus = 10,
		CrashRewardMultiplier = 0.5,
		StalledReward = 0,
		MaximumCoinsPerRun = 50,
		ResultActionTimeoutSeconds = 20,
		MinimumCleanUprightDot = 0.65,
		TeleportToleranceStuds = 8,
		TeleportCharacterReadyTimeoutSeconds = 8,
		TeleportIntermediateVerificationSeconds = 0.25,
		TeleportFinalVerificationSeconds = 0.75,
		LifecycleDiagnosticsEnabled = false,
		RunTelemetryEnabled = false,
	},

	PlayerData = {
		SchemaVersion = 2,
		ProductionStoreName = "Frostline_PlayerProgress_v1",
		StudioStoreName = "Frostline_PlayerProgress_Studio_v1",
		KeyPrefix = "Player_",
		DefaultSledId = "FrostlineClassic",
		KnownSledIds = knownSledIds,
		AutosaveIntervalSeconds = 60,
		SessionLeaseDurationSeconds = 180,
		MaximumAttempts = 4,
		BaseRetryDelaySeconds = 1,
		LoadWaitTimeoutSeconds = 15,
		ShutdownTimeoutSeconds = 25,
		DiagnosticsEnabled = false,
	},

	Leaderboard = {
		BoardId = "FrozenLakeDistance",
		CourseId = "FrozenLakeV2",
		ProductionStoreName = "Frostline_GlobalDistance_v1",
		StudioStoreName = "Frostline_GlobalDistance_Studio_v1",
		Scope = "FrozenLakeDistance",
		KeyPrefix = "User_",
		ScoreScale = 10,
		MinimumEncodedScore = 1,
		MaximumEncodedScore = 18000,
		PageSize = 10,
		QueueCapacity = 256,
		WriteMaximumAttempts = 3,
		ReadMaximumAttempts = 2,
		RetryBaseDelaySeconds = 1,
		RetryMaximumDelaySeconds = 2,
		RetryJitterSeconds = 0.25,
		BudgetPollIntervalSeconds = 0.25,
		BudgetWaitMaximumSeconds = 5,
		RetryDeadlineSeconds = 12,
		MinimumWriteIntervalSeconds = 2.5,
		RefreshDebounceSeconds = 5,
		MinimumRefreshIntervalSeconds = 30,
		RefreshIntervalSeconds = 120,
		NameLookupConcurrency = 2,
		NameLookupBatchTimeoutSeconds = 5,
		UsernamePositiveCacheSeconds = 21600,
		UsernameFailureCacheSeconds = 300,
		UsernameCacheCapacity = 256,
		WarningIntervalSeconds = 60,
		Board = {
			FolderName = "Leaderboards",
			ModelName = "FrozenLakeDistanceBoard",
			BackboardName = "Backboard",
			SurfaceGuiName = "SurfaceGui",
			LocalPosition = Vector3.new(-49, 16, -15),
			Size = Vector3.new(30, 20, 0.8),
			PixelsPerStud = 40,
		},
	},

	Store = {
		CatalogVersion = 1,
		Catalog = sledCatalog,
		TokenBucketCapacity = 4,
		TokenRefillPerSecond = 2,
		MutationMinimumIntervalSeconds = 0.5,
		CompletedResponseLimit = 32,
		CompletedResponseRetentionSeconds = 120,
		CachedResponseMinimumIntervalSeconds = 0.1,
		InvalidWarningIntervalSeconds = 5,
		PendingTimeoutSeconds = 9,
		MaximumRequestIdLength = 36,
		MaximumSledIdLength = 64,
	},

	Audio = {
		DiagnosticsEnabled = false,
		PreloadTimeoutSeconds = 15,
		MusicFadeInSeconds = 1.5,
		ShortFadeSeconds = 0.12,
		TuckReplayCooldownSeconds = 0.45,
		SlideMovingThreshold = 2,
		SlideFullVolumeSpeed = 70,
		LakeSlideVolumeMultiplier = 0.45,

		Music = {
			IdleTarget = 0.06,
			CountdownTarget = 0.035,
			DescentTarget = 0.03,
			AirborneTarget = 0.025,
			LandedTarget = 0.03,
			ResultsTarget = 0.035,
			PriorityCueDuckTarget = 0.015,
			DuckAttackSeconds = 0.10,
			NormalReleaseSeconds = 0.55,
			CountdownDuckSeconds = 1.10,
			LaunchDuckSeconds = 0.70,
			TuckDuckSeconds = 0.45,
			ImpactDuckSeconds = 0.65,
			ResultDuckSeconds = 1.15,
			ButtonDuckSeconds = 0.25,
			SlideDuckMultiplier = 0.55,
		},

		Assets = {
			BackgroundMusic = "rbxassetid://9046740461", -- Winter Holidays, uploaded by APMOfficial
			SledSnowSlide = "rbxassetid://9125945654", -- Sign Slide Snow Large Plastic Real Estate Ty (SFX), uploaded by ProSoundEffects
			CountdownBeep = "rbxassetid://9117060548", -- Nasa Transmission Beep 4 (SFX), uploaded by ProSoundEffects
			LaunchWhoosh = "rbxassetid://9120629528", -- Web Whoosh Fast Heavy Swooshes 3 (SFX), uploaded by ProSoundEffects
			TuckWhoosh = "rbxassetid://9113080265", -- Airy Pass By Fast Breathing Rush Of Air 5 (SFX), uploaded by ProSoundEffects
			SnowImpact = "rbxassetid://9125965330", -- Snow Impact Big Hits Semi- Deep Stomping Jum (SFX), uploaded by ProSoundEffects
			CoinReward = "rbxassetid://127645268874265", -- CoinTransfer_01, uploaded by Roblox
			Victory = "rbxassetid://12222253", -- victory.wav, uploaded by Roblox
			Failure = "rbxassetid://12221944", -- bass.wav, uploaded by Roblox
			UIButton = "rbxassetid://12221967", -- button.wav, uploaded by Roblox
		},

		Volumes = {
			SledSnowSlide = 0.31,
			CountdownBeep = 0.32,
			LaunchWhoosh = 0.46,
			TuckWhoosh = 0.29,
			SnowImpact = 0.44,
			CoinReward = 0.32,
			Victory = 0.36,
			Failure = 0.32,
			UIButton = 0.22,
		},
	},

	Presentation = {
		DiagnosticsEnabled = false,

		Snowfall = {
			Far = {
				DesktopRate = 36,
				MobileRate = 18,
				CameraOffset = Vector3.new(0, 13, -9),
				RegionSize = Vector3.new(44, 2, 32),
			},
			Near = {
				DesktopRate = 12,
				MobileRate = 6,
				CameraOffset = Vector3.new(0, 8, -5),
				RegionSize = Vector3.new(28, 2, 20),
			},
		},

		Trails = {
			BroadLifetime = 0.34,
			HighlightLifetime = 0.21,
			MinimumSpeed = 3,
			FullStrengthSpeed = 70,
			BroadWidth = 0.36,
			HighlightWidth = 0.065,
			TuckStrengthBonus = 0.18,
			LakeStrengthMultiplier = 0.62,
			LandingBoostDuration = 0.58,
		},

		SnowSpray = {
			MinimumSpeed = 8,
			FullRateSpeed = 70,
			DesktopMaximumRate = 54,
			MobileMaximumRate = 28,
			Lifetime = NumberRange.new(0.32, 0.48),
			GroundRayDistance = 4.5,
		},

		TuckStreaks = {
			DesktopRate = 36,
			MobileRate = 19,
			Lifetime = NumberRange.new(0.26, 0.38),
		},

		Bursts = {
			DesktopLaunch = 48,
			MobileLaunch = 26,
			DesktopLanding = 66,
			MobileLanding = 38,
			DesktopCrash = 82,
			MobileCrash = 46,
			LaunchLifetime = NumberRange.new(0.38, 0.50),
			LandingLifetime = NumberRange.new(0.50, 0.68),
			CrashLifetime = NumberRange.new(0.55, 0.72),
		},

		WinterGrade = {
			BloomIntensity = 0.15,
			BloomThreshold = 1.2,
			BloomSize = 22,
			Brightness = -0.01,
			Contrast = 0.07,
			Saturation = 0.02,
			TintColor = Color3.fromRGB(239, 248, 255),
		},
	},

	Camera = {
		NormalFieldOfView = 70,
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
