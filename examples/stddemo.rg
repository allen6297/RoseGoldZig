## Uses the bundled standard library (written in RoseGold itself, under `std/`).
## The `std/` root is discovered automatically, so no `--path` flag is needed:
##
##   zig build run -- run examples/stddemo.rg
##   zig build run -- run --vm examples/stddemo.rg   ## byte-identical
##
## (If you run the built binary from elsewhere, pass `--path DIR` where DIR
##  contains the `std/` folder.)

import std.lists
import std.strings
import std.mathx
import std.sets

func main():
    ## --- lists ---
    var nums = [5, 3, 8, 1, 9, 3, 5]
    print("sum:      ${lists.sum(nums)}")
    print("unique:   ${lists.unique(nums)}")
    print("chunks:   ${lists.chunk(nums, 3)}")
    var pairs = lists.zip([1, 2, 3], ["a", "b", "c"])
    print("zip:      ${pairs}")

    ## --- strings ---
    var heading = strings.title("the rose gold language")
    print("title:    ${heading}")
    var padded = strings.pad_left("7", 4, "0")
    print("padded:   ${padded}")
    var flipped = strings.reverse_str("rosegold")
    print("reversed: ${flipped}")

    ## --- mathx ---
    var primes = [n for n in 2..30 if mathx.is_prime(n)]
    print("primes:   ${primes}")
    print("gcd/lcm:  ${mathx.gcd(24, 36)} / ${mathx.lcm(4, 6)}")
    print("fib(15):  ${mathx.fib(15)}")
    print("mean:     ${mathx.mean(nums)}")

    ## --- sets ---
    var a = sets.of(nums)
    var b = sets.of([8, 9, 10, 11])
    print("set size: ${a.size()}")
    var shared = sort(a.intersect(b).to_list())
    print("shared:   ${shared}")
