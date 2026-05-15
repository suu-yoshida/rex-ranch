local RSGCore = exports['rsg-core']:GetCoreObject()
local buyPointNPCs = {} -- Track spawned buy point NPCs
local buyPointBlips = {} -- Track spawned buy point blips
lib.locale()

---------------------------------------------
-- buy point blips
---------------------------------------------
CreateThread(function()
    for i, buyPointData in pairs(Config.BuyPointLocations) do
        if buyPointData.showblip == true then
            local BuyBlip = Citizen.InvokeNative(0x5A039BB0BCA604B6, joaat(buyPointData.blipsprite), buyPointData.coords.x, buyPointData.coords.y, buyPointData.coords.z)
            SetBlipSprite(BuyBlip, joaat(buyPointData.blipsprite), true)
            SetBlipScale(BuyBlip, buyPointData.blipscale)
            Citizen.InvokeNative(0x9CB1A1623062F402, BuyBlip, buyPointData.blipname)
            buyPointBlips[i] = BuyBlip -- Track the blip for cleanup
        end
    end
end)

---------------------------------------------
-- buy point npcs
---------------------------------------------
-- Function to clean up any existing buy point NPCs (in case of improper restart)
local function CleanupExistingBuyPointNPCs()
    -- Get all peds in the world
    local allPeds = GetGamePool('CPed')
    local cleanedCount = 0
    
    for _, ped in ipairs(allPeds) do
        if DoesEntityExist(ped) and ped ~= cache.ped then
            -- Check if this ped is at a buy point location
            local pedCoords = GetEntityCoords(ped)
            for _, buyPointData in pairs(Config.BuyPointLocations) do
                local npcCoords = vector3(buyPointData.npccoords.x, buyPointData.npccoords.y, buyPointData.npccoords.z)
                local distance = #(pedCoords - npcCoords)
                if distance < 2.0 and GetEntityModel(ped) == buyPointData.npcmodel then
                    DeletePed(ped)
                    cleanedCount = cleanedCount + 1
                    break
                end
            end
        end
    end
    
    if Config.Debug and cleanedCount > 0 then
        print('^3[BUYPOINT DEBUG]^7 Cleaned up ' .. cleanedCount .. ' existing buy point NPCs before creating new ones')
    end
end

CreateThread(function()
    -- Clean up any existing NPCs first
    CleanupExistingBuyPointNPCs()
    
    -- Wait a moment for cleanup to complete
    Wait(500)
    
    for i, buyPointData in pairs(Config.BuyPointLocations) do
        lib.requestModel(buyPointData.npcmodel, 10000)
        
        local buyPointNPC = CreatePed(buyPointData.npcmodel, buyPointData.npccoords.x, buyPointData.npccoords.y, buyPointData.npccoords.z - 1, buyPointData.npccoords.w, false, true, 0, 0)
        Citizen.InvokeNative(0x283978A15512B2FE, buyPointNPC, true)
        SetRandomOutfitVariation(buyPointNPC, true)
        SetModelAsNoLongerNeeded(buyPointData.npcmodel)
        SetPedCanBeTargetted(buyPointNPC, false)
        SetEntityInvincible(buyPointNPC, true)
        FreezeEntityPosition(buyPointNPC, true)
        SetBlockingOfNonTemporaryEvents(buyPointNPC, true)
        
        -- Track the NPC for cleanup
        buyPointNPCs[i] = buyPointNPC
        
        -- target interaction
        exports.ox_target:addLocalEntity(buyPointNPC, {
            {
                name = 'buy_point_npc',
                icon = 'fas fa-shopping-cart',
                label = 'Buy Animals',
                onSelect = function()
                    TriggerEvent('rex-ranch:client:openBuyMenu', buyPointData)
                end,
                distance = 3.0
            }
        })
        
        if Config.Debug then
            print('^2[BUYPOINT DEBUG]^7 Created buy point NPC ' .. i .. ' (entity: ' .. buyPointNPC .. ') at ' .. buyPointData.name)
        end
    end
end)

---------------------------------------------
-- open buy menu
---------------------------------------------
RegisterNetEvent('rex-ranch:client:openBuyMenu', function(buyPointData)
    local PlayerData = RSGCore.Functions.GetPlayerData()
    local playerjob = PlayerData.job.name
    
    -- Check if player works at a ranch
    local playerRanchData = nil
    local isRancher = false
    for _, ranchData in pairs(Config.RanchLocations) do
        if ranchData.jobaccess == playerjob then
            isRancher = true
            playerRanchData = ranchData
            break
        end
    end
    
    if not isRancher then
        lib.notify({ title = 'Access Denied', description = 'You must be a rancher to buy animals!', type = 'error' })
        return
    end
    
    -- Check current animal count
    RSGCore.Functions.TriggerCallback('rex-ranch:server:countanimals', function(animalCount)
        local options = {}
        
        -- Header showing capacity
        table.insert(options, {
            title = 'Ranch Capacity: ' .. animalCount .. '/' .. Config.MaxRanchAnimals,
            description = 'Current animals at ' .. playerRanchData.name,
            icon = 'fa-solid fa-info',
            disabled = true
        })
        
        if animalCount >= Config.MaxRanchAnimals then
            table.insert(options, {
                title = 'Ranch Full',
                description = 'You have reached the maximum number of animals for your ranch',
                icon = 'fa-solid fa-exclamation-triangle',
                disabled = true
            })
        else
            table.insert(options, {
                title = '─────────────────────────',
                disabled = true
            })
            
            -- Available animals to buy
            local availableSlots = Config.MaxRanchAnimals - animalCount

            -- Bull option
            table.insert(options, {
                title = '🐂 Buy Bull',
                description = 'Price: $' .. Config.BullBuyPrice .. ' | Strong breeding bull for cattle production',
                icon = 'fa-solid fa-dollar-sign',
                onSelect = function()
                    TriggerEvent('rex-ranch:client:confirmBuyAnimal', {
                        animalType = 'a_c_bull_01',
                        animalName = 'Bull',
                        price = Config.BullBuyPrice,
                        ranchData = playerRanchData,
                        buyPointData = buyPointData
                    })
                end,
                arrow = true
            })

            -- Cow option
            table.insert(options, {
                title = '🐄 Buy Cow',
                description = 'Price: $' .. Config.CowBuyPrice .. ' | Young cow ready for raising',
                icon = 'fa-solid fa-dollar-sign',
                onSelect = function()
                    TriggerEvent('rex-ranch:client:confirmBuyAnimal', {
                        animalType = 'a_c_cow',
                        animalName = 'Cow',
                        price = Config.CowBuyPrice,
                        ranchData = playerRanchData,
                        buyPointData = buyPointData
                    })
                end,
                arrow = true
            })

            table.insert(options, {
                title = '─────────────────────────',
                disabled = true
            })
            
            table.insert(options, {
                title = 'Available Slots: ' .. availableSlots,
                description = 'You can purchase up to ' .. availableSlots .. ' more animals',
                icon = 'fa-solid fa-calculator',
                disabled = true
            })
        end
        
        lib.registerContext({
            id = 'buy_point_menu',
            title = buyPointData.name,
            options = options
        })
        lib.showContext('buy_point_menu')
        
    end, playerRanchData.ranchid)
end)

---------------------------------------------
-- confirm animal purchase
---------------------------------------------
RegisterNetEvent('rex-ranch:client:confirmBuyAnimal', function(data)
    local PlayerData = RSGCore.Functions.GetPlayerData()
    local playerMoney = PlayerData.money.cash
    
    -- Check if player has enough money
    if playerMoney < data.price then
        lib.notify({ 
            title = 'Insufficient Funds', 
            description = 'You need $' .. data.price .. ' but only have $' .. playerMoney, 
            type = 'error' 
        })
        return
    end
    
    -- Show confirmation dialog
    local alert = lib.alertDialog({
        header = 'Confirm Purchase',
        content = 'Are you sure you want to buy this ' .. data.animalName .. ' for $' .. data.price .. '? \n The animal will be available for pickup near the ' .. data.buyPointData.name .. '.',
        centered = true,
        cancel = true
    })
    
    if alert == 'confirm' then
        -- Process the purchase
        lib.notify({ title = 'Processing Purchase', description = 'Buying ' .. data.animalName .. '...', type = 'inform' })
        
        TriggerServerEvent('rex-ranch:server:buyAnimal', {
            animalType = data.animalType,
            animalName = data.animalName,
            price = data.price,
            ranchid = data.ranchData.ranchid,
            spawnpoint = data.buyPointData.spawnpoint,
            buyPointName = data.buyPointData.name
        })
    end
end)

---------------------------------------------
-- cleanup on resource stop
---------------------------------------------
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    -- Clean up buy point NPCs
    for i, npc in pairs(buyPointNPCs) do
        if DoesEntityExist(npc) then
            exports.ox_target:removeLocalEntity(npc, 'buy_point_npc')
            DeletePed(npc)
            if Config.Debug then
                print('^1[BUYPOINT DEBUG]^7 Cleaned up buy point NPC ' .. i .. ' (entity: ' .. npc .. ')')
            end
        end
        buyPointNPCs[i] = nil
    end
    
    -- Clean up buy point blips
    for i, blip in pairs(buyPointBlips) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
            if Config.Debug then
                print('^1[BUYPOINT DEBUG]^7 Cleaned up buy point blip ' .. i .. ' (blip: ' .. blip .. ')')
            end
        end
        buyPointBlips[i] = nil
    end
    
    if Config.Debug then
        print('^2[BUYPOINT DEBUG]^7 All buy point NPCs and blips cleaned up')
    end
end)
