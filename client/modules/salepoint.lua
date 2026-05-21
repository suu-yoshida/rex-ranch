local RSGCore = exports['rsg-core']:GetCoreObject()
local salePointNPCs = {} -- Track spawned sale point NPCs
local salePointBlips = {} -- Track spawned sale point blips
lib.locale()

---------------------------------------------
-- sale point blips
---------------------------------------------
CreateThread(function()
    for i, salePointData in pairs(Config.SalePointLocations) do
        if salePointData.showblip == true then
            local SaleBlip = Citizen.InvokeNative(0x5A039BB0BCA604B6, joaat(salePointData.blipsprite), salePointData.coords.x, salePointData.coords.y, salePointData.coords.z)
            SetBlipSprite(SaleBlip, joaat(salePointData.blipsprite), true)
            SetBlipScale(SaleBlip, salePointData.blipscale)
            Citizen.InvokeNative(0x9CB1A1623062F402, SaleBlip, salePointData.blipname)
            salePointBlips[i] = SaleBlip -- Track the blip for cleanup
        end
    end
end)

---------------------------------------------
-- sale point npcs
---------------------------------------------
-- Function to clean up any existing sale point NPCs (in case of improper restart)
local function CleanupExistingSalePointNPCs()
    -- Get all peds in the world
    local allPeds = GetGamePool('CPed')
    local cleanedCount = 0
    
    for _, ped in ipairs(allPeds) do
        if DoesEntityExist(ped) and ped ~= cache.ped then
            -- Check if this ped is at a sale point location
            local pedCoords = GetEntityCoords(ped)
            for _, salePointData in pairs(Config.SalePointLocations) do
                local npcCoords = vector3(salePointData.npccoords.x, salePointData.npccoords.y, salePointData.npccoords.z)
                local distance = #(pedCoords - npcCoords)
                if distance < 2.0 and GetEntityModel(ped) == salePointData.npcmodel then
                    DeletePed(ped)
                    cleanedCount = cleanedCount + 1
                    break
                end
            end
        end
    end
    
    if Config.Debug and cleanedCount > 0 then
        print('^3[SALEPOINT DEBUG]^7 Cleaned up ' .. cleanedCount .. ' existing sale point NPCs before creating new ones')
    end
end

CreateThread(function()
    -- Clean up any existing NPCs first
    CleanupExistingSalePointNPCs()
    
    -- Wait a moment for cleanup to complete
    Wait(500)
    
    for i, salePointData in pairs(Config.SalePointLocations) do
        lib.requestModel(salePointData.npcmodel, 10000)
        
        local salePointNPC = CreatePed(salePointData.npcmodel, salePointData.npccoords.x, salePointData.npccoords.y, salePointData.npccoords.z - 1, salePointData.npccoords.w, false, true, 0, 0)
        Citizen.InvokeNative(0x283978A15512B2FE, salePointNPC, true)
        SetRandomOutfitVariation(salePointNPC, true)
        SetModelAsNoLongerNeeded(salePointData.npcmodel)
        SetPedCanBeTargetted(salePointNPC, false)
        SetEntityInvincible(salePointNPC, true)
        FreezeEntityPosition(salePointNPC, true)
        SetBlockingOfNonTemporaryEvents(salePointNPC, true)
        
        -- Track the NPC for cleanup
        salePointNPCs[i] = salePointNPC
        
        -- target interaction
        exports.ox_target:addLocalEntity(salePointNPC, {
            {
                name = 'sale_point_npc',
                icon = 'fas fa-hand-paper',
                label = locale('sell_animals'),
                onSelect = function()
                    TriggerEvent('rex-ranch:client:openSaleMenu', salePointData)
                end,
                distance = 3.0
            }
        })
        
        if Config.Debug then
            print('^2[SALEPOINT DEBUG]^7 Created sale point NPC ' .. i .. ' (entity: ' .. salePointNPC .. ') at ' .. salePointData.name)
        end
    end
end)

---------------------------------------------
-- show sale points selector
---------------------------------------------
RegisterNetEvent('rex-ranch:client:showSalePoints', function(data)
    local options = {}
    
    for _, salePointData in pairs(Config.SalePointLocations) do
        table.insert(options, {
            title = salePointData.name,
            description = locale('visit_market_sell_animals'),
            icon = 'fa-solid fa-location-dot',
            onSelect = function()
                TriggerEvent('rex-ranch:client:openSaleMenu', salePointData)
            end,
            arrow = true
        })
    end
    
    lib.registerContext({
        id = 'sale_points_selector',
        title = locale('select_livestock_market'),
        options = options
    })
    lib.showContext('sale_points_selector')
end)

---------------------------------------------
-- open sale menu
---------------------------------------------
RegisterNetEvent('rex-ranch:client:openSaleMenu', function(salePointData)
    local PlayerData = RSGCore.Functions.GetPlayerData()
    local playerjob = PlayerData.job.name
    local joblevel = PlayerData.job.grade and PlayerData.job.grade.level or 0
    
    -- Check if player works at a ranch
    local isRancher = false
    for _, ranchData in pairs(Config.RanchLocations) do
        if ranchData.jobaccess == playerjob then
            isRancher = true
            break
        end
    end
    
    if not isRancher then
        lib.notify({ title = locale('access_denied'), description = locale('must_be_rancher_sell'), type = 'error' })
        return
    end
    
    -- Trainee Ranchers (level 0) cannot sell animals
    if joblevel < 1 then
        lib.notify({ title = locale('insufficient_rank'), description = locale('ranch_hands_managers_sell'), type = 'error' })
        return
    end
    
    -- Get animals available for sale at this location
    RSGCore.Functions.TriggerCallback('rex-ranch:server:getNearbyAnimalsForSale', function(animals)
        if not animals or #animals == 0 then
            if Config.RequireAnimalPresent then
                lib.notify({ title = locale('no_animals_nearby'), description = locale('bring_animals_sale_point'), type = 'inform' })
            else
                lib.notify({ title = locale('no_animals'), description = locale('no_adult_animals_sale'), type = 'inform' })
            end
            return
        end
        
        -- Separate nearby and distant animals
        local nearbyAnimals = {}
        local distantAnimals = {}
        
        for _, animal in ipairs(animals) do
            if animal.isNearby then
                table.insert(nearbyAnimals, animal)
            else
                table.insert(distantAnimals, animal)
            end
        end
        
        -- Create menu options
        local options = {}
        
        -- Add header showing nearby count
        if Config.RequireAnimalPresent then
            table.insert(options, {
                title = string.format(locale('animals_ready_for_sale'), #nearbyAnimals),
                description = string.format(locale('animals_too_far_count'), #distantAnimals, Config.AnimalSaleDistance),
                icon = 'fa-solid fa-info',
                disabled = true
            })
            
            if #nearbyAnimals == 0 and #distantAnimals > 0 then
                table.insert(options, {
                    title = locale('no_animals_at_sale_point'),
                    description = locale('bring_animals_here_then_sell'),
                    icon = 'fa-solid fa-exclamation-triangle',
                    disabled = true
                })
            end
            
            -- Add sell all option if there are nearby animals
            if #nearbyAnimals > 1 then
                local totalValue = 0
                for _, animal in ipairs(nearbyAnimals) do
                    totalValue = totalValue + animal.salePrice
                end
                
                table.insert(options, {
                    title = string.format(locale('sell_all_animals'), #nearbyAnimals),
                    description = string.format(locale('sell_all_nearby_total'), totalValue),
                    icon = 'fa-solid fa-hand-holding-dollar',
                    onSelect = function()
                        TriggerEvent('rex-ranch:client:confirmSellAll', nearbyAnimals, salePointData.name, salePointData.coords)
                    end,
                    arrow = true
                })
            end
            
            table.insert(options, {
                title = '─────────────────────────',
                disabled = true
            })
        else
            -- For non-proximity mode, add sell all option if there are animals
            if #animals > 1 then
                local totalValue = 0
                for _, animal in ipairs(animals) do
                    totalValue = totalValue + animal.salePrice
                end
                
                table.insert(options, {
                    title = string.format(locale('sell_all_animals'), #animals),
                    description = string.format(locale('sell_all_your_total'), totalValue),
                    icon = 'fa-solid fa-hand-holding-dollar',
                    onSelect = function()
                        TriggerEvent('rex-ranch:client:confirmSellAll', animals, salePointData.name, salePointData.coords)
                    end,
                    arrow = true
                })
                
                table.insert(options, {
                    title = '─────────────────────────',
                    disabled = true
                })
            end
        end
        
        -- Add animals (sellable)
        local animalsToShow = nearbyAnimals
        if not Config.RequireAnimalPresent then
            -- When proximity is not required, show all animals as sellable
            animalsToShow = animals
        end
        
        for _, animal in ipairs(animalsToShow) do
            local animalName = GetAnimalDisplayName(animal.model)
            
            -- Health status indicator
            local healthStatus = ''
            if animal.health >= 80 then
                healthStatus = locale('sale_health_healthy')
            elseif animal.health >= 50 then
                healthStatus = locale('sale_health_fair')
            else
                healthStatus = locale('sale_health_poor')
            end
            
            local description = string.format(locale('animal_sale_desc'), animal.age, healthStatus, animal.salePrice)
            if Config.RequireAnimalPresent and animal.distance then
                description = description .. string.format(locale('distance_suffix'), animal.distance)
            end
            
            table.insert(options, {
                title = string.format(locale('animal_sellable_title'), animalName, animal.ageCategory),
                description = description,
                icon = 'fa-solid fa-dollar-sign',
                onSelect = function()
                    TriggerEvent('rex-ranch:client:confirmSale', animal, salePointData.name, salePointData.coords)
                end,
                arrow = true
            })
        end
        
        -- Add distant animals (not sellable) if proximity is required
        if Config.RequireAnimalPresent and #distantAnimals > 0 then
            table.insert(options, {
                title = '─────────────────────────',
                disabled = true
            })
            
            for _, animal in ipairs(distantAnimals) do
                local animalName = GetAnimalDisplayName(animal.model)
                
                local healthStatus = ''
                if animal.health >= 80 then
                    healthStatus = locale('sale_health_healthy')
                elseif animal.health >= 50 then
                    healthStatus = locale('sale_health_fair')
                else
                    healthStatus = locale('sale_health_poor')
                end
                
                table.insert(options, {
                    title = string.format(locale('animal_too_far_title'), animalName, animal.ageCategory),
                    description = string.format(locale('animal_too_far_sale_desc'), animal.distance, Config.AnimalSaleDistance, animal.salePrice),
                    icon = 'fa-solid fa-map-marker-alt',
                    disabled = true
                })
            end
        end
        
        lib.registerContext({
            id = 'sale_point_menu',
            title = salePointData.name,
            options = options
        })
        lib.showContext('sale_point_menu')
        
    end, playerjob, salePointData.coords)
end)

---------------------------------------------
-- helper function to get animal display names
---------------------------------------------
function GetAnimalDisplayName(model)
    local displayNames = {
        ['a_c_bull_01'] = locale('animal_bull'),
        ['a_c_cow'] = locale('animal_cow')
    }
    return displayNames[model] or locale('animal_generic')
end

---------------------------------------------
-- confirm sale
---------------------------------------------
RegisterNetEvent('rex-ranch:client:confirmSale', function(animal, salePointName, salePointCoords)
    local animalName = GetAnimalDisplayName(animal.model)
    
    -- Check if animal is nearby before showing confirmation (only if proximity is required)
    if Config.RequireAnimalPresent and not animal.isNearby then
        lib.notify({ 
            title = locale('animal_too_far'), 
            description = string.format(locale('animal_distance_bring_closer'), animal.distance or locale('unknown')), 
            type = 'error' 
        })
        return
    end
    
    local alert = lib.alertDialog({
        header = locale('confirm_sale'),
        content = string.format(locale('confirm_sale_content'), animal.ageCategory, animalName, animal.salePrice),
        centered = true,
        cancel = true
    })
    
    if alert == 'confirm' then
        TriggerServerEvent('rex-ranch:server:sellAnimal', animal.animalid, animal.salePrice, salePointCoords)
        lib.notify({ title = locale('sale_confirmed'), description = locale('processing_sale'), type = 'inform' })
    end
end)

---------------------------------------------
-- confirm sell all animals
---------------------------------------------
RegisterNetEvent('rex-ranch:client:confirmSellAll', function(animals, salePointName, salePointCoords)
    if not animals or #animals == 0 then
        lib.notify({ title = locale('error'), description = locale('no_animals_to_sell'), type = 'error' })
        return
    end
    
    -- Calculate totals
    local totalValue = 0
    local animalCounts = {}
    
    for _, animal in ipairs(animals) do
        totalValue = totalValue + animal.salePrice
        local animalName = GetAnimalDisplayName(animal.model)
        animalCounts[animalName] = (animalCounts[animalName] or 0) + 1
    end
    
    -- Build summary string
    local summaryParts = {}
    for animalName, count in pairs(animalCounts) do
        if count == 1 then
            table.insert(summaryParts, string.format(locale('one_animal_summary'), animalName))
        else
            table.insert(summaryParts, string.format(locale('many_animals_summary'), count, animalName))
        end
    end
    local summary = table.concat(summaryParts, ', ')
    
    -- Show confirmation dialog
    local alert = lib.alertDialog({
        header = locale('confirm_sell_all_animals'),
        content = string.format(locale('confirm_sell_all_content'), summary, totalValue),
        centered = true,
        cancel = true
    })
    
    if alert == 'confirm' then
        -- Start selling process
        lib.notify({ title = locale('selling_animals'), description = string.format(locale('processing_sale_count'), #animals), type = 'inform' })
        
        
        -- Trigger server event to sell all animals
        TriggerServerEvent('rex-ranch:server:sellAllAnimals', animals, salePointCoords)
    end
end)


---------------------------------------------
-- cleanup on resource stop
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    -- Clean up sale point NPCs
    for i, npc in pairs(salePointNPCs) do
        if DoesEntityExist(npc) then
            exports.ox_target:removeLocalEntity(npc, 'sale_point_npc')
            DeletePed(npc)
        end
        salePointNPCs[i] = nil
    end
    
    -- Clean up sale point blips
    for i, blip in pairs(salePointBlips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
        salePointBlips[i] = nil
    end
end)
