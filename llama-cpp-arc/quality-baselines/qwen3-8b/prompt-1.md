Here's a Python function that returns the **nth Fibonacci number using memoization** to improve performance, especially for large values of `n`:

```python
def fibonacci(n, memo={}):
    """
    Returns the nth Fibonacci number using memoization.

    Parameters:
    n (int): The position in the Fibonacci sequence (0-based index).
    memo (dict): A dictionary to store previously computed Fibonacci numbers.

    Returns:
    int: The nth Fibonacci number.
    """
    if n <= 1:
        return n
    if n not in memo:
        memo[n] = fibonacci(n - 1, memo) + fibonacci(n - 2, memo)
    return memo[n]
```

### Example usage:

```python
print(fibonacci(10))  # Output: 55
print(fibonacci(0))   # Output: 0
print(fibonacci(1))   # Output: 1
```

### Explanation:

- **Memoization** is used to store previously computed Fibonacci numbers in a dictionary (`memo`), so we avoid redundant calculations.
- The function uses **recursion** with memoization to efficiently compute Fibonacci numbers.
- The base case is when `n <= 1`, where the Fibonacci number is simply `n`.

### Note:
If you want to avoid using a mutable default argument (to prevent unexpected behavior in multiple calls), you can initialize the memo inside the function:

```python
def fibonacci(n):
    memo = {}
    def fib(n):
        if n <= 1:
            return n
        if n not in memo:
            memo[n] = fib(n - 1) + fib(n - 2)
        return memo[n]
    return fib(n)
```

This version avoids using a mutable default argument.
