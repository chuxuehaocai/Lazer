/// The browser's preference store is already asynchronous.
void installDesktopPreferences() {}

Future<void> flushDesktopPreferences() => Future<void>.value();
