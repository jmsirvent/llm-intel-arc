**Fibonacci Function with Memoization**
=====================================

Here's a Python function that calculates the nth Fibonacci number using memoization. Memoization is a technique where we store the results of expensive function calls so that we can reuse them instead of recalculating them.

```python
def fibonacci(n, memo={}):
    """
    Calculate the nth Fibonacci number using memoization.

    Args:
        n (int): The position of the Fibonacci number to calculate.
        memo (dict, optional): A dictionary to store the memoized results. Defaults to {}.

    Returns:
        int: The nth Fibonacci number.
    """
    if n <= 0:
        return 0
    elif n == 1:
        return 1
    elif n not in memo:
        memo[n] = fibonacci(n-1, memo) + fibonacci(n-2, memo)
    return memo[n]
```

**Example Use Cases**
--------------------

```python
print(fibonacci(10))  # Output: 55
print(fibonacci(20))  # Output: 6765
print(fibonacci(30))  # Output: 832040
```

**How it Works**
-----------------

1. We define a function `fibonacci` that takes two arguments: `n` (the position of the Fibonacci number to calculate) and `memo` (a dictionary to store the memoized results).
2. We use a base case to handle the edge cases where `n` is 0 or 1.
3. If `n` is not in the `memo` dictionary, we calculate the `n`th Fibonacci number by recursively calling the function with `n-1` and `n-2` and storing the result in the `memo` dictionary.
4. Finally, we return the memoized result for `n`.

**Time Complexity**
------------------

The time complexity of this function is O(n), which is a significant improvement over the naive recursive approach (O(2^n)). This is because we're reusing the memoized results instead of recalculating them.
