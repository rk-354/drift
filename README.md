# Drift — screen breaks and water

A small Windows tray app. It reminds you to look away from the screen every 30 minutes and to drink water every hour.
It uses only what is built into Windows (PowerShell 5.1 and WinForms), so there is nothing to install. It needs no admin
rights and makes no network calls.

## Start it

| To | Do |
|---|---|
| Run it now | Double-click `Start-Drift.vbs` |
| Run it now and at every sign-in | Double-click `install.cmd` |
| Stop it and remove it from sign-in | Double-click `uninstall.cmd` |
| Try it with short intervals | `wscript Start-Drift.vbs demo`: a break after 1 minute, water after 2 minutes |

A blue water drop appears near the clock. Right-click or left-click it for the menu.

## Share it

Send `share\Drift.zip`, which is 24 KB, by email, Teams or a OneDrive link. The person receiving it should:

1. Unzip it anywhere, for example in Downloads.
2. Open the `Drift` folder and double-click `install.cmd`.
3. Read the message box, which confirms Drift is installed and running. They can then delete the unzipped folder.

The installer copies Drift into `%LOCALAPPDATA%\Programs\Drift` and adds it to Startup and the Start menu. It needs no
admin rights. Running a newer zip's `install.cmd` updates an existing install in place. To remove Drift, search the
Start menu for Drift, open the file location, and run `uninstall.cmd`.

If Windows shows "Windows protected your PC", click **More info** and then **Run anyway**. This appears for any
script that came from email or the web.

After changing `drift.ps1`, rebuild the zip from the six files: `drift.ps1`, `Start-Drift.vbs`, `install.ps1`,
`install.cmd`, `uninstall.cmd` and `README.md`.

## What it does

The reminders appear as soft cards in the bottom-right corner. Each has a pastel sky background with slowly drifting
clouds and flowing waves, rounded corners and a shadow, and fades in. Screen breaks use lavender and water uses aqua.
During a break the eye icon turns into a countdown ring. The cards are drawn by the `Drift.ReminderCard` C# class
inside `drift.ps1`, which Windows compiles when the app starts.

- **Screen break, every 30 min.** A card appears bottom-right with a tip (look 20 feet away, blink, stretch). It offers
  **Start 20s break** (a countdown, after which the card closes by itself), **Snooze 5 min**, and **Skip**.
- **Water, every 60 min.** A card shows today's glasses against your target of 8. It offers **Done**, **Snooze** and
  **Skip**. You can also log a glass at any time from the tray menu.
- **Morning card, 10:00.** A warm sunrise card with a fresh-start message: sit tall, have some water, and pick today's
  one priority.
- **Afternoon card, 16:00.** An ocean-teal card with a keep-going message: the dip is normal, so push through and finish
  strong.
  - Each card has 14 wordings with the same meaning. A different one is shown each day, and the same one all day.
  - Each card appears once a day. If the PC was off at the time, the morning card still appears until 13:00 and the
    afternoon card until 19:00. A restart never repeats a card.
  - Either card can be switched off in Settings, and both can be previewed from the tray menu under **Preview daily
    cards**.
- **It stays out of the way.**
  - Cards never take keyboard focus, so they can't swallow what you are typing.
  - While Windows reports you are presenting, in full-screen video or in a full-screen app, reminders wait until you
    finish.
  - **Pause** from the menu for 30 minutes, 1 hour, 2 hours or until tomorrow.
- **Summary** (from the menu): today's water and breaks, and the last 7 days.

Everything above can be changed in **Settings**: both intervals, break length, daily target, snooze length,
sound, turning either reminder off, and starting with Windows.

## Where things are kept

`%APPDATA%\Drift\`, which is your own profile:

- `settings.json`
- `history.csv`: one row per day (glasses, breaks taken, breaks skipped), kept for a year.
- `error.log`: only appears if something went wrong.

## Check the logic

```
powershell -ExecutionPolicy Bypass -File drift.ps1 -SelfTest
```

This runs the scheduling checks: when a reminder is due, which one wins when both are, full-screen
deferral, pause, and one card at a time.
