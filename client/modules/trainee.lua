local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

RegisterNetEvent('rex-ranch:client:opentraineemenu', function(ranchid)
    local options = {
        {
            title = locale('ranch_information'),
            description = locale('ranch_information_desc'),
            icon = 'fa-solid fa-info-circle',
            onSelect = function()
                lib.notify({
                    title = locale('trainee_info'),
                    description = locale('trainee_info_desc'),
                    type = 'inform',
                    duration = 8000
                })
            end
        },
        {
            title = locale('basic_animal_care'),
            description = locale('basic_animal_care_desc'),
            icon = 'fa-solid fa-heart',
            onSelect = function()
                lib.notify({
                    title = locale('animal_care_guide'),
                    description = locale('animal_care_guide_desc'),
                    type = 'inform',
                    duration = 8000
                })
            end
        }
    }
    
    -- Add herding guide if herding is enabled
    if Config.HerdingEnabled then
        table.insert(options, {
            title = locale('herding_guide'),
            description = locale('herding_guide_desc'),
            icon = 'fa-solid fa-paw',
            onSelect = function()
                lib.notify({
                    title = locale('herding_info'),
                    description = locale('herding_info_desc'),
                    type = 'inform',
                    duration = 6000
                })
            end
        })
    end
    
    lib.registerContext({
        id = 'trainee_job_menu',
        title = locale('trainee_menu'),
        options = options
    })
    lib.showContext('trainee_job_menu')
end)
