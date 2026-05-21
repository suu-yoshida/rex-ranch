local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- Animal Overview Menu
---------------------------------------------

RegisterNetEvent('rex-ranch:client:openAnimalOverview', function(ranchid)
    local Player = RSGCore.Functions.GetPlayerData()
    if not Player then return end
    
    -- Show loading notification
    lib.notify({
        title = locale('loading'),
        description = locale('fetching_animal_data'),
        type = 'inform',
        duration = 2000
    })
    
    RSGCore.Functions.TriggerCallback('rex-ranch:server:getAnimalOverview', function(data)
        if not data or not data.animals then
            lib.notify({
                title = locale('error'),
                description = locale('failed_load_animal_data'),
                type = 'error'
            })
            return
        end
        
        showAnimalOverview(data, ranchid)
    end, ranchid)
end)

function showAnimalOverview(data, ranchid)
    local options = {}
    
    -- Summary section
    table.insert(options, {
        title = locale('summary'),
        description = string.format(locale('total_animals_desc'), data.summary.total),
        icon = 'fa-solid fa-chart-bar',
        event = 'rex-ranch:client:showAnimalSummary',
        args = { summary = data.summary },
        arrow = true
    })
    
    -- Group animals by ranch if viewing all ranches
    local animalsByRanch = {}
    if not ranchid then
        for _, animal in ipairs(data.animals) do
            local ranch = animal.ranchid or locale('unknown')
            if not animalsByRanch[ranch] then
                animalsByRanch[ranch] = {}
            end
            table.insert(animalsByRanch[ranch], animal)
        end
        
        -- Add ranch sections
        for ranch, animals in pairs(animalsByRanch) do
            table.insert(options, {
                title = string.format(locale('ranch_title'), ranch),
                description = string.format(locale('animals_count'), #animals),
                icon = 'fa-solid fa-home',
                event = 'rex-ranch:client:showRanchAnimals',
                args = { animals = animals, ranchid = ranch },
                arrow = true
            })
        end
    else
        -- Show individual animals for specific ranch
        local animalsByType = {}
        for _, animal in ipairs(data.animals) do
            local type = animal.model or locale('unknown')
            if not animalsByType[type] then
                animalsByType[type] = {}
            end
            table.insert(animalsByType[type], animal)
        end
        
        -- Add animal type sections
        for animalType, animals in pairs(animalsByType) do
            local typeIcon = getAnimalTypeIcon(animalType)
            local label = getAnimalLabel(animalType)
            local healthyCount = 0
            local issues = 0
            
            for _, animal in ipairs(animals) do
                if not animal.is_unhealthy and not animal.is_hungry and not animal.is_thirsty then
                    healthyCount = healthyCount + 1
                else
                    issues = issues + 1
                end
            end
            
            local statusText = ''
            if issues > 0 then
                statusText = string.format(locale('need_attention_suffix'), issues)
            end
            
            table.insert(options, {
                title = string.format('%s %s', typeIcon, label),
                description = string.format(locale('animals_count_with_status'), #animals, statusText),
                icon = 'fa-solid fa-paw',
                event = 'rex-ranch:client:showAnimalsByType',
                args = { animals = animals, animalType = animalType, label = label },
                arrow = true
            })
        end
    end
    
    -- Add filter options
    if #data.animals > 0 then
        table.insert(options, {
            title = locale('filters'),
            description = locale('filter_animals_by_status'),
            icon = 'fa-solid fa-filter',
            event = 'rex-ranch:client:showAnimalFilters',
            args = { animals = data.animals, ranchid = ranchid },
            arrow = true
        })
    end
    
    local title = ranchid and locale('animal_overview') or locale('animal_overview_all_ranches')
    
    lib.registerContext({
        id = 'animal_overview_menu',
        title = title,
        options = options
    })
    lib.showContext('animal_overview_menu')
end

---------------------------------------------
-- Summary Display
---------------------------------------------
RegisterNetEvent('rex-ranch:client:showAnimalSummary', function(data)
    local summary = data.summary
    local options = {}
    
    -- Total animals
    table.insert(options, {
        title = string.format(locale('total_animals_title'), summary.total),
        icon = 'fa-solid fa-hashtag',
        readOnly = true
    })
    
    -- Gender breakdown
    table.insert(options, {
        title = string.format(locale('gender_summary'), summary.byGender.male or 0, summary.byGender.female or 0),
        icon = 'fa-solid fa-venus-mars',
        readOnly = true
    })
    
    -- Animal types
    if summary.byType and next(summary.byType) then
        for animalType, count in pairs(summary.byType) do
            local typeIcon = getAnimalTypeIcon(animalType)
            local label = getAnimalLabel(animalType)
            table.insert(options, {
                title = string.format(locale('animal_type_count_title'), typeIcon, label, count),
                icon = 'fa-solid fa-paw',
                readOnly = true
            })
        end
    end
    
    -- Status indicators
    if summary.pregnant > 0 then
        table.insert(options, {
            title = string.format(locale('pregnant_count'), summary.pregnant),
            icon = 'fa-solid fa-baby',
            readOnly = true
        })
    end
    
    if summary.ready_for_breeding > 0 then
        table.insert(options, {
            title = string.format(locale('ready_breed_count'), summary.ready_for_breeding),
            icon = 'fa-solid fa-heart',
            readOnly = true
        })
    end
    
    -- Health issues
    if summary.unhealthy > 0 then
        table.insert(options, {
            title = string.format(locale('unhealthy_count'), summary.unhealthy),
            icon = 'fa-solid fa-medical-note',
            readOnly = true
        })
    end
    
    if summary.hungry > 0 then
        table.insert(options, {
            title = string.format(locale('hungry_count'), summary.hungry),
            icon = 'fa-solid fa-utensils',
            readOnly = true
        })
    end
    
    if summary.thirsty > 0 then
        table.insert(options, {
            title = string.format(locale('thirsty_count'), summary.thirsty),
            icon = 'fa-solid fa-tint',
            readOnly = true
        })
    end
    
    lib.registerContext({
        id = 'animal_summary_menu',
        title = locale('animal_summary'),
        options = options,
        menu = 'animal_overview_menu'
    })
    lib.showContext('animal_summary_menu')
end)

---------------------------------------------
-- Ranch Animals Display (for multi-ranch view)
---------------------------------------------
RegisterNetEvent('rex-ranch:client:showRanchAnimals', function(data)
    local animals = data.animals
    local ranchid = data.ranchid
    
    -- Group by animal type
    local animalsByType = {}
    for _, animal in ipairs(animals) do
        local type = animal.model or locale('unknown')
        if not animalsByType[type] then
            animalsByType[type] = {}
        end
        table.insert(animalsByType[type], animal)
    end
    
    local options = {}
    for animalType, typeAnimals in pairs(animalsByType) do
        local typeIcon = getAnimalTypeIcon(animalType)
        local label = getAnimalLabel(animalType)
        local healthyCount = 0
        local issues = 0
        
        for _, animal in ipairs(typeAnimals) do
            if not animal.is_unhealthy and not animal.is_hungry and not animal.is_thirsty then
                healthyCount = healthyCount + 1
            else
                issues = issues + 1
            end
        end
        
        local statusText = ''
        if issues > 0 then
            statusText = string.format(locale('need_attention_suffix'), issues)
        end
        
        table.insert(options, {
            title = string.format('%s %s', typeIcon, label),
            description = string.format(locale('animals_count_with_status'), #typeAnimals, statusText),
            icon = 'fa-solid fa-paw',
            event = 'rex-ranch:client:showAnimalsByType',
            args = { animals = typeAnimals, animalType = animalType, label = label },
            arrow = true
        })
    end
    
    lib.registerContext({
        id = 'ranch_animals_menu',
        title = string.format(locale('ranch_animals_title'), ranchid, #animals),
        options = options,
        menu = 'animal_overview_menu'
    })
    lib.showContext('ranch_animals_menu')
end)

---------------------------------------------
-- Animals by Type Display
---------------------------------------------
RegisterNetEvent('rex-ranch:client:showAnimalsByType', function(data)
    local animals = data.animals
    local animalType = data.animalType
    local label = data.label or getAnimalLabel(animalType)
    local options = {}
    
    for _, animal in ipairs(animals) do
        local statusIcons = {}
        local statusText = ''
        
        -- Health status
        if animal.is_unhealthy then
            table.insert(statusIcons, '🏥')
        end
        if animal.is_hungry then
            table.insert(statusIcons, '🍖')
        end
        if animal.is_thirsty then
            table.insert(statusIcons, '💧')
        end
        
        -- Special status
        if animal.pregnant then
            if animal.pregnancy_status then
                table.insert(statusIcons, '🤱')
                statusText = animal.pregnancy_status
            else
                table.insert(statusIcons, '🤱')
            end
        elseif animal.breeding_ready then
            table.insert(statusIcons, '💕')
        elseif animal.breeding_restriction then
            table.insert(statusIcons, '⛔')
            if statusText == '' then
                statusText = animal.breeding_restriction
            end
        end
        
        if #statusIcons > 0 then
            statusText = table.concat(statusIcons, ' ') .. (statusText ~= '' and (' - ' .. statusText) or '')
        end
        
        local genderIcon = animal.gender == 'male' and '♂️' or '♀️'
        local title = string.format(locale('animal_id_age_title'), animal.animalid, genderIcon, animal.age)
        local description = statusText ~= '' and statusText or locale('health_healthy')
        
        table.insert(options, {
            title = title,
            description = description,
            icon = 'fa-solid fa-paw',
            event = 'rex-ranch:client:showAnimalDetails',
            args = { animal = animal },
            arrow = true
        })
    end
    
    lib.registerContext({
        id = 'animals_by_type_menu',
        title = string.format(locale('animals_by_label_title'), label, #animals),
        options = options,
        menu = 'animal_overview_menu'
    })
    lib.showContext('animals_by_type_menu')
end)

---------------------------------------------
-- Individual Animal Details
---------------------------------------------
RegisterNetEvent('rex-ranch:client:showAnimalDetails', function(data)
    local animal = data.animal
    local options = {}
    
    -- Basic info
    table.insert(options, {
        title = string.format(locale('animal_id_title'), animal.animalid),
        icon = 'fa-solid fa-id-card',
        readOnly = true
    })
    
    table.insert(options, {
        title = string.format(locale('animal_type_title'), getAnimalLabel(animal.model)),
        icon = 'fa-solid fa-paw',
        readOnly = true
    })
    
    local genderIcon = animal.gender == 'male' and '♂️' or '♀️'
    table.insert(options, {
        title = string.format(locale('animal_gender_title'), genderIcon, animal.gender),
        icon = 'fa-solid fa-venus-mars',
        readOnly = true
    })
    
    table.insert(options, {
        title = string.format(locale('animal_age_days'), animal.age),
        icon = 'fa-solid fa-calendar',
        readOnly = true
    })
    
    -- Health stats
    local healthColor = animal.health >= 70 and 'green' or (animal.health >= 40 and 'orange' or 'red')
    table.insert(options, {
        title = string.format(locale('health_percent'), math.floor(animal.health)),
        icon = 'fa-solid fa-heart-pulse',
        iconColor = healthColor,
        readOnly = true
    })
    
    local hungerColor = animal.hunger >= 50 and 'green' or (animal.hunger >= 25 and 'orange' or 'red')
    table.insert(options, {
        title = string.format(locale('hunger_percent'), math.floor(animal.hunger)),
        icon = 'fa-solid fa-utensils',
        iconColor = hungerColor,
        readOnly = true
    })
    
    local thirstColor = animal.thirst >= 50 and 'green' or (animal.thirst >= 25 and 'orange' or 'red')
    table.insert(options, {
        title = string.format(locale('thirst_percent'), math.floor(animal.thirst)),
        icon = 'fa-solid fa-tint',
        iconColor = thirstColor,
        readOnly = true
    })
    
    -- Special status
    if animal.pregnant then
        table.insert(options, {
            title = locale('status_pregnant'),
            description = animal.pregnancy_status or locale('expecting'),
            icon = 'fa-solid fa-baby',
            iconColor = 'pink',
            readOnly = true
        })
    elseif animal.breeding_ready then
        table.insert(options, {
            title = locale('status_ready_breed'),
            icon = 'fa-solid fa-heart',
            iconColor = 'red',
            readOnly = true
        })
    elseif animal.breeding_restriction then
        table.insert(options, {
            title = locale('status_breeding_restricted'),
            description = animal.breeding_restriction,
            icon = 'fa-solid fa-ban',
            iconColor = 'red',
            readOnly = true
        })
    else
        table.insert(options, {
            title = locale('status_normal'),
            icon = 'fa-solid fa-check',
            iconColor = 'green',
            readOnly = true
        })
    end
    
    -- Position info
    if animal.pos_x and animal.pos_y and animal.pos_z then
        table.insert(options, {
            title = string.format(locale('location_coords'), animal.pos_x, animal.pos_y, animal.pos_z),
            icon = 'fa-solid fa-map-marker-alt',
            readOnly = true
        })
    end
    
    lib.registerContext({
        id = 'animal_details_menu',
        title = locale('animal_details'),
        options = options,
        menu = 'animals_by_type_menu'
    })
    lib.showContext('animal_details_menu')
end)

---------------------------------------------
-- Filter Menu
---------------------------------------------
RegisterNetEvent('rex-ranch:client:showAnimalFilters', function(data)
    local animals = data.animals
    local ranchid = data.ranchid
    local options = {}
    
    -- Count animals by status
    local pregnantCount = 0
    local breedingReadyCount = 0
    local unhealthyCount = 0
    local hungryCount = 0
    local thirstyCount = 0
    
    for _, animal in ipairs(animals) do
        if animal.pregnant then pregnantCount = pregnantCount + 1 end
        if animal.breeding_ready then breedingReadyCount = breedingReadyCount + 1 end
        if animal.is_unhealthy then unhealthyCount = unhealthyCount + 1 end
        if animal.is_hungry then hungryCount = hungryCount + 1 end
        if animal.is_thirsty then thirstyCount = thirstyCount + 1 end
    end
    
    -- Filter options
    if pregnantCount > 0 then
        table.insert(options, {
            title = string.format(locale('pregnant_animals_count'), pregnantCount),
            icon = 'fa-solid fa-baby',
            event = 'rex-ranch:client:showFilteredAnimals',
            args = { animals = animals, filter = 'pregnant', title = locale('pregnant_animals') },
            arrow = true
        })
    end
    
    if breedingReadyCount > 0 then
        table.insert(options, {
            title = string.format(locale('ready_breed_animals_count'), breedingReadyCount),
            icon = 'fa-solid fa-heart',
            event = 'rex-ranch:client:showFilteredAnimals',
            args = { animals = animals, filter = 'breeding_ready', title = locale('ready_to_breed') },
            arrow = true
        })
    end
    
    if unhealthyCount > 0 then
        table.insert(options, {
            title = string.format(locale('unhealthy_animals_count'), unhealthyCount),
            icon = 'fa-solid fa-medical-note',
            event = 'rex-ranch:client:showFilteredAnimals',
            args = { animals = animals, filter = 'is_unhealthy', title = locale('unhealthy_animals') },
            arrow = true
        })
    end
    
    if hungryCount > 0 then
        table.insert(options, {
            title = string.format(locale('hungry_animals_count'), hungryCount),
            icon = 'fa-solid fa-utensils',
            event = 'rex-ranch:client:showFilteredAnimals',
            args = { animals = animals, filter = 'is_hungry', title = locale('hungry_animals') },
            arrow = true
        })
    end
    
    if thirstyCount > 0 then
        table.insert(options, {
            title = string.format(locale('thirsty_animals_count'), thirstyCount),
            icon = 'fa-solid fa-tint',
            event = 'rex-ranch:client:showFilteredAnimals',
            args = { animals = animals, filter = 'is_thirsty', title = locale('thirsty_animals') },
            arrow = true
        })
    end
    
    lib.registerContext({
        id = 'animal_filters_menu',
        title = locale('animal_filters'),
        options = options,
        menu = 'animal_overview_menu'
    })
    lib.showContext('animal_filters_menu')
end)

---------------------------------------------
-- Filtered Animals Display
---------------------------------------------
RegisterNetEvent('rex-ranch:client:showFilteredAnimals', function(data)
    local allAnimals = data.animals
    local filter = data.filter
    local title = data.title
    local options = {}
    
    local filteredAnimals = {}
    for _, animal in ipairs(allAnimals) do
        if animal[filter] then
            table.insert(filteredAnimals, animal)
        end
    end
    
    for _, animal in ipairs(filteredAnimals) do
        local genderIcon = animal.gender == 'male' and '♂️' or '♀️'
        local animalTitle = string.format(locale('animal_id_type_title'), animal.animalid, genderIcon, getAnimalLabel(animal.model))
        
        local description = ''
        if animal.pregnant and animal.pregnancy_status then
            description = animal.pregnancy_status
        elseif animal.is_unhealthy then
            description = string.format(locale('health_percent'), math.floor(animal.health))
        elseif animal.is_hungry then
            description = string.format(locale('hunger_percent'), math.floor(animal.hunger))
        elseif animal.is_thirsty then
            description = string.format(locale('thirst_percent'), math.floor(animal.thirst))
        end
        
        table.insert(options, {
            title = animalTitle,
            description = description,
            icon = 'fa-solid fa-paw',
            event = 'rex-ranch:client:showAnimalDetails',
            args = { animal = animal },
            arrow = true
        })
    end
    
    lib.registerContext({
        id = 'filtered_animals_menu',
        title = string.format(locale('filtered_title_count'), title, #filteredAnimals),
        options = options,
        menu = 'animal_filters_menu'
    })
    lib.showContext('filtered_animals_menu')
end)

---------------------------------------------
-- Helper Functions
---------------------------------------------

-- Animal model to label mapping
local animalLabels = {
    ['a_c_cow'] = locale('animal_cow'),
    ['a_c_bull_01'] = locale('animal_bull'),
    ['a_c_pig'] = locale('animal_pig'),
    ['a_c_sheep'] = locale('animal_sheep'),
    ['a_c_goat'] = locale('animal_goat'),
    ['a_c_horse'] = locale('animal_horse'),
    ['a_c_chicken'] = locale('animal_chicken'),
    ['a_c_rooster'] = locale('animal_rooster')
}

function getAnimalLabel(model)
    return animalLabels[model] or model or locale('unknown')
end

function getAnimalTypeIcon(animalType)
    local icons = {
        ['a_c_cow'] = '🐄',
        ['a_c_bull_01'] = '🐂',
        ['a_c_pig'] = '🐷',
        ['a_c_sheep'] = '🐑',
        ['a_c_goat'] = '🐐',
        ['a_c_horse'] = '🐴',
        ['a_c_chicken'] = '🐔',
        ['a_c_rooster'] = '🐓'
    }
    return icons[animalType] or '🐾'
end
