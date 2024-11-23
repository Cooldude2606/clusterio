local clusterio_api = require("modules/clusterio/api")
local compat = require("modules/clusterio/compat")

local v2_tech_progress = compat.version_ge("2.0.0")

local sync = {}

--- @param tech LuaTechnology
local function get_technology_progress(tech)
	if tech == tech.force.current_research then
		return tech.force.research_progress
	elseif v2_tech_progress then
		return tech.saved_progress
	else
		--- @diagnostic disable-next-line
		return tech.force.get_saved_technology_progress(tech.name)
	end
end

--- @param tech LuaTechnology
--- @param progress number
local function set_technology_progress(tech, progress)
	if tech == tech.force.current_research then
		tech.force.research_progress = progress
	elseif v2_tech_progress then
		tech.saved_progress = progress
	else
		--- @diagnostic disable-next-line
		tech.force.set_saved_technology_progress(tech.name, progress)
	end
end

--- @param no_early_return boolean?
--- @return table
local function get_script_data(no_early_return)
	local script_data = compat.script_data()
	local research_sync = script_data.research_sync
	if research_sync and not no_early_return then
		return research_sync
	end

	research_sync = research_sync or {}
	research_sync.technologies = research_sync.technologies or {}

	if research_sync.ignore_research_finished == nil then
		research_sync.ignore_research_finished = false
	end

	local force = game.forces["player"]
	for _, tech in pairs(force.technologies) do
		local progress = get_technology_progress(tech)
		research_sync.technologies[tech.name] = {
			level = tech.level,
			researched = tech.researched,
			progress = progress,
		}
	end

	script_data.research_sync = research_sync
	return research_sync
end

sync.events = {}
sync.events[clusterio_api.events.on_server_startup] = function(event)
	get_script_data(true)
end

--- @param tech LuaTechnology
local function get_contribution(tech)
	local progress = get_technology_progress(tech)
	if not progress then
		return 0, nil
	end

	local script_data = get_script_data()
	local prev_tech = script_data.technologies[tech.name]
	if prev_tech.progress and prev_tech.level == tech.level then
		return progress - prev_tech.progress, progress
	else
		return progress, progress
	end
end

--- @param tech LuaTechnology
local function send_contribution(tech)
	local contribution, progress = get_contribution(tech)
	if contribution ~= 0 then
		clusterio_api.send_json("research_sync:contribution", {
			name = tech.name,
			level = tech.level,
			contribution = contribution,
		})
		local script_data = get_script_data()
		script_data.technologies[tech.name].progress = progress
	end
end

--- @param event EventData.on_research_started
sync.events[defines.events.on_research_started] = function(event)
	local tech = event.last_research
	if tech then
		send_contribution(tech)
	end
end

--- @param event EventData.on_research_finished
sync.events[defines.events.on_research_finished] = function(event)
	local script_data = get_script_data()
	if research_sync.ignore_research_finished then
		return
	end

	local tech = event.research
	script_data.technologies[tech.name] = {
		level = tech.level,
		researched = tech.researched,
	}

	local level = tech.level
	if not tech.researched then
		level = level - 1
	end

	clusterio_api.send_json("research_sync:finished", {
		name = tech.name,
		level = level,
	})
end

sync.on_nth_tick = {}
sync.on_nth_tick[79] = function(event)
	local tech = game.forces["player"].current_research
	if tech then
		send_contribution(tech)
	end
end

research_sync = {}
function research_sync.dump_technologies()
	local force = game.forces["player"]

	local techs = {}
	for _, tech in pairs(force.technologies) do
		table.insert(techs, {
			name = tech.name,
			level = tech.level,
			progress = get_technology_progress(tech),
			researched = tech.researched,
		})
	end

	if #techs == 0 then
		rcon.print("[]")
	else
		rcon.print(compat.table_to_json(techs))
	end
end

--- @param data string
function research_sync.sync_technologies(data)
	local force = game.forces["player"]

	local nameIndex = 1
	local levelIndex = 2
	local progressIndex = 3
	local researchedIndex = 4

	local script_data = get_script_data()
	script_data.ignore_research_finished = true
	for _, tech_data in pairs(compat.json_to_table(data) --[[@as table]]) do
		local tech = force.technologies[tech_data[nameIndex]]
		if tech and tech.level <= tech_data[levelIndex] then
			local new_level = math.min(tech_data[levelIndex], tech.prototype.max_level)
			if new_level ~= tech.level then
				-- when the level of the current research changes the
				-- progress is not automatically reset.
				if force.current_research == tech then
					force.research_progress = 0
				end
				tech.level = new_level
			end

			local progress
			if tech_data[researchedIndex] then
				if force.current_research == tech then
					force.research_progress = 0
				end
				tech.researched = true
				progress = nil
			elseif tech_data[progressIndex] then
				send_contribution(tech)
				progress = tech_data[progressIndex]
				set_technology_progress(tech, progress)
			else
				progress = get_technology_progress(tech)
			end

			script_data.technologies[tech.name] = {
				level = tech.level,
				researched = tech.researched,
				progress = progress,
			}
		end
	end
	script_data.ignore_research_finished = false
end

--- @param data string
function research_sync.update_progress(data)
	local script_data = get_script_data()
	local techs = compat.json_to_table(data) --[[@as table]]
	local force = game.forces["player"]

	for _, controllerTech in ipairs(techs) do
		local tech = force.technologies[controllerTech.name]
		if tech and tech.level == controllerTech.level then
			send_contribution(tech)
			set_technology_progress(tech, controllerTech.progress)
			script_data.technologies[tech.name] = {
				level = tech.level,
				progress = controllerTech.progress
			}
		end
	end
end

--- @param name string
--- @param level number
function research_sync.research_technology(name, level)
	local force = game.forces["player"]
	local tech = force.technologies[name]
	if not tech or tech.level > level then
		return
	end

	if level > tech.prototype.max_level then
		level = tech.prototype.max_level
	end

	local script_data = get_script_data()
	script_data.ignore_research_finished = true
	if tech == force.current_research and tech.level == level then
		force.research_progress = 1

	elseif tech.level < level or tech.level == level and not tech.researched then
		tech.level = level
		tech.researched = true

		if tech.name:find("-%d+$") then
			game.print {"", "Researched ", {"technology-name." .. tech.name:gsub("-%d+$", "")}, " ", level}
		else
			game.print {"", "Researched ", {"technology-name." .. tech.name}}
		end
		game.play_sound { path = "utility/research_completed" }
	end
	script_data.ignore_research_finished = false

	script_data.technologies[tech.name] = {
		level = tech.level,
		researched = tech.researched,
	}
end


return sync
