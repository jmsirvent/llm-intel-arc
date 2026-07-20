```python
def fibonacci(n: int) -> int:
    """Return the nth Fibonacci number using memoization.

    The sequence is defined as:
        F(0) = 0
        F(1) = 1
        F(n) = F(n-1) + F(n-2)  for n >= 2

    Parameters
    ----------
    n : int
        Non-negative integer index.

    Returns
    -------
    int
        The nth Fibonacci number.

    Raises
    ------
    ValueError
        If n is negative.
    """
    if n < 0:
        raise ValueError("n must be a non-negative integer")

    memo = {0: 0, 1: 1}

    def _fib(k: int) -> int:
        if k in memo:
            return memo[k]
        memo[k] = _fib(k - 1) + _fib(k - 2)
        return memo[k]

    return _fib(n)
```

Example usage:

```python
for i in range(10):
    print(i, fibonacci(i))
# 0 1 1 2 3 5 8 13 21 34
```
