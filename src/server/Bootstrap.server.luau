--!strict

local WorldBuilder = require(script.Parent.Services.WorldBuilder)
local PlayerDataService = require(script.Parent.Services.PlayerDataService)
local RunManager = require(script.Parent.Services.RunManager)

PlayerDataService.start(RunManager.handlePlayerRemoving)
WorldBuilder.build()
RunManager.start()

print("[Frostline] Server bootstrap complete")
