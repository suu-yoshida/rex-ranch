local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- blips
---------------------------------------------
CreateThread(function()
    for _,ranchData in pairs(Config.RanchLocations) do
        if ranchData.showblip == true then
            local RanchBlip = Citizen.InvokeNative(0x5A039BB0BCA604B6, joaat(ranchData.blipsprite), ranchData.coords.x, ranchData.coords.y, ranchData.coords.z)
            SetBlipSprite(RanchBlip, joaat(ranchData.blipsprite), true)
            SetBlipScale(RanchBlip, ranchData.blipscale)
            Citizen.InvokeNative(0x9CB1A1623062F402, RanchBlip, ranchData.blipname)
        end
    end
end)

---------------------------------------------
-- get correct menu
---------------------------------------------
RegisterNetEvent('rex-ranch:client:openranch', function(ranchid, jobaccess)
    local PlayerData = RSGCore.Functions.GetPlayerData()
    local playerjob = PlayerData.job.name
    local playerlevel = PlayerData.job.grade.level
    if playerjob ~= jobaccess then return end
    if playerlevel == 0 then
        TriggerEvent('rex-ranch:client:opentraineemenu', ranchid)
    end
    if playerlevel == 1 then
        TriggerEvent('rex-ranch:client:openranchhandmenu', ranchid)
    end
    if playerlevel == 2 then
        TriggerEvent('rex-ranch:client:openmanagermenu', ranchid)
    end
end)
