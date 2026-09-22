# Kodi upstream policy

Noiro keeps Kodi in a separate repository so the upstream history, authorship,
and license remain clear:

- Noiro fork: <https://github.com/NoiroTV/noiro-kodi-engine>
- Kodi upstream: <https://github.com/xbmc/xbmc>
- Noiro reference: `vendor/kodi` Git submodule

The submodule pins an exact reviewed Kodi commit. Updating it is a deliberate
change: fetch upstream in the fork, review and test the new commit, update the
submodule pointer in this repository, and record the result in the pull request.

The presence of the submodule proves only which Kodi source revision Noiro is
tracking. It does not by itself prove that a Noiro-Kodi bridge builds, runs, or
passes playback tests on Android, Linux, Windows, macOS, iOS, or tvOS.

Kodi is a trademark of the XBMC Foundation. NoiroTV is an independent project
and is not affiliated with or endorsed by the Kodi Foundation.
