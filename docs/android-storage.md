# Android data directory

Open Settings, then Data storage. Grant All files access in Android's system
settings, return to Lazer, and change the Data directory to an absolute path
such as `/sdcard/Lazer`.

The selected directory is tested for write access before it is saved. The
change takes effect on the next app launch, before the audio engine or any
cache opens files. Existing support data, caches and app documents are copied
to `support`, `cache` and `documents` beneath the selected directory. Local
library and preference references to moved files are rewritten. Imported
fonts, lyrics, background pictures, the music index and the native streaming
cache all use the selected root.

Original files are retained during migration. If copying fails, the app keeps
the previous active directory and displays a migration error. Choosing Restore
defaults schedules the reverse migration to the app's standard directories.
An existing unrelated folder with conflicting data subdirectories is rejected.
Settings themselves remain in Android's private preferences so the app can
recover the directory selection when external storage is unavailable.
If a selected root becomes inaccessible, the app temporarily uses its default
directories while retaining the saved selection for recovery.

On Android 11 and later the app declares `MANAGE_EXTERNAL_STORAGE` and opens
the system's per-app All files access screen. It checks the grant after the
user returns. Older Android versions use the runtime read/write permissions.
These grants concern shared storage; Android still controls access to other
applications' private directories.

`test/app_storage_test.dart` covers migration, rewritten file references,
restoring defaults, rejected destinations, the settings flow and denied grants.
