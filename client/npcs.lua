local RSGCore = exports['rsg-core']:GetCoreObject()
local spawnedPeds = {}
lib.locale()

CreateThread(function()
    while true do
        Wait(500)
        for k,npcData in pairs(Config.RanchLocations) do
            local playerCoords = GetEntityCoords(cache.ped)
            local npcCoords = vector3(npcData.npccoords.x, npcData.npccoords.y, npcData.npccoords.z)
            local distance = #(playerCoords - npcCoords)
            if distance < Config.DistanceSpawn and not spawnedPeds[k] then
                local spawnedPed = NearPed(npcData)
                spawnedPeds[k] = { spawnedPed = spawnedPed }
            end
            if distance >= Config.DistanceSpawn and spawnedPeds[k] then
                if DoesEntityExist(spawnedPeds[k].spawnedPed) then
                    if Config.FadeIn then
                        for i = 255, 0, -51 do
                            Wait(50)
                            if DoesEntityExist(spawnedPeds[k].spawnedPed) then
                                SetEntityAlpha(spawnedPeds[k].spawnedPed, i, false)
                            end
                        end
                    end
                    DeletePed(spawnedPeds[k].spawnedPed)
                end
                spawnedPeds[k] = nil
            end
        end
    end
end)

function NearPed(npcData)
    RequestModel(npcData.npcmodel)
    while not HasModelLoaded(npcData.npcmodel) do
        Wait(50)
    end
    spawnedPed = CreatePed(npcData.npcmodel, npcData.npccoords.x, npcData.npccoords.y, npcData.npccoords.z - 1.0, npcData.npccoords.w, false, false, 0, 0)
    SetEntityAlpha(spawnedPed, 0, false)
    SetRandomOutfitVariation(spawnedPed, true)
    SetEntityCanBeDamaged(spawnedPed, false)
    SetEntityInvincible(spawnedPed, true)
    FreezeEntityPosition(spawnedPed, true)
    SetBlockingOfNonTemporaryEvents(spawnedPed, true)
    SetPedCanBeTargetted(spawnedPed, false)
    SetPedFleeAttributes(spawnedPed, 0, false)
    if Config.FadeIn then
        for i = 0, 255, 51 do
            Wait(50)
            SetEntityAlpha(spawnedPed, i, false)
        end
    end
    exports.ox_target:addLocalEntity(spawnedPed, {
        {
            name = 'npc_ranch',
            icon = 'far fa-eye',
            label = locale('open_ranch'),
            onSelect = function()
                TriggerEvent('rex-ranch:client:openranch', npcData.ranchid, npcData.jobaccess)
            end,
            distance = 2.0
        }
    })
    return spawnedPed
end

---------------------------------
-- cleanup
---------------------------------
AddEventHandler("onResourceStop", function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    for k,v in pairs(spawnedPeds) do
        if DoesEntityExist(spawnedPeds[k].spawnedPed) then
            DeletePed(spawnedPeds[k].spawnedPed)
        end
        spawnedPeds[k] = nil
    end
end)
