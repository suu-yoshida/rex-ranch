local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- Core Variables
---------------------------------------------
local animalDataCache = {}
local followStates = {}
local transportingAnimals = {}
local isBusy = false
local wanderStates = {} -- Track wandering state for each animal

---------------------------------------------
-- Spawn Manager (New System)
---------------------------------------------
local SpawnManager = {
    entities = {},          -- Stores spawned animal entities with metadata
    pending = {},          -- Tracks pending spawn requests
    config = {
        spawnDistance = 50.0,   -- Distance to spawn animals
        despawnDistance = 75.0, -- Distance to despawn animals
        checkInterval = 2000,   -- Check frequency in ms
        maxConcurrentSpawns = 5 -- Max animals spawning at once
    }
}

-- Initialize spawn manager
function SpawnManager:Initialize()
    self.entities = {}
    self.pending = {}
    
    -- Clean up any orphaned entities from previous sessions
    CreateThread(function()
        Wait(2000) -- Wait for player to fully load
        self:CleanupOrphanedEntities()
    end)
    
    -- Start the spawn check thread
    CreateThread(function()
        while true do
            self:CheckSpawnRequests()
            Wait(self.config.checkInterval)
        end
    end)
    
    if Config.Debug then
        print('^2[SPAWN MANAGER]^7 Initialized new spawn system')
    end
end

-- Check what animals need to be spawned/despawned
function SpawnManager:CheckSpawnRequests()
    if not cache.ped or not DoesEntityExist(cache.ped) or #animalDataCache == 0 then
        return
    end
    
    -- Clean up stale pending requests (older than 30 seconds)
    local currentTime = GetGameTimer()
    local staleTimeout = 30000
    for animalId, requestData in pairs(self.pending) do
        if (currentTime - requestData.timestamp) > staleTimeout then
            if Config.Debug then
                print('^3[SPAWN MANAGER]^7 Cleaning up stale pending request for animal ' .. animalId)
            end
            self.pending[animalId] = nil
        end
    end
    
    local playerCoords = GetEntityCoords(cache.ped)
    local pendingCount = self:GetPendingCount()
    
    for _, animalData in ipairs(animalDataCache) do
        if self:IsValidAnimalData(animalData) then
            local animalId = tostring(animalData.animalid)
            local animalPos = vector3(animalData.pos_x, animalData.pos_y, animalData.pos_z)
            local distance = #(playerCoords - animalPos)
            
            -- Check if we should spawn this animal
            if distance <= self.config.spawnDistance then
                if not self.entities[animalId] and not self.pending[animalId] then
                    if pendingCount < self.config.maxConcurrentSpawns then
                        self:RequestSpawn(animalId, animalData)
                        pendingCount = pendingCount + 1
                    end
                end
            -- Check if we should despawn this animal
            elseif distance > self.config.despawnDistance then
                if self.entities[animalId] then
                    -- Don't despawn if animal is being transported or following
                    if not transportingAnimals[animalId] and not followStates[animalId] then
                        self:DespawnAnimal(animalId)
                    end
                end
            end
        end
    end
end

-- Validate animal data
function SpawnManager:IsValidAnimalData(data)
    return data and data.animalid and data.model and 
           data.pos_x and data.pos_y and data.pos_z and
           type(data.pos_x) == 'number' and type(data.pos_y) == 'number' and type(data.pos_z) == 'number'
end

-- Request to spawn an animal
function SpawnManager:RequestSpawn(animalId, animalData)
    -- Don't request if already spawned
    if self.entities[animalId] then
        local existingEntity = self.entities[animalId].entity
        if DoesEntityExist(existingEntity) then
            if Config.Debug then
                print('^3[SPAWN MANAGER]^7 Animal ' .. animalId .. ' already spawned, skipping request')
            end
            return
        else
            -- Clean up stale reference
            self.entities[animalId] = nil
        end
    end
    
    -- Don't request if already pending
    if self.pending[animalId] then
        if Config.Debug then
            print('^3[SPAWN MANAGER]^7 Spawn already pending for animal ' .. animalId)
        end
        return
    end
    
    self.pending[animalId] = {
        data = animalData,
        timestamp = GetGameTimer()
    }
    
    TriggerServerEvent('rex-ranch:server:requestAnimalSpawn', animalId, animalData)
    
    if Config.Debug then
        print('^3[SPAWN MANAGER]^7 Requested spawn for animal ' .. animalId)
    end
end

-- Spawn an animal entity
function SpawnManager:SpawnAnimal(animalId, animalData, networkId, isCreator)
    -- Check if animal already exists
    if self.entities[animalId] then
        local existingEntity = self.entities[animalId].entity
        if DoesEntityExist(existingEntity) then
            if Config.Debug then
                print('^3[SPAWN MANAGER]^7 Animal ' .. animalId .. ' already exists (entity: ' .. existingEntity .. '), skipping spawn')
            end
            self.pending[animalId] = nil
            return true
        else
            -- Entity was deleted but not cleaned up, remove it
            if Config.Debug then
                print('^3[SPAWN MANAGER]^7 Cleaning up stale entity reference for animal ' .. animalId)
            end
            self.entities[animalId] = nil
        end
    end
    
    -- If we have a networkId but are not the creator, wait for the entity to sync
    if networkId and not isCreator then
        -- Try to get the existing networked entity
        local entity = NetworkGetEntityFromNetworkId(networkId)
        if DoesEntityExist(entity) then
            if Config.Debug then
                print('^2[SPAWN MANAGER]^7 Using synced networked entity ' .. entity .. ' for animal ' .. animalId .. ' (netId: ' .. networkId .. ')')
            end
            self:ConfigureAnimalEntity(entity, animalData)
            self.entities[animalId] = {
                entity = entity,
                data = animalData,
                spawnTime = GetGameTimer(),
                networkId = networkId
            }
            self.pending[animalId] = nil
            self:SetupAnimalInteraction(entity, animalData)
            if Config.AnimalWanderingEnabled then
                self:SetupAnimalWandering(animalId, entity, animalData)
            end
            return true
        end
        
        -- Entity doesn't exist yet, wait a bit and retry
        if Config.Debug then
            print('^3[SPAWN MANAGER]^7 Waiting for networked entity to sync for animal ' .. animalId .. ' (netId: ' .. networkId .. ')')
        end
        CreateThread(function()
            for i = 1, 10 do
                Wait(500)
                local entity = NetworkGetEntityFromNetworkId(networkId)
                if DoesEntityExist(entity) then
                    if Config.Debug then
                        print('^2[SPAWN MANAGER]^7 Synced networked entity ' .. entity .. ' for animal ' .. animalId .. ' after ' .. (i * 500) .. 'ms')
                    end
                    self:ConfigureAnimalEntity(entity, animalData)
                    self.entities[animalId] = {
                        entity = entity,
                        data = animalData,
                        spawnTime = GetGameTimer(),
                        networkId = networkId
                    }
                    self.pending[animalId] = nil
                    self:SetupAnimalInteraction(entity, animalData)
                    if Config.AnimalWanderingEnabled then
                        self:SetupAnimalWandering(animalId, entity, animalData)
                    end
                    return
                end
            end
            -- Timed out
            if Config.Debug then
                print('^1[SPAWN MANAGER]^7 Timed out waiting for networked entity for animal ' .. animalId)
            end
            self.pending[animalId] = nil
        end)
        return true
    end
    
    -- Only create if we are the creator
    if not isCreator then
        if Config.Debug then
            print('^3[SPAWN MANAGER]^7 Not creator and no networkId, cannot spawn animal ' .. animalId)
        end
        self.pending[animalId] = nil
        return false
    end
    
    local entity, newNetworkId = self:CreateAnimalEntity(animalData, nil)
    if not entity then
        if Config.Debug then
            print('^1[SPAWN MANAGER]^7 Failed to create entity for animal ' .. animalId)
        end
        self.pending[animalId] = nil
        return false
    end
    
    -- Store entity with metadata including network ID
    self.entities[animalId] = {
        entity = entity,
        data = animalData,
        spawnTime = GetGameTimer(),
        networkId = newNetworkId or networkId
    }
    
    -- Clean up pending request
    self.pending[animalId] = nil
    
    -- Report network ID to server for tracking (we are the creator)
    if newNetworkId then
        TriggerServerEvent('rex-ranch:server:registerAnimalNetworkId', animalId, newNetworkId)
    end
    
    -- Setup interaction (restricted to ranch staff via canInteract)
    self:SetupAnimalInteraction(entity, animalData)
    
    -- Setup wandering behavior if enabled
    if Config.AnimalWanderingEnabled then
        self:SetupAnimalWandering(animalId, entity, animalData)
    end
    
    if Config.Debug then
        print('^2[SPAWN MANAGER]^7 Spawned animal ' .. animalId .. ' (entity: ' .. entity .. ', netId: ' .. (newNetworkId or networkId or 'none') .. ')')
    end
    
    return true
end

-- Create the actual animal entity
function SpawnManager:CreateAnimalEntity(animalData, networkId)
    local model = GetHashKey(animalData.model)
    
    -- Request model
    lib.requestModel(model, 5000)
    if not HasModelLoaded(model) then
        return nil
    end
    
    -- Check if we should use an existing networked entity from server
    if networkId and networkId > 0 then
        local entity = NetworkGetEntityFromNetworkId(networkId)
        if DoesEntityExist(entity) then
            if Config.Debug then
                print('^2[SPAWN MANAGER]^7 Using existing networked entity ' .. entity .. ' (netId: ' .. networkId .. ')')
            end
            self:ConfigureAnimalEntity(entity, animalData)
            return entity, networkId
        end
    end
    
    -- Create the ped as a networked entity (isNetwork = true)
    local entity = CreatePed(
        model,
        animalData.pos_x,
        animalData.pos_y,
        animalData.pos_z - 1.0,
        animalData.pos_w or 0,
        true,  -- isNetwork: true for multiplayer visibility
        false,
        0,
        0
    )
    
    if not DoesEntityExist(entity) then
        return nil
    end
    
    -- Register entity as networked and get network ID
    NetworkRegisterEntityAsNetworked(entity)
    local newNetworkId = NetworkGetNetworkIdFromEntity(entity)
    
    -- Configure entity
    self:ConfigureAnimalEntity(entity, animalData)
    
    if Config.Debug then
        print('^2[SPAWN MANAGER]^7 Created networked entity ' .. entity .. ' (netId: ' .. newNetworkId .. ')')
    end
    
    return entity, newNetworkId
end

-- Configure animal entity properties
function SpawnManager:ConfigureAnimalEntity(entity, animalData)
    -- Networked entity configuration
    -- Animals are visible to all players but interactions are restricted to ranch staff
    
    -- Scale handling
    local scale = tonumber(animalData.scale) or 1.0
    if scale <= 0 or scale ~= scale then scale = 1.0 end
    scale = math.min(math.max(scale, 0.1), 2.0)
    SetPedScale(entity, scale)
    
    -- Entity properties
    -- SetEntityAsMissionEntity keeps it from being auto-deleted
    SetEntityAsMissionEntity(entity, true, true)
    SetEntityInvincible(entity, true)
    FreezeEntityPosition(entity, false)
    SetPedOutfitPreset(entity, 0)
    SetRelationshipBetweenGroups(1, GetPedRelationshipGroupHash(entity), joaat('PLAYER'))
    SetBlockingOfNonTemporaryEvents(entity, true)
    
    -- Fade in effect
    if Config.AnimalFadeIn then
        SetEntityAlpha(entity, 0, false)
        CreateThread(function()
            for i = 0, 255, 51 do
                if DoesEntityExist(entity) then
                    SetEntityAlpha(entity, i, false)
                    Wait(50)
                end
            end
        end)
    end
end

-- Setup animal interaction (ox_target)
function SpawnManager:SetupAnimalInteraction(entity, animalData)
    exports.ox_target:addLocalEntity(entity, {
        {
            name = 'ranch_animal',
            icon = 'far fa-eye',
            label = locale('animal_actions'),
            onSelect = function()
                TriggerEvent('rex-ranch:client:animalmenu', entity, animalData)
            end,
            canInteract = function()
                return isPlayerRanchStaff()
            end,
            distance = 2.0
        }
    })
end

-- Setup animal wandering behavior
function SpawnManager:SetupAnimalWandering(animalId, entity, animalData)
    -- Store spawn point as home location
    local homePosition = vector3(animalData.pos_x, animalData.pos_y, animalData.pos_z)
    
    -- Initialize wander state
    wanderStates[animalId] = {
        entity = entity,
        homePosition = homePosition,
        state = 'idle', -- 'idle' or 'moving'
        stateChangeTime = GetGameTimer(),
        targetPosition = nil,
        active = true
    }
    
    -- Start wander behavior thread
    CreateThread(function()
        while wanderStates[animalId] and wanderStates[animalId].active do
            self:UpdateAnimalWander(animalId)
            Wait(Config.WanderCheckInterval or 2000)
        end
    end)
    
    if Config.Debug then
        print('^2[WANDER]^7 Setup wandering for animal ' .. animalId)
    end
end

-- Update animal wandering behavior
function SpawnManager:UpdateAnimalWander(animalId)
    local wanderState = wanderStates[animalId]
    if not wanderState then return end
    
    local entity = wanderState.entity
    
    -- Check if entity still exists
    if not DoesEntityExist(entity) then
        wanderStates[animalId] = nil
        return
    end
    
    -- Don't wander if following player or being transported
    if followStates[animalId] or transportingAnimals[animalId] then
        return
    end
    
    local currentTime = GetGameTimer()
    local timeSinceStateChange = currentTime - wanderState.stateChangeTime
    
    if wanderState.state == 'idle' then
        -- Animal is standing still
        local idleTime = math.random(Config.WanderIdleTimeMin or 10000, Config.WanderIdleTimeMax or 30000)
        
        if timeSinceStateChange >= idleTime then
            -- Time to start moving
            self:StartAnimalWander(animalId, wanderState)
        end
    elseif wanderState.state == 'moving' then
        -- Animal is moving
        local moveTime = math.random(Config.WanderMoveTimeMin or 5000, Config.WanderMoveTimeMax or 15000)
        
        -- Check if reached target or time expired
        if wanderState.targetPosition then
            local currentPos = GetEntityCoords(entity)
            local distanceToTarget = #(currentPos - wanderState.targetPosition)
            
            if distanceToTarget < 1.0 or timeSinceStateChange >= moveTime then
                -- Reached destination or timeout, stop moving
                self:StopAnimalWander(animalId, wanderState)
            end
        else
            -- No target, something went wrong, stop
            self:StopAnimalWander(animalId, wanderState)
        end
    end
end

-- Start animal wandering to a new position
function SpawnManager:StartAnimalWander(animalId, wanderState)
    local entity = wanderState.entity
    local homePos = wanderState.homePosition
    
    -- Generate random wander position within radius from home
    local wanderRadius = Config.WanderRadius or 15.0
    local minDistance = Config.WanderMinDistance or 3.0
    
    -- Random angle and distance
    local angle = math.random() * math.pi * 2
    local distance = math.random() * (wanderRadius - minDistance) + minDistance
    
    -- Calculate target position
    local targetX = homePos.x + math.cos(angle) * distance
    local targetY = homePos.y + math.sin(angle) * distance
    
    -- Get ground Z coordinate
    local foundGround, groundZ = GetGroundZFor_3dCoord(targetX, targetY, homePos.z + 10.0, false)
    local targetZ = foundGround and groundZ or homePos.z
    
    local targetPos = vector3(targetX, targetY, targetZ)
    
    -- Update state
    wanderState.state = 'moving'
    wanderState.targetPosition = targetPos
    wanderState.stateChangeTime = GetGameTimer()
    
    -- Make animal walk to target
    TaskGoToCoordAnyMeans(entity, targetX, targetY, targetZ, Config.WanderSpeed or 1.0, 0, false, 786603, 0xbf800000)
    
    if Config.Debug then
        print('^3[WANDER]^7 Animal ' .. animalId .. ' started wandering to ' .. string.format('%.1f, %.1f, %.1f', targetX, targetY, targetZ))
    end
end

-- Stop animal wandering and make it idle
function SpawnManager:StopAnimalWander(animalId, wanderState)
    local entity = wanderState.entity
    
    -- Clear tasks
    ClearPedTasks(entity)
    
    -- Update state
    wanderState.state = 'idle'
    wanderState.targetPosition = nil
    wanderState.stateChangeTime = GetGameTimer()
    
    if Config.Debug then
        print('^2[WANDER]^7 Animal ' .. animalId .. ' stopped wandering (now idle)')
    end
end

-- Despawn an animal
function SpawnManager:DespawnAnimal(animalId)
    local animalInfo = self.entities[animalId]
    if not animalInfo then return end
    
    local entity = animalInfo.entity
    if DoesEntityExist(entity) then
        -- Remove interaction
        exports.ox_target:removeLocalEntity(entity, 'ranch_animal')
        
        -- Fade out effect
        if Config.AnimalFadeIn then
            CreateThread(function()
                for i = 255, 0, -51 do
                    if DoesEntityExist(entity) then
                        SetEntityAlpha(entity, i, false)
                        Wait(50)
                    end
                end
                if DoesEntityExist(entity) then
                    DeletePed(entity)
                end
            end)
        else
            DeletePed(entity)
        end
    end
    
    -- Clean up wander state
    if wanderStates[animalId] then
        wanderStates[animalId].active = false
        wanderStates[animalId] = nil
    end
    
    -- Report despawn to server so it can clear tracking
    TriggerServerEvent('rex-ranch:server:reportDespawn', animalId)
    
    -- Clean up data
    self.entities[animalId] = nil
    
    if Config.Debug then
        print('^1[SPAWN MANAGER]^7 Despawned animal ' .. animalId)
    end
end

-- Get count of pending spawns
function SpawnManager:GetPendingCount()
    local count = 0
    for _ in pairs(self.pending) do
        count = count + 1
    end
    return count
end

-- Clean up stale pending requests
function SpawnManager:CleanupPendingRequests()
    local currentTime = GetGameTimer()
    local timeout = 10000 -- 10 second timeout
    
    for animalId, requestData in pairs(self.pending) do
        if (currentTime - requestData.timestamp) > timeout then
            self.pending[animalId] = nil
            if Config.Debug then
                print('^3[SPAWN MANAGER]^7 Cleaned up stale spawn request for animal ' .. animalId)
            end
        end
    end
end

-- Get animal entity by ID (for other systems)
function SpawnManager:GetEntityById(animalId)
    local animalInfo = self.entities[tostring(animalId)]
    if animalInfo and DoesEntityExist(animalInfo.entity) then
        return animalInfo.entity
    end
    return nil
end

-- Remove specific animal (for selling/deletion)
function SpawnManager:RemoveAnimal(animalId)
    local animalKey = tostring(animalId)
    
    if self.entities[animalKey] then
        self:DespawnAnimal(animalKey)
    end
    
    -- Clean up related states
    followStates[animalKey] = nil
    transportingAnimals[animalKey] = nil
    if wanderStates[animalKey] then
        wanderStates[animalKey].active = false
        wanderStates[animalKey] = nil
    end
    
    -- Remove from cache
    for i, cachedAnimal in ipairs(animalDataCache) do
        if tostring(cachedAnimal.animalid) == animalKey then
            table.remove(animalDataCache, i)
            break
        end
    end
    
    if Config.Debug then
        print('^2[SPAWN MANAGER]^7 Removed animal ' .. animalId .. ' completely')
    end
end

-- Clear all spawned animals
function SpawnManager:ClearAll()
    for animalId in pairs(self.entities) do
        self:DespawnAnimal(animalId)
    end
    self.pending = {}
    
    -- Clean up all wander states
    for animalId in pairs(wanderStates) do
        wanderStates[animalId].active = false
        wanderStates[animalId] = nil
    end
    
    if Config.Debug then
        print('^3[SPAWN MANAGER]^7 Cleared all spawned animals')
    end
end

-- Clean up orphaned animal entities (for startup)
function SpawnManager:CleanupOrphanedEntities()
    if not cache.ped or not DoesEntityExist(cache.ped) then
        return
    end
    
    local playerCoords = GetEntityCoords(cache.ped)
    local cleanedCount = 0
    
    -- Check for nearby animal entities that might be orphaned
    for radius = 10, 200, 25 do
        local nearbyPeds = GetGamePool('CPed')
        
        for _, entity in ipairs(nearbyPeds) do
            if DoesEntityExist(entity) and entity ~= cache.ped then
                local entityCoords = GetEntityCoords(entity)
                local distance = #(playerCoords - entityCoords)
                
                if distance <= radius then
                    local model = GetEntityModel(entity)
                    
                    -- Check if it's a known ranch animal model from Config
                    local isRanchAnimal = false
                    
                    -- Check against models defined in Config.AnimalProducts
                    if Config.AnimalProducts then
                        for animalModel, _ in pairs(Config.AnimalProducts) do
                            if model == GetHashKey(animalModel) then
                                isRanchAnimal = true
                                break
                            end
                        end
                    end
                    
                    -- Fallback check for common ranch animals if Config is not available
                    if not isRanchAnimal then
                        for _, animalModel in pairs({'a_c_bull_01', 'a_c_cow', 'a_c_pig_01', 'a_c_sheep_01', 'a_c_hen_01', 'a_c_rooster_01', 'a_c_goat_01'}) do
                            if model == GetHashKey(animalModel) then
                                isRanchAnimal = true
                                break
                            end
                        end
                    end
                    
                    if isRanchAnimal then
                        -- Check if this entity is tracked by our spawn manager
                        local isTracked = false
                        for _, spawnData in pairs(self.entities) do
                            if spawnData.entity == entity then
                                isTracked = true
                                break
                            end
                        end
                        
                        -- If it's not tracked, it's likely orphaned from a previous session
                        if not isTracked then
                            -- Remove any ox_target interactions
                            exports.ox_target:removeLocalEntity(entity, 'ranch_animal')
                            
                            -- Delete the orphaned entity
                            DeletePed(entity)
                            cleanedCount = cleanedCount + 1
                            
                            if Config.Debug then
                                print('^1[SPAWN MANAGER]^7 Cleaned up orphaned animal entity: ' .. entity .. ' (model: ' .. model .. ')')
                            end
                        end
                    end
                end
            end
        end
    end
    
    if Config.Debug and cleanedCount > 0 then
        print('^3[SPAWN MANAGER]^7 Startup cleanup completed - removed ' .. cleanedCount .. ' orphaned animal entities')
    elseif Config.Debug then
        print('^2[SPAWN MANAGER]^7 Startup cleanup completed - no orphaned entities found')
    end
end

---------------------------------------------
-- Helper Functions
---------------------------------------------
-- Make isPlayerRanchStaff global so ox_target can access it
function isPlayerRanchStaff()
    local PlayerData = RSGCore.Functions.GetPlayerData()
    if not PlayerData or not PlayerData.job then
        return false
    end
    
    local playerjob = PlayerData.job.name
    
    -- All ranch staff levels (0-2) can target animals
    -- Level 0: Trainee Rancher, Level 1: Ranch Hand, Level 2: Ranch Manager
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            return true
        end
    end
    
    return false
end

local function getFreshAnimalData(animalid)
    local targetId = tostring(animalid)
    for _, cachedAnimal in ipairs(animalDataCache) do
        if tostring(cachedAnimal.animalid) == targetId then
            return cachedAnimal
        end
    end
    return nil
end

local function finalizeAnimalMenu(menuOptions, freshData, animal)
    table.insert(menuOptions, {
        title = '─────────────────────────',
        disabled = true
    })
    table.insert(menuOptions, {
        title = locale('animal_actions'),
        description = locale('care_for_animal'),
        icon = 'fa-solid fa-hand-holding-heart',
        event = 'rex-ranch:client:actionsmenu',
        args = { animalid = freshData.animalid, animal = animal },
        arrow = true
    })
    
    lib.registerContext({
        id = 'animal_info_menu',
        title = string.format(locale('ranch_animal_id'), freshData.animalid),
        options = menuOptions
    })
    lib.showContext('animal_info_menu')
end

---------------------------------------------
-- Server Communication Events
---------------------------------------------

-- Player loaded - initialize system
RegisterNetEvent('RSGCore:Client:OnPlayerLoaded', function()
    SpawnManager:Initialize()
    TriggerServerEvent('rex-ranch:server:refreshAnimals')
end)

-- Receive animal data from server
RegisterNetEvent('rex-ranch:client:spawnAnimals', function(animalData)
    -- Check if this is a single animal or a full refresh
    -- Single animals are sent as 1-item arrays after purchase
    if #animalData == 1 then
        -- Single animal - merge with existing cache
        local newAnimal = animalData[1]
        local animalExists = false
        
        -- Check if animal already exists in cache
        for i, cachedAnimal in ipairs(animalDataCache) do
            if cachedAnimal.animalid == newAnimal.animalid then
                animalDataCache[i] = newAnimal
                animalExists = true
                if Config.Debug then
                    print('^3[SPAWN MANAGER]^7 Updated existing animal ' .. newAnimal.animalid .. ' in cache')
                end
                break
            end
        end
        
        -- If it doesn't exist, add it to the cache
        if not animalExists then
            table.insert(animalDataCache, newAnimal)
            if Config.Debug then
                print('^2[SPAWN MANAGER]^7 Added new animal ' .. newAnimal.animalid .. ' to cache')
            end
        end
    else
        -- Full animal list - replace cache
        animalDataCache = animalData
        
        if Config.Debug then
            print('^2[SPAWN MANAGER]^7 Received ' .. #animalData .. ' animals from server (full refresh)')
        end
    end
end)

-- Server grants spawn permission (now includes network ID for sync and isCreator flag)
RegisterNetEvent('rex-ranch:client:spawnAnimalGranted', function(animalId, animalData, networkId, isCreator)
    SpawnManager:SpawnAnimal(animalId, animalData, networkId, isCreator)
end)

-- Server denies spawn request
RegisterNetEvent('rex-ranch:client:spawnAnimalDenied', function(animalId, reason)
    SpawnManager.pending[animalId] = nil
    
    if Config.Debug then
        print('^3[SPAWN MANAGER]^7 Spawn denied for animal ' .. animalId .. ': ' .. (reason or 'unknown'))
    end
end)

-- Force refresh animals from server
RegisterNetEvent('rex-ranch:client:refreshAnimals', function()
    SpawnManager:ClearAll()
    TriggerServerEvent('rex-ranch:server:refreshAnimals')
end)

-- Remove specific animal
RegisterNetEvent('rex-ranch:client:removeAnimal', function(animalid)
    SpawnManager:RemoveAnimal(animalid)
end)

-- Update single animal data
RegisterNetEvent('rex-ranch:client:refreshSingleAnimal', function(animalid, updatedData)
    for i, cachedAnimal in ipairs(animalDataCache) do
        if cachedAnimal.animalid == animalid then
            for key, value in pairs(updatedData) do
                animalDataCache[i][key] = value
            end
            break
        end
    end
end)

-- Update animal status (breeding, etc)
RegisterNetEvent('rex-ranch:client:updateAnimalStatus', function(animalid, updatedData)
    local targetId = tostring(animalid)
    
    for i, cachedAnimal in ipairs(animalDataCache) do
        if tostring(cachedAnimal.animalid) == targetId then
            for key, value in pairs(updatedData) do
                animalDataCache[i][key] = value
            end
            
            if Config.Debug then
                print('^2[SPAWN MANAGER]^7 Updated animal ' .. animalid .. ' status in cache')
            end
            break
        end
    end
    
    lib.hideContext()
end)

-- Set transport mode (prevents despawning)
RegisterNetEvent('rex-ranch:client:setAnimalTransporting', function(animalIds, transporting)
    if type(animalIds) == 'table' then
        for _, animalId in ipairs(animalIds) do
            local key = tostring(animalId)
            transportingAnimals[key] = transporting or nil
        end
    else
        local key = tostring(animalIds)
        transportingAnimals[key] = transporting or nil
    end
    
    if Config.Debug then
        local count = 0
        for _ in pairs(transportingAnimals) do count = count + 1 end
        print('^2[SPAWN MANAGER]^7 Transport mode animals: ' .. count)
    end
end)

---------------------------------------------
-- Animal Interaction Events
---------------------------------------------

-- Animal menu
RegisterNetEvent('rex-ranch:client:animalmenu', function(animal, data)
    if not DoesEntityExist(animal) or not data or not data.animalid then
        lib.notify({ title = locale('error'), description = locale('invalid_animal_data'), type = 'error' })
        return
    end
    
    local freshData = getFreshAnimalData(data.animalid) or data
    
    -- Ensure required fields exist
    freshData.health = freshData.health or 100
    freshData.thirst = freshData.thirst or 100
    freshData.hunger = freshData.hunger or 100
    freshData.age = freshData.age or 0
    freshData.animalid = freshData.animalid or data.animalid
    
    local actualAge = freshData.age or 0
    local genderText = freshData.gender and freshData.gender:gsub("^%l", string.upper) or locale('unknown')
    local isPregnant = (freshData.pregnant == 1 or freshData.pregnant == true)
    local pregnantStatus = isPregnant and locale('pregnant') or locale('not_pregnant')
    
    -- Animal age categories
    local ageText = locale('age_youth')
    if actualAge < 5 then ageText = locale('age_youth') end
    if actualAge >= 5 then ageText = locale('age_adult') end
    
    -- Health status colors
    local healthColorScheme = 'green'
    if freshData.health > 80 then healthColorScheme = 'green' end
    if freshData.health <= 80 and freshData.health > 10 then healthColorScheme = 'yellow' end
    if freshData.health <= 10 then healthColorScheme = 'red' end
    freshData.health = math.min(math.max(freshData.health or 100, 0), 100)
    
    local thirstColorScheme = 'green'
    if freshData.thirst > 80 then thirstColorScheme = 'green' end
    if freshData.thirst <= 80 and freshData.thirst > 10 then thirstColorScheme = 'yellow' end
    if freshData.thirst <= 10 then thirstColorScheme = 'red' end
    freshData.thirst = math.min(math.max(freshData.thirst or 100, 0), 100)
    
    local hungerColorScheme = 'green'
    if freshData.hunger > 80 then hungerColorScheme = 'green' end
    if freshData.hunger <= 80 and freshData.hunger > 10 then hungerColorScheme = 'yellow' end
    if freshData.hunger <= 10 then hungerColorScheme = 'red' end
    freshData.hunger = math.min(math.max(freshData.hunger or 100, 0), 100)
    
    -- Build menu options
    local menuOptions = {
        {
            title = locale('animal_information'),
            description = locale('basic_animal_details'),
            icon = 'fa-solid fa-info-circle',
            disabled = false
        },
        {
            title = string.format(locale('age_title'), ageText),
            description = string.format(locale('days_old'), actualAge),
            icon = 'fa-solid fa-calendar-days',
            disabled = false
        },
        {
            title = string.format(locale('gender_title'), genderText:gsub("^%l", string.upper)),
            description = freshData.gender == 'female' and pregnantStatus or locale('male_animal'),
            icon = freshData.gender == 'male' and 'fa-solid fa-mars' or 'fa-solid fa-venus',
            disabled = false
        },
        {
            title = string.format(locale('health_percent'), math.floor(freshData.health)),
            description = locale('overall_animal_health'),
            progress = freshData.health,
            colorScheme = healthColorScheme,
            icon = 'fa-solid fa-heart-pulse',
            disabled = false
        },
        {
            title = string.format(locale('thirst_percent'), math.floor(freshData.thirst)),
            description = locale('animal_water_needs'),
            progress = freshData.thirst,
            colorScheme = thirstColorScheme,
            icon = 'fa-solid fa-droplet',
            disabled = false
        },
        {
            title = string.format(locale('hunger_percent'), math.floor(freshData.hunger)),
            description = locale('animal_food_needs'),
            progress = freshData.hunger,
            colorScheme = hungerColorScheme,
            icon = 'fa-solid fa-wheat-awn',
            disabled = false
        }
    }
    
    -- Get detailed breeding status from server (includes cooldown information)
    if Config.BreedingEnabled and (freshData.gender == 'female' or freshData.gender == 'male') then
        RSGCore.Functions.TriggerCallback('rex-ranch:server:getBreedingStatus', function(breedingData)
            local breedingOption = nil
        
        if breedingData.status == 'pregnant' then
            -- Get pregnancy progress for pregnant animals
            RSGCore.Functions.TriggerCallback('rex-ranch:server:getPregnancyProgress', function(progressData)
                if progressData and progressData.isPregnant then
                    breedingOption = {
                        title = locale('breeding_pregnant'),
                        description = progressData.description,
                        icon = 'fa-solid fa-baby',
                        progress = progressData.progressPercent,
                        colorScheme = 'blue',
                        disabled = false
                    }
                else
                    breedingOption = {
                        title = locale('breeding_pregnant'),
                        description = locale('expecting_offspring_soon'),
                        icon = 'fa-solid fa-baby',
                        disabled = false
                    }
                end
                
                table.insert(menuOptions, breedingOption)
                
                -- Complete the menu display
                finalizeAnimalMenu(menuOptions, freshData, animal)
            end, freshData.animalid)
            return
        elseif breedingData.status == 'cooldown' then
            breedingOption = {
                title = locale('breeding_cooldown'),
                description = breedingData.message,
                icon = 'fa-solid fa-clock',
                disabled = false
            }
            
            -- Add progress bar for cooldown if we have time remaining info
            if breedingData.timeRemaining and breedingData.timeRemaining > 0 then
                -- Use gender-specific cooldown for progress calculation
                local totalCooldown
                if Config.GenderSpecificCooldowns and freshData.gender then
                    totalCooldown = Config.GenderSpecificCooldowns[freshData.gender]
                end
                
                -- Fallback to default cooldown
                if not totalCooldown or totalCooldown == 0 then
                    totalCooldown = Config.BreedingCooldown or 172800 -- 2 days default
                end
                
                if totalCooldown > 0 then
                    local elapsedTime = totalCooldown - breedingData.timeRemaining
                    local progressPercent = math.max(0, math.min(100, (elapsedTime / totalCooldown) * 100))
                    
                    breedingOption.progress = progressPercent
                    breedingOption.colorScheme = 'orange'
                else
                    -- Fallback if cooldown config is invalid
                    breedingOption.progress = 50
                    breedingOption.colorScheme = 'orange'
                end
            end
        elseif breedingData.status == 'ready' then
            breedingOption = {
                title = locale('breeding_ready'),
                description = breedingData.message,
                icon = freshData.gender == 'male' and 'fa-solid fa-mars' or 'fa-solid fa-venus',
                disabled = false
            }
            
            -- Add breeding partner button for ready animals
            local buttonTitle = locale('find_breeding_partner')
            local buttonDesc = locale('find_breeding_partner_desc')
            
            if freshData.gender == 'male' then
                buttonDesc = locale('find_female_animals')
            elseif freshData.gender == 'female' then
                buttonDesc = locale('find_male_animals')
            end
            
            table.insert(menuOptions, breedingOption)
            table.insert(menuOptions, {
                title = buttonTitle,
                description = buttonDesc,
                icon = 'fa-solid fa-search',
                event = 'rex-ranch:client:findBreedingPartner',
                args = { animalid = freshData.animalid, animal = animal }
            })
            
            -- Complete the menu display
            finalizeAnimalMenu(menuOptions, freshData, animal)
            return
        else
            -- Handle other statuses (disabled, too_young, too_old, requirements_not_met, error)
            local statusTitles = {
                disabled = locale('disabled'),
                too_young = locale('too_young'),
                too_old = locale('too_old'),
                requirements_not_met = locale('not_ready'),
                error = locale('error')
            }
            
            breedingOption = {
                title = string.format(locale('breeding_status_title'), statusTitles[breedingData.status] or locale('unknown')),
                description = breedingData.message,
                icon = 'fa-solid fa-exclamation-circle',
                disabled = false
            }
        end
        
        if breedingOption then
            table.insert(menuOptions, breedingOption)
        end
        
        -- Complete the menu display
        finalizeAnimalMenu(menuOptions, freshData, animal)
    end, freshData.animalid)
else
    -- Animal doesn't qualify for breeding or breeding is disabled
    finalizeAnimalMenu(menuOptions, freshData, animal)
end
end)

-- Animal actions menu
RegisterNetEvent('rex-ranch:client:actionsmenu', function(data)
    local animalid = data.animalid
    local animal = data.animal
    
    local freshData = getFreshAnimalData(animalid)
    if not freshData then
        lib.notify({ title = locale('error'), description = locale('animal_data_not_found'), type = 'error' })
        return
    end
    
    local hungerStatus = freshData.hunger > 80 and locale('well_fed') or freshData.hunger > 50 and locale('hungry') or locale('starving')
    local thirstStatus = freshData.thirst > 80 and locale('hydrated') or freshData.thirst > 50 and locale('thirsty') or locale('dehydrated')
    local followStatus = followStates[animalid] and locale('following') or locale('idle')
    
    lib.registerContext({
        id = 'animal_action_menu',
        title = locale('animal_actions'),
        menu = 'animal_info_menu',
        options = {
            {
                title = string.format(locale('toggle_follow_status'), followStatus),
                description = locale('toggle_follow_desc'),
                icon = followStates[animalid] and 'fa-solid fa-user-check' or 'fa-solid fa-walking',
                event = 'rex-ranch:client:animalfollow',
                args = { animal = animal, animalid = animalid }
            },
            {
                title = '─────────────────────────',
                disabled = true
            },
            {
                title = string.format(locale('feed_animal_status'), hungerStatus),
                description = string.format(locale('requires_item'), RSGCore.Shared.Items[Config.FeedItem].label),
                icon = 'fa-solid fa-wheat-awn',
                event = 'rex-ranch:client:feedAnimal',
                args = { animalid = animalid, animal = animal }
            },
            {
                title = string.format(locale('water_animal_status'), thirstStatus),
                description = string.format(locale('requires_item'), RSGCore.Shared.Items[Config.WaterItem].label),
                icon = 'fa-solid fa-droplet',
                event = 'rex-ranch:client:waterAnimal',
                args = { animalid = animalid, animal = animal }
            },
            {
                title = '─────────────────────────',
                disabled = true
            },
            {
                title = locale('check_products'),
                description = locale('check_products_desc'),
                icon = 'fa-solid fa-gift',
                event = 'rex-ranch:client:checkProducts',
                args = { animalid = animalid, animal = animal }
            },
        }
    })
    lib.showContext('animal_action_menu')
end)

-- Animal follow system
RegisterNetEvent('rex-ranch:client:animalfollow', function(data)
    if not DoesEntityExist(data.animal) or not DoesEntityExist(cache.ped) then
        lib.notify({ title = locale('error'), description = locale('invalid_animal_or_player'), type = 'error' })
        return
    end
    
    if IsPedDeadOrDying(data.animal, true) then
        lib.notify({ title = locale('animal_dead'), description = locale('animal_dead_desc'), type = 'error' })
        return
    end
    
    if followStates[data.animalid] == nil then
        followStates[data.animalid] = false
    end
    
    followStates[data.animalid] = not followStates[data.animalid]
    
    if followStates[data.animalid] then
        local animalOffset = vector3(0.0, 2.0, 0.0)
        ClearPedTasks(data.animal)
        TaskFollowToOffsetOfEntity(data.animal, cache.ped, animalOffset.x, animalOffset.y, animalOffset.z, 1.0, -1, 0.0, 1)
        lib.notify({ title = locale('animal_following'), description = locale('animal_following_desc'), duration = 5000, type = 'info' })
    else
        local currentPos = GetEntityCoords(data.animal)
        local heading = GetEntityHeading(data.animal)
        ClearPedTasks(data.animal)
        TriggerServerEvent('rex-ranch:server:saveAnimalPosition', data.animalid, currentPos.x, currentPos.y, currentPos.z, heading)
        lib.notify({ title = locale('animal_stopped'), description = locale('animal_stopped_desc'), duration = 5000, type = 'info' })
    end
end)

-- Feed animal
RegisterNetEvent('rex-ranch:client:feedAnimal', function(data)
    local animal = data.animal
    local animalid = data.animalid
    
    if not DoesEntityExist(cache.ped) or not DoesEntityExist(animal) then
        lib.notify({ title = locale('error'), description = locale('invalid_player_or_animal'), type = 'error' })
        return
    end
    
    local hasItem = RSGCore.Functions.HasItem('animal_feed', 1)
    if hasItem and not isBusy then
        isBusy = true
        LocalPlayer.state:set('inv_busy', true, true)
        TaskTurnPedToFaceEntity(cache.ped, animal, 2000)
        Wait(1500)
        FreezeEntityPosition(cache.ped, true)
        TaskStartScenarioInPlace(cache.ped, `WORLD_HUMAN_FEED_CHICKEN`, 0, true)
        Wait(10000)
        ClearPedTasksImmediately(cache.ped)
        SetCurrentPedWeapon(cache.ped, `WEAPON_UNARMED`, true)
        FreezeEntityPosition(cache.ped, false)
        TriggerServerEvent('rex-ranch:server:feedAnimal', animalid)
        LocalPlayer.state:set('inv_busy', false, true)
        isBusy = false
    else
        lib.notify({type = 'error', description = locale('need_animal_feed')})
    end
end)

-- Water animal
RegisterNetEvent('rex-ranch:client:waterAnimal', function(data)
    local animal = data.animal
    local animalid = data.animalid
    
    if not DoesEntityExist(cache.ped) or not DoesEntityExist(animal) then
        lib.notify({ title = locale('error'), description = locale('invalid_player_or_animal'), type = 'error' })
        return
    end
    
    local hasItem = RSGCore.Functions.HasItem('water_bucket', 1)
    if hasItem and not isBusy then
        isBusy = true
        LocalPlayer.state:set('inv_busy', true, true)
        TaskTurnPedToFaceEntity(cache.ped, animal, 2000)
        Wait(1500)
        FreezeEntityPosition(cache.ped, true)
        TaskStartScenarioInPlace(cache.ped, `WORLD_HUMAN_BUCKET_POUR_LOW`, 0, true)
        Wait(10000)
        ClearPedTasks(cache.ped)
        SetCurrentPedWeapon(cache.ped, `WEAPON_UNARMED`, true)
        FreezeEntityPosition(cache.ped, false)
        TriggerServerEvent('rex-ranch:server:waterAnimal', animalid)
        LocalPlayer.state:set('inv_busy', false, true)
        isBusy = false
    else
        lib.notify({type = 'error', description = locale('need_water_bucket')})
    end
end)

-- Check products
RegisterNetEvent('rex-ranch:client:checkProducts', function(data)
    local animalid = data.animalid
    local animal = data.animal
    
    if not DoesEntityExist(animal) or not animalid then
        lib.notify({ title = locale('error'), description = locale('invalid_animal'), type = 'error' })
        return
    end
    
    RSGCore.Functions.TriggerCallback('rex-ranch:server:getAnimalProductionStatus', function(productionData)
        if not productionData then
            lib.notify({ title = locale('no_production'), description = locale('animal_no_production'), type = 'info' })
            return
        end
        
        local timeText = ''
        if productionData.hasProduct then
            timeText = locale('ready_to_collect')
        elseif productionData.canProduce then
            local hours = math.floor(productionData.timeUntilNext / 3600)
            local minutes = math.floor((productionData.timeUntilNext % 3600) / 60)
            timeText = string.format(locale('next_production_in'), hours, minutes)
        else
            timeText = locale('animal_needs_better_care')
        end
        
        local options = {
            {
                title = locale('product_information'),
                description = locale('animal_production_details'),
                icon = 'fa-solid fa-info-circle',
                disabled = false
            },
            {
                title = string.format(locale('product_title'), productionData.productName),
                description = string.format(locale('animal_produces'), productionData.productAmount, productionData.productName),
                icon = 'fa-solid fa-box',
                disabled = false
            },
            {
                title = string.format(locale('status_title'), timeText),
                description = productionData.canProduce and locale('animal_meets_production_requirements') or locale('improve_animal_stats'),
                icon = productionData.hasProduct and 'fa-solid fa-check-circle' or 'fa-solid fa-clock',
                disabled = false
            }
        }
        
        if productionData.hasProduct then
            table.insert(options, {
                title = '─────────────────────────',
                disabled = true
            })
            table.insert(options, {
                title = string.format(locale('collect_product'), productionData.productName),
                description = string.format(locale('collect_product_desc'), productionData.productAmount, productionData.productName),
                icon = 'fa-solid fa-hand-holding',
                event = 'rex-ranch:client:collectProduct',
                args = { animalid = animalid, animal = animal }
            })
        end
        
        lib.registerContext({
            id = 'animal_production_menu',
            title = locale('animal_production'),
            menu = 'animal_action_menu',
            options = options
        })
        lib.showContext('animal_production_menu')
    end, animalid)
end)

-- Collect product
RegisterNetEvent('rex-ranch:client:collectProduct', function(data)
    local animal = data.animal
    local animalid = data.animalid
    
    if not DoesEntityExist(cache.ped) or not DoesEntityExist(animal) then
        lib.notify({ title = locale('error'), description = locale('invalid_player_or_animal'), type = 'error' })
        return
    end
    
    if not isBusy then
        isBusy = true
        LocalPlayer.state:set('inv_busy', true, true)
        TaskTurnPedToFaceEntity(cache.ped, animal, 2000)
        Wait(1500)
        FreezeEntityPosition(cache.ped, true)
        TaskStartScenarioInPlace(cache.ped, `WORLD_HUMAN_CROUCH_INSPECT`, 0, true)
        Wait(5000)
        ClearPedTasks(cache.ped)
        SetCurrentPedWeapon(cache.ped, `WEAPON_UNARMED`, true)
        FreezeEntityPosition(cache.ped, false)
        TriggerServerEvent('rex-ranch:server:collectProduct', animalid)
        LocalPlayer.state:set('inv_busy', false, true)
        isBusy = false
    end
end)

---------------------------------------------
-- Export Functions
---------------------------------------------
function GetAnimalEntityById(animalId)
    return SpawnManager:GetEntityById(animalId)
end

exports('GetAnimalEntityById', GetAnimalEntityById)
exports('GetAnimalDataCache', function() return animalDataCache end)

---------------------------------------------
-- Debug Commands
---------------------------------------------
-- Manual cleanup command for troubleshooting
RegisterCommand('cleanupranchanimals', function()
    local Player = RSGCore.Functions.GetPlayerData()
    if not Player or not Player.job then return end
    
    local playerjob = Player.job.name
    local isRanchStaff = false
    
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            isRanchStaff = true
            break
        end
    end
    
    if isRanchStaff then
        lib.notify({ title = locale('ranch_animals'), description = locale('cleaning_orphaned_animals'), type = 'info' })
        
        -- Clear current tracked animals
        SpawnManager:ClearAll()
        
        -- Clean up orphaned entities
        SpawnManager:CleanupOrphanedEntities()
        
        -- Refresh from server
        TriggerServerEvent('rex-ranch:server:refreshAnimals')
        
        lib.notify({ title = locale('ranch_animals'), description = locale('cleanup_completed'), type = 'success' })
    else
        lib.notify({ title = locale('ranch_animals'), description = locale('must_be_ranch_staff_command'), type = 'error' })
    end
end, false)

-- Debug command to test production system
RegisterCommand('testproduction', function(source, args)
    local Player = RSGCore.Functions.GetPlayerData()
    if not Player or not Player.job then return end
    
    local playerjob = Player.job.name
    local isRanchStaff = false
    
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            isRanchStaff = true
            break
        end
    end
    
    if not isRanchStaff then
        lib.notify({ title = locale('error'), description = locale('must_be_ranch_staff_command'), type = 'error' })
        return
    end
    
    local animalid = tonumber(args[1])
    if not animalid then
        lib.notify({ title = locale('usage'), description = locale('usage_testproduction'), type = 'info' })
        return
    end
    
    lib.notify({ title = locale('testing'), description = string.format(locale('testing_production_animal'), animalid), type = 'info' })
    
    RSGCore.Functions.TriggerCallback('rex-ranch:server:getAnimalProductionStatus', function(productionData)
        if Config.Debug then
            print('^3[CLIENT PRODUCTION TEST]^7 Result for animal ' .. animalid .. ':')
            if productionData then
                print('^3[CLIENT PRODUCTION TEST]^7 - Product Name: ' .. tostring(productionData.productName))
                print('^3[CLIENT PRODUCTION TEST]^7 - Product Amount: ' .. tostring(productionData.productAmount))
                print('^3[CLIENT PRODUCTION TEST]^7 - Has Product: ' .. tostring(productionData.hasProduct))
                print('^3[CLIENT PRODUCTION TEST]^7 - Can Produce: ' .. tostring(productionData.canProduce))
                print('^3[CLIENT PRODUCTION TEST]^7 - Time Until Next: ' .. tostring(productionData.timeUntilNext))
            else
                print('^1[CLIENT PRODUCTION TEST]^7 - Result is false/nil')
            end
        end
        
        if not productionData then
            lib.notify({ title = locale('test_result'), description = string.format(locale('no_production_data_animal'), animalid), type = 'error' })
        else
            local status = productionData.hasProduct and locale('ready_to_collect') or
                          productionData.canProduce and locale('can_produce') or locale('cannot_produce')
            lib.notify({ 
                title = locale('test_result'), 
                description = string.format(locale('test_result_desc'), animalid, productionData.productName, status), 
                type = 'success' 
            })
        end
    end, animalid)
end, false)

---------------------------------------------
-- Breeding System Events
---------------------------------------------

-- Find breeding partner (from animal info menu)
RegisterNetEvent('rex-ranch:client:findBreedingPartner', function(data)
    local animalid = data.animalid
    local PlayerData = RSGCore.Functions.GetPlayerData()
    local ranchid = PlayerData.job.name
    
    RSGCore.Functions.TriggerCallback('rex-ranch:server:getAvailableAnimalsForBreeding', function(availableAnimals)
        if not availableAnimals or #availableAnimals == 0 then
            lib.notify({ 
                title = locale('no_partners_available'), 
                description = locale('no_compatible_partners'), 
                type = 'info' 
            })
            return
        end
        
        local options = {
            {
                title = locale('available_breeding_partners'),
                description = string.format(locale('animals_found'), #availableAnimals),
                icon = 'fa-solid fa-list',
                disabled = false
            },
            {
                title = '─────────────────────────',
                disabled = false
            }
        }
        
        for _, partner in ipairs(availableAnimals) do
            local genderIcon = partner.gender == 'male' and 'fa-solid fa-mars' or 'fa-solid fa-venus'
            local healthStatus = partner.health > 80 and locale('health_excellent') or partner.health > 50 and locale('health_good') or locale('health_poor')
            local description = string.format(locale('partner_age_health'), partner.age, healthStatus, math.floor(partner.health))
            description = description .. string.format(locale('partner_distance'), partner.distance)
            
            if not partner.canBreed then
                description = description .. string.format(locale('partner_issue'), partner.breedingIssue)
            end
            
            table.insert(options, {
                title = string.format(locale('partner_title'), partner.gender:gsub("^%l", string.upper), partner.animalid),
                description = description,
                icon = genderIcon,
                metadata = {
                    { label = locale('status'), value = partner.canBreed and locale('ready') or locale('not_ready') },
                    { label = locale('health'), value = string.format(locale('percent_value'), math.floor(partner.health)) },
                    { label = locale('distance'), value = string.format(locale('meters_value'), partner.distance) }
                },
                disabled = not partner.canBreed,
                event = partner.canBreed and 'rex-ranch:client:confirmBreeding' or nil,
                args = partner.canBreed and { 
                    animal1id = animalid, 
                    animal2id = partner.animalid,
                    partner = partner
                } or nil
            })
        end
        
        lib.registerContext({
            id = 'breeding_partner_menu',
            title = locale('select_breeding_partner'),
            menu = 'animal_info_menu',
            options = options
        })
        lib.showContext('breeding_partner_menu')
        
    end, ranchid, animalid)
end)

-- Confirm breeding (from animal info menu)
RegisterNetEvent('rex-ranch:client:confirmBreeding', function(data)
    local animal1id = data.animal1id
    local animal2id = data.animal2id
    local partner = data.partner
    
    local alert = lib.alertDialog({
        header = locale('confirm_breeding'),
        content = string.format(locale('confirm_breeding_content'), animal1id, animal2id),
        centered = true,
        cancel = true
    })
    
    if alert == 'confirm' then
        TriggerServerEvent('rex-ranch:server:startBreeding', animal1id, animal2id)
    end
end)

-- Menu validation debug command
RegisterCommand('validatemenu', function(source, args)
    local Player = RSGCore.Functions.GetPlayerData()
    if not Player or not Player.job then
        lib.notify({ title = locale('error'), description = locale('player_data_not_loaded'), type = 'error' })
        return
    end
    
    local playerjob = Player.job.name
    local isRanchStaff = false
    
    for _, ranchData in pairs(Config.RanchLocations) do
        if playerjob == ranchData.jobaccess then
            isRanchStaff = true
            break
        end
    end
    
    if not isRanchStaff then
        lib.notify({ title = locale('error'), description = locale('must_be_ranch_staff_command'), type = 'error' })
        return
    end
    
    local animalid = tonumber(args[1])
    if not animalid then
        lib.notify({ title = locale('usage'), description = locale('usage_validatemenu'), type = 'info' })
        return
    end
    
    lib.notify({ title = locale('validating'), description = string.format(locale('validating_menu_animal'), animalid), type = 'info' })
    
    local validationResults = {}
    
    -- Check 1: Animal data exists in cache
    local animalData = getFreshAnimalData(animalid)
    if animalData then
        table.insert(validationResults, '✅ Animal data found in cache')
        
        -- Check 2: Required fields exist
        local requiredFields = {'animalid', 'model', 'health', 'hunger', 'thirst', 'age', 'gender'}
        local missingFields = {}
        
        for _, field in ipairs(requiredFields) do
            if not animalData[field] then
                table.insert(missingFields, field)
            end
        end
        
        if #missingFields == 0 then
            table.insert(validationResults, '✅ All required fields present')
        else
            table.insert(validationResults, '❌ Missing fields: ' .. table.concat(missingFields, ', '))
        end
        
        -- Check 3: Model has product config
        if Config.AnimalProducts[animalData.model] then
            table.insert(validationResults, '✅ Product config found for model: ' .. animalData.model)
        else
            table.insert(validationResults, '⚠️ No product config for model: ' .. animalData.model)
        end
        
    else
        table.insert(validationResults, '❌ Animal data not found in cache')
    end
    
    -- Check 4: Entity exists in spawn manager
    local entity = SpawnManager:GetEntityById(animalid)
    if entity and DoesEntityExist(entity) then
        table.insert(validationResults, '✅ Entity exists and spawned')
        
        -- Check 5: ox_target interaction  
        local playerCoords = GetEntityCoords(cache.ped)
        local entityCoords = GetEntityCoords(entity)
        local distance = #(playerCoords - entityCoords)
        
        if distance <= 3.0 then
            table.insert(validationResults, '✅ Entity within interaction range (' .. math.floor(distance * 10) / 10 .. 'm)')
        else
            table.insert(validationResults, '⚠️ Entity outside interaction range (' .. math.floor(distance * 10) / 10 .. 'm > 3m)')
        end
        
    else
        table.insert(validationResults, '❌ Entity not found or not spawned')
    end
    
    -- Check 6: Required items in inventory
    local hasFood = RSGCore.Functions.HasItem('animal_feed', 1)
    local hasWater = RSGCore.Functions.HasItem('water_bucket', 1)
    
    if hasFood then
        table.insert(validationResults, '✅ Has animal_feed for feeding')
    else
        table.insert(validationResults, '⚠️ Missing animal_feed (feeding will fail)')
    end
    
    if hasWater then
        table.insert(validationResults, '✅ Has water_bucket for watering')
    else
        table.insert(validationResults, '⚠️ Missing water_bucket (watering will fail)')
    end
    
    -- Display results
    CreateThread(function()
        for i, result in ipairs(validationResults) do
            lib.notify({ 
                title = string.format(locale('validation_step'), i, #validationResults), 
                description = result,
                type = string.find(result, '✅') and 'success' or string.find(result, '❌') and 'error' or 'info'
            })
            Wait(1500)
        end
        
        local passedChecks = 0
        for _, result in ipairs(validationResults) do
            if string.find(result, '✅') then
                passedChecks = passedChecks + 1
            end
        end
        
        lib.notify({ 
            title = locale('validation_complete'), 
            description = string.format(locale('validation_passed'), passedChecks, #validationResults),
            type = passedChecks == #validationResults and 'success' or 'info'
        })
    end)
end, false)

---------------------------------------------
-- Cleanup
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    SpawnManager:ClearAll()
    transportingAnimals = {}
    followStates = {}
end)

-- Cleanup on resource start to remove orphaned entities
AddEventHandler('onResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    -- Wait a bit for other resources to load
    CreateThread(function()
        Wait(3000)
        
        -- Only cleanup if player is loaded
        if cache.ped and DoesEntityExist(cache.ped) then
            if Config.Debug then
                print('^3[SPAWN MANAGER]^7 Resource restarted - cleaning up orphaned entities')
            end
            
            -- Initialize SpawnManager if not already done
            if not SpawnManager.entities then
                SpawnManager.entities = {}
                SpawnManager.pending = {}
            end
            
            -- Clean up orphaned entities
            SpawnManager:CleanupOrphanedEntities()
        end
    end)
end)

---------------------------------------------
-- Initialize on resource start
---------------------------------------------
CreateThread(function()
    Wait(1000)
    if cache.ped and DoesEntityExist(cache.ped) then
        SpawnManager:Initialize()
    end
end)
