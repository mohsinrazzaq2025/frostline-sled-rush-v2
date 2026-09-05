--!strict

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local PlayerDataTypes = require(ReplicatedStorage.Shared.PlayerDataTypes)
local StoreTypes = require(ReplicatedStorage.Shared.StoreTypes)

local DATA = GameConfig.PlayerData
local STORE = GameConfig.Store
local PERSISTENCE = PlayerDataTypes.PersistenceStatuses
local STORE_PERSISTENCE = StoreTypes.PersistenceStates
local STORE_STATUS = StoreTypes.StatusCodes
local DEFAULT_SLED_ID = DATA.DefaultSledId
local KNOWN_SLED_IDS = DATA.KnownSledIds
local OPERATION_POLL_INTERVAL = 0.05
local MAXIMUM_SAFE_INTEGER = 9007199254740991

type PersistenceStatus = PlayerDataTypes.PersistenceStatus
type OwnedSleds = PlayerDataTypes.OwnedSleds
type PlayerProgress = PlayerDataTypes.PlayerProgress
type ProgressSnapshot = PlayerDataTypes.ProgressSnapshot
type RewardUpdate = PlayerDataTypes.RewardUpdate
type StorePersistenceState = StoreTypes.PersistenceState
type StoreStatusCode = StoreTypes.StatusCode
type CatalogEntry = StoreTypes.CatalogEntry
type LoadState = "Loading" | "Persistent" | "SessionOnly" | "Releasing" | "Released"
type StoreMutationAction = "Purchase" | "Equip"
type ReservationValidator = () -> boolean

export type StoreProfileSnapshot = {
	Generation: number,
	DataRevision: number,
	PersistenceState: StorePersistenceState,
	FrostCoins: number,
	OwnedSleds: OwnedSleds,
	EquippedSledId: string,
}

export type StoreMutationResult = {
	StatusCode: StoreStatusCode,
	Snapshot: StoreProfileSnapshot?,
	InternalReason: string?,
}

type StoredSession = {
	Id: string,
	UpdatedAt: number,
}

type StoredEnvelope = {
	SchemaVersion: number,
	Data: {
		FrostCoins: number,
		BestDistance: number,
		OwnedSleds: OwnedSleds,
		EquippedSledId: string,
	},
	Session: StoredSession?,
	UpdatedAt: number,
}

type KeyOperationToken = {
	Id: number,
}

type KeyOperationQueue = {
	Active: boolean,
	NextId: number,
	Waiting: { KeyOperationToken },
}

type ProfileSession = {
	Player: Player,
	Key: string,
	SessionId: string,
	Generation: number,
	State: LoadState,
	Progress: PlayerProgress,
	Saveable: boolean,
	Dirty: boolean,
	Revision: number,
	LastSavedRevision: number,
	ReleaseStarted: boolean,
	ReleaseWorkerActive: boolean,
	ReleaseFinished: boolean,
	ReleaseSucceeded: boolean,
	SavePending: boolean,
	StoreSaveUnresolved: boolean,
	FallbackWarned: boolean,
	OwnershipWarningEmitted: boolean,
	ConsecutiveSaveFailures: number,
}

type SaveAttemptResult = {
	Saved: boolean,
	Reason: string,
	UnsafeToSave: boolean,
}

type LoadAttemptResult = {
	Loaded: boolean,
	Progress: PlayerProgress?,
	Reason: string,
}

type BeforePlayerRelease = (Player) -> ()

local PlayerDataService = {}

local selectedStoreName = if RunService:IsStudio()
	then DATA.StudioStoreName
	else DATA.ProductionStoreName
local progressStore = DataStoreService:GetDataStore(selectedStoreName)

local profiles: { [Player]: ProfileSession } = {}
local keyOperationQueues: { [string]: KeyOperationQueue } = {}
local removalCoordinated: { [Player]: boolean } = {}
local beforePlayerRelease: BeforePlayerRelease? = nil
local started = false
local shuttingDown = false
local latestProfileGeneration = 0

local function isFiniteNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function isNonNegativeInteger(value: any): boolean
	return isFiniteNumber(value) and value >= 0 and value % 1 == 0
end

local function isSafeNonNegativeInteger(value: any): boolean
	return isNonNegativeInteger(value) and value <= MAXIMUM_SAFE_INTEGER
end

local function createDefaultOwnedSleds(): OwnedSleds
	return {
		[DEFAULT_SLED_ID] = true,
	}
end

local function copyOwnedSleds(source: OwnedSleds): OwnedSleds
	local copied: OwnedSleds = {}
	for sledId in KNOWN_SLED_IDS do
		if source[sledId] == true then
			copied[sledId] = true
		end
	end
	copied[DEFAULT_SLED_ID] = true
	return copied
end

local function normalizeOwnedSleds(value: any): OwnedSleds
	local normalized = createDefaultOwnedSleds()
	if typeof(value) ~= "table" then
		return normalized
	end

	for sledId in KNOWN_SLED_IDS do
		if value[sledId] == true then
			normalized[sledId] = true
		end
	end
	normalized[DEFAULT_SLED_ID] = true
	return normalized
end

local function normalizeEquippedSledId(value: any, ownedSleds: OwnedSleds): string
	if typeof(value) == "string"
		and KNOWN_SLED_IDS[value] == true
		and ownedSleds[value] == true
	then
		return value
	end
	return DEFAULT_SLED_ID
end

local function createDefaultProgress(): PlayerProgress
	return {
		SchemaVersion = DATA.SchemaVersion,
		FrostCoins = 0,
		BestDistance = 0,
		OwnedSleds = createDefaultOwnedSleds(),
		EquippedSledId = DEFAULT_SLED_ID,
	}
end

local function copyProgress(progress: PlayerProgress): PlayerProgress
	return {
		SchemaVersion = DATA.SchemaVersion,
		FrostCoins = progress.FrostCoins,
		BestDistance = progress.BestDistance,
		OwnedSleds = copyOwnedSleds(progress.OwnedSleds),
		EquippedSledId = progress.EquippedSledId,
	}
end

local function createFrozenProgressCopy(progress: PlayerProgress): PlayerProgress
	local copied = copyProgress(progress)
	table.freeze(copied.OwnedSleds)
	return table.freeze(copied)
end

local function getPlayerKey(player: Player): string
	return DATA.KeyPrefix .. tostring(player.UserId)
end

local function createSessionId(player: Player): string
	local jobId = if game.JobId == "" then "Studio" else game.JobId
	return string.format("%s:%d:%s", jobId, player.UserId, HttpService:GenerateGUID(false))
end

local function diagnostic(entry: ProfileSession, event: string, detail: string)
	if not DATA.DiagnosticsEnabled then
		return
	end
	print(
		string.format(
			"[Frostline][Data] player=%s UserId=%d event=%s %s",
			entry.Player.Name,
			entry.Player.UserId,
			event,
			detail
		)
	)
end

local function warnFallback(entry: ProfileSession, reason: string)
	if entry.FallbackWarned then
		return
	end
	entry.FallbackWarned = true
	warn(
		string.format(
			"[Frostline][Data] Progress will not save for player=%s UserId=%d reason=%s",
			entry.Player.Name,
			entry.Player.UserId,
			reason
		)
	)
end

local function readStoredSession(value: any): (StoredSession?, string?)
	if value == nil then
		return nil, nil
	end
	if typeof(value) ~= "table" then
		return nil, "session lease is not a table"
	end
	if typeof(value.Id) ~= "string" or value.Id == "" then
		return nil, "session lease ID is invalid"
	end
	if not isNonNegativeInteger(value.UpdatedAt) then
		return nil, "session lease timestamp is invalid"
	end
	return {
		Id = value.Id,
		UpdatedAt = value.UpdatedAt,
	}, nil
end

-- This is intentionally pure: it never mutates the supplied value or performs I/O.
-- Missing legacy fields receive defaults, while malformed or future data is rejected.
local function reconcileProfile(rawValue: any): (PlayerProgress?, StoredSession?, string?)
	if rawValue == nil then
		return createDefaultProgress(), nil, nil
	end
	if typeof(rawValue) ~= "table" then
		return nil, nil, "stored record is not a table"
	end

	local schemaVersion = rawValue.SchemaVersion
	if schemaVersion == nil then
		schemaVersion = 0
	elseif not isNonNegativeInteger(schemaVersion) then
		return nil, nil, "schema version is invalid"
	end
	if schemaVersion > DATA.SchemaVersion then
		return nil, nil, string.format("unsupported schema version %d", schemaVersion)
	end

	local dataSource: any = rawValue
	if rawValue.Data ~= nil then
		if typeof(rawValue.Data) ~= "table" then
			return nil, nil, "stored progression data is not a table"
		end
		dataSource = rawValue.Data
	end

	local frostCoins = dataSource.FrostCoins
	if frostCoins == nil then
		frostCoins = 0
	elseif not isNonNegativeInteger(frostCoins) then
		return nil, nil, "stored Frost Coins are invalid"
	end

	local bestDistance = dataSource.BestDistance
	if bestDistance == nil then
		bestDistance = 0
	elseif not isFiniteNumber(bestDistance) or bestDistance < 0 then
		return nil, nil, "stored Best Distance is invalid"
	end
	local ownedSleds = createDefaultOwnedSleds()
	local equippedSledId = DEFAULT_SLED_ID
	if schemaVersion == DATA.SchemaVersion then
		ownedSleds = normalizeOwnedSleds(dataSource.OwnedSleds)
		equippedSledId = normalizeEquippedSledId(dataSource.EquippedSledId, ownedSleds)
	end

	if rawValue.UpdatedAt ~= nil and not isNonNegativeInteger(rawValue.UpdatedAt) then
		return nil, nil, "record timestamp is invalid"
	end
	local storedSession, sessionError = readStoredSession(rawValue.Session)
	if sessionError then
		return nil, nil, sessionError
	end

	return {
		SchemaVersion = DATA.SchemaVersion,
		FrostCoins = frostCoins,
		BestDistance = bestDistance,
		OwnedSleds = ownedSleds,
		EquippedSledId = equippedSledId,
	}, storedSession, nil
end

local function createEnvelope(progress: PlayerProgress, sessionId: string?, updatedAt: number): StoredEnvelope
	local envelope: StoredEnvelope = {
		SchemaVersion = DATA.SchemaVersion,
		Data = {
			FrostCoins = progress.FrostCoins,
			BestDistance = progress.BestDistance,
			OwnedSleds = copyOwnedSleds(progress.OwnedSleds),
			EquippedSledId = progress.EquippedSledId,
		},
		Session = nil,
		UpdatedAt = updatedAt,
	}
	if sessionId then
		envelope.Session = {
			Id = sessionId,
			UpdatedAt = updatedAt,
		}
	end
	return envelope
end

local function getKeyOperationQueue(key: string): KeyOperationQueue
	local existing = keyOperationQueues[key]
	if existing then
		return existing
	end
	local created: KeyOperationQueue = {
		Active = false,
		NextId = 0,
		Waiting = {},
	}
	keyOperationQueues[key] = created
	return created
end

local function acquireKeyOperation(key: string): (KeyOperationQueue, KeyOperationToken)
	local queue = getKeyOperationQueue(key)
	queue.NextId += 1
	local token: KeyOperationToken = {
		Id = queue.NextId,
	}
	table.insert(queue.Waiting, token)

	while queue.Active or queue.Waiting[1] ~= token do
		task.wait(OPERATION_POLL_INTERVAL)
	end
	queue.Active = true
	return queue, token
end

local function releaseKeyOperation(key: string, queue: KeyOperationQueue, token: KeyOperationToken)
	if queue.Waiting[1] ~= token then
		warn(string.format("[Frostline][Data] Ordered-operation queue mismatch key=%s", key))
		local tokenIndex = table.find(queue.Waiting, token)
		if tokenIndex then
			table.remove(queue.Waiting, tokenIndex)
		end
	else
		table.remove(queue.Waiting, 1)
	end
	queue.Active = false
	if #queue.Waiting == 0 and keyOperationQueues[key] == queue then
		keyOperationQueues[key] = nil
	end
end

local function waitForRetry(entry: ProfileSession, operation: string, attempt: number, reason: string): boolean
	if attempt >= DATA.MaximumAttempts or entry.ReleaseStarted or shuttingDown then
		return false
	end
	local delaySeconds = DATA.BaseRetryDelaySeconds * (2 ^ (attempt - 1))
	if DATA.DiagnosticsEnabled then
		diagnostic(
			entry,
			operation .. "-retry",
			string.format("attempt=%d delay=%.1f reason=%s", attempt, delaySeconds, reason)
		)
	end
	task.wait(delaySeconds)
	return not entry.ReleaseStarted and not shuttingDown and profiles[entry.Player] == entry
end

local function canContinueLoading(entry: ProfileSession): boolean
	return profiles[entry.Player] == entry
		and entry.State == "Loading"
		and not entry.ReleaseStarted
		and not shuttingDown
		and entry.Player.Parent == Players
end

local function loadWithRetries(entry: ProfileSession): LoadAttemptResult
	local lastReason = "load attempts exhausted"
	for attempt = 1, DATA.MaximumAttempts do
		if not canContinueLoading(entry) then
			return {
				Loaded = false,
				Progress = nil,
				Reason = "load cancelled because the player left",
			}
		end

		local decision = "unknown"
		local decisionReason = "UpdateAsync returned no decision"
		local callSucceeded, returnedValue = pcall(function()
			return progressStore:UpdateAsync(entry.Key, function(currentValue: any): any
				if not canContinueLoading(entry) then
					decision = "cancelled"
					decisionReason = "player lifecycle changed during load"
					return nil
				end

				local progress, storedSession, reconcileError = reconcileProfile(currentValue)
				if not progress then
					decision = "invalid-data"
					decisionReason = reconcileError or "stored profile is invalid"
					return nil
				end

				local now = os.time()
				if storedSession and storedSession.Id ~= entry.SessionId then
					local leaseAge = now - storedSession.UpdatedAt
					if leaseAge < DATA.SessionLeaseDurationSeconds then
						decision = "active-lock"
						decisionReason = "another live server owns the session lease"
						return nil
					end
				end

				decision = "acquired"
				decisionReason = "session lease acquired"
				return createEnvelope(progress, entry.SessionId, now)
			end)
		end)

		if callSucceeded and decision == "acquired" and returnedValue ~= nil then
			local returnedProgress, returnedSession, verifyError = reconcileProfile(returnedValue)
			if returnedProgress and returnedSession and returnedSession.Id == entry.SessionId then
				if DATA.DiagnosticsEnabled then
					diagnostic(entry, "load-succeeded", string.format("attempt=%d", attempt))
				end
				return {
					Loaded = true,
					Progress = returnedProgress,
					Reason = "loaded",
				}
			end
			lastReason = verifyError or "lease ownership could not be verified"
		elseif callSucceeded then
			lastReason = decisionReason
			if decision == "invalid-data" or decision == "cancelled" then
				break
			end
		else
			lastReason = "DataStore API error: " .. tostring(returnedValue)
		end

		if not waitForRetry(entry, "load", attempt, lastReason) then
			break
		end
	end

	return {
		Loaded = false,
		Progress = nil,
		Reason = lastReason,
	}
end

local function installFallback(entry: ProfileSession, reason: string, shouldWarn: boolean)
	entry.Progress = createDefaultProgress()
	entry.State = "SessionOnly"
	entry.Saveable = false
	entry.Dirty = false
	entry.Revision = 0
	entry.LastSavedRevision = 0
	entry.StoreSaveUnresolved = false
	if shouldWarn then
		warnFallback(entry, reason)
	end
end

local function loadEntry(entry: ProfileSession)
	local queue, token = acquireKeyOperation(entry.Key)
	local operationSucceeded, result = pcall(function(): LoadAttemptResult
		return loadWithRetries(entry)
	end)
	releaseKeyOperation(entry.Key, queue, token)

	if profiles[entry.Player] ~= entry or entry.State ~= "Loading" then
		return
	end
	if operationSucceeded and result.Loaded and result.Progress then
		entry.Progress = result.Progress
		entry.State = "Persistent"
		entry.Saveable = true
		entry.Dirty = false
		entry.Revision = 0
		entry.LastSavedRevision = 0
		entry.StoreSaveUnresolved = false
	else
		local failureReason = if operationSucceeded then result.Reason else tostring(result)
		local playerStillActive = entry.Player.Parent == Players and not entry.ReleaseStarted and not shuttingDown
		installFallback(entry, failureReason, playerStillActive)
	end

	if entry.Player.Parent ~= Players then
		entry.ReleaseStarted = true
	end
	if entry.ReleaseStarted then
		task.defer(function()
			PlayerDataService.saveAndRelease(entry.Player)
		end)
	end
end

local function beginLoading(player: Player)
	if shuttingDown or profiles[player] then
		return
	end
	latestProfileGeneration += 1
	local entry: ProfileSession = {
		Player = player,
		Key = getPlayerKey(player),
		SessionId = createSessionId(player),
		Generation = latestProfileGeneration,
		State = "Loading",
		Progress = createDefaultProgress(),
		Saveable = false,
		Dirty = false,
		Revision = 0,
		LastSavedRevision = 0,
		ReleaseStarted = false,
		ReleaseWorkerActive = false,
		ReleaseFinished = false,
		ReleaseSucceeded = false,
		SavePending = false,
		StoreSaveUnresolved = false,
		FallbackWarned = false,
		OwnershipWarningEmitted = false,
		ConsecutiveSaveFailures = 0,
	}
	profiles[player] = entry
	task.spawn(loadEntry, entry)
end

local function getPersistenceStatus(entry: ProfileSession): PersistenceStatus
	return if entry.Saveable and entry.State == "Persistent"
		then PERSISTENCE.Persistent
		else PERSISTENCE.SessionOnly
end

local function createSnapshot(entry: ProfileSession): ProgressSnapshot
	local ownedSleds = copyOwnedSleds(entry.Progress.OwnedSleds)
	table.freeze(ownedSleds)
	return table.freeze({
		SchemaVersion = DATA.SchemaVersion,
		FrostCoins = entry.Progress.FrostCoins,
		BestDistance = entry.Progress.BestDistance,
		OwnedSleds = ownedSleds,
		EquippedSledId = entry.Progress.EquippedSledId,
		PersistenceStatus = getPersistenceStatus(entry),
	})
end

local function getStorePersistenceState(entry: ProfileSession): StorePersistenceState
	if entry.State == "Loading" then
		return STORE_PERSISTENCE.Loading
	elseif entry.ReleaseStarted or entry.State == "Releasing" or entry.State == "Released" then
		return STORE_PERSISTENCE.Releasing
	elseif entry.State == "SessionOnly" or not entry.Saveable then
		return STORE_PERSISTENCE.SessionOnly
	elseif entry.StoreSaveUnresolved or entry.SavePending then
		return STORE_PERSISTENCE.SavePending
	end
	return STORE_PERSISTENCE.Persistent
end

local function createStoreProfileSnapshot(entry: ProfileSession): StoreProfileSnapshot
	local ownedSleds = copyOwnedSleds(entry.Progress.OwnedSleds)
	table.freeze(ownedSleds)
	return table.freeze({
		Generation = entry.Generation,
		DataRevision = entry.Revision,
		PersistenceState = getStorePersistenceState(entry),
		FrostCoins = entry.Progress.FrostCoins,
		OwnedSleds = ownedSleds,
		EquippedSledId = entry.Progress.EquippedSledId,
	})
end

local function createStoreMutationResult(
	entry: ProfileSession?,
	statusCode: StoreStatusCode,
	internalReason: string?
): StoreMutationResult
	local snapshot: StoreProfileSnapshot? = nil
	if entry and profiles[entry.Player] == entry then
		snapshot = createStoreProfileSnapshot(entry)
	end
	return table.freeze({
		StatusCode = statusCode,
		Snapshot = snapshot,
		InternalReason = internalReason,
	})
end

local function reservationIsCurrent(validateReservation: ReservationValidator): boolean
	local callSucceeded, reservationCurrent = pcall(validateReservation)
	return callSucceeded and reservationCurrent == true
end

local function ownedSledsMatch(left: OwnedSleds, right: OwnedSleds): boolean
	if left[DEFAULT_SLED_ID] ~= true or right[DEFAULT_SLED_ID] ~= true then
		return false
	end
	for sledId in KNOWN_SLED_IDS do
		if left[sledId] ~= right[sledId] then
			return false
		end
	end
	return true
end

local function profilesMatch(left: PlayerProgress, right: PlayerProgress): boolean
	return left.SchemaVersion == right.SchemaVersion
		and left.FrostCoins == right.FrostCoins
		and left.BestDistance == right.BestDistance
		and ownedSledsMatch(left.OwnedSleds, right.OwnedSleds)
		and left.EquippedSledId == right.EquippedSledId
end

local function saveWithRetries(
	entry: ProfileSession,
	snapshot: PlayerProgress,
	releaseLease: boolean,
	operation: string
): SaveAttemptResult
	local lastReason = operation .. " attempts exhausted"
	local ambiguousFailureOccurred = false
	for attempt = 1, DATA.MaximumAttempts do
		local decision = "unknown"
		local decisionReason = "UpdateAsync returned no decision"
		local callSucceeded, returnedValue = pcall(function()
			return progressStore:UpdateAsync(entry.Key, function(currentValue: any): any
				local currentProgress, storedSession, reconcileError = reconcileProfile(currentValue)
				if reconcileError then
					decision = "invalid-data"
					decisionReason = reconcileError
					return nil
				end
				if not storedSession then
					if releaseLease
						and ambiguousFailureOccurred
						and currentProgress ~= nil
						and profilesMatch(currentProgress, snapshot)
					then
						decision = "already-released"
						decisionReason = "an earlier release attempt already saved the profile and removed the lease"
					else
						decision = "missing-lock"
						decisionReason = "the stored session lease is missing"
					end
					return nil
				end
				if storedSession.Id ~= entry.SessionId then
					decision = "foreign-lock"
					decisionReason = "another server owns the stored session lease"
					return nil
				end

				decision = "written"
				decisionReason = "profile written"
				return createEnvelope(snapshot, if releaseLease then nil else entry.SessionId, os.time())
			end)
		end)

		if callSucceeded and decision == "written" and returnedValue ~= nil then
			local returnedProgress, returnedSession, verifyError = reconcileProfile(returnedValue)
			local sessionMatches = if releaseLease
				then returnedSession == nil
				else returnedSession ~= nil and returnedSession.Id == entry.SessionId
			if returnedProgress and profilesMatch(returnedProgress, snapshot) and sessionMatches then
				return {
					Saved = true,
					Reason = "saved",
					UnsafeToSave = false,
				}
			end
			lastReason = verifyError or "saved profile could not be verified"
		elseif callSucceeded and decision == "already-released" then
			return {
				Saved = true,
				Reason = decisionReason,
				UnsafeToSave = false,
			}
		elseif callSucceeded then
			lastReason = decisionReason
			if decision == "invalid-data" or decision == "missing-lock" or decision == "foreign-lock" then
				return {
					Saved = false,
					Reason = lastReason,
					UnsafeToSave = true,
				}
			end
		else
			ambiguousFailureOccurred = true
			lastReason = "DataStore API error: " .. tostring(returnedValue)
		end

		if attempt < DATA.MaximumAttempts then
			local delaySeconds = DATA.BaseRetryDelaySeconds * (2 ^ (attempt - 1))
			if DATA.DiagnosticsEnabled then
				diagnostic(
					entry,
					operation .. "-retry",
					string.format("attempt=%d delay=%.1f reason=%s", attempt, delaySeconds, lastReason)
				)
			end
			task.wait(delaySeconds)
		end
	end

	return {
		Saved = false,
		Reason = lastReason,
		UnsafeToSave = false,
	}
end

local function markUnsafeToSave(entry: ProfileSession, reason: string)
	entry.Saveable = false
	if entry.State ~= "Releasing" and entry.State ~= "Released" then
		entry.State = "SessionOnly"
	end
	if not entry.OwnershipWarningEmitted then
		entry.OwnershipWarningEmitted = true
		warn(
			string.format(
				"[Frostline][Data] Saving disabled for player=%s UserId=%d reason=%s",
				entry.Player.Name,
				entry.Player.UserId,
				reason
			)
		)
	end
end

local function performStoreMutation(
	player: Player,
	action: StoreMutationAction,
	sledId: string,
	expectedRevision: number,
	expectedGeneration: number,
	validateReservation: ReservationValidator
): StoreMutationResult
	local catalog = STORE.Catalog :: { [string]: CatalogEntry }

	local function validateContext(allowReservedSaveWorker: boolean): (
		ProfileSession?,
		CatalogEntry?,
		StoreStatusCode?,
		string?
	)
		if not started or shuttingDown or player.Parent ~= Players then
			return nil, nil, STORE_STATUS.StoreUnavailable, "player or service lifecycle is unavailable"
		elseif not isSafeNonNegativeInteger(expectedGeneration) then
			return nil, nil, STORE_STATUS.StateChanged, "profile generation is invalid"
		elseif not isSafeNonNegativeInteger(expectedRevision) then
			return nil, nil, STORE_STATUS.StateChanged, "data revision is invalid"
		elseif typeof(sledId) ~= "string" then
			return nil, nil, STORE_STATUS.UnknownSled, "sled ID is invalid"
		end

		local entry = profiles[player]
		if not entry then
			return nil, nil, STORE_STATUS.ProfileLoading, "profile is unavailable"
		elseif entry.Generation ~= expectedGeneration then
			return entry, nil, STORE_STATUS.StateChanged, "profile generation changed"
		elseif entry.ReleaseStarted or entry.State == "Releasing" or entry.State == "Released" then
			return entry, nil, STORE_STATUS.StoreUnavailable, "profile release is in progress"
		elseif entry.State == "Loading" then
			return entry, nil, STORE_STATUS.ProfileLoading, "profile is still loading"
		elseif entry.State == "SessionOnly" or not entry.Saveable then
			return entry, nil, STORE_STATUS.PersistenceUnavailable, "persistent profile is unavailable"
		elseif entry.StoreSaveUnresolved then
			return entry, nil, STORE_STATUS.SavePending, "a Store save is unresolved"
		elseif entry.SavePending and not allowReservedSaveWorker then
			return entry, nil, STORE_STATUS.SavePending, "a profile save is already in progress"
		elseif entry.Revision ~= expectedRevision then
			return entry, nil, STORE_STATUS.StateChanged, "data revision changed"
		elseif entry.Revision >= MAXIMUM_SAFE_INTEGER then
			return entry, nil, STORE_STATUS.InternalError, "data revision cannot be incremented safely"
		end

		local catalogEntry = catalog[sledId]
		if not catalogEntry or KNOWN_SLED_IDS[sledId] ~= true or catalogEntry.SledId ~= sledId then
			return entry, nil, STORE_STATUS.UnknownSled, "sled ID is not in the authoritative catalog"
		end

		if action == "Purchase" then
			if not catalogEntry.ForSale then
				return entry, catalogEntry, STORE_STATUS.NotForSale, "sled is not for sale"
			elseif not isNonNegativeInteger(catalogEntry.Price) then
				return entry, catalogEntry, STORE_STATUS.InternalError, "catalog price is invalid"
			elseif entry.Progress.OwnedSleds[sledId] == true then
				return entry, catalogEntry, STORE_STATUS.AlreadyOwned, nil
			elseif not isNonNegativeInteger(entry.Progress.FrostCoins) then
				return entry, catalogEntry, STORE_STATUS.InternalError, "authoritative balance is invalid"
			elseif entry.Progress.FrostCoins < catalogEntry.Price then
				return entry, catalogEntry, STORE_STATUS.InsufficientFunds, nil
			end
		else
			if entry.Progress.OwnedSleds[sledId] ~= true then
				return entry, catalogEntry, STORE_STATUS.NotOwned, nil
			elseif entry.Progress.EquippedSledId == sledId then
				return entry, catalogEntry, STORE_STATUS.AlreadyEquipped, nil
			end
		end

		if not reservationIsCurrent(validateReservation) then
			return entry, catalogEntry, STORE_STATUS.Busy, "Store operation reservation changed"
		end
		return entry, catalogEntry, nil, nil
	end

	local entry, _, initialStatus, initialReason = validateContext(false)
	if initialStatus then
		return createStoreMutationResult(entry, initialStatus, initialReason)
	end
	if not entry then
		return createStoreMutationResult(nil, STORE_STATUS.InternalError, "validated profile is unavailable")
	end

	-- This flag synchronously prevents autosave from entering the ordered queue
	-- between validation and this Store operation's queue acquisition.
	entry.SavePending = true
	local queue, token = acquireKeyOperation(entry.Key)

	local currentEntry, catalogEntry, queuedStatus, queuedReason = validateContext(true)
	if queuedStatus or currentEntry ~= entry or not catalogEntry then
		releaseKeyOperation(entry.Key, queue, token)
		entry.SavePending = false
		return createStoreMutationResult(
			currentEntry,
			queuedStatus or STORE_STATUS.StateChanged,
			queuedReason or "profile changed while waiting for the ordered save queue"
		)
	end

	-- The reservation validator above is the final operation before this
	-- non-yielding candidate construction and coherent live-profile mutation.
	local candidate = copyProgress(entry.Progress)
	if action == "Purchase" then
		candidate.FrostCoins -= catalogEntry.Price
		candidate.OwnedSleds[sledId] = true
	else
		candidate.EquippedSledId = sledId
	end
	local capturedRevision = entry.Revision + 1
	entry.Progress = candidate
	entry.Revision = capturedRevision
	entry.Dirty = true
	entry.StoreSaveUnresolved = true

	local capturedProgress = createFrozenProgressCopy(candidate)
	local operationSucceeded, saveResult = pcall(function(): SaveAttemptResult
		return saveWithRetries(entry, capturedProgress, false, "store-" .. string.lower(action))
	end)
	releaseKeyOperation(entry.Key, queue, token)
	entry.SavePending = false

	if operationSucceeded and saveResult.Saved then
		entry.ConsecutiveSaveFailures = 0
		entry.LastSavedRevision = math.max(entry.LastSavedRevision, capturedRevision)
		local currentCandidateMatches = entry.Revision == capturedRevision
			and profilesMatch(entry.Progress, capturedProgress)
		if currentCandidateMatches then
			entry.Dirty = false
			entry.StoreSaveUnresolved = false
		end
		if profiles[player] ~= entry or entry.Generation ~= expectedGeneration then
			return createStoreMutationResult(nil, STORE_STATUS.StoreUnavailable, "profile changed after Store save")
		end
		if not currentCandidateMatches then
			entry.Dirty = true
			entry.StoreSaveUnresolved = true
			return createStoreMutationResult(
				entry,
				STORE_STATUS.SavePending,
				"newer profile data remains unverified after Store save"
			)
		end
		return createStoreMutationResult(entry, STORE_STATUS.Success, nil)
	end

	entry.ConsecutiveSaveFailures += 1
	if operationSucceeded and saveResult.UnsafeToSave then
		markUnsafeToSave(entry, saveResult.Reason)
		return createStoreMutationResult(entry, STORE_STATUS.PersistenceUnavailable, saveResult.Reason)
	end

	local failureReason = if operationSucceeded
		then saveResult.Reason
		else "Store save worker failed"
	return createStoreMutationResult(entry, STORE_STATUS.SavePending, failureReason)
end

local function runAutosave(entry: ProfileSession)
	if profiles[entry.Player] ~= entry
		or entry.State ~= "Persistent"
		or not entry.Saveable
		or entry.ReleaseStarted
	then
		entry.SavePending = false
		return
	end

	local queue, token = acquireKeyOperation(entry.Key)
	if profiles[entry.Player] ~= entry
		or entry.State ~= "Persistent"
		or not entry.Saveable
		or entry.ReleaseStarted
	then
		releaseKeyOperation(entry.Key, queue, token)
		entry.SavePending = false
		return
	end

	local capturedRevision = entry.Revision
	local capturedProgress = createFrozenProgressCopy(entry.Progress)
	local operationSucceeded, result = pcall(function(): SaveAttemptResult
		return saveWithRetries(entry, capturedProgress, false, "autosave")
	end)
	releaseKeyOperation(entry.Key, queue, token)
	entry.SavePending = false

	if profiles[entry.Player] ~= entry or entry.State == "Released" then
		return
	end
	if not operationSucceeded then
		entry.ConsecutiveSaveFailures += 1
		warn(
			string.format(
				"[Frostline][Data] Autosave failed for player=%s UserId=%d reason=%s",
				entry.Player.Name,
				entry.Player.UserId,
				tostring(result)
			)
		)
		return
	end
	if result.UnsafeToSave then
		markUnsafeToSave(entry, result.Reason)
		return
	end
	if not result.Saved then
		entry.ConsecutiveSaveFailures += 1
		warn(
			string.format(
				"[Frostline][Data] Autosave exhausted retries for player=%s UserId=%d failures=%d reason=%s",
				entry.Player.Name,
				entry.Player.UserId,
				entry.ConsecutiveSaveFailures,
				result.Reason
			)
		)
		return
	end

	entry.ConsecutiveSaveFailures = 0
	entry.LastSavedRevision = math.max(entry.LastSavedRevision, capturedRevision)
	if entry.Revision == capturedRevision and profilesMatch(entry.Progress, capturedProgress) then
		entry.Dirty = false
		entry.StoreSaveUnresolved = false
	end
	if DATA.DiagnosticsEnabled then
		diagnostic(entry, "autosave-succeeded", string.format("revision=%d", capturedRevision))
	end
end

local function finishRelease(entry: ProfileSession, succeeded: boolean)
	entry.Saveable = false
	entry.Dirty = false
	entry.StoreSaveUnresolved = false
	entry.State = "Released"
	entry.ReleaseSucceeded = succeeded
	entry.ReleaseFinished = true
	entry.ReleaseWorkerActive = false
	if profiles[entry.Player] == entry then
		profiles[entry.Player] = nil
	end
	removalCoordinated[entry.Player] = nil
	if DATA.DiagnosticsEnabled then
		diagnostic(entry, "release-completed", string.format("saved=%s", tostring(succeeded)))
	end
end

local function performRelease(entry: ProfileSession): boolean
	while profiles[entry.Player] == entry and entry.State == "Loading" do
		task.wait(OPERATION_POLL_INTERVAL)
	end
	if profiles[entry.Player] ~= entry then
		entry.ReleaseFinished = true
		entry.ReleaseSucceeded = true
		entry.ReleaseWorkerActive = false
		return true
	end
	if entry.State == "SessionOnly" or not entry.Saveable then
		finishRelease(entry, true)
		return true
	end

	entry.State = "Releasing"
	local queue, token = acquireKeyOperation(entry.Key)
	local capturedRevision = entry.Revision
	local capturedProgress = createFrozenProgressCopy(entry.Progress)
	local operationSucceeded, result = pcall(function(): SaveAttemptResult
		return saveWithRetries(entry, capturedProgress, true, "final-save")
	end)
	releaseKeyOperation(entry.Key, queue, token)

	local saved = operationSucceeded and result.Saved
	if not operationSucceeded then
		warn(
			string.format(
				"[Frostline][Data] Final save failed for player=%s UserId=%d reason=%s",
				entry.Player.Name,
				entry.Player.UserId,
				tostring(result)
			)
		)
	elseif result.UnsafeToSave then
		markUnsafeToSave(entry, result.Reason)
	elseif not result.Saved then
		warn(
			string.format(
				"[Frostline][Data] Final save exhausted retries for player=%s UserId=%d reason=%s",
				entry.Player.Name,
				entry.Player.UserId,
				result.Reason
			)
		)
	else
		entry.LastSavedRevision = capturedRevision
		entry.Dirty = false
	end

	finishRelease(entry, saved)
	return saved
end

local function coordinatePlayerRemoval(player: Player)
	if removalCoordinated[player] then
		return
	end
	removalCoordinated[player] = true
	local callback = beforePlayerRelease
	if callback then
		local succeeded, failureReason = pcall(callback, player)
		if not succeeded then
			warn(
				string.format(
					"[Frostline][Data] Pre-save player cleanup failed for player=%s UserId=%d reason=%s",
					player.Name,
					player.UserId,
					tostring(failureReason)
				)
			)
		end
	end
end

local function blockMutationsForRelease(player: Player)
	local entry = profiles[player]
	if entry then
		entry.ReleaseStarted = true
	end
end

function PlayerDataService.isLoadComplete(player: Player): boolean
	local entry = profiles[player]
	return entry ~= nil and (entry.State == "Persistent" or entry.State == "SessionOnly")
end

function PlayerDataService.isPersistent(player: Player): boolean
	local entry = profiles[player]
	return entry ~= nil and entry.State == "Persistent" and entry.Saveable and not entry.ReleaseStarted
end

function PlayerDataService.waitForLoad(player: Player, timeoutSeconds: number?): boolean
	local entry = profiles[player]
	if not entry or entry.ReleaseStarted or shuttingDown or player.Parent ~= Players then
		return false
	end
	local timeout = math.max(0, timeoutSeconds or DATA.LoadWaitTimeoutSeconds)
	local deadline = os.clock() + timeout
	while profiles[player] == entry
		and entry.State == "Loading"
		and not entry.ReleaseStarted
		and not shuttingDown
		and player.Parent == Players
		and os.clock() < deadline
	do
		task.wait(OPERATION_POLL_INTERVAL)
	end
	return profiles[player] == entry
		and not entry.ReleaseStarted
		and not shuttingDown
		and player.Parent == Players
		and (entry.State == "Persistent" or entry.State == "SessionOnly")
end

function PlayerDataService.getFrostCoins(player: Player): number?
	local entry = profiles[player]
	if not entry or (entry.State ~= "Persistent" and entry.State ~= "SessionOnly") then
		return nil
	end
	return entry.Progress.FrostCoins
end

function PlayerDataService.getBestDistance(player: Player): number?
	local entry = profiles[player]
	if not entry or (entry.State ~= "Persistent" and entry.State ~= "SessionOnly") then
		return nil
	end
	return entry.Progress.BestDistance
end

function PlayerDataService.getSnapshot(player: Player): ProgressSnapshot?
	local entry = profiles[player]
	if not entry or (entry.State ~= "Persistent" and entry.State ~= "SessionOnly") then
		return nil
	end
	return createSnapshot(entry)
end

function PlayerDataService.getStoreSnapshot(player: Player): StoreProfileSnapshot?
	local entry = profiles[player]
	if not entry or entry.State == "Released" then
		return nil
	end
	return createStoreProfileSnapshot(entry)
end

function PlayerDataService.isProfileGenerationCurrent(player: Player, expectedGeneration: number): boolean
	if shuttingDown or player.Parent ~= Players or not isSafeNonNegativeInteger(expectedGeneration) then
		return false
	end
	local entry = profiles[player]
	return entry ~= nil
		and entry.Generation == expectedGeneration
		and not entry.ReleaseStarted
		and entry.State ~= "Releasing"
		and entry.State ~= "Released"
end

function PlayerDataService.purchaseSledAndSave(
	player: Player,
	sledId: string,
	expectedRevision: number,
	expectedGeneration: number,
	validateReservation: ReservationValidator
): StoreMutationResult
	return performStoreMutation(
		player,
		"Purchase",
		sledId,
		expectedRevision,
		expectedGeneration,
		validateReservation
	)
end

function PlayerDataService.equipSledAndSave(
	player: Player,
	sledId: string,
	expectedRevision: number,
	expectedGeneration: number,
	validateReservation: ReservationValidator
): StoreMutationResult
	return performStoreMutation(
		player,
		"Equip",
		sledId,
		expectedRevision,
		expectedGeneration,
		validateReservation
	)
end

function PlayerDataService.getEquippedSledId(player: Player): string?
	local entry = profiles[player]
	if shuttingDown
		or player.Parent ~= Players
		or not entry
		or entry.State ~= "Persistent"
		or not entry.Saveable
		or entry.ReleaseStarted
		or entry.StoreSaveUnresolved
	then
		return nil
	end
	return normalizeEquippedSledId(entry.Progress.EquippedSledId, entry.Progress.OwnedSleds)
end

function PlayerDataService.hasUnresolvedStoreSave(player: Player): boolean
	local entry = profiles[player]
	return entry ~= nil and entry.StoreSaveUnresolved
end

function PlayerDataService.isShuttingDown(): boolean
	return shuttingDown
end

function PlayerDataService.applyRunReward(
	player: Player,
	finalDistance: number,
	frostCoinsEarned: number
): (RewardUpdate?, string?)
	if not isFiniteNumber(finalDistance) or finalDistance < 0 then
		return nil, "invalid final distance"
	elseif not isNonNegativeInteger(frostCoinsEarned) then
		return nil, "invalid Frost Coin reward"
	elseif shuttingDown then
		return nil, "server shutdown is in progress"
	end

	local entry = profiles[player]
	if not entry then
		return nil, "profile is unavailable"
	elseif entry.ReleaseStarted or entry.State == "Releasing" or entry.State == "Released" then
		return nil, "profile release is in progress"
	elseif entry.State == "Loading" then
		return nil, "profile is still loading"
	end

	local updatedCoins = entry.Progress.FrostCoins + frostCoinsEarned
	if not isNonNegativeInteger(updatedCoins) then
		return nil, "Frost Coin total would be invalid"
	end
	local isNewBest = finalDistance > entry.Progress.BestDistance
	entry.Progress.FrostCoins = updatedCoins
	if isNewBest then
		entry.Progress.BestDistance = finalDistance
	end
	entry.Revision += 1
	entry.Dirty = true

	local ownedSleds = copyOwnedSleds(entry.Progress.OwnedSleds)
	table.freeze(ownedSleds)
	return table.freeze({
		SchemaVersion = DATA.SchemaVersion,
		FrostCoins = entry.Progress.FrostCoins,
		BestDistance = entry.Progress.BestDistance,
		OwnedSleds = ownedSleds,
		EquippedSledId = entry.Progress.EquippedSledId,
		PersistenceStatus = getPersistenceStatus(entry),
		IsNewBest = isNewBest,
	}), nil
end

function PlayerDataService.saveAndRelease(player: Player, timeoutSeconds: number?): boolean
	local entry = profiles[player]
	if not entry then
		return true
	end

	if not entry.ReleaseStarted then
		entry.ReleaseStarted = true
	end
	if entry.ReleaseWorkerActive then
		local deadline = if timeoutSeconds then os.clock() + math.max(0, timeoutSeconds) else nil
		while not entry.ReleaseFinished do
			if deadline and os.clock() >= deadline then
				return false
			end
			task.wait(OPERATION_POLL_INTERVAL)
		end
		return entry.ReleaseSucceeded
	end

	entry.ReleaseWorkerActive = true
	return performRelease(entry)
end

local function runAutosaveLoop()
	while started and not shuttingDown do
		task.wait(DATA.AutosaveIntervalSeconds)
		if shuttingDown then
			return
		end

		local eligibleEntries: { ProfileSession } = {}
		for _, entry in profiles do
			if entry.State == "Persistent"
				and entry.Saveable
				and not entry.ReleaseStarted
				and not entry.SavePending
			then
				entry.SavePending = true
				table.insert(eligibleEntries, entry)
			end
		end
		for _, entry in eligibleEntries do
			task.spawn(runAutosave, entry)
		end
	end
end

local function runShutdown()
	shuttingDown = true
	local targets: { ProfileSession } = {}
	for player, entry in profiles do
		coordinatePlayerRemoval(player)
		table.insert(targets, entry)
	end

	local completed = 0
	for _, entry in targets do
		local targetEntry = entry
		task.spawn(function()
			PlayerDataService.saveAndRelease(targetEntry.Player, DATA.ShutdownTimeoutSeconds)
			completed += 1
		end)
	end

	local deadline = os.clock() + DATA.ShutdownTimeoutSeconds
	while completed < #targets and os.clock() < deadline do
		task.wait(OPERATION_POLL_INTERVAL)
	end
	if completed < #targets then
		warn(
			string.format(
				"[Frostline][Data] Shutdown save deadline reached completed=%d total=%d",
				completed,
				#targets
			)
		)
	end
end

function PlayerDataService.start(callback: BeforePlayerRelease?)
	if started then
		return
	end
	started = true
	beforePlayerRelease = callback

	Players.PlayerAdded:Connect(beginLoading)
	Players.PlayerRemoving:Connect(function(player: Player)
		blockMutationsForRelease(player)
		coordinatePlayerRemoval(player)
		PlayerDataService.saveAndRelease(player)
		removalCoordinated[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		beginLoading(player)
	end

	task.spawn(runAutosaveLoop)
	game:BindToClose(runShutdown)
	print("[Frostline] PlayerDataService ready")
end

return PlayerDataService
