local RSGCore = exports['rsg-core']:GetCoreObject()
lib.locale()

---------------------------------------------
-- Open Staff Management Menu
---------------------------------------------
RegisterNetEvent('rex-ranch:client:openStaffManagement', function(ranchid)
    if not ranchid then return end
    
    -- Request staff data from server
    RSGCore.Functions.TriggerCallback('rex-ranch:server:getStaffList', function(staffData)
        if not staffData then
            lib.notify({type = 'error', description = locale('failed_load_staff_data')})
            return
        end
        
        -- Build staff management menu
        local options = {
            {
                title = locale('view_all_staff'),
                description = locale('view_all_staff_desc'),
                icon = 'fa-solid fa-users',
                onSelect = function()
                    OpenStaffListMenu(ranchid, staffData)
                end
            },
            {
                title = locale('hire_employee'),
                description = locale('hire_employee_desc'),
                icon = 'fa-solid fa-user-plus',
                onSelect = function()
                    OpenHireMenu(ranchid)
                end
            },
        }
        
        lib.registerContext({
            id = 'staff_management_menu',
            title = locale('staff_management_title'),
            options = options
        })
        lib.showContext('staff_management_menu')
    end, ranchid)
end)

---------------------------------------------
-- Staff List Menu
---------------------------------------------
function OpenStaffListMenu(ranchid, staffData)
    local options = {}
    
    if not staffData or #staffData.employees == 0 then
        table.insert(options, {
            title = locale('no_employees_found'),
            description = locale('no_employees_desc'),
            icon = 'fa-solid fa-info-circle',
            disabled = true
        })
    else
        for _, employee in ipairs(staffData.employees) do
            local gradeLabel = employee.grade_label or locale('unknown')
            local onlineStatus = employee.is_online and locale('staff_online') or locale('staff_offline')
            
            table.insert(options, {
                title = employee.name,
                description = gradeLabel .. ' | ' .. onlineStatus,
                icon = 'fa-solid fa-user',
                onSelect = function()
                    OpenEmployeeActionsMenu(ranchid, employee)
                end
            })
        end
    end
    
    table.insert(options, {
        title = locale('back'),
        icon = 'fa-solid fa-arrow-left',
        onSelect = function()
            TriggerEvent('rex-ranch:client:openStaffManagement', ranchid)
        end
    })
    
    lib.registerContext({
        id = 'staff_list_menu',
        title = string.format(locale('staff_list_count'), #staffData.employees, Config.StaffManagement.MaxEmployeesPerRanch),
        options = options
    })
    lib.showContext('staff_list_menu')
end

---------------------------------------------
-- Employee Actions Menu
---------------------------------------------
function OpenEmployeeActionsMenu(ranchid, employee)
    local options = {
        {
            title = locale('view_details'),
            description = locale('view_employee_info'),
            icon = 'fa-solid fa-info-circle',
            onSelect = function()
                OpenEmployeeDetailsMenu(ranchid, employee)
            end
        },
        {
            title = locale('promote'),
            description = locale('promote_desc'),
            icon = 'fa-solid fa-arrow-up',
            onSelect = function()
                TriggerServerEvent('rex-ranch:server:promoteEmployee', ranchid, employee.citizenid)
                Wait(500)
                TriggerEvent('rex-ranch:client:openStaffManagement', ranchid)
            end
        },
        {
            title = locale('demote'),
            description = locale('demote_desc'),
            icon = 'fa-solid fa-arrow-down',
            onSelect = function()
                TriggerServerEvent('rex-ranch:server:demoteEmployee', ranchid, employee.citizenid)
                Wait(500)
                TriggerEvent('rex-ranch:client:openStaffManagement', ranchid)
            end
        },
        {
            title = locale('fire_employee'),
            description = locale('fire_employee_desc'),
            icon = 'fa-solid fa-user-times',
            onSelect = function()
                local confirm = lib.alertDialog({
                    header = locale('confirm_termination'),
                    content = string.format(locale('confirm_fire_employee'), employee.name),
                    centered = true,
                    cancel = true
                })
                
                if confirm == 'confirm' then
                    TriggerServerEvent('rex-ranch:server:fireEmployee', ranchid, employee.citizenid)
                    Wait(500)
                    TriggerEvent('rex-ranch:client:openStaffManagement', ranchid)
                end
            end
        },
        {
            title = locale('back'),
            icon = 'fa-solid fa-arrow-left',
            onSelect = function()
                TriggerEvent('rex-ranch:client:openStaffManagement', ranchid)
            end
        }
    }
    
    lib.registerContext({
        id = 'employee_actions_menu',
        title = string.format(locale('employee_name_title'), employee.name),
        options = options
    })
    lib.showContext('employee_actions_menu')
end

---------------------------------------------
-- Employee Details Menu
---------------------------------------------
function OpenEmployeeDetailsMenu(ranchid, employee)
    local options = {
        {
            title = locale('name'),
            description = employee.name,
            icon = 'fa-solid fa-id-card',
            disabled = true
        },
        {
            title = locale('position'),
            description = employee.grade_label or locale('unknown'),
            icon = 'fa-solid fa-briefcase',
            disabled = true
        },
        {
            title = locale('status'),
            description = employee.is_online and locale('online') or locale('offline'),
            icon = employee.is_online and 'fa-solid fa-circle-check' or 'fa-solid fa-circle-xmark',
            disabled = true
        },
        {
            title = locale('back'),
            icon = 'fa-solid fa-arrow-left',
            onSelect = function()
                OpenEmployeeActionsMenu(ranchid, employee)
            end
        }
    }
    
    lib.registerContext({
        id = 'employee_details_menu',
        title = locale('employee_details'),
        options = options
    })
    lib.showContext('employee_details_menu')
end

---------------------------------------------
-- Hire Employee Menu
---------------------------------------------
function OpenHireMenu(ranchid)
    -- Get nearby players
    RSGCore.Functions.TriggerCallback('rex-ranch:server:getNearbyPlayers', function(nearbyPlayers)
        if not nearbyPlayers or #nearbyPlayers == 0 then
            lib.notify({type = 'error', description = locale('no_nearby_players')})
            return
        end
        
        local options = {}
        
        for _, player in ipairs(nearbyPlayers) do
            table.insert(options, {
                title = player.name,
                description = string.format(locale('player_distance_desc'), player.id, math.floor(player.distance)),
                icon = 'fa-solid fa-user',
                onSelect = function()
                    OpenHireConfirmDialog(ranchid, player)
                end
            })
        end
        
        table.insert(options, {
            title = locale('back'),
            icon = 'fa-solid fa-arrow-left',
            onSelect = function()
                TriggerEvent('rex-ranch:client:openStaffManagement', ranchid)
            end
        })
        
        lib.registerContext({
            id = 'hire_menu',
            title = locale('hire_employee'),
            options = options
        })
        lib.showContext('hire_menu')
    end)
end

---------------------------------------------
-- Hire Confirmation Dialog
---------------------------------------------
function OpenHireConfirmDialog(ranchid, player)
    local input = lib.inputDialog(string.format(locale('hire_player'), player.name), {
        {
            type = 'select',
            label = locale('starting_grade'),
            description = locale('starting_grade_desc'),
            required = true,
            options = {
                {value = 0, label = locale('grade_trainee')},
                {value = 1, label = locale('grade_ranch_hand')},
                {value = 2, label = locale('grade_manager')},
            }
        }
    })
    
    if input then
        TriggerServerEvent('rex-ranch:server:hireEmployee', ranchid, player.id, input[1])
        Wait(500)
        TriggerEvent('rex-ranch:client:openStaffManagement', ranchid)
    end
end
