## std.strings — string utilities, written in RoseGold itself.
##
##   import std.strings
##   print(strings.repeat("ab", 3))   ## ababab
##
## Runs on both backends. Indices are byte offsets (correct for ASCII text).

## `s` repeated `n` times ("" for n <= 0).
pub func repeat(s: str, n: int) -> str:
    var out = ""
    var i = 0
    while i < n:
        out = out + s
        i = i + 1
    return out

## Left-pad `s` with `fill` (a single character) up to `width`.
pub func pad_left(s: str, width: int, fill: str) -> str:
    if len(s) >= width:
        return s
    return repeat(fill, width - len(s)) + s

## Right-pad `s` with `fill` up to `width`.
pub func pad_right(s: str, width: int, fill: str) -> str:
    if len(s) >= width:
        return s
    return s + repeat(fill, width - len(s))

## Center `s` within `width`, padding both sides with `fill`.
pub func center(s: str, width: int, fill: str) -> str:
    if len(s) >= width:
        return s
    var total = width - len(s)
    var left = total / 2
    return repeat(fill, left) + s + repeat(fill, total - left)

## Uppercase the first character, leave the rest unchanged.
pub func capitalize(s: str) -> str:
    if len(s) == 0:
        return s
    return upper(s[0:1]) + s[1:len(s)]

## Capitalize each whitespace-separated word.
pub func title(s: str) -> str:
    var out = []
    for w in words(s):
        push(out, capitalize(w))
    return join(out, " ")

## Split `s` into lines on "\n" (a trailing newline yields a trailing "").
pub func lines(s: str) -> list<str>:
    return split(s, "\n")

## The whitespace-separated words of `s`, with empty pieces dropped.
pub func words(s: str) -> list<str>:
    var out = []
    for w in split(s, " "):
        if len(w) > 0:
            push(out, w)
    return out

## How many times the single character `ch` occurs in `s`.
pub func count_char(s: str, ch: str) -> int:
    var n = 0
    for i in 0..len(s):
        if s[i:i + 1] == ch:
            n = n + 1
    return n

## `s` with its characters in reverse order.
pub func reverse_str(s: str) -> str:
    var out = ""
    var i = len(s) - 1
    while i >= 0:
        out = out + s[i:i + 1]
        i = i - 1
    return out

## Whether `s` is empty or only whitespace.
pub func is_blank(s: str) -> bool:
    return len(trim(s)) == 0
