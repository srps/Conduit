Download the disk image matching your Mac: **arm64** for Apple Silicon (M1 or
later), **x86_64** for Intel. Requires macOS 26 or later on supported hardware.

Open the `.dmg`, drag **Conduit.app** into **Applications**, and launch it from
Applications. The `.zip` contains the same app if you prefer an archive.
No Xcode, Swift installation, or local bundling is required.

These packages are ad-hoc signed and are not notarized. If macOS blocks the
first launch, go to **System Settings → Privacy & Security → Open Anyway**.
The optional privileged helper is not installed by the disk image; Conduit
uses macOS admin prompts when it is absent.

SHA-256 checksum files are included for both the ZIP and disk image.
