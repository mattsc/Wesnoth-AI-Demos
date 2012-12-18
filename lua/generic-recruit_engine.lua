return {
    -- init parameters:
    -- ai: a reference to the ai engine so recruit has access to ai functions
    -- ai_cas: an object reference to store the CAs and associated data
    --   the CA will use the function names ai_cas:recruit_rushers_eval/exec, so should be referenced by the object name used by the calling AI
    --   ai_cas also has the functions find_best_recruit, find_best_recruit_hex and analyze_enemy_unit added to it
    --     find_best_recruit, find_best_recruit_hex may be useful for writing recruitment code separately from the engine
    -- params: parameters to configure recruitment
    --      score_function: function that returns the CA score when recruit_rushers_eval wants to recruit
    --          (default returns the RCA recruitment score)
    --      randomness: a measure of randomness in recruitment
    --          higher absolute values increase randomness, with values above about 3 being close to completely random
    --          (default = 0.1)
    init = function(ai, ai_cas, params)
        if not params then
            params = {}
        end
        math.randomseed(os.time())

        local H = wesnoth.require "lua/helper.lua"
        local W = H.set_wml_action_metatable {}
        local AH = wesnoth.require "~/add-ons/AI-demos/lua/ai_helper.lua"
        local DBG = wesnoth.require "~/add-ons/AI-demos/lua/debug.lua"

        local recruit_data = {}

        local get_hp_efficiency = function (table, recruit_id)
            -- raw durability is a function of hp and the regenerates ability
            -- efficiency decreases faster than cost increases to avoid recruiting many expensive units
            -- there is a requirement for bodies in order to block movement

            -- There is currently an assumption that opponents will average about 15 damage per strike
            -- and that two units will attack per turn until the unit dies to estimate the number of hp
            -- gained from regeneration
            local effective_hp = wesnoth.unit_types[recruit_id].max_hitpoints

            local unit = wesnoth.create_unit {
                type = recruit_id,
                random_traits = false,
                name = "X",
                random_gender = false
            }
            -- Find the best regeneration ability and use it to estimate hp regained by regeneration
            local abilities = H.get_child(unit.__cfg, "abilities")
            local regen_amount = 0
            if abilities then
                for regen in H.child_range(abilities, "regenerate") do
                    if regen.value > regen_amount then
                        regen_amount = regen.value
                    end
                end
                effective_hp = effective_hp + (regen_amount * effective_hp/30)
            end
            local efficiency = math.max(math.log(effective_hp/20),0.01)/(wesnoth.unit_types[recruit_id].cost^2)

            table[recruit_id] = efficiency
            return efficiency
        end
        local efficiency = {}
        setmetatable(efficiency, { __index = get_hp_efficiency })

        function living(unit)
            return not unit.status.not_living
        end

        function get_best_defense(unit)
            local terrain_archetypes = { "Wo", "Ww", "Wwr", "Ss", "Gt", "Ds", "Ft", "Hh", "Mm", "Vi", "Ch", "Uu", "At", "Qt", "^Uf", "Xt" }
            local best_defense = 100

            for i, terrain in ipairs(terrain_archetypes) do
                local defense = wesnoth.unit_defense(unit, terrain)
                if defense < best_defense then
                    best_defense = defense
                end
            end

            return best_defense
        end

        function analyze_enemy_unit(enemy_type, ally_type)
            local function get_best_attack(attacker, defender, unit_defense, can_poison)
                -- Try to find the average damage for each possible attack and return the one that deals the most damage.
                -- Would be preferable to call simulate combat, but that requires the defender to be on the map according
                -- to documentation and we are looking for hypothetical situations so would have to search for available
                -- locations for the defender that would have the desired defense. We would also need to remove nearby units
                -- in order to ensure that adjacent units are not modifying the result. In addition, the time of day is
                -- assumed to be neutral here, which is not assured in the simulation.
                -- Ideally, this function would be a clone of simulate combat, but run for each time of day in the scenario and on arbitrary terrain.
                -- In several cases this function only approximates the correct value (eg Thunderguard vs Goblin Spearman has damage capped by target health)
                -- In some cases (like poison), this approximation is preferred to the actual value.
                local best_damage = 0
                local best_attack = nil
                -- Steadfast is currently disabled because it biases the AI too much in favour of Guardsmen
                -- Basically it sees the defender stats for damage and wrongfully concludes that the unit is amazing
                -- This may be rectifiable by looking at retaliation damage as well.
                local steadfast = false

                for attack in H.child_range(wesnoth.unit_types[attacker.type].__cfg, "attack") do
                    local defense = unit_defense
                    local poison = false
                    local damage_multiplier = 1
                    -- TODO: handle more abilities (charge)
                    for special in H.child_range(attack, 'specials') do
                        local mod
                        if H.get_child(special, 'poison') and can_poison then
                            poison = true
                        end

                        -- Handle marksman and magical
                        -- TODO: Make this work properly for UMC chance_to_hit (does not account for all keys)
                        mod = H.get_child(special, 'chance_to_hit')
                        if mod then
                            if mod.cumulative then
                                if mod.value > defense then
                                    defense = mod.value
                                end
                            else
                                defense = mod.value
                            end
                        end

                        -- Handle backstab
                        mod = H.get_child(special, 'damage')
                        if mod then
                            if mod.backstab then
                                -- Assume backstab happens on only 1/2 of attacks
                                -- TODO: find out what actual probability of getting to backstab is
                                damage_multiplier = damage_multiplier*(mod.multiply*0.5 + 0.5)
                            end
                        end
                    end

                    -- Handle drain for defender
                    local drain_recovery = 0
                    for defender_attack in H.child_range(defender.__cfg, 'attack') do
                        if (defender_attack.range == attack.range) then
                            for special in H.child_range(defender_attack, 'specials') do
                                if H.get_child(special, 'drains') and living(attacker) then
                                    -- TODO: handle chance to hit
                                    -- currently assumes 50% chance to hit using supplied constant
                                    local attacker_resistance = wesnoth.unit_resistance(attacker, defender_attack.type)
                                    drain_recovery = (defender_attack.damage*defender_attack.number*attacker_resistance*0.25)/100
                                end
                            end
                        end
                    end

                    defense = defense/100.0
                    local resistance = wesnoth.unit_resistance(defender, attack.type)
                    if steadfast and (resistance < 100) then
                        resistance = 100 - ((100 - resistance) * 2)
                        if (resistance < 50) then
                            resistance = 50
                        end
                    end
                    local base_damage = attack.damage*resistance*damage_multiplier
                    if (resistance > 100) then
                        base_damage = base_damage-1
                    end
                    base_damage = math.floor(base_damage/100 + 0.5)
                    if (base_damage < 1) and (attack.damage > 0) then
                        -- Damage is always at least 1
                        base_damage = 1
                    end
                    local attack_damage = base_damage*attack.number*defense-drain_recovery

                    local poison_damage = 0
                    if poison then
                        -- Add poison damage * probability of poisoning
                        poison_damage = 8*(1-((1-defense)^attack.number))
                    end

                    if (not best_attack) or (attack_damage > best_damage) then
                        best_damage = attack_damage
                        best_attack = attack
                    end
                end

                return best_attack, best_damage, poison_damage
            end

            -- Use cached information when possible: this is expensive
            local analysis = {}
            if not recruit_data.analyses then
                recruit_data.analyses = {}
            else
                if recruit_data.analyses[enemy_type] then
                    analysis = recruit_data.analyses[enemy_type] or {}
                end
            end
            if analysis[ally_type] then
                return analysis[ally_type]
            end

            local unit = wesnoth.create_unit {
                type = enemy_type,
                random_traits = false,
                name = "X",
                random_gender = false
            }
            local can_poison = living(unit) or wesnoth.unit_ability(unit, 'regenerate')
            local flat_defense = wesnoth.unit_defense(unit, "Gt")
            local best_defense = get_best_defense(unit)

            local recruit = wesnoth.create_unit {
                type = ally_type,
                random_traits = false,
                name = "X",
                random_gender = false
            }
            local can_poison_retaliation = living(recruit) or wesnoth.unit_ability(recruit, 'regenerate')
            best_flat_attack, best_flat_damage, flat_poison = get_best_attack(recruit, unit, flat_defense, can_poison)
            best_high_defense_attack, best_high_defense_damage, high_defense_poison = get_best_attack(recruit, unit, best_defense, can_poison)
            best_retaliation, best_retaliation_damage, retaliation_poison = get_best_attack(unit, recruit, wesnoth.unit_defense(recruit, "Gt"), can_poison_retaliation)

            local result = {
                offense = { attack = best_flat_attack, damage = best_flat_damage, poison_damage = flat_poison },
                defense = { attack = best_high_defense_attack, damage = best_high_defense_damage, poison_damage = high_defense_poison },
                retaliation = { attack = best_retaliation, damage = best_retaliation_damage, poison_damage = retaliation_poison }
            }
            analysis[ally_type] = result

            -- Cache result before returning
            recruit_data.analyses[enemy_type] = analysis
            return analysis[ally_type]
        end

        function can_slow(unit)
            for defender_attack in H.child_range(unit.__cfg, 'attack') do
                for special in H.child_range(defender_attack, 'specials') do
                    if H.get_child(special, 'slow') then
                        return true
                    end
                end
            end
            return false
        end

        function get_hp_ratio_with_gold()
            function sum_gold_for_sides(side_filter)
                -- sum positive amounts of gold for a set of sides
                -- positive only because it is used to estimate the number of enemy units that could appear
                -- and negative numbers should't subtract from the number of units on the map
                local gold = 0
                local sides = wesnoth.get_sides(side_filter)
                for i,s in ipairs(sides) do
                    if s.gold > 0 then
                        gold = gold + s.gold
                    end
                end

                return gold
            end

            -- Hitpoint ratio of own units / enemy units
            -- Also convert available gold to a hp estimate
            my_units = AH.get_live_units {
                { "filter_side", {{"allied_with", {side = wesnoth.current.side} }} }
            }
            enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }} }
            }

            local my_hp, enemy_hp = 0, 0
            for i,u in ipairs(my_units) do my_hp = my_hp + u.hitpoints end
            for i,u in ipairs(enemies) do enemy_hp = enemy_hp + u.hitpoints end

            my_hp = my_hp + sum_gold_for_sides({{"allied_with", {side = wesnoth.current.side} }})*2.3
            enemy_hp = enemy_hp+sum_gold_for_sides({{"enemy_of", {side = wesnoth.current.side} }})*2.3
            hp_ratio = my_hp/(enemy_hp + 1e-6)

            return hp_ratio
        end

        function do_recruit_eval(data)
            -- Check if leader is on keep
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]

            if (not leader) or (not wesnoth.get_terrain_info(wesnoth.get_terrain(leader.x, leader.y)).keep) then
                return 0
            end

            -- Check if there is enough gold to recruit a unit
            local cheapest_unit_cost = AH.get_cheapest_recruit_cost()
            if cheapest_unit_cost > wesnoth.sides[wesnoth.current.side].gold then
                return 0
            end

            -- Check for space to recruit a unit
            get_current_castle(leader, data)
            local no_space = true
            for i,c in ipairs(data.castle.locs) do
                local unit = wesnoth.get_unit(c[1], c[2])
                if (not unit) then
                    no_space = false
                    break
                end
            end
            if no_space then
                return 0
            end

            -- Check for minimal recruit option
            if wesnoth.current.turn == 1 and params.min_turn_1_recruit and params.min_turn_1_recruit() then
                if not get_village_target(leader, data)[1] then
                    return 0
                end
            end

            if data.recruit == nil then
                data.recruit = init_data(leader)
            end
            data.recruit.cheapest_unit_cost = cheapest_unit_cost

            local score = 180000 -- default score if one not provided. Same as RCA AI
            if params.score_function then
                score = params.score_function()
            end
            return score
        end

        function init_data(leader)
            local data = {}

            -- Count enemies of each type
            local enemies = AH.get_live_units {
                { "filter_side", {{"enemy_of", {side = wesnoth.current.side} }}}
            }
            local enemy_counts = {}
            local enemy_types = {}

            local function add_unit_type(unit_type)
                if enemy_counts[unit_type] == nil then
                    table.insert(enemy_types, unit_type)
                    enemy_counts[unit_type] = 1
                else
                    enemy_counts[unit_type] = enemy_counts[unit_type] + 1
                end
            end

            -- Collect all enemies on map
            for i, unit in ipairs(enemies) do
                add_unit_type(unit.type)
            end
            -- Collect all possible enemy recruits and count them as virtual enemies
            local enemy_sides = wesnoth.get_sides({
                { "enemy_of", {side = wesnoth.current.side} },
                { "has_unit", { canrecruit = true }} })
            for i, side in ipairs(enemy_sides) do
                for j, unit_type in ipairs(wesnoth.sides[side.side].recruit) do
                    add_unit_type(unit_type)
                end
            end
            data.enemy_counts = enemy_counts
            data.enemy_types = enemy_types
            data.num_enemies = #enemies

            return data
        end

        function ai_cas:recruit_rushers_eval()
            local start_time, ca_name = os.clock(), 'recruit_rushers'
            if AH.print_eval() then print('     - Evaluating recruit_rushers CA:', os.clock()) end

            local score = do_recruit_eval(recruit_data)
            if score == 0 then
                -- We're done for the turn, discard data
                recruit_data.recruit = nil
            end

            AH.done_eval_messages(start_time, ca_name)
            return score
        end

        function ai_cas:recruit_rushers_exec()
            if AH.print_exec() then print('   ' .. os.clock() .. ' Executing recruit_rushers CA') end
            if AH.show_messages() then W.message { speaker = 'narrator', message = 'Recruiting' } end

            local enemy_counts = recruit_data.recruit.enemy_counts
            local enemy_types = recruit_data.recruit.enemy_types
            local num_enemies =  recruit_data.recruit.num_enemies
            local hp_ratio = get_hp_ratio_with_gold()

            -- Determine effectiveness of recruitable units against each enemy unit type
            local recruit_effectiveness = {}
            local recruit_vulnerability = {}
            local attack_type_count = {} -- The number of units who will likely use a given attack type
            local attack_range_count = {} -- The number of units who will likely use a given attack range
            local unit_attack_type_count = {} -- The attack types a unit will use
            local unit_attack_range_count = {} -- The ranges a unit will use
            local enemy_type_count = 0
            local recruit_count = {}
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                recruit_count[recruit_id] = #(AH.get_live_units { side = wesnoth.current.side, type = recruit_id, canrecruit = 'no' })
            end

            for i, unit_type in ipairs(enemy_types) do
                enemy_type_count = enemy_type_count + 1
                for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                    local analysis = analyze_enemy_unit(unit_type, recruit_id)

                    if recruit_effectiveness[recruit_id] == nil then
                        recruit_effectiveness[recruit_id] = {damage = 0, poison_damage = 0}
                        recruit_vulnerability[recruit_id] = 0
                    end

                    recruit_effectiveness[recruit_id].damage = recruit_effectiveness[recruit_id].damage + analysis.defense.damage * enemy_counts[unit_type]^2
                    if analysis.defense.poison_damage then
                        recruit_effectiveness[recruit_id].poison_damage = recruit_effectiveness[recruit_id].poison_damage +
                            analysis.defense.poison_damage * enemy_counts[unit_type]^2
                    end
                    recruit_vulnerability[recruit_id] = recruit_vulnerability[recruit_id] + (analysis.retaliation.damage * enemy_counts[unit_type])^3

                    local attack_type = analysis.defense.attack.type
                    if attack_type_count[attack_type] == nil then
                        attack_type_count[attack_type] = 0
                    end
                    attack_type_count[attack_type] = attack_type_count[attack_type] + recruit_count[recruit_id]

                    local attack_range = analysis.defense.attack.range
                    if attack_range_count[attack_range] == nil then
                        attack_range_count[attack_range] = 0
                    end
                    attack_range_count[attack_range] = attack_range_count[attack_range] + recruit_count[recruit_id]

                    if unit_attack_type_count[recruit_id] == nil then
                        unit_attack_type_count[recruit_id] = {}
                    end
                    unit_attack_type_count[recruit_id][attack_type] = true

                    if unit_attack_range_count[recruit_id] == nil then
                        unit_attack_range_count[recruit_id] = {}
                    end
                    unit_attack_range_count[recruit_id][attack_range] = true
                end
            end
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                -- Ensure effectiveness and vulnerability are positive.
                -- Negative values imply that drain is involved and the amount drained is very high
                if recruit_effectiveness[recruit_id].damage <= 0 then
                    recruit_effectiveness[recruit_id].damage = 0.01
                else
                    recruit_effectiveness[recruit_id].damage = (recruit_effectiveness[recruit_id].damage / (num_enemies)^2)^0.5
                end
                recruit_effectiveness[recruit_id].poison_damage = (recruit_effectiveness[recruit_id].poison_damage / (num_enemies)^2)^0.5
                if recruit_vulnerability[recruit_id] <= 0 then
                    recruit_vulnerability[recruit_id] = 0.01
                else
                    recruit_vulnerability[recruit_id] = (recruit_vulnerability[recruit_id] / ((num_enemies)^2))^0.5
                end
            end
            -- Correct count of units for each range
            local most_common_range = nil
            local most_common_range_count = 0
            for range, count in pairs(attack_range_count) do
                attack_range_count[range] = count/enemy_type_count
                if attack_range_count[range] > most_common_range_count then
                    most_common_range = range
                    most_common_range_count = attack_range_count[range]
                end
            end
            -- Correct count of units for each attack type
            for attack_type, count in pairs(attack_type_count) do
                attack_type_count[attack_type] = count/enemy_type_count
            end

            local recruit_type = nil
            local leader = wesnoth.get_units { side = wesnoth.current.side, canrecruit = 'yes' }[1]
            repeat
                recruit_data.recruit.best_hex, recruit_data.recruit.target_hex = ai_cas:find_best_recruit_hex(leader, recruit_data)
                recruit_type = ai_cas:find_best_recruit(attack_type_count, unit_attack_type_count, recruit_effectiveness, recruit_vulnerability, attack_range_count, unit_attack_range_count, most_common_range_count)
            until recruit_type ~= nil

            if wesnoth.unit_types[recruit_type].cost <= wesnoth.sides[wesnoth.current.side].gold then
                ai.recruit(recruit_type, recruit_data.recruit.best_hex[1], recruit_data.recruit.best_hex[2])
                return true
            else
                return false
            end
        end

        function get_current_castle(leader, data)
            if (not data.castle) or (data.castle.x ~= leader.x) or (data.castle.y ~= leader.y) then
                data.castle = {}
                local width,height,border = wesnoth.get_map_size()

                data.castle = {
                    locs = wesnoth.get_locations {
                        x = "1-"..width, y = "1-"..height,
                        { "and", {
                            x = leader.x, y = leader.y, radius = 200,
                            { "filter_radius", { terrain = 'C*^*,K*^*,*^Kov,*^Cov' } }
                        }}
                    },
                    x = leader.x,
                    y = leader.y
                }
            end
        end

        function ai_cas:find_best_recruit_hex(leader, data)
            -- Find the best recruit hex
            -- First choice: a hex that can reach an unowned village
            -- Second choice: a hex close to the enemy
            local enemy_leaders = AH.get_live_units { canrecruit = 'yes',
	            { "filter_side", { { "enemy_of", {side = wesnoth.current.side} } } }
            }
            local closest_enemy_distance, closest_enemy_location = AH.get_closest_enemy()

            get_current_castle(leader, data)

            local best_hex, village = get_village_target(leader, data)
            if village[1] then
                table.insert(data.castle.assigned_villages_x, village[1])
                table.insert(data.castle.assigned_villages_y, village[2])
            else
                -- no available village, look for hex closest to enemy leader
                local max_rating = -1
                for i,c in ipairs(data.castle.locs) do
                    local rating = 0
                    local unit = wesnoth.get_unit(c[1], c[2])
                    if (not unit) then
                        for j,e in ipairs(enemy_leaders) do
                            rating = rating + 1 / H.distance_between(c[1], c[2], e.x, e.y) ^ 2.
                        end
                        rating = rating + 1 / H.distance_between(c[1], c[2], closest_enemy_location.x, closest_enemy_location.y) ^ 2.
                        if (rating > max_rating) then
                            max_rating, best_hex = rating, { c[1], c[2] }
                        end
                    end
                end
            end

            if AH.print_eval() then
                if village[1] then
                    print("Recruit at: " .. best_hex[1] .. "," .. best_hex[2] .. " -> " .. village[1] .. "," .. village[2])
                else
                    print("Recruit at: " .. best_hex[1] .. "," .. best_hex[2])
                end
            end
            return best_hex, village
        end

        function ai_cas:find_best_recruit(attack_type_count, unit_attack_type_count, recruit_effectiveness, recruit_vulnerability, attack_range_count, unit_attack_range_count, most_common_range_count)
            -- Find best recruit based on damage done to enemies present, speed, and hp/gold ratio
            local recruit_scores = {}
            local best_scores = {offense = 0, defense = 0, move = 0}
            local best_hex = recruit_data.recruit.best_hex
            local target_hex = recruit_data.recruit.target_hex
            local distance_to_enemy, enemy_location
            if target_hex[1] then
                distance_to_enemy, enemy_location = AH.get_closest_enemy(target_hex)
            else
                distance_to_enemy, enemy_location = AH.get_closest_enemy(best_hex)
            end

            local gold_limit = 9e99
            if recruit_data.castle.loose_gold_limit >= recruit_data.recruit.cheapest_unit_cost then
                gold_limit = recruit_data.castle.loose_gold_limit
            end
            --print (recruit_data.castle.loose_gold_limit .. " " .. recruit_data.recruit.cheapest_unit_cost .. " " .. gold_limit)

            local recruitable_units = {}

            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                -- Count number of units with the same attack type. Used to avoid recruiting too many of the same unit
                local attack_types = 0
                local recruit_count = 0
                for attack_type, count in pairs(unit_attack_type_count[recruit_id]) do
                    attack_types = attack_types + 1
                    recruit_count = recruit_count + attack_type_count[attack_type]
                end
                recruit_count = recruit_count / attack_types
                local recruit_modifier = 1+recruit_count/50

                -- Use time to enemy to encourage recruiting fast units when the opponent is far away (game is beginning or we're winning)
                -- Base distance on
                local recruit_unit
                if target_hex[1] then
                    recruit_unit = wesnoth.create_unit {
                        type = recruit_id,
                        x = target_hex[1],
                        y = target_hex[2],
                        random_traits = false,
                        name = "X",
                        random_gender = false
                    }
                else
                    recruit_unit = wesnoth.create_unit {
                        type = recruit_id,
                        x = best_hex[1],
                        y = best_hex[2],
                        random_traits = false,
                        name = "X",
                        random_gender = false
                    }
                end
                local path, cost = wesnoth.find_path(recruit_unit, enemy_location.x, enemy_location.y, {ignore_units = true})
                local time_to_enemy = cost / wesnoth.unit_types[recruit_id].max_moves
                local move_score = 1 / (time_to_enemy * wesnoth.unit_types[recruit_id].cost^0.5)

                local eta = math.ceil(time_to_enemy)
                if target_hex[1] then
                    -- expect a 1 turn delay to reach village
                    eta = eta + 1
                end
                -- divide the lawful bonus by eta before running it through the function because the function converts from 0 centered to 1 centered
                local lawful_bonus = wesnoth.get_time_of_day(wesnoth.current.turn + eta).lawful_bonus / eta^2
                local damage_bonus = AH.get_unit_time_of_day_bonus(recruit_unit.__cfg.alignment, lawful_bonus)
                -- Estimate effectiveness on offense and defense
                local offense_score =
                    (recruit_effectiveness[recruit_id].damage*damage_bonus+recruit_effectiveness[recruit_id].poison_damage)
                    /(wesnoth.unit_types[recruit_id].cost^0.3*recruit_modifier^4)
                local defense_score = efficiency[recruit_id]/recruit_vulnerability[recruit_id]

                local unit_score = {offense = offense_score, defense = defense_score, move = move_score}
                recruit_scores[recruit_id] = unit_score
                for key, score in pairs(unit_score) do
                    if score > best_scores[key] then
                        best_scores[key] = score
                    end
                end

                if can_slow(recruit_unit) then
                    unit_score["slows"] = true
                end
                if wesnoth.match_unit(recruit_unit, { ability = "healing" }) then
                    unit_score["heals"] = true
                end
                if wesnoth.match_unit(recruit_unit, { ability = "skirmisher" }) then
                    unit_score["skirmisher"] = true
                end
                recruitable_units[recruit_id] = recruit_unit
            end
            local healer_count, healable_count = get_unit_counts_for_healing()
            local best_score = 0
            local recruit_type = nil
            local offense_weight = 2.5
            local defense_weight = 1/hp_ratio^0.5
            local move_weight = math.max((distance_to_enemy/20)^2, 0.25)
            local randomness = params.randomness or 0.1
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                local scores = recruit_scores[recruit_id]
                local offense_score = (scores["offense"]/best_scores["offense"])^0.5
                local defense_score = (scores["defense"]/best_scores["defense"])^0.5
                local move_score = (scores["move"]/best_scores["move"])^0.5

                local bonus = math.random()*randomness
                if scores["slows"] then
                    bonus = bonus + 0.4
                end
                if scores["heals"] then
                    bonus = bonus + (healable_count/(healer_count+1))/20
                end
                if scores["skirmisher"] then
                    bonus = bonus + 0.1
                end
                for attack_range, count in pairs(unit_attack_range_count[recruit_id]) do
                    bonus = bonus + 0.02 * most_common_range_count / (attack_range_count[attack_range]+1)
                end
                bonus = bonus + 0.03 * wesnoth.races[wesnoth.unit_types[recruit_id].__cfg.race].num_traits^2
                if target_hex[1] then
                    recruitable_units[recruit_id].x = best_hex[1]
                    recruitable_units[recruit_id].y = best_hex[2]
                    local path, cost = wesnoth.find_path(recruitable_units[recruit_id], target_hex[1], target_hex[2], {viewing_side=0, max_cost=wesnoth.unit_types[recruit_id].max_moves+1})
                    if cost > wesnoth.unit_types[recruit_id].max_moves then
                        -- large penalty if the unit can't reach the target village
                        bonus = bonus - 1.1
                    end
                end

                local score = offense_score*offense_weight + defense_score*defense_weight + move_score*move_weight + bonus

                if AH.print_eval() then
                    print(recruit_id .. " score: " .. offense_score*offense_weight .. " + " .. defense_score*defense_weight .. " + " .. move_score*move_weight  .. " + " .. bonus  .. " = " .. score)
                end
                if score > best_score and wesnoth.unit_types[recruit_id].cost <= gold_limit then
                    best_score = score
                    recruit_type = recruit_id
                end
            end

            return recruit_type
        end

        function get_unit_counts_for_healing()
            local healers = #AH.get_live_units {
                side = wesnoth.current.side,
                ability = "healing",
                { "not", { canrecruit = "yes" }}
            }
            local healable = #AH.get_live_units {
                side = wesnoth.current.side,
                { "not", { ability = "regenerates" }}
            }
            return healers, healable
        end

        function get_village_target(leader, data)
            -- Only consider villages reachable by our fastest unit
            local fastest_unit_speed = 0
            for i, recruit_id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                if wesnoth.unit_types[recruit_id].max_moves > fastest_unit_speed then
                    fastest_unit_speed = wesnoth.unit_types[recruit_id].max_moves
                end
            end

            local locsx, locsy = AH.split_location_list_to_strings(data.castle.locs)

            -- get a list of all unowned villages within fastest_unit_speed
            -- TODO get list of villages not owned by allies instead
            -- this may have false positives (villages that can't be reached due to difficult/impassible terrain)
            local exclude_x, exclude_y = "0", "0"
            if data.castle.assigned_villages_x ~= nil and data.castle.assigned_villages_x[1] then
                exclude_x = table.concat(data.castle.assigned_villages_x, ",")
                exclude_y = table.concat(data.castle.assigned_villages_y, ",")
            end
            local villages = wesnoth.get_villages {
                owner_side = 0,
                { "and", {
                    radius = fastest_unit_speed,
                    x = locsx, y = locsy
                }},
                { "not", {
                    x = exclude_x,
                    y = exclude_y
                }}
            }

            local hex, target, shortest_distance = {}, {}, AH.no_path

            if not data.castle.assigned_villages_x then
                data.castle.assigned_villages_x = {}
                data.castle.assigned_villages_y = {}

                if not params.leader_takes_village or params.leader_takes_village() then
                    -- skip one village for the leader
                    for i,v in ipairs(villages) do
                        local path, cost = wesnoth.find_path(leader, v[1], v[2])
                        if cost <= leader.max_moves then
                            table.insert(data.castle.assigned_villages_x, v[1])
                            table.insert(data.castle.assigned_villages_y, v[2])
                            table.remove(villages, i)
                            break
                        end
                    end
                end
            end

            local village_count = #villages
            local test_units = get_test_units()
            local num_recruits = #test_units

            local width,height,border = wesnoth.get_map_size()
            for i,v in ipairs(villages) do
                local close_castle_hexes = wesnoth.get_locations {
                    x = locsx, y = locsy,
                    { "and", {
                      x = v[1], y = v[2],
                      radius = fastest_unit_speed
                    }},
                    { "not", { { "filter", {} } } }
                }
                for u,unit in ipairs(test_units) do
                    test_units[u].x = v[1]
                    test_units[u].y = v[2]
                end

                local viable_village = false
                local village_best_hex, village_shortest_distance = {}, AH.no_path
                for j,c in ipairs(close_castle_hexes) do
                    if c[1] > 0 and c[2] > 0 and c[1] <= width and c[2] <= height then
                        local distance = 0
                        for x,unit in ipairs(test_units) do
                            local path, unit_distance = wesnoth.find_path(unit, c[1], c[2], {viewing_side=0, max_cost=fastest_unit_speed+1})
                            distance = distance + unit_distance

                            -- Village is only viable if at least one unit can reach it
                            if unit_distance <= unit.max_moves then
                                viable_village = true
                            end
                        end
                        distance = distance / num_recruits

                        if distance < village_shortest_distance then
                            village_best_hex = c
                            village_shortest_distance = distance
                        end
                    end
                end
                if village_shortest_distance < shortest_distance then
                    hex = village_best_hex
                    target = v
                    shortest_distance = village_shortest_distance
                end
                if not viable_village then
                    -- this village could not be reached by any unit
                    -- eliminate it from consideration
                    table.insert(data.castle.assigned_villages_x, v[1])
                    table.insert(data.castle.assigned_villages_y, v[2])
                    village_count = village_count - 1
                end

            end

            data.castle.loose_gold_limit = math.floor(wesnoth.sides[wesnoth.current.side].gold/village_count + 0.5)

            return hex, target
        end

        function get_test_units()
            local test_units, num_recruits = {}, 0
            local movetypes = {}
            for x,id in ipairs(wesnoth.sides[wesnoth.current.side].recruit) do
                local custom_movement = H.get_child(wesnoth.unit_types[id].__cfg, "movement_costs")
                local movetype = wesnoth.unit_types[id].__cfg.movement_type
                if custom_movement
                or (not movetypes[movetype])
                or (movetypes[movetype] > wesnoth.unit_types[id].max_moves)
                then
                    if not custom_movement then
                        movetypes[movetype] = wesnoth.unit_types[id].max_moves
                    end
                    num_recruits = num_recruits + 1
                    test_units[num_recruits] =  wesnoth.create_unit({
                        type = id,
                        side = wesnoth.current.side,
                        random_traits = false,
                        name = "X",
                        random_gender = false
                    })
                end
            end

            return test_units
        end
    end -- init()
}
