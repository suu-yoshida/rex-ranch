local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- helper function to check if player is ranch staff
---------------------------------------------
local function isPlayerRanchStaff(Player)
    if not Player or not Player.PlayerData.job then
        return false
    end
    
    local playerjob = Player.PlayerData.job.name
    
    -- Check if player's job matches any ranch job access
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            return true
        end
    end
    
    return false
end

---------------------------------------------
-- Spawn Management System
---------------------------------------------
local SpawnController = {
    activeSpawns = {},      -- [animalId] = {players, spawnTime, networkId, pos}
    spawnRequests = {},     -- Track pending spawn requests
    networkIds = {},        -- [animalId] = networkId for tracking networked entities
    config = {
        maxSpawnsPerPlayer = 10,    -- Max animals a single player can have spawned
        spawnTimeout = 30000,       -- Timeout for spawn requests (30s)
        cleanupInterval = 60000,    -- Cleanup interval (1 minute)
        broadcastRadius = 150.0     -- Radius to broadcast spawns to nearby players
    }
}

---------------------------------------------
-- Helper function to get nearby players
---------------------------------------------
local function GetNearbyPlayers(coords, radius)
    local nearbyPlayers = {}
    local players = GetPlayers()
    
    for _, playerId in ipairs(players) do
        local ped = GetPlayerPed(tonumber(playerId))
        if DoesEntityExist(ped) then
            local playerCoords = GetEntityCoords(ped)
            local distance = #(playerCoords - coords)
            if distance <= radius then
                table.insert(nearbyPlayers, tonumber(playerId))
            end
        end
    end
    
    return nearbyPlayers
end

---------------------------------------------
-- Initialize spawn controller
---------------------------------------------
function SpawnController:Initialize()
    -- Start cleanup thread
    CreateThread(function()
        while true do
            self:CleanupStaleData()
            Wait(self.config.cleanupInterval)
        end
    end)
    
    if Config.Debug then
        print('^2[SPAWN CONTROLLER]^7 Initialized new server spawn management')
    end
end

---------------------------------------------
-- Check if a player can spawn an animal
---------------------------------------------
function SpawnController:CanPlayerSpawn(playerId, animalId)
    -- Check if animal is already spawned
    if self.activeSpawns[animalId] then
        local spawnData = self.activeSpawns[animalId]
        
        -- First check if this data structure is valid
        if not spawnData.players then
            -- Invalid structure, clear it
            if Config.Debug then
                print('^3[SPAWN CONTROLLER]^7 Clearing invalid spawn data for animal ' .. animalId)
            end
            self.activeSpawns[animalId] = nil
        else
            -- Check if any of the players who have spawned this animal are still online AND nearby
            local anyPlayerNearby = false
            local playersToRemove = {}
            
            for spawnedByPlayerId, _ in pairs(spawnData.players) do
                local player = RSGCore.Functions.GetPlayer(spawnedByPlayerId)
                local isPlayerValid = false
                
                if player then
                    -- Player is online, check if they're still nearby
                    local ped = GetPlayerPed(spawnedByPlayerId)
                    if DoesEntityExist(ped) then
                        local playerCoords = GetEntityCoords(ped)
                        local animalCoords = vector3(spawnData.pos_x or 0, spawnData.pos_y or 0, spawnData.pos_z or 0)
                        local distance = #(playerCoords - animalCoords)
                        
                        -- Player is nearby if within 100m
                        if distance <= 100.0 then
                            anyPlayerNearby = true
                            isPlayerValid = true
                        end
                    end
                end
                
                -- Mark for removal if player is not valid
                if not isPlayerValid then
                    table.insert(playersToRemove, spawnedByPlayerId)
                end
            end
            
            -- Remove invalid players
            for _, removeId in ipairs(playersToRemove) do
                spawnData.players[removeId] = nil
                if Config.Debug then
                    print('^3[SPAWN CONTROLLER]^7 Removed player ' .. removeId .. ' from animal ' .. animalId .. ' spawn (out of range or offline)')
                end
            end
            
            -- If no players are nearby anymore, clear the spawn completely
            if not anyPlayerNearby then
                if Config.Debug then
                    print('^3[SPAWN CONTROLLER]^7 No players nearby for animal ' .. animalId .. ', clearing spawn')
                end
                self.activeSpawns[animalId] = nil
            else
                -- Animal is already spawned by someone nearby, allow this player to join
                spawnData.players[playerId] = true
                if Config.Debug then
                    print('^2[SPAWN CONTROLLER]^7 Player ' .. playerId .. ' joined existing spawn for animal ' .. animalId)
                end
                return true, "OK"
            end
        end
    end
    
    -- At this point, either the animal wasn't spawned or we cleared it
    -- Check player spawn limit before allowing new spawn
    local playerSpawnCount = 0
    for _, spawnData in pairs(self.activeSpawns) do
        if spawnData.players and spawnData.players[playerId] then
            playerSpawnCount = playerSpawnCount + 1
        end
    end
    
    if playerSpawnCount >= self.config.maxSpawnsPerPlayer then
        return false, "Too many animals spawned"
    end
    
    if Config.Debug then
        print('^2[SPAWN CONTROLLER]^7 Allowing new spawn for animal ' .. animalId .. ' by player ' .. playerId)
    end
    
    return true, "OK"
end

---------------------------------------------
-- Register an animal spawn
---------------------------------------------
function SpawnController:RegisterSpawn(playerId, animalId, animalData, networkId)
    if not self.activeSpawns[animalId] then
        self.activeSpawns[animalId] = {
            players = {},
            spawnTime = os.time(),
            pos_x = animalData.pos_x,
            pos_y = animalData.pos_y,
            pos_z = animalData.pos_z,
            networkId = networkId or nil
        }
    end
    
    -- Add this player to the list of players who have spawned this animal
    self.activeSpawns[animalId].players[playerId] = true
    
    -- Update network ID if provided
    if networkId then
        self.activeSpawns[animalId].networkId = networkId
        self.networkIds[animalId] = networkId
    end
    
    if Config.Debug then
        local playerCount = 0
        for _ in pairs(self.activeSpawns[animalId].players) do
            playerCount = playerCount + 1
        end
        print('^2[SPAWN CONTROLLER]^7 Registered spawn - Player: ' .. playerId .. ', Animal: ' .. animalId .. ' (Total players: ' .. playerCount .. ', netId: ' .. tostring(networkId or 'none') .. ')')
    end
end

---------------------------------------------
-- Unregister an animal spawn
---------------------------------------------
function SpawnController:UnregisterSpawn(animalId)
    if self.activeSpawns[animalId] then
        if Config.Debug then
            print('^3[SPAWN CONTROLLER]^7 Unregistered spawn - Animal: ' .. animalId)
        end
        self.activeSpawns[animalId] = nil
        self.networkIds[animalId] = nil
    end
end

-- Get spawn count for player
function SpawnController:GetPlayerSpawnCount(playerId)
    local count = 0
    for _, spawnData in pairs(self.activeSpawns) do
        if spawnData.players and spawnData.players[playerId] then
            count = count + 1
        end
    end
    return count
end

---------------------------------------------
-- Cleanup stale data
---------------------------------------------
function SpawnController:CleanupStaleData()
    local currentTime = os.time()
    local cleanedCount = 0
    
    -- Clean up stale spawn requests (requests that were never completed)
    for animalId, requestData in pairs(self.spawnRequests) do
        if (currentTime - requestData.timestamp) > (self.config.spawnTimeout / 1000) then
            self.spawnRequests[animalId] = nil
            cleanedCount = cleanedCount + 1
        end
    end
    
    -- Clean up spawns for disconnected players
    local playersToCheck = {}
    for animalId, spawnData in pairs(self.activeSpawns) do
        if spawnData.players then
            local playersToRemove = {}
            
            -- Check each player who has spawned this animal
            for playerId, _ in pairs(spawnData.players) do
                if not playersToCheck[playerId] then
                    local player = RSGCore.Functions.GetPlayer(playerId)
                    playersToCheck[playerId] = player ~= nil
                end
                
                -- Mark disconnected players for removal
                if not playersToCheck[playerId] then
                    table.insert(playersToRemove, playerId)
                end
            end
            
            -- Remove disconnected players
            for _, playerId in ipairs(playersToRemove) do
                spawnData.players[playerId] = nil
                cleanedCount = cleanedCount + 1
            end
            
            -- If no players left, clear the entire spawn
            local hasPlayers = false
            for _ in pairs(spawnData.players) do
                hasPlayers = true
                break
            end
            
            if not hasPlayers then
                self.activeSpawns[animalId] = nil
            end
        end
    end
    
    if Config.Debug and cleanedCount > 0 then
        print('^3[SPAWN CONTROLLER]^7 Cleaned up ' .. cleanedCount .. ' stale spawn entries')
    end
end

---------------------------------------------
-- Clear all spawns for a player
---------------------------------------------
function SpawnController:ClearPlayerSpawns(playerId)
    local clearedCount = 0
    for animalId, spawnData in pairs(self.activeSpawns) do
        if spawnData.players and spawnData.players[playerId] then
            spawnData.players[playerId] = nil
            
            -- If no players left, clear the entire spawn
            local hasPlayers = false
            for _ in pairs(spawnData.players) do
                hasPlayers = true
                break
            end
            
            if not hasPlayers then
                self.activeSpawns[animalId] = nil
            end
            
            clearedCount = clearedCount + 1
        end
    end
    
    if Config.Debug and clearedCount > 0 then
        print('^3[SPAWN CONTROLLER]^7 Cleared ' .. clearedCount .. ' spawns for disconnected player ' .. playerId)
    end
end

---------------------------------------------
-- Initialize the spawn controller
---------------------------------------------
SpawnController:Initialize()

---------------------------------------------
-- ranch storage
---------------------------------------------
RegisterNetEvent('rex-ranch:server:ranchstorage', function(data)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then return end
    local playerjob = Player.PlayerData.job.name
    local playerjobgrade = Player.PlayerData.job.grade.level
    if playerjob ~= data.ranchid then return end
    if playerjobgrade < Config.StorageMinJobGrade then return end
    local stashdata = { label = 'Ranch Storage', maxweight = Config.RanchStorageMaxWeight, slots = Config.RanchStorageMaxSlots }
    local stashName = data.ranchid
    exports['rsg-inventory']:OpenInventory(src, stashName, stashdata)
end)

---------------------------------------------
-- get gender-specific breeding cooldown
---------------------------------------------
local function GetBreedingCooldown(gender)
    if Config.GenderSpecificCooldowns and Config.GenderSpecificCooldowns[gender] then
        return Config.GenderSpecificCooldowns[gender]
    end
    
    -- Fallback to default cooldown
    return Config.BreedingCooldown or 172800
end

---------------------------------------------
-- select offspring model based on breeding config probabilities
---------------------------------------------
local function SelectOffspringModel(parentModel)
    local breedingConfig = Config.BreedingConfig[parentModel]
    if not breedingConfig or not breedingConfig.offspringModels then
        -- Fallback: return same model as parent
        return parentModel
    end
    
    local offspringModels = breedingConfig.offspringModels
    if #offspringModels == 0 then
        return parentModel
    end
    
    -- Calculate total chance for normalization
    local totalChance = 0
    for _, offspring in ipairs(offspringModels) do
        totalChance = totalChance + offspring.chance
    end
    
    if totalChance == 0 then
        return parentModel
    end
    
    -- Generate random number and select model
    local randomValue = math.random() * totalChance
    local currentChance = 0
    
    for _, offspring in ipairs(offspringModels) do
        currentChance = currentChance + offspring.chance
        if randomValue <= currentChance then
            if Config.Debug then
                print('^3[BREEDING DEBUG]^7 Selected offspring model: ' .. offspring.model .. ' (chance: ' .. offspring.chance .. '/' .. totalChance .. ')')
            end
            return offspring.model
        end
    end
    
    -- Fallback: return the first model
    if Config.Debug then
        print('^1[BREEDING ERROR]^7 Failed to select offspring model, using first option: ' .. offspringModels[1].model)
    end
    return offspringModels[1].model
end

---------------------------------------------
-- create unique animalid
---------------------------------------------
local function CreateAnimalId()
    local UniqueFound = false
    local animalid = nil
    local maxAttempts = 50 -- Reduced attempts for better performance
    local attempts = 0
    
    while not UniqueFound and attempts < maxAttempts do
        attempts = attempts + 1
        animalid = math.random(Config.ANIMAL_ID_MIN, Config.ANIMAL_ID_MAX)
        
        local success, result = pcall(function()
            return MySQL.query.await("SELECT COUNT(*) as count FROM rex_ranch_animals WHERE animalid = ?", { animalid })
        end)
        
        if success and result and result[1] and result[1].count == 0 then
            UniqueFound = true
        elseif not success then
            if Config.Debug then
                print("^1[ERROR]^7 Database error in CreateAnimalId: " .. tostring(result))
            end
            break
        end
    end
    
    if not UniqueFound then
        -- Better fallback: use timestamp + server ID + random for uniqueness
        local serverTime = os.time()
        local randomSuffix = math.random(Config.FALLBACK_ID_SUFFIX_MIN, Config.FALLBACK_ID_SUFFIX_MAX)
        animalid = tostring(serverTime) .. tostring(randomSuffix)
        -- Ensure it's not too long by taking last N characters
        if string.len(animalid) > Config.MAX_ID_LENGTH then
            animalid = string.sub(animalid, -Config.MAX_ID_LENGTH)
        end
        if Config.Debug then
            print("^3[WARNING]^7 Used fallback animal ID generation: " .. animalid)
        end
    end
    
    return tonumber(animalid) -- Ensure consistent numeric ID
end

---------------------------------------------
-- Spawn Event Handlers
---------------------------------------------

-- Handle spawn requests from clients
RegisterNetEvent('rex-ranch:server:requestAnimalSpawn', function(animalId, animalData)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    -- Allow everyone to spawn/see animals, but interactions are still restricted client-side
    if not Player then
        TriggerClientEvent('rex-ranch:client:spawnAnimalDenied', src, animalId, 'Player not found')
        return
    end
    
    -- Check if spawn is allowed
    local canSpawn, reason = SpawnController:CanPlayerSpawn(src, animalId)
    if not canSpawn then
        TriggerClientEvent('rex-ranch:client:spawnAnimalDenied', src, animalId, reason)
        return
    end
    
    -- Check if this animal already has a network ID (spawned by another player)
    local existingNetworkId = SpawnController.activeSpawns[animalId] and SpawnController.activeSpawns[animalId].networkId
    
    -- Register the spawn
    SpawnController:RegisterSpawn(src, animalId, animalData, existingNetworkId)
    
    if existingNetworkId then
        -- Entity already exists, just tell this player to use it
        TriggerClientEvent('rex-ranch:client:spawnAnimalGranted', src, animalId, animalData, existingNetworkId)
        if Config.Debug then
            print('^2[SPAWN CONTROLLER]^7 Player ' .. src .. ' using existing entity for animal ' .. animalId .. ' (netId: ' .. existingNetworkId .. ')')
        end
    else
        -- No entity exists yet - only requesting player creates it
        -- isCreator = true means this client should create the networked entity
        TriggerClientEvent('rex-ranch:client:spawnAnimalGranted', src, animalId, animalData, nil, true)
        
        if Config.Debug then
            print('^2[SPAWN CONTROLLER]^7 Player ' .. src .. ' granted creation rights for animal ' .. animalId)
        end
    end
end)

-- Handle network ID registration from clients (when a client creates a networked entity)
RegisterNetEvent('rex-ranch:server:registerAnimalNetworkId', function(animalId, networkId)
    local src = source
    
    if not networkId or networkId <= 0 then
        if Config.Debug then
            print('^1[SPAWN CONTROLLER]^7 Invalid network ID received for animal ' .. animalId)
        end
        return
    end
    
    -- Update the spawn data with the network ID
    if SpawnController.activeSpawns[animalId] then
        SpawnController.activeSpawns[animalId].networkId = networkId
        SpawnController.networkIds[animalId] = networkId
        
        if Config.Debug then
            print('^2[SPAWN CONTROLLER]^7 Registered network ID ' .. networkId .. ' for animal ' .. animalId .. ' from player ' .. src)
        end
        
        -- Broadcast the network ID to other nearby players so they can sync
        local spawnData = SpawnController.activeSpawns[animalId]
        if spawnData.pos_x and spawnData.pos_y and spawnData.pos_z then
            local animalCoords = vector3(spawnData.pos_x, spawnData.pos_y, spawnData.pos_z)
            local nearbyPlayers = GetNearbyPlayers(animalCoords, SpawnController.config.broadcastRadius)
            
            for _, playerId in ipairs(nearbyPlayers) do
                if playerId ~= src then
                    -- Get animal data from the spawn
                    local animalData = {
                        pos_x = spawnData.pos_x,
                        pos_y = spawnData.pos_y,
                        pos_z = spawnData.pos_z,
                        model = spawnData.model
                    }
                    TriggerClientEvent('rex-ranch:client:spawnAnimalGranted', playerId, animalId, animalData, networkId)
                end
            end
        end
    end
end)

---------------------------------------------
-- count amount of animals the ranch owns
---------------------------------------------
RSGCore.Functions.CreateCallback('rex-ranch:server:countanimals', function(src, cb, ranchid)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not ranchid then 
        cb(0)
        return 
    end
    
    local success, result = pcall(function()
        return MySQL.query.await("SELECT COUNT(*) as count FROM rex_ranch_animals WHERE ranchid = ?", { ranchid })
    end)
    
        if success and result and result[1] then
            cb(result[1].count or 0)
        else
            cb(0)
            if Config.Debug then
                print("^1[ERROR]^7 Failed to query animal count for ranchid: " .. tostring(ranchid))
            end
        end
end)

---------------------------------------------
-- send animals to client side from database
---------------------------------------------
RegisterNetEvent('rex-ranch:server:refreshAnimals', function()
    local src = source -- Get the requesting client
    local success, error = pcall(function()
        MySQL.query('SELECT * FROM `rex_ranch_animals`', {}, function(animals, error)
            if error then
                print('^1[ERROR]^7 Database query failed in refreshAnimals: ' .. tostring(error))
                return
            end
            
            if animals and #animals > 0 then
                -- Debug: Check pregnancy status in data being sent
                if Config.Debug then
                    for i, animal in ipairs(animals) do
                        if animal.pregnant == 1 then
                            print('^3[DEBUG PREGNANCY]^7 Animal ' .. animal.animalid .. ' is pregnant (gestation_end_time: ' .. tostring(animal.gestation_end_time) .. ')')
                        end
                    end
                end
                
                -- Send only to the requesting client, not all clients (-1)
                TriggerClientEvent('rex-ranch:client:spawnAnimals', src, animals)
                if Config.Debug then
                    print('^2[DEBUG]^7 Successfully sent ' .. #animals .. ' animals entries to client ' .. src)
                end
            else
                if Config.Debug then
                    print('^3[INFO]^7 No animals found in database.')
                end
            end
        end)
    end)
    
    if not success then
        if Config.Debug then
            print('^1[ERROR]^7 Critical error in refreshAnimals: ' .. tostring(error))
        end
    end
end)

---------------------------------------------
-- save animal position to database
---------------------------------------------
RegisterNetEvent('rex-ranch:server:saveAnimalPosition', function(animalid, pos_x, pos_y, pos_z, pos_w)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not animalid then return end
    -- update the animal's position in the database
    MySQL.update.await('UPDATE rex_ranch_animals SET pos_x = ?, pos_y = ?, pos_z = ?, pos_w = ? WHERE animalid = ?', {
        pos_x,
        pos_y,
        pos_z,
        pos_w,
        animalid
    })
    -- Update only the specific client with position change
    TriggerClientEvent('rex-ranch:client:refreshSingleAnimal', src, animalid, {pos_x = pos_x, pos_y = pos_y, pos_z = pos_z, pos_w = pos_w})
end)

---------------------------------------------
-- on restart send animals to client from database
---------------------------------------------
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() == resourceName then
        Wait(5000)
        MySQL.query('SELECT * FROM `rex_ranch_animals`', {}, function(animals)
            if animals then
                -- Debug: Check pregnancy status in restart data
                for i, animal in ipairs(animals) do
                    if animal.pregnant == 1 then
                        print('^3[RESTART DEBUG]^7 Animal ' .. animal.animalid .. ' is pregnant (gestation_end_time: ' .. tostring(animal.gestation_end_time) .. ')')
                    end
                end
                
                TriggerClientEvent('rex-ranch:client:spawnAnimals', -1, animals)
                print('^2[REX-RANCH]^7 Sent ' .. #animals .. ' animals entries to clients.')
            end
        end)
    end
end)

---------------------------------------------
-- Handle client reporting animal despawn
---------------------------------------------
RegisterNetEvent('rex-ranch:server:reportDespawn', function(animalId)
    local src = source
    
    if SpawnController.activeSpawns[animalId] then
        local spawnData = SpawnController.activeSpawns[animalId]
        
        if spawnData.players and spawnData.players[src] then
            spawnData.players[src] = nil
            
            if Config.Debug then
                print('^3[SPAWN CONTROLLER]^7 Player ' .. src .. ' despawned animal ' .. animalId)
            end
            
            -- Check if any players are still tracking this animal
            local hasPlayers = false
            for _ in pairs(spawnData.players) do
                hasPlayers = true
                break
            end
            
            -- If no players left, clear the spawn
            if not hasPlayers then
                SpawnController.activeSpawns[animalId] = nil
                if Config.Debug then
                    print('^3[SPAWN CONTROLLER]^7 All players despawned animal ' .. animalId .. ', clearing server tracking')
                end
            end
        end
    end
end)

---------------------------------------------
-- Handle player disconnects
---------------------------------------------
AddEventHandler('playerDropped', function(reason)
    local src = source
    SpawnController:ClearPlayerSpawns(src)
end)

---------------------------------------------
-- feed animal system
---------------------------------------------
RegisterNetEvent('rex-ranch:server:feedAnimal', function(data)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    -- Validate player is ranch staff
    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You must be ranch staff to feed animals!'})
        return
    end
    
    -- Handle both string and object parameters for backwards compatibility
    local animalid
    if type(data) == 'table' and data.animalid then
        animalid = data.animalid
    elseif type(data) == 'string' or type(data) == 'number' then
        animalid = tostring(data)
    else
        animalid = nil
    end
    
    if not animalid then return end
    
    -- Check if player has animal feed in inventory
    local hasFood = Player.Functions.GetItemByName(Config.FeedItem)
    if not hasFood or hasFood.amount < 1 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You need ' .. Config.FeedItem .. ' to feed the animals!'})
        return
    end
    
    -- First verify animal exists and get current stats for debugging
    local animalData = MySQL.query.await('SELECT animalid, hunger, health, thirst FROM rex_ranch_animals WHERE animalid = ?', {animalid})
    if not animalData or #animalData == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Animal not found!'})
        if Config.Debug then
            print('^1[DEBUG]^7 Player ' .. src .. ' tried to feed non-existent animal ' .. animalid)
        end
        return
    end
    
    local animal = animalData[1]
    if Config.Debug then
        print('^3[DEBUG]^7 Feeding animal ' .. animalid .. ' - Current hunger: ' .. (animal.hunger or 'null') .. ', health: ' .. (animal.health or 'null') .. ', thirst: ' .. (animal.thirst or 'null'))
    end
    
    -- Calculate health boost if animal is unhealthy
    local healthBoost = 0
    if animal.health < 100 and Config.ImmediateHealthBoost then
        healthBoost = math.min(Config.ImmediateHealthBoost, 100 - animal.health)
    end
    local newHealth = math.min(100, (animal.health or 100) + healthBoost)
    
    -- Update animal hunger and health
    local updateSuccess, updateError = pcall(function()
        return MySQL.update.await('UPDATE rex_ranch_animals SET hunger = 100, health = ? WHERE animalid = ?', {newHealth, animalid})
    end)
    
    if updateSuccess and updateError and updateError > 0 then
        Player.Functions.RemoveItem(Config.FeedItem, 1)
        if RSGCore.Shared.Items[Config.FeedItem] then
            TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[Config.FeedItem], 'remove', 1)
        end
        
        local notifyMsg = 'Animal has been fed!'
        if healthBoost > 0 then
            notifyMsg = notifyMsg .. ' Health improved by ' .. healthBoost .. '%!'
        end
        TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = notifyMsg})
        
        -- Send immediate update to client (no need for full refresh)
        TriggerClientEvent('rex-ranch:client:refreshSingleAnimal', src, animalid, {hunger = 100, health = newHealth})
        
        if Config.Debug then
            print('^2[DEBUG]^7 Player ' .. src .. ' successfully fed animal ' .. animalid .. ' (updated ' .. updateError .. ' rows)')
        end
    else
        if Config.Debug then
            print('^1[ERROR]^7 Failed to update hunger for animal ' .. animalid .. ' - Success: ' .. tostring(updateSuccess) .. ', Rows affected: ' .. tostring(updateError))
        end
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Failed to feed animal! Please try again.'})
    end
end)

---------------------------------------------
-- water animal system
---------------------------------------------
RegisterNetEvent('rex-ranch:server:waterAnimal', function(data)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    -- Validate player is ranch staff
    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You must be ranch staff to water animals!'})
        return
    end
    
    -- Handle both string and object parameters for backwards compatibility
    local animalid
    if type(data) == 'table' and data.animalid then
        animalid = data.animalid
    elseif type(data) == 'string' or type(data) == 'number' then
        animalid = tostring(data)
    else
        animalid = nil
    end
    
    if not animalid then return end
    
    -- Check if player has water bucket in inventory
    local item = Player.Functions.GetItemByName('water_bucket')
    if not item then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You need a water bucket to water the animals!'})
        return
    end
    
    -- Get current uses, default to 0 if no metadata
    local currentUses = (item.info and item.info.uses) or 0
    
    if currentUses <= 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Your water bucket is empty! Refill it at a water source.'})
        return
    end
    
    -- First verify animal exists and get current stats for debugging
    local animalData = MySQL.query.await('SELECT animalid, thirst, health, hunger FROM rex_ranch_animals WHERE animalid = ?', {animalid})
    if not animalData or #animalData == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Animal not found!'})
        if Config.Debug then
            print('^1[DEBUG]^7 Player ' .. src .. ' tried to water non-existent animal ' .. animalid)
        end
        return
    end
    
    local animal = animalData[1]
    if Config.Debug then
        print('^3[DEBUG]^7 Watering animal ' .. animalid .. ' - Current thirst: ' .. (animal.thirst or 'null') .. ', health: ' .. (animal.health or 'null') .. ', hunger: ' .. (animal.hunger or 'null'))
    end
    
    -- Calculate health boost if animal is unhealthy
    local healthBoost = 0
    if animal.health < 100 and Config.ImmediateHealthBoost then
        healthBoost = math.min(Config.ImmediateHealthBoost, 100 - animal.health)
    end
    local newHealth = math.min(100, (animal.health or 100) + healthBoost)
    
    -- Update animal thirst and health
    local updateSuccess, updateError = pcall(function()
        return MySQL.update.await('UPDATE rex_ranch_animals SET thirst = 100, health = ? WHERE animalid = ?', {newHealth, animalid})
    end)
    
    if updateSuccess and updateError and updateError > 0 then
        -- Remove old bucket and add new one with decreased uses
        Player.Functions.RemoveItem('water_bucket', 1, item.slot)
        
        local newUses = currentUses - 1
        local newDescription = newUses > 0 and ('Water Bucket - ' .. newUses .. ' use' .. (newUses > 1 and 's' or '') .. ' left') or 'Empty Water Bucket'
        Player.Functions.AddItem('water_bucket', 1, nil, {uses = newUses, description = newDescription})
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items['water_bucket'], 'remove', 1)
        
        local notifyMsg = 'Animal has been watered!'
        if healthBoost > 0 then
            notifyMsg = notifyMsg .. ' Health improved by ' .. healthBoost .. '%!'
        end
        TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = notifyMsg})
        
        -- Send immediate update to client (no need for full refresh)
        TriggerClientEvent('rex-ranch:client:refreshSingleAnimal', src, animalid, {thirst = 100, health = newHealth})
        
        if Config.Debug then
            print('^2[DEBUG]^7 Player ' .. src .. ' successfully watered animal ' .. animalid .. ' (updated ' .. updateError .. ' rows)')
        end
    else
        if Config.Debug then
            print('^1[ERROR]^7 Failed to update thirst for animal ' .. animalid .. ' - Success: ' .. tostring(updateSuccess) .. ', Rows affected: ' .. tostring(updateError))
        end
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Failed to water animal! Please try again.'})
    end
end)

---------------------------------------------
-- fill water bucket system
---------------------------------------------
RegisterNetEvent('rex-ranch:server:fillWaterBucket', function()
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if not Player then return end
    
    local item = Player.Functions.GetItemByName('water_bucket')
    
    if not item then
        TriggerClientEvent('ox_lib:notify', src, {title = 'No Bucket', type = 'error', duration = 3000 })
        return
    end
    
    -- Get current uses, default to 0 if no metadata
    local currentUses = (item.info and item.info.uses) or 0
    
    -- Only fill if bucket is empty (0 uses)
    if currentUses == 0 then
        Player.Functions.RemoveItem('water_bucket', 1, item.slot)
        Player.Functions.AddItem('water_bucket', 1, nil, {uses = 5, description = 'Water Bucket - 5 uses left'})
        TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items['water_bucket'], 'add', 1)
        TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = 'Water bucket filled!'})
    else
        TriggerClientEvent('ox_lib:notify', src, {title = 'Bucket Not Empty', type = 'error', duration = 3000 })
    end
end)

---------------------------------------------
-- collect animal product system
---------------------------------------------
RegisterNetEvent('rex-ranch:server:collectProduct', function(data)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    -- Validate player is ranch staff
    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You must be ranch staff to collect from animals!'})
        return
    end
    
    -- Handle both string and object parameters for backwards compatibility
    local animalid
    if type(data) == 'table' and data.animalid then
        animalid = data.animalid
    elseif type(data) == 'string' or type(data) == 'number' then
        animalid = tostring(data)
    else
        animalid = nil
    end
    
    if not animalid then
        if Config.Debug then
            print('^1[COLLECT ERROR]^7 Missing animalid - AnimalID: ' .. tostring(animalid))
        end
        return
    end
    
    -- Get animal data with comprehensive error handling
    local success, errorMsg = pcall(function()
        MySQL.query('SELECT model, product_ready, health, hunger, thirst FROM rex_ranch_animals WHERE animalid = ?', {animalid}, function(result)
            if not result or #result == 0 then
                TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Animal not found!'})
                if Config.Debug then
                    print('^1[COLLECT ERROR]^7 Animal ' .. animalid .. ' not found in database')
                end
                return
            end
        
        local animal = result[1]
        
        if Config.Debug then
            print('^3[COLLECT DEBUG]^7 Animal ' .. animalid .. ' collection attempt - product_ready: ' .. tostring(animal.product_ready))
        end
        
        if not animal.product_ready or animal.product_ready == 0 then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'No product ready to collect!'})
            if Config.Debug then
                print('^3[COLLECT DEBUG]^7 Animal ' .. animalid .. ' has no product ready (product_ready: ' .. tostring(animal.product_ready) .. ')')
            end
            return
        end
        
        -- Get product config
        local productConfig = Config.AnimalProducts[animal.model]
        if not productConfig then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'This animal does not produce anything!'})
            if Config.Debug then
                print('^1[COLLECT ERROR]^7 No product config found for animal model: ' .. tostring(animal.model))
            end
            return
        end
        
        if Config.Debug then
            print('^3[COLLECT DEBUG]^7 Attempting to give player ' .. src .. ' ' .. productConfig.amount .. 'x ' .. productConfig.product)
        end
        
        -- Give product to player with error handling
        local itemAdded = Player.Functions.AddItem(productConfig.product, productConfig.amount)
        if itemAdded then
            if RSGCore.Shared.Items[productConfig.product] then
                TriggerClientEvent('rsg-inventory:client:ItemBox', src, RSGCore.Shared.Items[productConfig.product], 'add', productConfig.amount)
            end
            
            -- Reset product ready status with proper error handling
            local resetSuccess, resetError = pcall(function()
                return MySQL.update.await('UPDATE rex_ranch_animals SET product_ready = 0 WHERE animalid = ?', {animalid})
            end)
            
            if resetSuccess and resetError and resetError > 0 then
                TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = 'Collected ' .. productConfig.amount .. ' ' .. productConfig.product .. '!'})
                
                -- Update client cache immediately (no need for full refresh)
                TriggerClientEvent('rex-ranch:client:refreshSingleAnimal', src, animalid, {product_ready = 0})
                
                if Config.Debug then
                    print('^2[COLLECT SUCCESS]^7 Player ' .. src .. ' successfully collected ' .. productConfig.amount .. 'x ' .. productConfig.product .. ' from animal ' .. animalid)
                end
            else
                if Config.Debug then
                    print('^1[COLLECT ERROR]^7 Failed to reset product_ready status for animal ' .. animalid .. ' - Success: ' .. tostring(resetSuccess) .. ', Result: ' .. tostring(resetError))
                end
                TriggerClientEvent('ox_lib:notify', src, {type = 'warning', description = 'Product collected but status update failed!'})
            end
        else
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Failed to add item to inventory!'})
            if Config.Debug then
                print('^1[COLLECT ERROR]^7 Failed to add ' .. productConfig.product .. ' to player ' .. src .. ' inventory')
            end
        end
        end)
    end)
    
    if not success then
        print('^1[ERROR]^7 Database error in collectProduct: ' .. tostring(errorMsg))
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Database error occurred!'})
    end
end)

---------------------------------------------
-- animal production status callback
---------------------------------------------
RSGCore.Functions.CreateCallback('rex-ranch:server:getAnimalProductionStatus', function(src, cb, animalid)
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if Config.Debug then
        print('^3[PRODUCTION DEBUG]^7 Production status request for animal ' .. tostring(animalid) .. ' from player ' .. src)
    end
    
    if not Player or not animalid or not isPlayerRanchStaff(Player) then
        if Config.Debug then
            print('^1[PRODUCTION DEBUG]^7 Request denied - Player: ' .. tostring(Player ~= nil) .. ', AnimalID: ' .. tostring(animalid) .. ', IsStaff: ' .. tostring(Player and isPlayerRanchStaff(Player)))
        end
        cb(false)
        return 
    end
    
    MySQL.query('SELECT model, product_ready, health, hunger, thirst, last_production, age, born FROM rex_ranch_animals WHERE animalid = ?', {animalid}, function(result)
        if Config.Debug then
            print('^3[PRODUCTION DEBUG]^7 Database query result for animal ' .. animalid .. ': ' .. (result and #result or 'nil/0') .. ' rows')
        end
        
        if not result or #result == 0 then
            if Config.Debug then
                print('^1[PRODUCTION DEBUG]^7 No animal found with ID: ' .. animalid)
            end
            cb(false)
            return
        end
        
        local animal = result[1]
        if Config.Debug then
            print('^3[PRODUCTION DEBUG]^7 Found animal - Model: ' .. tostring(animal.model) .. ', Product Ready: ' .. tostring(animal.product_ready))
        end
        
        local productConfig = Config.AnimalProducts[animal.model]
        if not productConfig then
            if Config.Debug then
                print('^1[PRODUCTION DEBUG]^7 No product config found for model: ' .. tostring(animal.model))
            end
            cb(false)
            return
        end
        
        if Config.Debug then
            print('^2[PRODUCTION DEBUG]^7 Product config found - Product: ' .. productConfig.product .. ', Amount: ' .. productConfig.amount)
        end
        
        local hasProduct = (animal.product_ready == 1 or animal.product_ready == true)
        
        -- Check production requirements using Config values
        local meetsHealthReq = (animal.health or 0) >= (productConfig.requiresHealth or 60)
        local meetsHungerReq = (animal.hunger or 0) >= (productConfig.requiresHunger or 40)
        local meetsThirstReq = (animal.thirst or 0) >= (productConfig.requiresThirst or 40)
        local canProduce = meetsHealthReq and meetsHungerReq and meetsThirstReq
        
        if Config.Debug then
            print('^3[PRODUCTION DEBUG]^7 Animal ' .. animalid .. ' production check:')
            print('^3[PRODUCTION DEBUG]^7 - Health: ' .. (animal.health or 0) .. '/' .. (productConfig.requiresHealth or 60) .. ' (meets: ' .. tostring(meetsHealthReq) .. ')')
            print('^3[PRODUCTION DEBUG]^7 - Hunger: ' .. (animal.hunger or 0) .. '/' .. (productConfig.requiresHunger or 40) .. ' (meets: ' .. tostring(meetsHungerReq) .. ')')
            print('^3[PRODUCTION DEBUG]^7 - Thirst: ' .. (animal.thirst or 0) .. '/' .. (productConfig.requiresThirst or 40) .. ' (meets: ' .. tostring(meetsThirstReq) .. ')')
            print('^3[PRODUCTION DEBUG]^7 - Can Produce: ' .. tostring(canProduce) .. ', Has Product: ' .. tostring(hasProduct))
        end
        
        local currentTime = os.time()
        local lastProduction = animal.last_production or 0
        local productionInterval = productConfig.productionTime or 3600
        local timeSinceLastProduction = currentTime - lastProduction
        local timeUntilNext = math.max(0, productionInterval - timeSinceLastProduction)
        
        -- Calculate animal age
        local animalAge = animal.age or 0
        if animal.born and animal.born > 0 then
            animalAge = math.floor((currentTime - animal.born) / 86400)
        end
        
        -- Check if animal meets minimum age for production
        local meetsAgeReq = animalAge >= (Config.MinAgeForProduction or 5)
        canProduce = canProduce and meetsAgeReq
        
        local productionData = {
            hasProduct = hasProduct and meetsAgeReq,
            canProduce = canProduce,
            productName = productConfig.product,
            productAmount = productConfig.amount,
            timeUntilNext = hasProduct and 0 or timeUntilNext
        }
        
        if Config.Debug then
            print('^3[PRODUCTION DEBUG]^7 Age check: ' .. animalAge .. 'd (min: ' .. (Config.MinAgeForProduction or 5) .. 'd) - Meets age: ' .. tostring(meetsAgeReq))
            print('^3[PRODUCTION DEBUG]^7 Timer calculation - Last production: ' .. lastProduction .. ', Current time: ' .. currentTime .. ', Time until next: ' .. timeUntilNext .. 's')
        end
        
        cb(productionData)
    end)
end)

---------------------------------------------
-- Animal Overview Callback
---------------------------------------------
RSGCore.Functions.CreateCallback('rex-ranch:server:getAnimalOverview', function(src, cb, ranchid)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then 
        cb({animals = {}, summary = {}})
        return 
    end
    
    if not ranchid then
        -- Get all animals if no specific ranch
        MySQL.query('SELECT * FROM rex_ranch_animals ORDER BY ranchid, model', {}, function(result)
            if not result then
                cb({animals = {}, summary = {}})
                return
            end
            
            local processedData = processAnimalOverviewData(result)
            cb(processedData)
        end)
    else
        -- Get animals for specific ranch
        MySQL.query('SELECT * FROM rex_ranch_animals WHERE ranchid = ? ORDER BY model', {ranchid}, function(result)
            if not result then
                cb({animals = {}, summary = {}})
                return
            end
            
            local processedData = processAnimalOverviewData(result)
            cb(processedData)
        end)
    end
end)

---------------------------------------------
-- Helper function to process animal overview data
---------------------------------------------
function processAnimalOverviewData(animals)
    local overview = {
        animals = {},
        summary = {
            total = #animals,
            byType = {},
            byGender = {male = 0, female = 0},
            pregnant = 0,
            ready_for_breeding = 0,
            unhealthy = 0,
            hungry = 0,
            thirsty = 0
        }
    }
    
    local currentTime = os.time()
    
    for _, animal in ipairs(animals) do
        -- Basic animal info
        local animalInfo = {
            animalid = animal.animalid,
            ranchid = animal.ranchid,
            model = animal.model,
            gender = animal.gender,
            age = animal.age or 0,
            health = animal.health or 100,
            hunger = animal.hunger or 100,
            thirst = animal.thirst or 100,
            pregnant = (animal.pregnant == 1 or animal.pregnant == true),
            breeding_ready_time = animal.breeding_ready_time,
            gestation_end_time = animal.gestation_end_time,
            pos_x = animal.pos_x,
            pos_y = animal.pos_y,
            pos_z = animal.pos_z
        }
        
        -- Calculate status flags
        animalInfo.is_unhealthy = (animalInfo.health < 70)
        animalInfo.is_hungry = (animalInfo.hunger < 50)
        animalInfo.is_thirsty = (animalInfo.thirst < 50)
        
        -- Check basic breeding readiness (age, pregnancy, cooldown)
        local basicBreedingReady = not animalInfo.pregnant and 
                                  (not animal.breeding_ready_time or animal.breeding_ready_time <= currentTime) and
                                  animalInfo.age >= (Config.MinAgeForBreeding or 5)
        
        -- For males, also check if there are already pregnant females in the ranch (if enabled)
        if basicBreedingReady and animalInfo.gender == 'male' and Config.RestrictMaleBreedingWhenFemalesPregnant then
            -- Count pregnant females in the same ranch
            local pregnantFemales = 0
            for _, otherAnimal in ipairs(animals) do
                if otherAnimal.ranchid == animalInfo.ranchid and 
                   otherAnimal.gender == 'female' and 
                   (otherAnimal.pregnant == 1 or otherAnimal.pregnant == true) then
                    pregnantFemales = pregnantFemales + 1
                end
            end
            animalInfo.breeding_ready = pregnantFemales == 0
            if pregnantFemales > 0 then
                animalInfo.breeding_restriction = 'Cannot breed - ' .. pregnantFemales .. ' female(s) already pregnant'
            end
        else
            animalInfo.breeding_ready = basicBreedingReady
        end
        
        -- Pregnancy status
        if animalInfo.pregnant and animalInfo.gestation_end_time then
            local timeRemaining = animalInfo.gestation_end_time - currentTime
            if timeRemaining > 0 then
                animalInfo.pregnancy_status = 'Due in ' .. math.floor(timeRemaining / (24 * 3600)) .. ' days'
            else
                animalInfo.pregnancy_status = 'Ready to give birth'
            end
        end
        
        table.insert(overview.animals, animalInfo)
        
        -- Update summary statistics
        overview.summary.byType[animal.model] = (overview.summary.byType[animal.model] or 0) + 1
        overview.summary.byGender[animal.gender] = (overview.summary.byGender[animal.gender] or 0) + 1
        
        if animalInfo.pregnant then
            overview.summary.pregnant = overview.summary.pregnant + 1
        end
        
        if animalInfo.breeding_ready then
            overview.summary.ready_for_breeding = overview.summary.ready_for_breeding + 1
        end
        
        if animalInfo.is_unhealthy then
            overview.summary.unhealthy = overview.summary.unhealthy + 1
        end
        
        if animalInfo.is_hungry then
            overview.summary.hungry = overview.summary.hungry + 1
        end
        
        if animalInfo.is_thirsty then
            overview.summary.thirsty = overview.summary.thirsty + 1
        end
    end
    
    return overview
end

---------------------------------------------
-- Breeding System Callbacks
---------------------------------------------

-- Get detailed breeding status including cooldowns
RSGCore.Functions.CreateCallback('rex-ranch:server:getBreedingStatus', function(src, cb, animalid)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not animalid then 
        cb({status = 'error', message = 'Invalid request'})
        return 
    end
    
    MySQL.query('SELECT model, gender, age, pregnant, breeding_ready_time, health, hunger, thirst, born FROM rex_ranch_animals WHERE animalid = ?', {animalid}, function(result)
        if not result or #result == 0 then
            cb({status = 'error', message = 'Animal not found'})
            return
        end
        
        local animal = result[1]
        local currentTime = os.time()
        local animalAge = animal.age or math.floor((currentTime - (animal.born or currentTime)) / (24 * 60 * 60))
        
        if Config.Debug then
            print('^3[BREEDING DEBUG]^7 Breeding status check for animal ' .. animalid .. ' - Age: ' .. animalAge .. ', Gender: ' .. tostring(animal.gender))
        end
        
        -- Check if breeding is enabled
        if not Config.BreedingEnabled then
            cb({status = 'disabled', message = 'Breeding system is disabled'})
            return
        end
        
        -- Check pregnancy status
        local isPregnant = (animal.pregnant == 1 or animal.pregnant == true or animal.pregnant == 'true')
        if isPregnant then
            cb({status = 'pregnant', message = 'Animal is pregnant'})
            return
        end
        
        -- Check age requirements
        if Config.MinAgeForBreeding and animalAge < Config.MinAgeForBreeding then
            cb({status = 'too_young', message = 'Too young to breed (need ' .. Config.MinAgeForBreeding .. ' days, currently ' .. animalAge .. ' days)'})
            return
        end
        
        if Config.MaxBreedingAge and animalAge > Config.MaxBreedingAge then
            cb({status = 'too_old', message = 'Too old to breed (max ' .. Config.MaxBreedingAge .. ' days, currently ' .. animalAge .. ' days)'})
            return
        end
        
        -- Check health requirements
        local healthReq = Config.RequireHealthForBreeding or 70
        local hungerReq = Config.RequireHungerForBreeding or 50
        local thirstReq = Config.RequireThirstForBreeding or 50
        
        if (animal.health or 100) < healthReq or (animal.hunger or 100) < hungerReq or (animal.thirst or 100) < thirstReq then
            local issues = {}
            if (animal.health or 100) < healthReq then table.insert(issues, 'health too low') end
            if (animal.hunger or 100) < hungerReq then table.insert(issues, 'hunger too low') end
            if (animal.thirst or 100) < thirstReq then table.insert(issues, 'thirst too low') end
            
            cb({status = 'requirements_not_met', message = 'Requirements not met: ' .. table.concat(issues, ', ')})
            return
        end
        
        -- Check breeding cooldown
        if animal.breeding_ready_time and animal.breeding_ready_time > currentTime then
            local timeRemaining = animal.breeding_ready_time - currentTime
            local hoursRemaining = math.ceil(timeRemaining / 3600)
            cb({
                status = 'cooldown', 
                message = 'Breeding cooldown active (' .. hoursRemaining .. 'h remaining)',
                timeRemaining = timeRemaining
            })
            return
        end
        
        -- Check if male and there are already pregnant females in the ranch (if enabled)
        if animal.gender == 'male' and Config.RestrictMaleBreedingWhenFemalesPregnant then
            -- Get ranch ID from the animal
            MySQL.query('SELECT ranchid FROM rex_ranch_animals WHERE animalid = ?', {animalid}, function(ranchResult)
                if ranchResult and #ranchResult > 0 then
                    local ranchid = ranchResult[1].ranchid
                    
                    -- Check for pregnant females in the same ranch
                    MySQL.query('SELECT COUNT(*) as pregnant_count FROM rex_ranch_animals WHERE ranchid = ? AND gender = ? AND pregnant = 1', 
                                {ranchid, 'female'}, function(pregnantResult)
                        if pregnantResult and #pregnantResult > 0 and pregnantResult[1].pregnant_count > 0 then
                            cb({
                                status = 'restricted', 
                                message = 'Cannot breed - there are already ' .. pregnantResult[1].pregnant_count .. ' pregnant female(s) in this ranch'
                            })
                            return
                        else
                            -- Animal is ready to breed
                            cb({status = 'ready', message = 'Ready for breeding'})
                            return
                        end
                    end)
                else
                    -- Animal is ready to breed (fallback if ranch not found)
                    cb({status = 'ready', message = 'Ready for breeding'})
                    return
                end
            end)
        else
            -- Female animals don't have this restriction
            cb({status = 'ready', message = 'Ready for breeding'})
        end
    end)
end)

---------------------------------------------
-- Get pregnancy progress
---------------------------------------------
RSGCore.Functions.CreateCallback('rex-ranch:server:getPregnancyProgress', function(src, cb, animalid)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not animalid or not isPlayerRanchStaff(Player) then 
        cb({isPregnant = false})
        return 
    end
    
    MySQL.query('SELECT pregnant, gestation_end_time, born, model FROM rex_ranch_animals WHERE animalid = ?', {animalid}, function(result)
        if not result or #result == 0 then
            cb({isPregnant = false})
            return
        end
        
        local animal = result[1]
        
        -- Check if animal is actually pregnant
        if not (animal.pregnant == 1 or animal.pregnant == true) or not animal.gestation_end_time then
            cb({isPregnant = false})
            return
        end
        
        local currentTime = os.time()
        local gestationEndTime = animal.gestation_end_time
        
        -- Get gestation period from config
        local breedingConfig = Config.BreedingConfig[animal.model]
        if not breedingConfig then
            cb({isPregnant = false})
            return
        end
        
        local gestationPeriod = breedingConfig.gestationPeriod
        local gestationStartTime = gestationEndTime - gestationPeriod
        
        -- Calculate progress
        local timeElapsed = currentTime - gestationStartTime
        local progressPercent = math.max(0, math.min(100, (timeElapsed / gestationPeriod) * 100))
        
        -- Calculate time remaining
        local timeRemaining = gestationEndTime - currentTime
        local description = ''
        
        if timeRemaining > 0 then
            local hoursRemaining = math.floor(timeRemaining / 3600)
            local daysRemaining = math.floor(hoursRemaining / 24)
            local remainingHours = hoursRemaining % 24
            
            if daysRemaining > 0 then
                description = 'Due in ' .. daysRemaining .. 'd ' .. remainingHours .. 'h (' .. math.floor(progressPercent) .. '% complete)'
            else
                description = 'Due in ' .. hoursRemaining .. ' hours (' .. math.floor(progressPercent) .. '% complete)'
            end
        else
            description = 'Ready to give birth! (100% complete)'
            progressPercent = 100
        end
        
        cb({
            isPregnant = true,
            progressPercent = progressPercent,
            description = description,
            timeRemaining = timeRemaining,
            daysRemaining = math.floor(timeRemaining / (24 * 3600)),
            hoursRemaining = math.floor(timeRemaining / 3600)
        })
    end)
end)

---------------------------------------------
-- Get available animals for breeding
---------------------------------------------
RSGCore.Functions.CreateCallback('rex-ranch:server:getAvailableAnimalsForBreeding', function(src, cb, ranchid, animalid)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not ranchid or not animalid or not isPlayerRanchStaff(Player) then 
        cb(false)
        return 
    end
    
    -- Get the animal we want to breed
    MySQL.query('SELECT model, gender, age FROM rex_ranch_animals WHERE animalid = ? AND ranchid = ?', {animalid, ranchid}, function(mainResult)
        if not mainResult or #mainResult == 0 then
            cb(false)
            return
        end
        
        local mainAnimal = mainResult[1]
        local targetGender = mainAnimal.gender == 'male' and 'female' or 'male'
        
        -- Check if the main animal is male and there are already pregnant females (if enabled)
        if mainAnimal.gender == 'male' and Config.RestrictMaleBreedingWhenFemalesPregnant then
            MySQL.query('SELECT COUNT(*) as pregnant_count FROM rex_ranch_animals WHERE ranchid = ? AND gender = ? AND pregnant = 1', 
                        {ranchid, 'female'}, function(pregnantCheck)
                if pregnantCheck and #pregnantCheck > 0 and pregnantCheck[1].pregnant_count > 0 then
                    -- Return empty list - male cannot breed when females are already pregnant
                    cb({})
                    return
                end
                
                -- Continue with normal breeding partner search
                findBreedingPartners()
            end)
        else
            -- Female animals can breed normally
            findBreedingPartners()
        end
        
        function findBreedingPartners()
            -- Find compatible animals of opposite gender
            MySQL.query('SELECT animalid, model, gender, age, health, hunger, thirst, pregnant, breeding_ready_time, pos_x, pos_y, pos_z FROM rex_ranch_animals WHERE ranchid = ? AND gender = ? AND animalid != ?', 
                        {ranchid, targetGender, animalid}, function(result)
                if not result or #result == 0 then
                    cb({})
                    return
                end
                
                local availableAnimals = {}
                local currentTime = os.time()
                
                for _, animal in ipairs(result) do
                    local canBreed = true
                    local breedingIssue = ''
                    
                    -- Check pregnancy
                    if animal.pregnant == 1 then
                        canBreed = false
                        breedingIssue = 'Pregnant'
                    end
                    
                    -- Check breeding cooldown
                    if canBreed and animal.breeding_ready_time and animal.breeding_ready_time > currentTime then
                        canBreed = false
                        local hoursRemaining = math.ceil((animal.breeding_ready_time - currentTime) / 3600)
                        breedingIssue = 'Cooldown (' .. hoursRemaining .. 'h)'
                    end
                    
                    -- Check age requirements
                    if canBreed then
                        local animalAge = animal.age or 0
                        if Config.MinAgeForBreeding and animalAge < Config.MinAgeForBreeding then
                            canBreed = false
                            breedingIssue = 'Too young'
                        elseif Config.MaxBreedingAge and animalAge > Config.MaxBreedingAge then
                            canBreed = false
                            breedingIssue = 'Too old'
                        end
                    end
                    
                    -- Check health/hunger/thirst requirements
                    if canBreed then
                        local healthReq = Config.RequireHealthForBreeding or 70
                        local hungerReq = Config.RequireHungerForBreeding or 50
                        local thirstReq = Config.RequireThirstForBreeding or 50
                        
                        if (animal.health or 100) < healthReq or (animal.hunger or 100) < hungerReq or (animal.thirst or 100) < thirstReq then
                            canBreed = false
                            breedingIssue = 'Poor condition'
                        end
                    end
                    
                    -- Calculate distance (simplified - assumes animals are at their database positions)
                    local distance = 0
                    if animal.pos_x and animal.pos_y and animal.pos_z then
                        distance = math.floor(math.random(5, 50)) -- Placeholder distance for now
                    end
                    
                    table.insert(availableAnimals, {
                        animalid = animal.animalid,
                        gender = animal.gender,
                        age = animal.age or 0,
                        health = animal.health or 100,
                        canBreed = canBreed,
                        breedingIssue = breedingIssue,
                        distance = distance
                    })
                end
                
                cb(availableAnimals)
            end)
        end
    end)
end)

---------------------------------------------
-- get nearby animals for sale
---------------------------------------------
RSGCore.Functions.CreateCallback('rex-ranch:server:getNearbyAnimalsForSale', function(src, cb, ranchid, salePointCoords)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player or not ranchid then 
        cb({})
        return 
    end
    
    -- Get all animals from this ranch that are old enough to sell
    local success, result = pcall(function()
        return MySQL.query.await(
            'SELECT animalid, model, gender, age, health, hunger, thirst, pos_x, pos_y, pos_z FROM rex_ranch_animals WHERE ranchid = ? AND age >= ?',
            { ranchid, Config.MinAgeToSell }
        )
    end)
    
    if not success or not result then
        cb({})
        return
    end
    
    local animals = {}
    local salePointVec = vector3(salePointCoords.x, salePointCoords.y, salePointCoords.z)
    
    for _, animal in ipairs(result) do
        -- Calculate sale price based on age
        local baseSellPrice = Config.BaseSellPrices[animal.model] or 100
        local ageMultiplier = 1.0
        local ageCategory = 'Adult'
        
        -- Determine age category and apply multiplier
        if animal.age < Config.PrimeAgeStart then
            ageMultiplier = Config.AgePricing.young
            ageCategory = 'Young'
        elseif animal.age >= Config.PrimeAgeStart and animal.age <= Config.PrimeAgeEnd then
            ageMultiplier = Config.AgePricing.prime
            ageCategory = 'Prime'
        elseif animal.age > Config.PrimeAgeEnd and animal.age < Config.OldAgeStart then
            ageMultiplier = Config.AgePricing.adult
            ageCategory = 'Adult'
        elseif animal.age >= Config.OldAgeStart then
            ageMultiplier = Config.AgePricing.old
            ageCategory = 'Old'
        end
        
        local salePrice = math.floor(baseSellPrice * ageMultiplier)
        
        -- Check if animal is nearby
        local animalVec = vector3(animal.pos_x, animal.pos_y, animal.pos_z)
        local distance = #(salePointVec - animalVec)
        local isNearby = distance <= Config.AnimalSaleDistance
        
        table.insert(animals, {
            animalid = animal.animalid,
            model = animal.model,
            gender = animal.gender,
            age = animal.age,
            ageCategory = ageCategory,
            health = animal.health,
            hunger = animal.hunger,
            thirst = animal.thirst,
            salePrice = salePrice,
            distance = math.floor(distance),
            isNearby = isNearby
        })
    end
    
    cb(animals)
end)

---------------------------------------------
-- sell single animal
---------------------------------------------
RegisterNetEvent('rex-ranch:server:sellAnimal', function(animalid, salePrice, salePointCoords)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if not Player then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Player not found!'})
        return
    end
    
    -- Verify player is ranch staff
    if not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You must be ranch staff to sell animals!'})
        return
    end
    
    if not animalid or not salePrice then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Invalid animal or price!'})
        return
    end
    
    -- Get animal data from database
    local animalResult = MySQL.query.await('SELECT animalid, ranchid, age, model FROM rex_ranch_animals WHERE animalid = ?', {animalid})
    
    if not animalResult or #animalResult == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Animal not found!'})
        if Config.Debug then
            print('^1[SELL ANIMAL ERROR]^7 Animal ' .. animalid .. ' not found in database')
        end
        return
    end
    
    local animal = animalResult[1]
    
    -- Verify animal is old enough to sell
    if animal.age < Config.MinAgeToSell then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            description = 'This animal is too young to sell! Must be at least ' .. Config.MinAgeToSell .. ' days old.'
        })
        return
    end
    
    -- Verify proximity if required
    if Config.RequireAnimalPresent then
        -- Would need to check animal position vs sale point - for now assume it passed the client check
    end
    
    -- Delete animal from database
    local deleteSuccess, deleteError = pcall(function()
        return MySQL.update.await('DELETE FROM rex_ranch_animals WHERE animalid = ?', {animalid})
    end)
    
    if not deleteSuccess or not deleteError or deleteError == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Failed to complete sale!'})
        if Config.Debug then
            print('^1[SELL ANIMAL ERROR]^7 Failed to delete animal ' .. animalid .. ' from database')
        end
        return
    end
    
    -- Give money to player
    Player.Functions.AddMoney('cash', salePrice)
    
    -- Notify player
    TriggerClientEvent('ox_lib:notify', src, {
        type = 'success',
        description = 'Sold ' .. (animal.model == 'a_c_bull_01' and 'Bull' or 'Cow') .. ' for $' .. salePrice .. '!'
    })
    
    -- Remove from clients and refresh
    TriggerClientEvent('rex-ranch:client:removeAnimal', -1, animalid)
    TriggerEvent('rex-ranch:server:refreshAnimals')
    
    if Config.Debug then
        print('^2[SELL ANIMAL SUCCESS]^7 Player ' .. src .. ' sold animal ' .. animalid .. ' for $' .. salePrice)
    end
end)

---------------------------------------------
-- sell all animals
---------------------------------------------
RegisterNetEvent('rex-ranch:server:sellAllAnimals', function(animals, salePointCoords)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if not Player then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Player not found!'})
        return
    end
    
    -- Verify player is ranch staff
    if not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You must be ranch staff to sell animals!'})
        return
    end
    
    if not animals or #animals == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'No animals to sell!'})
        return
    end
    
    local totalValue = 0
    local successCount = 0
    local failedAnimals = {}
    
    -- Process each animal
    for _, animal in ipairs(animals) do
        if animal.animalid and animal.salePrice then
            -- Get animal data from database to verify
            local animalResult = MySQL.query.await('SELECT animalid, age FROM rex_ranch_animals WHERE animalid = ?', {animal.animalid})
            
            if animalResult and #animalResult > 0 then
                local dbAnimal = animalResult[1]
                
                -- Verify age requirement
                if dbAnimal.age >= Config.MinAgeToSell then
                    -- Delete animal
                    local deleteSuccess, deleteError = pcall(function()
                        return MySQL.update.await('DELETE FROM rex_ranch_animals WHERE animalid = ?', {animal.animalid})
                    end)
                    
                    if deleteSuccess and deleteError and deleteError > 0 then
                        totalValue = totalValue + animal.salePrice
                        successCount = successCount + 1
                        TriggerClientEvent('rex-ranch:client:removeAnimal', -1, animal.animalid)
                    else
                        table.insert(failedAnimals, animal.animalid)
                    end
                else
                    table.insert(failedAnimals, animal.animalid)
                end
            else
                table.insert(failedAnimals, animal.animalid)
            end
        end
    end
    
    -- Give total money to player
    if totalValue > 0 then
        Player.Functions.AddMoney('cash', totalValue)
    end
    
    -- Notify player
    if successCount == #animals then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'success',
            description = 'Sold all ' .. successCount .. ' animals for a total of $' .. totalValue .. '!'
        })
    elseif successCount > 0 then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'warning',
            description = 'Sold ' .. successCount .. ' out of ' .. #animals .. ' animals for $' .. totalValue .. '!'
        })
    else
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            description = 'Failed to sell any animals!'
        })
    end
    
    -- Refresh all clients
    TriggerEvent('rex-ranch:server:refreshAnimals')
    
    if Config.Debug then
        print('^2[SELL ANIMALS SUCCESS]^7 Player ' .. src .. ' sold ' .. successCount .. ' animals for $' .. totalValue)
        if #failedAnimals > 0 then
            print('^3[SELL ANIMALS WARNING]^7 Failed to sell ' .. #failedAnimals .. ' animals')
        end
    end
end)

---------------------------------------------
-- buy animal system
---------------------------------------------
RegisterNetEvent('rex-ranch:server:buyAnimal', function(purchaseData)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if not Player then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Player not found!'})
        return
    end
    
    -- Verify player is ranch staff
    if not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You must be ranch staff to buy animals!'})
        return
    end
    
    -- Validate purchase data
    if not purchaseData or not purchaseData.animalType or not purchaseData.price or not purchaseData.ranchid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Invalid purchase data!'})
        if Config.Debug then
            print('^1[BUY ANIMAL ERROR]^7 Invalid purchase data from player ' .. src)
        end
        return
    end
    
    local playerMoney = Player.PlayerData.money.cash
    
    -- Check if player has enough money
    if playerMoney < purchaseData.price then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            description = 'You need $' .. purchaseData.price .. ' but only have $' .. playerMoney
        })
        return
    end
    
    -- Check animal count for the ranch
    local countResult = MySQL.query.await('SELECT COUNT(*) as count FROM rex_ranch_animals WHERE ranchid = ?', {purchaseData.ranchid})
    if not countResult or not countResult[1] then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Error checking ranch capacity!'})
        if Config.Debug then
            print('^1[BUY ANIMAL ERROR]^7 Failed to count animals for ranch ' .. purchaseData.ranchid)
        end
        return
    end
    
    local currentCount = countResult[1].count or 0
    if currentCount >= Config.MaxRanchAnimals then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'error',
            description = 'Your ranch is at maximum capacity (' .. Config.MaxRanchAnimals .. ' animals)'
        })
        return
    end
    
    -- Create unique animal ID
    local animalid = CreateAnimalId()
    if not animalid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Failed to create animal ID!'})
        if Config.Debug then
            print('^1[BUY ANIMAL ERROR]^7 Failed to create unique animal ID for player ' .. src)
        end
        return
    end
    
    -- Determine gender based on config
    local gender = 'female'
    if Config.GenderRatios and Config.GenderRatios[purchaseData.animalType] then
        local maleChance = Config.GenderRatios[purchaseData.animalType]
        gender = (math.random() < maleChance) and 'male' or 'female'
    end
    
    -- Get spawn point for the animal
    local spawnPos = purchaseData.spawnpoint or vector4(0, 0, 0, 0)
    
    -- Current time for database
    local currentTime = os.time()
    
    -- Insert animal into database
    local success, error = pcall(function()
        return MySQL.insert.await('INSERT INTO rex_ranch_animals (animalid, ranchid, model, gender, age, health, hunger, thirst, pos_x, pos_y, pos_z, pos_w, pregnant, born) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
            animalid,
            purchaseData.ranchid,
            purchaseData.animalType,
            gender,
            0,  -- age starts at 0
            100,  -- health
            100,  -- hunger
            100,  -- thirst
            spawnPos.x,
            spawnPos.y,
            spawnPos.z,
            spawnPos.w or 0,
            0,  -- not pregnant
            currentTime  -- born timestamp
        })
    end)
    
    if not success or not error or error == 0 then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Failed to purchase animal!'})
        if Config.Debug then
            print('^1[BUY ANIMAL ERROR]^7 Database insert failed: ' .. tostring(error))
        end
        return
    end
    
    -- Deduct money from player
    Player.Functions.RemoveMoney('cash', purchaseData.price)
    
    -- Notify player of successful purchase
    TriggerClientEvent('ox_lib:notify', src, {
        type = 'success',
        description = 'Successfully purchased ' .. purchaseData.animalName .. ' for $' .. purchaseData.price .. '!'
    })
    
    if Config.ServerNotify then
        TriggerClientEvent('ox_lib:notify', src, {
            type = 'info',
            description = 'A new animal has been purchased at ' .. (purchaseData.buyPointName or 'the livestock dealer') .. '!'
        })
    end
    
    -- Refresh animals for the purchasing player first to trigger immediate spawn
    -- Query the newly created animal
    MySQL.query('SELECT * FROM rex_ranch_animals WHERE animalid = ?', {animalid}, function(newAnimalData)
        if newAnimalData and #newAnimalData > 0 then
            -- Send the new animal data to the purchasing player
            local animalDataArray = {newAnimalData[1]}
            TriggerClientEvent('rex-ranch:client:spawnAnimals', src, animalDataArray)
            
            if Config.Debug then
                print('^2[BUY ANIMAL SUCCESS]^7 Sent new animal ' .. animalid .. ' to player ' .. src .. ' for immediate spawn')
            end
        end
    end)
    
    -- Also refresh all clients to update their animal lists
    Wait(500)  -- Small delay to ensure the purchasing player processes first
    TriggerEvent('rex-ranch:server:refreshAnimals')
    
    if Config.Debug then
        print('^2[BUY ANIMAL SUCCESS]^7 Player ' .. src .. ' purchased ' .. purchaseData.animalName .. ' (ID: ' .. animalid .. ') for $' .. purchaseData.price)
    end
end)

---------------------------------------------
-- Helper function to start breeding between two animals
---------------------------------------------
local function StartBreeding(animal1id, animal2id, isAutomatic)
    isAutomatic = isAutomatic or false
    
    if Config.Debug then
        print('^3[BREEDING DEBUG]^7 Starting breeding process for animals ' .. animal1id .. ' and ' .. animal2id .. ' (automatic: ' .. tostring(isAutomatic) .. ')')
    end
    
    -- Get both animals' data
    MySQL.query('SELECT animalid, model, gender, age, pregnant, breeding_ready_time, health, hunger, thirst, ranchid FROM rex_ranch_animals WHERE animalid IN (?, ?)', 
                {animal1id, animal2id}, function(result)
        if not result or #result ~= 2 then
            if Config.Debug then
                print('^1[BREEDING ERROR]^7 Could not find both animals for breeding')
            end
            return
        end
        
        local animal1 = result[1]
        local animal2 = result[2]
        
        -- Ensure we have one male and one female
        local male, female
        if animal1.gender == 'male' and animal2.gender == 'female' then
            male = animal1
            female = animal2
        elseif animal1.gender == 'female' and animal2.gender == 'male' then
            male = animal2
            female = animal1
        else
            if Config.Debug then
                print('^1[BREEDING ERROR]^7 Animals must be opposite genders (got ' .. animal1.gender .. ' and ' .. animal2.gender .. ')')
            end
            return
        end
        
        -- Verify both animals are from the same ranch
        if male.ranchid ~= female.ranchid then
            if Config.Debug then
                print('^1[BREEDING ERROR]^7 Animals must be from the same ranch')
            end
            return
        end
        
        local currentTime = os.time()
        
        -- Verify breeding readiness for both animals
        local healthReq = Config.RequireHealthForBreeding or 70
        local hungerReq = Config.RequireHungerForBreeding or 50
        local thirstReq = Config.RequireThirstForBreeding or 50
        
        -- Check female
        if (female.pregnant == 1 or female.pregnant == true) then
            if Config.Debug then
                print('^1[BREEDING ERROR]^7 Female animal ' .. female.animalid .. ' is already pregnant')
            end
            return
        end
        
        if female.breeding_ready_time and female.breeding_ready_time > currentTime then
            if Config.Debug then
                print('^1[BREEDING ERROR]^7 Female animal ' .. female.animalid .. ' is on breeding cooldown')
            end
            return
        end
        
        if (female.health or 100) < healthReq or (female.hunger or 100) < hungerReq or (female.thirst or 100) < thirstReq then
            if Config.Debug then
                print('^1[BREEDING ERROR]^7 Female animal ' .. female.animalid .. ' does not meet health/hunger/thirst requirements')
            end
            return
        end
        
        -- Check male
        if male.breeding_ready_time and male.breeding_ready_time > currentTime then
            if Config.Debug then
                print('^1[BREEDING ERROR]^7 Male animal ' .. male.animalid .. ' is on breeding cooldown')
            end
            return
        end
        
        if (male.health or 100) < healthReq or (male.hunger or 100) < hungerReq or (male.thirst or 100) < thirstReq then
            if Config.Debug then
                print('^1[BREEDING ERROR]^7 Male animal ' .. male.animalid .. ' does not meet health/hunger/thirst requirements')
            end
            return
        end
        
        -- Get breeding config for female (who will be pregnant)
        local breedingConfig = Config.BreedingConfig[female.model]
        if not breedingConfig or not breedingConfig.enabled then
            if Config.Debug then
                print('^1[BREEDING ERROR]^7 Breeding not enabled for model: ' .. female.model)
            end
            return
        end
        
        local gestationPeriod = breedingConfig.gestationPeriod
        local gestationEndTime = currentTime + gestationPeriod
        
        -- Set female as pregnant
        MySQL.update('UPDATE rex_ranch_animals SET pregnant = 1, gestation_end_time = ? WHERE animalid = ?', 
                     {gestationEndTime, female.animalid}, function(updateResult)
            local rowsAffected = 0
            if type(updateResult) == 'table' then
                rowsAffected = updateResult.affectedRows or updateResult.changedRows or 0
            elseif type(updateResult) == 'number' then
                rowsAffected = updateResult
            end
            
            if rowsAffected > 0 then
                -- Set breeding cooldowns
                local femaleCooldown = GetBreedingCooldown('female')
                local maleCooldown = GetBreedingCooldown('male')
                local femaleCooldownTime = currentTime + femaleCooldown
                local maleCooldownTime = currentTime + maleCooldown
                
                MySQL.update('UPDATE rex_ranch_animals SET breeding_ready_time = ? WHERE animalid = ?', 
                             {femaleCooldownTime, female.animalid})
                MySQL.update('UPDATE rex_ranch_animals SET breeding_ready_time = ? WHERE animalid = ?', 
                             {maleCooldownTime, male.animalid})
                
                if Config.Debug then
                    print('^2[BREEDING SUCCESS]^7 Female ' .. female.animalid .. ' is now pregnant! Due in ' .. math.floor(gestationPeriod / (24 * 3600)) .. ' days')
                    print('^2[BREEDING SUCCESS]^7 Female cooldown: ' .. math.floor(femaleCooldown / 3600) .. 'h, Male cooldown: ' .. math.floor(maleCooldown / 3600) .. 'h')
                end
                
                -- Send notification if automatic breeding notifications are enabled
                if isAutomatic and Config.AutomaticBreedingNotifications then
                    local daysRemaining = math.floor(gestationPeriod / (24 * 3600))
                    print('^2[REX-RANCH AUTO-BREEDING]^7 Animals ' .. female.animalid .. ' and ' .. male.animalid .. ' have bred! Offspring due in ' .. daysRemaining .. ' days at ranch ' .. female.ranchid)
                end
                
                -- Refresh animals to show pregnancy status
                TriggerEvent('rex-ranch:server:refreshAnimals')
            else
                if Config.Debug then
                    print('^1[BREEDING ERROR]^7 Failed to update pregnancy status for animal ' .. female.animalid)
                end
            end
        end)
    end)
end

---------------------------------------------
-- Start breeding process (manual trigger from players)
---------------------------------------------
RegisterNetEvent('rex-ranch:server:startBreeding', function(animal1id, animal2id)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if not Player or not isPlayerRanchStaff(Player) then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You must be ranch staff to breed animals!'})
        return
    end
    
    if Config.Debug then
        print('^3[BREEDING DEBUG]^7 Manual breeding request from player ' .. src .. ' for animals ' .. animal1id .. ' and ' .. animal2id)
    end
    
    -- Start the breeding process
    StartBreeding(animal1id, animal2id, false)
    
    -- Notify player
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = 'Breeding initiated!'})
end)

---------------------------------------------
-- automatic breeding system
---------------------------------------------
CreateThread(function()
    -- Wait for server to be fully loaded
    Wait(10000)
    
    if not Config.AutomaticBreedingEnabled then
        if Config.Debug then
            print('^3[AUTO-BREEDING]^7 Automatic breeding is disabled in config')
        end
        return
    end
    
    print('^2[REX-RANCH]^7 Initializing automatic breeding system (check interval: ' .. Config.AutomaticBreedingCheckInterval .. 's, max distance: ' .. Config.AutomaticBreedingMaxDistance .. 'm)')
    
    -- Run automatic breeding checks
    while true do
        Wait(Config.AutomaticBreedingCheckInterval * 1000)
        
        if Config.Debug then
            print('^3[AUTO-BREEDING]^7 Running automatic breeding check at ' .. os.date('%Y-%m-%d %H:%M:%S'))
        end
        
        -- Get all animals that could potentially breed
        MySQL.query('SELECT animalid, model, gender, age, pregnant, breeding_ready_time, health, hunger, thirst, ranchid, pos_x, pos_y, pos_z, born FROM rex_ranch_animals WHERE pregnant = 0', {}, function(animals)
            if not animals or #animals < 2 then
                if Config.Debug then
                    print('^3[AUTO-BREEDING]^7 Not enough animals for breeding (need at least 2 non-pregnant animals)')
                end
                return
            end
            
            local currentTime = os.time()
            local healthReq = Config.RequireHealthForBreeding or 70
            local hungerReq = Config.RequireHungerForBreeding or 50
            local thirstReq = Config.RequireThirstForBreeding or 50
            local minAge = Config.MinAgeForBreeding or 5
            local maxAge = Config.MaxBreedingAge or 30
            local maxDistance = Config.AutomaticBreedingMaxDistance or 5.0
            
            -- Separate animals by ranch and gender
            local ranchAnimals = {}
            
            for _, animal in ipairs(animals) do
                -- Calculate age
                local animalAge = animal.age or 0
                if animal.born and animal.born > 0 then
                    animalAge = math.floor((currentTime - animal.born) / (24 * 60 * 60))
                end
                
                -- Check if animal meets breeding requirements
                local isEligible = true
                
                -- Age check
                if animalAge < minAge or animalAge > maxAge then
                    isEligible = false
                end
                
                -- Cooldown check
                if animal.breeding_ready_time and animal.breeding_ready_time > currentTime then
                    isEligible = false
                end
                
                -- Health/hunger/thirst check
                if (animal.health or 100) < healthReq or (animal.hunger or 100) < hungerReq or (animal.thirst or 100) < thirstReq then
                    isEligible = false
                end
                
                -- Breeding config check
                local breedingConfig = Config.BreedingConfig[animal.model]
                if not breedingConfig or not breedingConfig.enabled then
                    isEligible = false
                end
                
                if isEligible then
                    if not ranchAnimals[animal.ranchid] then
                        ranchAnimals[animal.ranchid] = {males = {}, females = {}}
                    end
                    
                    if animal.gender == 'male' then
                        table.insert(ranchAnimals[animal.ranchid].males, animal)
                    elseif animal.gender == 'female' then
                        table.insert(ranchAnimals[animal.ranchid].females, animal)
                    end
                end
            end
            
            -- Check for breeding opportunities in each ranch
            local breedingPairs = 0
            
            for ranchid, genderGroups in pairs(ranchAnimals) do
                local males = genderGroups.males
                local females = genderGroups.females
                
                if Config.Debug then
                    print('^3[AUTO-BREEDING]^7 Ranch ' .. ranchid .. ' has ' .. #males .. ' eligible males and ' .. #females .. ' eligible females')
                end
                
                -- Check male restriction if enabled
                if Config.RestrictMaleBreedingWhenFemalesPregnant then
                    -- Check if there are any pregnant females in this ranch
                    local hasPregnantFemales = false
                    MySQL.query('SELECT COUNT(*) as count FROM rex_ranch_animals WHERE ranchid = ? AND gender = ? AND pregnant = 1', 
                                {ranchid, 'female'}, function(pregnantResult)
                        if pregnantResult and #pregnantResult > 0 and pregnantResult[1].count > 0 then
                            hasPregnantFemales = true
                        end
                        
                        if hasPregnantFemales then
                            if Config.Debug then
                                print('^3[AUTO-BREEDING]^7 Ranch ' .. ranchid .. ' has pregnant females - males cannot breed')
                            end
                            return
                        end
                        
                        -- Try to find breeding pairs
                        ProcessBreedingPairs(males, females, maxDistance, ranchid)
                    end)
                else
                    -- No restriction, proceed with breeding
                    ProcessBreedingPairs(males, females, maxDistance, ranchid)
                end
            end
        end)
    end
end)

---------------------------------------------
-- Helper function to process breeding pairs
---------------------------------------------
function ProcessBreedingPairs(males, females, maxDistance, ranchid)
    for _, male in ipairs(males) do
        for _, female in ipairs(females) do
            -- Check distance between animals
            local malePos = vector3(male.pos_x, male.pos_y, male.pos_z)
            local femalePos = vector3(female.pos_x, female.pos_y, female.pos_z)
            local distance = #(malePos - femalePos)
            
            if distance <= maxDistance then
                if Config.Debug then
                    print('^2[AUTO-BREEDING]^7 Found breeding pair at ranch ' .. ranchid .. ': Male ' .. male.animalid .. ' and Female ' .. female.animalid .. ' (distance: ' .. string.format('%.2f', distance) .. 'm)')
                end
                
                -- Start breeding for this pair
                StartBreeding(male.animalid, female.animalid, true)
                
                -- Remove these animals from further pairing in this cycle
                return
            end
        end
    end
end

---------------------------------------------
-- animal cronjob
---------------------------------------------
-- Initialize cron job with better error handling
CreateThread(function()
    -- Wait for server to be fully loaded
    Wait(5000)
    
    if not lib or not lib.cron then
        print('^1[REX-RANCH ERROR]^7 ox_lib cron not available! Make sure ox_lib is started before rex-ranch.')
        return
    end
    
    print('^2[REX-RANCH]^7 Initializing animal survival cronjob with schedule: ' .. Config.AnimalCronJob)
    
    lib.cron.new(Config.AnimalCronJob, function ()
        if Config.Debug then
            print('^2[REX-RANCH CRON]^7 Starting animal update cycle at ' .. os.date('%Y-%m-%d %H:%M:%S'))
        end
        
        -- Run in separate thread to avoid blocking cron
        CreateThread(function()
            ProcessAnimalSurvival()
        end)
    end)
end)

---------------------------------------------
-- animal survival processing
---------------------------------------------
function ProcessAnimalSurvival()  
    local success, cronError = pcall(function()
        MySQL.query('SELECT animalid, model, born, health, thirst, hunger, last_production, product_ready, gender, pregnant, gestation_end_time, ranchid, pos_x, pos_y, pos_z, pos_w FROM rex_ranch_animals', {}, function(animals)
            if not animals or #animals == 0 then
                if Config.Debug then
                    print('^3[REX-RANCH CRON]^7 No animals found in database or query returned empty')
                end
                return
            end
            
            if Config.Debug then
                print('^2[REX-RANCH CRON]^7 Processing ' .. #animals .. ' animals')
            end

        local scaleTable = {
            [0] = 0.50,
            [1] = 0.60,
            [2] = 0.70,
            [3] = 0.80,
            [4] = 0.90,
            [5] = 1.00
        }

        local animalsToRemove = {}
        local batchUpdates = {} -- Collect updates for batch processing

        for _, animal in ipairs(animals) do
            -- Comprehensive validation of animal data
            if not animal.animalid or not animal.born or not animal.pos_x or not animal.pos_y or not animal.pos_z then
                if Config.Debug then
                    print('^1[ERROR]^7 Invalid animal data: missing critical fields for animalid ' .. (animal.animalid or 'unknown'))
                    print('^1[ERROR]^7 Fields: born=' .. tostring(animal.born) .. ', pos_x=' .. tostring(animal.pos_x) .. ', pos_y=' .. tostring(animal.pos_y) .. ', pos_z=' .. tostring(animal.pos_z))
                end
                goto continue
            end

            local animalAge = math.floor((os.time() - animal.born) / (24 * 60 * 60))
            if animalAge < 0 then
                if Config.Debug then
                    print('^1[ERROR]^7 Invalid birth date for animalid ' .. animal.animalid)
                end
                goto continue
            end

            -- Prepare batch update data instead of individual queries
            local scale = scaleTable[math.min(animalAge, 5)] or 1.00
            
            -- Check for breeding/pregnancy events if enabled
            -- Handle both boolean and integer pregnancy values from database
            local isPregnant = (animal.pregnant == 1 or animal.pregnant == true or animal.pregnant == 'true')
            if Config.BreedingEnabled and isPregnant and animal.gestation_end_time then
                local currentTime = os.time()
                
                if Config.Debug then
                    print('^3[PREGNANCY DEBUG]^7 Found pregnant animal ' .. animal.animalid .. ':')
                    print('^3[PREGNANCY DEBUG]^7 - Current time: ' .. currentTime .. ' (' .. os.date('%Y-%m-%d %H:%M:%S', currentTime) .. ')')
                    print('^3[PREGNANCY DEBUG]^7 - Gestation end: ' .. animal.gestation_end_time .. ' (' .. os.date('%Y-%m-%d %H:%M:%S', animal.gestation_end_time) .. ')')
                    print('^3[PREGNANCY DEBUG]^7 - Time remaining: ' .. (animal.gestation_end_time - currentTime) .. ' seconds')
                    print('^3[PREGNANCY DEBUG]^7 - Ready to give birth: ' .. tostring(currentTime >= animal.gestation_end_time))
                end
                
                -- Check if gestation period is complete
                if currentTime >= animal.gestation_end_time then
                    local breedingConfig = Config.BreedingConfig[animal.model]
                    
                    if Config.Debug then
                        print('^3[PREGNANCY DEBUG]^7 Animal ' .. animal.animalid .. ' is ready to give birth!')
                        print('^3[PREGNANCY DEBUG]^7 - Model: ' .. tostring(animal.model))
                        print('^3[PREGNANCY DEBUG]^7 - Breeding config exists: ' .. tostring(breedingConfig ~= nil))
                        if breedingConfig then
                            print('^3[PREGNANCY DEBUG]^7 - Offspring count: ' .. breedingConfig.offspringCount.min .. '-' .. breedingConfig.offspringCount.max)
                        end
                    end
                    
                    if breedingConfig then
                        local success, breedingError = pcall(function()
                        -- Determine number of offspring
                        local offspringCount = math.random(breedingConfig.offspringCount.min, breedingConfig.offspringCount.max)
                        local offspringTypes = {} -- Track offspring types for notification
                        
                        -- Spawn offspring near the mother
                        for i = 1, offspringCount do
                            local offspringId = CreateAnimalId()
                            if not offspringId then
                                print('^1[BREEDING ERROR]^7 Failed to generate offspring ID for mother ' .. animal.animalid)
                                goto skipOffspring
                            end
                            
                            -- Select offspring model based on breeding config probabilities
                            local offspringModel = SelectOffspringModel(animal.model)
                            
                            -- Set appropriate gender based on offspring model
                            local offspringGender
                            if offspringModel == 'a_c_bull_01' then
                                offspringGender = 'male'  -- Bulls are always male
                            elseif offspringModel == 'a_c_cow' then
                                offspringGender = 'female'  -- Cows are always female
                            else
                                -- For other models, use random gender
                                offspringGender = math.random() < 0.5 and 'male' or 'female'
                            end
                            
                            if Config.Debug then
                                print('^2[BREEDING DEBUG]^7 Creating offspring ' .. offspringId .. ': model=' .. offspringModel .. ', gender=' .. offspringGender)
                            end
                            
                            -- Validate parent position data
                            if not animal.pos_x or not animal.pos_y or not animal.pos_z or
                               type(animal.pos_x) ~= 'number' or type(animal.pos_y) ~= 'number' or type(animal.pos_z) ~= 'number' then
                                if Config.Debug then
                                    print('^1[BREEDING ERROR]^7 Invalid position data for mother ' .. animal.animalid)
                                    print('^1[BREEDING ERROR]^7 Position: x=' .. tostring(animal.pos_x) .. ', y=' .. tostring(animal.pos_y) .. ', z=' .. tostring(animal.pos_z))
                                end
                                goto skipOffspring
                            end
                            
                            -- Add some random variation to spawn position
                            local spawnVariation = 5.0
                            local randomX = animal.pos_x + math.random(-spawnVariation, spawnVariation)
                            local randomY = animal.pos_y + math.random(-spawnVariation, spawnVariation)
                            
                            -- Insert offspring into database with error handling (non-blocking)
                            MySQL.insert('INSERT INTO rex_ranch_animals (ranchid, animalid, model, pos_x, pos_y, pos_z, pos_w, health, hunger, thirst, scale, age, born, gender, pregnant, breeding_ready_time, mother_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)', {
                                animal.ranchid,
                                offspringId,
                                offspringModel,
                                randomX,
                                randomY,
                                animal.pos_z,
                                animal.pos_w or 0,
                                100, -- health
                                100, -- hunger
                                100, -- thirst
                                0.5, -- scale (young animal)
                                0,   -- age
                                currentTime, -- born
                                offspringGender,
                                0,   -- not pregnant
                                0,   -- can breed when old enough
                                animal.animalid -- mother_id
                            }, function(insertResult)
                                -- insertResult can be a table with insertId or a number
                                local success = false
                                if type(insertResult) == 'table' then
                                    success = insertResult.insertId ~= nil or insertResult.affectedRows > 0
                                elseif type(insertResult) == 'number' then
                                    success = insertResult > 0
                                end
                                
                                if not success then
                                    if Config.Debug then
                                        print('^1[BREEDING ERROR]^7 Failed to insert offspring ' .. offspringId .. ' for mother ' .. animal.animalid)
                                    end
                                else
                                    if Config.Debug then
                                        print('^2[BREEDING SUCCESS]^7 Successfully inserted offspring ' .. offspringId .. ' (' .. offspringModel .. ', ' .. offspringGender .. ') for mother ' .. animal.animalid)
                                    end
                                    
                                    -- Track offspring type for notification
                                    if not offspringTypes[offspringModel] then
                                        offspringTypes[offspringModel] = 0
                                    end
                                    offspringTypes[offspringModel] = offspringTypes[offspringModel] + 1
                                end
                            end)
                            
                            ::skipOffspring::
                        end
                        
                        -- Reset mother's pregnancy status and apply post-birth cooldown
                        local postBirthCooldown = GetBreedingCooldown('female')
                        local postBirthCooldownTime = currentTime + postBirthCooldown
                        
                        MySQL.update('UPDATE rex_ranch_animals SET pregnant = 0, gestation_end_time = NULL, breeding_ready_time = ? WHERE animalid = ?', 
                                     {postBirthCooldownTime, animal.animalid}, function(updateResult)
                            -- updateResult can be a table with affectedRows or a number
                            local rowsAffected = 0
                            if type(updateResult) == 'table' then
                                rowsAffected = updateResult.affectedRows or updateResult.changedRows or 0
                            elseif type(updateResult) == 'number' then
                                rowsAffected = updateResult
                            end
                            
                            if rowsAffected > 0 then
                                if Config.Debug then
                                    print('^2[BREEDING]^7 Applied post-birth cooldown to mother ' .. animal.animalid .. ': ' .. math.floor(postBirthCooldown / 3600) .. ' hours')
                                end
                                
                                -- Update client-side pregnancy data
                                if Config.UpdateClientsOnCron then
                                    TriggerClientEvent('rex-ranch:client:refreshSingleAnimal', -1, animal.animalid, {
                                        pregnant = 0,
                                        gestation_end_time = nil,
                                        breeding_ready_time = postBirthCooldownTime
                                    })
                                end
                            end
                        end)
                        
                        if Config.Debug then
                            print('^2[BREEDING]^7 Animal ' .. animal.animalid .. ' gave birth to ' .. offspringCount .. ' offspring')
                        end
                        
                        if Config.ServerNotify then
                            -- Create detailed offspring description
                            local offspringDescription = {}
                            for model, count in pairs(offspringTypes) do
                                local modelName = model == 'a_c_cow' and 'calf' or (model == 'a_c_bull_01' and 'bull calf' or model)
                                table.insert(offspringDescription, count .. ' ' .. modelName .. (count > 1 and 's' or ''))
                            end
                            local description = table.concat(offspringDescription, ', ')
                            print('^2[REX-RANCH BREEDING]^7 ' .. description .. ' born at ' .. animal.ranchid .. ' (mother: ' .. animal.animalid .. ')')
                        end
                        
                        -- Refresh animals after breeding to show new offspring
                        SetTimeout(2000, function()
                            TriggerEvent('rex-ranch:server:refreshAnimals')
                        end)
                        end)
                        
                        if not success then
                            if Config.Debug then
                                print('^1[BREEDING ERROR]^7 Error during offspring creation for animal ' .. animal.animalid .. ': ' .. tostring(breedingError))
                            end
                        end
                    else
                        if Config.Debug then
                            print('^1[BREEDING ERROR]^7 No breeding config found for model: ' .. tostring(animal.model))
                            print('^1[BREEDING ERROR]^7 Available breeding configs:')
                            for model, config in pairs(Config.BreedingConfig) do
                                print('^1[BREEDING ERROR]^7 - ' .. model)
                            end
                        end
                    end
                else
                    if Config.Debug and isPregnant then
                        print('^3[PREGNANCY DEBUG]^7 Animal ' .. animal.animalid .. ' is pregnant but not ready to give birth yet (time remaining: ' .. (animal.gestation_end_time - currentTime) .. ' seconds)')
                    end
                end
            else
                -- Debug when breeding conditions are not met
                local debugIsPregnant = (animal.pregnant == 1 or animal.pregnant == true or animal.pregnant == 'true')
                if Config.Debug and debugIsPregnant then
                    local reasons = {}
                    if not Config.BreedingEnabled then
                        table.insert(reasons, 'Breeding disabled')
                    end
                    if not debugIsPregnant then
                        table.insert(reasons, 'Not pregnant')
                    end
                    if not animal.gestation_end_time then
                        table.insert(reasons, 'No gestation end time')
                    end
                    if #reasons > 0 then
                        print('^3[PREGNANCY DEBUG]^7 Animal ' .. animal.animalid .. ' breeding skipped: ' .. table.concat(reasons, ', '))
                    end
                end
            end
            
            -- Check for production if enabled
            if Config.ProductionEnabled and Config.AnimalProducts[animal.model] then
                local productConfig = Config.AnimalProducts[animal.model]
                local currentTime = os.time()
                local lastProduction = animal.last_production or 0
                
                -- Check if animal is old enough and meets requirements
                if animalAge >= Config.MinAgeForProduction and
                   (animal.health or 100) >= productConfig.requiresHealth and
                   (animal.hunger or 100) >= productConfig.requiresHunger and
                   (animal.thirst or 100) >= productConfig.requiresThirst then
                    
                    -- Check if enough time has passed for production
                    if (currentTime - lastProduction) >= productConfig.productionTime then
                        if Config.Debug then
                            print('^3[PRODUCTION DEBUG]^7 Animal ' .. animal.animalid .. ' meets production requirements:')
                            print('^3[PRODUCTION DEBUG]^7 Age: ' .. animalAge .. ' (min: ' .. Config.MinAgeForProduction .. ')')
                            print('^3[PRODUCTION DEBUG]^7 Health: ' .. (animal.health or 100) .. '% (min: ' .. productConfig.requiresHealth .. '%)')
                            print('^3[PRODUCTION DEBUG]^7 Hunger: ' .. (animal.hunger or 100) .. '% (min: ' .. productConfig.requiresHunger .. '%)')
                            print('^3[PRODUCTION DEBUG]^7 Thirst: ' .. (animal.thirst or 100) .. '% (min: ' .. productConfig.requiresThirst .. '%)')
                            print('^3[PRODUCTION DEBUG]^7 Time since last production: ' .. (currentTime - lastProduction) .. 's (required: ' .. productConfig.productionTime .. 's)')
                        end
                        
                        -- Use a more reliable update with better error handling
                        local success, updateError = pcall(function()
                            return MySQL.update.await('UPDATE rex_ranch_animals SET last_production = ?, product_ready = 1 WHERE animalid = ?', {
                                currentTime, animal.animalid
                            })
                        end)
                        
                        if success and updateError and updateError > 0 then
                            if Config.Debug then
                                print('^2[PRODUCTION SUCCESS]^7 Animal ' .. animal.animalid .. ' (' .. animal.model .. ') produced ' .. productConfig.product .. ' (ready for collection)')
                            end
                            
                            -- Update client-side production data immediately
                            if Config.UpdateClientsOnCron then
                                TriggerClientEvent('rex-ranch:client:refreshSingleAnimal', -1, animal.animalid, {
                                    last_production = currentTime,
                                    product_ready = 1
                                })
                            end
                            
                            if Config.ServerNotify then
                                print('^2[REX-RANCH PRODUCTION]^7 ' .. productConfig.product .. ' ready for collection from animal ' .. animal.animalid .. ' at ranch ' .. animal.ranchid)
                            end
                        else
                            if Config.Debug then
                                print('^1[PRODUCTION ERROR]^7 Failed to update production status for animal ' .. animal.animalid .. ' - Success: ' .. tostring(success) .. ', Result: ' .. tostring(updateError))
                            end
                        end
                    else
                        if Config.Debug then
                            local remainingTime = productConfig.productionTime - (currentTime - lastProduction)
                            print('^3[PRODUCTION DEBUG]^7 Animal ' .. animal.animalid .. ' not ready for production. Time remaining: ' .. remainingTime .. 's')
                        end
                    end
                else
                    if Config.Debug then
                        local issues = {}
                        if animalAge < Config.MinAgeForProduction then
                            table.insert(issues, 'Too young (' .. animalAge .. 'd, need ' .. Config.MinAgeForProduction .. 'd)')
                        end
                        if (animal.health or 100) < productConfig.requiresHealth then
                            table.insert(issues, 'Low health (' .. (animal.health or 100) .. '%, need ' .. productConfig.requiresHealth .. '%)')
                        end
                        if (animal.hunger or 100) < productConfig.requiresHunger then
                            table.insert(issues, 'Low hunger (' .. (animal.hunger or 100) .. '%, need ' .. productConfig.requiresHunger .. '%)')
                        end
                        if (animal.thirst or 100) < productConfig.requiresThirst then
                            table.insert(issues, 'Low thirst (' .. (animal.thirst or 100) .. '%, need ' .. productConfig.requiresThirst .. '%)')
                        end
                        
                        if #issues > 0 then
                            print('^3[PRODUCTION DEBUG]^7 Animal ' .. animal.animalid .. ' cannot produce: ' .. table.concat(issues, ', '))
                        end
                    end
                end
            end
            
            -- Reduce hunger and thirst
            local newHunger = math.max(0, (animal.hunger or 100) - Config.HungerDecayRate)
            local newThirst = math.max(0, (animal.thirst or 100) - Config.ThirstDecayRate)
            local currentHealth = animal.health or 100
            local newHealth = currentHealth
            
            -- Check if animal is starving or dehydrated
            if newHunger <= Config.MinSurvivalStats or newThirst <= Config.MinSurvivalStats then
                newHealth = math.max(0, currentHealth - Config.HealthDecayRate)
                if Config.Debug then
                    print('^3[DEBUG]^7 Animal ' .. animal.animalid .. ' is starving/dehydrated. Health: ' .. newHealth)
                end
            -- Check if animal is well-fed and watered for health regeneration
            elseif currentHealth < 100 and Config.HealthRegenerationRate and Config.MinStatsForRegeneration then
                if newHunger >= Config.MinStatsForRegeneration and newThirst >= Config.MinStatsForRegeneration then
                    newHealth = math.min(100, currentHealth + Config.HealthRegenerationRate)
                    if Config.Debug then
                        print('^2[DEBUG]^7 Animal ' .. animal.animalid .. ' is regenerating health. Health: ' .. currentHealth .. ' -> ' .. newHealth)
                    end
                end
            end
            
            -- Mark animal for removal if health reaches zero
            if newHealth <= 0 then
                table.insert(animalsToRemove, animal.animalid)
                if Config.ServerNotify then
                    print('^1[REX-RANCH]^7 Animal ' .. animal.animalid .. ' has died and will be removed from the database.')
                end
            else
                -- Collect updates for batch processing including scale and age
                table.insert(batchUpdates, {
                    animalid = animal.animalid,
                    hunger = newHunger,
                    thirst = newThirst,
                    health = newHealth,
                    scale = scale,
                    age = animalAge
                })
                if Config.Debug then
                    print('^2[DEBUG]^7 Prepared update for animal ' .. animal.animalid .. ' - Hunger: ' .. newHunger .. ', Thirst: ' .. newThirst .. ', Health: ' .. newHealth)
                end
            end
            
            ::continue::
        end
        
        -- Process batch updates for living animals using individual updates for reliability
        if #batchUpdates > 0 then
            local updateSuccess = 0
            local updateFailed = 0
            
            for _, update in ipairs(batchUpdates) do
                -- Validate update data
                if not update.animalid then
                    if Config.Debug then
                        print('^1[ERROR]^7 Skipping update with missing animalid')
                    end
                    updateFailed = updateFailed + 1
                    goto continue_update
                end
                
                -- Use individual updates for better reliability (non-blocking)
                MySQL.update('UPDATE rex_ranch_animals SET hunger = ?, thirst = ?, health = ?, scale = ?, age = ? WHERE animalid = ?', {
                    update.hunger or 0,
                    update.thirst or 0,
                    update.health or 0,
                    update.scale or 1.00,
                    update.age or 0,
                    update.animalid
                }, function(result)
                    -- result can be a table with affectedRows or a number
                    local rowsAffected = 0
                    if type(result) == 'table' then
                        rowsAffected = result.affectedRows or result.changedRows or 0
                    elseif type(result) == 'number' then
                        rowsAffected = result
                    end
                    
                    if rowsAffected > 0 then
                        updateSuccess = updateSuccess + 1
                        if Config.Debug then
                            print('^2[DEBUG]^7 Updated animal ' .. update.animalid .. ' - Hunger: ' .. (update.hunger or 0) .. ', Thirst: ' .. (update.thirst or 0) .. ', Health: ' .. (update.health or 0) .. ', Age: ' .. (update.age or 0) .. ' days')
                        end
                        
                        -- Update client-side data for this specific animal
                        if Config.UpdateClientsOnCron then
                            TriggerClientEvent('rex-ranch:client:refreshSingleAnimal', -1, update.animalid, {
                                hunger = update.hunger,
                                thirst = update.thirst,
                                health = update.health,
                                scale = update.scale,
                                age = update.age
                            })
                        end
                    else
                        updateFailed = updateFailed + 1
                        if Config.Debug then
                            print('^1[ERROR]^7 Update returned 0 rows affected for animal ' .. update.animalid)
                        end
                    end
                end)
                
                ::continue_update::
            end
            
            if Config.Debug then
                print('^2[DEBUG]^7 Processed ' .. #batchUpdates .. ' animal updates: ' .. updateSuccess .. ' successful, ' .. updateFailed .. ' failed')
            end
        end
        
        -- Clean up expired breeding cooldowns (separate simple query)
        local currentTime = os.time()
        MySQL.query('SELECT animalid FROM rex_ranch_animals WHERE breeding_ready_time > 0 AND breeding_ready_time <= ?', {currentTime}, function(expiredAnimals)
            if expiredAnimals and #expiredAnimals > 0 then
                -- Clear the cooldowns in database
                MySQL.execute('UPDATE rex_ranch_animals SET breeding_ready_time = 0 WHERE breeding_ready_time > 0 AND breeding_ready_time <= ?', {currentTime})
                
                -- Update client cache for each expired animal
                if Config.UpdateClientsOnCron then
                    for _, animal in ipairs(expiredAnimals) do
                        TriggerClientEvent('rex-ranch:client:refreshSingleAnimal', -1, animal.animalid, {
                            breeding_ready_time = 0
                        })
                        
                        if Config.Debug then
                            print('^2[DEBUG]^7 Cleared breeding cooldown for animal ' .. animal.animalid)
                        end
                    end
                end
            end
        end)
        
        -- Remove dead animals from database and client
        if #animalsToRemove > 0 then
            if Config.Debug then
                print('^1[REX-RANCH]^7 Removing ' .. #animalsToRemove .. ' dead animals from database and game world')
                for _, id in ipairs(animalsToRemove) do
                    print('^1[REX-RANCH DEBUG]^7 Dead animal ID: ' .. tostring(id))
                end
            end
            
            -- Immediately remove animals from clients (don't wait for database)
            for _, animalid in ipairs(animalsToRemove) do
                if Config.Debug then
                    print('^1[REX-RANCH]^7 Immediately removing animal ' .. animalid .. ' from all clients')
                end
                TriggerClientEvent('rex-ranch:client:removeAnimal', -1, animalid)
            end
            
            -- Then remove from database
            for _, animalid in ipairs(animalsToRemove) do
                MySQL.execute('DELETE FROM rex_ranch_animals WHERE animalid = ?', {animalid}, function(deleteResult)
                    -- deleteResult can be a table with affectedRows or a number
                    local rowsAffected = 0
                    if type(deleteResult) == 'table' then
                        rowsAffected = deleteResult.affectedRows or deleteResult.changedRows or 0
                    elseif type(deleteResult) == 'number' then
                        rowsAffected = deleteResult
                    end
                    
                    if rowsAffected > 0 then
                        if Config.Debug then
                            print('^2[REX-RANCH]^7 Successfully removed animal ' .. animalid .. ' from database')
                        end
                    else
                        if Config.Debug then
                            print('^1[REX-RANCH ERROR]^7 Failed to remove animal ' .. animalid .. ' from database')
                        end
                        -- If database removal fails, we should still keep the client removal
                        -- The animal is already gone from client, database cleanup can be retried
                    end
                end)
            end
            
            -- Refresh animals on client after removals (delayed)
            SetTimeout(1000, function()
                TriggerEvent('rex-ranch:server:refreshAnimals')
            end)
            
            if Config.ServerNotify then
                print('^1[REX-RANCH]^7 Removed ' .. #animalsToRemove .. ' dead animals from the game world')
            end
        end
        
        -- Print completion summary
        if Config.Debug then
            if #animalsToRemove > 0 then
                print('^2[REX-RANCH]^7 Animal survival check completed. ' .. #animals .. ' animals processed, ' .. #animalsToRemove .. ' animals died.')
            else
                print('^2[REX-RANCH]^7 Animal survival check completed. ' .. #animals .. ' animals updated.')
            end
            
            if #batchUpdates > 0 and Config.UpdateClientsOnCron then
                print('^2[REX-RANCH]^7 Updated client data for ' .. #batchUpdates .. ' animals')
            end
        end
        
        if Config.Debug then
            print('^2[REX-RANCH CRON]^7 Animal update cycle completed successfully')
        end
        
        -- Refresh all animal data on clients after cronjob completion
        -- This ensures any missed individual updates are caught
        if Config.RefreshAfterCron then
            SetTimeout(500, function()
                if Config.Debug then
                    print('^2[REX-RANCH CRON]^7 Refreshing all animal data on clients')
                end
                TriggerEvent('rex-ranch:server:refreshAnimals')
            end)
        end
    end) -- Close MySQL.query callback
    end) -- Close pcall function
    
    if not success then
        cronFailures = cronFailures + 1
        print('^1[REX-RANCH CRON ERROR]^7 Animal cron job failed (failure #' .. cronFailures .. '): ' .. tostring(cronError))
        
        -- If we have too many failures, something is seriously wrong
        if cronFailures >= 5 then
            print('^1[REX-RANCH CRITICAL]^7 Animal survival cronjob has failed ' .. cronFailures .. ' times!')
            print('^1[REX-RANCH CRITICAL]^7 This may indicate a database connection issue or resource conflict.')
        end
    else
        cronFailures = 0 -- Reset failure counter on success
    end
end

---------------------------------------------
-- Staff Management System
---------------------------------------------

-- Get staff list for a ranch
RSGCore.Functions.CreateCallback('rex-ranch:server:getStaffList', function(source, cb, ranchid)
    local Player = RSGCore.Functions.GetPlayer(source)
    if not Player or not ranchid then 
        cb({employees = {}})
        return 
    end
    
    -- Check if player has permission to manage staff
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.StaffManagement.MinGradeToManage then
        cb({employees = {}})
        return
    end
    
    -- Get all players with this job
    local employees = {}
    local players = RSGCore.Functions.GetPlayers()
    
    for _, playerId in ipairs(players) do
        local targetPlayer = RSGCore.Functions.GetPlayer(playerId)
        if targetPlayer and targetPlayer.PlayerData.job.name == ranchid then
            table.insert(employees, {
                citizenid = targetPlayer.PlayerData.citizenid,
                name = targetPlayer.PlayerData.charinfo.firstname .. ' ' .. targetPlayer.PlayerData.charinfo.lastname,
                grade = targetPlayer.PlayerData.job.grade.level,
                grade_label = targetPlayer.PlayerData.job.grade.name,
                is_online = true
            })
        end
    end
    
    -- Also get offline employees from database
    MySQL.query('SELECT citizenid, charinfo, job FROM players WHERE JSON_EXTRACT(job, "$.name") = ?', {ranchid}, function(result)
        if result then
            for _, row in ipairs(result) do
                local alreadyAdded = false
                for _, emp in ipairs(employees) do
                    if emp.citizenid == row.citizenid then
                        alreadyAdded = true
                        break
                    end
                end
                
                if not alreadyAdded then
                    local charinfo = json.decode(row.charinfo)
                    local job = json.decode(row.job)
                    
                    table.insert(employees, {
                        citizenid = row.citizenid,
                        name = charinfo.firstname .. ' ' .. charinfo.lastname,
                        grade = job.grade.level,
                        grade_label = job.grade.name,
                        is_online = false
                    })
                end
            end
        end
        
        cb({employees = employees})
    end)
end)

-- Get nearby players
RSGCore.Functions.CreateCallback('rex-ranch:server:getNearbyPlayers', function(src, cb)
    local Player = RSGCore.Functions.GetPlayer(src)
    if not Player then 
        cb({})
        return 
    end
    
    local ped = GetPlayerPed(src)
    local coords = GetEntityCoords(ped)
    local players = {}
    
    for _, playerId in ipairs(RSGCore.Functions.GetPlayers()) do
        if playerId ~= src then
            local targetPed = GetPlayerPed(playerId)
            local targetCoords = GetEntityCoords(targetPed)
            local distance = #(coords - targetCoords)
            
            if distance < 10.0 then -- Within 10 meters
                local targetPlayer = RSGCore.Functions.GetPlayer(playerId)
                if targetPlayer then
                    table.insert(players, {
                        id = playerId,
                        name = targetPlayer.PlayerData.charinfo.firstname .. ' ' .. targetPlayer.PlayerData.charinfo.lastname,
                        distance = distance
                    })
                end
            end
        end
    end
    
    cb(players)
end)

-- Hire employee
RegisterNetEvent('rex-ranch:server:hireEmployee', function(ranchid, targetId, grade)

    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    local Target = RSGCore.Functions.GetPlayer(targetId)

    if not Player or not Target then return end
    
    -- Check permissions
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.StaffManagement.MinGradeToManage then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You do not have permission to hire staff!'})
        return
    end

    -- Check if target player is already employed at this ranch
    if Target.PlayerData.job.name == ranchid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'This player is already employed at your ranch!'})
        if Config.Debug then
            print('^3[STAFF MANAGEMENT]^7 Attempted to hire ' .. Target.PlayerData.charinfo.firstname .. ' who is already employed at ' .. ranchid)
        end
        return
    end

	-- check if the player can take the job
	local canTake = exports['rsg-multijob']:CanTakeNewJob(Target.PlayerData.citizenid)
	if not canTake then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Unable to hire as player has too many jobs!'})
        return
	end
	
	local staffCount = exports['rex-ranch']:getStaffCount(ranchid)
	if staffCount >= Config.StaffManagement.MaxEmployeesPerRanch then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You have the maximum staff hired!'})
        return
	end

	Target.Functions.SetJob(ranchid, grade)
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = 'Job added successfully'})
    TriggerClientEvent('ox_lib:notify', targetId, {type = 'success', description = 'You have been hired at ' .. ranchid .. '!'})

end)

-- Fire employee
RegisterNetEvent('rex-ranch:server:fireEmployee', function(ranchid, targetCitizenid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if not Player then return end
    
    -- Check permissions
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.StaffManagement.MinGradeToManage then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You do not have permission to fire staff!'})
        return
    end
    
    -- Prevent manager from firing themselves
    if Player.PlayerData.citizenid == targetCitizenid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You cannot fire yourself!'})
        return
    end
    
    -- Get target player
    local Target = RSGCore.Functions.GetPlayerByCitizenId(targetCitizenid)
    
    if Target then
        -- Verify the target is actually employed at this ranch
        if Target.PlayerData.job.name ~= ranchid then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'This player is not employed at your ranch!'})
            return
        end
        
        -- Player is online
        Target.Functions.SetJob('unemployed', 0)
		-- update multijob
		local success = exports['rsg-multijob']:RemoveJobFromPlayer(targetCitizenid, ranchid)
		if success then
			TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = 'Player removed from multijob!'})
		else
			print('Failed to remove job - player may not have this job')
			TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Failed to remove job - player may not have this job!'})
		end
        TriggerClientEvent('ox_lib:notify', Target.PlayerData.source, {type = 'error', description = 'You have been fired from ' .. ranchid .. '!'})
    else
        -- Player is offline, verify they work at this ranch first
        local checkResult = MySQL.query.await('SELECT job FROM players WHERE citizenid = ?', {targetCitizenid})
        if checkResult and #checkResult > 0 then
            local jobData = json.decode(checkResult[1].job)
            if jobData.name ~= ranchid then
                TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'This player is not employed at your ranch!'})
                return
            end
        else
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Employee not found!'})
            return
        end
        
        -- update database
        MySQL.update('UPDATE players SET job = JSON_SET(JSON_SET(job, "$.name", "unemployed"), "$.grade", JSON_OBJECT("level", 0, "name", "Unemployed")) WHERE citizenid = ?', {targetCitizenid})
		-- update multijob
		local success = exports['rsg-multijob']:RemoveJobFromPlayer(targetCitizenid, ranchid)
		if success then
			TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = 'Player removed from multijob!'})
		else
			print('Failed to remove job - player may not have this job')
			TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Failed to remove job - player may not have this job!'})
		end

    end
    
    TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = 'Employee has been fired!'})
    
    if Config.Debug then
        print('^3[STAFF MANAGEMENT]^7 ' .. Player.PlayerData.charinfo.firstname .. ' fired employee ' .. targetCitizenid .. ' from ' .. ranchid)
    end
end)

-- Promote employee
RegisterNetEvent('rex-ranch:server:promoteEmployee', function(ranchid, targetCitizenid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if not Player then return end
    
    -- Check permissions
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.StaffManagement.MinGradeToManage then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You do not have permission to promote staff!'})
        return
    end
    
    local Target = RSGCore.Functions.GetPlayerByCitizenId(targetCitizenid)
    
    if Target then
        -- Verify the target is actually employed at this ranch
        if Target.PlayerData.job.name ~= ranchid then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'This player is not employed at your ranch!'})
            return
        end
        
        local currentGrade = Target.PlayerData.job.grade.level
        local maxGrade = 3 -- Boss level
        
        -- Prevent promoting to same or higher grade than manager
        if currentGrade + 1 >= Player.PlayerData.job.grade.level and Player.PlayerData.job.grade.level < maxGrade then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You cannot promote an employee to your rank or higher!'})
            return
        end
        
        if currentGrade >= maxGrade then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Employee is already at maximum rank!'})
            return
        end
        
        Target.Functions.SetJob(ranchid, currentGrade + 1)
        TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = 'Employee promoted!'})
        TriggerClientEvent('ox_lib:notify', Target.PlayerData.source, {type = 'success', description = 'You have been promoted!'})
        
        if Config.Debug then
            print('^2[STAFF MANAGEMENT]^7 ' .. Player.PlayerData.charinfo.firstname .. ' promoted ' .. Target.PlayerData.charinfo.firstname .. ' to grade ' .. (currentGrade + 1))
        end
    else
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Employee must be online to promote!'})
    end
end)

-- Demote employee
RegisterNetEvent('rex-ranch:server:demoteEmployee', function(ranchid, targetCitizenid)
    local src = source
    local Player = RSGCore.Functions.GetPlayer(src)
    
    if not Player then return end
    
    -- Check permissions
    if Player.PlayerData.job.name ~= ranchid or Player.PlayerData.job.grade.level < Config.StaffManagement.MinGradeToManage then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You do not have permission to demote staff!'})
        return
    end
    
    -- Prevent manager from demoting themselves
    if Player.PlayerData.citizenid == targetCitizenid then
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You cannot demote yourself!'})
        return
    end
    
    local Target = RSGCore.Functions.GetPlayerByCitizenId(targetCitizenid)
    
    if Target then
        -- Verify the target is actually employed at this ranch
        if Target.PlayerData.job.name ~= ranchid then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'This player is not employed at your ranch!'})
            return
        end
        
        local currentGrade = Target.PlayerData.job.grade.level
        
        -- Prevent demoting someone at same or higher rank (unless you're boss)
        if currentGrade >= Player.PlayerData.job.grade.level and Player.PlayerData.job.grade.level < 3 then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'You cannot demote someone at your rank or higher!'})
            return
        end
        
        if currentGrade <= 0 then
            TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Employee is already at minimum rank!'})
            return
        end
        
        Target.Functions.SetJob(ranchid, currentGrade - 1)
        TriggerClientEvent('ox_lib:notify', src, {type = 'success', description = 'Employee demoted!'})
        TriggerClientEvent('ox_lib:notify', Target.PlayerData.source, {type = 'info', description = 'You have been demoted!'})
        
        if Config.Debug then
            print('^3[STAFF MANAGEMENT]^7 ' .. Player.PlayerData.charinfo.firstname .. ' demoted ' .. Target.PlayerData.charinfo.firstname .. ' to grade ' .. (currentGrade - 1))
        end
    else
        TriggerClientEvent('ox_lib:notify', src, {type = 'error', description = 'Employee must be online to demote!'})
    end
end)

