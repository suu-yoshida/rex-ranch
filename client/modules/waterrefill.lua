local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- water refill system
---------------------------------------------
local fillWaterBucketActive = false
local fillWaterBucketCooldown = 0

-- Set up targeting for water props to fill water bucket
local function setupWaterPropTargets()
    if not Config.WaterProps or #Config.WaterProps == 0 then
        return
    end

    exports.ox_target:addModel(Config.WaterProps, {
        label = locale('fill_water_bucket'),
        icon = 'fa-solid fa-bucket',
        distance = 1.5,
        canInteract = function(entity, distance, coords, name, bone)
            -- Check if player has an empty water bucket
            local hasWaterBucket = RSGCore.Functions.HasItem('water_bucket', 1)
            if not hasWaterBucket then
                return false
            end

            -- Check if the bucket has zero uses (is empty)
            local Player = RSGCore.Functions.GetPlayerData()
            if not Player or not Player.items then
                return false
            end

            for _, item in pairs(Player.items) do
                if item and item.name == 'water_bucket' then
                    local uses = (item.info and item.info.uses) or 0
                    return uses == 0 -- Only allow interaction if bucket is empty
                end
            end

            return false
        end,
        onSelect = function(data)
            -- Prevent spam and overlapping fill animations
            if fillWaterBucketActive then
                lib.notify({type = 'error', description = locale('already_filling_bucket')})
                return
            end

            if fillWaterBucketCooldown > GetGameTimer() then
                lib.notify({type = 'error', description = locale('filling_bucket_too_quickly')})
                return
            end

            -- Check bucket uses before playing animation
            local Player = RSGCore.Functions.GetPlayerData()
            if not Player or not Player.items then
                return
            end

            local bucketUses = 0
            for _, item in pairs(Player.items) do
                if item and item.name == 'water_bucket' then
                    bucketUses = (item.info and item.info.uses) or 0
                    break
                end
            end

            -- If bucket is not empty, show notification instead of playing animation
            if bucketUses > 0 then
                lib.notify({type = 'error', description = locale('bucket_not_empty_use_first')})
                return
            end

            fillWaterBucketActive = true
            fillWaterBucketCooldown = GetGameTimer() + 2000 -- 2 second cooldown between fills

            -- Play the bucket fill animation
            local ped = cache.ped
            FreezeEntityPosition(ped, true)
            TaskStartScenarioInPlace(ped, `WORLD_HUMAN_BUCKET_POUR_LOW`, 0, true)

            -- Animation duration (roughly 3 seconds for pouring water)
            Wait(3000)

            -- Clear animation and unfreeze
            ClearPedTasks(ped)
            FreezeEntityPosition(ped, false)

            -- Trigger server event to actually fill the bucket
            TriggerServerEvent('rex-ranch:server:fillWaterBucket')

            fillWaterBucketActive = false
        end
    })

    if Config.Debug then
        print('^2[WATER REFILL]^7 Water prop targets set up successfully')
    end
end

-- Initialize on client start
CreateThread(function()
    -- Wait a bit for ox_target to be available
    Wait(500)
    setupWaterPropTargets()
end)
