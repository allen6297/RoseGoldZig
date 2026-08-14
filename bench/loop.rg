func main():
    var total = 0
    var i = 0
    while i < 5000000:
        total = total + i % 7
        i = i + 1
    print(total)
