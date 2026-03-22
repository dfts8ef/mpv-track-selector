local mp = require "mp"
local utils = require "mp.utils"
local input = require "mp.input"

local options =
{
    profiles = "~~/script-opts/track-selector-profiles.json",
    languages = "~~/script-opts/track-selector-languages.json",
    exceptions = "~~/script-opts/track-selector-exceptions.json",

    -- Check flag and title
    forced_title_check = true,
    hearing_impaired_title_check = true,
    visual_impaired_title_check = true,

    -- codec, bitrate (highest), id (lowest), default (flag), title, channels (audio)
    audio_precedence = "codec,channels,title,default,bitrate,id",
    subtitle_precedence = "codec,title,default,id",

    -- Audio codec ordered by uncompressed to lossless to lossy compressed
    audio_codec_order = "pcm,dts-hd,truehd,flac,dts,opus,eac3,ac3,aac,vorbis,mp3,mp2",
    audio_channels_order = "8,7,6,5,4,3,2,1",
    audio_title_order = "original,dub",

    -- Subtitle codec ordered by the ability to restyle
    subtitle_codec_order = "ass,subrip,mov_text,webvtt,hdmv_pgs_subtitle,dvd_subtitle",
    subtitle_title_order = "mtbb,commie",  -- Probably only useful for sub groups

    keybind_toggle_exception = "e",
    keybind_show_profile_menu = "p",

    osd_messages = true,  -- Profile changes and exceptions
    osd_duration = 3,  -- Seconds

    log = false  -- Additional output to console for debugging
}

require "mp.options".read_options(options, "track-selector")

-- For exceptions
local exeption_path
local excepted_directory
local exceptions_file

-- For matching
local profiles = {}
local languages = {}
local audio_tracks = {}
local subtitle_tracks = {}
local all_profile_matches = {}
local current_profile
local exceptions = {}

-- For precedence
local earliest_matches = {}
local earliest_index = nil

-- Flags
local file_load
local track_change = false
local manual_track_change = true
local menu_track_change = true
local exception_track_change = true
local excepted = false

local function log(message)
    if options.log then
        print(message)
    end
end

local function osd(message)
    if options.osd_messages then
        mp.osd_message(message, options.osd_duration)
    end
end

local function convert_option_to_table(option)
    local list = {}
    for item in string.gmatch(option, '([^,]+)') do
        -- Splits string on comma
        table.insert(list, item)
    end
    return list
end

local function clear_matching(matches)
    for match in pairs(matches) do
        matches[match] = nil
    end
end

local function json_file_to_table(json_file)
    local json_path = mp.command_native({"expand-path", json_file})  -- Convert path to OS specific path
    local file = assert(io.open(json_path, "r"), "No such file: " .. json_path)
    local json = file:read("*all")
    file:close()

    local data = assert(utils.parse_json(json), "JSON file may be invalid: " .. json_path)
    return data
end

local function get_track_list()
    local track_list = mp.get_property_native("track-list")

    for _, track in ipairs(track_list) do
        if track.type == "audio" then
            table.insert(audio_tracks, track)
            log(utils.to_string(track))
        elseif track.type == "sub" then
            table.insert(subtitle_tracks, track)
            log(utils.to_string(track))
        end
    end
end

local function convert_iso_639_2_to_639_1(code)
    for two, three in pairs(languages) do  -- 2 letter (639-1), 3 letter (639-2) code
        for _, variation in ipairs(three) do
            -- Some ISO 639-2 codes have a Bibliographic (/B) and Terminological (/T) variation
            -- Example: French ISO 639-1 = 'fr', ISO 639-2/B = 'fre', ISO 639-2/T = 'fra'
            if code == variation then
                return two
            end
        end
    end
end

local function convert_bcp_47_to_iso_639_1(code)
    local country = code:match("([%a]+)%-")  -- Primary subtag
    -- Not all 3 letter codes have a corresponding 2 letter code. Examples: Cantonese 'yue',  Filipino 'fil'
    -- Use the full BCP 47 code in profile preference for matching. Example: "subtitle_lang": ["fil-PH"]
    return country
end

-- Handle ISO 639-1 (en), ISO 639-2 (eng), BCP 47 (en-US) language codes
local function handle_language_codes(preference_code, track_code)
    -- Language code conversion needed to avoid false positives and incorrect profile matching
    -- Example: track language = 'en', preference language = '!eng'. 
    -- This is logically true but 'en' and 'eng' mean the same, so it should be false
    -- Since BCP 47 can be split into ISO 639-1, convert 639-2 codes to 639-1 as well for ease
    if track_code == nil then
        track_code = "und"
    end

    pref_code = preference_code:lower()
    trck_code = track_code:lower()

    if pref_code == trck_code then
        return pref_code, trck_code
    elseif #pref_code == 2 and #trck_code == 2 then
        return pref_code, trck_code
    else
        if pref_code:find("-") then
            pref_code = convert_bcp_47_to_iso_639_1(pref_code)
        end
        if trck_code:find("-") then
            trck_code = convert_bcp_47_to_iso_639_1(trck_code)
        end
        if #pref_code == 3 and pref_code ~= "und" then
            pref_code = convert_iso_639_2_to_639_1(pref_code)
        end
        if #trck_code == 3 and trck_code ~= "und" then
            trck_code = convert_iso_639_2_to_639_1(trck_code)
        end
        if pref_code == nil and trck_code == nil then
            -- Language codes not in language map return nil, avoid matching if both missing
            return preference_code, track_code
        end

        return pref_code, trck_code
    end
end

local function match_flag(track, preference, property)
    local id
    local match

    if track[property] == true and preference == "yes" then
        id = track.id
        match = true
    elseif track[property] == false and preference == "no" then
        id = track.id
        match = true
    else
        id = 0
        match = false
    end

    return id, match
end

-- Flags are not always correctly set, so search title for detection if enabled in options
local function match_flag_title(track, preference, property)
    local id
    local match
    local found
    local title = track.title:lower()

    -- Mirrors mkvtoolnix-gui : src/mkvtoolnix-gui/util/settings.cpp
    if property == "forced" then
        found = title:find("forced") or title:find("sign")
    elseif property == "hearing-impaired" then
        found = title:find("sdh") or title:find("%[cc%]") or title:find("%(cc%)")
    elseif property == "visual-impaired" then
        found = title:find("descrip")
    end
    -- MPV does not support commentary flag yet

    if found then
        if preference == "yes" then
            id = track.id
            match = true
        elseif preference == "no" then
            id = 0
            match = false
        end
    else
        if preference == "yes" then
            id = 0
            match = false
        elseif preference == "no" then
            id = track.id
            match = true
        end
    end

    return id, match
end

local function match_wildcard(preference, track, property)
    -- All matching is done ignoring case
    -- No wildcard = exact match
    -- ! at the start = not exact match
    -- ? at the end = contains
    -- ! at the start and ? at the end = not contains

    preference = preference and preference:lower()
    track = track and track:lower()

    if preference:sub(-1, -1) == "?" then
        if property == "lang" then
            preference, track = handle_language_codes(preference:sub(1, -2), track)
        end
        return track:find(preference:sub(1, -2), 1, true) ~= nil
    else
        if property == "lang" then
            preference, track = handle_language_codes(preference, track)
        end

        return track == preference
    end
end

local function match_preferences(preferences, tracks, property)
    local matches = {}
    local match
    local id

    if not preferences then
        return matches
    end

    if next(tracks) == nil then
        table.insert(matches, 0)
        return matches
    end

    for _, track in ipairs(tracks) do
        local log_matching =
        {
            id = track.id,
            type = track.type,
            track = {[property] = track[property]},
            preference = {},
            match = nil
        }

        if type(preferences) == "string" then
            -- Yes/No options
            id, match = match_flag(track, preferences, property)
            table.insert(matches, id)

            log_matching.preference[property] = preferences
            log_matching.match = match

            local property_option = property:gsub("%-", "_")  -- Convert snake case to track option - separator
            if track.title and track.title ~= "" and options[property_option .. "_title_check"] then
                id, match = match_flag_title(track, preferences, property)
                table.insert(matches, id)

                log_matching.track["title"] = track.title
                log_matching.match = match
            end
            log(utils.to_string(log_matching))

        elseif type(preferences) == "table" then
            local not_contain = {}
            local does_contain = {}

            for _, preference in ipairs(preferences) do
                if property == "title" and track[property] == nil then
                    track[property] = ""
                end

                if preference:sub(1, 1) == "!" then
                    -- Not matching
                    local result = match_wildcard(preference:sub(2, -1), track[property], property)
                    table.insert(not_contain, not result)
                else
                    -- Matching
                    local result = match_wildcard(preference, track[property], property)
                    table.insert(does_contain, result)
                end
            end

            local not_contain_result = false
            local does_contain_result = false

            -- All ! preferences should be true to be matched
            for _, match in ipairs(not_contain) do
                if match == false then
                    not_contain_result = false
                    break
                else
                    not_contain_result = true
                end
            end

            -- At least one preference should be true to be matched
            for _, match in ipairs(does_contain) do
                if match == true then
                    does_contain_result = true
                end
            end

            log_matching.preference[property] = preferences

            -- Handle a mix of does contain and not contain preferences
            if next(not_contain) ~= nil and next(does_contain) ~= nil then
                if not_contain_result and does_contain_result then
                    log_matching.match = true
                    table.insert(matches, log_matching.id)
                else
                    log_matching.match = false
                    table.insert(matches, 0)
                end
            -- Only not contains    
            elseif next(not_contain) ~= nil and next(does_contain) == nil then
                log_matching.match = not_contain_result
                if not_contain_result then
                    table.insert(matches, log_matching.id)
                else
                    table.insert(matches, 0)
                end
            -- Only contains
            elseif next(not_contain) == nil and next(does_contain) ~= nil then
                log_matching.match = does_contain_result
                if does_contain_result then
                    table.insert(matches, log_matching.id)
                else
                    table.insert(matches, 0)
                end
            end
            log(utils.to_string(log_matching))
        end
    end

    return matches
end

local function find_earliest_precedence(track_type, precedence, track_value, id)
    if track_type == "secondary subtitle" then
        track_type = "subtitle"  -- For options matching
    end

    local precedence_index = nil
    local precedence_order = convert_option_to_table(options[track_type .. "_" .. precedence .. "_order"])

    for i, order_value in ipairs(precedence_order) do
        if precedence == "title" then
            if track_value:find(order_value) then
                precedence_index = i
                break
            end
        else
            if track_value == order_value then
                precedence_index = i
                break
            end
        end
    end

    if precedence_index then
        if not earliest_index or precedence_index < earliest_index then
            earliest_index = precedence_index
            earliest_matches = {id}
        elseif precedence_index == earliest_index then
            table.insert(earliest_matches, id)
        end
    end

    return earliest_matches
end

local function match_precedence(track_ids, tracks, precedences, track_type)
    log("Multiple " .. track_type .. " matches: " .. utils.to_string(track_ids) .. " Applying precedence")
    local track_id

    for _, precedence in ipairs(convert_option_to_table(precedences)) do
        local tracks_matching_precedence = {}
        local current_highest_bitrate = 0

        if precedence == "id" then
            table.sort(track_ids)
            tracks_matching_precedence = {track_ids[1]}
        end

        for _, id in ipairs(track_ids) do
            if precedence == "default" then
                if tracks[id]["default"] then
                    table.insert(tracks_matching_precedence, id)
                end

            elseif precedence == "title" then
                local track_title
                if not tracks[id][precedence] then
                    track_title = ""
                else
                    track_title = tracks[id][precedence]:lower()
                end
                tracks_matching_precedence = find_earliest_precedence(track_type, precedence, track_title, id)

            elseif precedence == "codec" then
                local track_codec = tracks[id][precedence]
                if track_codec:find("pcm") then
                    track_codec = "pcm"  -- Ignore the many different sample formats
                end
                if track_codec == "dts" and tonumber(tracks[id]["metadata"]["BPS"]) > 1509000 then
                    track_codec = "dts-hd"
                    -- MPV reports both DTS and DTSHD-MA as 'dts'. This is an imperfect attempt to differentiate
                end
                tracks_matching_precedence = find_earliest_precedence(track_type, precedence, track_codec, id)

            elseif precedence == "channels" then
                local track_channels = tostring(tracks[id]["demux-channel-count"])
                tracks_matching_precedence = find_earliest_precedence(track_type, precedence, track_channels, id)

            elseif precedence == "bitrate" then
                local track_bitrate = tonumber(tracks[id]["metadata"]["BPS"])
                if track_bitrate > current_highest_bitrate then
                    current_highest_bitrate = track_bitrate
                    table.insert(tracks_matching_precedence, id)
                end
            end
        end

        if next(tracks_matching_precedence) == nil then
            log(precedence .. " precedence: " .. track_type .. " tracks " .. utils.to_string(track_ids) .. " did not match")
        elseif #tracks_matching_precedence == 1 then
            log(precedence .. " precedence: " .. track_type .. " track " .. tracks_matching_precedence[1] .. " matched")
            track_id = tracks_matching_precedence[1]
            break
        else
            log(precedence .. " precedence: " .. track_type .. " tracks filtered to " .. utils.to_string(tracks_matching_precedence))
            earliest_index = nil
            clear_matching(track_ids)
            for i, id in pairs(tracks_matching_precedence) do
                track_ids[i] = id
            end
        end
    end

    if track_id then
        log("Precedence matched " .. track_type .. " track: " .. track_id)
    else
        track_id = track_ids[1]
        log("Multiple matches after precedences. Using first match: " .. track_id)
    end

    return track_id
end

local function common_matching_id(track_matches, track_type)
    -- If there are x option preferences matching, there should be a track ID appearing x times for profile to match
    local match_count = {}
    local matches_required = 0
    local no_options = true

    for _, option in pairs(track_matches) do
        if next(option) then
            no_options = false
            break
        end
    end

    if no_options then
        log("No " .. track_type .. " option")
        return 0
    end

    for _, matches in ipairs(track_matches) do
        if next(matches) ~= nil then
            matches_required = matches_required + 1

            local seen = {}
            for _, id in ipairs(matches) do
                if id ~= 0 and not seen[id] then
                    match_count[id] = (match_count[id] or 0) + 1
                    seen[id] = true
                end
            end
        end
    end

    local common = {}
    for id, count in pairs(match_count) do
        if count == matches_required then
            table.insert(common, id)
        end
    end

    if #common == 1 then
        return common[1]
    elseif #common > 1 then
        local track_id
        if track_type == "audio" then
            track_id = match_precedence(common, audio_tracks, options.audio_precedence, track_type)
        elseif track_type:find("subtitle") then
            track_id = match_precedence(common, subtitle_tracks, options.subtitle_precedence, track_type)
        end
        return track_id
    else
        log("No " .. track_type .. " preferences matched")
        return nil
    end
end

local function match_profiles(profiles)
    local properties =
    {
        "lang", "title", "default", "forced", "hearing-impaired", "visual-impaired", "external", "codec"
    }

    for _, profile in ipairs(profiles) do
        log("\n" .. profile.description)

        local audio_matches = {}
        local subtitle_matches = {}
        local secondary_subtitle_matches = {}

        for _, property in ipairs(properties) do
            table.insert(audio_matches, match_preferences(profile["audio_" .. property], audio_tracks, property))
            table.insert(subtitle_matches, match_preferences(profile["subtitle_" .. property], subtitle_tracks, property))
            table.insert(secondary_subtitle_matches, match_preferences(profile["secondary_subtitle_" .. property], subtitle_tracks, property))
        end

        local audio_track_id = common_matching_id(audio_matches, "audio")
        local subtitle_track_id = common_matching_id(subtitle_matches, "subtitle")
        local secondary_subtitle_track_id = common_matching_id(secondary_subtitle_matches, "secondary subtitle")

        -- Must match both audio and subtitle preferences
        if audio_track_id ~= nil and subtitle_track_id ~= nil and secondary_subtitle_track_id ~= nil then
            profile_matches = {profile.description, {audio_track_id, subtitle_track_id, secondary_subtitle_track_id}}
            table.insert(all_profile_matches, profile_matches)
        end

        log("Audio: " .. utils.to_string(audio_matches))
        log("Subtitle: " .. utils.to_string(subtitle_matches))
        log("Secondary Subtitle: " .. utils.to_string(secondary_subtitle_matches))
        log("Matched audio ID: " .. utils.to_string(audio_track_id))
        log("Matched subtitle ID: " .. utils.to_string(subtitle_track_id))
        log("Matched secondary subtitle ID: " .. utils.to_string(secondary_subtitle_track_id))
        -- Each nested table represents a track property: {{lang}, {title}, {default} etc.
        -- Each value within nested table is a track ID that matched the property or 0 meaning no match
        -- If options *_title_check is enabled then an extra value will appear for each property: flag & title
    end
end

local function get_profiles_matching_tracks(all_matches, profile)
    for _, match in ipairs(all_matches) do
        local description = match[1]
        local aid = match[2][1]
        local sid = match[2][2]
        local secondary_sid = match[2][3]

        if description == profile then
            return aid, sid, secondary_sid
        end
    end
    return nil
end

local function set_tracks(audio_id, subtitle_id, secondary_subtitle_id)
    mp.set_property("aid", audio_id)
    mp.set_property("sid", subtitle_id)
    mp.set_property("secondary-sid", secondary_subtitle_id)
end

mp.add_hook("on_preloaded", 50, function()
    -- Load configuration files on initial load, not on file change
    if current_profile == nil then
        exeption_path = mp.get_property_native("path")
        excepted_directory = exeption_path:match("^(.*[\\/])")  -- Path minus file

        profiles = json_file_to_table(options.profiles)
        languages = json_file_to_table(options.languages)

        exceptions_file = io.open(mp.command_native({"expand-path", options.exceptions}), "r")
        if exceptions_file then
            exceptions = json_file_to_table(options.exceptions)
            exceptions_file:close()
        end
    end

    clear_matching(audio_tracks)
    clear_matching(subtitle_tracks)
    clear_matching(all_profile_matches)

    get_track_list()
    match_profiles(profiles)

    log("\nResults:\n" .. utils.to_string(all_profile_matches))

    local first_profile_matched = all_profile_matches[1]
    local first_profile_description
    local first_profile_aid
    local first_profile_sid
    local first_profile_secondary_sid

    if first_profile_matched then
        first_profile_description = first_profile_matched[1]
        first_profile_aid = first_profile_matched[2][1]
        first_profile_sid = first_profile_matched[2][2]
        first_profile_secondary_sid = first_profile_matched[2][3]
    end

    -- Apply profile
    if #all_profile_matches == 0 then
        current_profile = nil
        print("No matching profile. Using mpv.conf")
        osd("No matching profile. Using mpv.conf")
    elseif current_profile == nil then
        -- File opened
        current_profile = first_profile_description
        if exceptions[excepted_directory] and exceptions[excepted_directory] ~= current_profile then
            -- Current path in exceptions file
            excepted = true
            local audio_id, subtitle_id, secondary_subtitle_id = get_profiles_matching_tracks(all_profile_matches, exceptions[excepted_directory])

            if not (audio_id or subtitle_id or secondary_subtitle_id) then
                -- Excepted profile not in track-selector-profiles
                print("Missing profile:", exceptions[excepted_directory], "referenced in exceptions")
                audio_id, subtitle_id, secondary_subtitle_id = get_profiles_matching_tracks(all_profile_matches, current_profile)
            else
                current_profile = exceptions[excepted_directory]
                print("Exception: Selecting", current_profile .. ", not", first_profile_description)
            end
            set_tracks(audio_id, subtitle_id, secondary_subtitle_id)
        else
            set_tracks(first_profile_aid, first_profile_sid, first_profile_secondary_sid)
        end
        print("Applying profile:", current_profile)
        osd("Applying profile: " .. current_profile)

    elseif current_profile ~= nil then
        -- Next/Previous file
        local audio_id, subtitle_id, secondary_subtitle_id

        -- Scenario: 
        -- E01 matches profile A & B, E02 only matches profile B. E03 matches profile A & B
        -- Matching will match A for E01, switch to B for E02, switch back to A for E03
        -- If on E01, track is changed manually and now matches B, E02 and E03 will maintain B match
        if current_profile ~= first_profile_description then
            if track_change then
                -- Manual track change, maintain profile match
                audio_id, subtitle_id, secondary_subtitle_id = get_profiles_matching_tracks(all_profile_matches, current_profile)
            else
                if excepted then
                    -- Excepted path
                    audio_id, subtitle_id, secondary_subtitle_id = get_profiles_matching_tracks(all_profile_matches, current_profile)
                else
                -- Return to first profile matched after next/prev did not
                    audio_id, subtitle_id, secondary_subtitle_id = get_profiles_matching_tracks(all_profile_matches, first_profile_description)
                    current_profile = first_profile_description
                    exception_track_change = false
                end
            end
        else
            -- Maintain profile - see comment scenario above
            -- Catch track having different ID
            audio_id, subtitle_id, secondary_subtitle_id = get_profiles_matching_tracks(all_profile_matches, current_profile)
        end

        -- Next/Prev not matching same profile, use matches from playing file
        if audio_id == nil and subtitle_id == nil and secondary_subtitle_id then
            audio_id, subtitle_id, secondary_subtitle_id = get_profiles_matching_tracks(all_profile_matches, first_profile_description)
            current_profile = first_profile_description
        end

        print("Applying profile:", current_profile)
        osd("Applying profile: "  .. current_profile)
        set_tracks(audio_id, subtitle_id, secondary_subtitle_id)
    end
end)

-- On audio track change, if aid in another profile, reselect to that profiles sid
mp.observe_property("aid", "number", function(_, value)
    -- Confusing variable names but needed to work
    if not file_load then
        -- Ignore audio track changes on initial load and next/prev
        file_load = true
        return
    elseif not menu_track_change then
        -- Ignore track changes from profile menu
        menu_track_change = true
        return
    elseif not exception_track_change then
        -- Ignore track changes from exceptions
        exception_track_change = true
        return
    elseif not manual_track_change then
        -- Manual audio track changes
        for _, match in ipairs(all_profile_matches) do
            local description = match[1]
            local aid = match[2][1]
            local sid = match[2][2]
            local secondary_sid = match[2][3]

            if value == aid then
                -- Current aid matches the aid of another matched profile, update sid too
                mp.set_property("sid", sid)
                mp.set_property("secondary-sid", secondary_sid)
                current_profile = description
                print("Switching profile:", current_profile)
                osd("Switching profile: " .. current_profile)
                track_change = true
                break  -- Multiple matches? Apply first
            end
        end
    end
    manual_track_change = false
end)

mp.add_forced_key_binding(options.keybind_toggle_exception, "toggle-exception", function()
    if current_profile ~= nil then
        if exceptions_file then
            if exceptions[excepted_directory] == current_profile then
                exceptions[excepted_directory] = nil
                print("Removing exception:", current_profile, "->", excepted_directory)
                osd("Removing exception")
            else
                exceptions[excepted_directory] = current_profile
                print("Adding exception:", current_profile, "->", excepted_directory)
                osd("Adding exception")
            end

            -- Update exceptions file
            local exception_file = io.open(mp.command_native({"expand-path", options.exceptions}), "w")
            exception_file:write(utils.format_json(exceptions))
            exception_file:close()
        else
            -- Create exception file
            local exception_file = io.open(mp.command_native({"expand-path", options.exceptions}), "w")
            local exception = {}
            exception[excepted_directory] = current_profile
            print("Creating exception file:", mp.command_native({"expand-path", options.exceptions}))
            print("Adding exception:", current_profile, "->", excepted_directory)
            osd("Adding exception")
            exception_file:write(utils.format_json(exception))
            exception_file:close()
        end
    else
        print("No profile to except")
        osd("No profile to except")
    end
end)

mp.add_forced_key_binding(options.keybind_show_profile_menu, "profile-menu", function()
    local profile_menu = {}
    for _, profile in ipairs(all_profile_matches) do
        local description = profile[1]
        table.insert(profile_menu, description)
    end

    local default_item

    for i, profile in ipairs(profile_menu) do
        if profile == current_profile then
            default_item = i  -- Highlight menu item matching current profile 
        end
    end

    if #profile_menu == 0 then
        print("No Matching Profiles.")
        return
    end

    input.select(
    {
        prompt = "Select a Profile entry:",
        items = profile_menu,
        default_item = default_item,
        submit = function (index)
            audio_id, subtitle_id, secondary_subtitle_id = get_profiles_matching_tracks(all_profile_matches, profile_menu[index])
            set_tracks(audio_id, subtitle_id, secondary_subtitle_id)
            if current_profile ~= profile_menu[index] then
                print("Switched profile:", profile_menu[index])
                osd("Switched profile: " .. profile_menu[index])
                track_change = true
            end
            current_profile = profile_menu[index]
            menu_track_change = false
        end,
    })
end)
