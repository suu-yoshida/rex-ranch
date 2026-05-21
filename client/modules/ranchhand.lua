local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

RegisterNetEvent('rex-ranch:client:openranchhandmenu', function(ranchid)
    local herdingOption = {}
    if Config.HerdingEnabled then
        herdingOption = {
            title = locale('animal_herding'),
            description = locale('animal_herding_desc'),
            icon = 'fa-solid fa-paw',
            event = 'rex-ranch:client:openHerdingMenu',
            arrow = true
        }
    end
    
    local options = {
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
    
    if Config.HerdingEnabled then
        table.insert(options, herdingOption)
    end
    
    lib.registerContext({
        id = 'ranchhand_job_menu',
        title = locale('rancher_menu'),
        options = options
    })
    lib.showContext('ranchhand_job_menu')
end)
