# mpv-track-selector
Auto select audio, subtitle, secondary-subtitle tracks based on defined profiles.

## Setup
`track-selector.lua` into `~~/scripts/`

`track-selector.conf`, `track-selector-profiles.json`, `track-selector-languages.json` into `~~/script-opts/`

`track-selector-exceptions.json` will be created in `~~/script-opts/`. Don't create it yourself.

## Features
- Define profiles to match specific types of media, e.g. Anime Subbed, Anime Dubbed, Foreign, Non Linguistic, etc.
- Granular control over matching audio/subtitle tracks by their tags and flags
- Language code conversion
- Ability to filter multiple matches via: id, default, title, codec, channels, bitrate
- Secondary subtitle support
- Automatic selection
- Maintain profile on next/prev
- Ability to change profile via a menu or switching audio track. Then maintain this profile on next/prev
- Ability to toggle an exception to override the profile matching and maintain between sessions

## Configuration
### Profile
[Example track-selector-profiles.json](https://github.com/dfts8ef/mpv-track-selector/blob/main/track-selector-profiles.json)

[Wiki Examples](https://github.com/dfts8ef/mpv-track-selector/wiki/Example-Profiles)
| Option | Preference | Optional? | Basic Example |
|---|---|---|---|
| description | string | No | `"description": "Example Profile"` |
| audio_lang| array | Yes | `"audio_lang": ["jpn"]` |
| audio_title | array | Yes | `"audio_title": ["!commentary?"]` |
| audio_default | boolean | Yes | `"audio_default": "yes"` |
| audio_forced | boolean | Yes | `"audio_forced": "no"` |
| audio_hearing-impaired | boolean | Yes | `"audio_hearing-impaired": "no"` |
| audio_visual-impaired | boolean | Yes | `"audio_visual-impaired": "no"` |
| audio_external | boolean | Yes | `"audio_external": "yes"` |
| audio_codec | array | Yes | `"audio_codec": ["flac", "dts"]` |
| subtitle_lang | array | Yes | `"subtitle_lang": ["eng"]` |
| subtitle_title | array | Yes | `"subtitle_title": ["full?", "dialog?", ""]` |
| subtitle_default | boolean | Yes | `"subtitle_default": "no"` |
| subtitle_forced | boolean | Yes | `"subtitle_forced": "yes"` |
| subtitle_hearing-impaired | boolean | Yes | `"subtitle_hearing-impaired": "no"` |
| subtitle_visual-impaired | boolean | Yes |  `"subtitle_visual-impaired": "no"` |
| subtitle_external | boolean | Yes | `"subtitle_external": "yes"` |
| subtitle_codec | array | Yes | `"subtitle_codec": ["!hdmv_pgs_subtitle", "!dvd_subtitle"]`
| secondary_subtitle_lang | array | Yes | `"secondary_subtitle_lang": ["de"]` |
| secondary_subtitle_title | array | Yes | `"secondary_subtitle_title": ["dialog?"]` |
| secondary_subtitle_default | boolean | Yes | `"secondary_subtitle_default": "yes"` |
| secondary_subtitle_forced | boolean | Yes | `"secondary_subtitle_forced": "yes"` |
| secondary_subtitle_hearing-impaired | boolean | Yes | `"secondary_subtitle_hearing-impaired": "no"` |
| secondary_subtitle_visual-impaired | boolean | Yes |  `"secondary_subtitle_visual-impaired": "no"` |
| secondary_subtitle_external | boolean | Yes | `"secondary_subtitle_external": "no"` |
| secondary_subtitle_codec | array | Yes | `"secondary_subtitle_codec": ["ass", "subrip"]` |

- Order of profiles matter. If there is an overlap the first profile match is selected
- If no profile matches, track selection in `mpv.conf` is used
- No `audio_` option means no audio track selected
- No `subtitle_` option means no subtitle track selected
- No `secondary_subtitle_` option means no secondary subtitle track selected
- All matching is done ignoring case
- Arrays are string arrays. Matching ignores case. Strings can contain wildcards ( ! or ? )
- No wildcard in string means **exact match**
- `!` at the start of string means **not exact match**
- `?` at the end of string means **contains**
- `!` at the start and `?` at the end means **not contains**
- Script handles ISO 639-1, ISO 639-2, BCP-47 language code conversion, however not all BCP-47 subtags are in [track-selector-languages.json](https://github.com/dfts8ef/mpv-track-selector/blob/main/track-selector-languages.json) because that would require too many entries. Example: `fil` not in map so use `fil-PH` instead

### Configuration File
- Adjust options here, not the script. Options include:
  - Location of profiles, languages, exceptions
  - For forced/hearing-impaired/visual-impaired check title as well, since not all tracks are tagged/flagged correctly
  - Audio/Subtitle precedence if multiple tracks match
  - Keybinding for toggling exceptions (`e`) and showing profile menu (`p`)
  - OSD message settings
  - Whether to output extra information (for debugging)
