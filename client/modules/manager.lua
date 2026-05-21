local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

RegisterNetEvent('rex-ranch:client:openmanagermenu', function(ranchid)
    local options = {
        {
            title = locale('staff_management'),
            description = locale('staff_management_desc'),
            icon = 'fa-solid fa-user-tie',
            event = 'rex-ranch:client:openStaffManagement',
            args = ranchid,
            arrow = true
        },
        {
            title = locale('ranch_storage'),
            icon = 'fa-solid fa-box',
            serverEvent = 'rex-ranch:server:ranchstorage',
            args = { ranchid = ranchid },
            arrow = true
        },
        {
            title = locale('animal_overview'),
            description = locale('animal_overview_desc'),
            icon = 'fa-solid fa-list',
            event = 'rex-ranch:client:openAnimalOverview',
            args = ranchid,
            arrow = true
        },
    }
    
    -- Add herding option if enabled
    if Config.HerdingEnabled then
        table.insert(options, {
            title = locale('animal_herding'),
            description = locale('animal_herding_desc'),
            icon = 'fa-solid fa-paw',
            event = 'rex-ranch:client:openHerdingMenu',
            arrow = true
        })
    end
    
    lib.registerContext({
        id = 'manager_job_menu',
        title = locale('manager_menu'),
        options = options
    })
    lib.showContext('manager_job_menu')
end)
