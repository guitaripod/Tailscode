#!/usr/bin/env python3
"""The scene the camera is pointed at: one split, one new chat, one prompt.

Everything here goes through XTEST, so the app cannot tell any of it from a person — and because
it is a take and not a test, it is written in beats rather than assertions: the pointer travels
instead of teleporting, keys land on their own rhythm, letters arrive at a hand's speed, and every
screen the flow passes through is held long enough to be read before the next key moves it on.

    scripts/film-take.py                 the whole scene
    scripts/film-take.py --from split    from a beat onward, for re-shooting the back half
    scripts/film-take.py --list          the beats and what each one costs in seconds
"""
import argparse
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from film_stage import Stage  # noqa: E402

PROMPT = (
    "Write a six-line poem about coding from a phone over Tailscale, "
    "then give me three sentences on why watching an answer arrive word "
    "by word feels different from seeing it appear all at once."
)

TRANSCRIPT = (1900, 1100)
RIGHT_PANE = (3000, 1200)


def beats(stage):
    def opening():
        stage.say("the app, as it was left")
        stage.hold(3.4)
        stage.glide(*TRANSCRIPT, seconds=0.7)
        stage.scroll("up", ticks=7, gap=0.13)
        stage.hold(1.6)
        stage.scroll("down", ticks=7, gap=0.13)
        stage.hold(1.4)

    yield "open", opening

    def focus_pane():
        stage.say("a press is what says which pane you are working in")
        stage.click()
        stage.hold(1.4)

    yield "focus", focus_pane

    def split():
        stage.say("ctrl+w v — the pane divides, and the empty half asks a question")
        stage.chord("ctrl+w")
        time.sleep(0.28)
        stage.tap("v")
        stage.hold(3.4)

    yield "split", split

    def choose_server():
        stage.say("walking the servers, then choosing one")
        stage.keys("Down", gap=0.75)
        stage.keys("Down", gap=0.95)
        stage.keys("Up", gap=0.6)
        stage.keys("Up", gap=0.9)
        stage.tap("Return")
        stage.hold(3.2)

    yield "server", choose_server

    def new_chat():
        stage.say("new chat here")
        stage.tap("Return")
        stage.hold(3.4)
        stage.say("naming the folder narrows the list to it")
        stage.write("tails", speed=0.13)
        stage.hold(2.0)
        stage.tap("Return")
        stage.hold(3.6)

    yield "newchat", new_chat

    def send():
        stage.say("the prompt")
        stage.glide(*RIGHT_PANE, seconds=0.8)
        stage.hold(0.6)
        stage.write(PROMPT)
        stage.hold(1.3)
        stage.tap("Return")
        stage.say("and the answer, written rather than pasted")

    yield "send", send

    yield "stream", lambda: stage.hold(52.0)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--from", dest="start", default=None)
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--quiet", action="store_true")
    options = parser.parse_args()

    stage = Stage(verbose=not options.quiet)
    scene = list(beats(stage))
    if options.list:
        for name, _ in scene:
            print(name)
        return
    started = options.start is None
    for name, beat in scene:
        if not started:
            started = name == options.start
            if not started:
                continue
        beat()
    stage.say("cut")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
