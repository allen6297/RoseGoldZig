## A small RoseGold program exercising the language end to end.

enum Suit { HEARTS, SPADES, CLUBS, DIAMONDS }

struct Card:
    var rank: int = 0
    var suit: Suit = Suit.HEARTS

    func name() -> str:
        return match rank {
            1: "Ace"
            11: "Jack"
            12: "Queen"
            13: "King"
            _: "pip"
        }

func fib(n: int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)

func main():
    var c: Card = Card()
    c.rank = 12
    c.suit = Suit.SPADES
    print("card:", c.name(), "of", c.suit)

    print("fib(10) =", fib(10))

    var total: int = 0
    for n in range(6):
        total = total + n
    print("sum 0..5 =", total)
