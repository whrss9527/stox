# App Review notes

The notes are in [listing/review_notes.txt](listing/review_notes.txt) (English, up to 4000 characters). The `app-store` workflow puts them into App Store Connect → the version page → App Review Information → Notes, sets "Sign-in required" to No, and fills in the contact from the `APPSTORE_REVIEW_CONTACT` secret when it is set.

The first review of 0.49.0 came back with Guideline 2.1 "Information Needed": App Review asked new developer accounts for a screen recording on a real Mac and for six answers, both in a reply in App Store Connect and in the Notes field for later submissions. The notes are therefore organized by Apple's numbered questions (recording, purpose and audience, how to try it, external services, regional differences, regulated industry and third-party material), followed by privacy and permissions. The recording itself is attached to the reply in App Store Connect; the API cannot reply to App Review messages.

What the notes cover, and why:

- **How to try it.** Stox has no Dock icon and no main window, so the notes start with where the menu bar icon is and walk through the panel, the expanded chart, search, the context menu, the global hotkey and Settings. The default watchlist already has symbols, so there is something to see without setting anything up.
- **Data sources** (sections 4 and 6). Guideline 5.2.2 asks apps that use third-party services for permission. The notes name every quote endpoint, say that these are the public endpoints the finance websites themselves use (no account or API key), that Hong Kong quotes are delayed and data is for reference only, and that the app offers no trading. They also explain why prices don't move outside market hours, so a reviewer on a weekend isn't confused.
- **Privacy and permissions.** One line per entitlement and per system permission (notifications, launch at login, the hotkey without Accessibility), matching the "Data Not Collected" privacy answer.
- **Updates.** The App Store build has no self-updater; the notes say so because the GitHub build does have one and the source is public.

Keep the notes in line with the description and the App Privacy answers when features change.
