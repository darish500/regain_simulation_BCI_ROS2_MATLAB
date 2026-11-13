"""ReGain application state machine (Stage 7).

Pure Python, no ROS imports, so it can be tested with plain python3.
It turns EEG intents into destination-selection state. It never produces motion.
"""
import json

STATES = ("IDLE", "SELECTING", "CONFIRMING", "CONFIRMED", "CANCELLED")
DESTINATIONS = ("BEDROOM", "KITCHEN", "LIVING_ROOM", "ENTRANCE")
VALID_INTENTS = ("LEFT_FIST", "RIGHT_FIST", "BOTH_FEET", "REST", "NO_DECISION")
NO_ACTION_INTENTS = ("REST", "NO_DECISION")


def parse_intent(payload):
    """Return (intent, None) if the payload is usable, else (None, reason).

    Only the 'intent' field is read. confidence, agreement, seq and t may be
    any type or missing, because they are diagnostic only at this stage.
    """
    try:
        data = json.loads(payload)
    except (TypeError, ValueError) as exc:      # JSONDecodeError is a ValueError
        return None, f"malformed JSON ({exc.__class__.__name__})"
    if not isinstance(data, dict):
        return None, "JSON is not an object"
    intent = data.get("intent")
    if intent is None:
        return None, "missing 'intent' field"
    if not isinstance(intent, str) or intent not in VALID_INTENTS:
        return None, f"unknown intent {intent!r}"
    return intent, None


class ApplicationStateMachine:
    def __init__(self):
        self.state = "IDLE"
        self.index = 0                      # starts at BEDROOM
        self.confirmed_destination = None
        self.latched = False                # True while one intent is being held

    @property
    def destination(self):
        return DESTINATIONS[self.index]

    def step(self, intent):
        """Feed one intent. Returns a list of event strings (empty = nothing happened)."""
        if intent in NO_ACTION_INTENTS:
            self.latched = False            # REST / NO_DECISION release the latch
            return []
        if intent not in VALID_INTENTS:     # defensive; the node filters these first
            return [f"WARNING unknown intent {intent!r}, no action"]
        if self.latched:                    # same physical action still being held
            return []
        self.latched = True                 # act once, then wait for REST/NO_DECISION
        return self._act(intent)

    def _move(self, step):
        self.index = (self.index + step) % len(DESTINATIONS)   # wrap-around
        self.state = "SELECTING"
        return [f"Selected destination: {self.destination}", "State: SELECTING"]

    def _act(self, intent):
        s = self.state
        if s in ("IDLE", "SELECTING"):
            if intent == "RIGHT_FIST":
                return self._move(+1)
            if intent == "LEFT_FIST":
                return self._move(-1)
            if intent == "BOTH_FEET" and s == "SELECTING":
                self.state = "CONFIRMING"
                return [f"Confirm destination: {self.destination}", "State: CONFIRMING"]
        elif s == "CONFIRMING":
            if intent == "BOTH_FEET":       # second BOTH_FEET, after a REST in between
                self.confirmed_destination = self.destination
                self.state = "CONFIRMED"
                return [f"Destination confirmed: {self.confirmed_destination}",
                        "State: CONFIRMED"]
            if intent == "LEFT_FIST":
                self.state = "SELECTING"
                return ["Confirmation cancelled", "State: SELECTING"]
        elif s == "CONFIRMED":
            if intent == "LEFT_FIST":
                cancelled = self.confirmed_destination
                self.confirmed_destination = None
                self.state = "CANCELLED"
                events = [f"Destination cancelled: {cancelled}", "State: CANCELLED"]
                self.state = "IDLE"         # CANCELLED is a one-step transient state
                events.append("State: IDLE")
                return events
        return [f"Ignored {intent} in state {s}"]


# ---------------------------------------------------------------- self-test
def _feed(sm, intents):
    """Feed a list of intents and return all events produced."""
    out = []
    for i in intents:
        out += sm.step(i)
    return out


def _check(name, condition):
    print(f"{'PASS' if condition else 'FAIL'}  {name}")
    return condition


def self_test():
    ok = True

    sm = ApplicationStateMachine()                       # Test A
    _feed(sm, ["RIGHT_FIST", "REST"])
    ok &= _check("A next: BEDROOM -> KITCHEN, SELECTING",
                 sm.destination == "KITCHEN" and sm.state == "SELECTING")

    _feed(sm, ["LEFT_FIST", "REST"])                     # Test B (after A)
    ok &= _check("B previous: KITCHEN -> BEDROOM",
                 sm.destination == "BEDROOM" and sm.state == "SELECTING")

    sm = ApplicationStateMachine()
    _feed(sm, ["LEFT_FIST", "REST"])
    ok &= _check("B2 previous from start wraps to ENTRANCE",
                 sm.destination == "ENTRANCE" and sm.state == "SELECTING")

    sm = ApplicationStateMachine()                       # Test C
    _feed(sm, ["RIGHT_FIST", "REST", "BOTH_FEET", "REST"])
    ok &= _check("C first BOTH_FEET: CONFIRMING KITCHEN, nothing confirmed",
                 sm.state == "CONFIRMING" and sm.destination == "KITCHEN"
                 and sm.confirmed_destination is None)
    _feed(sm, ["BOTH_FEET", "REST"])
    ok &= _check("C second BOTH_FEET: CONFIRMED KITCHEN",
                 sm.state == "CONFIRMED" and sm.confirmed_destination == "KITCHEN")

    sm = ApplicationStateMachine()                       # Test D
    ev = _feed(sm, ["RIGHT_FIST"] * 4 + ["REST"])
    ok &= _check("D repeated RIGHT_FIST x4: exactly one destination change",
                 sm.index == 1 and sum("Selected destination" in e for e in ev) == 1)

    sm = ApplicationStateMachine()                       # Test E
    ev = _feed(sm, ["NO_DECISION", "NO_DECISION", "REST"])
    ok &= _check("E NO_DECISION/REST: no action, still IDLE",
                 ev == [] and sm.state == "IDLE" and sm.index == 0)

    sm = ApplicationStateMachine()                       # latch release
    _feed(sm, ["RIGHT_FIST"] * 3 + ["REST", "RIGHT_FIST"])
    ok &= _check("G RIGHT x3, REST, RIGHT: two destination changes", sm.index == 2)

    sm = ApplicationStateMachine()                       # direct switch
    _feed(sm, ["RIGHT_FIST", "LEFT_FIST"])
    ok &= _check("I RIGHT then LEFT with no REST: second is ignored", sm.index == 1)

    sm = ApplicationStateMachine()                       # BOTH_FEET in IDLE
    ev = _feed(sm, ["BOTH_FEET", "REST"])
    ok &= _check("J BOTH_FEET in IDLE: ignored", sm.state == "IDLE"
                 and any("Ignored" in e for e in ev))

    sm = ApplicationStateMachine()                       # cancel in CONFIRMING
    _feed(sm, ["RIGHT_FIST", "REST", "BOTH_FEET", "REST", "LEFT_FIST", "REST"])
    ok &= _check("H LEFT_FIST in CONFIRMING: back to SELECTING",
                 sm.state == "SELECTING" and sm.destination == "KITCHEN")

    sm = ApplicationStateMachine()                       # cancel in CONFIRMED
    _feed(sm, ["RIGHT_FIST", "REST", "BOTH_FEET", "REST", "BOTH_FEET", "REST"])
    ev = _feed(sm, ["LEFT_FIST", "REST"])
    ok &= _check("K LEFT_FIST in CONFIRMED: CANCELLED then IDLE, destination cleared",
                 sm.state == "IDLE" and sm.confirmed_destination is None
                 and "State: CANCELLED" in ev)

    sm = ApplicationStateMachine()                       # RIGHT in CONFIRMED
    _feed(sm, ["RIGHT_FIST", "REST", "BOTH_FEET", "REST", "BOTH_FEET", "REST"])
    _feed(sm, ["RIGHT_FIST", "REST"])
    ok &= _check("L RIGHT_FIST in CONFIRMED: ignored, still CONFIRMED",
                 sm.state == "CONFIRMED" and sm.confirmed_destination == "KITCHEN")

    good = '{"seq":3,"t":1.79E+9,"intent":"RIGV","confidence":null,"agreement":"4/4"}'
    good = good.replace("RIGV", "RIGHT_FIST")             # Test F: parsing
    ok &= _check("F valid JSON with null confidence and string agreement",
                 parse_intent(good) == ("RIGHT_FIST", None))
    ok &= _check("F malformed JSON rejected", parse_intent("{not json")[0] is None)
    ok &= _check("F missing intent rejected", parse_intent('{"seq":1}')[0] is None)
    ok &= _check("F unknown intent rejected", parse_intent('{"intent":"FORWARD"}')[0] is None)
    ok &= _check("F non-object JSON rejected", parse_intent("[1,2]")[0] is None)
    ok &= _check("F non-string intent rejected", parse_intent('{"intent":5}')[0] is None)
    ok &= _check("F None payload rejected", parse_intent(None)[0] is None)

    print("ALL PASS" if ok else "SOME TESTS FAILED")
    return ok


if __name__ == "__main__":
    raise SystemExit(0 if self_test() else 1)