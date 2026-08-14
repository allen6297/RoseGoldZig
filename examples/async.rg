## Deterministic async/await: an `async func` returns a task, `await` runs it
## (once, memoized), and `gather` awaits a whole list. Cooperative but fully
## deterministic — identical output on the tree-walker and the --vm backend.

async func double(n: int) -> int:
    return n * 2

async func slow_sum(a: int, b: int) -> int:
    var x = await double(a)
    var y = await double(b)
    return x + y

func main():
    ## Calling an async function hands back a task, not the result yet.
    var t = double(21)
    print(await t)          ## 42

    ## Awaiting the same task again returns the memoized value (no re-run).
    print(await t)          ## 42

    ## Awaits can nest: slow_sum awaits two inner tasks.
    print(await slow_sum(3, 4))   ## 14

    ## gather awaits a list of tasks, in order.
    var tasks = [double(1), double(2), double(3)]
    print(gather(tasks))    ## [2, 4, 6]

    ## A comprehension of tasks, then gathered.
    var squares = gather([double(i) for i in 1..5])
    print(squares)          ## [2, 4, 6, 8]

    ## Errors propagate out through await.
    try:
        var bad = await failing()
        print(bad)
    catch e:
        print("caught: ${e}")

async func failing() -> int:
    raise "boom"
    return 0
