## Deliberately badly-formatted (but valid) program, for the formatter:
##
##   zig build run -- fmt examples/messy.rg
##
## `fmt` re-prints it in canonical style. It runs too (`run examples/messy.rg`).

enum Suit{HEARTS,SPADES,CLUBS,DIAMONDS}

class Card:
    static var  count:int=0
    var rank:int=0
    var suit:Suit=Suit.HEARTS
    func name()->str:
        return match rank{1:"Ace"
          11:"Jack"
            _:"pip"}

func score(cards:list<Card>, mult)->int:
    var total=0
    var bump=func(c):c.rank*mult+1
    for c in cards:
        total+=bump(c)
    return (total+1)*2 - total%3

func main():
    var a:Card=Card()
    a.rank=11
    var b:Card=Card()
    b.rank=3
    print("a is", a.name())
    print("score:", score([a,b], 2))
