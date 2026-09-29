#!/usr/bin/env python3
"""webmin-form.py ACTION [NAME=VALUE...]

Reads the HTML page a Webmin CGI printed on standard input and writes the
query string a browser submits for the form whose action is ACTION, with
every field left as the page filled it in, then NAME=VALUE replaced or
added for each argument. It is how the tests press Save on a page without
changing anything: the page, not the test, decides what "unchanged" is.
"""
import sys
from html.parser import HTMLParser
from urllib.parse import urlencode


class Form(HTMLParser):
    def __init__(self, action):
        super().__init__()
        self.action = action
        self.fields = {}
        self.select = None
        self.inside = False

    def put(self, name, value):
        self.fields[name] = value

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "form":
            target = (a.get("action") or "").split("?")[0]
            self.inside = target.endswith(self.action)
            return
        name = a.get("name")
        if not self.inside or not name:
            return
        if tag == "input":
            kind = (a.get("type") or "text").lower()
            if kind in ("radio", "checkbox"):
                if "checked" in a:
                    self.put(name, a.get("value", "on"))
            elif kind not in ("submit", "button", "reset", "image"):
                self.put(name, a.get("value") or "")
        elif tag == "select":
            self.select = name
            self.put(name, None)
        elif tag == "textarea":
            self.put(name, "")

    def handle_startendtag(self, tag, attrs):
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if tag == "form":
            self.inside = False
        elif tag == "select":
            self.select = None

    def handle_data(self, data):
        pass


class Options(Form):
    """An <option> belongs to the <select> opened before it: the first one
    is the default, a selected one wins."""

    def handle_starttag(self, tag, attrs):
        if tag == "option" and self.inside and self.select:
            a = dict(attrs)
            if self.fields[self.select] is None or "selected" in a:
                self.fields[self.select] = a.get("value", "")
            return
        super().handle_starttag(tag, attrs)


def main(argv):
    if len(argv) < 2:
        sys.exit("usage: webmin-form.py ACTION [NAME=VALUE...]")
    page = sys.stdin.read()
    form = Options(argv[1])
    form.feed(page)
    if not form.fields:
        sys.exit(f"webmin-form.py: no form posting to {argv[1]} on the page")
    for arg in argv[2:]:
        name, value = arg.split("=", 1)
        form.put(name, value)
    print(urlencode([(k, v or "") for k, v in form.fields.items()]))


if __name__ == "__main__":
    main(sys.argv)
