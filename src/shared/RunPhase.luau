--!strict

local RunPhase = table.freeze({
	Idle = "Idle",
	Countdown = "Countdown",
	Descent = "Descent",
	Airborne = "Airborne",
	Landed = "Landed",
	Results = "Results",
	Reset = "Reset",
})

export type Name = "Idle" | "Countdown" | "Descent" | "Airborne" | "Landed" | "Results" | "Reset"

return RunPhase
