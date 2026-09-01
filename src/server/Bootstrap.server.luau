--!strict

local WorldBuilder = require(script.Parent.Services.WorldBuilder)
local RunManager = require(script.Parent.Services.RunManager)

WorldBuilder.build()
RunManager.start()

print("[Frostline] Server bootstrap complete")
