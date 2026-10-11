#!/usr/bin/env python3
"""Serves solo/ (the serverless Dog Park) on port 9103, never cached, so a
reload always gets the latest edit."""
import functools
import http.server
import pathlib

SOLO = pathlib.Path(__file__).resolve().parent.parent / "solo"


class NoCache(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()


if __name__ == "__main__":
    handler = functools.partial(NoCache, directory=str(SOLO))
    http.server.ThreadingHTTPServer(("0.0.0.0", 9103), handler).serve_forever()
