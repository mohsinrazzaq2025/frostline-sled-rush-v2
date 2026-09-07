--!strict

local AudioController = require(script.Parent.Controllers.AudioController)
local VFXController = require(script.Parent.Controllers.VFXController)
local RunController = require(script.Parent.Controllers.RunController)
local ResultController = require(script.Parent.Controllers.ResultController)

AudioController.start()
RunController.start()

local routeContentStarted, routeContentFailure = pcall(function()
	local FrostTrailRouteContentController = require(script.Parent.Controllers.FrostTrailRouteContentController)
	FrostTrailRouteContentController.start()
end)
if not routeContentStarted then
	warn(
		string.format(
			"[Frostline][RouteContent] Client presentation unavailable: %s",
			tostring(routeContentFailure)
		)
	)
end

-- RunController waits for the server-created remotes, which means WorldBuilder's
-- Lighting and sled hierarchy are available before client VFX inspects them.
VFXController.start()
ResultController.start()

local storeStarted, storeFailure = pcall(function()
	local StoreController = require(script.Parent.Controllers.StoreController)
	StoreController.start()
end)
if not storeStarted then
	warn(
		string.format(
			"[Frostline] StoreController failed to start; Store unavailable: %s",
			tostring(storeFailure)
		)
	)
end

local cameraStarted, cameraFailure = pcall(function()
	local CameraController = require(script.Parent.Controllers.CameraController)
	CameraController.start()
end)
if not cameraStarted then
	warn(
		string.format(
			"[Frostline] CameraController failed to start; using Roblox camera: %s",
			tostring(cameraFailure)
		)
	)
end

print("[Frostline] Client bootstrap complete")
