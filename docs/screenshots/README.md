# Screenshots

To capture docs screenshots without personal data, launch a debug build with:

```sh
open /path/to/Talaria.app --args -screenshotFixture -screenshotSurface sessions
open /path/to/Talaria.app --args -screenshotFixture -screenshotSurface chat
open /path/to/Talaria.app --args -screenshotFixture -screenshotSurface models
open /path/to/Talaria.app --args -screenshotFixture -screenshotSurface extensions
open /path/to/Talaria.app --args -screenshotFixture -screenshotSurface cron
```

## Blocking-prompt kinds

The `chat-*` surfaces open the fixture chat and inject one live blocking prompt
so its rendering can be captured — used to confirm a clarify question / secret
prompt no longer wears the "Permission Required" chrome:

```sh
open /path/to/Talaria.app --args -screenshotFixture -screenshotSurface chat-approval  # .permission
open /path/to/Talaria.app --args -screenshotFixture -screenshotSurface chat-clarify   # .question
open /path/to/Talaria.app --args -screenshotFixture -screenshotSurface chat-secret    # .secret
```

For a headless capture (no window/Space needed), `-renderPromptShots <dir>`
renders all three kinds — plus a combined `prompts-gallery.png` — to PNGs via
`ImageRenderer` and exits (macOS only):

```sh
/path/to/Talaria.app/Contents/MacOS/Talaria -renderPromptShots /tmp/talaria-prompt-shots
```
