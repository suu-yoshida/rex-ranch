local RSGCore = exports['rsg-core']:GetCoreObject()
local herdingActive = false
local herdedAnimals = {}
local herdingTarget = nil
local herdingThreadId = nil -- Changed from boolean to thread ID
local herdingStartTime = nil
local selectedAnimals = {} -- For individual animal selection
local selectionMode = false -- Whether we're in selection mode
-- Blip tracking removed
lib.locale()

---------------------------------------------
-- herding command/keybind
---------------------------------------------
RegisterCommand('herd', function(source, args, rawCommand)
    if not Config.HerdingEnabled then
        lib.notify({ title = locale('herding_disabled'), description = locale('herding_disabled_desc'), type = 'error' })
        return
    end
    
    local PlayerData = RSGCore.Functions.GetPlayerData()
    if not PlayerData or not PlayerData.job then
        return
    end
    
    -- Check if player works at a ranch
    local isRancher = false
    for _, ranchData in pairs(Config.RanchLocations) do
        if PlayerData.job.name == ranchData.jobaccess then
            isRancher = true
            break
        end
    end
    
    if not isRancher then
        lib.notify({ title = locale('access_denied'), description = locale('must_be_rancher_herding'), type = 'error' })
        return
    end
    
    -- Check if player has required tool (if enabled)
    if Config.RequireHerdingTool then
        local hasItem = RSGCore.Functions.HasItem(Config.HerdingTool, 1)
        if not hasItem then
            lib.notify({ title = locale('missing_tool'), description = string.format(locale('need_tool_herd'), Config.HerdingTool), type = 'error' })
            return
        end
    end
    
    TriggerEvent('rex-ranch:client:openHerdingMenu')
end, false)

---------------------------------------------
-- herding menu
---------------------------------------------
RegisterNetEvent('rex-ranch:client:openHerdingMenu', function()
    -- Debug: Check for nearby animals
    if Config.Debug then
        local nearbyAnimals = GetNearbyAnimals()
        print('^3[HERDING DEBUG]^7 Found ' .. #nearbyAnimals .. ' nearby animals')
        for i, animal in ipairs(nearbyAnimals) do
            print('^3[HERDING DEBUG]^7 Animal ' .. i .. ': ID=' .. tostring(animal.id) .. ', Model=' .. tostring(animal.model) .. ', Distance=' .. tostring(math.floor(animal.distance * 10) / 10) .. 'm')
        end
    end
    
    if herdingActive then
        lib.registerContext({
            id = 'herding_active_menu',
            title = locale('herding_control'),
            options = {
                {
                    title = locale('stop_herding'),
                    description = string.format(locale('stop_herding_desc'), #herdedAnimals),
                    icon = 'fa-solid fa-stop',
                    event = 'rex-ranch:client:stopHerding'
                },
                {
                    title = locale('herding_status'),
                    description = string.format(locale('currently_herding_count'), #herdedAnimals),
                    icon = 'fa-solid fa-info',
                    disabled = true
                }
            }
        })
        lib.showContext('herding_active_menu')
    else
        local options = {
            {
                title = locale('herd_by_distance'),
                description = string.format(locale('herd_by_distance_desc'), Config.HerdingDistance),
                icon = 'fa-solid fa-location-dot',
                event = 'rex-ranch:client:startDistanceHerding'
            },
            {
                title = locale('herd_by_type'),
                description = locale('herd_by_type_desc'),
                icon = 'fa-solid fa-filter',
                event = 'rex-ranch:client:showTypeMenu',
                arrow = true
            }
        }
        
        -- Add individual selection option if enabled
        if Config.IndividualSelectionEnabled then
            table.insert(options, {
                title = locale('select_individual_animals'),
                description = locale('select_individual_animals_desc'),
                icon = 'fa-solid fa-hand-pointer',
                event = 'rex-ranch:client:showIndividualSelectionMenu',
                arrow = true
            })
        end
        
        lib.registerContext({
            id = 'herding_menu',
            title = locale('animal_herding'),
            options = options
        })
        lib.showContext('herding_menu')
    end
end)

---------------------------------------------
-- animal type selection menu
---------------------------------------------
RegisterNetEvent('rex-ranch:client:showTypeMenu', function()
    local nearbyAnimals = GetNearbyAnimals()
    local animalTypes = {}
    local typeCounts = {}
    
    -- Count animals by type
    for _, animalData in pairs(nearbyAnimals) do
        local model = animalData.model
        if not animalTypes[model] then
            animalTypes[model] = true
            typeCounts[model] = 0
        end
        typeCounts[model] = typeCounts[model] + 1
    end
    
    local options = {}
    for model, _ in pairs(animalTypes) do
        local displayName = GetAnimalDisplayName(model)
        table.insert(options, {
            title = string.format(locale('herd_animals_by_name'), displayName),
            description = string.format(locale('animals_nearby_by_name'), typeCounts[model], displayName),
            icon = 'fa-solid fa-paw',
            event = 'rex-ranch:client:startTypeHerding',
            args = { animalType = model }
        })
    end
    
    if #options == 0 then
        table.insert(options, {
            title = locale('no_animals_found'),
            description = locale('no_animals_herding_range'),
            icon = 'fa-solid fa-exclamation-triangle',
            disabled = true
        })
    end
    
    lib.registerContext({
        id = 'herding_type_menu',
        title = locale('select_animal_type'),
        menu = 'herding_menu',
        options = options
    })
    lib.showContext('herding_type_menu')
end)

---------------------------------------------
-- individual animal selection menu
---------------------------------------------
RegisterNetEvent('rex-ranch:client:showIndividualSelectionMenu', function()
    local nearbyAnimals = GetNearbyAnimals()
    
    if #nearbyAnimals == 0 then
        lib.notify({ title = locale('no_animals'), description = locale('no_animals_selection_range'), type = 'error' })
        return
    end
    
    local options = {}
    
    -- Add header option showing current selection
    local selectedCount = 0
    for _ in pairs(selectedAnimals) do
        selectedCount = selectedCount + 1
    end
    
    table.insert(options, {
        title = string.format(locale('selected_animals_count'), selectedCount),
        description = string.format(locale('currently_selected_count'), selectedCount),
        icon = 'fa-solid fa-list-check',
        disabled = true
    })
    
    if selectedCount > 0 then
        table.insert(options, {
            title = locale('start_herding_selected'),
            description = string.format(locale('start_selected_desc'), selectedCount),
            icon = 'fa-solid fa-play',
            event = 'rex-ranch:client:startSelectedHerding'
        })
        
        table.insert(options, {
            title = locale('clear_selection'),
            description = locale('clear_selection_desc'),
            icon = 'fa-solid fa-times',
            event = 'rex-ranch:client:clearAnimalSelection'
        })
        
        table.insert(options, {
            title = '─────────────────────────',
            disabled = true
        })
    end
    
    -- Add individual animals
    for i, animalData in ipairs(nearbyAnimals) do
        local isSelected = selectedAnimals[animalData.id] ~= nil
        local displayName = GetAnimalDisplayName(animalData.model)
        local distance = math.floor(animalData.distance * 10) / 10
        
        local statusIcon = isSelected and 'fa-solid fa-check-square' or 'fa-regular fa-square'
        local statusText = isSelected and locale('selected_bracket') or locale('not_selected_bracket')
        
        -- Build description based on config
        local description = locale('toggle_selection_desc')
        if Config.ShowAnimalDistance then
            description = string.format(locale('distance_prefix_desc'), distance, description)
        end
        
        table.insert(options, {
            title = displayName .. ' #' .. i .. ' ' .. statusText,
            description = description,
            icon = statusIcon,
            event = 'rex-ranch:client:toggleAnimalSelection',
            args = { 
                animalData = animalData,
                animalIndex = i
            }
        })
    end
    
    lib.registerContext({
        id = 'herding_individual_menu',
        title = locale('select_animals_to_herd'),
        menu = 'herding_menu',
        options = options
    })
    lib.showContext('herding_individual_menu')
end)

---------------------------------------------
-- toggle animal selection
---------------------------------------------
RegisterNetEvent('rex-ranch:client:toggleAnimalSelection', function(data)
    local animalData = data.animalData
    local animalId = animalData.id
    
    if selectedAnimals[animalId] then
        -- Deselect animal
        selectedAnimals[animalId] = nil
        lib.notify({ 
            title = locale('animal_deselected'), 
            description = string.format(locale('removed_animal_selection'), GetAnimalDisplayName(animalData.model)),
            type = 'info'
        })
    else
        -- Check if we've reached the maximum
        local selectedCount = 0
        for _ in pairs(selectedAnimals) do
            selectedCount = selectedCount + 1
        end
        
        if selectedCount >= Config.HerdingMaxAnimals then
            lib.notify({ 
                title = locale('selection_full'), 
                description = string.format(locale('max_animals_selected'), Config.HerdingMaxAnimals),
                type = 'error'
            })
            TriggerEvent('rex-ranch:client:showIndividualSelectionMenu') -- Refresh menu
            return
        end
        
        -- Select animal
        selectedAnimals[animalId] = animalData
        lib.notify({ 
            title = locale('animal_selected'), 
            description = string.format(locale('added_animal_selection'), GetAnimalDisplayName(animalData.model)),
            type = 'success'
        })
    end
    
    -- Refresh the menu to show updated selection
    TriggerEvent('rex-ranch:client:showIndividualSelectionMenu')
end)

---------------------------------------------
-- clear animal selection
---------------------------------------------
RegisterNetEvent('rex-ranch:client:clearAnimalSelection', function()
    local clearedCount = 0
    for _ in pairs(selectedAnimals) do
        clearedCount = clearedCount + 1
    end
    
    selectedAnimals = {}
    
    lib.notify({ 
        title = locale('selection_cleared'), 
        description = string.format(locale('removed_animals_selection_count'), clearedCount),
        type = 'info'
    })
    
    -- Refresh the menu
    TriggerEvent('rex-ranch:client:showIndividualSelectionMenu')
end)

---------------------------------------------
-- start herding selected animals
---------------------------------------------
RegisterNetEvent('rex-ranch:client:startSelectedHerding', function()
    if herdingActive then
        lib.notify({ title = locale('already_herding'), description = locale('stop_current_herding_first'), type = 'error' })
        return
    end
    
    local selectedCount = 0
    local selectedList = {}
    for animalId, animalData in pairs(selectedAnimals) do
        -- Verify animal still exists and is nearby
        if DoesEntityExist(animalData.entity) then
            local playerPos = GetEntityCoords(cache.ped)
            local animalPos = GetEntityCoords(animalData.entity)
            local distance = #(playerPos - animalPos)
            
            if distance <= Config.HerdingDistance * Config.SelectionRangeMultiplier then
                table.insert(selectedList, animalData)
                selectedCount = selectedCount + 1
            end
        end
    end
    
    if selectedCount == 0 then
        lib.notify({ title = locale('no_valid_animals'), description = locale('no_selected_animals_available'), type = 'error' })
        selectedAnimals = {} -- Clear invalid selections
        return
    end
    
    -- Clear selection after starting herding
    selectedAnimals = {}
    
    StartHerding(selectedList, 'selected')
end)

---------------------------------------------
-- start distance-based herding
---------------------------------------------
RegisterNetEvent('rex-ranch:client:startDistanceHerding', function()
    if herdingActive then
        lib.notify({ title = locale('already_herding'), description = locale('stop_current_herding_first'), type = 'error' })
        return
    end
    
    local nearbyAnimals = GetNearbyAnimals()
    if #nearbyAnimals == 0 then
        lib.notify({ title = locale('no_animals'), description = locale('no_animals_herding_distance'), type = 'error' })
        return
    end
    
    if #nearbyAnimals > Config.HerdingMaxAnimals then
        lib.notify({ title = locale('too_many_animals'), description = string.format(locale('found_animals_max'), #nearbyAnimals, Config.HerdingMaxAnimals), type = 'error' })
        return
    end
    
    StartHerding(nearbyAnimals, 'distance')
end)

---------------------------------------------
-- start type-based herding
---------------------------------------------
RegisterNetEvent('rex-ranch:client:startTypeHerding', function(data)
    if herdingActive then
        lib.notify({ title = locale('already_herding'), description = locale('stop_current_herding_first'), type = 'error' })
        return
    end
    
    local nearbyAnimals = GetNearbyAnimals()
    local filteredAnimals = {}
    
    for _, animalData in pairs(nearbyAnimals) do
        if animalData.model == data.animalType then
            table.insert(filteredAnimals, animalData)
        end
    end
    
    if #filteredAnimals == 0 then
        lib.notify({ title = locale('no_animals'), description = locale('no_animals_type_nearby'), type = 'error' })
        return
    end
    
    if #filteredAnimals > Config.HerdingMaxAnimals then
        lib.notify({ title = locale('too_many_animals'), description = string.format(locale('found_animals_max'), #filteredAnimals, Config.HerdingMaxAnimals), type = 'error' })
        return
    end
    
    StartHerding(filteredAnimals, 'type')
end)

---------------------------------------------
-- stop herding
---------------------------------------------
RegisterNetEvent('rex-ranch:client:stopHerding', function()
    if not herdingActive then return end
    
    herdingActive = false
    
    -- Stop herding thread
    if herdingThreadId then
        herdingThreadId = nil
    end
    
    -- Collect animal IDs and clear tasks
    local animalIds = {}
    for animalId, animalInfo in pairs(herdedAnimals) do
        table.insert(animalIds, animalId)
        if DoesEntityExist(animalInfo.entity) then
            ClearPedTasks(animalInfo.entity)
            local pos = GetEntityCoords(animalInfo.entity)
            local heading = GetEntityHeading(animalInfo.entity)
            TriggerServerEvent('rex-ranch:server:saveAnimalPosition', animalId, pos.x, pos.y, pos.z, heading)
        end
    end
    
    -- Disable transport mode
    if Config.TransportMode then
        TriggerEvent('rex-ranch:client:setAnimalTransporting', animalIds, false)
        if Config.Debug then
            print('^2[HERDING DEBUG]^7 Disabled transport mode for ' .. #animalIds .. ' animals')
        end
    end
    
    -- Blip removal no longer needed
    
    local animalCount = #herdedAnimals
    herdedAnimals = {}
    herdingTarget = nil
    herdingStartTime = nil
    
    -- Clear any pending selections
    selectedAnimals = {}
    
    lib.notify({ 
        title = locale('herding_stopped'), 
        description = string.format(locale('released_animals_herding'), animalCount), 
        type = 'success' 
    })
end)

---------------------------------------------
-- core herding functions
---------------------------------------------
function GetNearbyAnimals()
    local playerPos = GetEntityCoords(cache.ped)
    local nearbyAnimals = {}
    
    -- Try to get animal data cache, fall back to entity scanning if not available
    local animalDataCache = nil
    local success, result = pcall(function()
        return exports['rex-ranch']:GetAnimalDataCache()
    end)
    
    if success and result then
        animalDataCache = result
    end
    
    -- Method 1: Use animal data cache (preferred)
    if animalDataCache and type(animalDataCache) == 'table' then
        if Config.Debug then
            print('^3[HERDING DEBUG]^7 Using animal data cache method, found ' .. #animalDataCache .. ' animals in cache')
        end
        for i, animalData in ipairs(animalDataCache) do
            if Config.Debug then
                print('^3[HERDING DEBUG]^7 Checking animal ' .. i .. ': ID=' .. tostring(animalData.animalid or 'nil') .. ', Model=' .. tostring(animalData.model or 'nil'))
            end
            
            if animalData and animalData.pos_x and animalData.pos_y and animalData.pos_z and animalData.animalid then
                local animalPos = vector3(animalData.pos_x, animalData.pos_y, animalData.pos_z)
                local distance = #(playerPos - animalPos)
                
                if Config.Debug then
                    print('^3[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' DB position: ' .. tostring(animalPos) .. ', Distance: ' .. tostring(math.floor(distance * 10) / 10) .. 'm')
                end
                
                if distance <= Config.HerdingDistance then
                    if Config.Debug then
                        print('^3[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' is within herding distance, checking for spawned entity')
                    end
                    
                    -- Try to get the actual spawned entity
                    local animalEntity = nil
                    pcall(function()
                        animalEntity = exports['rex-ranch']:GetAnimalEntityById(animalData.animalid)
                    end)
                    
                    if Config.Debug then
                        print('^3[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' entity: ' .. tostring(animalEntity) .. ', exists: ' .. tostring(animalEntity and DoesEntityExist(animalEntity)))
                    end
                    
                    if animalEntity and DoesEntityExist(animalEntity) then
                        -- Update position to current entity position (more accurate)
                        animalPos = GetEntityCoords(animalEntity)
                        distance = #(playerPos - animalPos)
                        
                        if Config.Debug then
                            print('^3[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' actual position: ' .. tostring(animalPos) .. ', Distance: ' .. tostring(math.floor(distance * 10) / 10) .. 'm')
                        end
                        
                        if distance <= Config.HerdingDistance then
                            table.insert(nearbyAnimals, {
                                id = animalData.animalid,
                                entity = animalEntity,
                                model = animalData.model,
                                position = animalPos,
                                distance = distance
                            })
                            
                            if Config.Debug then
                                print('^2[HERDING DEBUG]^7 Added animal ' .. animalData.animalid .. ' to nearby list')
                            end
                        else
                            if Config.Debug then
                                print('^1[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' entity too far: ' .. tostring(math.floor(distance * 10) / 10) .. 'm')
                            end
                        end
                    else
                        if Config.Debug then
                            print('^1[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' has no spawned entity or entity does not exist')
                        end
                    end
                else
                    if Config.Debug then
                        print('^1[HERDING DEBUG]^7 Animal ' .. animalData.animalid .. ' DB position too far: ' .. tostring(math.floor(distance * 10) / 10) .. 'm (max: ' .. Config.HerdingDistance .. 'm)')
                    end
                end
            else
                if Config.Debug then
                    print('^1[HERDING DEBUG]^7 Animal ' .. i .. ' has invalid data: pos_x=' .. tostring(animalData and animalData.pos_x) .. ', pos_y=' .. tostring(animalData and animalData.pos_y) .. ', pos_z=' .. tostring(animalData and animalData.pos_z) .. ', animalid=' .. tostring(animalData and animalData.animalid))
                end
            end
        end
    else
        -- Method 2: Fallback to entity scanning
        if Config.Debug then
            print('^3[HERDING DEBUG]^7 Using fallback entity scanning method')
        end
        local nearbyEntities = GetGamePool('CPed')
        
        for _, entity in ipairs(nearbyEntities) do
            if DoesEntityExist(entity) and entity ~= cache.ped then
                local entityModel = GetEntityModel(entity)
                local modelName = nil
                
                -- Check if this is a ranch animal by model
                if Config.AnimalProducts then
                    for model, _ in pairs(Config.AnimalProducts) do
                        if GetHashKey(model) == entityModel then
                            modelName = model
                            break
                        end
                    end
                end
                
                -- Also check for models that might not be in products config
                if not modelName then
                    local commonModels = {
                        [GetHashKey('a_c_cow')] = 'a_c_cow',
                        [GetHashKey('a_c_bull_01')] = 'a_c_bull_01'
                    }
                    modelName = commonModels[entityModel]
                end
                
                if modelName then
                    local animalPos = GetEntityCoords(entity)
                    local distance = #(playerPos - animalPos)
                    
                    if distance <= Config.HerdingDistance then
                        -- Use entity handle as ID for fallback method
                        table.insert(nearbyAnimals, {
                            id = entity,
                            entity = entity,
                            model = modelName,
                            position = animalPos,
                            distance = distance
                        })
                    end
                end
            end
        end
    end
    
    return nearbyAnimals
end

function GetAnimalDisplayName(model)
    local displayNames = {
        ['a_c_cow'] = locale('animal_cow'),
        ['a_c_bull_01'] = locale('animal_bull')
    }
    return displayNames[model] or locale('animal_generic')
end

---------------------------------------------
-- blip functionality removed
---------------------------------------------

function StartHerding(animals, herdType)
    herdingActive = true
    herdingStartTime = GetGameTimer()
    herdedAnimals = {}
    
    -- Convert animals to herded format
    local animalIds = {}
    for _, animalData in pairs(animals) do
        herdedAnimals[animalData.id] = {
            entity = animalData.entity,
            model = animalData.model,
            originalPos = animalData.position
        }
        table.insert(animalIds, animalData.id)
    end
    
    -- Enable transport mode to prevent despawning
    if Config.TransportMode then
        TriggerEvent('rex-ranch:client:setAnimalTransporting', animalIds, true)
        if Config.Debug then
            print('^2[HERDING DEBUG]^7 Enabled transport mode for ' .. #animalIds .. ' animals')
        end
    end
    
    local animalCount = #animals
    local typeText
    if herdType == 'distance' then
        typeText = locale('herd_type_nearby')
    elseif herdType == 'selected' then
        typeText = locale('herd_type_selected')
    else
        typeText = locale('herd_type_selected_type')
    end
    
    lib.notify({ 
        title = locale('herding_started'), 
        description = string.format(locale('now_herding_animals'), animalCount, typeText), 
        type = 'success',
        duration = 5000
    })
    
    -- Start herding control thread
    herdingThreadId = CreateThread(function()
        local threadActive = true
        while herdingActive and threadActive do
            Wait(100)
            
            -- Check if we should still be running (thread wasn't cancelled)
            if not herdingActive or not herdingThreadId then
                threadActive = false
                break
            end
            
            -- Check timeout
            if herdingStartTime and (GetGameTimer() - herdingStartTime) > (Config.HerdingTimeout * 1000) then
                TriggerEvent('rex-ranch:client:stopHerding')
                lib.notify({ title = locale('herding_timeout'), description = locale('herding_timeout_desc'), type = 'info' })
                break
            end
            
            -- Update animal following
            UpdateHerdingMovement()
        end
        
        -- Thread cleanup
        if Config.Debug then
            print('^3[HERDING DEBUG]^7 Herding thread ended')
        end
    end)
    
    -- Show herding instructions
    lib.notify({
        title = locale('herding_active'),
        description = locale('herding_active_desc'),
        type = 'info',
        duration = 8000
    })
end

function UpdateHerdingMovement()
    if not herdingActive or not cache.ped then return end
    
    local playerPos = GetEntityCoords(cache.ped)
    local playerSpeed = GetEntitySpeed(cache.ped)
    
    -- Update animal movement
    local animalIndex = 0
    for animalId, animalInfo in pairs(herdedAnimals) do
        if DoesEntityExist(animalInfo.entity) and not IsPedDeadOrDying(animalInfo.entity, true) then
            animalIndex = animalIndex + 1
            
            -- Only move animals if player is moving
            if playerSpeed > 0.1 then
                -- Calculate follow position (spread animals around player)
                local angle = (animalIndex * 60) * (math.pi / 180) -- Convert to radians
                local followDistance = Config.HerdingFollowDistance + (animalIndex * 0.5)
                local followPos = vector3(
                    playerPos.x + math.cos(angle) * followDistance,
                    playerPos.y + math.sin(angle) * followDistance,
                    playerPos.z
                )
                
                -- Set animal to follow to position
                ClearPedTasks(animalInfo.entity)
                TaskGoToCoordAnyMeans(animalInfo.entity, followPos.x, followPos.y, followPos.z, Config.HerdingSpeed, 0, false, 786603, 0xbf800000)
            end
        else
            -- Remove dead or non-existent animals
            herdedAnimals[animalId] = nil
        end
    end
    
    -- Check if all animals are gone
    local remainingAnimals = 0
    for _ in pairs(herdedAnimals) do
        remainingAnimals = remainingAnimals + 1
    end
    
    if remainingAnimals == 0 then
        TriggerEvent('rex-ranch:client:stopHerding')
        lib.notify({ title = locale('no_animals_left'), description = locale('all_herded_animals_gone'), type = 'info' })
    end
end

---------------------------------------------
-- cleanup on resource stop
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    if herdingActive then
        TriggerEvent('rex-ranch:client:stopHerding')
    end
    -- Clear any pending selections
    selectedAnimals = {}
end)

-- Additional selection management commands
RegisterCommand('herdselectstatus', function()
    if not Config.HerdingEnabled or not Config.IndividualSelectionEnabled then return end
    
    local selectedCount = 0
    for _ in pairs(selectedAnimals) do
        selectedCount = selectedCount + 1
    end
    
    if selectedCount == 0 then
        lib.notify({ title = locale('no_selection'), description = locale('no_animals_selected_herding'), type = 'info' })
    else
        lib.notify({ 
            title = locale('selection_status'), 
            description = string.format(locale('selected_animals_herding'), selectedCount),
            type = 'info',
            duration = 3000
        })
    end
end, false)

RegisterCommand('herdclear', function()
    if not Config.HerdingEnabled or not Config.IndividualSelectionEnabled then return end
    
    local clearedCount = 0
    for _ in pairs(selectedAnimals) do
        clearedCount = clearedCount + 1
    end
    
    if clearedCount > 0 then
        selectedAnimals = {}
        lib.notify({ 
            title = locale('selection_cleared'), 
            description = string.format(locale('cleared_selected_animals'), clearedCount),
            type = 'success'
        })
    else
        lib.notify({ title = locale('no_selection'), description = locale('no_animals_were_selected'), type = 'info' })
    end
end, false)

-- herdblipstatus command removed

-- Note: Use /herd command to access herding menu
-- RegisterKeyMapping is not available in RedM
