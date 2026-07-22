Here's a Python function to calculate the nth Fibonacci number using memoization:

```python
def fibonacci(n, memo={}):
    # Base cases for the first two Fibonacci numbers
    if n == 0:
        return 0
    elif n == 1:
        return 1
    
    # Check if the result is already in the memo dictionary
    if n not in memo:
        # Store the result in memo dictionary to avoid redundant calculations
        memo[n] = fibonacci(n-1, memo) + fibonacci(n-2, memo)
    
    # Return the nth Fibonacci number from the memo dictionary
    return memo[n]
```

In this solution, we define a function `fibonacci` that calculates the nth Fibonacci number using a technique called memoization. Memoization helps in storing the results of expensive function calls and reusing them when the same inputs occur again, thus optimizing the computation.

The function uses a dictionary named `memo` to store the Fibonacci numbers that have already been computed. This prevents the function from recalculating the Fibonacci numbers for the same index multiple times, which significantly improves the efficiency of the function, especially for large values of `n`.

The base cases handle the first two Fibonacci numbers: `fibonacci(0)` returns 0 and `fibonacci(1)` returns 1. For other values of `n`, the function checks if the result is already in the `memo` dictionary. If not, it calculates the Fibonacci number by recursively calling itself for `n-1` and `n-2`, stores the result in `memo`, and then returns the result. This approach ensures that each Fibonacci number is calculated only once, making the function much more efficient than a naive recursive implementation.
