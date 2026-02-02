local mp = require "mp"
local utils = require "mp.utils"
local input = require "mp.input"

local options =
{
    profiles = "~~/script-opts/track-selector-profiles.json",

    -- Language mapping is a slightly modified version found here:
    -- https://github.com/mpv-player/mpv/blob/master/misc/language.c
    languages = "~~/script-opts/language-code-mapping.json",

    exceptions = "~~/script-opts/track-selector-exceptions.json",

    -- Check title for "forced", "sdh", "descrip" respectively since not all tracks are flagged
    forced_check = true,
    hearing_impaired_check = true,
    visual_impaired_check = true,

    -- If multiple tracks match, precedence decides which is chosen
    audio_precedence = "codec",  -- codec, channels, bitrate, id, default
    subtitle_precedence = "codec",  -- codec, id, default, title
    -- bitrate = Highest chosen
    -- id = Lowest chosen
    -- default = Has default tag

    -- Audio ordered by uncompressed to lossless to lossy compressed
    audio_codec_order = "pcm,dts-hd,truehd,flac,dts,opus,eac3,ac3,aac,vorbis,mp3,mp2",

    -- Subtitle ordered by the ability to restyle
    subtitle_codec_order = "ass,subrip,mov_text,webvtt,hdmv_pgs_subtitle,dvd_subtitle",
    -- Advanced Substation Alpha, SRT, MP4 Time Text, WebVTT (WEB), PGS (BluRay), Vobsub (DVD)

    audio_channel_order = "8,7,6,5,4,3,2,1",

    subtitle_title_order = "mtbb,commie",  -- Placeholders. Probably only useful for sub groups

    -- If no profile is matched apply these track preferences
    audio_fallback = "eng",  -- String = alang/slang
    subtitle_fallback = 0,  -- Number = aid/sid (Use 0, not "no" to disable)

    keybind_exception = "e",  -- Except playing files path
    keybind_menu = "p",  -- Show menu of matched profiles

    log = false  -- Additional output
}

require "mp.options".read_options(options, "track-selector")

-- For exceptions
local path
local directory
local exceptions_file

-- For matching
local profiles
local languages = {}
local audio_tracks = {}
local subtitle_tracks = {}
local all_profile_matches = {}
local current_profile
local exceptions = {}

-- Flags
local file_load
local track_change = false
local manual_track_change = true
local menu_track_change = true
local exception_track_change = true
local excepted = false

-- Read track profile and language map files, convert to table
local function read_json(json_file)
    local path = mp.command_native({"expand-path", json_file})  -- Convert path to OS path
    local file = assert(io.open(path, "r"))  -- Catch 'no such file'
    local json = file:read("*all")
    file:close()

    local data = assert(utils.parse_json(json), "JSON file may be invalid: " .. path)
    return data
end

-- Get audio and subtitle tracks
local function get_track_list()
    local track_list = mp.get_property_native("track-list")

    for _, track in ipairs(track_list) do
        if track.type == "audio" then
            table.insert(audio_tracks, track)
        elseif track.type == "sub" then
            table.insert(subtitle_tracks, track)
        end
    end
end

-- Convert ISO 639-2 (eng) to ISO 639-1 (en)
local function iso_639_converter(code)
    for two, three in pairs(languages) do  -- 2 letter, 3 letter
        for _, variation in ipairs(three) do
            -- Some ISO 639-2 codes have a Bibliographic (/B) and Terminological (/T) variation
            -- Example: French ISO 639-1 = 'fr', ISO 639-2/B = 'fre', ISO 639-2/T = 'fra'
            if code == variation then
                return two
            end
        end
    end
end

-- Convert BCP 47 (en-US) to ISO 639-1 (en) code
local function bcp_47_converter(code)
    local country = string.match(code, "([%a]+)%-")  -- Capture primary subtag
    -- Not all 3 letter codes have a corresponding 2 letter code
    -- Examples: Cantonese 'yue',  Filipino 'fil'
    -- New releases seem to use BCP 47 instead of ISO 639-1/2
    -- BCP 47 includes codes from ISO 639-1/2/3/5 and others ~ 8000 entries
    -- Not interested in new language map that size - mkvtoolnix example:
    -- https://codeberg.org/mbunkus/mkvtoolnix/src/branch/main/src/common/iso639_language_list.cpp
    -- Workaround is to use exact matching in your profile preference:
    -- "subtitle_languages": ["fil-PH"],
    return country
end

-- Handle ISO 639-1 (en), ISO 639-2 (eng), BCP 47 (en-US) language codes
local function language_code_handler(preference_code, track_code)
    -- Language code conversion needed to avoid false positives and incorrect profile matching
    -- Example:
    -- track language = 'en', preference language = '!eng'. This is logically true
    -- but 'en' and 'eng' mean the same, so it should be false
    -- Since BCP 47 can be split into ISO 639-1, convert 639-2 codes to 639-1 as well for ease

    if track_code == nil then
        -- Track missing language tag e.g. external subtitles without language code in filename
        track_code = "und"
    end

    pref_code = preference_code:lower()
    trck_code = track_code:lower()

    if pref_code == trck_code then
        -- Same code, no conversion needed
        return pref_code, trck_code
    elseif #pref_code == 2 and #trck_code == 2 then
        -- Both ISO-639-1, no conversion needed
        return pref_code, trck_code
    else
        if pref_code:find("-") then
            -- BCP 47
            pref_code = bcp_47_converter(pref_code)
        end
        if trck_code:find("-") then
            -- BCP 47
            trck_code = bcp_47_converter(trck_code)
        end
        if #pref_code == 3 and pref_code ~= "und" then
            -- ISO-639-2
            pref_code = iso_639_converter(pref_code)
        end
        if #trck_code == 3 and trck_code ~= "und" then
            -- ISO-639-2
            trck_code = iso_639_converter(trck_code)
        end

        if pref_code == nil and trck_code == nil then
            -- Language codes not in language map return nil, avoid matching if both missing
            return preference_code, track_code
        end

        return pref_code, trck_code
    end
end

local function matching(preference, track, property)
    -- All matching is done ignoring case
    -- No wildcard = exact match
    -- ! at the start = not exact match
    -- ? at the end = contains
    -- ! at the start and ? at the end = not contains

    -- If not nil then lower case
    preference = preference and preference:lower()
    track = track and track:lower()

    if preference:sub(-1, -1) == "?" then
        -- Contains
        if property == "lang" then
            preference, track = language_code_handler(preference:sub(1, -2), track)
        end
        return track:find(preference:sub(1, -2)) ~= nil
    else
        -- Exact match
        if property == "lang" then
            preference, track = language_code_handler(preference, track)
        end

        return track == preference
    end
end

-- Compare each preference against each track, return matches
local function match_preferences(preferences, tracks, property)

    local matches = {}

    if preferences then
        if next(tracks) ~= nil then
            for _, track in ipairs(tracks) do

                local debug_match_pref =
                {
                    id = track.id,
                    type = track.type,
                    track = {[property] = track[property]},
                    preference = {},
                    match = nil
                }

                -- MPV track-list does not return 'commentary' flag, so not included
                if property ~= "lang" and property == "external" or property == "forced" or property == "hearing-impaired" or property == "visual-impaired" then
                    -- Yes/No options
                    if track[property] == true and preferences == "yes" then
                        table.insert(matches, track.id)
                        debug_match_pref.preference[property] = preferences
                        debug_match_pref.match = true
                    elseif track[property] == false and preferences == "no" then
                        table.insert(matches, track.id)
                        debug_match_pref.preference[property] = preferences
                        debug_match_pref.match = true
                    else
                        table.insert(matches, 0)
                        debug_match_pref.preference[property] = preferences
                        debug_match_pref.match = false
                    end

                    -- Check title for keywords since track flags are not always set
                    -- Have not found a need to differentiate audio & subtitle yet
                    if track.title then
                        if property == "forced" and options.forced_check then
                            if track.title:lower():find("forced") then
                                debug_match_pref.track["title"] = true
                                if preferences == "yes" then
                                    table.insert(matches, track.id)
                                    debug_match_pref.match = true
                                elseif preferences == "no" then
                                    table.insert(matches, 0)
                                    debug_match_pref.match = false
                                end
                            else
                                table.insert(matches, 0)
                                debug_match_pref.track["title"] = false
                                debug_match_pref.match = false
                            end
                        elseif property == "hearing-impaired" and options.hearing_impaired_check then
                            if track.title:lower():find("sdh") then
                                debug_match_pref.track["title"] = true
                                if preferences == "yes" then
                                    table.insert(matches, track.id)
                                    debug_match_pref.match = true
                                elseif preferences == "no" then
                                    table.insert(matches, 0)
                                    debug_match_pref.match = false
                                end
                            else
                                table.insert(matches, 0)
                                debug_match_pref.track["title"] = false
                                debug_match_pref.match = false
                            end
                        elseif property == "visual-impaired" and options.visual_impaired_check then
                            if track.title:lower():find("descrip") then
                                -- Covers 'descripton' & 'descriptive'
                                debug_match_pref.track["title"] = true
                                if preferences == "yes" then
                                    table.insert(matches, track.id)
                                    debug_match_pref.match = true
                                elseif preferences == "no" then
                                    table.insert(matches, 0)
                                    debug_match_pref.match = false
                                end
                            else
                                table.insert(matches, 0)
                                debug_match_pref.track["title"] = false
                                debug_match_pref.match = false
                            end
                        end
                    end
                    if options.log then
                        print(utils.to_string(debug_match_pref))
                    end
                else  -- Multiple options (table)
                    local not_contain = {}
                    local does_contain = {}

                    for _, preference in ipairs(preferences) do
                        if property == "title" and track[property] == nil then
                            -- Missing track title tag
                            track[property] = ""
                        end

                        if preference:sub(1, 1) == "!" then
                            -- Not matching
                            local result = matching(preference:sub(2, -1), track[property], property)
                            table.insert(not_contain, not result)
                        else
                            -- Matching
                            local result = matching(preference, track[property], property)
                            table.insert(does_contain, result)
                        end
                    end

                    local not_contain_result = false
                    local does_contain_result = false

                    -- All ! preferences should be true to be matched
                    for _, match in ipairs(not_contain) do
                        if match == false then
                            not_contain_result = false
                            break  -- No need to check all
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

                    debug_match_pref.preference[property] = preferences

                    -- Handle a mix of does contain and not contain preferences
                    if next(not_contain) ~= nil and next(does_contain) ~= nil then
                        if not_contain_result and does_contain_result then
                            debug_match_pref.match = true
                            table.insert(matches, debug_match_pref.id)
                        else
                            debug_match_pref.match = false
                            table.insert(matches, 0)
                        end
                    -- Only not contains    
                    elseif next(not_contain) ~= nil and next(does_contain) == nil then
                        debug_match_pref.match = not_contain_result
                        if not_contain_result then
                            table.insert(matches, debug_match_pref.id)
                        else
                            table.insert(matches, 0)
                        end
                    -- Only contains
                    elseif next(not_contain) == nil and next(does_contain) ~= nil then
                        debug_match_pref.match = does_contain_result
                        if does_contain_result then
                            table.insert(matches, debug_match_pref.id)
                        else
                            table.insert(matches, 0)
                        end
                    end

                    if options.log then
                        print(utils.to_string(debug_match_pref))
                    end
                end
            end
        else
            -- No audio/subtitle track
            table.insert(matches, 0)
        end
    end

    return matches
end

-- Filter matches to tracks that match all option preferences of a profile
local function common_matches(track_matches)
    local counts = {}
    local track_count = #track_matches

    -- Count unique ID's (ignore 0 - no match, ignore duplicates - multiple preferences match)
    for _, matches in ipairs(track_matches) do
        local seen = {}
        for _, id in ipairs(matches) do
            if id ~= 0 and not seen[id] then
                counts[id] = (counts[id] or 0) + 1
                seen[id] = true
            end
        end
    end
    local common = {}  -- Common ID's
    for id, count in pairs(counts) do
        if count == track_count then
            table.insert(common, id)
        end
    end

    if #common == 1 then
        return common[1]  -- Single match
    elseif #common > 1 then
        return common  -- Multiple matches
    else
        return nil  -- No matches
    end
end

-- Convert string into table items on comma
local function option_list(option)
    local list = {}
    for item in string.gmatch(option, '([^,]+)') do
        table.insert(list, item)
    end
    return list
end

-- If multiple matching tracks, select which according to precedence
local function match_precedence(precedence, ids, property)

    local earliest_index = math.huge
    local preferred_id = nil

    if precedence == "id" then  -- Select track with lowest ID
        table.sort(ids)
        preferred_id = ids[1]
    else
        for _, id in ipairs(ids) do
            if precedence == "default" then  -- Select track with default tag
                if property == "audio" then
                    if audio_tracks[id]["default"] then
                        preferred_id = id
                    end
                    break
                elseif property == "subtitle" then
                    if subtitle_tracks[id]["default"] then
                        preferred_id = id
                    end
                    break
                end
            elseif precedence == "codec" then  -- Select track with earliest matching codec
                if property == "audio" then
                    local audio_codec_order = option_list(options.audio_codec_order)
                    local codec = audio_tracks[id]["codec"]
                    for i, preferred_codec in ipairs(audio_codec_order) do
                        -- Can't easily diferentiate eac3 & eac3/Atmos as Atmos is metadata
                        -- Assumed file won't contain both versions and their order is enough
                        if codec:find("pcm") then  -- Ignore the many different formats
                            codec = "pcm"
                        end
                        if codec == "dts" and tonumber(audio_tracks[id]["metadata"]["BPS"]) > 1509000 then
                            codec = "dts-hd"
                            -- MPV reports both DTS and DTSHD-MA as "dts"
                            -- This is an imperfect attempt to differentiate
                        end
                        if codec == preferred_codec then
                            if i < earliest_index then
                                earliest_index = i
                                preferred_id = id
                            end
                            break  -- Stop on first match
                        end
                    end
                elseif property == "subtitle" then
                    local subtitle_codec_order = option_list(options.subtitle_codec_order)
                    local codec = subtitle_tracks[id]["codec"]
                    for i, preferred_codec in ipairs(subtitle_codec_order) do
                        if codec == preferred_codec then
                            if i < earliest_index then
                                earliest_index = i
                                preferred_id = id
                            end
                            break
                        end
                    end
                end
            elseif precedence == "bitrate" then  -- Select track with highest bitrate
                local bitrate = tonumber(audio_tracks[id]["metadata"]["BPS"])
                local current_highest = nil
                if current_highest == nil or bitrate > current_highest then
                    current_highest = bitrate
                end
            elseif precedence == "channels" then  -- Select track with earliest number in list
                local channels = audio_tracks[id]["demux-channel-count"]
                local audio_channel_order = option_list(options.audio_channel_order)
                for i, preferred_layout in ipairs(audio_channel_order) do
                    if channels == preferred_layout then
                        if i < earliest_index then
                            earliest_index = i
                            preferred_id = id
                        end
                        break
                    end
                end
            elseif precedence == "title" then
                local track_title = subtitle_tracks[id]["codec"]
                local subtitle_title_order = option_list(options.subtitle_title_order)
                for i, title in ipairs(subtitle_title_order) do
                    if title == track_title then
                        if i < earliest_index then
                            earliest_index = i
                            preferred_id = id
                        end
                        break
                    end
                end
            end
        end
    end

    if options.log then
        print("Multiple", property, "matches:", utils.to_string(ids))
        print("Using", precedence, "to select", property, "ID:", preferred_id)
    end

    return preferred_id
end

-- Match tracks to profiles
local function match_profiles(profiles)

    for _, profile in ipairs(profiles) do
        if options.log then
            print("\n" .. profile.description)
        end

        local audio_language_matches = match_preferences(profile.audio_languages, audio_tracks, "lang")
        local audio_title_matches = match_preferences(profile.audio_titles, audio_tracks, "title")
        local audio_hearing_impaired_matches = match_preferences(profile.audio_hearing_impaired, audio_tracks, "hearing-impaired")
        local audio_visual_impaired_matches = match_preferences(profile.audio_visual_impaired, audio_tracks, "visual-impaired")
        local audio_external_matches = match_preferences(profile.audio_external, audio_tracks, "external")
        local audio_format_matches = match_preferences(profile.audio_format, audio_tracks, "codec")

        local subtitle_language_matches = match_preferences(profile.subtitle_languages, subtitle_tracks, "lang")
        local subtitle_title_matches = match_preferences(profile.subtitle_titles, subtitle_tracks, "title")
        local subtitle_forced_matches = match_preferences(profile.subtitle_forced, subtitle_tracks, "forced")
        local subtitle_hearing_impaired_matches = match_preferences(profile.subtitle_hearing_impaired, subtitle_tracks, "hearing-impaired")
        local subtitle_visual_impaired_matches = match_preferences(profile.subtitle_visual_impaired, subtitle_tracks, "visual-impaired")
        local subtitle_external_matches = match_preferences(profile.subtitle_external, subtitle_tracks, "external")
        local subtitle_format_matches = match_preferences(profile.subtitle_format, subtitle_tracks, "codec")

        -- Combine audio matches
        local profile_audio_matches     = {}
        if next(audio_language_matches) ~= nil then  -- Check table is not empty
            table.insert(profile_audio_matches, audio_language_matches)
        end
        if next(audio_title_matches) ~= nil then
            table.insert(profile_audio_matches, audio_title_matches)
        end
        if next(audio_hearing_impaired_matches) ~= nil then
            table.insert(profile_audio_matches, audio_hearing_impaired_matches)
        end
        if next(audio_visual_impaired_matches) ~= nil then
            table.insert(profile_audio_matches, audio_visual_impaired_matches)
        end
        if next(audio_external_matches) ~= nil then
            table.insert(profile_audio_matches, audio_external_matches)
        end
        if next(audio_format_matches) ~= nil then
            table.insert(profile_audio_matches, audio_format_matches)
        end

        -- Combine subtitle matches
        local profile_subtitle_matches = {}
        if next(subtitle_language_matches) ~= nil then
            table.insert(profile_subtitle_matches, subtitle_language_matches)
        end
        if next(subtitle_title_matches) ~= nil then
            table.insert(profile_subtitle_matches, subtitle_title_matches)
        end
        if next(subtitle_forced_matches) ~= nil then
            table.insert(profile_subtitle_matches, subtitle_forced_matches)
        end
        if next(subtitle_hearing_impaired_matches) ~= nil then
            table.insert(profile_subtitle_matches, subtitle_hearing_impaired_matches)
        end
        if next(subtitle_visual_impaired_matches) ~= nil then
            table.insert(profile_subtitle_matches, subtitle_visual_impaired_matches)
        end
        if next(subtitle_external_matches) ~= nil then
            table.insert(profile_subtitle_matches, subtitle_external_matches)
        end
        if next(subtitle_format_matches) ~= nil then
            table.insert(profile_subtitle_matches, subtitle_format_matches)
        end

        local audio_track_id
        local subtitle_track_id

        -- Find common track ID's matching profile preferences
        if next(profile_audio_matches) ~= nil then
            audio_track_id = common_matches(profile_audio_matches)
        else
            if options.log then
                print("No audio preferences")
            end
            audio_track_id = 0
        end
        if next(profile_subtitle_matches) ~= nil then
            subtitle_track_id = common_matches(profile_subtitle_matches)
        else
            if options.log then
                print("No subtitle preferences")
            end
            subtitle_track_id = 0
        end

        -- If multiple matches
        if type(audio_track_id) == "table" and #audio_track_id ~= 0 then
            audio_track_id = match_precedence(options.audio_precedence, audio_track_id, "audio")
        end
        if type(subtitle_track_id) == "table" and #subtitle_track_id ~= 0 then
            subtitle_track_id = match_precedence(options.subtitle_precedence, subtitle_track_id, "subtitle")
        end

        -- Must match both audio and subtitle preferences
        if audio_track_id ~= nil and subtitle_track_id ~= nil then
            local profile_matches = {profile.description, {audio_track_id, subtitle_track_id}}
            table.insert(all_profile_matches, profile_matches)
        end

        if options.log then
            -- print(profile.description)
            print("Audio   ", utils.to_string(profile_audio_matches))
            print("Subtitle", utils.to_string(profile_subtitle_matches))
            print("Matched audio ID:   ", utils.to_string(audio_track_id))
            print("Matched subtitle ID:", utils.to_string(subtitle_track_id))
        end
        -- Example output:
        -- Foreign Dialog in English Media (Forced)
        -- Audio {{1}, {1}}
        -- Subtitle {{1, 2, 3, 0, 0}, {1, 0, 0, 0, 0}}
        -- ------------------------------------------------------------------------------------
        -- Examples track listing:
        --  ● Audio  --aid=1  --alang=en  (ac3 6ch 48000 Hz)
        --  ● Subs   --sid=1  --slang=en  'Forced' (subrip) [forced]
        --  ○ Subs   --sid=2  --slang=en  (subrip)
        --  ○ Subs   --sid=3  --slang=en  'SDH' (subrip)
        --  ○ Subs   --sid=4  --slang=es  (subrip)
        --  ○ Subs   --sid=5  --slang=pt  (subrip)
        -- ------------------------------------------------------------------------------------
        -- Example profile:
        -- "description": "Foreign Dialog in English Media (Forced)",
        -- "audio_languages": ["eng"],
        -- "audio_titles": ["!commentary?"],
        -- "subtitle_languages": ["eng"],
        -- "subtitle_forced": "yes"
        -- ------------------------------------------------------------------------------------
        -- Explantion:
        -- Each nested {} represents a profiles options.
        -- "Foreign Dialog in English Media (Forced)" has:
        -- 2 audio options: "audio_languages" and "audio_titles". So there are 2 nested {}
        -- 2 subtitle options: "subtitle_languages" and "subtitle_forced". So 2 nested {}
        -- The amount of numbers listed is: number of tracks * the number of preferences
        -- There is 1 audio track and 1 preference per option, so 1*1=1 number per {}
        -- There are 5 subtitle tracks and 1 preference per option, so 5*1=5 numbers per {}
        -- If 'forced_check' is enabled, extra numbers in {} as it's checking title for 'forced' as well
        -- The numbers listed represents the track ID that matched the options preference
        -- Except 0 which represents no match
        -- Audio track 1 matched both preferences
        -- Subtitle track 1 matched both preferences
        -- Only when both audio and subtitle preferences have a match will tracks be selected
        -- So the tracks selected will be aid:1, and sid:1
        -- If output was: Subtitle {{1, 2, 3, 0, 0}, {1, 2, 0, 0, 0}}
        -- Subtitle tracks 1 & 2 matched. Precedence in options will decide which selected
        -- If there are multiple ! preferences only 1 ID added to list - must all be true
    end
end

-- Remove results from previous file matching on next/previous
local function clear_matching(matches)
    for match in pairs(matches) do
        matches[match] = nil
    end
end

-- Match other profiles
local function other_profiles_matched(all_matches, profile)
    for _, match in ipairs(all_matches) do
        if match[1] == profile then
            return match[2][1], match[2][2]  -- audio, sub
        end
    end
    return nil
end

-- Select tracks that match a profile defined in script-opts/track-selector.json
mp.add_hook("on_preloaded", 50, function()

    -- Load configuration files on initial load, not on file change
    if current_profile == nil then
        path = mp.get_property_native("path")
        directory = path:match("^(.*[\\/])")  -- Path minus file

        profiles = read_json(options.profiles)
        languages = read_json(options.languages)

        exceptions_file = io.open(mp.command_native({"expand-path", options.exceptions}), "r")
        if exceptions_file then
            exceptions = read_json(options.exceptions)
            exceptions_file:close()
        end
    end

    clear_matching(audio_tracks)
    clear_matching(subtitle_tracks)
    clear_matching(all_profile_matches)

    get_track_list()
    match_profiles(profiles)

    local audio_selection
    if type(options.audio_fallback) == "string" then
        audio_selection = "alang"
    elseif type(options.audio_fallback) == "number" then
        audio_selection = "aid"
    end

    local subtitle_selection
    if type(options.subtitle_fallback) == "string" then
        subtitle_selection = "slang"
    elseif type(options.subtitle_fallback) == "number" then
        subtitle_selection = "sid"
    end

    if options.log then
        print("\nResults:")
        print(utils.to_string(all_profile_matches))
    end
    -- {{"Profile Description 1", {aid, sid}}, {"Profile Description 2", {aid, sid}}}
    -- [1]       -> {{"Profile Description 1", {aid, sid}}}
    -- [2]       -> {{"Profile Description 2", {aid, sid}}}
    -- [1][1]    -> Profile Description 1
    -- [1][2][1] -> aid
    -- [1][2][2] -> sid

    -- Apply profile
    if #all_profile_matches == 0 then
        current_profile = nil
        mp.set_property(audio_selection, options.audio_fallback)
        mp.set_property(subtitle_selection, options.subtitle_fallback)
        print("No matching profile")
        if options.log then
            print("Fallback Audio:", options.audio_fallback .. ", Subtitles:", options.subtitle_fallback)
        end
    elseif current_profile == nil then
        -- File opened
        current_profile = all_profile_matches[1][1]
        if exceptions[directory] and exceptions[directory] ~= current_profile then
            -- Current path in exceptions file
            excepted = true
            local audio_id, sub_id = other_profiles_matched(all_profile_matches, exceptions[directory])
            mp.set_property("aid", audio_id)
            mp.set_property("sid", sub_id)
            current_profile = exceptions[directory]
            print("Exception: Selecting", current_profile .. ", not", all_profile_matches[1][1])
        else
            mp.set_property("aid", all_profile_matches[1][2][1])
            mp.set_property("sid", all_profile_matches[1][2][2])
        end
        print("Applying profile:", current_profile)

    elseif current_profile ~= nil then
        -- Next/Previous file
        local audio_id, sub_id

        -- Scenario: 
        -- E01 matches profile A & B, E02 only matches profile B. E03 matches profile A and B
        -- Matching will match A for E01, switch to B for E02, switch back to A for E03
        -- If on E01 track is changed manually and now matches B, E02 and E03 will maintain B match

        if current_profile ~= all_profile_matches[1][1] then
            if track_change then
                -- Manual track change, maintain profile match
                audio_id, sub_id = other_profiles_matched(all_profile_matches, current_profile)
            else
                if excepted then
                    -- Excepted path
                    audio_id, sub_id = other_profiles_matched(all_profile_matches, current_profile)
                else
                -- Return to first profile matched after next/prev did not
                    audio_id, sub_id = other_profiles_matched(all_profile_matches, all_profile_matches[1][1])
                    current_profile = all_profile_matches[1][1]
                    exception_track_change = false
                end
            end
        else
            -- Maintain profile - see comment scenario above
            -- Catch track having different ID
            audio_id, sub_id = other_profiles_matched(all_profile_matches, current_profile)
        end

        -- Next/Prev not matching same profile, use matches from playing file
        if audio_id == nil and sub_id == nil then
            audio_id, sub_id = other_profiles_matched(all_profile_matches, all_profile_matches[1][1])
            current_profile = all_profile_matches[1][1]
        end

        print("Applying profile:", current_profile)
        mp.set_property("aid", audio_id)
        mp.set_property("sid", sub_id)
    end

end)

-- On aid change, if aid in another profile, reselect to that profiles sid
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
            local prof = match[1]
            local aid = match[2][1]
            local sid = match[2][2]

            if value == aid then
                -- Current aid matches the aid of another matched profile, update sid too
                mp.set_property("sid", sid)
                current_profile = prof
                print("Switching profile:", current_profile)
                track_change = true
                break  -- Multiple matches? Apply first
            end
        end
    end
    manual_track_change = false

end)

-- Exceptions to profile matching per folder
mp.add_forced_key_binding(options.keybind_exception, "toggle-exception", function()

    if current_profile ~= nil then
        if exceptions_file then
            -- Exception file exists
            if exceptions[directory] == current_profile then
                -- If path & profile already excepted, remove
                exceptions[directory] = nil
                print("Removing exception:", current_profile, "->", directory)
            else
                -- If path & profile not excepted or profile changed, add
                exceptions[directory] = current_profile
                print("Adding exception:", current_profile, "->", directory)
            end

            -- Update exceptions file
            local exception_file = io.open(mp.command_native({"expand-path", options.exceptions}), "w")
            exception_file:write(utils.format_json(exceptions))
            exception_file:close()
        else
            -- Create exception file
            local exception_file = io.open(mp.command_native({"expand-path", options.exceptions}), "w")
            local exception = {}
            exception[directory] = current_profile
            print("Creating exception file:", mp.command_native({"expand-path", options.exceptions}))
            print("Adding exception:", current_profile, "->", directory)
            exception_file:write(utils.format_json(exception))
            exception_file:close()
        end
    else
        print("No profile to except")
    end

end)

-- Menu for switching profiles
mp.add_forced_key_binding(options.keybind_menu, "profile-menu", function()

    local profile_menu = {}
    for _, profile in ipairs(all_profile_matches) do
        table.insert(profile_menu, profile[1])  -- Profile description
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

    input.select({
        prompt = "Select a Profile entry:",
        items = profile_menu,
        default_item = default_item,
        submit = function (index)
            -- Get aid, sid from selected entry matching profile description
            audio_id, sub_id = other_profiles_matched(all_profile_matches, profile_menu[index])
            mp.set_property("aid", audio_id)
            mp.set_property("sid", sub_id)
            if current_profile ~= profile_menu[index] then
                print("Switched profile:", profile_menu[index])
                track_change = true
            end
            current_profile = profile_menu[index]
            menu_track_change = false
        end,
    })

end)