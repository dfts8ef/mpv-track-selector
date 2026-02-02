# mpv-track-selector
Auto select tracks based on defined profiles.

## Setup
`track-selector.lua` into `~~/scripts/`

`track-selector.conf`, `track-selector-profiles.json`, `language-code-mapping.json` into `~~/script-opts/`

`track-selector-exceptions.json` will be created in `~~/script-opts/`. Don't create it yourself.

## Features
- Define profiles to match specific types of media, e.g. Anime Subbed, Anime Dubbed, Foreign, Non Linguistic, etc.
- Granular control over matching audio/subtitle tracks by their tags and flags
- Language code conversion
- Ability to filter multiple matches via: id, default, title, codec, channels, bitrate
- Automatic selection
- Maintain profile on next/prev
- Ability to change profile via a menu or switching audio track. Then maintain this profile on next/prev
- Ability to toggle an exception to override the profile matching and maintain between sessions

## Configuration
### Profile
[Examples](https://github.com/dfts8ef/mpv-track-selector/blob/main/track-selector-profiles.json)
| Option | Preference | Optional? |
|---|---|---|
| description | string | No |
| audio_languages| array | Yes |
| audio_titles | array | Yes |
| audio_hearing_impaired | boolean | Yes |
| audio_visual_impaired | boolean | Yes |
| audio_external | boolean | Yes |
| subtitle_languages | array | Yes |
| subtitle_titles | array | Yes |
| subtitle_hearing_impaired | boolean | Yes |
| subtitle_visual_impaired | boolean | Yes |
| subtitle_forced | boolean | Yes |
| subtitle_external | boolean | Yes |

- Order of profiles matter. If there is an overlap the first profile match is selected.
- No `audio_` option means no audio track selected
- No `subtitle_` option means no subtitle track selected
- All matching is done ignoring case
- Arrays are string arrays. Matching ignores case. Strings can contain wildcards ( ! or ? )
- No wildcard in string means **exact match**
- `!` at the start of string means **not exact match**
- `?` at the end of string means **contains**
- `!` at the start and `?` at the end means **not contains**
- Script handles ISO 639-1, ISO 639-2, BCP-47 language code conversion, however not all BCP-47 subtags are in [language-code-mapping.json](https://github.com/dfts8ef/mpv-track-selector/blob/main/language-code-mapping.json) because that would require too many entries. Example: `fil` not in map so use `fil-PH` instead.

### Configuration File
- Adjust options here, not the script. Options include:
  - Location of profiles, language map, exceptions
  - For forced/hearing-impaired/visual-impaired check title as well, since not all tracks are tagged/flagged correctly
  - Audio/Subtitle precedence if multiple tracks match
  - Audio/Subtitle fallback if no profile matches
  - Keybinding for toggling exceptions (`e`) and showing profile menu (`p`)
  - Whether to output extra information (for debugging)
