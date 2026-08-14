## Signals: events with connected handlers. A `signal` is a first-class value
## holding an ordered handler list; `connect` registers a handler (any callable)
## and `emit` fires them in order. Top-level signals are shared; a class signal
## is created fresh per instance. Runs the same on both backends:
##
##   zig build run -- run       examples/signals.rg
##   zig build run -- run --vm  examples/signals.rg   ## the bytecode VM

signal tick(n)

class Button:
    var label: str = "?"
    signal pressed(who)

    func press(who):
        emit(pressed, who)          ## a method emits its own signal by bare name

class Counter:
    var total: int = 0

    func on_press(who):
        total = total + 1

func main():
    ## A top-level signal with two lambda handlers, fired in connection order.
    var log = []
    connect(tick, func(n): push(log, n))
    connect(tick, func(n): push(log, n * 100))
    emit(tick, 1)
    emit(tick, 2)
    print("tick log:", log)

    ## Per-instance class signals + a bound-method handler.
    var ok = Button()
    ok.label = "OK"
    var cancel = Button()
    var clicks = Counter()
    connect(ok.pressed, clicks.on_press)   ## only OK is wired to the counter
    ok.press("alice")
    cancel.press("bob")                     ## an independent signal — not counted
    ok.press("carol")
    print("OK clicks counted:", clicks.total)
    print("the signal value:", ok.pressed)
