# Privacy Policy

Display Anchor is designed to respect your privacy. All functionality is performed locally on your Mac.

## What Data is Collected?

To restore your window layouts effectively, Display Anchor captures "snapshots" of your current workspace. A snapshot includes:
- **Display Topology:** Information about your connected displays (resolutions, arrangements, IDs).
- **Window Metadata:** Details about your open windows, including:
  - Application bundle identifiers (e.g., `com.apple.Safari`)
  - Window titles
  - Window frames (coordinates and dimensions)
  - Window roles (e.g., standard window, dialog)

Display Anchor **does not** read or capture the contents of your windows, files, or any keystrokes.

## Where is Data Stored?

Snapshots are stored exclusively on your local machine in plain JSON format at the following path:
`~/Library/Application Support/Display Anchor/LastSnapshot.json`

## Does Data Leave Your Device?

**No.** Display Anchor operates entirely offline. It does not send any data to the internet. There is no telemetry, analytics, tracking, or remote crash reporting built into the app.

## Why Are Accessibility Permissions Required?

macOS requires apps to have Accessibility permissions to query and modify the positions of windows belonging to other applications. Display Anchor uses this permission for the sole purpose of reading your window layout to create a snapshot and repositioning windows when restoring a layout. It is not used for any other purpose.

## Changes to this Policy

If we change our privacy policy, we will update this document in the repository.

## Contact

If you have any questions or concerns regarding your privacy when using Display Anchor, please open an issue in this repository.
