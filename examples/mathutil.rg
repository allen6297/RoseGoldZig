## A small importable module of math helpers.
##
## Only `pub` declarations are visible to importers; `twice` below is
## module-private and can only be used from inside this file.

pub const PI: float = 3.14159

pub func square(n: int) -> int:
    return n * n

## Uses the private helper and the module constant, both of which resolve in
## this module even when `area` is called from another one.
pub func area(r: int) -> float:
    return PI * twice(square(r))

func twice(n: int) -> float:
    return 2.0 * n
