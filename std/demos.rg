

class enitiy:
    static var count = 0

    func init():
        enitiy.count += 1

func main():
    var e0 = enitiy()
    var e1 = enitiy()
    var e2 = enitiy()

    var count = enitiy.count
    print(count)