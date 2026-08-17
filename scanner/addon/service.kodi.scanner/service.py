"""Scan the shared video library, clean it, then shut Kodi down.

Runs as a Kodi service addon, which means it starts automatically and needs
nothing to reach it from outside: no JSON-RPC webserver, no open port, no
polling. That matters here because the alternative (poll
Library.IsScanningVideo over HTTP) has a race at the start, where the first
poll can read "not scanning" before the scan has actually begun, and because
enabling the webserver at all would mean pre-baking guisettings.xml.

Waiting on the Monitor callbacks avoids the race entirely: the Monitor is
registered before the scan is triggered, so the finished notification cannot
be missed no matter how fast the scan completes.

Deliberately no timeout anywhere. If a scan wedges, this container stays up
with its log intact, which is the state you want to inspect. A watchdog that
killed Kodi mid-scan would destroy exactly that evidence, and force-killing
during a library write is not obviously safer than leaving it hung.
"""

import threading

import xbmc

ADDON_ID = "service.kodi.scanner"


def log(message, level=xbmc.LOGINFO):
    xbmc.log(f"[{ADDON_ID}] {message}", level)


class ScanMonitor(xbmc.Monitor):
    """Signals completion of the video scan and the video clean."""

    def __init__(self):
        super().__init__()
        self.scan_done = threading.Event()
        self.clean_done = threading.Event()

    def onScanFinished(self, library):
        if library == "video":
            log("video scan finished")
            self.scan_done.set()

    def onCleanFinished(self, library):
        if library == "video":
            log("video clean finished")
            self.clean_done.set()


def wait(event, monitor):
    """Block until event fires, or until Kodi itself asks us to stop.

    waitForAbort is polled rather than waited on directly so that a shutdown
    requested from elsewhere (kodi -q, a crash handler) doesn't leave this
    thread parked forever on an event that will never fire.
    """
    while not event.is_set():
        if monitor.abortRequested():
            log("abort requested while waiting, giving up", xbmc.LOGWARNING)
            return False
        monitor.waitForAbort(1)
    return True


def main():
    monitor = ScanMonitor()

    # Let Kodi finish coming up before asking it to do work. A service addon
    # starts early, and a scan triggered before the video library is
    # initialised is silently dropped rather than queued.
    if monitor.waitForAbort(10):
        log("aborted during startup delay", xbmc.LOGWARNING)
        return

    log("starting video library update")
    xbmc.executebuiltin("UpdateLibrary(video)")
    if not wait(monitor.scan_done, monitor):
        return

    # Clean after scanning, not before: entries for files that disappeared are
    # only knowable once the scan has walked the source, and cleaning first
    # would just be a second full pass over the same paths.
    log("starting video library clean")
    xbmc.executebuiltin("CleanLibrary(video)")
    if not wait(monitor.clean_done, monitor):
        return

    log("done, quitting kodi")
    xbmc.executebuiltin("Quit")


if __name__ == "__main__":
    main()
