-- Poly Loot | Android / Delta | Mobile Helper v3.0
-- Offline, self-contained script. No loadstring(), HTTP, remote downloads or telemetry.
-- Auto Farm / Auto Loot depend on Poly Loot's live combat & pickup mechanics.
-- Based on the original v2.0. Adds orbital anti-hit, rapid input, HP retreat.
-- Client-side evasion is not invulnerability: server determines aggro, damage and cooldowns.

if not game:IsLoaded() then game.Loaded:Wait() end
if game.PlaceId ~= 124032631078772 and game.GameId ~= 10541331578 then
    warn('[PolyLoot v3] This script is intended for [TOWER] Poly Loot.')
    return
end

local Players = game:GetService('Players')
local Workspace = game:GetService('Workspace')
local UIS = game:GetService('UserInputService')
local RunService = game:GetService('RunService')
local CollectionService = game:GetService('CollectionService')
local VirtualInputManager = game:GetService('VirtualInputManager')
local VirtualUser = game:GetService('VirtualUser')
local player = Players.LocalPlayer
if not player then return end

local env = _G
if type(getgenv) == 'function' then
    local ok, e = pcall(getgenv)
    if ok and type(e) == 'table' then env = e end
end
if type(env.PolyLootMobile_Stop) == 'function' then pcall(env.PolyLootMobile_Stop) end
local alive = true
local state = {
    farm = false, loot = false, mobESP = false, lootESP = false,
    speed = false, jump = false, noclip = false, infJump = false,
    fastAttack = true, safeFarm = true, autoRetreat = true
}
local conns, marks, collisions, taughtEnemies = {}, {}, {}, {}
local char, hum, root, normalSpeed, normalJump, normalUseJumpPower
local bodyHover, retreatActive, lastObservedHP
local gui, main, bubble, statusLabel
local allEnemies, allLoot, unknownHumanoids = {}, {}, {}
local diagnosticStats = { models = 0, humanoids = 0, prompts = 0, clicks = 0, looseTools = 0 }
local lastScan, lastAttack, lastLoot = 0, 0, 0
local lootAttempts, targetDamage, attackCount, currentTarget = {}, 0, 0, nil
local hint = 'v3: умный отход, бой по кругу, ускоренная атака.'
local attackIntervalFast, attackIntervalNormal = 0.16, 0.42
local hoverBase, hoverNow, hoverMin, hoverMax = 5, 5, 1.5, 9.5
local safePoint, retreatAt, retreatReason = nil, 0, ''
local attacksWithoutDamage, lastEnemyHP = 0, nil
local orbitSeed = 0


local function connect(event, fn)
    local c = event:Connect(fn)
    conns[#conns + 1] = c
    return c
end
local function status(s)
    hint = tostring(s)
    if statusLabel and statusLabel.Parent then statusLabel.Text = hint end
end
local function lower(s)
    return string.lower(tostring(s or ''))
end
local function contains(s, tokens)
    s = lower(s)
    for _, token in ipairs(tokens) do
        if string.find(s, token, 1, true) then return true end
    end
    return false
end
local function getRoot(obj)
    if not obj or not obj.Parent then return nil end
    if obj:IsA('BasePart') then return obj end
    if obj:IsA('Model') then
        return obj:FindFirstChild('HumanoidRootPart') or obj.PrimaryPart
            or obj:FindFirstChild('UpperTorso') or obj:FindFirstChild('Torso')
            or obj:FindFirstChildWhichIsA('BasePart', true)
    end
    return obj:FindFirstChildWhichIsA('BasePart', true)
end
local function bindCharacter(model)
    char = model
    hum = model and model:FindFirstChildWhichIsA('Humanoid')
    root = model and getRoot(model)
    if hum then
        normalSpeed, normalJump, normalUseJumpPower = hum.WalkSpeed, hum.JumpPower, hum.UseJumpPower
    else
        normalSpeed, normalJump, normalUseJumpPower = 16, 50, true
    end
end
bindCharacter(player.Character)
connect(player.CharacterAdded, function(model)
    -- Hover attachment is always destroyed when the old character goes away.
    if bodyHover then pcall(function() bodyHover:Destroy() end); bodyHover = nil end
    retreatActive = false
    lastObservedHP = nil
    bindCharacter(model)
    task.delay(1, function()
        if alive and char == model then bindCharacter(model) end
    end)
end)

-- Do not classify every Humanoid as hostile: NPCs, merchants and trainers also have one.
local friendlyTokens = {
    'merchant', 'shop', 'vendor', 'seller', 'trader', 'trainer', 'guide',
    'quest', 'teleport', 'blacksmith', 'craft', 'upgrade', 'bank', 'npc',
    'companion', 'pet', 'dummy', 'statue', 'guard', 'villager', 'citizen'
}
local enemyTokens = {
    'monster', 'enemy', 'hostile', 'mob', 'boss', 'slime', 'spider', 'goblin',
    'skeleton', 'zombie', 'wolf', 'boar', 'orc', 'bandit', 'bat', 'golem',
    'mushroom', 'chicken', 'dragon', 'demon', 'vex', 'blackpowder', 'nay'
}
local lootTokens = {
    'loot', 'drop', 'pickup', 'pick up', 'collect', 'treasure', 'chest',
    'coin', 'gold', 'gem', 'crystal', 'reward', 'material', 'item', 'scroll',
    'bag', 'orb', 'weapon drop', 'equipment'
}
local collectTokens = {'take', 'collect', 'pick', 'loot', 'grab', 'claim', 'open', 'gather'}

local function attr(obj, name)
    if not obj then return nil end
    local ok, val = pcall(function() return obj:GetAttribute(name) end)
    if ok then return val end
    return nil
end
local function hasEnemyTag(obj)
    local ok, tags = pcall(function() return CollectionService:GetTags(obj) end)
    if not ok then return false end
    for _, tag in ipairs(tags) do
        if contains(tag, enemyTokens) then return true end
    end
    return false
end
local function getHealth(model)
    local h = model:FindFirstChildWhichIsA('Humanoid')
    if h then return h.Health, h.MaxHealth end
    local healthObj = model:FindFirstChild('Health') or model:FindFirstChild('HP')
        or model:FindFirstChild('CurrentHealth')
    if healthObj and (healthObj:IsA('NumberValue') or healthObj:IsA('IntValue')) then
        return healthObj.Value, 1
    end
    local a = attr(model, 'Health') or attr(model, 'HP')
    if type(a) == 'number' then return a, 1 end
    return nil, nil
end
local function isOwnOrOtherPlayer(obj)
    if char and obj:IsDescendantOf(char) then return true end
    local ancestor = obj
    for _ = 1, 6 do
        if not ancestor or ancestor == Workspace then break end
        if ancestor:IsA('Model') and Players:GetPlayerFromCharacter(ancestor) then return true end
        ancestor = ancestor.Parent
    end
    return false
end
local function classifyEnemy(model)
    if not model or not model:IsA('Model') or model == char then return false end
    if isOwnOrOtherPlayer(model) or not getRoot(model) then return false end
    local hp = getHealth(model)
    if hp == nil or hp <= 0 then return false end
    if attr(model, 'Friendly') == true or attr(model, 'IsFriendly') == true then return false end
    if taughtEnemies[model.Name] then return true end

    local score = 0
    for _, key in ipairs({'IsEnemy', 'Enemy', 'IsMonster', 'Monster', 'Hostile', 'Aggressive', 'IsMob'}) do
        if attr(model, key) == true then score = score + 6 end
    end
    for _, key in ipairs({'Faction', 'Team', 'Type', 'EntityType', 'MobType'}) do
        local value = attr(model, key)
        if type(value) == 'string' and contains(value, enemyTokens) then score = score + 4 end
        if type(value) == 'string' and contains(value, friendlyTokens) then score = score - 8 end
    end
    if hasEnemyTag(model) then score = score + 6 end
    if contains(model.Name, enemyTokens) then score = score + 5 end
    if contains(model.Name, friendlyTokens) then score = score - 9 end
    local parent = model.Parent
    for _ = 1, 3 do
        if not parent or parent == Workspace then break end
        if contains(parent.Name, {'enemies', 'monsters', 'hostiles', 'mobs', 'bosses', 'creatures'}) then
            score = score + 5
        elseif contains(parent.Name, {'shop', 'merchant', 'vendors', 'town npcs', 'friendly npc'}) then
            score = score - 7
        end
        parent = parent.Parent
    end
    return score >= 4
end

local function getLootOwner(obj)
    if not obj or not obj.Parent then return nil end
    local curr = obj
    local named = nil
    for _ = 1, 4 do
        if not curr or curr == Workspace then break end
        if curr:IsA('Model') or curr:IsA('Tool') then
            if contains(curr.Name, lootTokens) then named = curr end
        end
        curr = curr.Parent
    end
    if named then return named end
    if obj:IsA('ProximityPrompt') or obj:IsA('ClickDetector') or obj:IsA('TouchTransmitter') then
        return obj.Parent
    end
    return obj
end
local function modelHasHumanoidAncestor(obj)
    local curr = obj
    for _ = 1, 6 do
        if not curr or curr == Workspace then break end
        if curr:IsA('Model') and curr:FindFirstChildWhichIsA('Humanoid') then return true end
        curr = curr.Parent
    end
    return false
end
local function lootScore(source, owner)
    if not source or not owner then return -100 end
    if isOwnOrOtherPlayer(source) or modelHasHumanoidAncestor(source) then return -100 end
    local score = 0
    if contains(source.Name, lootTokens) then score = score + 2 end
    if contains(owner.Name, lootTokens) then score = score + 3 end
    if owner:IsA('Tool') or source:IsA('Tool') then score = score + 7 end
    local cur = owner.Parent
    for _ = 1, 3 do
        if not cur or cur == Workspace then break end
        if contains(cur.Name, {'drops', 'loot', 'pickups', 'collectibles', 'grounditems', 'items on ground'}) then
            score = score + 6
        end
        if contains(cur.Name, {'map', 'terrain', 'decorations', 'buildings'}) then score = score - 1 end
        cur = cur.Parent
    end
    for _, key in ipairs({'ItemId', 'ItemName', 'Rarity', 'DropId', 'LootId', 'Pickup'}) do
        if attr(source, key) ~= nil or attr(owner, key) ~= nil then score = score + 4 end
    end
    if source:IsA('ProximityPrompt') then
        local label = source.Name .. ' ' .. source.ActionText .. ' ' .. source.ObjectText
        if contains(label, collectTokens) then score = score + 6 end
        if contains(label, {'talk', 'buy', 'sell', 'quest', 'upgrade', 'travel'}) then score = score - 7 end
    elseif source:IsA('ClickDetector') then
        score = score + 1
    elseif source:IsA('TouchTransmitter') then
        score = score + 1
    end
    return score
end

local function scan(force)
    local now = os.clock()
    if not force and now - lastScan < 1.7 then return end
    lastScan = now
    local enemies, loots, unknown = {}, {}, {}
    local byOwner = {}
    local stats = { models = 0, humanoids = 0, prompts = 0, clicks = 0, looseTools = 0 }
    local ok, descendants = pcall(function() return Workspace:GetDescendants() end)
    if not ok then return end
    for _, obj in ipairs(descendants) do
        if obj:IsA('Model') then
            stats.models = stats.models + 1
            local hp = getHealth(obj)
            if hp ~= nil and hp > 0 and not isOwnOrOtherPlayer(obj) then
                if classifyEnemy(obj) then
                    enemies[#enemies + 1] = obj
                elseif obj:FindFirstChildWhichIsA('Humanoid') then
                    unknown[#unknown + 1] = obj
                end
            end
        elseif obj:IsA('Humanoid') then
            stats.humanoids = stats.humanoids + 1
        end

        local isInteract = obj:IsA('ProximityPrompt') or obj:IsA('ClickDetector')
            or obj:IsA('TouchTransmitter')
        local isPart = obj:IsA('BasePart')
        local isLooseTool = obj:IsA('Tool') and obj:IsDescendantOf(Workspace)
        if obj:IsA('ProximityPrompt') then stats.prompts = stats.prompts + 1 end
        if obj:IsA('ClickDetector') then stats.clicks = stats.clicks + 1 end
        if isLooseTool then stats.looseTools = stats.looseTools + 1 end
        if isInteract or isLooseTool or (isPart and contains(obj.Name, lootTokens)) then
            local owner = getLootOwner(obj)
            if owner and owner:IsDescendantOf(Workspace) then
                local score = lootScore(obj, owner)
                if score >= 4 then
                    local part = getRoot(owner)
                    if not part and obj.Parent then part = getRoot(obj.Parent) end
                    if part then
                        local candidate = byOwner[owner]
                        if not candidate then
                            candidate = { object = owner, part = part, prompts = {}, clicks = {}, touches = {}, score = score }
                            byOwner[owner] = candidate
                            loots[#loots + 1] = candidate
                        end
                        if score > candidate.score then candidate.score = score end
                        if obj:IsA('ProximityPrompt') then
                            candidate.prompts[#candidate.prompts + 1] = obj
                        elseif obj:IsA('ClickDetector') then
                            candidate.clicks[#candidate.clicks + 1] = obj
                        elseif obj:IsA('TouchTransmitter') then
                            candidate.touches[#candidate.touches + 1] = obj
                        end
                    end
                end
            end
        end
    end
    -- Attach every interaction belonging to a recognized item, even when the
    -- ClickDetector itself has a generic name (e.g. "ClickDetector").
    for _, rec in ipairs(loots) do
        local hadPrompt, hadClick, hadTouch = {}, {}, {}
        for _, obj in ipairs(rec.prompts) do hadPrompt[obj] = true end
        for _, obj in ipairs(rec.clicks) do hadClick[obj] = true end
        for _, obj in ipairs(rec.touches) do hadTouch[obj] = true end
        for _, child in ipairs(rec.object:GetDescendants()) do
            if child:IsA('ProximityPrompt') and not hadPrompt[child] then
                rec.prompts[#rec.prompts + 1] = child
            elseif child:IsA('ClickDetector') and not hadClick[child] then
                rec.clicks[#rec.clicks + 1] = child
            elseif child:IsA('TouchTransmitter') and not hadTouch[child] then
                rec.touches[#rec.touches + 1] = child
            end
        end
    end
    allEnemies, allLoot, unknownHumanoids, diagnosticStats = enemies, loots, unknown, stats
end

local function nearestEnemy()
    if not root or not root.Parent then return nil, nil, math.huge end
    local best, bestRoot, dist = nil, nil, 180
    for _, obj in ipairs(allEnemies) do
        local p = getRoot(obj)
        local hp = getHealth(obj)
        if p and hp and hp > 0 then
            local d = (p.Position - root.Position).Magnitude
            if d < dist then best, bestRoot, dist = obj, p, d end
        end
    end
    return best, bestRoot, dist
end
local function nearestLoot()
    if not root or not root.Parent then return nil, math.huge end
    local best, dist = nil, 110
    for _, obj in ipairs(allLoot) do
        if obj.object.Parent and obj.part.Parent then
            local d = (obj.part.Position - root.Position).Magnitude
            if d < dist and (os.clock() - (lootAttempts[obj.object] or -1e6) > 3.0) then
                best, dist = obj, d
            end
        end
    end
    return best, dist
end

local function ensureMark(inst, part, label, color, kind)
    if not inst or not inst.Parent or not part or not part.Parent then return end
    local m = marks[inst]
    if m and m.kind == kind and m.h and m.h.Parent then return end
    if m then
        pcall(function() m.h:Destroy() end)
        pcall(function() m.bill:Destroy() end)
    end
    local h = Instance.new('Highlight')
    h.Name = 'PolyLoot_v3_ESP'
    h.Adornee = inst
    h.FillColor, h.OutlineColor = color, color
    h.FillTransparency, h.OutlineTransparency = 0.77, 0.1
    h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    h.Parent = inst
    local bb = Instance.new('BillboardGui')
    bb.Name = 'PolyLoot_v3_Label'
    bb.Adornee = part
    bb.AlwaysOnTop = true
    bb.Size = UDim2.new(0, 150, 0, 24)
    bb.StudsOffset = Vector3.new(0, 3, 0)
    bb.Parent = gui
    local txt = Instance.new('TextLabel')
    txt.Size = UDim2.new(1, 0, 1, 0)
    txt.BackgroundTransparency = 0.45
    txt.BackgroundColor3 = Color3.new(0, 0, 0)
    txt.TextColor3 = color
    txt.Font = Enum.Font.GothamBold
    txt.TextScaled = true
    txt.Text = label
    txt.Parent = bb
    marks[inst] = { h = h, bill = bb, kind = kind }
end
local function clearMarks(kind)
    for inst, m in pairs(marks) do
        if kind == nil or m.kind == kind then
            pcall(function() m.h:Destroy() end)
            pcall(function() m.bill:Destroy() end)
            marks[inst] = nil
        end
    end
end
local function updateESP()
    if not root or not root.Parent then return end
    local present = {}
    if state.mobESP then
        local n = 0
        for _, obj in ipairs(allEnemies) do
            local p = getRoot(obj)
            if p and (p.Position - root.Position).Magnitude <= 210 and n < 40 then
                ensureMark(obj, p, obj.Name, Color3.fromRGB(255, 85, 85), 'enemy')
                present[obj] = true
                n = n + 1
            end
        end
    end
    if state.lootESP then
        local n = 0
        for _, rec in ipairs(allLoot) do
            if rec.part.Parent and (rec.part.Position - root.Position).Magnitude <= 180 and n < 55 then
                ensureMark(rec.object, rec.part, rec.object.Name, Color3.fromRGB(95, 255, 145), 'loot')
                present[rec.object] = true
                n = n + 1
            end
        end
    end
    for inst, m in pairs(marks) do
        if not present[inst] or not inst.Parent then
            pcall(function() m.h:Destroy() end)
            pcall(function() m.bill:Destroy() end)
            marks[inst] = nil
        end
    end
end

-- Retain the movement features confirmed to work in v1.
local function applyMovement()
    if not hum or not hum.Parent then return end
    pcall(function()
        hum.WalkSpeed = state.speed and 32 or (normalSpeed or 16)
        if state.jump then
            hum.UseJumpPower = true
            hum.JumpPower = 100
        else
            hum.UseJumpPower = normalUseJumpPower
            hum.JumpPower = normalJump or 50
        end
    end)
end
local function restoreCollision()
    for part, original in pairs(collisions) do
        if part and part.Parent then pcall(function() part.CanCollide = original end) end
        collisions[part] = nil
    end
end
local function releaseHover()
    if bodyHover then
        pcall(function() bodyHover:Destroy() end)
        bodyHover = nil
    end
end

local function holdVertical()
    if not root or not root.Parent then return end
    if not bodyHover or bodyHover.Parent ~= root then
        releaseHover()
        bodyHover = Instance.new('BodyVelocity')
        bodyHover.Name = 'PolyLoot_v3_Hover'
        bodyHover.MaxForce = Vector3.new(0, 120000, 0)
        bodyHover.P = 7000
        bodyHover.Parent = root
    end
    bodyHover.Velocity = Vector3.new(0, 0, 0)
end

local function stop()
    if not alive then return end
    alive = false
    for k in pairs(state) do state[k] = false end
    retreatActive = false
    for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
    clearMarks()
    releaseHover()
    restoreCollision()
    applyMovement()
    if gui then pcall(function() gui:Destroy() end) end
    if env.PolyLootMobile_Stop == stop then env.PolyLootMobile_Stop = nil end
end
env.PolyLootMobile_Stop = stop

local function moveNear(part, distance, faceEnemy)
    if not root or not root.Parent or not part or not part.Parent then return false end
    local diff = root.Position - part.Position
    if diff.Magnitude > 150 then return false end
    if diff.Magnitude < distance then
        if faceEnemy and diff.Magnitude > 0.1 then
            pcall(function()
                root.CFrame = CFrame.lookAt(root.Position, Vector3.new(part.Position.X, root.Position.Y, part.Position.Z))
            end)
        end
        return true
    end
    local horizontal = Vector3.new(diff.X, 0, diff.Z)
    if horizontal.Magnitude < 0.05 then horizontal = Vector3.new(0, 0, 1) end
    local pos = part.Position + horizontal.Unit * distance + Vector3.new(0, 1.8, 0)
    pcall(function()
        if faceEnemy then
            root.CFrame = CFrame.lookAt(pos, Vector3.new(part.Position.X, pos.Y, part.Position.Z))
        else
            root.CFrame = CFrame.new(pos)
        end
    end)
    return true
end

-- Keep circling instead of standing inside enemy hitboxes. Using CFrame and a
-- Y-only velocity helper may work for client-owned characters; enemy server AI
-- and damage/collision detection cannot be changed from this client script.
local function orbitEnemy(targetRoot, t)
    if not root or not root.Parent or not targetRoot or not targetRoot.Parent then return end
    if not state.safeFarm then
        releaseHover()
        moveNear(targetRoot, 4.5, true)
        return
    end
    holdVertical()
    local angle = t * 2.35 + orbitSeed
    local radius = 3.0
    local pos = targetRoot.Position + Vector3.new(
        math.cos(angle) * radius,
        hoverNow,
        math.sin(angle) * radius
    )
    pcall(function()
        root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
        root.CFrame = CFrame.lookAt(pos, targetRoot.Position + Vector3.new(0, 1, 0))
    end)
end

local function retreatFromEnemy(targetRoot, ratio)
    releaseHover()
    if not root or not root.Parent then return end
    local away = nil
    if targetRoot then
        local delta = root.Position - targetRoot.Position
        local horizontal = Vector3.new(delta.X, 0, delta.Z)
        if horizontal.Magnitude > .1 then away = horizontal.Unit end
    end
    if not away then away = Vector3.new(1, 0, 0) end
    local destination
    if safePoint and (safePoint - root.Position).Magnitude < 350 then
        destination = safePoint + Vector3.new(0, 3, 0)
    else
        destination = root.Position + away * 32 + Vector3.new(0, 5, 0)
    end
    pcall(function() root.CFrame = CFrame.new(destination) end)
    retreatAt = os.clock()
    retreatReason = 'HP ' .. math.floor(ratio * 100) .. '%. Отступил, ждём восстановления до 75%.'
    status(retreatReason)
end

local function equipTool()
    if not char or not hum then return nil end
    local equipped = char:FindFirstChildWhichIsA('Tool')
    if equipped then return equipped end
    local backpack = player:FindFirstChildOfClass('Backpack')
    if not backpack then return nil end
    local tool = backpack:FindFirstChildWhichIsA('Tool')
    if tool then pcall(function() hum:EquipTool(tool) end) end
    return tool
end
local function findAttackButton()
    local pg = player:FindFirstChildOfClass('PlayerGui')
    if not pg then return nil end
    for _, b in ipairs(pg:GetDescendants()) do
        if b:IsA('GuiButton') and b.Visible and b.AbsoluteSize.X > 15
            and not (gui and b:IsDescendantOf(gui)) then
            local name = lower(b.Name)
            local caption = b:IsA('TextButton') and lower(b.Text) or ''
            if contains(name, {'attack', 'swing', 'slash', 'hit', 'basicattack', 'm1'})
                or contains(caption, {'attack', 'swing', 'slash', 'hit'}) then
                return b
            end
        end
    end
    return nil
end
local function pressAttack()
    local attempts = {}
    local tool = equipTool()
    if tool then
        local ok = pcall(function() tool:Activate() end)
        if ok then attempts[#attempts + 1] = 'Tool' end
    end
    local btn = findAttackButton()
    if btn then
        local ok = pcall(function() btn:Activate() end)
        if ok then attempts[#attempts + 1] = 'GUI' end
        if type(firesignal) == 'function' then
            pcall(function() firesignal(btn.Activated) end)
            attempts[#attempts + 1] = 'Signal'
        end
    end
    -- Games without classic Roblox Tools may listen to pointer presses (M1).
    local cam = Workspace.CurrentCamera
    if cam then
        local vp = cam.ViewportSize
        local x, y = math.floor(vp.X * 0.57), math.floor(vp.Y * 0.52)
        local ok = pcall(function()
            VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
            VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
        end)
        if ok then attempts[#attempts + 1] = 'M1' end
        if #attempts == 0 then
            ok = pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:Button1Down(Vector2.new(x, y), cam.CFrame)
                VirtualUser:Button1Up(Vector2.new(x, y), cam.CFrame)
            end)
            if ok then attempts[#attempts + 1] = 'VU' end
        end
    end
    return #attempts > 0 and table.concat(attempts, '+') or 'NO_INPUT'
end

local function collectViaGui()
    local pg = player:FindFirstChildOfClass('PlayerGui')
    if not pg then return nil end
    for _, b in ipairs(pg:GetDescendants()) do
        if b:IsA('GuiButton') and b.Visible and b.AbsoluteSize.X >= 12
            and not (gui and b:IsDescendantOf(gui)) then
            local t = lower(b.Name) .. ' ' .. (b:IsA('TextButton') and lower(b.Text) or '')
            if contains(t, {'collect all', 'take all', 'pick up', 'pickup', 'collect loot', 'loot all'})
                or lower(b.Name) == 'collectbutton' or lower(b.Name) == 'lootbutton' then
                local ok = pcall(function() b:Activate() end)
                if ok then return b.Name end
            end
        end
    end
    return nil
end

local function interactLoot(rec)
    if not rec or not rec.object.Parent or not rec.part.Parent then return end
    local part = rec.part
    local d = root and (root.Position - part.Position).Magnitude or 1000
    if d > 8 then moveNear(part, 2.8, false) end
    local methods = {}
    -- A prompt is NOT necessarily named "Loot"; it can say "Take" or "Pick up".
    for _, p in ipairs(rec.prompts) do
        if p.Parent and p.Enabled then
            if type(fireproximityprompt) == 'function' then
                if pcall(function() fireproximityprompt(p) end) then
                    methods[#methods + 1] = 'Prompt'
                end
            else
                pcall(function()
                    p:InputHoldBegin()
                    task.delay(math.max(0.08, p.HoldDuration + 0.05), function()
                        if p and p.Parent then pcall(function() p:InputHoldEnd() end) end
                    end)
                end)
                methods[#methods + 1] = 'Hold'
            end
        end
    end
    for _, click in ipairs(rec.clicks) do
        if click.Parent and type(fireclickdetector) == 'function' then
            if pcall(function() fireclickdetector(click) end) then methods[#methods + 1] = 'Click' end
        end
    end
    if type(firetouchinterest) == 'function' then
        local toucher = char and (char:FindFirstChild('HumanoidRootPart') or char:FindFirstChild('RightFoot')
            or char:FindFirstChildWhichIsA('BasePart'))
        if toucher then
            local ok = pcall(function()
                firetouchinterest(toucher, part, 0)
                firetouchinterest(toucher, part, 1)
            end)
            if ok then methods[#methods + 1] = 'Touch' end
        end
    end
    -- Physical pickup fallback: stand on the drop so regular Touched logic can run.
    if #methods == 0 then
        pcall(function()
            root.CFrame = CFrame.new(part.Position + Vector3.new(0, 2.4, 0))
        end)
        methods[#methods + 1] = 'Proximity'
        -- Mobile games sometimes use world taps rather than ProximityPrompts.
        local cam = Workspace.CurrentCamera
        if cam then
            local screenPos, onScreen = cam:WorldToViewportPoint(part.Position)
            if onScreen and screenPos.Z > 0 then
                local ok = pcall(function()
                    VirtualInputManager:SendMouseButtonEvent(screenPos.X, screenPos.Y, 0, true, game, 0)
                    VirtualInputManager:SendMouseButtonEvent(screenPos.X, screenPos.Y, 0, false, game, 0)
                end)
                if ok then methods[#methods + 1] = 'Tap' end
            end
        end
    end
    lootAttempts[rec.object] = os.clock()
    status('Лут: ' .. rec.object.Name .. ' | попытка: ' .. table.concat(methods, '+'))
end

-- Minimal mobile UI, no external libraries.
local guiParent = player:WaitForChild('PlayerGui')
if type(gethui) == 'function' then
    local ok, custom = pcall(gethui)
    if ok and custom then guiParent = custom end
end

gui = Instance.new('ScreenGui')
gui.Name = 'PolyLoot_Delta_v3'
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 99999
gui.Parent = guiParent
local function rounded(obj)
    local c = Instance.new('UICorner')
    c.CornerRadius = UDim.new(0, 8)
    c.Parent = obj
end
local function button(parent, textValue, sz, pos)
    local b = Instance.new('TextButton')
    b.Size = sz
    if pos then b.Position = pos end
    b.BackgroundColor3 = Color3.fromRGB(45, 54, 74)
    b.TextColor3 = Color3.new(1, 1, 1)
    b.Font = Enum.Font.GothamSemibold
    b.TextSize = 13
    b.Text = textValue
    b.BorderSizePixel = 0
    b.Parent = parent
    rounded(b)
    return b
end
main = Instance.new('Frame')
main.Size = UDim2.new(0, 294, 0, 432)
main.Position = UDim2.new(0.5, -147, 0.5, -216)
main.BackgroundColor3 = Color3.fromRGB(25, 29, 43)
main.BorderSizePixel = 0
main.Active = true
main.Parent = gui
rounded(main)
local top = Instance.new('Frame')
top.Size = UDim2.new(1, 0, 0, 42)
top.BackgroundColor3 = Color3.fromRGB(34, 41, 60)
top.Active = true
top.Parent = main
rounded(top)
local title = Instance.new('TextLabel')
title.Position = UDim2.new(0, 9, 0, 0)
title.Size = UDim2.new(1, -90, 1, 0)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBold
title.TextSize = 14
title.TextColor3 = Color3.fromRGB(240, 240, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = 'POLY LOOT v3 | DELTA'
title.Parent = top
local hide = button(top, '_', UDim2.new(0, 34, 0, 30), UDim2.new(1, -76, 0, 6))
local close = button(top, 'X', UDim2.new(0, 34, 0, 30), UDim2.new(1, -38, 0, 6))
close.BackgroundColor3 = Color3.fromRGB(140, 54, 63)
local scroll = Instance.new('ScrollingFrame')
scroll.Position = UDim2.new(0, 9, 0, 48)
scroll.Size = UDim2.new(1, -18, 1, -137)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 3
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.Parent = main
local layout = Instance.new('UIListLayout')
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 5)
layout.Parent = scroll
local order = 0
local function addButton(label, fn)
    order = order + 1
    local b = button(scroll, label, UDim2.new(1, -5, 0, 36))
    b.LayoutOrder = order
    connect(b.MouseButton1Click, fn)
    return b
end
local function toggle(label, key)
    local b
    b = addButton(label .. (state[key] and '  [ON]' or '  [OFF]'), function()
        state[key] = not state[key]
        b.Text = label .. (state[key] and '  [ON]' or '  [OFF]')
        b.BackgroundColor3 = state[key] and Color3.fromRGB(29, 110, 88) or Color3.fromRGB(45, 54, 74)
        if key == 'noclip' and not state[key] then restoreCollision() end
        if key == 'safeFarm' and not state[key] then releaseHover() end
        if key == 'farm' then
            retreatActive = false
            hoverNow, attacksWithoutDamage = hoverBase, 0
            if state[key] and root then safePoint = safePoint or root.Position end
            if not state[key] then releaseHover() end
        end
        if key == 'autoRetreat' and not state[key] then retreatActive = false end
        if key == 'mobESP' and not state[key] then clearMarks('enemy') end
        if key == 'lootESP' and not state[key] then clearMarks('loot') end
        if key == 'speed' or key == 'jump' then applyMovement() end
        if key == 'farm' or key == 'loot' or key == 'mobESP' or key == 'lootESP' then scan(true) end
        status(label .. (state[key] and ': включено.' or ': выключено.'))
    end)
    b.BackgroundColor3 = state[key] and Color3.fromRGB(29, 110, 88) or Color3.fromRGB(45, 54, 74)
end

toggle('AUTO FARM / АТАКА', 'farm')
toggle('FAST ATTACK ~0.16c', 'fastAttack')
toggle('SAFE FARM (ОРБИТА)', 'safeFarm')
toggle('AUTO RETREAT (HP 35%)', 'autoRetreat')
addButton('ВЫСОТА SAFE: 5 (настроить)', function()
    hoverBase = hoverBase >= 9 and 3 or hoverBase + 2
    hoverNow = hoverBase
    status('Высота над врагом = ' .. hoverBase
        .. '. Если урон не проходит — уменьшай высоту.')
end)
addButton('ЗАПОМНИТЬ БЕЗОПАСНОЕ МЕСТО', function()
    if root and root.Parent then
        safePoint = root.Position
        status('Точка отхода сохранена: ' .. tostring(safePoint))
    end
end)
toggle('AUTO LOOT / СБОР', 'loot')
toggle('ESP ВРАГИ (НЕ NPC)', 'mobESP')
toggle('ESP ЛУТ / СУНДУКИ', 'lootESP')
toggle('SPEED x2', 'speed')
toggle('HIGH JUMP', 'jump')
toggle('NOCLIP', 'noclip')
toggle('INFINITE JUMP', 'infJump')

addButton('ОБУЧИТЬ: ближайший моб', function()
    scan(true)
    local chosen, dist = nil, 18
    if not root then return status('Персонаж ещё не появился.') end
    for _, model in ipairs(unknownHumanoids) do
        local p = getRoot(model)
        if p then
            local d = (p.Position - root.Position).Magnitude
            if d < dist then chosen, dist = model, d end
        end
    end
    if chosen then
        taughtEnemies[chosen.Name] = true
        scan(true)
        status('Запомнил врага: ' .. chosen.Name .. '. Теперь ESP/фарм видят этот тип.')
    else
        status('В пределах 18 studs нет неопознанного NPC. Подойди к монстру.')
    end
end)

local function debugReport()
    scan(true)
    local lines = {
        'POLY LOOT v3 | PlaceId: ' .. tostring(game.PlaceId),
        'Enemies: ' .. #allEnemies .. ' | Loot: ' .. #allLoot .. ' | Unknown NPC: ' .. #unknownHumanoids,
        'Models: ' .. diagnosticStats.models .. ' | Humanoids: ' .. diagnosticStats.humanoids,
        'Prompts: ' .. diagnosticStats.prompts .. ' | Click: ' .. diagnosticStats.clicks
            .. ' | Tools in world: ' .. diagnosticStats.looseTools,
        'Player tool: ' .. tostring(char and char:FindFirstChildWhichIsA('Tool') and
            char:FindFirstChildWhichIsA('Tool').Name or 'none'),
        'Attack GUI: ' .. tostring(findAttackButton() and findAttackButton().Name or 'none'),
        'Safety: orbit=' .. tostring(state.safeFarm) .. ' | fast=' .. tostring(state.fastAttack)
            .. ' | retreat=' .. tostring(state.autoRetreat),
        'Height: ' .. tostring(hoverNow) .. ' | Attacks: ' .. tostring(attackCount)
            .. ' | Confirmed damage: ' .. tostring(math.floor(targetDamage)),
        'Player HP: ' .. tostring(hum and hum.Health or 'unknown')
    }
    local function pushExamples(label, list, maxCount, getName)
        lines[#lines + 1] = label
        for i = 1, math.min(maxCount, #list) do
            lines[#lines + 1] = tostring(i) .. ': ' .. getName(list[i])
        end
    end
    pushExamples('Enemy models:', allEnemies, 8, function(m) return m:GetFullName() end)
    pushExamples('Unknown humanoids:', unknownHumanoids, 8, function(m) return m:GetFullName() end)
    pushExamples('Loot candidates:', allLoot, 10, function(r) return r.object:GetFullName()
        .. ' | score=' .. r.score .. ' | prompt=' .. #r.prompts .. ' | click=' .. #r.clicks end)
    local out = table.concat(lines, '\n')
    print('[PolyLoot v3] DIAGNOSTICS\n' .. out)
    local copied = false
    if type(setclipboard) == 'function' then copied = pcall(function() setclipboard(out) end) end
    if not copied and type(writefile) == 'function' then
        copied = pcall(function() writefile('polyloot_v3_debug.txt', out) end)
    end
    status('Скан: враги=' .. #allEnemies .. ', лут=' .. #allLoot ..
        ', NPC=' .. #unknownHumanoids .. (copied and '. Лог скопирован/сохранён.' or '. Лог в консоли Delta.'))
end
addButton('ДИАГНОСТИКА / СКОПИРОВАТЬ', debugReport)

statusLabel = Instance.new('TextLabel')
statusLabel.Position = UDim2.new(0, 11, 1, -83)
statusLabel.Size = UDim2.new(1, -22, 0, 75)
statusLabel.BackgroundTransparency = 1
statusLabel.TextColor3 = Color3.fromRGB(192, 211, 229)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 12
statusLabel.TextWrapped = true
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.TextYAlignment = Enum.TextYAlignment.Center
statusLabel.Text = hint
statusLabel.Parent = main
bubble = button(gui, 'PL3', UDim2.new(0, 54, 0, 54), UDim2.new(0, 14, 0.5, -27))
bubble.BackgroundColor3 = Color3.fromRGB(32, 117, 107)
bubble.Visible = false
connect(hide.MouseButton1Click, function() main.Visible = false; bubble.Visible = true end)
connect(bubble.MouseButton1Click, function() main.Visible = true; bubble.Visible = false end)
connect(close.MouseButton1Click, stop)

-- Touch drag of the top bar.
local dragging, dragInput, dragStart, startPos = false, nil, nil, nil
connect(top.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging, dragInput, dragStart, startPos = true, input, input.Position, main.Position
    end
end)
connect(UIS.InputChanged, function(input)
    if not dragging or not dragInput then return end
    if input == dragInput or (dragInput.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseMovement) then
        local delta = input.Position - dragStart
        main.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + delta.X,
            startPos.Y.Scale, startPos.Y.Offset + delta.Y)
    end
end)
connect(UIS.InputEnded, function(input)
    if input == dragInput then dragging = false; dragInput = nil end
end)
connect(UIS.JumpRequest, function()
    if alive and state.infJump and hum then
        pcall(function() hum:ChangeState(Enum.HumanoidStateType.Jumping) end)
    end
end)
connect(RunService.Stepped, function()
    if not alive or not state.noclip or not char then return end
    for _, part in ipairs(char:GetDescendants()) do
        if part:IsA('BasePart') then
            if collisions[part] == nil then collisions[part] = part.CanCollide end
            part.CanCollide = false
        end
    end
end)

-- Primary loop: 1) scan/ESP, 2) collect nearby drops, 3) attack recognized monsters.
task.spawn(function()
    while alive do
        local ok, err = pcall(function()
            if char and not hum then hum = char:FindFirstChildWhichIsA('Humanoid') end
            if char and (not root or not root.Parent) then root = getRoot(char) end
            if state.speed or state.jump then applyMovement() end
            if state.farm or state.loot or state.mobESP or state.lootESP then
                scan(false)
                if state.mobESP or state.lootESP then updateESP() end
            end
            if not root or not hum or hum.Health <= 0 then return end
            local now = os.clock()
            local didLoot = false
            if state.loot and not retreatActive and now - lastLoot >= 0.7 then
                local guiCollect = collectViaGui()
                local rec = nearestLoot()
                if rec then
                    lastLoot = now
                    interactLoot(rec)
                    didLoot = true
                elseif guiCollect then
                    lastLoot = now
                    status('Сбор через меню: ' .. guiCollect .. ' (успех проверяется в игре)')
                end
            end
            -- Auto-retreat when server-confirmed health gets dangerously low.
            -- While recovering, the farm is paused instead of repeatedly dying.
            local hpRatio = hum.MaxHealth > 0 and hum.Health / hum.MaxHealth or 0
            if not state.farm then
                retreatActive = false
                releaseHover()
                lastObservedHP = hum.Health
            elseif state.autoRetreat and hpRatio <= .35 then
                if not retreatActive or now - retreatAt > 3 then
                    local _, nearestRoot = nearestEnemy()
                    retreatFromEnemy(nearestRoot, hpRatio)
                    retreatActive = true
                end
            elseif retreatActive and hpRatio >= .75 then
                retreatActive = false
                hoverNow, attacksWithoutDamage, lastEnemyHP = hoverBase, 0, nil
                status('HP восстановлены. Автофарм возобновлён.')
            end
            if retreatActive then
                releaseHover()
                if state.autoRetreat and hpRatio < .75 then
                    if now - retreatAt > 2.5 and hpRatio <= .35 then
                        local _, threatRoot = nearestEnemy()
                        retreatFromEnemy(threatRoot, hpRatio)
                    else
                        status('SAFE RETREAT: HP ' .. math.floor(hpRatio * 100)
                            .. '%, возврат к фарму при 75%.')
                    end
                end
                lastObservedHP = hum.Health
                return
            end
            local interval = state.fastAttack and attackIntervalFast or attackIntervalNormal
            if state.farm and not didLoot and now - lastAttack >= interval then
                local enemy, p = nearestEnemy()
                lastAttack = now
                if enemy and p then
                    if currentTarget ~= enemy then
                        currentTarget = enemy
                        targetDamage, attackCount = 0, 0
                        attacksWithoutDamage, lastEnemyHP = 0, nil
                        hoverNow = hoverBase
                        orbitSeed = math.random() * 6.28
                    end
                    local hBefore = getHealth(enemy)
                    if lastEnemyHP and hBefore then
                        if hBefore < lastEnemyHP then
                            targetDamage = targetDamage + (lastEnemyHP - hBefore)
                            attacksWithoutDamage = 0
                        elseif hBefore == lastEnemyHP then
                            attacksWithoutDamage = attacksWithoutDamage + 1
                        end
                    end
                    lastEnemyHP = hBefore
                    if state.safeFarm and lastObservedHP and hum.Health < lastObservedHP then
                        hoverNow = math.min(hoverMax, hoverNow + 1.3)
                    elseif state.safeFarm and attacksWithoutDamage > 17 then
                        hoverNow = math.max(hoverMin, hoverNow - 1.2)
                        attacksWithoutDamage = 0
                    end
                    orbitEnemy(p, now)
                    local mode = pressAttack()
                    attackCount = attackCount + 1
                    if attackCount > 20 and targetDamage == 0 then
                        status('Урон пока не подтверждён: ' .. enemy.Name
                            .. ' | ' .. mode .. ' | высота: ' .. math.floor(hoverNow * 10) / 10)
                    else
                        status('Фарм: ' .. enemy.Name .. ' | ' .. mode
                            .. ' | HP ' .. math.floor(hpRatio * 100) .. '%'
                            .. ' | урон: ' .. math.floor(targetDamage)
                            .. ' | ' .. (state.fastAttack and 'FAST' or 'NORMAL'))
                    end
                else
                    releaseHover()
                    if #unknownHumanoids > 0 then
                        status('Монстры не распознаны. Подойди к врагу и нажми ОБУЧИТЬ.')
                    else
                        status('Рядом нет живых монстров.')
                    end
                end
            end
            lastObservedHP = hum.Health

        end)
        if not ok then status('Ошибка v3: ' .. tostring(err):sub(1, 110)) end
        task.wait(0.07)
    end
end)

status('v3 готова: SAFE FARM + FAST ATTACK + RETREAT включены. Проверь результат в игре.')
print('[PolyLoot v3] Ready. No downloaded scripts. Server may reject faster hits or client evasion.')
