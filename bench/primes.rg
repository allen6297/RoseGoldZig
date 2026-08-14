func is_prime(n: int) -> int:
    if n < 2:
        return 0
    var d = 2
    while d * d <= n:
        if n % d == 0:
            return 0
        d = d + 1
    return 1

func main():
    var count = 0
    var n = 2
    while n < 100000:
        count = count + is_prime(n)
        n = n + 1
    print(count)
