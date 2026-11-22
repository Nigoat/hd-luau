local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")

type GuardConfig = {
	DetectionRadius: number,
	FieldOfView: number, -- total degrees
	DetectionTime: number, -- seconds of being seen before fully spotted
	LoseSightTime: number, -- seconds chasing blind before giving up
	PatrolSpeed: number,
	ChaseSpeed: number,
	PatrolPauseTime: number,
	SearchTime: number,
	SearchRadius: number,
	PathRecalcDistance: number,
	UpdateInterval: number,
}

local defaultConfig: GuardConfig = {
	DetectionRadius = 45,
	FieldOfView = 120,
	DetectionTime = 1.2,
	LoseSightTime = 3,
	PatrolSpeed = 8,
	ChaseSpeed = 16,
	PatrolPauseTime = 1.5,
	SearchTime = 4,
	SearchRadius = 10,
	PathRecalcDistance = 6,
	UpdateInterval = 0.1,
}

type GuardState = "Patrolling" | "Investigating" | "Chasing" | "Returning"

local Guard = {}
Guard.__index = Guard

function Guard.new(model: Model): any
	local self = setmetatable({}, Guard)
	self.Model = model
	self.Config = defaultConfig
	self.Humanoid = model:FindFirstChildOfClass("Humanoid")
	self.Root = model:FindFirstChild("HumanoidRootPart")
	self.State = "Patrolling" :: GuardState
	self.Detection = 0 -- builds up while a player is visible and decays when not
	self.Suspect = nil :: Player?
	self.TargetPlayer = nil :: Player?
	self.LastKnownPosition = nil :: Vector3?
	self.Waypoints = {}
	self.WaypointIndex = 1
	self.PathGoal = nil :: Vector3?
	self.PathCooldown = 0
	self.PatrolPoints = {}
	self.PatrolIndex = 0
	self.Phase = nil :: string?
	self.Timer = 0
	self.LostTimer = 0
	self.Pausing = false
	self.SearchPoint = nil :: Vector3?
	self.Active = true
	return self
end

function Guard:SetState(state: GuardState)
	if state ~= "Chasing" then
		self.Detection = 0 -- fresh eyes when we calm down
	end
	self.State = state
	self.Timer = 0
	self.Phase = nil
	self.Waypoints = {}
	self.WaypointIndex = 1
	self.PathGoal = nil
	print(self.Model.Name .. " -> " .. state)
end

function Guard:CanSee(character: Model): boolean
	local charRoot = character:FindFirstChild("HumanoidRootPart")
	if not charRoot then return false end

	local eyePos = self.Root.Position + Vector3.new(0, 1.5, 0) -- roughly head height
	local offset = charRoot.Position - eyePos
	if offset.Magnitude > self.Config.DetectionRadius then return false end -- too far away

	-- dot product check if are they inside our cone of vision
	local facing = self.Root.CFrame.LookVector
	if facing:Dot(offset.Unit) < math.cos(math.rad(self.Config.FieldOfView / 2)) then
		return false
	end

	-- raycast to make sure nothing is blocking the view
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = {self.Model}
	local hit = workspace:Raycast(eyePos, offset, params)
	return hit == nil or hit.Instance:IsDescendantOf(character)
end

function Guard:GetVisiblePlayer(): Player?
	for _, player in Players:GetPlayers() do -- check every player in the game
		local character = player.Character
		if character and self:CanSee(character) then -- and see if we can see them
			return player
		end
	end
	return nil
end

function Guard:TickDetection(dt: number)
	local player = self:GetVisiblePlayer()
	if player then
		self.Detection = math.min(self.Detection + dt / self.Config.DetectionTime, 1)
		self.Suspect = player
	else
		self.Detection = math.max(self.Detection - dt / self.Config.DetectionTime, 0)
		self.Suspect = nil
	end
	if self.Detection >= 1 and self.Suspect then -- spotted them for real
		self:StartChase(self.Suspect)
	end
end

function Guard:ComputePath(target: Vector3): boolean
	if self.PathCooldown > 0 then return false end -- dont spam path requests
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = false,
	})
	local ok = pcall(function()
		path:ComputeAsync(self.Root.Position, target)
	end)
	self.PathCooldown = 0.5
	if ok and path.Status == Enum.PathStatus.Success then
		self.Waypoints = path:GetWaypoints()
		self.WaypointIndex = 2 -- waypoint 1 is where were already standing
		self.PathGoal = target
		return true
	end
	return false
end

function Guard:FollowPath(): boolean
	local waypoint = self.Waypoints[self.WaypointIndex]
	if not waypoint then
		return true -- out of waypoints we've arrived
	end
	if waypoint.Action == Enum.PathWaypointAction.Jump then
		self.Humanoid.Jump = true
	end
	self.Humanoid:MoveTo(waypoint.Position)
	local flat = Vector3.new(1, 0, 1) -- ignore height so ramps dont confuse us
	if ((self.Root.Position - waypoint.Position) * flat).Magnitude < 3 then
		self.WaypointIndex += 1
	end
	return self.WaypointIndex > #self.Waypoints
end

function Guard:RefreshLastKnown()
	local character = self.TargetPlayer and self.TargetPlayer.Character
	local charRoot = character and character:FindFirstChild("HumanoidRootPart")
	if charRoot then
		self.LastKnownPosition = charRoot.Position -- remember where we saw them last
	end
end

function Guard:StartChase(player: Player)
	self.TargetPlayer = player
	self:RefreshLastKnown()
	self.Humanoid.WalkSpeed = self.Config.ChaseSpeed
	self:SetState("Chasing")
end

function Guard:Patrol()
	self.Humanoid.WalkSpeed = self.Config.PatrolSpeed
	while self.Active and self.State == "Patrolling" do
		local dt = task.wait(self.Config.UpdateInterval)
		self.PathCooldown = math.max(self.PathCooldown - dt, 0)
		self:TickDetection(dt)
		if self.State ~= "Patrolling" then break end -- detection kicked us into chase

		if not self.PathGoal and not self.Pausing then
			self.PatrolIndex += 1 -- next patrol point
			if self.PatrolIndex > #self.PatrolPoints then self.PatrolIndex = 1 end
			local point = self.PatrolPoints[self.PatrolIndex]
			if point then
				self:ComputePath(point.Position) -- if it fails we just retry next tick
			end
		end

		if self.PathGoal then
			if self:FollowPath() then
				self.PathGoal = nil
				self.Pausing = true
				self.Timer = 0
				self.Humanoid:MoveTo(self.Root.Position) -- stand still for a moment
			end
		elseif self.Pausing then
			self.Timer += dt
			if self.Timer >= self.Config.PatrolPauseTime then
				self.Pausing = false
				self.Timer = 0
			end
		end
	end
end

function Guard:Chase()
	while self.Active and self.State == "Chasing" do
		local dt = task.wait(self.Config.UpdateInterval)
		self.PathCooldown = math.max(self.PathCooldown - dt, 0)

		local character = self.TargetPlayer and self.TargetPlayer.Character
		local visible = character ~= nil and self:CanSee(character)
		if visible then
			self.LostTimer = 0
			self:RefreshLastKnown()
		else
			self.LostTimer += dt
			if self.LostTimer >= self.Config.LoseSightTime then -- lost them for good
				self:StartInvestigation()
				break
			end
		end

		local goal = self.LastKnownPosition
		if goal then
			-- recompute if the player moved away from where our current path leads
			if not self.PathGoal or (goal - self.PathGoal).Magnitude > self.Config.PathRecalcDistance then
				self:ComputePath(goal)
			end
			local reached = false
			if self.PathGoal then
				reached = self:FollowPath()
			end
			if reached then
				if not visible then
					self:StartInvestigation() -- got to the last spot and they're gone
					break
				else
					self.PathGoal = nil -- fresh path next tick keep pressing
			end
			end
		end
	end
end

function Guard:StartInvestigation()
	self.Humanoid.WalkSpeed = self.Config.PatrolSpeed + 2 -- hurry over but not sprint
	self:SetState("Investigating")
	self.Phase = "Going"
end

function Guard:Investigate()
	while self.Active and self.State == "Investigating" do
		local dt = task.wait(self.Config.UpdateInterval)
		self.PathCooldown = math.max(self.PathCooldown - dt, 0)
		self:TickDetection(dt) -- might spot them again and jump straight back to chase
		if self.State ~= "Investigating" then break end

		if self.Phase == "Going" then
			if not self.PathGoal and self.LastKnownPosition then
				self:ComputePath(self.LastKnownPosition)
			end
			if self.PathGoal and self:FollowPath() then
				self.PathGoal = nil
				self.Phase = "Searching"
				self.Timer = 0
				self.SearchPoint = nil
			end
		elseif self.Phase == "Searching" then
			self.Timer += dt
			-- wander around the area so we actually look like were searching
			if not self.SearchPoint or ((self.Root.Position - self.SearchPoint) * Vector3.new(1, 0, 1)).Magnitude < 2 then
				local angle = math.random() * math.pi * 2
				local dist = math.random() * self.Config.SearchRadius
				local origin = self.LastKnownPosition or self.Root.Position
				self.SearchPoint = origin + Vector3.new(math.cos(angle) * dist, 0, math.sin(angle) * dist)
				self.Humanoid:MoveTo(self.SearchPoint)
			end
			if self.Timer >= self.Config.SearchTime then -- nothing here go back to work
				self:StartReturn()
				break
			end
		end
	end
end

function Guard:StartReturn()
	self.Humanoid.WalkSpeed = self.Config.PatrolSpeed
	self:SetState("Returning")
end

function Guard:Return()
	while self.Active and self.State == "Returning" do
		local dt = task.wait(self.Config.UpdateInterval)
		self.PathCooldown = math.max(self.PathCooldown - dt, 0)
		self:TickDetection(dt)
		if self.State ~= "Returning" then break end

		if not self.PathGoal then
			-- head back to whichever patrol point is closest
			local closest, bestDist = nil, math.huge
			for i, point in self.PatrolPoints do
				local d = (self.Root.Position - point.Position).Magnitude
				if d < bestDist then -- closer than the best so far
					bestDist = d
					closest = i
				end
			end
			if closest then
				self.PatrolIndex = closest
				self:ComputePath(self.PatrolPoints[closest].Position)
			end
		end

		if self.PathGoal and self:FollowPath() then
			self.PathGoal = nil
			self:SetState("Patrolling")
		end
	end
end

function Guard:Run()
	while self.Active and self.Humanoid.Health > 0 do
		if self.State == "Patrolling" then
			self:Patrol()
		elseif self.State == "Investigating" then
			self:Investigate()
		elseif self.State == "Chasing" then
			self:Chase()
		elseif self.State == "Returning" then
			self:Return()
		end
		task.wait()
	end
	if self.Root then
		self.Humanoid:MoveTo(self.Root.Position) -- stop walking
	end
end

local activeGuards = {}

local function isGuardModel(instance)
	return instance:IsA("Model")
		and instance:FindFirstChildOfClass("Humanoid") ~= nil
		and string.find(instance.Name, "Guard") ~= nil
end

local function setupGuard(model)
	if activeGuards[model] then return end -- already running

	local points = {}
	local pointsFolder = workspace:FindFirstChild("PatrolPoints", true)
	if pointsFolder then
		for _, child in pointsFolder:GetChildren() do
			if child:IsA("BasePart") then
				table.insert(points, child)
			end
		end
		table.sort(points, function(a, b) -- keep them in name order
			return a.Name < b.Name
		end)
	end

	local guard = Guard.new(model)
	guard.PatrolPoints = points
	activeGuards[model] = guard

	task.spawn(function() -- each guard runs on its own
		guard:Run()
	end)

	model.Destroying:Connect(function()
		guard.Active = false
		activeGuards[model] = nil
	end)
end

for _, descendant in workspace:GetDescendants() do
	if isGuardModel(descendant) then
		setupGuard(descendant)
	end
end

workspace.DescendantAdded:Connect(function(descendant)
	if isGuardModel(descendant) then
		task.defer(function() -- give it a moment to finish loading in
			setupGuard(descendant)
		end)
	end
end)
